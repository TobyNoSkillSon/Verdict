import Foundation
import XCTest

/// A built verdict-helper with stub models (VERDICT_STUB_MODELS=1: no weights, fixed answers) in a private support
/// directory: never the installed app, its config or the model cache. Build it with scripts/build-helper.sh; tests
/// that need it skip when it is missing. VERDICT_TEST_HELPER points at another build.
final class StubHelper {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var binary: URL {
        if let path = ProcessInfo.processInfo.environment["VERDICT_TEST_HELPER"] { return URL(fileURLWithPath: path) }
        return root.appendingPathComponent(".build/release-helper/verdict-helper")
    }

    let process = Process()
    let support: URL
    let port: Int

    init(environment extra: [String: String] = [:]) throws {
        guard FileManager.default.isExecutableFile(atPath: Self.binary.path) else {
            throw XCTSkip("no helper at \(Self.binary.path); run scripts/build-helper.sh")
        }
        support = FileManager.default.temporaryDirectory.appendingPathComponent("verdictkit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env.merge(["VERDICT_SUPPORT_DIR": support.path, "HF_HUB_CACHE": support.appendingPathComponent("hub").path,
                   "VERDICT_STUB_MODELS": "1", "VERDICT_PRELOAD": "", "VERDICT_PORT": "0",
                   "VERDICT_CATALOG": Self.root.appendingPathComponent("Resources/models.json").path]) { _, new in new }
        env.merge(extra) { _, new in new }
        env.removeValue(forKey: "VERDICT_EXIT_ON_STDIN_EOF")
        process.executableURL = Self.binary
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while !line.contains(0x0A) {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { throw NSError(domain: "StubHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: "helper exited before its port line"]) }
            line.append(chunk)
        }
        let object = try JSONSerialization.jsonObject(with: line.prefix { $0 != 0x0A }) as? [String: Any]
        port = object?["port"] as? Int ?? 0
    }

    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: support)
    }

    /// A raw request, for checking status codes and headers the clients never send.
    func raw(_ method: String, _ path: String, body: String? = nil, headers: [String: String] = ["Content-Type": "application/json"]) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let body { request.httpBody = Data(body.utf8) }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }
}
