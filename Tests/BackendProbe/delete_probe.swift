import Foundation
import VerdictCore

/// Drives the real Backend against a stub helper (Tests/test_backend.py): Delete is authoritative for the launch set.
/// argv: <scenario: ok|fail> <model>. Prints one JSON line of observations.
@main struct DeleteProbe {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments, scenario = args[1], model = args[2]
        let port = Int(ProcessInfo.processInfo.environment["PROBE_PORT"]!)!
        let b = Backend()
        try b.save(Configuration(executable: "/unused", hotModels: [model]))
        var s = WorkerStatus(); s.port = port
        s.models[model] = LoadedModel(device: "mlx", load_s: 0, bits: 0, residency: "manual")
        try JSONEncoder().encode(s).write(to: Backend.statusURL)
        b.poll()
        var seen: [String: Any] = ["scenario": scenario]
        b.delete(model)
        // The delete is queued in the helper (e.g. behind inference). A config or status write wakes the watcher.
        try await Task.sleep(nanoseconds: 300_000_000)
        b.poll()
        seen["while_queued"] = try b.configuration().hotModels
        FileManager.default.createFile(atPath: Backend.support.appendingPathComponent("release").path, contents: nil)
        let deadline = Date().addingTimeInterval(20)
        while b.busyModel != nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        b.poll()   // any later reconciliation
        seen["after"] = try b.configuration().hotModels
        seen["error"] = b.lastError ?? NSNull()
        seen["busy"] = b.busyModel ?? NSNull()
        print(String(data: try JSONSerialization.data(withJSONObject: seen, options: .sortedKeys), encoding: .utf8)!)
    }
}
