import Foundation

public enum VerdictError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let m): return m } }
}

/// Persisted in ~/Library/Application Support/Verdict/config.json.
public struct Configuration: Codable, Equatable {
    public var executable: String            // python inside the runtime venv
    public var hotModels: [String]           // loaded at launch, kept resident
    public var launchAtLogin: Bool
    public var idleMinutes: Int?             // 0 or nil = always hot
    public var precision: [String: Int]?     // model id -> 0 (fp16), 8 or 4
    public init(executable: String, hotModels: [String] = ["laya-english"], launchAtLogin: Bool = false, idleMinutes: Int? = 0) {
        self.executable = executable; self.hotModels = hotModels; self.launchAtLogin = launchAtLogin; self.idleMinutes = idleMinutes
    }
    public func validate() throws {
        guard executable.hasPrefix("/"), executable.split(separator: "/").last?.hasPrefix("python") == true else {
            throw VerdictError.message("Runtime is not set up. Run scripts/setup-backend.sh, then relaunch Verdict.")
        }
    }
}

public struct CatalogModel: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var backbone: String
    public var params: String
    public var repository: String
    public var subfolder: String
    public var downloadBytes: Int64
    public var context: Int
    public var languages: String
    public var license: String
    public var recommendation: String
    public var recommended: Bool
    public var reference: Bool?
    public var runtime: String?
    public var inputs: [String]?
}

public func formatContext(_ tokens: Int) -> String {
    tokens >= 1024 ? "\(tokens / 1024)k" : String(tokens)
}

public struct BenchmarkResult: Codable, Equatable {
    public var source: String
    public var n: Int?
    public var sets: [String: Double]
    public var ece: Double
    public var ms: Double
    public var accuracy: Double
    public var note: String?
}

public struct LoadedModel: Codable, Equatable {
    public var device: String
    public var load_s: Double
    public var bits: Int?
    public init(device: String, load_s: Double, bits: Int? = nil) { self.device = device; self.load_s = load_s; self.bits = bits }
}

public struct InstalledModel: Codable, Equatable {
    public var bytes: Int64
    public init(bytes: Int64) { self.bytes = bytes }
}

/// Written by the worker after every change; the app never needs a request to draw the menu.
public struct WorkerStatus: Codable, Equatable {
    public var models: [String: LoadedModel] = [:]
    public var installed: [String: InstalledModel] = [:]
    public var calls: Int = 0
    public var items: Int = 0
    public var last_ms: Double? = nil
    public var started: Double = 0
    public var port: Int? = nil
    public var pid: Int32? = nil
    public var loading: String? = nil
    public var downloading: Bool? = nil
    public var idle_unloaded: Bool? = nil
    public var memory: [String: Double]? = nil
    public var idle_minutes: Int? = nil
    public var error: String? = nil
    public var updated: Double = 0
    public init() {}
}

public enum WorkerPhase: Equatable {
    case stopped, starting, settingUp, loading(String), downloading(String), ready(hot: Int), failed(String)
}

public func phase(for status: WorkerStatus?, processRunning: Bool) -> WorkerPhase {
    guard processRunning else { return .stopped }
    guard let status, status.port != nil else { return .starting }
    if let error = status.error, status.loading == nil, status.models.isEmpty { return .failed(error) }
    if let loading = status.loading { return status.downloading == true ? .downloading(loading) : .loading(loading) }
    return .ready(hot: status.models.count)
}

public func summaryLine(_ phase: WorkerPhase, status: WorkerStatus?) -> String {
    switch phase {
    case .stopped: return "Verdict: stopped"
    case .starting: return "Verdict: starting…"
    case .settingUp: return "Verdict: setting up runtime…"
    case .loading(let id): return "Verdict: loading \(id)…"
    case .downloading(let id): return "Verdict: downloading \(id)…"
    case .failed: return "Verdict: needs attention…"
    case .ready(let hot):
        let count = status?.items ?? 0
        let judged = count == 1 ? "1 judgement" : "\(count.formatted(.number.locale(Locale(identifier: "en_US")))) judgements"
        if hot == 0 { return status?.idle_unloaded == true ? "Verdict: idle, models unloaded" : "Verdict: ready, no model hot" }
        return "Verdict: \(hot) model\(hot == 1 ? "" : "s") hot · \(judged)"
    }
}

public func latencyLine(_ status: WorkerStatus?) -> String? {
    guard let status else { return nil }
    var parts: [String] = []
    if let ms = status.last_ms { parts.append(ms < 1000 ? String(format: "Last judgement %.0f ms", ms) : String(format: "Last judgement %.1f s", ms / 1000)) }
    if let weights = status.memory?["mlx_active_mb"], weights > 0 { parts.append(String(format: "%.1f GB in memory", weights / 1000)) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

public func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Copied by "Copy Skill for Your Agent": a complete SKILL.md an agent can drop into its skills folder.
/// The skill text lives in Resources/SKILL.md (bundled); the app and `verdict skill` read the same file.


/// Copied from the models table: a brief the user can hand to an agent to add or evaluate a model.
public let modelRequest = """
Add a decision model to Verdict (menu-bar app that keeps typed-question models hot on this Mac; project at ~/Projects/Verdict or github.com/TobyNoSkillSon/Verdict).

A candidate needs: open weights with a licence that allows local use; a predict(state, questions) interface over choice / score / noul questions returning per-answer probabilities; an Apple-Silicon-native runtime (MLX preferred) that loads in seconds.

Steps: (1) find the weights and runtime, verify the licence; (2) add a catalog entry to Resources/models.json (id, name, backbone, params, repository, context, languages, license, recommendation); (3) if it is not a Laya checkpoint, add a loader branch in Resources/worker.py; (4) run scripts/benchmark.py so it appears with measured accuracy, calibration and speed; (5) run the tests (xcrun swift test; cd Tests && python3 -m unittest test_worker). Report what you verified and what remains uncertain.
"""

public let keepHotChoices: [(minutes: Int, title: String)] = [(0, "Always"), (15, "15 minutes after use"), (60, "1 hour after use"), (240, "4 hours after use")]

public let precisionChoices: [(bits: Int, title: String)] = [(0, "fp16"), (8, "8-bit"), (4, "4-bit")]
