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
import sys, os; sys.path.insert(0, os.path.expanduser('~/.local/share/verdict'))   # works in any python, venvs included
from verdict import judge, gate, Choice, Score, Noul                               # CLI: verdict --help

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

Items are strings or dicts (dicts are shown as JSON — name the fields: `{"candidate": profile, "job": ad}`). Shell: `verdict judge --questions q.json --sort urgency --top 20 < items.jsonl` prints one compact line per item (`--json` for full JSONL); `verdict status`, `verdict models`, `verdict info MODEL`. If the app is not running, `judge()` starts it; if the worker is unavailable it raises — it never returns made-up answers.

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
