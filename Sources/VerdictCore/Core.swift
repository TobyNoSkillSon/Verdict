import Foundation

public enum VerdictError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let m): return m } }
}

/// Persisted in ~/Library/Application Support/Verdict/config.json.
public struct Configuration: Codable, Equatable {
    public var executable: String            // the bundled verdict-helper (informational)
    public var hotModels: [String]           // loaded at launch, kept resident
    public var launchAtLogin: Bool
    public var idleMinutes: Int?             // 0 or nil = always hot
    public var precision: [String: Int]?     // model id -> 0 (native: Laya fp16, Von fp32), 16, 8 or 4
    public init(executable: String, hotModels: [String] = ["laya-english"], launchAtLogin: Bool = false, idleMinutes: Int? = 0) {
        self.executable = executable; self.hotModels = hotModels; self.launchAtLogin = launchAtLogin; self.idleMinutes = idleMinutes
    }
    public func validate() throws {
        guard executable.hasPrefix("/") else { throw VerdictError.message("The native helper is missing. Reinstall: git pull && scripts/install.sh") }
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

/// Measured figures for one model at one precision. Every field is optional: absent = not measured ("—").
public struct BenchmarkResult: Codable, Equatable {
    public var accuracy: Double?
    public var accuracy_en: Double?
    public var accuracy_ml: Double?
    public var ece: Double?
    public var ms: Double?              // single-item p50 wall
    public var items_per_s: Double?     // batched throughput
    public var j_per_1k: Double?        // net energy per 1,000 judgements (batched)
    public var memory_mb: Double?       // phys_footprint loaded, after warm-up
    public var sets: [String: Double]?
    public var n_tasks: Int?
    public var n: Int?
    public var source: String?
    public var date: String?
    public var hardware: String?
    public var note: String?
    public init(accuracy: Double? = nil, ece: Double? = nil, ms: Double? = nil, j_per_1k: Double? = nil, memory_mb: Double? = nil, source: String? = nil) {
        self.accuracy = accuracy; self.ece = ece; self.ms = ms; self.j_per_1k = j_per_1k; self.memory_mb = memory_mb; self.source = source
    }
}

/// One model's entry in benchmarks.json: `{"default_bits": 16|32, "precisions": {"16": {...}, "8": {...}}}`.
/// The older flat shape (one result per model, e.g. the published jev entry) decodes as a single result at the default precision.
public struct ModelBenchmark: Codable, Equatable {
    public var default_bits: Int?
    public var precisions: [String: BenchmarkResult]
    public init(default_bits: Int?, precisions: [Int: BenchmarkResult]) {
        self.default_bits = default_bits
        self.precisions = Dictionary(uniqueKeysWithValues: precisions.map { (String($0.key), $0.value) })
    }
    private enum Keys: String, CodingKey { case default_bits, precisions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        default_bits = try? c.decodeIfPresent(Int.self, forKey: .default_bits)
        if c.contains(.precisions) {
            // Tolerate a malformed precision entry rather than dropping the whole model.
            let raw = (try? c.decode([String: FailableResult].self, forKey: .precisions)) ?? [:]
            precisions = raw.compactMapValues(\.value)
        } else {
            precisions = [String(default_bits ?? 16): try BenchmarkResult(from: decoder)]
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(default_bits, forKey: .default_bits)
        try c.encode(precisions, forKey: .precisions)
    }
    /// Result at an effective precision (16/8/4/32 — never the config's 0).
    public func result(bits: Int) -> BenchmarkResult? { precisions[String(bits)] }
    public func defaultResult(nativeBits: Int) -> BenchmarkResult? { result(bits: default_bits ?? nativeBits) }
}

private struct FailableResult: Decodable {
    let value: BenchmarkResult?
    init(from decoder: Decoder) throws { value = try? BenchmarkResult(from: decoder) }
}

/// Decodes benchmarks.json; a malformed model entry is skipped, not fatal.
public func decodeBenchmarks(_ data: Data) -> [String: ModelBenchmark] {
    guard let raw = try? JSONDecoder().decode([String: FailableModel].self, from: data) else { return [:] }
    return raw.compactMapValues(\.value)
}
private struct FailableModel: Decodable {
    let value: ModelBenchmark?
    init(from decoder: Decoder) throws { value = try? ModelBenchmark(from: decoder) }
}

// MARK: Precision

/// Native weight precision: Laya checkpoints are fp16, Von fp32.
public func nativeBits(runtime: String?) -> Int { runtime == "von" ? 32 : 16 }
/// Offered precisions, highest first. Never below 4.
public func precisionOptions(runtime: String?) -> [Int] { runtime == "von" ? [32, 16, 8, 4] : [16, 8, 4] }
/// Config/helper bits (0 = native) → effective bits.
public func effectiveBits(config bits: Int, native: Int) -> Int { bits == 0 ? native : bits }
/// Effective bits → config/helper bits: the native precision is stored as 0.
public func configBits(effective bits: Int, native: Int) -> Int { bits == native ? 0 : bits }

// MARK: Recommended precision

/// Accuracy margin (fraction, 0.005 = 0.5 points) a precision may lose against the native precision.
public let recommendationMargin = 0.005

/// The recommended precision: among measured precisions (accuracy present) whose accuracy is at least the NATIVE
/// precision's accuracy minus 0.5 points, the lowest energy per 1,000 judgements; ties → lower ms; then higher bits.
/// The native precision is the reference, so benchmark noise at a lossy setting (e.g. 4-bit scoring above native)
/// cannot move the bar. A precision without energy (or ms) ranks after those with it. `options` limits the
/// candidates to offered precisions. Nil when the native precision has no measured accuracy.
/// client/verdict.py `recommended_bits` mirrors this rule; scripts/measure_catalog.py writes default_bits with it.
public func recommendedBits(_ benchmark: ModelBenchmark?, native: Int, options: [Int]? = nil) -> Int? {
    guard let benchmark, let reference = benchmark.result(bits: native)?.accuracy else { return nil }
    let measured: [(bits: Int, result: BenchmarkResult)] = benchmark.precisions.compactMap { key, r in
        guard let bits = Int(key), let accuracy = r.accuracy, options?.contains(bits) ?? true,
              // 1e-9 absorbs float error: 0.480 − 0.475 is not exactly 0.005.
              accuracy >= reference - recommendationMargin - 1e-9 else { return nil }
        return (bits, r)
    }
    func order(_ a: Double?, _ b: Double?) -> Bool? {
        switch (a, b) {
        case let (x?, y?): return x == y ? nil : x < y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return nil
        }
    }
    return measured.min { a, b in
        order(a.result.j_per_1k, b.result.j_per_1k) ?? order(a.result.ms, b.result.ms) ?? (a.bits > b.bits)
    }?.bits
}

/// Recommended precision for a catalog model; nil for the hosted reference and unmeasured models.
public func recommendedBits(for model: CatalogModel, benchmark: ModelBenchmark?) -> Int? {
    guard model.reference != true else { return nil }
    return recommendedBits(benchmark, native: nativeBits(runtime: model.runtime), options: precisionOptions(runtime: model.runtime))
}

/// Default precision (effective bits) when config has no explicit choice: the recommended one, else native.
public func defaultBits(recommended: Int?, native: Int) -> Int { recommended ?? native }

/// Selected precision as effective bits: the explicit config choice (0 = native) or the default.
public func selectedBits(config: Int?, recommended: Int?, native: Int) -> Int {
    config.map { effectiveBits(config: $0, native: native) } ?? defaultBits(recommended: recommended, native: native)
}

/// What the load button does for a model with a selected precision and, if loaded, its loaded precision.
public enum LoadAction: Equatable { case load, unload, reload }
public func loadAction(selected: Int, loaded: Int?, native: Int) -> LoadAction {
    guard let loaded else { return .load }
    return effectiveBits(config: loaded, native: native) == effectiveBits(config: selected, native: native) ? .unload : .reload
}

// MARK: Deltas vs the recommended (default) precision

public enum DeltaTone: Equatable { case better, worse, neutral }
public struct Delta: Equatable {
    public var text: String
    public var tone: DeltaTone
    public init(_ text: String, _ tone: DeltaTone) { self.text = text; self.tone = tone }
}

private let minus = "\u{2212}"
private func signed(_ value: Double, _ format: String) -> String {
    let body = String(format: format, abs(value))
    return (value < 0 ? minus : "+") + body
}

/// Accuracy (fractions 0…1) → "−0.4 pt"; higher is better. Differences under 0.05 pt read as "±0.0 pt".
public func accuracyDelta(_ value: Double?, base: Double?) -> Delta? {
    guard let value, let base else { return nil }
    let points = (value - base) * 100
    if abs(points) < 0.05 { return Delta("±0.0 pt", .neutral) }
    return Delta(signed(points, "%.1f") + " pt", points > 0 ? .better : .worse)
}

/// Calibration error → "+0.012"; lower is better. Differences under 0.0005 read as "±0.000".
public func eceDelta(_ value: Double?, base: Double?) -> Delta? {
    guard let value, let base else { return nil }
    let d = value - base
    if abs(d) < 0.0005 { return Delta("±0.000", .neutral) }
    return Delta(signed(d, "%.3f"), d < 0 ? .better : .worse)
}

/// Latency (ms per item) → "35% faster" / "20% slower" as a rate change (base/value − 1);
/// from 2× on it reads "2.4× faster". Under 1% reads "same speed".
public func speedDelta(_ ms: Double?, base: Double?, short: Bool = false) -> Delta? {
    guard let ms, let base, ms > 0, base > 0 else { return nil }
    let faster = ms < base
    let ratio = faster ? base / ms : ms / base
    let word = faster ? "faster" : "slower"
    if ratio - 1 < 0.01 { return Delta(short ? "same" : "same speed", .neutral) }
    let amount = ratio >= 2 ? String(format: "%.1f×", ratio) : String(format: "%.0f%%", (ratio - 1) * 100)
    if amount == "0%" { return Delta(short ? "same" : "same speed", .neutral) }
    return Delta("\(amount) \(word)", faster ? .better : .worse)
}

/// Energy per 1,000 judgements → "20% less energy" / "15% more energy" (fraction of the base); from 2× the base on it
/// reads "2.9× more energy". Under 1% reads "same energy".
public func energyDelta(_ joules: Double?, base: Double?, short: Bool = false) -> Delta? {
    guard let joules, let base, base > 0 else { return nil }
    let change = joules / base - 1
    let suffix = short ? "" : " energy"
    if abs(change) < 0.005 { return Delta("same" + suffix, .neutral) }
    if change >= 1 { return Delta(String(format: "%.1f× more", joules / base) + suffix, .worse) }
    return Delta(String(format: "%.0f%%", abs(change) * 100) + (change < 0 ? " less" : " more") + suffix, change < 0 ? .better : .worse)
}

/// Megabytes → "782 MB" / "1.26 GB", formatted like the On disk column.
public func formatMemory(_ mb: Double?) -> String? {
    guard let mb else { return nil }
    return formatBytes(Int64((mb * 1_000_000).rounded()))
}

/// "4.6 ms" under 10 ms, else whole milliseconds.
public func formatMs(_ ms: Double?) -> String? {
    guard let ms else { return nil }
    return ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms)
}

/// Which optimized paths a loaded model uses on this Mac (from the helper). Anything not optimized is the
/// stock fallback: same answers, slower.
public struct Optimizations: Codable, Equatable {
    public var tokenizer: String?
    public var attention: String?
    public var matmul: String?
    public var optimized: Bool
    public init(tokenizer: String? = nil, attention: String? = nil, matmul: String? = nil, optimized: Bool) {
        self.tokenizer = tokenizer; self.attention = attention; self.matmul = matmul; self.optimized = optimized
    }
    /// One line for a tooltip: what is fast, and what fell back and why.
    public var summary: String {
        var fast: [String] = [], fallback: [String] = []
        if let t = tokenizer { t == "fast" ? fast.append("fast tokenizer") : fallback.append("library tokenizer (tokenizer format not recognised)") }
        if let a = attention { a == "windowed" ? fast.append("windowed attention") : fallback.append("stock attention (kernel self-test did not pass)") }
        if let m = matmul {
            if m == "neural accelerators" { fast.append("GPU neural accelerators") }
            else if m == "standard GPU" { fallback.append("standard GPU matmul (neural accelerators need an M5-class GPU and macOS 26.2+)") }
            else { fast.append(m) }   // precision choice (f32 / quantized), not a missing capability
        }
        let head = optimized ? "Optimized for this Mac" : "Standard on this Mac (fallback, same answers, slower)"
        return head + (fast.isEmpty ? "" : ": " + fast.joined(separator: ", ")) + (fallback.isEmpty ? "." : ". Fallback: " + fallback.joined(separator: "; ") + ".")
    }
}

public struct LoadedModel: Codable, Equatable {
    public var device: String
    public var load_s: Double
    public var bits: Int?
    public var optimizations: Optimizations?
    public init(device: String, load_s: Double, bits: Int? = nil, optimizations: Optimizations? = nil) { self.device = device; self.load_s = load_s; self.bits = bits; self.optimizations = optimizations }
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
    case stopped, starting, loading(String), downloading(String), ready(hot: Int), failed(String)
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

/// Decimal byte counts with a fixed en_US decimal point, like the app's other numbers ("842.6 MB").
public func formatBytes(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file).locale(Locale(identifier: "en_US")))
}

/// Copied by "Copy Skill for Your Agent": a complete SKILL.md an agent can drop into its skills folder.
/// The skill text lives in Resources/SKILL.md (bundled); the app and `verdict skill` read the same file.


/// Copied from the models table: a brief the user can hand to an agent to add or evaluate a model.
public let modelRequest = """
Add a decision model to Verdict (menu-bar app that keeps typed-question models hot on this Mac; project at ~/Projects/Verdict or github.com/TobyNoSkillSon/Verdict).

A candidate needs: open weights with a licence that allows local use; a predict(state, questions) interface over choice / score / noul questions returning per-answer probabilities; an architecture that can be implemented on mlx-swift (Verdict's helper is native Swift; see native/PLAN.md).

Steps: (1) find the weights and runtime, verify the licence; (2) add a catalog entry to Resources/models.json (id, name, backbone, params, repository, context, languages, license, recommendation); (3) if it is not a Laya checkpoint, implement a DecisionModel + ModelLoader in native/Sources/VerdictEngine and register it by the catalog's runtime field in native/Sources/VerdictHelper/Registry.swift; (4) prove parity against the model's reference implementation on fixed fixtures (see native/fixtures and scripts/oracle.py); (5) run scripts/benchmark.py so it appears with measured accuracy, calibration and speed; (6) run the tests (xcrun swift test; python3 Tests/edge_pass.py). Report what you verified and what remains uncertain.
"""

public let keepHotChoices: [(minutes: Int, title: String)] = [(0, "Always"), (15, "15 minutes after use"), (60, "1 hour after use"), (240, "4 hours after use")]

