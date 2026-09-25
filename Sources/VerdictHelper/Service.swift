import Foundation
import Darwin
import MLX
import VerdictEngine

final class Service {
    let catalog: Catalog
    let support: URL
    private let lock = NSRecursiveLock()
    private var models: [String: DecisionModel] = [:]
    private var order: [String] = []
    /// Precision each loaded model runs at (helper bits, 0 = native); set by its load, cleared by its unload.
    private var loadedBits: [String: Int] = [:]
    /// VERDICT_PRECISION (id -> bits, 0 = native): a launch override for test and benchmark harnesses. The app does
    /// not set it; its Models table choice lives in config.json, which `implicitBits` rereads for every load.
    private var launchPrecision: [String: Int] = [:]
    /// Models switched to the stock path after an optimized-path failure: id -> the failure. Cleared on unload
    /// (the switch lasts for that loaded model's lifetime).
    private var fallbacks: [String: String] = [:]
    private var state: [String: Any]
    private let cacheLimit: Int
    private let shedPercent: Double
    private let trimPercent: Double
    private var lastRSS: (Double, Double) = (0, 0)
    var quitting = false
    /// Per loaded model: its residency class, when a request last used it (or it loaded), and its load estimate (MB).
    private var residency: [String: Residency] = [:]
    private var lastUsed: [String: Double] = [:]
    private var footprint: [String: Double] = [:]
    /// Models the request being served needs; never evicted or idle-unloaded meanwhile.
    private var pinned: Set<String> = []
    /// Keep Hot idle windows in minutes per class (0 = always) and the Memory mode.
    private var manualIdle: Int
    private var onDemandIdle: Int
    private var allowSwap: Bool
    private let probe: MemoryProbe
    /// Seconds per Keep Hot minute; tests shorten it (VERDICT_TEST_MINUTE_SECONDS).
    private let minuteSeconds: Double

    init() throws {
        catalog = try Catalog()
        let env = ProcessInfo.processInfo.environment
        support = URL(fileURLWithPath: env["VERDICT_SUPPORT_DIR"] ?? ((env["HOME"] ?? NSHomeDirectory()) + "/Library/Application Support/Verdict"), isDirectory: true)
        cacheLimit = Int(env["VERDICT_CACHE_LIMIT_MB"] ?? "") ?? 1024
        shedPercent = Double(env["VERDICT_SHED_FREE_PCT"] ?? "") ?? 8
        trimPercent = Double(env["VERDICT_TRIM_FREE_PCT"] ?? "") ?? 15
        if let data = env["VERDICT_PRECISION"]?.data(using: .utf8), let p = try? JSONSerialization.jsonObject(with: data) as? [String: Int] { launchPrecision = p }
        let now = Date().timeIntervalSince1970
        // VERDICT_IDLE_MINUTES (older launchers and test harnesses) sets both classes unless the per-class
        // variables are given; the app passes all three.
        let legacy = Int(env["VERDICT_IDLE_MINUTES"] ?? "")
        manualIdle = max(0, Int(env["VERDICT_MANUAL_IDLE_MINUTES"] ?? "") ?? legacy ?? 0)
        onDemandIdle = max(0, Int(env["VERDICT_ON_DEMAND_IDLE_MINUTES"] ?? "") ?? legacy ?? 15)
        allowSwap = env["VERDICT_ALLOW_SWAP"] == "1"
        probe = MemoryProbe(environment: env)
        minuteSeconds = Double(env["VERDICT_TEST_MINUTE_SECONDS"] ?? "") ?? 60
        state = ["api": Self.apiVersion, "version": Self.appVersion ?? NSNull(), "models": [:], "calls": 0, "items": 0, "last_ms": NSNull(), "started": now, "port": NSNull(), "pid": Int(getpid()), "loading": NSNull(), "error": NSNull(), "last_used": now, "gpu": Self.gpu, "evictions": [], "refused": NSNull()]
        Memory.cacheLimit = cacheLimit * 1024 * 1024
        publishSettings()
    }
    /// Keep Hot and Memory settings as /status reports them; idle_minutes is the manual value (older clients).
    private var settings: [String: Any] {
        ["idle_minutes": manualIdle, "manual_idle_minutes": manualIdle, "on_demand_idle_minutes": onDemandIdle, "allow_swap": allowSwap]
    }
    private func publishSettings() { for (key, value) in settings { state[key] = value } }
    func start(port: Int) { locked { state["port"] = port; writeStatus() } }
    func finish() { locked { state["models"] = [:]; state["port"] = NSNull(); writeStatus() }; flushStatus() }
    /// The app that launched this helper is gone (its stdin pipe closed): record the shutdown unless a request holds
    /// the lock for more than two seconds, then exit.
    func abandon() -> Never {
        if lock.lock(before: Date().addingTimeInterval(2)) {
            state["models"] = [:]; state["port"] = NSNull(); writeStatus(); lock.unlock()
            flushStatus()
        }
        exit(0)
    }
    func preload() {
        for id in (ProcessInfo.processInfo.environment["VERDICT_PRELOAD"] ?? "").split(separator: ",") {
            do { try locked { _ = try load(String(id), as: .manual) } }
            catch { fputs("{\"error\":\"\(String(describing: error).prefix(300))\"}\n", stderr) }
        }
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    private func memory() -> [String: Double] {
        let now = Date().timeIntervalSince1970
        if now - lastRSS.0 > 1 {
            let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-o", "rss=", "-p", String(getpid())]
            let output = Pipe(); ps.standardOutput = output; ps.standardError = Pipe()
            if (try? ps.run()) != nil {
                let data = output.fileHandleForReading.readDataToEndOfFile(); ps.waitUntilExit()
                if let str = String(data: data, encoding: .utf8), let kb = Double(str.trimmingCharacters(in: .whitespacesAndNewlines)) { lastRSS = (now, (kb / 1024).rounded()) }
            }
        }
        return ["rss_mb": lastRSS.1, "mlx_active_mb": (Double(Memory.activeMemory) / 1e6).rounded(), "mlx_cache_mb": (Double(Memory.cacheMemory) / 1e6).rounded(),
                "available_mb": probe.availableMB(loadedMB: loadedReclaimMB).rounded()]
    }
    /// What unloading every loaded model would free (`reclaim`); the test probe counts exactly this as in use, so a
    /// reload credit or an eviction gives back what the probe took (the real probe measures pages instead).
    private var loadedReclaimMB: Double { order.reduce(0) { $0 + reclaim($1) } }
    /// Which optimized paths a loaded model uses on this Mac. Anything not optimized is the stock fallback:
    /// same answers, slower. `optimized` is true only when every reported path is the fast one.
    static func optimizations(_ agent: Any, runtime: String, bits: Int) -> [String: Any] {
        var out: [String: Any] = [:], fast = true
        if let t = (agent as? TokenizerPathReporting)?.tokenizerPath { out["tokenizer"] = t; fast = fast && t == "fast" }
        if let k = (agent as? KernelPathReporting)?.kernelPath {
            let windowed = k.hasPrefix("windowed")
            out["attention"] = windowed ? "windowed" : "stock"; fast = fast && windowed
        }
        // Neural accelerators run fp16/bf16 GEMMs only. Von's default is f32 by design (fp16 misses the ≤1%
        // gate) and quantized GEMMs dequantize on the regular path: those are a precision choice, not a
        // missing capability, so they do not mark the Mac as "standard".
        let nax = gpu["neural_accelerators"] as? Bool ?? false
        let halfPrecision = runtime == "von" ? bits == 16 : (bits == 0 || bits == 16)
        if !nax { out["matmul"] = "standard GPU"; fast = false }
        else if halfPrecision { out["matmul"] = "neural accelerators" }
        else { out["matmul"] = runtime == "von" && (bits == 0 || bits == 32) ? "f32 (by design)" : "\(bits)-bit (regular GPU path)" }
        out["optimized"] = fast
        return out
    }
    static let stockRequested = ProcessInfo.processInfo.environment["VERDICT_STOCK_PATH"] == "1"
    /// The engine label's facts: "optimized" when Verdict's optimized path (fast tokenizer + windowed attention that
    /// passed its load-time self-test on this Mac) serves the model, else "mlx" with the reason: the stock path, or
    /// partly optimized when one of the two is still active (optimizations says which; the app's tooltip lists both).
    /// Neural-accelerator matmuls and precision are reported separately (optimizations.matmul); they do not decide it.
    static func engine(_ agent: Any, runtime: String, fallback: String?) -> (engine: String, reason: String?) {
        if let fallback { return ("mlx", "the optimized path failed during inference (\(fallback)); switched to the stock MLX path") }
        if stockRequested, agent is InferencePathSwitching { return ("mlx", "stock path requested (VERDICT_STOCK_PATH=1)") }
        var why: [String] = []
        let tokenizer = (agent as? TokenizerPathReporting)?.tokenizerPath
        let kernel = (agent as? KernelPathReporting)?.kernelPath
        if tokenizer == nil && kernel == nil { return ("mlx", "no optimized path for this runtime") }
        if let t = tokenizer, t != "fast" {
            why.append(runtime == "von" && ProcessInfo.processInfo.environment["VERDICT_VON_TOKENIZER"] == "library"
                       ? "library tokenizer requested (VERDICT_VON_TOKENIZER=library)" : "tokenizer format not recognised")
        }
        if let k = kernel, !k.hasPrefix("windowed") {
            why.append(k.contains("self-test failed") ? "kernel self-test did not pass on this chip"
                       : "windowed attention disabled (VERDICT_\(runtime == "von" ? "VON" : "LAYA")_WINDOW=0)")
        }
        return why.isEmpty ? ("optimized", nil) : ("mlx", why.joined(separator: "; "))
    }
    /// Recompute a loaded model's optimizations and engine entry in state (after load or a stock fallback).
    private func describe(_ id: String, _ agent: DecisionModel, runtime: String, bits: Int) {
        var active = state["models"] as? [String: Any] ?? [:]
        guard var entry = active[id] as? [String: Any] else { return }
        entry["optimizations"] = Self.optimizations(agent, runtime: runtime, bits: bits)
        if let path = (agent as? KernelPathReporting)?.kernelPath { entry["kernel"] = path }
        let engine = Self.engine(agent, runtime: runtime, fallback: fallbacks[id])
        entry["engine"] = engine.engine; entry["engine_reason"] = engine.reason ?? NSNull()
        active[id] = entry; state["models"] = active
    }
    /// GPU facts for the compatibility indicator. Neural-accelerator matmuls: MLX core 0.32 uses them on
    /// macOS 26.2+ when the GPU generation is >= 17 (Mac) / >= 18 (phone class) — mirrors mlx is_nax_available().
    static let gpu: [String: Any] = {
        let arch = GPU.deviceInfo().architecture   // e.g. applegpu_g17s
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var gen = 0, cls: Character = "?"
        if let g = arch.range(of: "_g") {
            let tail = arch[g.upperBound...]
            gen = Int(tail.prefix { $0.isNumber }) ?? 0
            cls = tail.last ?? "?"
        }
        let osOK = os.majorVersion > 26 || (os.majorVersion == 26 && os.minorVersion >= 2)
        let nax = osOK && gen >= (cls == "p" ? 18 : 17)
        // "Apple M5 Max" -> "M5 Max", for the engine label ("Optimized · M5 Max").
        var size = 0; var chip = ""
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 { chip = String(cString: bytes) }
        }
        if chip.hasPrefix("Apple ") { chip = String(chip.dropFirst(6)) }
        return ["chip": chip, "architecture": arch, "generation": gen, "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", "neural_accelerators": nax]
    }()

    /// Disk scan of downloaded snapshots; only load/download/delete change it, so judgements reuse it.
    private var installedCache: [String: Any]?
    /// Judgements write status.json off the request path (serial queue keeps writes ordered); a judgement
    /// used to spend ~1.2 ms here on a catalog disk scan, JSON and an atomic rename. Lifecycle changes
    /// (load, unload, delete, settings) stay synchronous: once they return, the file reflects them.
    private let statusQueue = DispatchQueue(label: "verdict.status")
    private func writeStatus(refreshInstalled: Bool = true, background: Bool = false) {
        if refreshInstalled || installedCache == nil { installedCache = catalog.installed() }
        var value = state; value["updated"] = Date().timeIntervalSince1970; value["installed"] = installedCache!; value["memory"] = memory()
        guard let bytes = try? JSONSerialization.data(withJSONObject: value) else { fputs("status write: unserializable state\n", stderr); return }
        let support = self.support
        let write = {
            do {
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                let tmp = support.appendingPathComponent("status.\(getpid()).\(UUID().uuidString).tmp")
                try bytes.write(to: tmp)
                let target = support.appendingPathComponent("status.json")
                guard rename(tmp.path, target.path) == 0 else { throw ServiceError("status.json rename failed: \(errno)") }
            } catch { fputs("status write: \(error)\n", stderr) }
        }
        if background { statusQueue.async(execute: write) } else { statusQueue.sync(execute: write) }
    }
    /// Block until queued status writes reach disk (shutdown).
    func flushStatus() { statusQueue.sync {} }
    /// Loads `id` (or returns it loaded). A manual request promotes an on-demand model to manual; an on-demand request
    /// never demotes. In "Fit in free memory" mode the load must fit without swapping (see `admit`).
    /// `bits`: an explicit precision for this load (validated by the caller); nil loads at `implicitBits`.
    private func load(_ id: String, as requested: Residency, bits explicit: Int? = nil) throws -> DecisionModel {
        if let existing = models[id] {
            if requested == .manual && residency[id] != .manual {
                residency[id] = .manual; updateEntry(id); writeStatus(refreshInstalled: false)
            }
            return existing
        }
        let spec = try catalog.spec(id)
        // Do not download weights if no production loader is registered.
        let type = try loader(runtime: spec.runtime)
        let bits = explicit ?? implicitBits(spec)
        let estimate = try admit(spec, bits: bits)
        let downloading = catalog.cached(spec) == nil
        state["loading"] = id; state["downloading"] = downloading; state["error"] = NSNull(); writeStatus()
        let start = Date()
        do {
            let stub = ProcessInfo.processInfo.environment["VERDICT_STUB_MODELS"] == "1"
            let snapshot = stub ? support : try catalog.snapshot(spec)
            // A download can take minutes and memory moves meanwhile: check again right before allocating weights.
            if downloading && !stub { installedCache = nil; try admit(spec, bits: bits) }
            let agent = try type.load(id: id, snapshot: snapshot, bits: bits)
            // VERDICT_STOCK_PATH=1: serve every model on the stock MLX path (diagnosis; the fallback tests' reference).
            if Self.stockRequested, let paths = agent as? InferencePathSwitching { try paths.useStockPath(true) }
            // Stub models take the catalog's context (real models read their own config).
            if let stub = agent as? CatalogContextAdopting { stub.adoptContext(spec.context) }
            models[id] = agent; order.append(id); loadedBits[id] = bits
            residency[id] = requested; lastUsed[id] = Date().timeIntervalSince1970; footprint[id] = estimate
            var active = state["models"] as? [String: Any] ?? [:]
            active[id] = ["device": "mlx", "load_s": (Date().timeIntervalSince(start) * 10).rounded() / 10, "bits": bits,
                          "context": agent.contextLimit, "memory_estimate_mb": estimate.rounded()]
            state["models"] = active; fallbacks[id] = nil
            updateEntry(id)
            describe(id, agent, runtime: spec.runtime, bits: bits)
            state["loading"] = NSNull(); state["downloading"] = false; state["refused"] = NSNull(); writeStatus()
            return agent
        } catch {
            state["loading"] = NSNull(); state["downloading"] = false
            // A refusal is reported in state["refused"] (admit), not as a worker failure.
            if !(error is MemoryRefusal) { state["error"] = "\(id): \(String(describing: error).prefix(200))" }
            writeStatus()
            throw error
        }
    }
    private func unload(_ id: String) {
        models.removeValue(forKey: id); order.removeAll { $0 == id }; fallbacks[id] = nil; loadedBits[id] = nil
        residency[id] = nil; lastUsed[id] = nil; footprint[id] = nil
        var active = state["models"] as? [String: Any] ?? [:]; active.removeValue(forKey: id); state["models"] = active
        Memory.clearCache(); writeStatus()
    }
    /// Residency and last use into the model's /status entry.
    private func updateEntry(_ id: String) {
        var active = state["models"] as? [String: Any] ?? [:]
        guard var entry = active[id] as? [String: Any] else { return }
        entry["residency"] = (residency[id] ?? .onDemand).rawValue
        entry["last_used"] = lastUsed[id] ?? NSNull()
        active[id] = entry; state["models"] = active
    }
    /// Unloads a model the service chose to drop (idle window, making room, memory pressure) and says why: /status
    /// `evictions` (last 20) and a JSON log line.
    private func evict(_ id: String, reason: String) {
        let cls = (residency[id] ?? .onDemand).rawValue
        unload(id)
        var list = state["evictions"] as? [[String: Any]] ?? []
        list.append(["model": id, "residency": cls, "reason": reason, "at": Date().timeIntervalSince1970])
        state["evictions"] = Array(list.suffix(20)); writeStatus(refreshInstalled: false)
        fputs("{\"evicted\":\(jsonString(id)),\"residency\":\"\(cls)\",\"reason\":\(jsonString(reason))}\n", stderr)
    }
    /// Eviction order: on-demand models least recently used first, then manual ones the same way.
    private func evictionOrder() -> [String] {
        func lru(_ cls: Residency) -> [String] {
            order.filter { (residency[$0] ?? .onDemand) == cls }.sorted { (lastUsed[$0] ?? 0) < (lastUsed[$1] ?? 0) }
        }
        return lru(.onDemand) + lru(.manual)
    }
    /// "Fit in free memory" mode: a load must fit in what macOS can give without swapping (MemoryProbe): need = the
    /// model's estimate + activation headroom. Too little: unload idle models (on-demand LRU first, then manual; never
    /// a model the current request uses), re-checking after each. If even unloading every candidate would not free
    /// enough by their estimates, nothing is unloaded. Still short: MemoryRefusal (HTTP 507). Allow-swap skips all of
    /// it. `credit`: memory the caller frees before loading (the same model at another precision, `reclaim`); it is
    /// added to the raw headroom before clamping, so a deficit already present is not forgotten. Returns the estimate.
    @discardableResult
    private func admit(_ spec: ModelSpec, bits: Int, credit: Double = 0) throws -> Double {
        let estimate = memoryEstimateMB(spec, bits: bits, measured: catalog.measuredMemory, diskBytes: installedBytes(spec.id))
        if allowSwap { return estimate }
        let need = estimate + MemoryProbe.headroomMB
        Memory.clearCache()   // our own reusable buffers are not free pages yet
        func raw() -> Double { probe.rawAvailableMB(loadedMB: loadedReclaimMB) + credit }
        func available() -> Double { max(0, raw()) }
        var free = available()
        if free >= need { return estimate }
        let candidates = evictionOrder().filter { $0 != spec.id && !pinned.contains($0) }
        // Forecast from the raw (possibly negative) headroom: a deficit must be paid off before evictions help.
        if raw() + candidates.reduce(0, { $0 + reclaim($1) }) >= need {
            for victim in candidates {
                evict(victim, reason: "memory: made room for \(spec.id) at \(spec.effectiveBits(bits))-bit (needs ~\(gigabytes(need)) GB; ~\(gigabytes(free)) GB was free without swapping)")
                free = available()
                if free >= need { return estimate }
            }
        }
        // Never advise unloading a model this request needs: it would be loaded again and refused the same way.
        let message = refusalMessage(spec, bits: bits, needMB: need, freeMB: free,
                                     loaded: order.filter { $0 != spec.id && !pinned.contains($0) },
                                     together: order.filter { $0 != spec.id && pinned.contains($0) })
        state["refused"] = ["model": spec.id, "message": message, "at": Date().timeIntervalSince1970]; writeStatus(refreshInstalled: false)
        fputs("{\"refused\":\(jsonString(spec.id)),\"message\":\(jsonString(message))}\n", stderr)
        throw MemoryRefusal(message: message)
    }
    /// What unloading a model is expected to free: the weights MLX holds (not the whole-process footprint, which
    /// includes overhead that stays), else the load estimate (stub models).
    private func reclaim(_ id: String) -> Double {
        let resident = Double(models[id]?.residentBytes ?? 0) / 1e6
        return resident > 0 ? resident : footprint[id] ?? 0
    }
    private func installedBytes(_ id: String) -> Int? {
        ((installedCache ?? catalog.installed())[id] as? [String: Any])?["bytes"] as? Int
    }
    private func freePercent() -> Double { MemoryProbe.levelPercent() }
    /// Critical memory pressure: keep one model (the first manual one loaded, else the first loaded), unload the rest.
    private func shed() {
        let keep = order.first { residency[$0] == .manual } ?? order.first
        let level = freePercent()
        for id in evictionOrder() where id != keep && !pinned.contains(id) { evict(id, reason: "memory pressure (kern.memorystatus_level \(Int(level))%)") }
        Memory.clearCache(); state["shed_at"] = Date().timeIntervalSince1970; state["idle_unloaded"] = true; writeStatus()
        fputs("{\"shed\":true,\"kept\":\(order),\"free_pct\":\(level)}\n", stderr)
    }
    /// Every 30 s: pressure shed/trim, then Keep Hot per model — a model idle (no request since its last use or load)
    /// longer than its class's window unloads; the next request loads it again.
    func idleTick() {
        locked {
            let free = freePercent()
            if order.count > 1 && free < shedPercent && state["loading"] is NSNull { shed(); return }
            if free < trimPercent { Memory.clearCache() }
            guard state["loading"] is NSNull else { return }
            let now = Date().timeIntervalSince1970
            var unloaded = false
            for id in order where !pinned.contains(id) {
                let cls = residency[id] ?? .onDemand
                let minutes = cls == .manual ? manualIdle : onDemandIdle
                guard minutes > 0, now - (lastUsed[id] ?? now) > Double(minutes) * minuteSeconds else { continue }
                evict(id, reason: "idle: unused for \(minutes) min (\(cls == .manual ? "manually loaded" : "loaded on demand"))")
                unloaded = true
            }
            if unloaded { state["idle_unloaded"] = true; writeStatus() }
        }
    }
    /// The item's original JSON type travels with its text: Von formats a dict as key: value lines, but a string that
    /// happens to look like JSON stays the string (SDK _format_state).
    private func item(_ raw: Any, ordered: OrderedJSON?) -> Item {
        if let ordered {
            switch ordered {
            case .string(let text): return Item(text: text, kind: .text)
            case .object: return Item(text: ordered.render(), kind: .object)
            default: return Item(text: ordered.render(), kind: .value)
            }
        }
        if let text = raw as? String { return Item(text: text, kind: .text) }
        return Item(text: jsonString(raw), kind: raw is [String: Any] ? .object : .value)
    }
    private func containsMedia(_ raw: Any) -> Bool {
        guard let dict = raw as? [String: Any] else { return false }
        return dict.keys.contains { ["image", "images", "audio", "video", "videos"].contains($0) }
    }
    private func jsonString(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject([obj]), let bytes = try? JSONSerialization.data(withJSONObject: [obj], options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]), let str = String(data: bytes, encoding: .utf8) else { return String(describing: obj) }
        return String(str.dropFirst().dropLast())
    }
    /// Questions from the order-preserving parse, looked up by exact key bytes: Foundation/Swift dictionaries would
    /// fold ids (and labels) that differ only by Unicode normalization into one.
    private func questions(_ raw: [String: Any], ordered: OrderedJSON?) throws -> [Question] {
        guard let fields = ordered?.fields else { throw ServiceError("questions must be a nonempty object") }
        return try fields.map { id, q in
            guard let name = q["type"]?.text, let kind = QuestionKind(rawValue: name) else {
                throw ServiceError("Unknown question type '\(q["type"].map { $0.text ?? $0.render() } ?? "")'")
            }
            var criteria: [(String, String)] = []
            if let entries = q["criteria"]?.fields {
                // null means "no description" (the Von SDK and Laya's reference both use the bare label then).
                criteria = entries.map { ($0.0, $0.1.isNull ? "" : ($0.1.text ?? $0.1.render())) }
            } else if let values = q["criteria"]?.arrayValues {
                let labels = values.compactMap(\.text)
                if labels.count == values.count { criteria = labels.map { ($0, $0) } }
            }
            return Question(id: id, kind: kind, instructions: q["instructions"]?.text ?? "", criteria: criteria, sourceJSON: q.render())
        }
    }
    private func answer(_ a: Answer) -> [String: Any] {
        var out: [String: Any] = [:]
        if let v = a.choice { out["choice"] = v }
        if let v = a.probabilities {
            // NSString keys compare literally, so byte-distinct labels ("é" / "e\u{301}") stay two JSON keys.
            let labelled = NSMutableDictionary()
            for (label, p) in v { labelled[NSString(string: label)] = p }
            out["probabilities"] = labelled
        }
        if let v = a.confidence { out["confidence"] = v }
        if let v = a.noul { out["noul"] = v }
        if let v = a.score { out["score"] = v }
        if let v = a.calibrated { out["calibrated"] = v }
        return out
    }
    private func english(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return letters.isEmpty || Double(letters.filter { $0.value < 128 }.count) / Double(letters.count) > 0.995
    }
    private func pick(_ raw: Any, requested: String) throws -> String {
        if requested != "auto" && !requested.isEmpty { return requested }
        return english((raw as? String) ?? jsonString(raw)) ? "laya-english" : "laya-multilingual"
    }
    private func judge(_ body: [String: Any], ordered: OrderedJSON?) throws -> [String: Any] {
        guard let items = body["items"] as? [Any], !items.isEmpty else { throw ServiceError("items must be a nonempty list") }
        guard let rawQuestions = body["questions"] as? [String: Any], !rawQuestions.isEmpty else { throw ServiceError("questions must be a nonempty object") }
        let qs = try questions(rawQuestions, ordered: ordered?["questions"]), requested = body["model"] as? String ?? "auto"
        let orderedItems = ordered?["items"]?.arrayValues ?? []
        var groups: [String: [Int]] = [:], modelOrder: [String] = []
        var results = Array(repeating: [String: Any](), count: items.count)
        for (index, item) in items.enumerated() {
            if containsMedia(item) {
                results[index] = ["error": "Verdict judges text; image, audio and video items are not supported.", "model": NSNull(), "ms": 0]
                continue
            }
            let id = try pick(item, requested: requested)
            if groups[id] == nil { modelOrder.append(id) }
            groups[id, default: []].append(index)
        }
        // bits: the precision every model this request uses runs at (like /load bits: a model stays at it while it
        // stays loaded). Validated for all of them before anything loads; null is the same as omitted.
        var requestedBits: [String: Int] = [:]
        if let raw = body["bits"], let bits = try wholeNumber(raw, "bits") {
            for id in modelOrder { requestedBits[id] = try validBits(bits, for: id) }
        }
        // Every model this request needs is in flight until it returns: loading a later one never evicts an earlier one.
        pinned = Set(modelOrder); defer { pinned = [] }
        for id in modelOrder {
            if let bits = requestedBits[id] {
                let spec = try catalog.spec(id)
                if models[id] == nil {
                    _ = try load(id, as: .onDemand, bits: bits)
                } else if spec.effectiveBits(loadedBits[id] ?? 0) != spec.effectiveBits(bits) {
                    try reload(id, bits: bits, as: residency[id] == .manual ? .manual : .onDemand)
                }
            }
            let agent = try load(id, as: .onDemand), indexes = groups[id]!
            func modelItem(_ index: Int) -> Item { item(items[index], ordered: orderedItems.indices.contains(index) ? orderedItems[index] : nil) }
            let start = Date()
            let answers = try predict(agent, id, indexes.map(modelItem), qs)
            guard answers.count == indexes.count else { throw ServiceError("Model returned wrong result count") }
            let accepted = answers.reduce(0) { count, result in
                if case .answers = result { return count + 1 }
                return count
            }
            let per = (Date().timeIntervalSince(start) * 10000 / Double(max(1, accepted))).rounded() / 10
            for (index, result) in zip(indexes, answers) { results[index] = resultObject(result, id, per) }
            lastUsed[id] = Date().timeIntervalSince1970; updateEntry(id)
            state["calls"] = (state["calls"] as? Int ?? 0) + 1
            state["items"] = (state["items"] as? Int ?? 0) + accepted; state["last_ms"] = per
        }
        state["last_used"] = Date().timeIntervalSince1970; state["idle_unloaded"] = false
        if Memory.cacheMemory > cacheLimit * 1_000_000 { Memory.clearCache() }
        let w = ContinuousClock.now
        writeStatus(refreshInstalled: false, background: true)
        if ProcessInfo.processInfo.environment["VERDICT_PROFILE"] == "1" { FileHandle.standardError.write(Data("profile status-write \(ContinuousClock.now - w)\n".utf8)) }
        return ["results": results]
    }
    /// Runs a request. If the optimized path throws or returns non-finite outputs, the request reruns on the stock
    /// path. When that succeeds the optimized path was at fault: the model stays on stock for the rest of its loaded
    /// lifetime (status engine "mlx" with the reason) and the switch is logged. When the stock run fails too, the
    /// request itself was at fault: the model returns to its optimized path and the stock run's error is reported.
    private func predict(_ agent: DecisionModel, _ id: String, _ items: [Item], _ qs: [Question]) throws -> [ItemResult] {
        guard let paths = agent as? InferencePathSwitching, paths.optimizedPathActive else { return try Self.finite(agent.predict(items, qs)) }
        let failure: Error
        do { return try Self.finite(agent.predict(items, qs)) } catch { failure = error }
        do { try paths.useStockPath(true) } catch {
            fputs("{\"stock_fallback\":\"\(id)\",\"unavailable\":\(jsonString(Self.message(error)))}\n", stderr)
            throw failure
        }
        do {
            let answers = try Self.finite(agent.predict(items, qs))
            let reason = String(Self.message(failure).prefix(200))
            fallbacks[id] = reason
            if let spec = try? catalog.spec(id) {
                let bits = ((state["models"] as? [String: Any])?[id] as? [String: Any])?["bits"] as? Int ?? 0
                describe(id, agent, runtime: spec.runtime, bits: bits)
            }
            writeStatus(refreshInstalled: false)
            fputs("{\"stock_fallback\":\"\(id)\",\"reason\":\(jsonString(reason))}\n", stderr)
            return answers
        } catch {
            try? paths.useStockPath(false)
            throw error
        }
    }
    /// Every answer value must be finite: a NaN is a failed run, never a probability.
    static func finite(_ results: [ItemResult]) throws -> [ItemResult] {
        for case .answers(let answers) in results {
            for (_, a) in answers {
                let values = [a.confidence, a.noul, a.score].compactMap { $0 } + (a.probabilities?.values ?? [])
                guard values.allSatisfy(\.isFinite) else { throw ServiceError("Non-finite model outputs") }
            }
        }
        return results
    }
    private func resultObject(_ result: ItemResult, _ id: String, _ ms: Double) -> [String: Any] {
        switch result {
        case .error(let message): return ["error": message, "model": id, "ms": 0]
        case .answers(let answers):
            // NSString keys compare literally: question ids that differ only by normalization stay two keys.
            let byID = NSMutableDictionary()
            for (question, a) in answers { byID[NSString(string: question)] = answer(a) }
            return ["answers": byID, "model": id, "ms": ms]
        }
    }
    /// A whole number from a request field: a JSON integer (4, 4.0 and 4e0 are the same number) or its string form
    /// (the app's control bodies are strings). null is nil (the field is treated as omitted). Fractions (4.9), booleans,
    /// arrays, objects and out-of-range values are refused, never truncated.
    func wholeNumber(_ raw: Any, _ name: String) throws -> Int? {
        if raw is NSNull { return nil }
        let refused = ServiceError("\(name) must be a whole number, not \(Self.literal(raw))")
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { throw refused }
            if let exact = Int(exactly: number.int64Value), NSNumber(value: exact) == number { return exact }
            let value = number.doubleValue
            guard value.isFinite, value == value.rounded(), let exact = Int(exactly: value) else { throw refused }
            return exact
        }
        if let string = raw as? String, let value = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) { return value }
        throw refused
    }
    /// A request value as the client wrote it, for error messages: 4.9, true, "4.5", [4].
    static func literal(_ raw: Any) -> String {
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return String(describing: raw) }
        return text
    }
    /// The app version, reported in /v1/status as "version": the enclosing Verdict.app's Info.plist, or for a helper
    /// run from a build directory, the checkout's Resources/Info.plist.
    static let appVersion: String? = {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return v }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return NSDictionary(contentsOf: root.appendingPathComponent("Resources/Info.plist"))?["CFBundleShortVersionString"] as? String
    }()
    /// Public API version, reported in /v1/status as "api". Bumped only for incompatible changes to /v1.
    static let apiVersion = 1
    /// Public endpoints are served under /v1 and, for older clients, at their original unversioned paths.
    /// /shed, /trim and /quit are internal (the app's memory-pressure hooks and shutdown): unversioned only.
    static let publicRoutes: Set<String> = ["/status", "/judge", "/load", "/unload", "/delete", "/settings"]
    static let versionedOnly: Set<String> = ["/models"]
    static let internalRoutes: Set<String> = ["/shed", "/trim", "/quit"]
    /// Request path -> route ("/v1/judge" and "/judge" -> "/judge"); nil for anything not served.
    static func route(_ path: String) -> String? {
        let bare = String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        if bare.hasPrefix("/v1/") {
            let route = String(bare.dropFirst(3))
            return publicRoutes.contains(route) || versionedOnly.contains(route) ? route : nil
        }
        return publicRoutes.contains(bare) || internalRoutes.contains(bare) ? bare : nil
    }
    /// config.json precision choices (id -> bits, 0 = native), as the app's Models table last saved them. Reread on
    /// every call, so a choice made while the helper runs applies to the next load.
    private func selectedPrecision() -> [String: Int] {
        guard let data = try? Data(contentsOf: support.appendingPathComponent("config.json")),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return (config["precision"] as? [String: Any] ?? [:]).compactMapValues { try? wholeNumber($0, "bits") }
    }
    /// The recommended precision (effective bits): VerdictCore's rule over benchmarks.json, else models.json default_bits.
    private func recommendedBits(_ spec: ModelSpec) -> Int {
        ModelsView.recommended(catalog.benchmarks[spec.id], runtime: spec.runtime) ?? spec.effectiveBits(spec.defaultBits)
    }
    /// The one rule for a load without bits (helper bits, 0 = native), which /v1/models reports as precision.selected:
    /// the launch override (VERDICT_PRECISION), else the app's saved choice (config.json), else the recommended
    /// precision. A choice this model cannot run is skipped. Explicit bits (/load, /judge) apply to that load only.
    private func implicitBits(_ spec: ModelSpec, config: [String: Int]? = nil) -> Int {
        let allowed = Self.precisions[spec.runtime]?.0
        for choice in [launchPrecision[spec.id], (config ?? selectedPrecision())[spec.id]] {
            if let bits = choice, allowed?.contains(bits) ?? true { return bits }
        }
        let recommended = recommendedBits(spec)
        return recommended == spec.nativeBits ? 0 : recommended   // helper bits store the native precision as 0
    }
    /// Validates a precision for `id` without touching state.
    private func validBits(_ bits: Int, for id: String) throws -> Int {
        let spec = try catalog.spec(id)
        if let rule = Self.precisions[spec.runtime], !rule.0.contains(bits) { throw ServiceError("\(id): \(rule.1)") }
        return bits
    }
    /// Loads `id` at `bits` (already validated), replacing a loaded precision. Memory is checked before the loaded
    /// precision is dropped (what unloading it frees counts): a refusal changes nothing. If the new precision fails
    /// after the old one was unloaded (a refusal on re-measure, a load error), the working model is put back as it was
    /// and the original failure is reported.
    private func reload(_ id: String, bits: Int, as cls: Residency) throws {
        let spec = try catalog.spec(id)
        let loadedClass = residency[id], previous = loadedBits[id]
        if models[id] != nil { try admit(spec, bits: bits, credit: reclaim(id)) }
        unload(id)
        do { _ = try load(id, as: cls, bits: bits) } catch {
            if let loadedClass { restore(id, as: loadedClass, bits: previous) }
            throw error
        }
    }
    func request(_ method: String, _ path: String, _ body: [String: Any], rawBody: Data? = nil) -> (Int, [String: Any]) {
        do {
            return try locked {
                guard let route = Self.route(path) else { return (404, ["error": "not found: \(method) \(path)"]) }
                if method == "GET" {
                    switch route {
                    case "/status": return (200, state.merging(["catalog": catalog.raw, "installed": catalog.installed(), "memory": memory()]) { _, new in new })
                    case "/models":
                        let config = selectedPrecision()
                        var selected: [String: Int] = [:], recommended: [String: Int] = [:]
                        for spec in catalog.entries where !spec.repository.isEmpty {
                            selected[spec.id] = spec.effectiveBits(implicitBits(spec, config: config))
                            recommended[spec.id] = recommendedBits(spec)
                        }
                        let view = ModelsView.build(catalog: catalog.raw, benchmarks: catalog.benchmarks, loaded: state["models"] as? [String: Any] ?? [:],
                                                    installed: catalog.installed(), selected: selected, recommended: recommended)
                        return (200, ["models": view])
                    default: return (404, ["error": "\(path) takes POST"])
                    }
                }
                if method != "POST" { return (404, ["error": "not found: \(method) \(path)"]) }
                switch route {
                case "/judge":
                    var parser = OrderedJSONParser(rawBody ?? Data("{}".utf8))
                    return (200, try judge(body, ordered: parser.parse()))
                case "/load":
                    guard let id = body["model"] as? String else { throw ServiceError("'model'") }
                    guard let manual = flag(body["manual"] ?? false) else { throw ServiceError("manual must be true or false") }
                    // The app's menu sends manual; agents and scripts load on demand. A reload keeps a manual model manual.
                    let cls: Residency = manual || residency[id] == .manual ? .manual : .onDemand
                    if let raw = body["bits"], let bits = try wholeNumber(raw, "bits") {
                        // Validate model and precision before touching state: a bad request must neither unload the
                        // working model nor leave an unusable precision behind.
                        try reload(id, bits: try validBits(bits, for: id), as: cls)
                        return (200, ["loaded": order])
                    }
                    _ = try load(id, as: cls); return (200, ["loaded": order])
                case "/unload":
                    guard let id = body["model"] as? String else { throw ServiceError("'model'") }
                    unload(id); state["refused"] = NSNull(); writeStatus(refreshInstalled: false)
                    return (200, ["loaded": order])
                case "/delete":
                    guard let id = body["model"] as? String else { throw ServiceError("'model'") }
                    guard let spec = catalog.entries.first(where: { $0.id == id }) else { throw ServiceError("'\(id)'") }
                    unload(id); catalog.delete(spec); state.removeValue(forKey: "error"); writeStatus()
                    return (200, ["installed": catalog.installed()])
                case "/settings":
                    // Validate everything before changing anything. idle_minutes (older clients) is the manual window.
                    var minutes: [String: Int] = [:]
                    for key in ["idle_minutes", "manual_idle_minutes", "on_demand_idle_minutes"] {
                        guard let raw = body[key] else { continue }
                        guard let value = try wholeNumber(raw, key) else { continue }
                        guard value >= 0 else { throw ServiceError("\(key) must be 0 or more, not \(value)") }
                        minutes[key] = value
                    }
                    var swap: Bool?
                    if let raw = body["allow_swap"] {
                        guard let value = flag(raw) else { throw ServiceError("allow_swap must be true or false") }
                        swap = value
                    }
                    if let v = minutes["idle_minutes"] { manualIdle = v }
                    if let v = minutes["manual_idle_minutes"] { manualIdle = v }
                    if let v = minutes["on_demand_idle_minutes"] { onDemandIdle = v }
                    if let swap { allowSwap = swap; state["refused"] = NSNull() }
                    publishSettings()
                    state["last_used"] = Date().timeIntervalSince1970; writeStatus()
                    // A body with only idle_minutes gets the reply older clients compare against.
                    let legacyOnly = !body.keys.contains { ["manual_idle_minutes", "on_demand_idle_minutes", "allow_swap"].contains($0) }
                    return (200, legacyOnly ? ["idle_minutes": manualIdle] : settings)
                case "/shed": shed(); return (200, ["loaded": order])
                case "/trim": Memory.clearCache(); return (200, ["ok": true])
                case "/quit": quitting = true; return (200, ["bye": true])
                default: return (404, ["error": "\(path) takes GET"])
                }
            }
        } catch let refusal as MemoryRefusal { return (507, ["error": refusal.message]) }
        catch { return (400, ["error": Self.message(error).prefix(500).description]) }
    }
    /// Reloads a model at its previous precision after a failed reload, keeping the failed attempt's refusal/error
    /// in /status. If that fails too, the model stays unloaded and the log says why.
    private func restore(_ id: String, as cls: Residency, bits: Int?) {
        let refused = state["refused"], failure = state["error"]
        do { _ = try load(id, as: cls, bits: bits) }
        catch { fputs("{\"restore_failed\":\(jsonString(id)),\"error\":\(jsonString(Self.message(error)))}\n", stderr) }
        state["refused"] = refused; state["error"] = failure; writeStatus(refreshInstalled: false)
    }
    /// JSON true/false, 1/0 or the strings "true"/"false"/"1"/"0" (the app's control body is strings).
    private func flag(_ raw: Any) -> Bool? {
        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String { return ["true": true, "1": true, "false": false, "0": false][string.lowercased()] }
        return nil
    }
    /// Precisions each loader accepts, checked before a /load mutates anything.
    static let precisions: [String: (Set<Int>, String)] = ["laya": (LayaModel.precisions, LayaModel.precisionMessage),
                                                          "von": (VonModel.precisions, VonModel.precisionMessage)]
    /// Engine errors carry their own text (`invalid("…")` would otherwise leak into the message).
    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
