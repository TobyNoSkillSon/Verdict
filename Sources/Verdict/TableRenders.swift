import AppKit
import SwiftUI
import VerdictCore
import VerdictUpdate

/// `Verdict --render-table DIR`: draws the models table in fixed states to PNGs without starting the worker
/// or touching config.json. Set VERDICT_BENCHMARKS to render against a fixture, VERDICT_RENDER_CHIP (e.g. 'Apple M3 Pro')
/// to render as another Mac (default M5 Max).
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
        let chip = displayChip(ProcessInfo.processInfo.environment["VERDICT_RENDER_CHIP"]) ?? "M5 Max"
        base.gpu = GPUStatus(chip: chip, neural_accelerators: true)
        let fast = Optimizations(tokenizer: "fast", attention: "windowed", matmul: "neural accelerators", optimized: true)
        let stock = Optimizations(tokenizer: "library", attention: "stock", matmul: "neural accelerators", optimized: false)
        var laya = base; laya.models["laya-english"] = LoadedModel(device: "mlx", load_s: 0.6, bits: 0, optimizations: fast, engine: "optimized")
        var von = base; von.models["von-1.2"] = LoadedModel(device: "mlx", load_s: 1.1, bits: 16, optimizations: fast, engine: "optimized")
        var fallback = base
        fallback.models["laya-english"] = LoadedModel(device: "mlx", load_s: 0.6, bits: 0, optimizations: stock, engine: "mlx",
            engine_reason: "the optimized path failed during inference (Non-finite model outputs); switched to the stock MLX path")
        // Footer states: loading (left, replaces the hardware note) and a recent refusal (error, left).
        var loadingState = base; loadingState.loading = "von-1.2"
        var refused = base
        refused.refused = Refusal(model: "von-1.2", message: "von-1.2 at 16-bit needs ~2.0 GB; ~0.9 GB free without swapping. Unload laya-english, pick 8-bit, or allow swap in Verdict \u{2192} Memory.", at: Date().timeIntervalSince1970)
        var refusedShort = base
        refusedShort.refused = Refusal(model: "von-1.2", message: "von-1.2 at 16-bit needs ~2.0 GB; ~0.9 GB free.", at: Date().timeIntervalSince1970)
        // Selections are config bits (0 = native); models without one show their recommended precision.
        let states: [(String, WorkerStatus, [String: Int])] = [
            ("footer-loading", loadingState, [:]),
            ("footer-error-long", refused, [:]),
            ("footer-error-short", refusedShort, [:]),
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


/// `Verdict --render-menu DIR`: draws the main menu and its Keep Hot and Memory submenus (MenuMock, the dark menu
/// drawing used for documentation captures) in fixed states, without starting the worker or touching config.json.
@MainActor final class MenuRenderDelegate: NSObject, NSApplicationDelegate {
    let directory: URL
    let app = AppDelegate()
    init(directory: URL) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backend = app.backend
        backend.previewing = true; backend.previewRunning = true
        let now = Date().timeIntervalSince1970
        var status = WorkerStatus(); status.port = 1; status.items = 1204; status.last_ms = 6.6
        status.gpu = GPUStatus(chip: "M5 Max", neural_accelerators: true)
        status.models["laya-english"] = LoadedModel(device: "mlx", load_s: 0.6, bits: 0, engine: "optimized", residency: "manual", last_used: now - 40, context: 8192)
        status.models["von-1.2"] = LoadedModel(device: "mlx", load_s: 1.1, bits: 16, engine: "optimized", residency: "on_demand", last_used: now - 300, context: 8192)
        status.memory = ["mlx_active_mb": 2250, "available_mb": 86_900]
        var defaults = Configuration(executable: "/Applications/Verdict.app/Contents/MacOS/verdict-helper")
        defaults.manualIdleMinutes = nil; defaults.onDemandIdleMinutes = nil; defaults.allowSwap = nil
        // A refusal and an eviction: the Memory submenu's captions and the models table footer.
        var tight = status
        tight.models["von-1.2"] = nil
        tight.memory = ["mlx_active_mb": 1270, "available_mb": 900]
        tight.evictions = [Eviction(model: "laya-multilingual", residency: "on_demand", reason: "memory: made room for von-1.2 at 16-bit (needs ~2.0 GB; ~0.9 GB was free without swapping)", at: now - 120)]
        tight.refused = Refusal(model: "von-1.2", message: "von-1.2 at 16-bit needs ~2.0 GB; ~0.9 GB free without swapping. Unload laya-english, pick 8-bit, or allow swap in Verdict → Memory.", at: now - 5)
        var custom = defaults; custom.manualIdleMinutes = 60; custom.onDemandIdleMinutes = 5; custom.allowSwap = true
        let states: [(String, WorkerStatus, Configuration)] = [("default-", status, defaults), ("tight-", tight, defaults), ("custom-", status, custom)]
        render(states, 0)
    }

    private func render(_ states: [(String, WorkerStatus, Configuration)], _ index: Int) {
        guard index < states.count else { renderUpdate(status: states[0].1, config: states[0].2); return }
        let (prefix, status, config) = states[index]
        let backend = app.backend
        backend.status = status; backend.previewConfiguration = config
        backend.previewPhase(phase(for: status, processRunning: true))
        app.rebuildMenu()
        MenuMock.render(app.menu.items, width: 322, to: directory.appendingPathComponent("\(prefix)menu.png")) { [self] in
            MenuMock.renderSubmenus(of: app.menu, into: directory, prefix: prefix) { [self] in
                if prefix == "default-" {
                    MenuMock.renderTooltips(of: app.menu, to: directory.appendingPathComponent("tooltips.png")) { [self] in render(states, index + 1) }
                    return
                }
                guard prefix == "tight-" else { render(states, index + 1); return }
                // The models table with the refusal in its footer.
                let table = MenuTableHostingView(rootView: ModelTable(backend: backend))
                table.frame = NSRect(x: 0, y: 0, width: ModelTable.width, height: ModelTable.height(rows: backend.catalog.count))
                let container = NSView(frame: table.frame.insetBy(dx: -12, dy: -10))
                container.wantsLayer = true
                container.layer?.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.14, alpha: 1).cgColor
                container.layer?.cornerRadius = 10
                table.frame.origin = NSPoint(x: 12, y: 10)
                container.addSubview(table); container.appearance = NSAppearance(named: .darkAqua)
                let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.backgroundColor = .clear; window.contentView = container
                window.orderFrontRegardless(); window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                    if let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
                        container.cacheDisplay(in: container.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("tight-models-footer.png"))
                    }
                    window.orderOut(nil)
                    render(states, index + 1)
                }
            }
        }
    }
}

extension MenuRenderDelegate {
    /// update-menu.png (the orange item under Support), update-downloading-menu.png and update-popup.png (the
    /// confirmation), for a sample release newer than this build.
    static let sampleRelease = ReleaseInfo(tag: "v0.3.1", version: SemanticVersion("0.3.1")!, name: "Verdict 0.3.1", body: """
        Verdict updates itself: a newer release shows **Update to …** in the menu, and `verdict update` does the same from the command line.

        - Downloads are checked (SHA-256 and code signature) before anything is replaced.
        - A failed update keeps the version you had.

        ## Verify

            gh attestation verify Verdict-0.3.1-arm64.zip --repo TobyNoSkillSon/Verdict
        """)

    func renderUpdate(status: WorkerStatus, config: Configuration) {
        let backend = app.backend
        backend.status = status; backend.previewConfiguration = config
        backend.previewPhase(phase(for: status, processRunning: true))
        let release = Self.sampleRelease
        app.updates.preview(.available(release)); app.rebuildMenu()
        MenuMock.render(app.menu.items, width: 322, to: directory.appendingPathComponent("update-menu.png")) { [self] in
            app.updates.preview(.downloading(release)); app.rebuildMenu()
            MenuMock.render(app.menu.items, width: 322, to: directory.appendingPathComponent("update-downloading-menu.png")) { [self] in
                let alert = app.updates.confirmation(release)
                alert.window.appearance = NSAppearance(named: .darkAqua)
                alert.layout()
                let window = alert.window
                window.setFrameOrigin(NSPoint(x: -5000, y: -5000)); window.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                    // Layer-backed controls (the alert's text and buttons) draw only through their layers offscreen:
                    // render the layer tree over the dark alert colour.
                    if let view = window.contentView {
                        window.displayIfNeeded()
                        let scale = window.backingScaleFactor, size = view.bounds.size
                        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0)!
                        rep.size = size
                        NSGraphicsContext.saveGraphicsState()
                        let context = NSGraphicsContext(bitmapImageRep: rep)!
                        NSGraphicsContext.current = context
                        NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.18, alpha: 1).setFill()
                        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 16, yRadius: 16).fill()
                        if let layer = view.layer { layer.render(in: context.cgContext) } else { view.displayIgnoringOpacity(view.bounds, in: context) }
                        NSGraphicsContext.restoreGraphicsState()
                        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("update-popup.png"))
                    }
                    window.orderOut(nil)
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
