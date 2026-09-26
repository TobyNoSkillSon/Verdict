import Foundation
import VerdictKit

/// `verdict diagnose`: a short, fixed check of the running app for bug reports. It reads /v1/status and /v1/models,
/// times the models that are already loaded on 20 built-in items (never the user's data), and builds a prefilled
/// GitHub issue URL. It loads nothing unless asked (`--load` loads `recommendedModel`) and never starts the app.
struct Diagnosis: Equatable {
    struct Host: Equatable {
        var chip: String?
        var architecture: String?
        var macos: String?
        var neuralAccelerators: Bool?
        /// hw.model, e.g. "Mac17,6".
        var hardware: String?
        var memoryGB: Int?
    }
    struct Timing: Equatable {
        /// Median wall time of one short item per request (18 items, one at a time), milliseconds.
        var singleMs: Double
        /// Median wall time of one long item (>1k tokens, the windowed-attention path) per request, milliseconds.
        var longMs: Double
        /// All 20 items in one request: items per second (median of three requests).
        var batchPerSecond: Double
    }
    struct Answers: Equatable {
        /// Items answered with every probability finite and in [0, 1] (scores within their rubric).
        var valid: Int
        /// Items whose yes/no answer (P > 0.5) matches the built-in item's obvious answer.
        var agreed: Int
        var total: Int
        /// Item errors, verbatim (first three).
        var errors: [String]
    }
    struct ModelReport: Equatable {
        var id: String
        var label: String
        var engine: String?
        var bits: Int?
        var recommendedBits: Int?
        var residency: String?
        var tokenizer: String?
        var attention: String?
        var matmul: String?
        var selfTest: String
        /// Every reason a path is not the optimized one; empty when none.
        var fallbacks: [String]
        var timing: Timing?
        var answers: Answers?
        /// Why the model was not timed (a request failed), verbatim.
        var error: String?
    }

    var cliVersion: String?
    var appVersion: String?
    var api: Int?
    var mlx: String?
    var host: Host
    /// False when Verdict was not running: the report then holds this Mac's facts only.
    var running: Bool
    var models: [ModelReport]
    /// Status `error` (the last load failure) and the last memory refusal, verbatim.
    var statusError: String?
    var refused: String?
    /// Set when `--load` loaded a model for this run.
    var loadedForDiagnosis: String?
}

enum Diagnose {
    typealias Timing = Diagnosis.Timing
    typealias Answers = Diagnosis.Answers
    static let recommendedModel = "laya-english"
    static let repository = "https://github.com/TobyNoSkillSon/Verdict"
    /// GitHub answers 414 above roughly 8 KB of URL; stay well under it.
    static let maxURLLength = 7000

    // MARK: fixed workload

    static let questions: JSON = .object([
        .init("refund", .object([.init("type", .string("noul")), .init("instructions", .string("Does the writer ask for their money back?"))])),
        .init("kind", .object([.init("type", .string("choice")), .init("instructions", .string("What kind of message is this?")),
                               .init("criteria", .object([.init("billing", .string("payments, charges or refunds")),
                                                          .init("bug", .string("something is broken")),
                                                          .init("feature", .string("a request for something new")),
                                                          .init("other", .string("anything else"))]))])),
        .init("urgency", .object([.init("type", .string("score")), .init("instructions", .string("How soon does it need a reply?")),
                                  .init("criteria", .array([.string("whenever"), .string("this week"), .string("today")]))]))
    ])

    /// A fixed order log of over 1,000 tokens (1,200+ words and symbols): long enough for the windowed-attention path
    /// (768 tokens and up), short enough for Von 1.1's 2,048.
    static let orderLog = "Order history for account 4471.\n" + (1...60).map {
        "Line \($0): order #\(1000 + $0) was delivered on day \($0 % 28 + 1) and the invoice total matched the basket."
    }.joined(separator: "\n")

    /// 20 built-in items with an obvious answer to `refund`: 18 short, then 2 long.
    static let items: [(text: String, refund: Bool)] = [
        ("I was charged twice for my order. Please refund the second payment.", true),
        ("The export button does nothing when I click it.", false),
        ("The headphones broke after two days. I want my money back.", true),
        ("Could you add a dark mode to the app?", false),
        ("Please cancel my subscription and return this month's fee.", true),
        ("What time does the store open on Sundays?", false),
        ("The course was nothing like its description, so I am requesting a full refund.", true),
        ("Thanks, the new update works great.", false),
        ("You cancelled my hotel night. Refund me for it, please.", true),
        ("How do I change my password?", false),
        ("My parcel never arrived. Can I get the money back?", true),
        ("The meeting moved to 3 pm on Thursday.", false),
        ("I returned the jacket last week; when will I get my refund?", true),
        ("Please add a CSV option to the report page.", false),
        ("You billed me after I cancelled. Reverse the charge and pay me back.", true),
        ("The app crashes when I open the settings screen.", false),
        ("The tickets were for a concert that was called off. I would like my money returned.", true),
        ("The weather in Lisbon was lovely this weekend.", false),
        (orderLog + "\nThe last order arrived broken. Please refund it in full.", true),
        (orderLog + "\nEverything arrived in good condition; no action is needed.", false),
    ]
    static var shortCount: Int { items.count - 2 }

    // MARK: collection

    /// Runs the diagnosis against the app `verdict` points at. Never launches it.
    static func collect(_ verdict: Verdict, cliVersion: String?, load: Bool) async throws -> Diagnosis {
        let local = localHost()
        var diagnosis = Diagnosis(cliVersion: cliVersion, host: local, running: false, models: [])
        guard verdict.runningPort() != nil else { return diagnosis }
        let quiet = Verdict(unchecked: false, timeout: verdict.timeout, app: verdict.app, supportDirectory: verdict.supportDirectory)
        diagnosis.running = true
        var status = try await quiet.status()
        if load, status.models[recommendedModel] == nil {
            _ = try await quiet.load(recommendedModel)
            diagnosis.loadedForDiagnosis = recommendedModel
            status = try await quiet.status()
        }
        let client = SystemOneClient(verdict: quiet)
        var timings: [String: (Timing?, Answers?, String?)] = [:]
        for id in status.models.keys.sorted() {
            do {
                let (t, a) = try await measure(client, model: id)
                timings[id] = (t, a, nil)
            } catch {
                timings[id] = (nil, nil, (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
        // Read again: a stock fallback during the timed run shows up here.
        let after = (try? await quiet.status()) ?? status
        let catalog = (try? await quiet.models()) ?? []
        diagnosis.appVersion = after.version
        diagnosis.api = after.api
        diagnosis.mlx = after.mlx
        diagnosis.statusError = after.error.flatMap { $0.isEmpty ? nil : $0 }
        diagnosis.refused = after.refused?.message
        let gpu = after.gpu
        diagnosis.host.chip = gpu?.chip.flatMap { $0.isEmpty ? nil : $0 } ?? local.chip
        diagnosis.host.architecture = gpu?.architecture
        diagnosis.host.neuralAccelerators = gpu?.neural_accelerators
        let states = after.models.isEmpty ? status.models : after.models
        diagnosis.models = states.keys.sorted().map { id in
            let t = timings[id]
            return report(id: id, state: states[id]!, precision: catalog.first { $0.id == id }?.precision, chip: diagnosis.host.chip,
                          timing: t?.0, answers: t?.1, error: t?.2)
        }
        return diagnosis
    }

    /// Warm-up and answers from one batch, then three timed batches and every item alone.
    static func measure(_ client: SystemOneClient, model: String) async throws -> (Timing, Answers) {
        let states = items.map { JSON.string($0.text) }
        let clock = ContinuousClock()
        func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        let results = try await client.judgeJSON(states, questions: questions, model: model)
        var batches: [Double] = []
        for _ in 0..<3 {
            let start = clock.now
            _ = try await client.judgeJSON(states, questions: questions, model: model)
            batches.append(seconds(clock.now - start))
        }
        var single: [Double] = []
        for state in states {
            let start = clock.now
            _ = try await client.judgeJSON([state], questions: questions, model: model)
            single.append(seconds(clock.now - start) * 1000)
        }
        let timing = Timing(singleMs: median(Array(single.prefix(shortCount))), longMs: median(Array(single.suffix(2))),
                            batchPerSecond: Double(items.count) / median(batches))
        return (timing, check(results))
    }

    /// Validity and agreement with the built-in items' obvious `refund` answers.
    static func check(_ results: [JSON]) -> Answers {
        var valid = 0, agreed = 0, errors: [String] = []
        for (item, result) in zip(items, results) {
            if let error = result["error"], !error.isNull { errors.append(error.string ?? error.compact); continue }
            let answers = result["answers"]
            let noul = answers?["refund"]?["noul"]?.double
            let probabilities = answers?["kind"]?["probabilities"]?.members?.compactMap(\.value.double) ?? []
            let score = answers?["urgency"]?["score"]?.double
            func unit(_ x: Double?) -> Bool { x.map { $0.isFinite && $0 >= 0 && $0 <= 1 } ?? false }
            let ok = unit(noul) && !probabilities.isEmpty && probabilities.allSatisfy { unit($0) }
                && (score.map { $0.isFinite && $0 >= 0 && $0 <= 2 } ?? false)
            if ok { valid += 1 }
            if let noul, noul.isFinite, (noul > 0.5) == item.refund { agreed += 1 }
        }
        return Answers(valid: valid, agreed: agreed, total: items.count, errors: Array(errors.prefix(3)))
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// One loaded model's facts from its /v1/status entry.
    static func report(id: String, state m: Status.LoadedModel, precision: Model.Precision?, chip: String?,
                       timing: Timing?, answers: Answers?, error: String?) -> Diagnosis.ModelReport {
        let o = m.optimizations
        var fallbacks = (m.engine_reason ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let t = o?.tokenizer, t != "fast", !fallbacks.contains(where: { $0.contains("tokenizer") }) { fallbacks.append("tokenizer: \(t)") }
        if let a = o?.attention, a != "windowed", !fallbacks.contains(where: { $0.contains("attention") || $0.contains("kernel") || $0.contains("stock") }) {
            fallbacks.append("attention: \(a)")
        }
        // Only a missing capability is a fallback; 8/4-bit or Von's f32 on the regular GPU path is a precision choice.
        if let mm = o?.matmul, mm == "standard GPU" { fallbacks.append("matmul: standard GPU (no neural accelerators on this chip or macOS)") }
        let bits = precision?.loaded ?? m.bits.flatMap { $0 == 0 ? nil : $0 }
        return Diagnosis.ModelReport(id: id, label: m.engineLabel(chip: chip), engine: m.engine, bits: bits, recommendedBits: precision?.default,
                                     residency: m.residency, tokenizer: o?.tokenizer, attention: o?.attention, matmul: o?.matmul,
                                     selfTest: selfTest(m.kernel), fallbacks: fallbacks, timing: timing, answers: answers, error: error)
    }

    /// The windowed-attention self-test result from the helper's kernel path.
    static func selfTest(_ kernel: String?) -> String {
        guard let kernel, !kernel.isEmpty else { return "not reported" }
        if kernel.contains("self-test failed") { return "failed (\(kernel))" }
        if kernel.hasPrefix("windowed") { return "passed (\(kernel))" }
        if kernel.contains("after an inference failure") { return "passed at load; \(kernel)" }
        return kernel
    }

    /// This Mac's facts without the app: chip, model, memory, macOS.
    static func localHost() -> Diagnosis.Host {
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
            return String(cString: bytes)
        }
        var memory: UInt64 = 0, size = MemoryLayout<UInt64>.size
        let gb = sysctlbyname("hw.memsize", &memory, &size, nil, 0) == 0 ? Int((Double(memory) / 1_073_741_824).rounded()) : nil
        var chip = sysctl("machdep.cpu.brand_string")
        if let c = chip, c.hasPrefix("Apple ") { chip = String(c.dropFirst(6)) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macos = "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
        return Diagnosis.Host(chip: chip, macos: macos, hardware: sysctl("hw.model"), memoryGB: gb)
    }

    // MARK: report

    static func text(_ d: Diagnosis) -> [String] {
        let versions = "verdict \(d.cliVersion ?? "?")"
            + (d.running ? " (app \(d.appVersion ?? "?"), API \(d.api.map(String.init) ?? "?")) · MLX \(d.mlx ?? "?")" : "")
        let h = d.host
        var mac = [h.chip ?? "unknown chip", h.hardware, h.memoryGB.map { "\($0) GB" }, "macOS \(h.macos ?? "?")"].compactMap { $0 }.joined(separator: " · ")
        if h.architecture != nil || h.neuralAccelerators != nil {
            mac += " · GPU \(h.architecture ?? "?"), neural accelerators \(h.neuralAccelerators.map { $0 ? "yes" : "no" } ?? "?")"
        }
        var out = ["verdict diagnose", versions, "Mac: " + mac]
        guard d.running else {
            out.append("Verdict is not running: start it (menu bar, or `open -g /Applications/Verdict.app`) and run `verdict diagnose` again.")
            return out
        }
        if let loaded = d.loadedForDiagnosis { out.append("loaded \(loaded) for this diagnosis (--load)") }
        for m in d.models {
            var head = "\(m.id): \(m.label)"
            if let bits = m.bits { head += " · \(bits)-bit" + (m.recommendedBits.map { $0 == bits ? " (recommended)" : " (recommended \($0))" } ?? "") }
            if let r = m.residency, !r.isEmpty { head += " · " + r.replacingOccurrences(of: "_", with: " ") }
            out.append(head)
            out.append("  paths: tokenizer \(m.tokenizer ?? "—"), attention \(m.attention ?? "—"), matmul \(m.matmul ?? "—")")
            out.append("  self-test: \(m.selfTest)")
            out.append("  fallbacks: \(m.fallbacks.isEmpty ? "none" : m.fallbacks.joined(separator: "; "))")
            if let t = m.timing {
                out.append("  timing: \(Format.ms(t.singleMs)) single (p50 of \(shortCount)), \(Format.ms(t.longMs)) long item (>1k tokens), "
                           + "\(Format.fixed(t.batchPerSecond, 0)) items/s batched (\(items.count) per request)")
            }
            if let a = m.answers {
                var line = "  answers: \(a.valid)/\(a.total) valid; refund as expected on \(a.agreed)/\(a.total)"
                if !a.errors.isEmpty { line += "; errors: " + a.errors.joined(separator: " | ") }
                out.append(line)
            }
            if let e = m.error { out.append("  not timed: \(e)") }
        }
        if d.models.isEmpty {
            out.append("no model loaded: nothing timed. `verdict diagnose --load` loads \(recommendedModel) (downloads it on first use) and times it.")
        }
        if let e = d.statusError { out.append("last load error: \(e)") }
        if let r = d.refused { out.append("last refusal: \(r)") }
        return out
    }

    /// A short issue title: chip, macOS and what is not optimized.
    static func title(_ d: Diagnosis) -> String {
        let where_ = "\(d.host.chip ?? "unknown chip"), macOS \(d.host.macos ?? "?")"
        guard d.running else { return "\(where_): Verdict not running" }
        let mlx = d.models.filter { $0.label == "MLX" }
        if let first = mlx.first {
            let reason = first.fallbacks.first.map { ": \($0)" } ?? ""
            return String("\(where_): \(mlx.map(\.id).joined(separator: ", ")) on MLX\(reason)".prefix(120))
        }
        return "\(where_): " + (d.models.isEmpty ? "diagnose report" : "diagnose report (optimized)")
    }

    static func json(_ d: Diagnosis, issueURL: String) -> JSON {
        func s(_ v: String?) -> JSON { v.map(JSON.string) ?? .null }
        func n(_ v: Double?) -> JSON { v.map { JSON(($0 * 100).rounded() / 100) } ?? .null }
        func i(_ v: Int?) -> JSON { v.map { JSON($0) } ?? .null }
        let h = d.host
        let host = JSON.object([.init("chip", s(h.chip)), .init("hardware", s(h.hardware)), .init("memory_gb", i(h.memoryGB)),
                                .init("macos", s(h.macos)), .init("gpu_architecture", s(h.architecture)),
                                .init("neural_accelerators", h.neuralAccelerators.map(JSON.bool) ?? .null)])
        let models = d.models.map { m -> JSON in
            var members: [JSON.Member] = [
                .init("id", .string(m.id)), .init("label", .string(m.label)), .init("engine", s(m.engine)),
                .init("bits", i(m.bits)), .init("recommended_bits", i(m.recommendedBits)), .init("residency", s(m.residency)),
                .init("optimizations", .object([.init("tokenizer", s(m.tokenizer)), .init("attention", s(m.attention)), .init("matmul", s(m.matmul))])),
                .init("self_test", .string(m.selfTest)), .init("fallbacks", .array(m.fallbacks.map(JSON.string)))]
            members.append(.init("timing", m.timing.map { t in
                .object([.init("single_ms_p50", n(t.singleMs)), .init("long_ms_p50", n(t.longMs)), .init("batch_items_per_s", n(t.batchPerSecond)),
                         .init("items", JSON(items.count))]) } ?? .null))
            members.append(.init("answers", m.answers.map { a in
                .object([.init("valid", JSON(a.valid)), .init("agreed", JSON(a.agreed)), .init("total", JSON(a.total)),
                         .init("errors", .array(a.errors.map(JSON.string)))]) } ?? .null))
            members.append(.init("error", s(m.error)))
            return .object(members)
        }
        return .object([
            .init("verdict", s(d.cliVersion)), .init("app", s(d.appVersion)), .init("api", i(d.api)), .init("mlx", s(d.mlx)),
            .init("running", .bool(d.running)), .init("host", host), .init("loaded_for_diagnosis", s(d.loadedForDiagnosis)),
            .init("models", .array(models)), .init("last_load_error", s(d.statusError)), .init("last_refusal", s(d.refused)),
            .init("issue_url", .string(issueURL))])
    }

    static func issueURL(_ d: Diagnosis) -> String {
        IssueURL.bugReport(repository: repository, title: title(d), fields: [
            ("chip", [d.host.chip, d.host.hardware].compactMap { $0 }.joined(separator: ", ")),
            ("macos", d.host.macos ?? ""),
            ("version", d.appVersion ?? d.cliVersion ?? "")
        ], diagnose: text(d).joined(separator: "\n"), maxLength: maxURLLength)
    }
}

/// A new-issue URL for the bug-report form (.github/ISSUE_TEMPLATE/bug_report.yml), fields prefilled by their ids.
/// The `diagnose` field goes last and is cut at a line boundary (or, for one huge line, a character) to keep the
/// whole URL within `maxLength`; percent escapes are never split.
enum IssueURL {
    static let template = "bug_report.yml"
    static let truncationNote = "\n[truncated: paste the full `verdict diagnose` output]"
    /// RFC 3986 unreserved characters, ASCII only (CharacterSet.alphanumerics would pass non-ASCII letters).
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    static func bugReport(repository: String, title: String, fields: [(String, String)], diagnose: String, maxLength: Int) -> String {
        var url = "\(repository)/issues/new?template=\(template)&title=\(encode(title))"
        for (id, value) in fields where !value.isEmpty { url += "&\(id)=\(encode(value))" }
        let prefix = "&diagnose="
        let budget = maxLength - url.count - prefix.count
        let full = encode(diagnose)
        if full.count <= budget { return url + prefix + full }
        let note = encode(truncationNote)
        var kept = "", used = 0
        let lines = diagnose.components(separatedBy: "\n")
        for (n, line) in lines.enumerated() {
            let piece = encode((n == 0 ? "" : "\n") + line)
            if used + piece.count + note.count > budget {
                if n == 0 {   // one line longer than the whole budget: keep what fits, character by character
                    for ch in line {
                        let e = encode(String(ch))
                        if used + e.count + note.count > budget { break }
                        kept += e; used += e.count
                    }
                }
                break
            }
            kept += piece; used += piece.count
        }
        return url + prefix + kept + note
    }
}
