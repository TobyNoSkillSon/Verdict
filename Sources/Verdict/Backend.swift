import Foundation
import VerdictCore

/// Owns the single worker process. The worker listens on loopback only; the app
/// reads its status file and issues control requests over HTTP.
@MainActor final class Backend: ObservableObject {
    nonisolated static let support = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VERDICT_SUPPORT_DIR"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Verdict").path, isDirectory: true)
    static var configURL: URL { support.appendingPathComponent("config.json") }
    static var statusURL: URL { support.appendingPathComponent("status.json") }
    static var logURL: URL { support.appendingPathComponent("worker.log") }

    @Published var status: WorkerStatus?
    @Published private(set) var phase: WorkerPhase = .stopped
    @Published private(set) var catalog: [CatalogModel] = []
    @Published private(set) var benchmarks: [String: ModelBenchmark] = [:]
    /// config.precision mirrored so the table redraws while the menu is open.
    @Published private(set) var selectedPrecision: [String: Int] = [:]
    /// While true the status poller does not overwrite injected preview state.
    var previewing = false
    /// Render harness only: menu settings and a running worker without touching config.json or starting one.
    var previewConfiguration: Configuration?
    var previewRunning = false
    /// Keep Hot / Memory state for the menu.
    var menuConfiguration: Configuration { previewConfiguration ?? (try? configuration()) ?? Configuration(executable: "") }
    func previewPhase(_ next: WorkerPhase) { phase = next }
    @Published var busyModel: String?
    @Published var lastError: String?
    var onChange: (() -> Void)?
    private var process: Process?
    private var poller: Timer?
    private var restartAttempts = 0
    private var stopping = false
    private var memoryPressure: DispatchSourceMemoryPressure?

    init() {
        loadCatalog()
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure = pressure
        pressure.setEventHandler { [weak self] in
            // Warning: drop MLX cache. Critical: keep the first hot model, shed the rest. Never kill mid-request.
            guard let self else { return }
            let critical = self.memoryPressure?.data.contains(.critical) == true
            let line = "memory pressure \(critical ? "critical" : "warning") at \(Date())\n"
            if let h = try? FileHandle(forWritingTo: Self.logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
            Task { try? await self.control(critical ? "shed" : "trim", [:]) }
        }
        pressure.resume()
    }

    func loadCatalog() {
        let url = Bundle.main.url(forResource: "models", withExtension: "json") ?? URL(fileURLWithPath: "Resources/models.json")
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([CatalogModel].self, from: data) { catalog = list }
        let bench = ProcessInfo.processInfo.environment["VERDICT_BENCHMARKS"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "benchmarks", withExtension: "json") ?? URL(fileURLWithPath: "Resources/benchmarks.json")
        if let data = try? Data(contentsOf: bench) { benchmarks = decodeBenchmarks(data) }
        selectedPrecision = (try? configuration())?.precision ?? [:]
    }

    func configuration() throws -> Configuration {
        if FileManager.default.fileExists(atPath: Self.configURL.path) {
            return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: Self.configURL))
        }
        return Configuration(executable: bundledHelper?.path ?? "")
    }
    func save(_ config: Configuration) throws {
        try FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: Self.configURL, options: .atomic)
    }

    var processRunning: Bool { process?.isRunning == true }

    /// Prefer the bundled native helper; legacy Python installations still work until the switch.
    private var bundledHelper: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("verdict-helper")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    /// True when the bundled native helper is present (the app is built with it).
    var runtimeReady: Bool { bundledHelper != nil }

    /// Workers from earlier app instances (crash, force-quit) must not linger. Matched by the executable they run
    /// (this user's processes only), never by command-line text: a shell whose arguments mention the helper's path is
    /// left alone. Both generations: an orphaned Python worker must not race the native helper for status.json.
    private func sweepStrayWorkers() {
        for pid in WorkerProcesses.strays(excluding: process?.processIdentifier) { kill(pid, SIGTERM) }
    }
    /// Our end of the helper's stdin. Never written; when the app exits for any reason the pipe closes and the
    /// helper (VERDICT_EXIT_ON_STDIN_EOF) exits too.
    private var lifeline: Pipe?

    func start() {
        guard !processRunning else { return }
        sweepStrayWorkers()
        stopping = false
        do {
            let config = try configuration()
            guard let helper = bundledHelper else {
                throw VerdictError.message("The native helper is missing from Verdict.app. Reinstall: git pull && scripts/install.sh")
            }
            let proc = Process()
            proc.executableURL = helper
            proc.arguments = []
            var env = ProcessInfo.processInfo.environment
            env["VERDICT_SUPPORT_DIR"] = Self.support.path
            env["VERDICT_EXIT_ON_STDIN_EOF"] = "1"
            env.merge(config.helperEnvironment) { _, new in new }
            proc.environment = env
            let lifeline = Pipe()
            proc.standardInput = lifeline
            try FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: Self.logURL); log.seekToEndOfFile()
            proc.standardOutput = log; proc.standardError = log
            proc.terminationHandler = { [weak self] p in
                Task { @MainActor in self?.processEnded(status: p.terminationStatus) }
            }
            try? FileManager.default.removeItem(at: Self.statusURL)
            try proc.run()
            process = proc
            self.lifeline = lifeline
            lastError = nil
            phase = .starting
            startPolling()
        } catch {
            lastError = error.localizedDescription
            phase = .failed(error.localizedDescription)
        }
        onChange?()
    }

    func stop() {
        stopping = true
        poller?.invalidate(); poller = nil; watcher?.cancel(); watcher = nil
        if let p = process, p.isRunning {
            Task { try? await control("quit", [:]) }
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if p.isRunning { p.terminate() }
        }
        process = nil; status = nil; phase = .stopped
        onChange?()
    }

    private func processEnded(status code: Int32) {
        process = nil
        poller?.invalidate(); poller = nil; watcher?.cancel(); watcher = nil
        if stopping { phase = .stopped; onChange?(); return }
        let tail = (try? String(contentsOf: Self.logURL, encoding: .utf8))?.split(separator: "\n").suffix(3).joined(separator: " ") ?? ""
        lastError = "Worker exited (\(code)). \(tail)".trimmingCharacters(in: .whitespaces)
        phase = .failed(lastError ?? "Worker exited")
        onChange?()
        restartAttempts += 1
        if restartAttempts <= 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(restartAttempts) * 2) { [weak self] in self?.start() }
        }
    }

    private var watcher: DispatchSourceFileSystemObject?

    /// Event-driven: the worker replaces status.json atomically, which writes the support
    /// directory; watch that instead of polling. A slow timer covers the starting phase and
    /// anything the watcher misses. Idle cost: no wake-ups while nothing changes.
    private func startPolling() {
        poller?.invalidate(); watcher?.cancel()
        let fd = open(Self.support.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in self?.poll() } }
            source.setCancelHandler { close(fd) }
            source.resume(); watcher = source
        }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        timer.tolerance = 5
        poller = timer; RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    func poll() {
        guard !previewing else { return }
        guard let data = try? Data(contentsOf: Self.statusURL),
              let decoded = try? JSONDecoder().decode(WorkerStatus.self, from: data) else {
            let next = VerdictCore.phase(for: nil, processRunning: processRunning)
            if next != phase { phase = next; onChange?() }
            return
        }
        let next = VerdictCore.phase(for: decoded, processRunning: processRunning)
        if case .ready = next { restartAttempts = 0 }
        let changed = decoded != status || next != phase
        // The launch set is the manually loaded models. On-demand loads never join it; Keep Hot and memory unloads
        // never leave it (only Unload/Delete in the table do). A model being deleted is never added back meanwhile.
        var reconciled = decoded; for id in deleting { reconciled.models[id] = nil }
        if var config = try? configuration(), let hot = launchSet(config.hotModels, adding: reconciled) {
            config.hotModels = hot; try? save(config)
        }
        status = decoded; phase = next
        if changed { onChange?() }
    }

    /// Control request to the worker (load/unload/delete/quit). Throws on failure.
    func control(_ action: String, _ body: [String: String]) async throws {
        guard let port = status?.port else { throw VerdictError.message("Worker is not ready.") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(action)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 600
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw VerdictError.message(message ?? "Worker returned \(http.statusCode).")
        }
        poll()
    }

    /// A menu Load/Reload is a manual load: it joins the launch set (loads again at next launch) and follows the
    /// "Manually loaded" Keep Hot window. Loads at the selected precision, sent explicitly so the reload happens even when the model is already loaded.
    func load(_ id: String) {
        busyModel = id; lastError = nil; onChange?()
        let bits = precision(id)
        Task {
            do {
                try await control("load", ["model": id, "bits": String(bits), "manual": "true"])
                setHot(id, true)
            } catch { lastError = error.localizedDescription }
            busyModel = nil; onChange?()
        }
    }
    /// A menu Unload also removes the model from the launch set.
    func unload(_ id: String) {
        busyModel = id; lastError = nil; onChange?()
        Task {
            do { try await control("unload", ["model": id]); setHot(id, false) } catch { lastError = error.localizedDescription }
            busyModel = nil; onChange?()
        }
    }
    /// Models with a Delete in flight: status reconciliation must not put them back in the launch set.
    private var deleting: Set<String> = []
    /// A menu Delete removes the model from the launch set once the helper has deleted it; a failed delete leaves the
    /// launch set as it was.
    func delete(_ id: String) {
        busyModel = id; lastError = nil; deleting.insert(id); onChange?()
        Task {
            do { try await control("delete", ["model": id]); setHot(id, false) } catch { lastError = error.localizedDescription }
            deleting.remove(id)
            busyModel = nil; onChange?()
        }
    }
    func setHot(_ id: String, _ hot: Bool) {
        guard var config = try? configuration(), config.hotModels.contains(id) != hot else { return }
        config.hotModels.removeAll { $0 == id }
        if hot { config.hotModels.append(id) }
        try? save(config)
    }
    func isHotAtLaunch(_ id: String) -> Bool { (try? configuration())?.hotModels.contains(id) ?? false }
}

extension Backend {
    /// Keep Hot and Memory choices: saved to config.json (the next launch's environment) and sent to the running helper.
    func apply(_ action: MenuAction) {
        guard let config = try? configuration() else { return }
        let next = applying(action, to: config)
        try? save(next)
        if case .memory = action { lastError = nil }
        Task { try? await control("settings", next.helperSettings) }
        onChange?()
    }
}

extension Backend {
    /// Recommended precision (effective bits) from the measured catalog; nil for the reference/unmeasured.
    func recommendedPrecision(_ id: String) -> Int? {
        guard let model = catalog.first(where: { $0.id == id }) else { return nil }
        return recommendedBits(for: model, benchmark: benchmarks[id])
    }
    /// Config bits for the selected precision (0 = native). Without an explicit choice: the recommended precision,
    /// which the helper also loads by default (models.json default_bits). Nothing is written until the user picks.
    func precision(_ id: String) -> Int {
        if let explicit = selectedPrecision[id] { return explicit }
        let native = nativeBits(runtime: catalog.first(where: { $0.id == id })?.runtime)
        return configBits(effective: defaultBits(recommended: recommendedPrecision(id), native: native), native: native)
    }
    /// Records the selection only; the table shows its numbers and a loaded model offers Reload.
    func setPrecision(_ id: String, _ bits: Int) {
        guard precision(id) != bits else { return }
        selectedPrecision[id] = bits
        guard var config = try? configuration() else { return }
        var map = config.precision ?? [:]; map[id] = bits; config.precision = map
        try? save(config)
        onChange?()
    }
    /// Render harness only: replaces the selection without writing config.json.
    func previewSelections(_ map: [String: Int]) { selectedPrecision = map }
}
