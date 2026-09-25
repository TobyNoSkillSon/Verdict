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
    @Published var busyModel: String?
    @Published var lastError: String?
    var onChange: (() -> Void)?
    private var process: Process?
    private var poller: Timer?
    private var lastHotSet: [String]?
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

    /// Workers from earlier app instances (crash, force-quit) must not linger.
    private func sweepStrayWorkers() {
        let mine = process?.processIdentifier
        // Sweep both generations: an orphaned Python worker must not race the native helper
        // for status.json after an update.
        for pattern in ["Verdict.app/Contents/MacOS/verdict-helper", "Verdict.app/Contents/Resources/worker.py"] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", pattern]
            let pipe = Pipe(); p.standardOutput = pipe
            try? p.run(); p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for line in out.split(separator: "\n") {
                if let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid != mine { kill(pid, SIGTERM) }
            }
        }
    }

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
            env["VERDICT_PRELOAD"] = config.hotModels.joined(separator: ",")
            env["VERDICT_IDLE_MINUTES"] = String(config.idleMinutes ?? 0)
            if let data = try? JSONSerialization.data(withJSONObject: config.precision ?? [:]) { env["VERDICT_PRECISION"] = String(data: data, encoding: .utf8) }
            proc.environment = env
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
        // The hot set is the launch set. Idle/pressure unloads are transient and do not count.
        if case .ready = next, decoded.loading == nil, decoded.idle_unloaded != true, !decoded.models.isEmpty || status?.models.isEmpty == false,
           Set(lastHotSet ?? []) != Set(decoded.models.keys), var config = try? configuration(), Set(config.hotModels) != Set(decoded.models.keys) {
            config.hotModels = decoded.models.keys.sorted(); try? save(config)
        }
        if case .ready = next, decoded.loading == nil, decoded.idle_unloaded != true {
            lastHotSet = decoded.models.keys.sorted()
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

    /// The set of hot models is the launch set: what you leave loaded comes back next time.
    /// Loads at the selected precision (the helper's own map may predate the selection).
    func load(_ id: String) {
        busyModel = id; lastError = nil; onChange?()
        let bits = precision(id)
        Task {
            do { try await control("load", ["model": id, "bits": String(bits)]) } catch { lastError = error.localizedDescription }
            busyModel = nil; onChange?()
        }
    }
    func unload(_ id: String) {
        busyModel = id; onChange?()
        Task {
            do { try await control("unload", ["model": id]) } catch { lastError = error.localizedDescription }
            busyModel = nil; onChange?()
        }
    }
    func delete(_ id: String) {
        busyModel = id; onChange?()
        Task {
            do { try await control("delete", ["model": id]) } catch { lastError = error.localizedDescription }
            busyModel = nil; onChange?()
        }
    }
    func setHot(_ id: String, _ hot: Bool) {
        guard var config = try? configuration() else { return }
        config.hotModels.removeAll { $0 == id }
        if hot { config.hotModels.append(id) }
        try? save(config)
    }
    func isHotAtLaunch(_ id: String) -> Bool { (try? configuration())?.hotModels.contains(id) ?? false }
}

extension Backend {
    var idleMinutes: Int { (try? configuration())?.idleMinutes ?? 0 }
    func setIdleMinutes(_ minutes: Int) {
        guard var config = try? configuration() else { return }
        config.idleMinutes = minutes
        try? save(config)
        Task { try? await control("settings", ["idle_minutes": String(minutes)]) }
        onChange?()
    }
}

extension Backend {
    /// Config bits for the selected precision (0 = native).
    func precision(_ id: String) -> Int { selectedPrecision[id] ?? 0 }
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
