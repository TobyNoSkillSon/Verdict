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
    private var precision: [String: Int] = [:]
    private var state: [String: Any]
    private let cacheLimit: Int
    private let shedPercent: Double
    private let trimPercent: Double
    private var lastRSS: (Double, Double) = (0, 0)
    var quitting = false

    init() throws {
        catalog = try Catalog()
        let env = ProcessInfo.processInfo.environment
        support = URL(fileURLWithPath: env["VERDICT_SUPPORT_DIR"] ?? ((env["HOME"] ?? NSHomeDirectory()) + "/Library/Application Support/Verdict"), isDirectory: true)
        cacheLimit = Int(env["VERDICT_CACHE_LIMIT_MB"] ?? "") ?? 1024
        shedPercent = Double(env["VERDICT_SHED_FREE_PCT"] ?? "") ?? 8
        trimPercent = Double(env["VERDICT_TRIM_FREE_PCT"] ?? "") ?? 15
        if let data = env["VERDICT_PRECISION"]?.data(using: .utf8), let p = try? JSONSerialization.jsonObject(with: data) as? [String: Int] { precision = p }
        let now = Date().timeIntervalSince1970
        state = ["models": [:], "calls": 0, "items": 0, "last_ms": NSNull(), "started": now, "port": NSNull(), "pid": Int(getpid()), "loading": NSNull(), "error": NSNull(), "last_used": now, "idle_minutes": Int(env["VERDICT_IDLE_MINUTES"] ?? "") ?? 0, "gpu": Self.gpu]
        Memory.cacheLimit = cacheLimit * 1024 * 1024
    }
    func start(port: Int) { locked { state["port"] = port; writeStatus() } }
    func finish() { locked { state["models"] = [:]; state["port"] = NSNull(); writeStatus() }; flushStatus() }
    func preload() {
        for id in (ProcessInfo.processInfo.environment["VERDICT_PRELOAD"] ?? "").split(separator: ",") {
            do { try locked { _ = try load(String(id)) } }
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
        return ["rss_mb": lastRSS.1, "mlx_active_mb": (Double(Memory.activeMemory) / 1e6).rounded(), "mlx_cache_mb": (Double(Memory.cacheMemory) / 1e6).rounded()]
    }
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
        else { out["matmul"] = runtime == "von" ? "f32 (by design)" : "\(bits)-bit (regular GPU path)" }
        out["optimized"] = fast
        return out
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
        return ["architecture": arch, "generation": gen, "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", "neural_accelerators": nax]
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
    private func load(_ id: String) throws -> DecisionModel {
        if let existing = models[id] { return existing }
        let spec = try catalog.spec(id)
        // Do not download weights if no production loader is registered.
        let type = try loader(runtime: spec.runtime)
        state["loading"] = id; state["downloading"] = catalog.cached(spec) == nil; state["error"] = NSNull(); writeStatus()
        let start = Date()
        do {
            let snapshot = ProcessInfo.processInfo.environment["VERDICT_STUB_MODELS"] == "1" ? support : try catalog.snapshot(spec)
            let bits = precision[id] ?? 0
            let agent = try type.load(id: id, snapshot: snapshot, bits: bits)
            models[id] = agent; order.append(id)
            var active = state["models"] as? [String: Any] ?? [:]
            active[id] = ["device": "mlx", "load_s": (Date().timeIntervalSince(start) * 10).rounded() / 10, "bits": bits]
            if let path = (agent as? KernelPathReporting)?.kernelPath, var entry = active[id] as? [String: Any] { entry["kernel"] = path; active[id] = entry }
            if var entry = active[id] as? [String: Any] { entry["optimizations"] = Self.optimizations(agent, runtime: spec.runtime, bits: bits); active[id] = entry }
            state["models"] = active; state["loading"] = NSNull(); state["downloading"] = false; writeStatus()
            return agent
        } catch {
            state["loading"] = NSNull(); state["downloading"] = false
            state["error"] = "\(id): \(String(describing: error).prefix(200))"; writeStatus()
            throw error
        }
    }
    private func unload(_ id: String) {
        models.removeValue(forKey: id); order.removeAll { $0 == id }
        var active = state["models"] as? [String: Any] ?? [:]; active.removeValue(forKey: id); state["models"] = active
        Memory.clearCache(); writeStatus()
    }
    private func freePercent() -> Double {
        var value: Int32 = 100; var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_level", &value, &size, nil, 0) == 0 ? Double(value) : 100
    }
    private func shed() {
        for id in Array(order.dropFirst()) { unload(id) }
        Memory.clearCache(); state["shed_at"] = Date().timeIntervalSince1970; state["idle_unloaded"] = true; writeStatus()
        fputs("{\"shed\":true,\"kept\":\(order),\"free_pct\":\(freePercent())}\n", stderr)
    }
    func idleTick() {
        locked {
            let free = freePercent()
            if order.count > 1 && free < shedPercent && state["loading"] is NSNull { shed(); return }
            if free < trimPercent { Memory.clearCache() }
            let minutes = state["idle_minutes"] as? Int ?? 0
            if minutes > 0 && !order.isEmpty && Date().timeIntervalSince1970 - (state["last_used"] as? Double ?? 0) > Double(minutes * 60) && state["loading"] is NSNull {
                for id in Array(order) { unload(id) }
                state["idle_unloaded"] = true; writeStatus()
            }
        }
    }
    private func item(_ raw: Any, ordered: OrderedJSON?) -> Item {
        if let ordered { return Item(text: ordered.text ?? ordered.render()) }
        return Item(text: (raw as? String) ?? jsonString(raw))
    }
    private func containsMedia(_ raw: Any) -> Bool {
        guard let dict = raw as? [String: Any] else { return false }
        return dict.keys.contains { ["image", "images", "audio", "video", "videos"].contains($0) }
    }
    private func jsonString(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject([obj]), let bytes = try? JSONSerialization.data(withJSONObject: [obj], options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]), let str = String(data: bytes, encoding: .utf8) else { return String(describing: obj) }
        return String(str.dropFirst().dropLast())
    }
    private func questions(_ raw: [String: Any], ordered: OrderedJSON?) throws -> [Question] {
        let ids = ordered?.fields?.map(\.0) ?? raw.keys.sorted()
        return try ids.map { id in
            guard let q = raw[id] as? [String: Any], let name = q["type"] as? String, let kind = QuestionKind(rawValue: name) else { throw ServiceError("Unknown question type '\((raw[id] as? [String: Any])?["type"] ?? "")'") }
            var criteria: [(String, String)] = []
            if let fields = ordered?[id]?["criteria"]?.fields {
                criteria = fields.map { ($0.0, $0.1.text ?? $0.1.render()) }
            } else if let values = q["criteria"] as? [String: String] { criteria = values.keys.sorted().map { ($0, values[$0]!) } }
            else if let values = q["criteria"] as? [String] { criteria = values.map { ($0, $0) } }
            return Question(id: id, kind: kind, instructions: q["instructions"] as? String ?? "", criteria: criteria, sourceJSON: ordered?[id]?.render())
        }
    }
    private func answer(_ a: Answer) -> [String: Any] {
        var out: [String: Any] = [:]
        if let v = a.choice { out["choice"] = v }
        if let v = a.probabilities { out["probabilities"] = v }
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
        for id in modelOrder {
            let agent = try load(id), indexes = groups[id]!
            func modelItem(_ index: Int) -> Item { item(items[index], ordered: orderedItems.indices.contains(index) ? orderedItems[index] : nil) }
            let start = Date()
            let answers = try agent.predict(indexes.map(modelItem), qs)
            guard answers.count == indexes.count else { throw ServiceError("Model returned wrong result count") }
            let accepted = answers.reduce(0) { count, result in
                if case .answers = result { return count + 1 }
                return count
            }
            let per = (Date().timeIntervalSince(start) * 10000 / Double(max(1, accepted))).rounded() / 10
            for (index, result) in zip(indexes, answers) { results[index] = resultObject(result, id, per) }
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
    private func resultObject(_ result: ItemResult, _ id: String, _ ms: Double) -> [String: Any] {
        switch result {
        case .error(let message): return ["error": message, "model": id, "ms": 0]
        case .answers(let answers): return ["answers": answers.mapValues(answer), "model": id, "ms": ms]
        }
    }
    private func integer(_ raw: Any?) -> Int? {
        if raw is NSNull { return 0 }
        if let number = raw as? NSNumber { return number.intValue }
        if let string = raw as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
    func request(_ method: String, _ path: String, _ body: [String: Any], rawBody: Data? = nil) -> (Int, [String: Any]) {
        do {
            return try locked {
                if method == "GET" { return path == "/status" ? (200, state.merging(["catalog": catalog.raw, "installed": catalog.installed(), "memory": memory()]) { _, new in new }) : (404, ["error": "not found"]) }
                if method != "POST" { return (404, ["error": "not found"]) }
                switch path {
                case "/judge":
                    var parser = OrderedJSONParser(rawBody ?? Data("{}".utf8))
                    return (200, try judge(body, ordered: parser.parse()))
                case "/load":
                    guard let id = body["model"] as? String else { throw ServiceError("'model'") }
                    if body["bits"] != nil {
                        guard let bits = integer(body["bits"]) else { throw ServiceError("invalid literal for int() with base 10: '\(body["bits"]!)'") }
                        precision[id] = bits; unload(id)
                    }
                    _ = try load(id); return (200, ["loaded": order])
                case "/unload":
                    guard let id = body["model"] as? String else { throw ServiceError("'model'") }
                    unload(id); return (200, ["loaded": order])
                case "/delete":
                    guard let id = body["model"] as? String else { throw ServiceError("'model'") }
                    guard let spec = catalog.entries.first(where: { $0.id == id }) else { throw ServiceError("'\(id)'") }
                    unload(id); catalog.delete(spec); state.removeValue(forKey: "error"); writeStatus()
                    return (200, ["installed": catalog.installed()])
                case "/settings":
                    if let raw = body["idle_minutes"], let minutes = integer(raw) { state["idle_minutes"] = minutes }
                    else if body["idle_minutes"] == nil { state["idle_minutes"] = state["idle_minutes"] as? Int ?? 0 }
                    else { throw ServiceError("invalid literal for int() with base 10: '\(body["idle_minutes"]!)'") }
                    state["last_used"] = Date().timeIntervalSince1970; writeStatus(); return (200, ["idle_minutes": state["idle_minutes"]!])
                case "/shed": shed(); return (200, ["loaded": order])
                case "/trim": Memory.clearCache(); return (200, ["ok": true])
                case "/quit": quitting = true; return (200, ["bye": true])
                default: return (404, ["error": "not found"])
                }
            }
        } catch { return (400, ["error": String(describing: error).prefix(500).description]) }
    }
}
