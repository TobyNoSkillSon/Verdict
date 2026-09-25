import Foundation

public enum VerdictError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let m): return m } }
}

/// Persisted in ~/Library/Application Support/Verdict/config.json.
public struct Configuration: Codable, Equatable {
    public var executable: String            // the bundled verdict-helper (informational)
    public var hotModels: [String]           // the launch set: models the user loaded manually; empty on a fresh install
    public var launchAtLogin: Bool
    public var idleMinutes: Int?             // before Keep Hot per class: one window for every model (0 or nil = always)
    public var precision: [String: Int]?     // model id -> 0 (native: Laya fp16, Von fp32), 16, 8 or 4
    public var manualIdleMinutes: Int?       // Keep Hot, manually loaded models; nil = from idleMinutes, else Always (0)
    public var onDemandIdleMinutes: Int?     // Keep Hot, models loaded on demand; nil = 15
    public var allowSwap: Bool?              // Memory: nil/false = Fit in free memory (avoids swap, best effort)
    public init(executable: String, hotModels: [String] = [], launchAtLogin: Bool = false, idleMinutes: Int? = 0) {
        self.executable = executable; self.hotModels = hotModels; self.launchAtLogin = launchAtLogin; self.idleMinutes = idleMinutes
    }
    /// Keep Hot window for manually loaded models. A config from before per-class Keep Hot keeps its single choice
    /// when the new menu offers it (15 or 60 minutes); its other choice (4 hours) becomes Always.
    public var manualIdle: Int {
        if let manualIdleMinutes { return manualIdleMinutes }
        guard let legacy = idleMinutes, manualKeepHotChoices.contains(where: { $0.minutes == legacy }) else { return 0 }
        return legacy
    }
    public var onDemandIdle: Int { onDemandIdleMinutes ?? defaultOnDemandIdleMinutes }
    public var swapAllowed: Bool { allowSwap ?? false }
    /// The helper's launch environment for these settings (launch set, Keep Hot, Memory).
    public var helperEnvironment: [String: String] {
        let env = ["VERDICT_PRELOAD": hotModels.joined(separator: ","),
                   "VERDICT_IDLE_MINUTES": String(manualIdle),
                   "VERDICT_MANUAL_IDLE_MINUTES": String(manualIdle),
                   "VERDICT_ON_DEMAND_IDLE_MINUTES": String(onDemandIdle),
                   "VERDICT_ALLOW_SWAP": swapAllowed ? "1" : "0"]
        // No VERDICT_PRECISION: the helper reads the precision choices from config.json at every load, so a Models
        // table choice made while it runs applies to the next load without a restart (a launch snapshot would not).
        return env
    }
    /// The /settings body that applies these settings to a running helper.
    public var helperSettings: [String: String] {
        ["manual_idle_minutes": String(manualIdle), "on_demand_idle_minutes": String(onDemandIdle), "allow_swap": swapAllowed ? "true" : "false"]
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

/// "8k" for 8,192 (binary sizes) and "32k" for 32,000 (decimal ones, e.g. a hosted API's listed limit).
public func formatContext(_ tokens: Int) -> String {
    guard tokens >= 1000 else { return String(tokens) }
    return tokens % 1024 == 0 ? "\(tokens / 1024)k" : "\(Int((Double(tokens) / 1000).rounded()))k"
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
/// clients/python/verdict.py `recommended_bits` mirrors this rule; the benchmark tooling writes default_bits with it.
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
        // The cause of a stock component is the helper's engine_reason; this line only says what is active.
        if let t = tokenizer { t == "fast" ? fast.append("fast tokenizer") : fallback.append("library tokenizer") }
        if let a = attention { a == "windowed" ? fast.append("windowed attention") : fallback.append("stock attention") }
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
    /// "optimized" (Verdict's fast tokenizer + windowed attention, self-tested at load) or "mlx" (stock path).
    public var engine: String?
    /// Why the model is on the stock path (nil when optimized).
    public var engine_reason: String?
    /// "manual" (menu Load/Reload, launch set) or "on_demand" (a request loaded it).
    public var residency: String?
    /// When a request last used it (or it loaded), seconds since 1970.
    public var last_used: Double?
    /// Tokens per item this loaded model accepts (its config's limit).
    public var context: Int?
    public init(device: String, load_s: Double, bits: Int? = nil, optimizations: Optimizations? = nil, engine: String? = nil, engine_reason: String? = nil,
                residency: String? = nil, last_used: Double? = nil, context: Int? = nil) {
        self.device = device; self.load_s = load_s; self.bits = bits; self.optimizations = optimizations; self.engine = engine; self.engine_reason = engine_reason
        self.residency = residency; self.last_used = last_used; self.context = context
    }
    /// True on Verdict's optimized path. Helpers before the engine field: fast tokenizer and windowed attention.
    public var optimizedEngine: Bool {
        if let engine { return engine == "optimized" }
        guard let o = optimizations else { return false }
        return o.tokenizer == "fast" && o.attention == "windowed"
    }
}

/// GPU facts from the helper (/status gpu).
public struct GPUStatus: Codable, Equatable {
    public var chip: String?
    public var neural_accelerators: Bool?
    public init(chip: String? = nil, neural_accelerators: Bool? = nil) { self.chip = chip; self.neural_accelerators = neural_accelerators }
}

/// The engine label next to a hot model: "Optimized · M5 Max" on Verdict's optimized path, else "MLX" (not fully
/// optimized: the stock path or partly optimized; `engineHelp` says which).
/// Both work; the label says which path answers. clients/python/verdict.py `engine_label` mirrors it.
public func engineLabel(_ model: LoadedModel, chip: String?) -> String {
    guard model.optimizedEngine else { return "MLX" }
    guard let chip, !chip.isEmpty else { return "Optimized" }
    return "Optimized \u{00b7} " + chip
}

/// Tooltip for the engine label: what is active (tokenizer, attention, neural-accelerator matmuls, precision) and,
/// off the optimized path, why. "MLX" covers two states: every Verdict optimization off (the stock path: a runtime
/// switch, VERDICT_STOCK_PATH, or none reported) and partly optimized (one of the fast tokenizer / windowed attention
/// still active); the first line says which.
public func engineHelp(_ model: LoadedModel, chip: String?, effectiveBits bits: Int) -> String {
    let o = model.optimizations
    var lines: [String] = []
    let why = model.engine_reason.map { " Why: \($0)." } ?? ""
    var active: [String] = [], stock: [String] = []
    if let t = o?.tokenizer { t == "fast" ? active.append("Verdict fast tokenizer") : stock.append("library tokenizer") }
    if let a = o?.attention { a == "windowed" ? active.append("windowed attention") : stock.append("MLX attention") }
    if model.optimizedEngine {
        lines.append("Verdict's optimized path, self-tested at load on this Mac" + (chip.map { " (\($0))" } ?? "") + ".")
    } else if !active.isEmpty {
        lines.append("Partly optimized, slower than Verdict's full optimized path \u{2014} "
                     + "active: " + active.joined(separator: ", ") + "; stock: " + (stock.isEmpty ? "none" : stock.joined(separator: ", ")) + "." + why)
    } else {
        lines.append("Stock MLX path: the same model without Verdict's optimizations; slower." + why)
    }
    if let t = o?.tokenizer { lines.append("Tokenizer: " + (t == "fast" ? "Verdict fast tokenizer" : "swift-transformers (library)")) }
    if let a = o?.attention { lines.append("Attention: " + (a == "windowed" ? "windowed kernel (self-test passed)" : "stock MLX attention")) }
    if let m = o?.matmul {
        let text: String
        switch m {
        case "neural accelerators": text = "GPU neural accelerators"
        case "standard GPU": text = "regular GPU path (neural accelerators need an M5-class GPU and macOS 26.2+)"
        case "f32 (by design)": text = "regular GPU path (f32; neural accelerators run 16-bit only)"
        default: text = "regular GPU path (\(m.replacingOccurrences(of: " (regular GPU path)", with: "")) quantized weights)"
        }
        lines.append("Matmuls: " + text)
    }
    lines.append("Precision: \(bits)-bit")
    return lines.joined(separator: "\n")
}

/// A model the helper unloaded on its own: Keep Hot idle window, making room for a load, or memory pressure.
public struct Eviction: Codable, Equatable {
    public var model: String
    public var residency: String?
    public var reason: String
    public var at: Double
    public init(model: String, residency: String? = nil, reason: String, at: Double) { self.model = model; self.residency = residency; self.reason = reason; self.at = at }
}

/// The last load refused because it would have needed swap (Fit in free memory).
public struct Refusal: Codable, Equatable {
    public var model: String
    public var message: String
    public var at: Double
    public init(model: String, message: String, at: Double) { self.model = model; self.message = message; self.at = at }
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
    public var manual_idle_minutes: Int? = nil
    public var on_demand_idle_minutes: Int? = nil
    public var allow_swap: Bool? = nil
    public var evictions: [Eviction]? = nil
    public var refused: Refusal? = nil
    public var error: String? = nil
    public var gpu: GPUStatus? = nil
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

A candidate needs: open weights with a licence that allows local use; a predict(state, questions) interface over choice / score / noul questions returning per-answer probabilities; an architecture that can be implemented on mlx-swift (Verdict's helper is native Swift).

Steps: (1) find the weights and runtime, verify the licence; (2) add a catalog entry to Resources/models.json (id, name, backbone, params, repository, context, languages, license, recommendation); (3) if it is not a Laya checkpoint, implement a DecisionModel + ModelLoader in Sources/VerdictEngine and register it by the catalog's runtime field in Sources/VerdictHelper/Registry.swift; (4) prove parity against the model's reference implementation: run both on the same fixed items and compare the per-answer probabilities; (5) measure accuracy, calibration and speed before adding its numbers to Resources/benchmarks.json; (6) build and test (scripts/build.sh; xcrun swift test). Report what you verified and what remains uncertain.
"""

// MARK: Keep Hot and Memory menus

/// Keep Hot idle windows (minutes; 0 = Always). Idle is per model: time since a request last used it (or it loaded).
public let manualKeepHotChoices: [(minutes: Int, title: String)] = [(0, "Always"), (15, "15 min idle"), (30, "30 min idle"), (60, "60 min idle")]
public let onDemandKeepHotChoices: [(minutes: Int, title: String)] = [(5, "5 min idle"), (15, "15 min idle"), (30, "30 min idle"), (60, "60 min idle"), (0, "Always")]
public let defaultOnDemandIdleMinutes = 15

public enum ResidencyClass: String, Equatable { case manual, onDemand = "on_demand" }

/// One entry of the Keep Hot or Memory submenu: a section header, a choice, or a disabled caption. `help` is the
/// item's tooltip: one sentence for anything that is not self-explanatory at a glance.
public enum MenuEntry: Equatable {
    case header(String, help: String? = nil)
    case choice(title: String, checked: Bool, action: MenuAction, help: String? = nil)
    case caption(String)
    case separator
}
public enum MenuAction: Equatable {
    case keepHot(ResidencyClass, minutes: Int)
    case memory(allowSwap: Bool)
}

public let manualLoadHelp = "You loaded these yourself (Load in Models…, or verdict load --manual); they load again when Verdict starts."
public let onDemandLoadHelp = "An agent's request needed these, so Verdict loaded them; they are not loaded again when Verdict starts."
public let keepHotAlwaysHelp = "Never unloaded for being idle; only Unload, or Memory making room for another model, unloads them."
public let fitInFreeMemoryTitle = "Fit in free memory"
public let fitInFreeMemoryHelp = "Checks free memory before loading and avoids swap: a model loads only if it fits in memory that is free at that moment; otherwise idle models are unloaded (least recently used, on-demand first) or the load is refused with the reason. Best effort: memory use can change after the check."
public let copySkillHelp = "Copies SKILL.md for a coding agent: when Verdict is worth using, how to write questions, and the verdict command, Python and HTTP API."
public let openFilesHelp = "Opens ~/Library/Application Support/Verdict: settings (config.json), the API's port and state (status.json) and the worker log."
public let allowSwapTitle = "Allow swap (slower)"
public let allowSwapHelp = "Loads even when memory is short; macOS moves data to disk and everything, including other apps, can slow down."

/// Keep Hot submenu: manually loaded (menu Load/Reload, the launch set) and loaded on demand (a request needed it).
public func keepHotMenu(_ config: Configuration) -> [MenuEntry] {
    func choices(_ list: [(minutes: Int, title: String)], _ kind: ResidencyClass, _ current: Int) -> [MenuEntry] {
        list.map { .choice(title: $0.title, checked: current == $0.minutes, action: .keepHot(kind, minutes: $0.minutes),
                           help: $0.minutes == 0 ? keepHotAlwaysHelp : nil) }
    }
    var entries: [MenuEntry] = [.header("Manually loaded", help: manualLoadHelp)]
    entries += choices(manualKeepHotChoices, .manual, config.manualIdle)
    entries += [.separator, .header("Loaded on demand", help: onDemandLoadHelp)]
    entries += choices(onDemandKeepHotChoices, .onDemand, config.onDemandIdle)
    entries += [.separator, .caption("Unloaded models reload on the next request")]
    return entries
}

/// Memory submenu. Fit in free memory: a load must fit in memory macOS can give without swapping, unloading idle
/// models (on demand first) to make room, else it is refused with the reason. Allow swap skips the check.
public func memoryMenu(_ config: Configuration, status: WorkerStatus?) -> [MenuEntry] {
    var entries: [MenuEntry] = [
        .choice(title: fitInFreeMemoryTitle, checked: !config.swapAllowed, action: .memory(allowSwap: false), help: fitInFreeMemoryHelp),
        .choice(title: allowSwapTitle, checked: config.swapAllowed, action: .memory(allowSwap: !config.swapAllowed), help: allowSwapHelp),
    ]
    var captions: [String] = []
    if let mb = status?.memory?["available_mb"] { captions.append(String(format: "~%.1f GB free now", Swift.max(0, mb) / 1000)) }
    if let last = status?.evictions?.last(where: { $0.reason.hasPrefix("memory") }) { captions.append("Unloaded \(last.model) to make room") }
    if !captions.isEmpty { entries.append(.separator); entries += captions.map { .caption($0) } }
    return entries
}

/// Applies a Keep Hot or Memory choice to the configuration.
public func applying(_ action: MenuAction, to config: Configuration) -> Configuration {
    var next = config
    switch action {
    case .keepHot(.manual, let minutes): next.manualIdleMinutes = minutes; next.idleMinutes = minutes
    case .keepHot(.onDemand, let minutes): next.onDemandIdleMinutes = minutes
    case .memory(let allow): next.allowSwap = allow
    }
    return next
}

/// The launch set grows by the models the helper reports as manually loaded (Load from the menu, or `verdict load
/// --manual`). It shrinks only on an explicit Unload/Delete, never when Keep Hot or the memory check unloads a model.
/// Nil when nothing changes.
public func launchSet(_ hot: [String], adding status: WorkerStatus) -> [String]? {
    let manual = status.models.filter { $0.value.residency == ResidencyClass.manual.rawValue }.keys.sorted()
    let added = manual.filter { !hot.contains($0) }
    return added.isEmpty ? nil : hot + added
}

/// The models table's footer notice: the app's own error, the worker's, else a recent memory refusal (10 minutes).
public func footerNotice(lastError: String?, status: WorkerStatus?, now: Double) -> String? {
    if let lastError { return lastError }
    if let error = status?.error { return error }
    if let refused = status?.refused, now - refused.at < 600 { return refused.message }
    return nil
}


/// A chip name without the vendor prefix: "Apple M5 Max" → "M5 Max". Nil when empty.
public func displayChip(_ chip: String?) -> String? {
    guard var c = chip?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return nil }
    if c.hasPrefix("Apple ") { c = String(c.dropFirst(6)) }
    return c.isEmpty ? nil : c
}

/// The generation token of an Apple Silicon chip name: "M5" in "M5 Max", "Apple M5 Pro" or "M5". Nil when there is none.
public func chipGeneration(_ chip: String?) -> String? {
    guard let chip else { return nil }
    return chip.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init).first { token in
        token.count > 1 && token.first == "M" && token.dropFirst().allSatisfy(\.isNumber)
    }
}

/// The chip the benchmarks were measured on, from benchmarks.json `hardware` ("Apple M5 Max, macOS 26.6" → "M5 Max"):
/// the most common chip among the results; hosted or published entries without a chip are ignored.
public func measurementChip(_ benchmarks: [String: ModelBenchmark]) -> String? {
    var counts: [String: Int] = [:]
    for model in benchmarks.values {
        for result in model.precisions.values {
            guard let hardware = result.hardware, let chip = displayChip(hardware.split(separator: ",").first.map(String.init)),
                  chipGeneration(chip) != nil else { continue }
            counts[chip, default: 0] += 1
        }
    }
    return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key
}

/// The models table's footer note when this Mac is not in the measurement chip's family (M5 vs M5 Pro: same family).
/// Nil when either chip is unknown or both share a generation.
public func hardwareNote(thisChip: String?, measuredOn: String?) -> (text: String, help: String)? {
    guard let this = displayChip(thisChip), let measured = displayChip(measuredOn),
          let thisGeneration = chipGeneration(this), let measuredGeneration = chipGeneration(measured),
          thisGeneration != measuredGeneration else { return nil }
    return ("Benchmarks measured on \(measured)",
            "Speed, energy and memory were measured on \(measured); they differ on this Mac (\(this)). Accuracy is the same.")
}
