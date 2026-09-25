import AppKit
import SwiftUI
import VerdictCore

/// Transparent host so NSMenu supplies its own material and shadow (same as Vella).
final class MenuTableHostingView: NSHostingView<ModelTable> {
    override var allowsVibrancy: Bool { true }
}

@MainActor final class ModelsMenu: NSObject {
    let backend: Backend
    private weak var tableMenu: NSMenu?
    init(backend: Backend) { self.backend = backend; super.init() }
    func modelItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Models…", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
        let menu = NSMenu(); menu.autoenablesItems = false; tableMenu = menu
        let item = NSMenuItem()
        let view = MenuTableHostingView(rootView: ModelTable(backend: backend, requestDelete: { [weak self] id in self?.confirmDeletion(id) }))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false
        view.frame = NSRect(x: 0, y: 0, width: ModelTable.width, height: ModelTable.height)
        item.view = view; menu.addItem(item); root.submenu = menu
        return root
    }
    private func confirmDeletion(_ id: String) {
        guard let model = backend.catalog.first(where: { $0.id == id }) else { return }
        tableMenu?.cancelTracking()
        DispatchQueue.main.async { [self] in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "Delete \(model.name)?"
            alert.informativeText = "Removes its downloaded weights from this Mac. If it is hot it is unloaded first. You can download it again later."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Delete")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            backend.setHot(id, false)
            backend.delete(id)
        }
    }
}

enum ModelSortColumn { case name, accuracy, calibration, speed, size, context }

struct ModelTable: View {
    static let width: CGFloat = 780
    static let height: CGFloat = 228
    @ObservedObject var backend: Backend
    var requestDelete: (String) -> Void = { _ in }
    @State private var sortColumn: ModelSortColumn = .accuracy
    @State private var ascending = false
    @State private var copied = false
    @State private var copyGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var status: WorkerStatus? { backend.status }
    private var rows: [CatalogModel] {
        let bench = backend.benchmarks
        func key(_ m: CatalogModel) -> Double {
            let b = bench[m.id]
            switch sortColumn {
            case .name: return 0
            case .accuracy: return b?.accuracy ?? -1
            case .calibration: return b.map { -$0.ece } ?? -9
            case .speed: return b.map { -$0.ms } ?? -1e9
            case .size: return Double(m.downloadBytes)
            case .context: return Double(m.context)
            }
        }
        let sorted = backend.catalog.sorted { a, b in
            if sortColumn == .name { return a.name < b.name }
            return key(a) > key(b)
        }
        return ascending ? sorted.reversed() : sorted
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                heading("Model", .name, 146, .leading)
                Text("Inputs").frame(width: 66, alignment: .leading).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                heading("Context", .context, 52, .trailing)
                heading("Params", .size, 46, .trailing)
                Text("Bits").frame(width: 72, alignment: .center).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                heading("Accuracy", .accuracy, 64, .trailing)
                heading("Calibr.", .calibration, 48, .trailing)
                heading("Speed", .speed, 52, .trailing)
                heading("On disk", .size, 62, .trailing)
                Text("").frame(width: 82)
            }.padding(.horizontal, 6)
            Divider().opacity(0.35)
            VStack(spacing: 3) {
                ForEach(rows) { model in
                    row(model)
                }
            }
            Divider().opacity(0.35)
            footer
        }.padding(.vertical, 6).padding(.leading, 6).padding(.trailing, 2)
            .frame(width: Self.width, height: Self.height)
            .background(Color.clear)
            .foregroundStyle(.primary)
            .overlay(alignment: .top) {
                if copied {
                    Text("Copied").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 3).transition(.opacity).allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder private func row(_ model: CatalogModel) -> some View {
        let reference = model.reference == true
        let hot = status?.models[model.id] != nil
        let loading = status?.loading == model.id || backend.busyModel == model.id
        let installed = status?.installed[model.id]
        let bench = backend.benchmarks[model.id]
        let measured = bench?.source == "measured"
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: hot ? "flame.fill" : reference ? "cloud" : "circle").font(.system(size: 10))
                    .foregroundStyle(hot ? Color.orange : .secondary).frame(width: 12)
                Text(model.name).font(.system(size: 11)).lineLimit(1)
                if let o = status?.models[model.id]?.optimizations {
                    Text(o.optimized ? "optimized" : "standard").font(.system(size: 9, weight: .medium))
                        .foregroundStyle(o.optimized ? Color.green : .secondary).lineLimit(1).fixedSize()
                        .help(o.summary)
                }
            }.frame(width: 146, alignment: .leading)
                .help(reference ? model.recommendation : "\(model.backbone) · \(model.languages) · \(model.context) tokens. \(model.recommendation) License: \(model.license).")
            inputIcons(model).frame(width: 66, alignment: .leading)
            Text(formatContext(model.context)).frame(width: 52, alignment: .trailing)
                .help("Maximum tokens per item, questions included. Longer items are cut from the end.")
            Text(model.params).frame(width: 46, alignment: .trailing)
            precisionPicker(model, hot: hot, loading: loading).frame(width: 72, alignment: .center)
            Text(bench.map { String(format: "%.1f%%", $0.accuracy * 100) } ?? "—").frame(width: 64, alignment: .trailing)
                .help(benchHelp(bench))
            HStack(spacing: 2) {
                Text(bench.map { String(format: "%.3f", $0.ece) } ?? "—")
                if let b = bench, b.ece > 0.25 {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundStyle(.orange).accessibilityLabel("uncalibrated")
                }
            }.frame(width: 48, alignment: .trailing)
                .help((bench?.ece ?? 0) > 0.25 ? "Expected calibration error; lower is better. This model's confidence is not trustworthy: use its answers, ignore its probabilities. " + (bench?.note ?? "") : "Expected calibration error over both sets; lower is better. Whether a reported 90% is right about 90% of the time.")
            Text(bench.map { String(format: "%.0f ms", $0.ms) } ?? "—").frame(width: 52, alignment: .trailing)
                .help(measured ? "Median per item, one question, on this Mac." : "Published p50 for the hosted API, including network.")
            Text(reference ? "API" : installed.map { formatBytes($0.bytes) } ?? "—").frame(width: 62, alignment: .trailing)
                .help(reference ? "Hosted service; nothing to download." : installed == nil ? "Not downloaded. Loading downloads \(formatBytes(model.downloadBytes)) from Hugging Face: \(model.repository)." : "Downloaded weights in the Hugging Face cache.")
            if reference {
                Text("").frame(width: 60)
                Text("").frame(width: 20)
            } else {
                Button(loading ? "…" : hot ? "Unload" : installed == nil ? "Get" : "Load") {
                    if hot { backend.unload(model.id) } else { backend.load(model.id) }
                }.buttonStyle(.bordered).controlSize(.small).frame(width: 60)
                    .disabled(loading || backend.busyModel != nil || status?.port == nil)
                    .help(hot ? "Free its memory; it stays downloaded and will not load at next launch." : installed == nil ? "Download and keep resident; hot models load again at next launch." : "Keep resident; hot models load again at next launch.")
                Button { requestDelete(model.id) } label: { Image(systemName: "trash").frame(width: 20) }
                    .buttonStyle(.plain).opacity(installed == nil ? 0 : 1).disabled(installed == nil || loading)
                    .help("Delete downloaded weights (with confirmation)")
                    .accessibilityLabel("Delete \(model.name)")
            }
        }.font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 6).frame(height: 30)
            .background(hot ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(hot ? Color(nsColor: .selectedMenuItemTextColor) : reference ? Color.secondary : Color.primary)
            .contentShape(Rectangle())
    }

    @ViewBuilder private func precisionPicker(_ model: CatalogModel, hot: Bool, loading: Bool) -> some View {
        if model.reference == true {
            Text("—").foregroundStyle(.secondary)

        } else {
            Picker("", selection: Binding(get: { backend.precision(model.id) }, set: { backend.setPrecision(model.id, $0) })) {
                Text("16").tag(0); Text("8").tag(8); Text("4").tag(4)
            }.pickerStyle(.segmented).controlSize(.mini).labelsHidden().frame(width: 72)
                .disabled(loading || backend.busyModel != nil)
                .help("Weight precision: 16 = fp16, fastest and full quality; 8-bit saves about 350 MB per model for 0.2 points; 4-bit saves about 530 MB for 1 point. A hot model reloads in place.")
        }
    }

    private func inputIcons(_ model: CatalogModel) -> some View {
        let inputs = model.inputs ?? ["text"]
        let symbols: [(String, String, String)] = [("text", "text.alignleft", "text"), ("image", "photo", "images"), ("audio", "waveform", "audio"), ("video", "video", "video")]
        return HStack(spacing: 5) {
            ForEach(symbols, id: \.0) { key, symbol, label in
                Image(systemName: symbol).font(.system(size: 10))
                    .foregroundStyle(inputs.contains(key) ? Color.primary : Color.secondary.opacity(0.25))
                    .accessibilityLabel(inputs.contains(key) ? label : "no \(label)")
            }
        }.help("Accepts " + inputs.joined(separator: ", ") + ".")
    }

    private func benchHelp(_ b: BenchmarkResult?) -> String {
        guard let b else { return "Not measured." }
        let sets = b.sets.sorted { $0.key < $1.key }.map { "\($0.key.replacingOccurrences(of: "_", with: " ")) \(String(format: "%.1f%%", $0.value * 100))" }.joined(separator: ", ")
        let base = "Mean accuracy on \(sets)."
        if b.source == "measured" { return base + " Measured on this Mac through Verdict, \(b.n ?? 0) items per set." }
        return base + " " + (b.note ?? "Published figures, not measured here.")
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if let error = backend.lastError ?? status?.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1).help(error)
            } else if let loading = status?.loading, loading != "" {
                ProgressView().controlSize(.mini)
                Text("Loading \(loading)…").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(modelRequest, forType: .string)
                    copyGeneration += 1; let generation = copyGeneration
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        guard generation == copyGeneration else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { copied = false }
                    }
                } label: {
                    HStack {
                        Text("Want another model? Copy a request for your agent.")
                        Spacer(minLength: 8)
                        Image(systemName: "doc.on.doc").accessibilityHidden(true)
                    }.padding(.horizontal, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .help(modelRequest)
                    .accessibilityHint("Copies a model-request brief to the clipboard. Nothing is sent automatically.")
            }
        }.buttonStyle(.bordered).controlSize(.small)
    }

    private func heading(_ text: String, _ column: ModelSortColumn, _ width: CGFloat, _ alignment: Alignment) -> some View {
        Button {
            if sortColumn == column { ascending.toggle() } else { sortColumn = column; ascending = column == .name }
        } label: {
            Text(text).frame(width: width, alignment: alignment)
                .overlay(alignment: alignment == .leading ? .trailing : .leading) {
                    Image(systemName: ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 8, weight: .semibold)).frame(width: 9)
                        .opacity(sortColumn == column ? 1 : 0)
                        .allowsHitTesting(false)
                }
        }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(sortColumn == column ? .primary : .secondary)
    }
}

