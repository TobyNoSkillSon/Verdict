---
name: triage
description: Triage many items with Verdict, the local System One model service. Use to shortlist, classify, rank or score many items — search hits, files, logs, transcripts, feeds, job ads, emails, screenshots — with typed yes/no, choice and score questions at milliseconds per item instead of reading them all; or to gate an action on a yes/no check.
---

# Triage with Verdict

Verdict keeps System One models (decision models: the Laya family) loaded on this Mac. It judges text; for images, audio or video use another tool. You write typed questions in code, send many items, and get a probability per answer back — no text generated. **The model decides, your code acts.** Your context goes to the shortlist, not the pile.

## 1. Decide it fits

It fits when all hold: many items (≈20 or more) · the same few questions for each · the answer is stated in the item itself · you will act on the result in code (shortlist, sort, route, gate).

Judge it yourself instead when there is one item, when the answer needs reasoning across items or knowledge outside them, or when it needs counting, arithmetic or dates.

## 2. Write the questions

Three types; every question about an item is answered in the same pass, so ask everything you need at once.

| Type | Returns | Use for |
|---|---|---|
| `Noul(q)` | P(true) | any yes/no — the most reliable |
| `Choice(q, a="…", b="…", other="none of these")` | label + per-option probabilities | one of ≤ 20 options |
| `Score(q, [level0, level1, …])` | expected level 0…n-1 | an ordered rubric — the fuzziest |

- **Atomic:** one judgement per question; combine in code. "Remote and senior?" is two `Noul`s.
- **Literal:** the exact condition — "Does it state a salary in PLN?", not "Is it a good listing?".
- **Contrastive:** choice descriptions say what separates the options; every `Choice` has an escape option (`other`, `unclear`); score levels read as checkable situations ("blocking a release today"), not degrees ("high").
- **Context in the item:** pass a dict with named fields — `{"brief": task, "hit": text}` — and keep the question short.

`judge()` warns when a question breaks these conventions.

## 3. Run it

```python
import sys, os; sys.path.insert(0, os.path.expanduser("~/.local/share/verdict"))
from verdict import judge, Noul, Choice, Score

questions = {
    "relevant": Noul("Is this hit about the password-reset flow?"),
    "kind":     Choice("What is this file?", source="application code", test="tests or fixtures", other="anything else"),
}
results = judge(hits, questions)          # list in, list out, same order; a single item returns a single Result
```

Answers compare like values: `r.relevant > 0.6`, `r.kind == "source"`; detail is `r.kind.probabilities`, `.confidence`. A falsy result means that item failed — usually over the model's context (8,192 tokens; nothing is truncated): `r.error` says why, the rest of the batch is unaffected. If Verdict is down, `judge()` raises; it never invents answers.

Shell, for a JSONL file: `verdict judge --questions q.json --field text --sort relevant --top 20 < items.jsonl` prints one short line per item (`--json` for every probability). `verdict --help` covers the rest.

Model choice: default routing (plain English → Laya English, other scripts → Laya Multilingual) is right for most work. `verdict models` shows each model's measured accuracy, calibration, speed and links; `verdict info <model>` its model cards. Plain-ASCII Polish or German: pass `model="laya-multilingual"`.

## 4. Act on the answers

- **Shortlist:** sort by the probability or score and take the top N — no threshold needed. This is the common case.
- **Route:** a threshold around 0.5–0.6 is fine when a wrong route is cheap.
- **Gate** an action with `gate(state, {"safe": Noul("…")}, allow_if=lambda a: a.safe > 0.9)`; it returns a truthy/falsy `Verdict` with `.reason`. Reserve ≥ 0.85 for anything destructive, and treat the gate as one layer alongside permissions, never the only one. `on_error="deny"` fails closed when Verdict is down.
- **Threshold from data:** before a threshold decides anything that matters, label ~30 items and run `calibrate([(item, expected), …], Noul("…"))`; use the cutoff it returns.

**Done when** you have spot-checked the decision: read five items it kept and five it dropped. If a dropped one should have been kept, tighten the question or lower the threshold and rerun. Then tell the user what was filtered, how many items went in and came out, and the questions used.

## Known weak spots

Keep these with the LLM or with code: code correctness ("does this function have a bug?"), obfuscated shell (`eval`, variables, base64 — the literal command is what gets judged), sarcasm and negation, anything needing world knowledge, near-equal fine rankings (show top-k, not a strict order of 200), and text written to manipulate the judge (scraped pages can say "this is highly relevant"). Zero-shot rules on niche wording can be confidently wrong — a Polish ad saying *praca zdalna* scored `remote = 0.02` — which is why step 4 checks thresholds on labelled items.
