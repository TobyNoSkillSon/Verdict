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
    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] chunk, _, done, error in
            if error != nil || done { connection.cancel(); return }
            var data = buffer; if let chunk { data.append(chunk) }
            if data.count > 64 * 1024 * 1024 { respond(connection, 400, ["error": "request too large"]); return }
            let delimiter = Data("\r\n\r\n".utf8)
            if let range = data.range(of: delimiter) {
                let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let length = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("content-length:") }).flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
                guard length >= 0 && length <= 64 * 1024 * 1024 else { respond(connection, 400, ["error": "invalid Content-Length"]); return }
                if data.count < range.upperBound + length { read(connection, data); return }
                let parts = (lines.first ?? "").split(separator: " ")
                guard parts.count >= 2 else { respond(connection, 400, ["error": "bad request"]); return }
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
        let header = "HTTP/1.1 \(code) \(code == 200 ? "OK" : code == 404 ? "Not Found" : "Bad Request")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
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
