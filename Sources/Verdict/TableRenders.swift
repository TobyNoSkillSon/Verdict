import AppKit
import SwiftUI
import VerdictCore

/// `Verdict --render-table DIR`: draws the models table in fixed states to PNGs without starting the worker
/// or touching config.json. Set VERDICT_BENCHMARKS to render against a fixture.
@MainActor final class TableRenderDelegate: NSObject, NSApplicationDelegate {
    let directory: URL
    let backend = Backend()
    init(directory: URL) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        backend.previewing = true
        var base = WorkerStatus(); base.port = 1
        base.installed = ["laya-english": InstalledModel(bytes: 842_600_000), "laya-multilingual": InstalledModel(bytes: 643_800_000),
                          "von-1.2": InstalledModel(bytes: 1_580_000_000)]
        base.gpu = GPUStatus(chip: "M5 Max", neural_accelerators: true)
        let fast = Optimizations(tokenizer: "fast", attention: "windowed", matmul: "neural accelerators", optimized: true)
        let stock = Optimizations(tokenizer: "library", attention: "stock", matmul: "neural accelerators", optimized: false)
        var laya = base; laya.models["laya-english"] = LoadedModel(device: "mlx", load_s: 0.6, bits: 0, optimizations: fast, engine: "optimized")
        var von = base; von.models["von-1.2"] = LoadedModel(device: "mlx", load_s: 1.1, bits: 16, optimizations: fast, engine: "optimized")
        var fallback = base
        fallback.models["laya-english"] = LoadedModel(device: "mlx", load_s: 0.6, bits: 0, optimizations: stock, engine: "mlx",
            engine_reason: "the optimized path failed during inference (Non-finite model outputs); switched to the stock MLX path")
        // Selections are config bits (0 = native); models without one show their recommended precision.
        let states: [(String, WorkerStatus, [String: Int])] = [
            ("nothing-loaded", base, [:]),
            ("laya-english-loaded", laya, [:]),
            ("von-16-loaded-32-selected", von, ["von-1.2": 0]),
            ("laya-english-mlx-fallback", fallback, [:]),
        ]
        // Tooltips are not visible in a PNG: write the engine tooltips next to the renders.
        let help = states.flatMap { name, status, _ in status.models.sorted { $0.key < $1.key }.map { id, m in
            "\(name) / \(id): \(engineLabel(m, chip: status.gpu?.chip))\n\(engineHelp(m, chip: status.gpu?.chip, effectiveBits: m.bits == 0 ? (id.hasPrefix("von") ? 32 : 16) : m.bits ?? 16))\n" } }
        try? help.joined(separator: "\n").write(to: directory.appendingPathComponent("engine-tooltips.txt"), atomically: true, encoding: .utf8)
        render(states, 0)
    }

    private func render(_ states: [(String, WorkerStatus, [String: Int])], _ index: Int) {
        guard index < states.count else { NSApp.terminate(nil); return }
        let (name, status, selection) = states[index]
        backend.status = status
        backend.previewSelections(selection)
        let table = MenuTableHostingView(rootView: ModelTable(backend: backend))
        table.frame = NSRect(x: 0, y: 0, width: ModelTable.width, height: ModelTable.height(rows: backend.catalog.count))
        let container = NSView(frame: table.frame.insetBy(dx: -12, dy: -10))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.14, alpha: 1).cgColor
        container.layer?.cornerRadius = 10
        table.frame.origin = NSPoint(x: 12, y: 10)
        container.addSubview(table)
        container.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .clear; window.contentView = container
        window.orderFrontRegardless(); window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            if let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
                container.cacheDisplay(in: container.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("models-\(name).png"))
            }
            window.orderOut(nil)
            render(states, index + 1)
        }
    }
}
