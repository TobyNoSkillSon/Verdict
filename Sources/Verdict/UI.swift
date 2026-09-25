import AppKit
import ServiceManagement
import VerdictCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let backend = Backend()
    private lazy var models = ModelsMenu(backend: backend)
    var status: NSStatusItem!
    let menu = NSMenu()
    private var tracking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = ScalesIcon.menuBarImage()
        menu.delegate = self; menu.autoenablesItems = false
        status.menu = menu
        backend.onChange = { [weak self] in self?.refresh() }
        rebuildMenu()
        backend.start()
        if let index = CommandLine.arguments.firstIndex(of: "--screenshot"), CommandLine.arguments.count > index + 1 {
            // Visual QA: wait for the worker, open the menu, capture, render the table, quit.
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [self] in
                Screenshots.capture(delegate: self, into: directory)
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { backend.stop() }

    func menuWillOpen(_ menu: NSMenu) { if menu === self.menu { tracking = true } }
    func menuDidClose(_ menu: NSMenu) { if menu === self.menu { tracking = false } }
    func menuNeedsUpdate(_ menu: NSMenu) { guard menu === self.menu, !tracking else { return }; rebuildMenu() }
    private func refresh() {
        if !tracking { rebuildMenu() }
        status.button?.appearsDisabled = false
        if case .failed = backend.phase { status.button?.contentTintColor = .systemOrange }
        else if case .loading = backend.phase { status.button?.contentTintColor = .secondaryLabelColor }
        else if case .downloading = backend.phase { status.button?.contentTintColor = .secondaryLabelColor }
        else { status.button?.contentTintColor = nil }
    }

    func rebuildMenu() {
        menu.removeAllItems()
        let summary = summaryLine(backend.phase, status: backend.status)
        let failed: Bool = { if case .failed = backend.phase { return true }; return false }()
        let header = NSMenuItem(title: summary, action: failed ? #selector(showError) : nil, keyEquivalent: "")
        header.target = self; header.isEnabled = failed
        header.toolTip = backend.lastError ?? backend.status?.error
        let color: NSColor = failed ? .systemOrange : { if case .ready = backend.phase { return .systemGreen }; return .secondaryLabelColor }()
        header.attributedTitle = NSAttributedString(string: summary, attributes: [.foregroundColor: color])
        menu.addItem(header)
        if let latency = latencyLine(backend.status) {
            let line = NSMenuItem(title: latency, action: nil, keyEquivalent: ""); line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())
        menu.addItem(models.modelItem())
        let config = backend.menuConfiguration
        menu.addItem(submenu("Keep Hot", "flame", keepHotMenu(config)))
        menu.addItem(submenu("Memory", "memorychip", memoryMenu(config, status: backend.status)))
        menu.addItem(.separator())
        item("Copy Skill for Your Agent", "doc.on.doc", #selector(copyInstructions))
        item("Open Verdict Files", "folder", #selector(files))
        if backend.processRunning || backend.previewRunning { item("Restart Worker", "arrow.clockwise", #selector(restart)) }
        else { item("Start Worker", "play", #selector(start)) }
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        item("Support the developer…", "heart", #selector(support))
        item("Quit Verdict", "power", #selector(quit), key: "q", modifiers: [.command])
    }
    /// Keep Hot / Memory submenu from VerdictCore's entries (section headers, checkmarked choices, short captions).
    private func submenu(_ title: String, _ icon: String, _ entries: [MenuEntry]) -> NSMenuItem {
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        let sub = NSMenu(); sub.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .header(let text): sub.addItem(.sectionHeader(title: text))
            case .separator: sub.addItem(.separator())
            case .caption(let text):
                let line = NSMenuItem(title: text, action: nil, keyEquivalent: ""); line.isEnabled = false
                sub.addItem(line)
            case .choice(let text, let checked, let action):
                let choice = NSMenuItem(title: text, action: #selector(choose(_:)), keyEquivalent: "")
                choice.target = self; choice.state = checked ? .on : .off
                choice.representedObject = MenuActionBox(action)
                sub.addItem(choice)
            }
        }
        root.submenu = sub
        return root
    }
    private func item(_ title: String, _ icon: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = []) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self; entry.keyEquivalentModifierMask = modifiers
        entry.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        menu.addItem(entry)
    }
    @objc private func showError() {
        let alert = NSAlert(); alert.messageText = "Verdict worker failed"
        alert.informativeText = backend.lastError ?? backend.status?.error ?? "See worker.log in Verdict Files."
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Open Log")
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(Backend.logURL) }
    }
    @objc private func copyInstructions() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(skillText(), forType: .string)
    }
    @objc private func files() {
        try? FileManager.default.createDirectory(at: Backend.support, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Backend.support)
    }
    @objc private func restart() { backend.stop(); backend.start() }
    @objc private func start() { backend.start() }
    @objc private func choose(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MenuActionBox else { return }
        backend.apply(box.action)
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { NSAlert(error: error).runModal() }
        rebuildMenu()
    }
    @objc private func support() { NSWorkspace.shared.open(URL(string: "https://github.com/sponsors/TobyNoSkillSon")!) }
    @objc private func quit() { NSApp.terminate(nil) }
}


@MainActor enum Screenshots {
    /// Renders the models table in representative states; the live menu is captured separately.
    static func capture(delegate: AppDelegate, into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backend = delegate.backend
        var states: [(String, WorkerStatus?, String?, String?)] = []
        var s = WorkerStatus(); s.port = 1
        states.append(("fresh", s, nil, nil))
        s.installed["laya-english"] = InstalledModel(bytes: 842_600_000)
        s.loading = "laya-english"
        states.append(("loading", s, nil, nil))
        s.loading = nil
        s.models["laya-english"] = LoadedModel(device: "mlx", load_s: 4.2)
        s.installed["laya-multilingual"] = InstalledModel(bytes: 643_800_000)
        s.items = 1204; s.last_ms = 6.6
        states.append(("hot", s, nil, nil))
        s.models["laya-multilingual"] = LoadedModel(device: "mlx", load_s: 3.1)
        states.append(("two-hot", s, nil, nil))
        states.append(("error", s, "Could not download aac6fef/laya-typed-decisions-mlx: network unreachable", nil))
        states.append(("busy", s, nil, "laya-typed-decisions"))
        let realStatus = backend.status, realError = backend.lastError, realBusy = backend.busyModel
        backend.previewing = true
        func render(_ index: Int) {
            guard index < states.count else {
                backend.status = realStatus; backend.lastError = realError; backend.busyModel = realBusy
                backend.previewing = false
                let frame = delegate.status.button?.window?.frame ?? .zero
                let info = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
                if let data = try? JSONSerialization.data(withJSONObject: info) {
                    try? data.write(to: directory.appendingPathComponent("status-item.json"))
                }
                // Main menu, drawn as a faithful mock of the NSMenu (a real NSMenu cannot be rendered offscreen).
                delegate.rebuildMenu()
                let width: CGFloat = 322
                let view = MenuMock(items: delegate.menu.items, width: width)
                let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.backgroundColor = .clear; window.contentView = view
                window.appearance = NSAppearance(named: .darkAqua)
                window.orderFrontRegardless(); window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("menu.png"))
                    }
                    window.orderOut(nil)
                    MenuMock.renderSubmenus(of: delegate.menu, into: directory) { NSApp.terminate(nil) }
                }
                return
            }
            let (name, status, error, busy) = states[index]
            backend.status = status; backend.lastError = error; backend.busyModel = busy
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
                    container.cacheDisplay(in: container.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("models-\(name).png"))
                }
                window.orderOut(nil)
                render(index + 1)
            }
        }
        render(0)
    }
}


/// Draws NSMenuItems the way macOS does in dark mode, for documentation captures only.
final class MenuMock: NSView {
    let items: [NSMenuItem]
    init(items: [NSMenuItem], width: CGFloat) {
        self.items = items
        let height = items.reduce(CGFloat(12)) { $0 + ($1.isSeparatorItem ? 11 : $1.isSectionHeader ? 22 : 26) }
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }
    required init?(coder: NSCoder) { nil }
    /// Draws `items` offscreen to `url` (PNG), then calls `done`.
    static func render(_ items: [NSMenuItem], width: CGFloat, to url: URL, done: @escaping () -> Void) {
        let view = MenuMock(items: items, width: width)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .clear; window.contentView = view; window.appearance = NSAppearance(named: .darkAqua)
        window.orderFrontRegardless(); window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            window.orderOut(nil); done()
        }
    }
    /// keep-hot.png and memory.png from the main menu's submenus.
    static func renderSubmenus(of menu: NSMenu, into directory: URL, prefix: String = "", done: @escaping () -> Void) {
        let subs = [("Keep Hot", "keep-hot"), ("Memory", "memory")].compactMap { title, name in
            menu.items.first(where: { $0.title == title })?.submenu.map { ($0.items, name) }
        }
        func next(_ index: Int) {
            guard index < subs.count else { done(); return }
            render(subs[index].0, width: 300, to: directory.appendingPathComponent("\(prefix)\(subs[index].1).png")) { next(index + 1) }
        }
        next(0)
    }
    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.15, alpha: 1).setFill(); panel.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke(); panel.lineWidth = 1; panel.stroke()
        var y = bounds.height - 6
        let attrs: (NSColor, CGFloat) -> [NSAttributedString.Key: Any] = { c, size in [.font: NSFont.systemFont(ofSize: size), .foregroundColor: c] }
        for item in items {
            if item.isSectionHeader {
                y -= 22
                NSAttributedString(string: item.title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.5)]).draw(at: NSPoint(x: 14, y: y + 4))
                continue
            }
            if item.isSeparatorItem {
                y -= 5.5
                NSColor.white.withAlphaComponent(0.14).setFill(); NSBezierPath(rect: NSRect(x: 14, y: y, width: bounds.width - 28, height: 1)).fill()
                y -= 5.5; continue
            }
            y -= 26
            let color: NSColor = item.isEnabled ? .white : NSColor.white.withAlphaComponent(0.4)
            let title = item.attributedTitle.map { NSAttributedString(string: $0.string, attributes: attrs(($0.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) ?? color, 13)) }
                ?? NSAttributedString(string: item.title, attributes: attrs(color, 13))
            var x: CGFloat = 14
            if let image = item.image {
                let tinted = image.copy() as! NSImage; tinted.isTemplate = false
                let r = NSRect(x: x, y: y + 6, width: 14, height: 14)
                NSGraphicsContext.saveGraphicsState()
                color.set(); tinted.lockFocus(); color.set(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
                tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                x += 22
            } else if items.contains(where: { $0.image != nil }) { x += 22 }
            title.draw(at: NSPoint(x: x, y: y + 5))
            if item.state == .on { NSAttributedString(string: "✓", attributes: attrs(color, 13)).draw(at: NSPoint(x: bounds.width - 30, y: y + 5)) }
            if item.submenu != nil { NSAttributedString(string: "›", attributes: attrs(color, 15)).draw(at: NSPoint(x: bounds.width - 22, y: y + 4)) }
            if !item.keyEquivalent.isEmpty { NSAttributedString(string: "⌘" + item.keyEquivalent.uppercased(), attributes: attrs(NSColor.white.withAlphaComponent(0.5), 13)).draw(at: NSPoint(x: bounds.width - 44, y: y + 5)) }
        }
    }
}


/// Carries a VerdictCore menu action through NSMenuItem.representedObject.
final class MenuActionBox: NSObject {
    let action: MenuAction
    init(_ action: MenuAction) { self.action = action }
}

func skillText() -> String {
    guard let url = Bundle.main.url(forResource: "SKILL", withExtension: "md"), let text = try? String(contentsOf: url, encoding: .utf8) else {
        return "Verdict skill file is missing from the app bundle; run `verdict skill` or see the repository's Resources/SKILL.md."
    }
    return text
}
