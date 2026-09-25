import Foundation
import Network
import Darwin
import MLX

final class HTTPServer {
    private let listener: NWListener
    private let service: Service
    private let queue = DispatchQueue(label: "verdict.http", attributes: .concurrent)
    init(_ service: Service) throws {
        self.service = service
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
                timer.schedule(deadline: .now() + 30, repeating: 30)
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
    /// Loopback is not a browser trust boundary. Local clients (the app, verdict.py, the bench) never send Origin, address
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
                // Checked before waiting for the body.
                if let refused = Self.refusal(method: String(parts[0]), headers: headers, port: boundPort) {
                    respond(connection, refused.0, ["error": refused.1]); return
                }
                if data.count < range.upperBound + length { read(connection, data); return }
                do {
                    let rawBody = data.subdata(in: range.upperBound..<(range.upperBound + length))
                    let body = length == 0 ? [:] : try JSONSerialization.jsonObject(with: rawBody) as? [String: Any] ?? [:]
                    let (code, response) = service.request(String(parts[0]), String(parts[1]), body, rawBody: rawBody)
                    respond(connection, code, response)
                } catch { respond(connection, 400, ["error": String(describing: error).prefix(500).description]) }
            } else { read(connection, data) }
        }
    }
    private func respond(_ connection: NWConnection, _ code: Int, _ body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let reason = [200: "OK", 403: "Forbidden", 404: "Not Found", 415: "Unsupported Media Type"][code] ?? "Bad Request"
        let header = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { [self] _ in
            connection.cancel()
            if service.quitting { listener.cancel(); service.finish(); exit(0) }
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
    try HTTPServer(service).run()
} catch {
    fputs("verdict-helper: \(error)\n", stderr)
    exit(1)
}
