import Foundation
import VerdictCore

/// Installs a StagedUpdate over an installed Verdict.app the way scripts/install-release.sh does: quit the app (never
/// while it loads a model), copy the new app next to the old one, swap them (the old one kept as a rollback), relaunch,
/// wait until the new version answers, then delete the old one. When the new app does not become ready, it is
/// removed and the old one is put back and relaunched. Settings and models (Application Support, the model cache) are
/// never touched.
///
/// The app hands off to this code in a separate process (`verdict update --finish PLAN`) because it has to quit
/// for the swap; `verdict update` runs it directly.
public struct InstallPlan: Codable, Equatable, Sendable {
    public var staged: StagedUpdate
    /// The installed Verdict.app to replace.
    public var destination: String
    /// The version being replaced (for messages and the rollback check).
    public var from: String
    /// Wait for this process (the app that handed off) to exit instead of quitting the app.
    public var waitForPID: Int32?
    /// Application Support/Verdict (VERDICT_SUPPORT_DIR): status.json, config.json, update-result.json.
    public var supportDirectory: String
    /// Write update-result.json for the relaunched app to report (the app's hand-off; the CLI prints instead).
    public var writeResult: Bool

    public init(staged: StagedUpdate, destination: String, from: String, waitForPID: Int32? = nil, supportDirectory: String, writeResult: Bool) {
        self.staged = staged; self.destination = destination; self.from = from
        self.waitForPID = waitForPID; self.supportDirectory = supportDirectory; self.writeResult = writeResult
    }
}

/// A failed update, for the relaunched app to report (it reads and deletes update-result.json at launch). Written
/// before the app is relaunched; a successful update leaves none.
public struct UpdateResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var from: String
    public var to: String
    public var message: String
    public var at: Double
    public init(ok: Bool, from: String, to: String, message: String, at: Double = Date().timeIntervalSince1970) {
        self.ok = ok; self.from = from; self.to = to; self.message = message; self.at = at
    }
    public static func url(support: URL) -> URL { support.appendingPathComponent("update-result.json") }
    /// Reads and removes the result, if there is one.
    public static func take(support: URL) -> UpdateResult? {
        let url = url(support: support)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return try? JSONDecoder().decode(UpdateResult.self, from: data)
    }
}

public struct Installer {
    public let plan: InstallPlan
    public var log: (String) -> Void
    /// How long the relaunched app has to answer with the new version (VERDICT_UPDATE_READY_SECONDS, default 120).
    public var startTimeout: TimeInterval
    /// How long launch-set models may take to load after that (as the installers: 30 minutes).
    public var loadTimeout: TimeInterval = 30 * 60

    public init(plan: InstallPlan, log: @escaping (String) -> Void = { _ in }, env: [String: String] = ProcessInfo.processInfo.environment) {
        self.plan = plan; self.log = log
        startTimeout = env["VERDICT_UPDATE_READY_SECONDS"].flatMap(TimeInterval.init) ?? 120
    }

    var destination: URL { URL(fileURLWithPath: plan.destination, isDirectory: true) }
    var support: URL { URL(fileURLWithPath: plan.supportDirectory, isDirectory: true) }
    var fm: FileManager { .default }

    /// Installs, relaunches and checks readiness; rolls back on failure. Throws the reason. On failure the old app
    /// is installed, and running again if it was running (always after the app's own hand-off: it quit for this).
    public func run() async throws {
        try? fm.removeItem(at: UpdateResult.url(support: support))
        let progress = Progress()
        do {
            try await install(progress)
        } catch {
            let message = (error as? UpdateError)?.message ?? error.localizedDescription
            if plan.writeResult && !progress.reported { write(UpdateResult(ok: false, from: plan.from, to: plan.staged.version, message: message)) }
            if progress.stopped && !progress.restarted && Self.appProcesses(at: destination).isEmpty { launch() }
            try? fm.removeItem(atPath: plan.staged.directory)
            throw error
        }
        try? fm.removeItem(atPath: plan.staged.directory)
    }

    /// What has happened so far, for the failure path.
    final class Progress {
        var stopped = false         // the app at the destination was quit (or quit itself to hand off)
        var restarted = false       // the rollback already relaunched (or gave up on) the old app
        var reported = false        // update-result.json is written
    }

    private func install(_ progress: Progress) async throws {
        let parent = destination.deletingLastPathComponent()
        guard fm.fileExists(atPath: destination.appendingPathComponent("Contents/Info.plist").path) else {
            throw UpdateError("\(plan.destination) is not an installed Verdict.app")
        }
        progress.stopped = plan.waitForPID != nil
        guard fm.isWritableFile(atPath: parent.path) else { throw UpdateError("\(parent.path) is not writable; installation left unchanged") }
        if try await quitRunningApp() { progress.stopped = true }

        let staged = parent.appendingPathComponent(".Verdict.app.install.\(getpid())")
        guard !fm.fileExists(atPath: staged.path) else { throw UpdateError("Staging path exists: \(staged.path)") }
        guard Updater.run("/usr/bin/ditto", [plan.staged.app, staged.path]).status == 0 else {
            try? fm.removeItem(at: staged); throw UpdateError("Could not copy the new app to \(parent.path)")
        }
        do { try Updater.verifySignature(staged); try Updater.removeQuarantine(staged) }
        catch { try? fm.removeItem(at: staged); throw error }

        let stamp = Self.stamp()
        let previous = parent.appendingPathComponent(".Verdict.app.previous.\(stamp).\(getpid())")
        do { try fm.moveItem(at: destination, to: previous) }
        catch { try? fm.removeItem(at: staged); throw UpdateError("Could not move the installed app aside; installation left unchanged") }
        do { try fm.moveItem(at: staged, to: destination) }
        catch {
            try? fm.moveItem(at: previous, to: destination); try? fm.removeItem(at: staged)
            throw UpdateError("Install failed; previous app restored")
        }
        log("installed \(plan.destination) (\(plan.staged.version))")
        refreshClientLibrary()

        launch()
        log("starting…")
        if let reason = await waitUntilReady(version: plan.staged.version) {
            log("the new version did not start: \(reason); restoring \(plan.from)")
            await terminateApps(timeout: 15)
            let failed = parent.appendingPathComponent(".Verdict.app.failed.\(stamp).\(getpid())")
            var restored = false
            if (try? fm.moveItem(at: destination, to: failed)) != nil, (try? fm.moveItem(at: previous, to: destination)) != nil {
                restored = true; try? fm.removeItem(at: failed)
            }
            progress.restarted = true
            guard restored else { throw UpdateError("Verdict \(plan.staged.version) did not start (\(reason)) and restoring \(plan.from) failed; the previous app is at \(previous.path)") }
            refreshClientLibrary()
            let failure = UpdateError("Verdict \(plan.staged.version) did not start (\(reason)); Verdict \(plan.from) was restored")
            // The restored app reports this at launch, so it is written first.
            if plan.writeResult { write(UpdateResult(ok: false, from: plan.from, to: plan.staged.version, message: failure.message)); progress.reported = true }
            launch()
            if let back = await waitUntilReady(version: plan.from) {
                throw UpdateError(failure.message + " but did not start either: \(back)")
            }
            throw failure
        }
        try? fm.removeItem(at: previous)
    }

    // MARK: Quitting

    /// The running app at the destination quits: the app that handed off exits by itself; otherwise it is asked to
    /// quit (SIGTERM, which Verdict answers like Quit), but never while it is loading a model. True when an app was quit.
    private func quitRunningApp() async throws -> Bool {
        var quit = false
        if let pid = plan.waitForPID {
            guard await Self.wait(timeout: 120, until: { kill(pid, 0) != 0 }) else { throw UpdateError("Verdict did not quit; installation left unchanged") }
        } else {
            let running = Self.appProcesses(at: destination)
            if !running.isEmpty {
                if let loading = Self.loadingModel(support: support) {
                    throw UpdateError("Verdict is loading \(loading). Try again in a moment; installation left unchanged")
                }
                for pid in running { kill(pid, SIGTERM) }
                guard await Self.wait(timeout: 20, until: { Self.appProcesses(at: destination).isEmpty }) else {
                    throw UpdateError("Verdict did not quit; installation left unchanged")
                }
                quit = true
            }
        }
        // Its worker follows (it exits when the app's end of its stdin closes).
        if !(await Self.wait(timeout: 10, until: { Self.helperProcesses(at: destination).isEmpty })) {
            for pid in Self.helperProcesses(at: destination) { kill(pid, SIGTERM) }
            _ = await Self.wait(timeout: 5, until: { Self.helperProcesses(at: destination).isEmpty })
        }
        return quit
    }

    private func terminateApps(timeout: TimeInterval) async {
        for pid in Self.appProcesses(at: destination) { kill(pid, SIGTERM) }
        if !(await Self.wait(timeout: timeout, until: { Self.appProcesses(at: destination).isEmpty })) {
            for pid in Self.appProcesses(at: destination) { kill(pid, SIGKILL) }
        }
        if !(await Self.wait(timeout: 10, until: { Self.helperProcesses(at: destination).isEmpty })) {
            for pid in Self.helperProcesses(at: destination) { kill(pid, SIGKILL) }
        }
    }

    /// The model the helper reports loading (status.json), if any.
    public static func loadingModel(support: URL) -> String? {
        guard let data = try? Data(contentsOf: support.appendingPathComponent("status.json")),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let loading = object["loading"] as? String, !loading.isEmpty else { return nil }
        return loading
    }

    /// Processes running this bundle's app or helper executable (matched by the file they run, not by name: another
    /// Verdict.app elsewhere is left alone).
    public static func appProcesses(at app: URL) -> [pid_t] { processes(running: app.appendingPathComponent("Contents/MacOS/Verdict")) }
    public static func helperProcesses(at app: URL) -> [pid_t] { processes(running: app.appendingPathComponent("Contents/MacOS/verdict-helper")) }
    static func processes(running executable: URL) -> [pid_t] {
        let target = realPath(executable.path)
        return WorkerProcesses.userProcesses().filter { $0 != getpid() && WorkerProcesses.executablePath($0).map(realPath) == target }
    }
    static func realPath(_ path: String) -> String {
        // The parent is resolved when the file itself is gone (a process whose bundle was moved).
        if let resolved = realpath(path, nil) { defer { free(resolved) }; return String(cString: resolved) }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, !parent.isEmpty else { return path }
        return (realPath(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    // MARK: Launch and readiness

    /// `open -n -g`: a new instance even when another copy of Verdict runs, in the background. VERDICT_* variables are
    /// passed on (open does not forward the environment), so an isolated test instance stays isolated.
    private func launch() {
        var arguments = ["-n", "-g"]
        for (key, value) in ProcessInfo.processInfo.environment.sorted(by: { $0.key < $1.key }) where key.hasPrefix("VERDICT_") {
            arguments += ["--env", "\(key)=\(value)"]
        }
        arguments.append(plan.destination)
        let result = Updater.run("/usr/bin/open", arguments)
        if result.status != 0 { log("open failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    /// nil when `version`'s helper answers and is not loading, with a model loaded or none in the launch set (the
    /// installers' readiness rule); otherwise the reason it is not ready.
    func waitUntilReady(version: String) async -> String? {
        let start = Date()
        var answeredAt: Date?
        var last = "no answer"
        while true {
            let elapsed = Date().timeIntervalSince(start)
            if answeredAt == nil && elapsed > startTimeout { return "no answer from version \(version) after \(Int(startTimeout)) s (\(last))" }
            if let answeredAt, Date().timeIntervalSince(answeredAt) > loadTimeout { return "still loading after \(Int(loadTimeout / 60)) min" }
            if elapsed > 10 && Self.appProcesses(at: destination).isEmpty { return "the app exited" }
            switch await Self.readiness(support: support, version: version) {
            case .ready: return nil
            case .answering(let why): if answeredAt == nil { answeredAt = Date() }; last = why
            case .notAnswering(let why): last = why
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    enum Readiness: Equatable { case ready, answering(String), notAnswering(String) }

    static func readiness(support: URL, version: String) async -> Readiness {
        guard let data = try? Data(contentsOf: support.appendingPathComponent("status.json")),
              let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let port = (file["port"] as? NSNumber)?.intValue, port > 0 else { return .notAnswering("no status.json") }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let (body, _) = try? await session.data(from: URL(string: "http://127.0.0.1:\(port)/status")!),
              let status = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return .notAnswering("helper not answering") }
        guard status["version"] as? String == version else { return .notAnswering("helper reports version \(status["version"] as? String ?? "?")") }
        if let loading = status["loading"] as? String, !loading.isEmpty { return .answering("loading \(loading)") }
        let models = status["models"] as? [String: Any] ?? [:]
        let hot: [String]
        if let data = try? Data(contentsOf: support.appendingPathComponent("config.json")) {
            hot = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["hotModels"] as? [String] ?? []
        } else { hot = [] }
        return models.isEmpty && !hot.isEmpty ? .answering("launch-set models not loaded yet") : .ready
    }

    // MARK: Helpers

    /// The Python library in ~/.local/share/verdict follows the app it was installed from (install.sh records it).
    private func refreshClientLibrary() {
        let share = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/verdict")
        guard let recorded = try? String(contentsOf: share.appendingPathComponent("app-path"), encoding: .utf8),
              Self.realPath(recorded.trimmingCharacters(in: .whitespacesAndNewlines)) == Self.realPath(plan.destination) else { return }
        let source = destination.appendingPathComponent("Contents/Resources/verdict.py")
        let target = share.appendingPathComponent("verdict.py")
        guard let data = try? Data(contentsOf: source) else { return }
        try? data.write(to: target, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
    }

    private func write(_ result: UpdateResult) {
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(result) { try? data.write(to: UpdateResult.url(support: support), options: .atomic) }
    }

    static func stamp() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: Date())
    }

    static func wait(timeout: TimeInterval, until done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return done()
    }
}
