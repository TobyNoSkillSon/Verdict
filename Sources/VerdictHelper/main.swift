import Foundation
import Network
import Darwin
import MLX

final class HTTPServer {
    private let listener: NWListener
    private let service: Service
    private let queue = DispatchQueue(label: "verdict.http", attributes: .concurrent)
    private let batcher: SystemOneBatcher
    init(_ service: Service) throws {
        self.service = service
        batcher = SystemOneBatcher(execute: service.systemOne)
        let requested = UInt16(ProcessInfo.processInfo.environment["VERDICT_PORT"] ?? "") ?? 0
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requested)!)
        // A fixed port cannot be supplied both as requiredLocalEndpoint and `on:`;
        // Network.framework rejects that combination with EINVAL. This binds IPv4 loopback only.
        listener = try NWListener(using: parameters)
    }
    func run() {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            read(connection, Data())
        }
        listener.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else { return }
                boundPort = Int(port)
                service.start(port: Int(port))
                let line = "{\"port\":\(port),\"pid\":\(getpid())}\n"
                FileHandle.standardOutput.write(Data(line.utf8))
                DispatchQueue.global().async { self.service.preload() }
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                // Keep Hot and pressure checks; VERDICT_TEST_IDLE_TICK_S shortens the interval for tests.
                let tick = Double(ProcessInfo.processInfo.environment["VERDICT_TEST_IDLE_TICK_S"] ?? "") ?? 30
                timer.schedule(deadline: .now() + tick, repeating: tick)
                timer.setEventHandler { self.service.idleTick() }
                timer.resume(); self.timer = timer
            case .failed(let error): fputs("listener: \(error)\n", stderr); exit(1)
            default: break
            }
        }
        listener.start(queue: queue)
        dispatchMain()
    }
    private var timer: DispatchSourceTimer?
    private var boundPort = 0
    /// Loopback is not a browser trust boundary. Local clients (the app, the CLI, VerdictKit, verdict.py) never send Origin, address
    /// the helper as 127.0.0.1/localhost:<port> and post JSON. Refuse anything else before reading the body: a web page's
    /// request (Origin), DNS rebinding (foreign Host), and form/text "simple" POSTs that skip CORS preflight.
    static func refusal(method: String, headers: [String: String], port: Int) -> (Int, String)? {
        if headers["origin"] != nil { return (403, "cross-origin requests are not accepted") }
        guard let host = headers["host"]?.lowercased(), ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host) else {
            return (403, "Host must be 127.0.0.1:\(port) or localhost:\(port)")
        }
        if method == "POST" {
            let type = headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
            guard type == "application/json" else { return (415, "Content-Type must be application/json") }
        }
        return nil
    }
    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] chunk, _, done, error in
            if error != nil || done { connection.cancel(); return }
            var data = buffer; if let chunk { data.append(chunk) }
            if data.count > 64 * 1024 * 1024 { respond(connection, 400, ["error": "request too large"]); return }
            let delimiter = Data("\r\n\r\n".utf8)
            if let range = data.range(of: delimiter) {
                let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    // A repeated Origin/Host/Content-Type is never legitimate here; keep a marker that fails the checks.
                    headers[name] = headers[name] == nil ? value : "\u{0}duplicate"
                }
                let length = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("content-length:") }).flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
                guard length >= 0 && length <= 64 * 1024 * 1024 else { respond(connection, 400, ["error": "invalid Content-Length"]); return }
                let parts = (lines.first ?? "").split(separator: " ")
                guard parts.count >= 2 else { respond(connection, 400, ["error": "bad request"]); return }
                let method = String(parts[0]), path = String(parts[1])
                let systemOne = Self.systemOnePath(path)
                // One request per connection (Connection: close). Keep-alive (VERDICT_KEEPALIVE=1, off by default) saved
                // ~0.1 ms per sequential SDK call but made 500 concurrent typesafe-sdk calls 2–8x slower: httpx's pool
                // polls every idle kept connection on each request.
                let keep = ProcessInfo.processInfo.environment["VERDICT_KEEPALIVE"] == "1" && parts.count >= 3 && parts[2] == "HTTP/1.1" && !(headers["connection"]?.lowercased().contains("close") ?? false)
                if headers["transfer-encoding"] != nil {
                    respond(connection, 400, systemOne ? ["detail": ["error_type": "invalid_request_error", "message": "chunked request bodies are not supported; send Content-Length"]]
                                                       : ["error": "chunked request bodies are not supported; send Content-Length"])
                    return
                }
                // Checked before waiting for the body.
                if let refused = Self.refusal(method: method, headers: headers, port: boundPort) {
                    respond(connection, refused.0, systemOne ? ["detail": ["error_type": refused.0 == 415 ? "invalid_request_error" : "permission_error", "message": refused.1]] : ["error": refused.1])
                    return
                }
                if data.count < range.upperBound + length { read(connection, data); return }
                let rawBody = data.subdata(in: range.upperBound..<(range.upperBound + length))
                let next = keep ? data.subdata(in: (range.upperBound + length)..<data.count) : nil
                if Self.route(path) == "/v1/systemone" {
                    guard method == "POST" else { respond(connection, 405, ["detail": "Method Not Allowed"], next: next); return }
                    switch SystemOne.validate(rawBody, catalog: service.catalog) {
                    case .failure(let issues): let (code, body) = SystemOne.unprocessable(issues); respond(connection, code, body, next: next)
                    case .success(let call):
                        batcher.submit(call) { [self] reply in
                            respond(connection, reply.status, reply.body, next: next, headers: reply.bits.map { ["x-verdict-bits": String($0)] } ?? [:])
                        }
                    }
                    return
                }
                // The System One API's other paths answer as FastAPI does: unknown /v1 paths (a trailing slash
                // included) 404 {"detail": "Not Found"}, /v1/models with another method 405.
                if let refusal = Self.fastAPIRefusal(method: method, path: path) { respond(connection, refusal.0, refusal.1, next: next); return }
                do {
                    let body = length == 0 ? [:] : try JSONSerialization.jsonObject(with: rawBody) as? [String: Any] ?? [:]
                    let (code, response) = service.request(String(parts[0]), String(parts[1]), body, rawBody: rawBody)
                    respond(connection, code, response, next: next)
                } catch { respond(connection, 400, ["error": String(describing: error).prefix(500).description], next: next) }
            } else { read(connection, data) }
        }
    }
    /// /v1/systemone and /v1/models answer in TypeSafe's error format (`{"detail": …}`).
    static func systemOnePath(_ path: String) -> Bool {
        let bare = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        return bare == "/v1/systemone" || bare == "/v1/models"
    }
    static func route(_ path: String) -> String? {
        let bare = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        return bare == "/v1/systemone" ? bare : nil
    }
    /// 404/405 in FastAPI's shape for /v1 paths Verdict does not serve and methods /v1/models does not take; nil otherwise.
    static func fastAPIRefusal(method: String, path: String) -> (Int, [String: Any])? {
        let bare = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        guard bare.hasPrefix("/v1/") else { return nil }
        if bare == "/v1/models" { return method == "GET" ? nil : (405, ["detail": "Method Not Allowed"]) }
        return Service.route(bare) == nil ? (404, ["detail": "Not Found"]) : nil
    }
    static let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 415: "Unsupported Media Type",
                          422: "Unprocessable Entity", 500: "Internal Server Error", 507: "Insufficient Storage"]
    /// `next`: keep the connection and read the client's next request (bytes already received first); nil closes it.
    private func respond(_ connection: NWConnection, _ code: Int, _ body: [String: Any], next: Data? = nil, headers: [String: String] = [:]) {
        // Sorted keys (stable output for clients and docs), shortest round-trip numbers.
        let data = ResponseJSON.data(body)
        let reason = Self.reasons[code] ?? "Bad Request"
        // Every response carries a request id in TypeSafe's header (the SDKs expose it as result.request_id).
        let header = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nx-typesafe-request-id: \(SystemOne.requestID())\r\n\(headers.map { "\($0.key): \($0.value)\r\n" }.joined())Connection: \(next == nil ? "close" : "keep-alive")\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { [self] error in
            if service.quitting { connection.cancel(); listener.cancel(); service.finish(); exit(0) }
            if let next, error == nil { read(connection, next) } else { connection.cancel() }
        })
    }
}

do {
    // A signed .app keeps its Metal library in Contents/Resources, not MacOS.
    // Standalone builds continue using the colocated mlx.metallib fallback.
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let bundledLibrary = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/mlx.metallib")
    if FileManager.default.fileExists(atPath: bundledLibrary.path) { GPU.metallib = bundledLibrary }
    let service = try Service()
    // The app keeps a pipe on our stdin and never writes to it: EOF means the app is gone (quit, crash, force-quit),
    // so the helper exits instead of lingering. Opt-in: tests and scripts run the helper with other stdins.
    if ProcessInfo.processInfo.environment["VERDICT_EXIT_ON_STDIN_EOF"] == "1" {
        Thread.detachNewThread {
            var byte: UInt8 = 0
            while true {
                let count = read(0, &byte, 1)
                if count == 0 || (count < 0 && errno != EINTR) { service.abandon() }
            }
        }
    }
    try HTTPServer(service).run()
} catch {
    fputs("verdict-helper: \(error)\n", stderr)
    exit(1)
}
