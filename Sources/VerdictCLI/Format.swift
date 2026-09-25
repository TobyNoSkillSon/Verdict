import Foundation
import VerdictKit

/// Output formatting for the `verdict` command: one short plain line per fact. Widths count Unicode scalars (as the
/// line formats were first defined, in Python).
enum Format {
    static func fixed(_ x: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", x) }
    static func percent(_ x: Double) -> String { fixed(x * 100, 1) + "%" }
    static func left(_ s: String, _ width: Int) -> String {
        let n = s.unicodeScalars.count
        return n >= width ? s : s + String(repeating: " ", count: width - n)
    }
    static func right(_ s: String, _ width: Int) -> String {
        let n = s.unicodeScalars.count
        return n >= width ? s : String(repeating: " ", count: width - n) + s
    }
    /// A number as JSON wrote it: integral values without ".0" (the helper writes 5, not 5.0).
    static func plain(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e15 ? String(Int(x)) : "\(x)"
    }
    static func num(_ v: Double?, _ render: (Double) -> String) -> String { v.map(render) ?? "—" }
    static func ms(_ v: Double?) -> String { v.map { $0 < 10 ? fixed($0, 1) + " ms" : fixed($0, 0) + " ms" } ?? "—" }
    static func memory(_ mb: Double?) -> String { mb.map { $0 >= 1000 ? fixed($0 / 1000, 2) + " GB" : fixed($0, 0) + " MB" } ?? "—" }
    /// Python-style list of strings: ['a', 'b'].
    static func list(_ items: [String]) -> String { "[" + items.map { "'\($0)'" }.joined(separator: ", ") + "]" }

    // MARK: status

    static func status(_ s: Status) -> [String] {
        let chip = s.gpu?.chip
        let hot = s.models.keys.sorted().map { id -> String in
            let m = s.models[id]!
            let label = m.engineLabel(chip: chip)
            var text = "\(id) (\(label)" + (label == "MLX" && !(m.engine_reason ?? "").isEmpty ? ": \(m.engine_reason!)" : "") + ")"
            if let residency = m.residency, !residency.isEmpty { text += " [\(residency.replacingOccurrences(of: "_", with: " "))]" }
            return text
        }.joined(separator: ", ")
        let mem = s.memory
        let free = mem?.available_mb.map { ", ~\(fixed($0 / 1000, 1)) GB free now" } ?? ""
        let last = s.last_ms.map { "  last: \(plain($0)) ms" } ?? ""
        var line = "port \(s.port.map(String.init) ?? "None")  models: \(hot.isEmpty ? "none loaded (a judge loads its model on demand)" : hot)"
            + "  calls: \(s.calls ?? 0)\(last)  memory: \(fixed(mem?.rss_mb ?? 0, 0)) MB rss, \(fixed(mem?.mlx_active_mb ?? 0, 0)) MB weights\(free)"
        if let loading = s.loading, !loading.isEmpty { line += "  loading: \(loading)" }
        if let error = s.error, !error.isEmpty { line += "  error: \(error)" }
        var out = [line]
        if let onDemand = s.on_demand_idle_minutes {
            func window(_ m: Int?) -> String { (m ?? 0) == 0 ? "always" : "\(m!) min idle" }
            out.append("keep hot: manual \(window(s.manual_idle_minutes)), on demand \(window(onDemand))  memory: \(s.allow_swap == true ? "allow swap" : "fit in free memory")")
        }
        for e in (s.evictions ?? []).suffix(3) {
            out.append("unloaded \(e.model) (\((e.residency ?? "").replacingOccurrences(of: "_", with: " "))): \(e.reason)")
        }
        if let refused = s.refused { out.append("refused: \(refused.message)") }
        return out
    }

    // MARK: models

    /// Highest accuracy first; equal accuracy keeps catalog order.
    static func byAccuracy(_ models: [Model]) -> [Model] {
        models.enumerated().sorted { a, b in
            let x = a.element.benchmark?.accuracy ?? 0, y = b.element.benchmark?.accuracy ?? 0
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    static func table(_ models: [Model]) -> [String] {
        var out = ["\(left("model", 22)) \(left("inputs", 16)) \(right("context", 7)) \(right("bits", 4)) \(right("accuracy", 8)) \(right("ece", 6)) \(right("speed", 8)) \(right("J/1k", 6)) \(right("memory", 8))  \(left("state", 10)) weights"]
        for m in byAccuracy(models) {
            let b = m.benchmark
            let bits = m.precision.map { String($0.selected) } ?? "—"
            let weights = m.links["weights"] ?? m.links["upstream"] ?? ""
            out.append("\(left(m.id, 22)) \(left(m.inputs.joined(separator: ","), 16)) \(right(m.context.map(String.init) ?? "None", 7)) \(right(bits, 4)) "
                       + "\(right(num(b?.accuracy, percent), 8)) \(right(num(b?.ece) { fixed($0, 3) }, 6)) \(right(ms(b?.ms), 8)) "
                       + "\(right(num(b?.j_per_1k) { fixed($0, 0) }, 6)) \(right(memory(b?.memory_mb), 8))  \(left(m.state, 10)) \(weights)")
        }
        out += ["", "figures at the selected precision (bits). verdict models --all for every precision; verdict info <model> for details."]
        return out
    }

    static let precisionHeader = "\(right("bits", 4))  \(left("accuracy", 16)) \(left("ece", 15)) \(left("speed", 20)) \(left("energy/1k", 24)) \(right("memory", 8))"

    /// One line per offered precision: figures with deltas against the recommended precision; marks recommended,
    /// selected and loaded.
    static func precisionRows(_ m: Model) -> [String] {
        let p = m.precision
        let options = p?.options ?? m.benchmarks.keys.compactMap(Int.init).sorted(by: >)
        return options.map { bits in
            let r = m.benchmarks[String(bits)]
            let d = r?.deltas ?? [:]
            func cell(_ value: String, _ delta: String?) -> String { value + ((delta ?? "").isEmpty ? "" : " " + delta!) }
            var tags: [String] = []
            if let p {
                if bits == p.default { tags.append("recommended") }
                if bits == p.selected { tags.append("selected") }
                if bits == p.loaded { tags.append("loaded") }
            }
            return "\(right(p == nil ? "—" : String(bits), 4))  \(left(cell(num(r?.accuracy, percent), d["accuracy"]), 16)) "
                + "\(left(cell(num(r?.ece) { fixed($0, 3) }, d["ece"]), 15)) \(left(cell(ms(r?.ms), d["speed"]), 20)) "
                + "\(left(cell(num(r?.j_per_1k) { fixed($0, 0) + " J" }, d["energy"]), 24)) \(right(memory(r?.memory_mb), 8))"
                + (tags.isEmpty ? "" : "  " + tags.joined(separator: ", "))
        }
    }

    static func allPrecisions(_ models: [Model]) -> [String] {
        var out = ["\(left("model", 22)) \(precisionHeader)"]
        for m in byAccuracy(models) {
            for (n, row) in precisionRows(m).enumerated() { out.append("\(left(n == 0 ? m.id : "", 22)) \(row)") }
        }
        out += ["", "deltas vs each model's recommended precision (lowest energy within 0.5 pt of its native precision's accuracy); speed is single-item p50, energy is batched."]
        return out
    }

    static func info(_ m: Model) -> [String] {
        var out = ["\(m.name) (\(m.id)) — \(m.state)",
                   "  family      \(m.family ?? "None")    licence \(m.license ?? "None")",
                   "  inputs      \(m.inputs.joined(separator: ", "))    context \(m.context.map(String.init) ?? "None") tokens    languages \(m.languages ?? "None")    params \(m.params ?? "None")"]
        if !m.benchmarks.isEmpty {
            out.append("  \(precisionHeader)")
            out += precisionRows(m).map { "  " + $0 }
        }
        if let b = m.benchmark {
            let sets = (b.sets ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) \(fixed($0.value * 100, 1))%" }.joined(separator: ", ")
            let split = [b.accuracy_en.map { "English \(percent($0))" }, b.accuracy_ml.map { "multilingual \(percent($0))" }].compactMap { $0 }.joined(separator: ", ")
            if !sets.isEmpty { out.append("  tasks       \(sets)" + (b.n_tasks.map { $0 != 0 ? "  (\($0) tasks)" : "" } ?? "")) }
            if !split.isEmpty { out.append("  split       \(split)") }
            var src = [b.source, b.n.flatMap { $0 != 0 ? "n=\($0)" : nil }, b.date, b.hardware].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            if let rate = b.items_per_s, rate != 0 { src += "; batched \(fixed(rate, 0)) items/s" }
            if !src.isEmpty { out.append("  source      \(src)") }
            if let note = b.note, !note.isEmpty { out.append("              \(note)") }
        }
        out.append("  use for     \(m.recommendation ?? "None")")
        for key in m.links.keys.sorted() { out.append("  \(left(key, 11)) \(m.links[key]!)") }
        return out
    }

    // MARK: judge

    /// "noul=0.75", "dept=billing(0.90)", "urgency=1.60".
    static func answer(_ a: JSON) -> String {
        if let choice = a["choice"] { return "\(choice.string ?? choice.compact)(\(fixed(a["confidence"]?.double ?? 0, 2)))" }
        if let noul = a["noul"] { return fixed(noul.double ?? 0, 2) }
        return fixed(a["score"]?.double ?? 0, 2)
    }

    /// One short line per item: `#index  name=value …  | first 60 characters of the item` (or `--field`'s value).
    static func line(index: Int, item: JSON, result: JSON, field: String?, order: [String]) -> String {
        if let error = result["error"], !error.isNull { return "#\(index)  error: \(error.string ?? error.compact)" }
        let answers = result["answers"]?.members ?? []
        let ordered = order.compactMap { id in answers.first { $0.key == id } } + answers.filter { !order.contains($0.key) }
        let text = field.flatMap { item.members != nil ? (item[$0] ?? .null) : nil } ?? item
        let snippet = (text.string ?? text.spaced).replacingOccurrences(of: "\n", with: " ")
        return "#\(index)  " + ordered.map { "\($0.key)=\(answer($0.value))" }.joined(separator: "  ") + "  | " + String(String.UnicodeScalarView(snippet.unicodeScalars.prefix(60)))
    }

    /// The --sort value of a result: the question's score, else P(true), else confidence; -1 for an item error.
    static func sortKey(_ result: JSON, _ question: String) -> Double {
        guard let answers = result["answers"], let a = answers[question] else { return -1 }
        return a["score"]?.double ?? a["noul"]?.double ?? a["confidence"]?.double ?? 0
    }
}
