# Verdict usage

## Menu

- **Header** — `Verdict: 2 models hot · 1,204 judgements`. Green when ready, grey while loading, orange when the worker failed (click it for the error and the log).
- **Last judgement** — wall time of the most recent call.
- **Models…** — the table, sorted by accuracy by default; click a heading to sort. **Get** downloads and loads; **Load**/**Unload** toggle residency; the trash icon deletes downloaded weights (with confirmation). Hot models are remembered and loaded again at the next launch. Hover a number for what it measures. The greyed cloud row is a hosted reference model that cannot be loaded. The footer copies a model-request brief for a coding agent.
- **Copy Skill for Your Agent** — puts a complete `SKILL.md` on the clipboard: when to use Verdict, the API, how to write questions.
- **Set Up Runtime…** — appears only when the Python runtime is missing; installs it (about a minute) and starts the worker. Progress in `setup.log`.
- **Open Verdict Files** — `~/Library/Application Support/Verdict`.
- **Keep Hot** — Always, or unload after 15 min / 1 h / 4 h idle; the next judgement reloads.
- **Bits** (in the Models table) — Laya 16 (native), 8 or 4; Von 32 (native), 16, 8 or 4. The row shows accuracy, calibration error, ms/item, energy (J per 1,000 judgements) and memory for the selected precision, with differences from the native precision in green (better) or red (worse). On a loaded model at another precision, **Unload** becomes **Reload**, which loads the selection.
- **Restart Worker** / **Launch at Login** / **Quit**.

Quitting Verdict stops the worker; nothing else keeps the models loaded.

## Client

`verdict` (installed by `scripts/build.sh` into `~/.local/bin`) is both a CLI and an importable module.

```
verdict status
verdict models [--json]            # catalog at each model's selected precision: accuracy, ece, ms, J/1k, memory, state, weights link
verdict models --all               # every precision per model, with deltas vs the native precision
verdict info MODEL [--json]        # one model: all precisions, task breakdown, measurement source, links
verdict load laya-multilingual | verdict unload ID | verdict quit
verdict judge --questions q.json [--model ID] [--field KEY] [--sort NAME] [--min X] [--top N] < items.jsonl
```

`--field` picks one key of each JSONL object as the state; without it the whole object is the state. Output is one JSON object per line: `{"item": …, "answers": {…}, "model": …, "ms": …}`. `--sort` orders by that question's score/probability, highest first.

```python
import sys; sys.path.insert(0, "/path/to/Verdict/client")   # or symlink verdict.py somewhere importable
from verdict import judge, status
results = judge(items, questions, model="auto", batch=64)
```

`items` can be strings or dicts (Laya sees a dict as JSON, Von as `key: value` lines, so name the fields; a string stays a string even when it looks like JSON). Choice labels must be unique. Von reserves `[MASK]` for its option markers: an item containing it gets a per-item error, and a question containing it is refused. Items with image, audio or video paths return a per-item error; Verdict judges text...}` in its position — nothing is truncated.

## Writing questions

- One question, one decision. Put the rubric in `criteria`, not in `instructions`.
- `noul` for anything yes/no. `choice` for buckets; keep them distinct and ≤ 20, or split into two stages. `score` for ordered levels; expect it to be the fuzziest.
- Put the comparison context in the state: `{"candidate": profile, "job": ad}` works better than a long instruction.
- The model judges one item at a time. Ranking is just sorting by score; it never sees two items together.
- Confidence is calibrated by the model's authors on their data. Before trusting a threshold, label ~30 of your own items and check.

## Worker protocol

Loopback HTTP, JSON, port in `status.json`:

```
GET  /status
POST /judge   {"items": [...], "questions": {...}, "model": "auto"|"laya-english"|...}
POST /load    {"model": ID}       POST /unload {"model": ID}       POST /delete {"model": ID}
POST /quit
```

## Adding models

`Resources/models.json` is the catalog. A candidate needs: open weights with a licence that allows local use, a typed-question interface over choice / score / yes-no with per-answer probabilities, and an architecture that can be implemented on mlx-swift. Add the entry, implement a `DecisionModel` + `ModelLoader` in `native/Sources/VerdictEngine`, register it in `native/Sources/VerdictHelper/Registry.swift`, prove parity against the model's reference implementation on fixed fixtures, then run `scripts/benchmark.py`.

## Troubleshooting

- **Worker exited / orange header** — open the log from the header. Reinstall with `git pull && scripts/install.sh` if the helper is missing or damaged.
- **First load is slow** — that is the download (~0.6–0.85 GB per model). Later loads take a few seconds.
- **`verdict` says not running and the app is installed elsewhere** — set `VERDICT_APP=/path/to/Verdict.app`.
- **Wrong language model** — pass `--model laya-multilingual`; auto-routing only switches on non-ASCII text.
