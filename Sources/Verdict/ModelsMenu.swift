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
        view.frame = NSRect(x: 0, y: 0, width: ModelTable.width, height: ModelTable.height(rows: backend.catalog.count))
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
            backend.delete(id)   // leaves the launch set only after the helper confirms
        }
    }
}

enum ModelSortColumn { case name, accuracy, calibration, speed, energy, memory, size, context }

struct ModelTable: View {
    static let width: CGFloat = 900
    /// Fits every catalog row (30 pt each + 3 pt spacing) plus heading, dividers and footer.
    static func height(rows: Int) -> CGFloat { 64 + CGFloat(rows) * 33 }
    @ObservedObject var backend: Backend
    var requestDelete: (String) -> Void = { _ in }
    @State private var sortColumn: ModelSortColumn = .accuracy
    @State private var ascending = false
    @State private var copied = false
    @State private var copyGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var status: WorkerStatus? { backend.status }

    /// Column widths; spacing 6 between columns.
    private enum W {
        static let model: CGFloat = 146, inputs: CGFloat = 56, context: CGFloat = 46, params: CGFloat = 42, bits: CGFloat = 92
        static let accuracy: CGFloat = 60, ece: CGFloat = 54, speed: CGFloat = 62, energy: CGFloat = 54, memory: CGFloat = 56, disk: CGFloat = 56
        static let button: CGFloat = 58, trash: CGFloat = 18
    }
    /// Subtle green/red; lighter on the hot (accent-filled) row so they stay legible.
    private static func tone(_ t: DeltaTone, hot: Bool) -> Color {
        switch t {
        case .better: return hot ? Color(red: 0.62, green: 0.96, blue: 0.68) : Color(red: 0.42, green: 0.82, blue: 0.52)
        case .worse: return hot ? Color(red: 1.0, green: 0.74, blue: 0.70) : Color(red: 1.0, green: 0.52, blue: 0.48)
        case .neutral: return .secondary
        }
    }

    /// Loaded row: the selection blue at reduced intensity, so the row reads as "hot" without shouting.
    static let hotRow = Color(nsColor: .selectedContentBackgroundColor).opacity(0.6)
    /// Same green family as the deltas, deep enough for white text on the loaded row.
    static let reloadGreen = Color(red: 0.20, green: 0.56, blue: 0.31)

    private func native(_ m: CatalogModel) -> Int { nativeBits(runtime: m.runtime) }
    private func recommended(_ m: CatalogModel) -> Int? { backend.recommendedPrecision(m.id) }
    /// Selected precision as effective bits (16/8/4, or 32 for Von); the recommended one unless the user picked.
    private func selectedBits(_ m: CatalogModel) -> Int { effectiveBits(config: backend.precision(m.id), native: native(m)) }
    /// (selected, base) results; deltas compare against the recommended precision. The reference model has only its
    /// published figures.
    private func results(_ m: CatalogModel) -> (BenchmarkResult?, BenchmarkResult?) {
        guard let b = backend.benchmarks[m.id] else { return (nil, nil) }
        if m.reference == true { let base = b.defaultResult(nativeBits: native(m)); return (base, base) }
        let base = b.result(bits: defaultBits(recommended: recommended(m), native: native(m)))
        return (b.result(bits: selectedBits(m)), base)
    }
    private func isDefault(_ m: CatalogModel) -> Bool {
        m.reference == true || selectedBits(m) == defaultBits(recommended: recommended(m), native: native(m))
    }

    private var rows: [CatalogModel] {
        func key(_ m: CatalogModel) -> Double {
            let b = results(m).0
            switch sortColumn {
            case .name: return 0
            case .accuracy: return b?.accuracy ?? -1
            case .calibration: return b?.ece.map { -$0 } ?? -9
            case .speed: return b?.ms.map { -$0 } ?? -1e9
            case .energy: return b?.j_per_1k.map { -$0 } ?? -1e12
            case .memory: return b?.memory_mb.map { -$0 } ?? -1e12
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
            HStack(spacing: 6) {
                heading("Model", .name, W.model, .leading)
                Text("Inputs").frame(width: W.inputs, alignment: .leading).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                heading("Context", .context, W.context, .trailing)
                heading("Params", .size, W.params, .trailing)
                Text("Bits").frame(width: W.bits, alignment: .leading).padding(.leading, 0).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                heading("Accuracy", .accuracy, W.accuracy, .trailing)
                heading("Calibr.", .calibration, W.ece, .trailing)
                heading("Speed", .speed, W.speed, .trailing)
                heading("J / 1k", .energy, W.energy, .trailing)
                heading("Memory", .memory, W.memory, .trailing)
                heading("On disk", .size, W.disk, .trailing)
                Text("").frame(width: W.button + W.trash + 6)
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
            .frame(width: Self.width, height: Self.height(rows: backend.catalog.count))
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
        let loaded = status?.models[model.id]
        let hot = loaded != nil
        let loading = status?.loading == model.id || backend.busyModel == model.id
        let installed = status?.installed[model.id]
        let (bench, base) = results(model)
        let compare = !isDefault(model)
        let action = loadAction(selected: backend.precision(model.id), loaded: hot ? (loaded?.bits ?? 0) : nil, native: native(model))
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: hot ? "flame.fill" : reference ? "cloud" : "circle").font(.system(size: 10))
                    .foregroundStyle(hot ? Color.orange : .secondary).frame(width: 12)
                // Engine label beneath the name, like the deltas beneath the figures. Both paths work, so both labels
                // are green; the tooltip says what is active and, on the stock path, why.
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.name).font(.system(size: 11)).lineLimit(1)
                    if let loaded {
                        Text(engineLabel(loaded, chip: status?.gpu?.chip)).font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Self.tone(.better, hot: hot)).lineLimit(1)
                            .help(engineHelp(loaded, chip: status?.gpu?.chip, effectiveBits: effectiveBits(config: loaded.bits ?? 0, native: native(model))))
                    }
                }
            }.frame(width: W.model, alignment: .leading)
                .help(reference ? model.recommendation : "\(model.backbone) · \(model.languages) · \(model.context) tokens. \(model.recommendation) License: \(model.license).")
            inputIcons(model).frame(width: W.inputs, alignment: .leading)
            Text(formatContext(model.context)).frame(width: W.context, alignment: .trailing)
                .help("Maximum tokens per item, questions included. A longer item gets its own error; it is never truncated.")
            Text(reference ? "" : model.params).frame(width: W.params, alignment: .trailing)
            precisionPicker(model, loadedBits: hot ? effectiveBits(config: loaded?.bits ?? 0, native: native(model)) : nil, loading: loading, hot: hot)
                .frame(width: W.bits, alignment: .leading)
            metric(bench?.accuracy.map { String(format: "%.1f%%", $0 * 100) }, compare ? accuracyDelta(bench?.accuracy, base: base?.accuracy) : nil, W.accuracy, hot: hot)
                .help(accuracyHelp(model, bench))
            HStack(spacing: 2) {
                if let e = bench?.ece, e > 0.25 {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundStyle(.orange).accessibilityLabel("uncalibrated")
                }
                metric(bench?.ece.map { String(format: "%.3f", $0) }, compare ? eceDelta(bench?.ece, base: base?.ece) : nil, nil, hot: hot)
            }.frame(width: W.ece, alignment: .trailing)
                .help((bench?.ece ?? 0) > 0.25 ? "Expected calibration error; lower is better. This model's confidence is not trustworthy: use its answers, ignore its probabilities. " + (bench?.note ?? "") : "Expected calibration error, mean over the benchmark tasks; lower is better. Whether a reported 90% is right about 90% of the time.")
            metric(formatMs(bench?.ms), compare ? speedDelta(bench?.ms, base: base?.ms, short: true) : nil, W.speed, hot: hot)
                .help(speedHelp(model, bench))
            metric(bench?.j_per_1k.map { String(format: "%.0f J", $0) }, compare ? energyDelta(bench?.j_per_1k, base: base?.j_per_1k, short: true) : nil, W.energy, hot: hot)
                .help(bench?.j_per_1k == nil ? "Not measured." : "Joules per 1,000 judgements, batched, net of idle." + measured(bench))
            metric(formatMemory(bench?.memory_mb), nil, W.memory, hot: hot)
                .help(bench?.memory_mb == nil ? "Not measured." : "Memory with this model loaded, after warm-up." + measured(bench))
            Text(reference ? "API" : installed.map { formatBytes($0.bytes) } ?? "—").frame(width: W.disk, alignment: .trailing)
                .help(reference ? "Hosted service; nothing to download." : installed == nil ? "Not downloaded. Loading downloads \(formatBytes(model.downloadBytes)) from Hugging Face: \(model.repository)." : "Downloaded weights in the Hugging Face cache.")
            if reference {
                Text("").frame(width: W.button + W.trash + 6)
            } else {
                loadButton(loading ? "…" : action == .unload ? "Unload" : action == .reload ? "Reload" : installed == nil ? "Get" : "Load", reload: action == .reload && !loading) {
                    if action == .unload { backend.unload(model.id) } else { backend.load(model.id) }
                }.frame(width: W.button)
                    .disabled(loading || backend.busyModel != nil || status?.port == nil)
                    .help(action == .unload ? "Free its memory; it stays downloaded and will not load at next launch."
                          : action == .reload ? "Load it at \(selectedBits(model))-bit in place of the loaded \(effectiveBits(config: loaded?.bits ?? 0, native: native(model)))-bit."
                          : installed == nil ? "Download and keep resident; hot models load again at next launch." : "Keep resident; hot models load again at next launch.")
                Button { requestDelete(model.id) } label: { Image(systemName: "trash").frame(width: W.trash) }
                    .buttonStyle(.plain).opacity(installed == nil ? 0 : 1).disabled(installed == nil || loading)
                    .help("Delete downloaded weights (with confirmation)")
                    .accessibilityLabel("Delete \(model.name)")
            }
        }.font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 6).frame(height: 30)
            .background(hot ? Self.hotRow : .clear, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(hot ? Color(nsColor: .selectedMenuItemTextColor) : reference ? Color.secondary : Color.primary)
            .contentShape(Rectangle())
    }

    /// Value on top, delta vs the default precision beneath it in small type.
    @ViewBuilder private func metric(_ value: String?, _ delta: Delta?, _ width: CGFloat?, hot: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value ?? "—").lineLimit(1)
            if let delta {
                Text(delta.text).font(.system(size: 9)).lineLimit(1).fixedSize()
                    .foregroundStyle(Self.tone(delta.tone, hot: hot))
            }
        }.frame(width: width, alignment: .trailing)
    }

    /// Reload (a different precision is selected for the loaded model) is the green variant of the same button.
    @ViewBuilder private func loadButton(_ title: String, reload: Bool, action: @escaping () -> Void) -> some View {
        if reload {
            Button(title, action: action).buttonStyle(ReloadButtonStyle()).controlSize(.small)
        } else {
            Button(title, action: action).buttonStyle(.bordered).controlSize(.small)
        }
    }

    @ViewBuilder private func precisionPicker(_ model: CatalogModel, loadedBits: Int?, loading: Bool, hot: Bool) -> some View {
        if model.reference == true {
            Text("—").foregroundStyle(.secondary)
        } else {
            let options = precisionOptions(runtime: model.runtime)
            let n = native(model)
            PrecisionControl(options: options, selected: selectedBits(model), recommended: recommended(model), hot: hot, enabled: !loading,
                             help: "Weight precision; \(n) is the model's native precision. Selecting one shows its measured numbers"
                                + (loadedBits.map { "; loaded at \($0)-bit, Reload applies the selection." } ?? "."),
                             recommendedHelp: "Recommended: lowest energy within 0.5 pt of the best accuracy") { bits in
                backend.setPrecision(model.id, configBits(effective: bits, native: n))
            }.controlSize(.mini).fixedSize()
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

    private func measured(_ b: BenchmarkResult?) -> String {
        guard let b, b.source != "published" else { return "" }
        let at = [b.date, b.hardware].compactMap { $0 }.joined(separator: ", ")
        return at.isEmpty ? "" : " Measured \(at)."
    }

    private func accuracyHelp(_ model: CatalogModel, _ b: BenchmarkResult?) -> String {
        guard let b, let accuracy = b.accuracy else { return "Not measured at this precision." }
        let sets = (b.sets ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key.replacingOccurrences(of: "_", with: " ")) \(String(format: "%.1f%%", $0.value * 100))" }.joined(separator: ", ")
        var parts = [String(format: "%.1f%%", accuracy * 100) + (b.n_tasks.map { " mean over \($0) tasks" } ?? " mean") + (sets.isEmpty ? "." : ": \(sets).")]
        let split = [b.accuracy_en.map { String(format: "English %.1f%%", $0 * 100) }, b.accuracy_ml.map { String(format: "multilingual %.1f%%", $0 * 100) }].compactMap { $0 }
        if !split.isEmpty { parts.append(split.joined(separator: ", ") + ".") }
        if b.source == "published" { parts.append(b.note ?? "Published figures, not measured here.") }
        else if let n = b.n, b.n_tasks == nil { parts.append("Measured on this Mac through Verdict, \(n) items per set.") }
        let at = measured(b); if !at.isEmpty { parts.append(String(at.dropFirst())) }
        return parts.joined(separator: " ")
    }

    private func speedHelp(_ model: CatalogModel, _ b: BenchmarkResult?) -> String {
        guard let b, b.ms != nil else { return "Not measured at this precision." }
        if b.source == "published" { return "Published p50 for the hosted API, including network." }
        var text = "Median per item, one item at a time."
        if let rate = b.items_per_s { text += String(format: " Batched: %.0f items/s.", rate) }
        return text + measured(b)
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if let error = footerNotice(lastError: backend.lastError, status: status, now: Date().timeIntervalSince1970) {
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

/// The pending-Reload button: the bordered small button's shape, filled in the deltas' green family (deep enough for
/// white text on the loaded row). Drawn directly, so it stays green in an inactive window or a menu.
struct ReloadButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 7).frame(height: 16)
            .background(ModelTable.reloadGreen.opacity(configuration.isPressed ? 0.75 : enabled ? 1 : 0.5),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
