import Foundation

/// Client for the Verdict app's local HTTP API (docs/API.md).
///
///     let verdict = try await Verdict()          // finds the running app, or launches it and waits
///     let results = try await verdict.judge(tickets, [
///         "refund": .noul("Does the customer ask for money back?"),
///         "dept": .choice("Which team should handle this?", ["billing": "charges, refunds", "tech": "bugs", "other": "none of these"]),
///     ])
///     for r in results where (r["refund"]?.noul ?? 0) > 0.7 { … }
///
/// The port is read from status.json before every request, so a restarted helper (new port) is found again.
public struct Verdict: Sendable {
    /// `~/Library/Application Support/Verdict` (VERDICT_SUPPORT_DIR overrides): status.json, config.json, worker.log.
    public let supportDirectory: URL
    /// Launch the app when it is not running.
    public let launch: Bool
    /// How long to wait for a launched app to answer.
    public let timeout: TimeInterval
    /// The app to launch; nil searches the usual places (see `appCandidates`).
    public let app: URL?
    private let session: URLSession

    public static var defaultSupportDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["VERDICT_SUPPORT_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Verdict", isDirectory: true)
    }

    /// Finds the running app, or launches it (unless `launch` is false) and waits until it answers.
    public init(launch: Bool = true, timeout: TimeInterval = 90, app: URL? = nil, supportDirectory: URL? = nil) async throws {
        self.init(unchecked: launch, timeout: timeout, app: app, supportDirectory: supportDirectory)
        _ = try await ensureRunning()
    }

    /// No discovery until the first request (which launches the app if needed).
    public init(unchecked launch: Bool, timeout: TimeInterval = 90, app: URL? = nil, supportDirectory: URL? = nil) {
        self.launch = launch; self.timeout = timeout; self.app = app
        self.supportDirectory = supportDirectory ?? Self.defaultSupportDirectory
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]          // loopback never goes through a proxy
        config.timeoutIntervalForRequest = 600          // a first load downloads its model
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config)
    }

    // MARK: Discovery

    /// The helper's port from status.json when its process is alive; nil otherwise.
    public func runningPort() -> Int? {
        guard let data = try? Data(contentsOf: supportDirectory.appendingPathComponent("status.json")),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let port = (object["port"] as? NSNumber)?.intValue, port > 0,
              let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0, kill(pid, 0) == 0 else { return nil }
        return port
    }

    /// Where the app is looked for, in order: `app`, VERDICT_APP, the bundle this program ships in, the path
    /// install.sh recorded (~/.local/share/verdict/app-path), /Applications, ~/Applications.
    public var appCandidates: [URL] {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out: [URL] = []
        if let app { out.append(app) }
        if let path = env["VERDICT_APP"], !path.isEmpty { out.append(URL(fileURLWithPath: path)) }
        if let bundle = Self.containingApp { out.append(bundle) }
        if let recorded = try? String(contentsOf: home.appendingPathComponent(".local/share/verdict/app-path"), encoding: .utf8) {
            let path = recorded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { out.append(URL(fileURLWithPath: path)) }
        }
        out.append(URL(fileURLWithPath: "/Applications/Verdict.app"))
        out.append(home.appendingPathComponent("Applications/Verdict.app"))
        return out
    }

    /// Verdict.app when this executable ships inside it (the `verdict` CLI is Verdict.app/Contents/Helpers/verdict).
    public static var containingApp: URL? {
        var url = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "/")).resolvingSymlinksInPath()
        while url.path != "/" && !url.path.isEmpty {
            if url.pathExtension == "app" {
                let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                return info?["CFBundleIdentifier"] as? String == bundleIdentifier ? url : nil
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
    static let bundleIdentifier = "dev.verdict.judge"

    /// The helper's port, launching the app and waiting for it if needed.
    @discardableResult
    public func ensureRunning() async throws -> Int {
        if let port = runningPort() { return port }
        guard launch else { throw VerdictError.unavailable("Verdict is not running") }
        let candidates = appCandidates
        guard let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path) }) else {
            throw VerdictError.unavailable("Verdict is not running and \(candidates.first?.path ?? "Verdict.app") is not installed")
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", app.path]           // in the background; the app is a menu-bar item
        open.standardOutput = FileHandle.nullDevice; open.standardError = FileHandle.nullDevice
        try? open.run(); open.waitUntilExit()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let port = runningPort() { return port }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw VerdictError.unavailable("Verdict did not start in time")
    }

    // MARK: Transport

    /// One API call; returns the response body. Non-200 answers throw `.api` with the helper's message verbatim.
    public func request(_ method: String, _ path: String, body: JSON? = nil) async throws -> Data {
        let port = try await ensureRunning()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.compact.utf8)
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw VerdictError.unavailable("Verdict did not answer: \(error.localizedDescription)") }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            // Helpers before the versioned API answer every /v1 path with a bare "not found".
            if code == 404, message == "not found", path.hasPrefix("/v1/") {
                throw VerdictError.unavailable("The running Verdict predates the v1 API; update it (git pull && scripts/install.sh)")
            }
            throw VerdictError.api(status: code, message: message ?? "Verdict answered HTTP \(code)")
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw VerdictError.unavailable("Unexpected answer from Verdict: \(error)") }
    }

    // MARK: Judge

    /// Answers every question for every item, in order. Items over a model's context (nothing is truncated) or with
    /// media come back with `error` set; the rest still run. `model`: "auto" routes plain English to laya-english and
    /// other scripts to laya-multilingual. `bits`: run the model(s) at this precision (reloads a model loaded at
    /// another; it stays at the new precision while it stays loaded, and a later load without bits uses the selected
    /// precision, `Model.precision.selected`). Requests go out in batches of `batch` items.
    public func judge(_ items: [Item], _ questions: Questions, model: String = "auto", bits: Int? = nil, batch: Int = 256) async throws -> [Judgement] {
        // Parsed with VerdictKit's JSON, not JSONDecoder: that would fold ids differing only by normalization.
        try await judgeJSON(items.map(\.json), questions: questions.json, model: model, bits: bits, batch: batch).map {
            do { return try Judgement(json: $0) }
            catch let error as VerdictError { throw error }
            catch { throw VerdictError.unavailable("Unexpected answer from Verdict: \(error)") }
        }
    }
    public func judge(_ items: [String], _ questions: Questions, model: String = "auto", bits: Int? = nil, batch: Int = 256) async throws -> [Judgement] {
        try await judge(items.map { Item($0) }, questions, model: model, bits: bits, batch: batch)
    }
    /// One item, one result.
    public func judge(_ item: Item, _ questions: Questions, model: String = "auto", bits: Int? = nil) async throws -> Judgement {
        try await judge([item], questions, model: model, bits: bits)[0]
    }
    public func judge(_ item: String, _ questions: Questions, model: String = "auto", bits: Int? = nil) async throws -> Judgement {
        try await judge([Item(item)], questions, model: model, bits: bits)[0]
    }

    /// The same call with untyped JSON in and out (results keep the API's key order): for tools that pass questions
    /// files through unchanged.
    public func judgeJSON(_ items: [JSON], questions: JSON, model: String = "auto", bits: Int? = nil, batch: Int = 256) async throws -> [JSON] {
        var out: [JSON] = []
        for body in try bodies(items, questions, model: model, bits: bits, batch: batch) {
            let data = try await request("POST", "/v1/judge", body: body)
            let reply: JSON
            do { reply = try JSON.parse(data) } catch { throw VerdictError.unavailable("Unexpected answer from Verdict: \(error.localizedDescription)") }
            guard let results = reply["results"]?.array else { throw VerdictError.unavailable("Unexpected answer from Verdict: no results") }
            out += results
        }
        return out
    }

    private func bodies(_ items: [JSON], _ questions: JSON, model: String, bits: Int?, batch: Int) throws -> [JSON] {
        guard !items.isEmpty else { return [] }
        guard questions.members?.isEmpty == false else { throw VerdictError.invalidRequest("questions must be a nonempty object") }
        let size = max(1, batch)
        return stride(from: 0, to: items.count, by: size).map { start in
            var members: [JSON.Member] = [.init("items", .array(Array(items[start..<min(items.count, start + size)]))),
                                          .init("questions", questions), .init("model", .string(model))]
            if let bits { members.append(.init("bits", JSON(bits))) }
            return .object(members)
        }
    }

    // MARK: Models and state

    public func status() async throws -> Status { try decode(Status.self, try await request("GET", "/v1/status")) }

    /// The catalog with each model's state, precision and measured figures.
    public func models() async throws -> [Model] {
        struct Reply: Decodable { let models: [Model] }
        return try decode(Reply.self, try await request("GET", "/v1/models")).models
    }

    /// Loads a model (downloading it the first time). `bits` reloads it at that precision (0 = native). `manual`
    /// loads it like the menu's Load: it joins the launch set and follows the "Manually loaded" Keep Hot window.
    /// Returns the loaded models.
    @discardableResult
    public func load(_ id: String, bits: Int? = nil, manual: Bool = false) async throws -> [String] {
        var members: [JSON.Member] = [.init("model", .string(id))]
        if let bits { members.append(.init("bits", JSON(bits))) }
        if manual { members.append(.init("manual", .bool(true))) }
        return try loaded(try await request("POST", "/v1/load", body: .object(members)))
    }

    /// Unloads a model; returns the loaded models.
    @discardableResult
    public func unload(_ id: String) async throws -> [String] {
        try loaded(try await request("POST", "/v1/unload", body: ["model": .string(id)]))
    }

    /// Unloads a model and deletes its downloaded weights; returns the downloaded models (id -> bytes).
    @discardableResult
    public func delete(_ id: String) async throws -> [String: Int64] {
        struct Reply: Decodable { struct Entry: Decodable { let bytes: Int64? }; let installed: [String: Entry] }
        return try decode(Reply.self, try await request("POST", "/v1/delete", body: ["model": .string(id)])).installed.mapValues { $0.bytes ?? 0 }
    }

    public struct Settings: Sendable, Codable, Equatable {
        public var manual_idle_minutes: Int?
        public var on_demand_idle_minutes: Int?
        public var allow_swap: Bool?
    }
    /// Keep Hot idle windows (minutes; 0 = always) and the Memory mode for the running helper. The app's menu
    /// choices are saved in config.json and win at the next launch.
    @discardableResult
    public func settings(manualIdleMinutes: Int? = nil, onDemandIdleMinutes: Int? = nil, allowSwap: Bool? = nil) async throws -> Settings {
        var members: [JSON.Member] = []
        if let manualIdleMinutes { members.append(.init("manual_idle_minutes", JSON(manualIdleMinutes))) }
        if let onDemandIdleMinutes { members.append(.init("on_demand_idle_minutes", JSON(onDemandIdleMinutes))) }
        if let allowSwap { members.append(.init("allow_swap", .bool(allowSwap))) }
        if members.isEmpty { members.append(.init("allow_swap", .bool((try await status()).allow_swap ?? false))) }
        return try decode(Settings.self, try await request("POST", "/v1/settings", body: .object(members)))
    }

    private func loaded(_ data: Data) throws -> [String] {
        struct Reply: Decodable { let loaded: [String] }
        return try decode(Reply.self, data).loaded
    }
}
