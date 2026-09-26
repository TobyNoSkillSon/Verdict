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

    /// The recommended precision (effective bits) for a benchmarks.json entry; nil when the native one is unmeasured.
    static func recommended(_ entry: Any?, runtime: String) -> Int? {
        let native = nativeBits(runtime: runtime)
        return recommended(precisions(entry, native: native).1, native: native, options: precisionOptions(runtime: runtime))
    }

    /// `selected`: effective bits a load without bits uses, and `recommended`: the recommended effective bits, per
    /// loadable model, both from the helper's one resolution rule (Service.implicitBits / recommendedBits).
    static func build(catalog: [[String: Any]], benchmarks: [String: Any], loaded: [String: Any], installed: [String: Any],
                      selected: [String: Int], recommended recommendedByID: [String: Int]) -> [[String: Any]] {
        catalog.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let repository = m["repository"] as? String ?? ""
            let hosted = repository.isEmpty
            let runtime = m["runtime"] as? String
            let native = nativeBits(runtime: runtime), options = precisionOptions(runtime: runtime)
            var (defaultBits, results) = precisions(benchmarks[id], native: native)
            if !hosted { defaultBits = recommendedByID[id] ?? recommended(results, native: native, options: options) ?? native }
            let effective = { (bits: Int) in bits == 0 ? native : bits }
            let selection = hosted ? defaultBits : selected[id] ?? defaultBits
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

    /// GET /v1/models: TypeSafe's `{"models": [{"name", "description", "release_date"}]}` listing every name the
    /// `model` field accepts — the `auto` alias first, then each local model (with all of the fields above; `name` is
    /// its id, `display_name` the human name) — plus `references`: hosted models shown for comparison that Verdict
    /// does not serve (Jev). Catalog clients skip the entry with `"alias": true`.
    static func listing(_ view: [[String: Any]], catalog: [[String: Any]]) -> [String: Any] {
        func raw(_ id: String) -> [String: Any] { catalog.first { $0["id"] as? String == id } ?? [:] }
        func described(_ entry: [String: Any]) -> [String: Any] {
            var out = entry
            let id = entry["id"] as? String ?? ""
            let m = raw(id)
            out["display_name"] = entry["name"] ?? id
            out["name"] = id
            out["release_date"] = m["release_date"] as? String ?? ""
            var facts: [String] = []
            if let backbone = m["backbone"] as? String, backbone != "closed" { facts.append(backbone + ((m["params"] as? String).map { " (\($0))" } ?? "")) }
            if let languages = m["languages"] as? String { facts.append(languages) }
            if let context = m["context"] as? Int { facts.append("\(context.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))) tokens") }
            let summary = [m["recommendation"] as? String, facts.isEmpty ? nil : facts.joined(separator: ", ") + "."].compactMap { $0 }.joined(separator: " ")
            out["description"] = "\(entry["name"] as? String ?? id): \(summary)"
            return out
        }
        let local = view.filter { $0["loadable"] as? Bool == true }.map(described)
        let hosted = view.filter { $0["loadable"] as? Bool != true }.map(described)
        let autoTargets = ["laya-english", "laya-multilingual"]
        let released = autoTargets.compactMap { raw($0)["release_date"] as? String }.max() ?? ""
        let about = "Alias: laya-english for English text (letters at least 99.5% ASCII), laya-multilingual for anything else."
        // The alias also carries every field of a catalog entry (neutral values), so clients written before the System
        // One listing, which read those fields from each entry, keep working (api stays 1).
        let alias: [String: Any] = ["name": "auto", "alias": true, "release_date": released, "description": about,
                                    "id": "auto", "display_name": "Auto", "family": NSNull(), "inputs": ["text"], "params": NSNull(),
                                    "context": NSNull(), "languages": NSNull(), "license": NSNull(), "state": "alias", "loadable": false,
                                    "precision": NSNull(), "benchmark": NSNull(), "benchmarks": [String: Any](), "links": [String: Any](),
                                    "recommendation": about]
        return ["models": [alias] + local, "references": hosted]
    }
}

