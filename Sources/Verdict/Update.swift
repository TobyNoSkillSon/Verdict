import AppKit
import VerdictCore
import VerdictUpdate

/// Updates from GitHub Releases. Checks at launch and every 24 hours (one request to the releases API; nothing
/// else is sent). A newer release shows an orange "Update to X…" item under "Support the developer…"; Update Now
/// downloads it, checks its SHA-256 and signature, waits while a model is loading, then hands the install to
/// `verdict update --finish` (the app has to quit for the swap) and quits. That process swaps the app with a rollback,
/// relaunches it and waits until the new version answers; a failure restores this version and the relaunched app
/// reports why (update-result.json).
@MainActor final class UpdateController: NSObject {
    private(set) var machine = UpdateMachine()
    let backend: Backend
    var onChange: (() -> Void)?
    let current = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(SemanticVersion.init)
    /// `--install-update` (end-to-end tests): install the release the launch check finds, without the popup.
    var installWithoutAsking = CommandLine.arguments.contains("--install-update")
    private var lastCheck: Date?
    private var checking = false
    private var timer: Timer?
    /// A model load can take minutes (a first load downloads the model); after this the update gives up and says so.
    private let loadWait: TimeInterval = 15 * 60

    init(backend: Backend) { self.backend = backend }

    func start() {
        if let result = UpdateResult.take(support: Backend.support), !result.ok {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                showFailure(title: "Update to \(result.to) failed", result.message.hasSuffix(".") ? result.message : result.message + ".")
            }
        }
        check()
        // Hourly wake-up, 24-hour cadence: a Mac that slept through the due time checks soon after it wakes.
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self, updateCheckDue(last: self.lastCheck) { self.check() } }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }

    func check() {
        guard !checking, !machine.phase.busy, let current else { return }
        checking = true; lastCheck = Date()
        Task {
            do {
                let release = try await UpdateClient(source: try UpdateSource.fromEnvironment()).check(current: current)
                machine.handle(.checked(release))
            } catch {
                machine.handle(.checkFailed((error as? UpdateError)?.message ?? error.localizedDescription))
                lastCheck = Date().addingTimeInterval(-23 * 3600)      // offline at launch, say: try again in about an hour
            }
            checking = false
            onChange?()
            if installWithoutAsking, case .available = machine.phase { installWithoutAsking = false; install() }
        }
    }

    /// Render harness only.
    func preview(_ phase: UpdatePhase) { machine = UpdateMachine(phase: phase) }

    // MARK: Menu

    /// The orange item under "Support the developer…"; nil when this version is current.
    func menuItem() -> NSMenuItem? {
        guard let title = machine.phase.menuTitle else { return nil }
        let item = NSMenuItem(title: title, action: #selector(confirm), keyEquivalent: "")
        item.target = self
        item.isEnabled = !machine.phase.busy
        item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemOrange])
        item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        item.toolTip = machine.lastError.map { "Last attempt failed: \($0)" }
        return item
    }

    @objc func confirm() {
        guard case .available(let release) = machine.phase else { return }
        NSApp.activate(ignoringOtherApps: true)
        if confirmation(release).runModal() == .alertFirstButtonReturn { install() }
    }

    /// The popup: version, short release notes, Update Now / Later.
    func confirmation(_ release: ReleaseInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Update to Verdict \(release.version)?"
        let notes = release.shortNotes()
        alert.informativeText = "You have \(current?.description ?? "an earlier version"). Settings and models are kept; Verdict restarts."
            + (notes.isEmpty ? "" : "\n\n" + notes)
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        return alert
    }

    // MARK: Install

    private var modelBusy: Bool {
        backend.busyModel != nil || backend.status?.loading != nil || backend.status?.downloading == true
    }

    func install() {
        guard let current, machine.handle(.confirmed), let release = machine.phase.release else { return }
        onChange?()
        Task {
            var staged: StagedUpdate?
            do {
                let client = UpdateClient(source: try UpdateSource.fromEnvironment())
                staged = try await Updater.prepare(release, client: client)
                machine.handle(.verified(modelLoading: modelBusy)); onChange?()
                if case .waitingForLoad = machine.phase {
                    let deadline = Date().addingTimeInterval(loadWait)
                    while modelBusy && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000_000) }
                    guard !modelBusy else { throw UpdateError("A model is still loading, so the update was not installed. Try again once it has loaded") }
                    machine.handle(.loadFinished); onChange?()
                }
                try handOff(staged!, from: current)
                NSApp.terminate(nil)
            } catch {
                if let staged { try? FileManager.default.removeItem(atPath: staged.directory) }
                let reason = (error as? UpdateError)?.message ?? error.localizedDescription
                machine.handle(.failed(reason)); onChange?()
                showFailure(title: "Update to \(release.version) failed", reason + ". Verdict \(current) is unchanged.")
            }
        }
    }

    /// Starts the detached installer (this app's own `verdict` command) that waits for this process to exit.
    private func handOff(_ staged: StagedUpdate, from current: SemanticVersion) throws {
        let app = Bundle.main.bundleURL
        let cli = app.appendingPathComponent("Contents/Helpers/verdict")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw UpdateError("The verdict command is missing from Verdict.app; reinstall with scripts/install.sh") }
        let plan = InstallPlan(staged: staged, destination: app.path, from: current.description, waitForPID: getpid(),
                               supportDirectory: Backend.support.path, writeResult: true)
        let planURL = URL(fileURLWithPath: staged.directory).appendingPathComponent("plan.json")
        try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
        let process = Process()
        process.executableURL = cli
        process.arguments = ["update", "--finish", planURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateError("Could not start the installer: \(error.localizedDescription)") }
    }

    private func showFailure(title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
