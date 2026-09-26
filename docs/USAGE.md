# Verdict usage

## Menu

- **Header** — `Verdict: 2 models hot · 1,204 judgements`. Green when ready, grey while loading, orange when the worker failed (click it for the error and the log).
- **Last judgement** — wall time of the most recent call.
- **Models…** — the table, sorted by accuracy by default; click a heading to sort. **Get** downloads and loads; **Load**/**Unload** toggle residency; the trash icon deletes downloaded weights (with confirmation). Models loaded here are remembered and loaded again at the next launch; **Unload** removes them from that set. Hover a number for what it measures. The greyed cloud row is a hosted reference model that cannot be loaded. The footer copies a model-request brief for a coding agent.
- **Copy Skill for Your Agent** — puts a complete `SKILL.md` on the clipboard: when to use Verdict, how to write questions, the `verdict` command, the Python library and the HTTP API.
- **Open Verdict Files** — `~/Library/Application Support/Verdict`: `config.json` (menu settings), `status.json` (the API's port and state), `worker.log`.
- **Keep Hot** — idle windows per kind of load, each model timed from its own last request; the next request that needs an unloaded model loads it again.
  - **Manually loaded** (Load/Reload in the table or `verdict load --manual`; these form the launch set, loaded again at every launch): Always (default), 15, 30 or 60 min idle. A fresh install's launch set is empty, so nothing loads until the first request.
  - **Loaded on demand** (a request or an agent's `verdict load` needed it): 5, 15 (default), 30 or 60 min idle, or Always. On-demand loads do not join the launch set.
- **Memory** — **Fit in free memory** (default): checks free memory before loading and avoids swap: a model loads only if it fits in memory that is free at that moment. Before a load, need = the model's measured memory at that precision (benchmarks.json `memory_mb`; else weights on disk scaled to the precision + 0.77 GB) + 0.5 GB activation headroom; free = min((free − speculative) + file-backed + purgeable pages, kern.memorystatus_level × RAM) − max(1 GB, 10% of RAM) (disjoint page counts; inactive anonymous pages are not counted; re-checked after a download). Best-effort at load time, not a no-swap guarantee. Short of it, Verdict unloads idle models (on demand before manual, least recently used first, never one serving the current request) and re-checks after each; if even that cannot free enough, nothing is unloaded and the load is refused (HTTP 507) with the reason and what to do. **Allow swap (slower)** skips the check: the load goes ahead and macOS moves data to disk, which can slow everything, other apps included. The submenu shows current free memory (`~X GB free now`) and the last model unloaded to make room; `verdict status` lists recent unloads and the last refusal.
- **Bits** (in the Models table) — Laya 16 (native), 8 or 4; Von 32 (native), 16, 8 or 4. The row shows accuracy, calibration error, ms/item, energy (J per 1,000 judgements) and memory for the selected precision, with differences from the recommended precision in green (better) or red (worse). The recommended precision (marked in the Bits control) is the lowest energy within 0.5 accuracy points of the native precision; it is what a load uses until you pick another. On a loaded model at another precision, **Unload** becomes **Reload**, which loads the selection.
- **Restart Worker** / **Launch at Login** / **Support the developer…** (GitHub Sponsors) / **Quit Verdict**.

Quitting Verdict stops the worker; nothing else keeps the models loaded.

## Command line and libraries

Everything below is a client of Verdict's local HTTP API: an endpoint compatible with the System One API (TypeSafe Jev), which works with the TypeSafe SDK (`verdict url` gives its base URL), plus Verdict's batch and management endpoints. [API.md](API.md) documents it (discovery, every endpoint, errors, security, differences from Jev, examples in curl, Python, Swift and JavaScript).

`verdict` (a link in `~/.local/bin` to the app's `Contents/Helpers/verdict`, made by `scripts/install.sh`):

```
verdict status                     # port, loaded models (engine, residency), memory, Keep Hot, recent unloads, last refusal
verdict models [--json]            # catalog at each model's selected precision: accuracy, ece, ms, J/1k, memory, state, weights link
verdict models --all               # every precision per model, with deltas vs the recommended precision
verdict info MODEL [--json]        # one model: all precisions, task breakdown, measurement source, links
verdict load ID [--bits N] [--manual] | verdict unload ID   # load: on demand; --manual: like the menu (launch set)
verdict judge --questions q.json [--model ID] [--bits N] [--field KEY] [--sort NAME] [--min X] [--top N] [--json] < items.jsonl
verdict url                        # the base URL for TypeSafe SDKs and HTTP clients (starts the app if needed)
verdict skill [--install DIR]      # the agent skill
verdict diagnose [--load] [--json] # report for a bug report: chip, versions, engines, fallbacks, timing (see Troubleshooting)
```

`judge` reads JSONL: `--field` picks one key of each object as the item; without it the whole line is the item. It prints one line per item, `#index  name=value …  | first 60 characters` (a choice as `label(confidence)`); `--json` prints `{"index", "item", "answers", "model", "ms"}` per line with every probability. `--sort` orders by that question's score or probability, highest first; `--min` drops rows below a value; `--top` keeps the first N.

Python scripts import the library installed at `~/.local/share/verdict/verdict.py` (standard library only):

```python
import sys, os; sys.path.insert(0, os.path.expanduser("~/.local/share/verdict"))
from verdict import judge, gate, calibrate, Noul, Choice, Score, status, models, load, unload
results = judge(items, questions, model="auto")   # a list in, a list of Results out; one item in, one Result out
```

For one state at a time, use the TypeSafe SDK (`pip install typesafe-sdk`) with `base_url=verdict.base_url()`, any API key and `model="auto"`; the library above adds batches, `gate`, `calibrate`, model management and starting the app.

Swift code uses VerdictKit, a library product of this package: `let client = SystemOneClient()`, then `client.systemOne(state:questions:)` (the TypeSafe SDK's call shape) or `client.judge(items:questions:)` for batches.

`items` can be strings or dicts (Laya sees a dict as JSON, Von as `key: value` lines, so name the fields; a string stays a string even when it looks like JSON). Choice labels must be unique. Von reserves `[MASK]` for its option markers: an item containing it gets a per-item error, and a question containing it is refused. Items with image, audio or video paths return a per-item error; Verdict judges text. An item longer than its model's context returns a per-item error in its position — nothing is truncated.

## Writing questions

- One question, one decision. Put the rubric in `criteria`, not in `instructions`.
- `noul` for anything yes/no. `choice` for buckets; keep them distinct and ≤ 20, or split into two stages. `score` for ordered levels; expect it to be the fuzziest.
- Put the comparison context in the state: `{"candidate": profile, "job": ad}` works better than a long instruction.
- The model judges one item at a time. Ranking is just sorting by score; it never sees two items together.
- Confidence is calibrated by the model's authors on their data. Before trusting a threshold, label ~30 of your own items and check.

## Adding models

`Resources/models.json` is the catalog. A candidate needs: open weights with a licence that allows local use, a typed-question interface over choice / score / yes-no with per-answer probabilities, and an architecture that can be implemented on mlx-swift. Add the entry, implement a `DecisionModel` + `ModelLoader` in `Sources/VerdictEngine`, register it in `Sources/VerdictHelper/Registry.swift`, prove parity against the model's reference implementation on fixed fixtures, then measure accuracy, calibration and speed before adding its numbers to `Resources/benchmarks.json`.

## Troubleshooting

- **A model shows "MLX", is slow, or its answers look wrong** — run `verdict diagnose`. It checks the running app with no data of yours: chip, memory, macOS, the Verdict and MLX versions, the GPU facts from `/v1/status`, and for each loaded model its engine label, the active optimizations (tokenizer, attention, matmul), every fallback with its reason, the windowed-attention self-test result and the precision. It then times each loaded model on 20 built-in items (18 short, 2 over 1,000 tokens): single-item median, long-item median and batched items per second, and checks the answers are valid probabilities and that the obvious yes/no answers come out as expected. It only uses models that are already loaded; `--load` first loads Laya English (downloading it on first use). It never starts the app: if Verdict is not running it reports this Mac's facts and says so. The last line is a link that opens GitHub's bug-report form with the report, chip, macOS and version filled in (cut at a line boundary if the link would be too long); add what you saw and submit. `--json` prints the report as JSON, with the link as `issue_url`.
- **Worker exited / orange header** — open the log from the header. Reinstall with `git pull && scripts/install.sh` if the helper is missing or damaged.
- **First load is slow** — that is the download (0.6–1.6 GB per model). Later loads take a few seconds.
- **`verdict` says not running and the app is installed elsewhere** — set `VERDICT_APP=/path/to/Verdict.app`.
- **Wrong language model** — pass `--model laya-multilingual`; auto-routing only switches on non-ASCII text.
