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
public let agentSkill = """
---
name: verdict
description: Judge many items with the same typed questions locally in milliseconds using the decision model kept hot by the Verdict menu-bar app (Laya). Use when a script needs to classify, score, filter, rank or gate ≥20 texts on facts stated in them — a very smart if statement.
---

# Verdict

A decision model answers typed questions about one item in a single forward pass (~7 ms), returning probabilities, never text. Verdict keeps it hot; `judge()` is the call. **The model decides, your code executes.**

## When it is the right tool

All of these: many items · the same few questions · the answer is in the text · you branch on the result in code. Otherwise judge it yourself in the conversation; one nuanced decision is cheaper and better in the LLM.

## Call

```python
from verdict import judge, gate, Choice, Score, Noul   # ~/.local/bin/verdict; add its folder to sys.path or symlink verdict.py

questions = {
    "refund":  Noul("Does the customer explicitly ask for money back?"),
    "dept":    Choice("Which team should handle this?", billing="charges, invoices, refunds", tech="bugs, outages", other="none of these"),
    "urgency": Score("How urgent is this?", ["routine, no deadline", "needs attention this week", "blocking or deadline today"]),
}
for item, r in zip(items, judge(items, questions)):   # list in, list out, order kept; one forward pass per item
    if r.dept == "billing" and r.refund > 0.7:         # answers compare like values
        route_to_billing(item)
    r.dept.probabilities, r.dept.confidence            # detail one attribute away
    if not r: log(r.error)                             # an over-long item is a falsy Result, never silently cut

r = judge(one_item, questions)                         # single item → single Result
```

Items are strings or dicts (dicts are shown as JSON — name the fields: `{"candidate": profile, "job": ad}`). Shell: `verdict judge --questions q.json --sort urgency --top 20 < items.jsonl`; `verdict status`, `verdict models`. If the app is not running, `judge()` starts it; if the worker is unavailable it raises — it never returns made-up answers.

Question classes are the TypeSafe/Laya names, so questions written for Jev work unchanged; plain dicts (`{"type": "noul", "instructions": …}`) are accepted too. `judge()` warns at call time when a question breaks the conventions below.

## Choosing a model

`verdict models` lists every model with inputs, context, measured accuracy, calibration error, speed, state and its weights link; `verdict info <model>` adds the benchmark breakdown, what it is good for, and links to the upstream model card, the weights and the runtime (Hugging Face / GitHub) — read those for specifics. `--json` on either, or `models()` in Python, for the same data as objects. Default routing (English → Laya English, non-ASCII → Multilingual, media → Gemma) is right for most work; pass `model=` when the table says another fits better.

## Three primitives

| | Returns | Use for |
|---|---|---|
| `noul` | `noul` = P(true) | any yes/no; the most reliable |
| `choice` | `choice` + `probabilities` | one of ≤20 named options; **always include an escape option** (`other`, `unclear`) |
| `score` | `score` = expected level 0…n-1 + `probabilities` | ordered rubric; the fuzziest |

Every answer also has `confidence` (top probability). Extra questions cost almost nothing — ask everything you need in one call.

## Writing questions (the conventions the field settled on)

- **Atomic.** One judgement per question. "Is it remote *and* senior?" → two `noul`s, combine in code.
- **Literal.** State the exact condition: "Does the text mention a salary in PLN?" not "Is it a good listing?"
- **Contrastive criteria.** Choice descriptions should say what distinguishes options; score levels should read like checkable situations, not "low / medium / high".
- **Context in the state, not the prompt.** Put the profile, brief or rubric into the item dict; keep `instructions` short.
- **No arithmetic, counting or dates in the model.** Ask a `noul` per element and sum in code.
- **Budget:** 8,192 tokens for Laya (128k for Gemma), questions included. Nothing is truncated: an over-long item comes back as `{"error": …}` in its position — check for it, then split or trim that item.
- Non-ASCII text routes to the multilingual model; plain-ASCII Polish/German: `judge(..., model="laya-multilingual")`.
- **Images, audio, video:** pass `{"image": path}` (or `audio`, `video`, plus any text fields) as the item; it routes to Gemma E2B (~0.2 s per image, ~2 s per audio clip). Gemma's *answers* are usable, its *probabilities* are not calibrated — argmax only, no thresholds.

## Deciding on the answers

- **Picking the best:** sort by score/probability, no threshold needed.
- **Acting on a yes/no (gate):** thresholds by cost of error — ~0.5 to route or shortlist, ≥0.85 before anything destructive, and escalate (ask, or leave to the LLM) in between. Put thresholds in one place in the script, or use `gate(state, checks, allow_if=lambda a: a.safe > 0.9)` → a truthy/falsy `Verdict` with `.reason`; `on_error="allow"|"deny"` chooses fail-open/closed when the worker is down (default raises).
- **Picking a threshold:** `calibrate([(item, expected_bool), …], Noul("…"))` sweeps cutoffs on your labelled cases and returns the best one — the number in the script should come from data, not a guess.
- **Never** treat confidence as authorization, and never let a gate fail silently: if Verdict is down, `judge()` raises — catch it and fall back to the LLM or stop.
- **Before trusting a threshold** on a new question, label ~30 items and check; zero-shot fine rules can be confidently wrong (a Polish ad with *praca zdalna* scored `remote = 0.02`). For a rule that matters, fine-tune on 50–500 examples.
- Many options (>20): two-stage choice (category → subcategory).

## Patterns that pay

Scrape-then-filter (pages, tweets, abstracts → read the top 20) · automation triage ("anything worth a notification?") · sorting old piles (sessions, imports) · worker-reply checks ("claims success without showing verification?") · intent routing in front of an expensive step.
"""

/// Copied from the models table: a brief the user can hand to an agent to add or evaluate a model.
public let modelRequest = """
Add a decision model to Verdict (menu-bar app that keeps typed-question models hot on this Mac; project at ~/Projects/Verdict or github.com/TobyNoSkillSon/Verdict).

A candidate needs: open weights with a licence that allows local use; a predict(state, questions) interface over choice / score / noul questions returning per-answer probabilities; an Apple-Silicon-native runtime (MLX preferred) that loads in seconds.

Steps: (1) find the weights and runtime, verify the licence; (2) add a catalog entry to Resources/models.json (id, name, backbone, params, repository, context, languages, license, recommendation); (3) if it is not a Laya checkpoint, add a loader branch in Resources/worker.py; (4) run scripts/benchmark.py so it appears with measured accuracy, calibration and speed; (5) run the tests (xcrun swift test; cd Tests && python3 -m unittest test_worker). Report what you verified and what remains uncertain.
"""

public let keepHotChoices: [(minutes: Int, title: String)] = [(0, "Always"), (15, "15 minutes after use"), (60, "1 hour after use"), (240, "4 hours after use")]

public let precisionChoices: [(bits: Int, title: String)] = [(0, "fp16"), (8, "8-bit"), (4, "4-bit")]
