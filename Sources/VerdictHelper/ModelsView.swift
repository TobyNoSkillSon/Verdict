import Foundation
import VerdictCore

/// GET /v1/models: every catalog model with its state, measured figures at each precision (deltas against the
/// recommended precision), the precision a load uses, and links. Clients print this; none recompute it.
enum ModelsView {
    /// benchmarks.json entry -> (default bits, bits -> raw result). The older flat shape is one result at its default.
    static func precisions(_ entry: Any?, native: Int) -> (Int, [Int: [String: Any]]) {
        guard let entry = entry as? [String: Any] else { return (native, [:]) }
        let declared = (entry["default_bits"] as? NSNumber)?.intValue
        let fallback = declared.flatMap { $0 == 0 ? nil : $0 }
        guard let raw = entry["precisions"] else { return (fallback ?? native, [fallback ?? 16: entry]) }
        var out: [Int: [String: Any]] = [:]
        for (key, value) in raw as? [String: Any] ?? [:] {
            if let bits = Int(key), let result = value as? [String: Any] { out[bits] = result }
        }
        return (fallback ?? native, out)
    }

    /// Figures at one precision against the recommended one, as short strings; empty when either side is unmeasured.
    static func deltas(_ result: [String: Any], base: [String: Any]?) -> [String: String] {
        func number(_ dict: [String: Any]?, _ key: String) -> Double? { (dict?[key] as? NSNumber)?.doubleValue }
        var out: [String: String] = [:]
        out["accuracy"] = accuracyDelta(number(result, "accuracy"), base: number(base, "accuracy"))?.text
        out["ece"] = eceDelta(number(result, "ece"), base: number(base, "ece"))?.text
        out["speed"] = speedDelta(number(result, "ms"), base: number(base, "ms"))?.text
        out["energy"] = energyDelta(number(result, "j_per_1k"), base: number(base, "j_per_1k"))?.text
        return out
    }

    /// The recommended precision by VerdictCore's rule (lowest energy within 0.5 points of the native accuracy).
    static func recommended(_ results: [Int: [String: Any]], native: Int, options: [Int]) -> Int? {
        var decoded: [Int: BenchmarkResult] = [:]
        for (bits, raw) in results {
            guard let data = try? JSONSerialization.data(withJSONObject: raw),
                  let result = try? JSONDecoder().decode(BenchmarkResult.self, from: data) else { continue }
            decoded[bits] = result
        }
        return recommendedBits(ModelBenchmark(default_bits: nil, precisions: decoded), native: native, options: options)
    }

    /// `selected`: config.json precision choices (id -> bits, 0 = native).
    static func build(catalog: [[String: Any]], benchmarks: [String: Any], loaded: [String: Any], installed: [String: Any],
                      selected: [String: Int]) -> [[String: Any]] {
        catalog.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let repository = m["repository"] as? String ?? ""
            let hosted = repository.isEmpty
            let runtime = m["runtime"] as? String
            let native = nativeBits(runtime: runtime), options = precisionOptions(runtime: runtime)
            var (defaultBits, results) = precisions(benchmarks[id], native: native)
            if !hosted { defaultBits = recommended(results, native: native, options: options) ?? native }
            let effective = { (bits: Int) in bits == 0 ? native : bits }
            let selection = hosted ? defaultBits : selected[id].map(effective) ?? defaultBits
            let loadedEntry = loaded[id] as? [String: Any]
            let base = results[defaultBits]
            var all: [String: Any] = [:]
            for (bits, result) in results {
                var entry = result
                if bits != defaultBits { entry["deltas"] = deltas(result, base: base) }
                all[String(bits)] = entry
            }
            let state = loadedEntry != nil ? "hot" : installed[id] != nil ? "downloaded" : hosted ? "hosted" : "available"
            var links = m["links"] as? [String: Any] ?? [:]
            let family = links.removeValue(forKey: "family")
            var precision: Any = NSNull()
            if !hosted {
                precision = ["selected": selection, "default": defaultBits, "options": options,
                             "loaded": loadedEntry.map { effective(($0["bits"] as? NSNumber)?.intValue ?? 0) } as Any? ?? NSNull()]
            }
            return ["id": id, "name": m["name"] ?? id, "family": family ?? NSNull(), "inputs": m["inputs"] ?? ["text"],
                    "params": m["params"] ?? NSNull(), "context": m["context"] ?? NSNull(), "languages": m["languages"] ?? NSNull(),
                    "license": m["license"] ?? NSNull(), "state": state, "loadable": !hosted, "precision": precision,
                    "benchmark": all[String(selection)] ?? NSNull(), "benchmarks": all, "links": links,
                    "recommendation": m["recommendation"] ?? NSNull()]
        }
    }
}
