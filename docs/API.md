# Verdict HTTP API (v1)

Verdict's models are served by one local HTTP API. Everything else is a client of it: the menu-bar app, the `verdict` command, the Swift library VerdictKit and the Python library `verdict.py`. Use a client when one fits; call the API directly from anything else.

Contents: [Discovery](#discovery) · [Conventions](#conventions) · [Endpoints](#endpoints) · [Judge](#post-v1judge) · [Status](#get-v1status) · [Models](#get-v1models) · [Load, unload, delete](#post-v1load) · [Settings](#post-v1settings) · [Errors](#errors) · [Clients](#clients)

## Discovery

The helper listens on a random loopback port chosen at each start. It writes the port and its process id to

```
~/Library/Application Support/Verdict/status.json      (VERDICT_SUPPORT_DIR overrides the directory)
{"api": 1, "port": 58245, "pid": 88420, "models": {…}, …}
```

1. Read `port` and `pid` from `status.json`. The API is up when both are set and the process `pid` is alive (`kill(pid, 0)` succeeds). After a clean shutdown `port` is `null`.
2. If it is not up, start the app in the background: `open -g /Applications/Verdict.app` (or `~/Applications/Verdict.app`; `scripts/install.sh` records the installed path in `~/.local/share/verdict/app-path`). Poll `status.json` until step 1 succeeds: usually one to three seconds; allow 90.
3. Optionally check `GET /v1/status` → `"api": 1`. A Verdict from before the versioned API answers every `/v1/…` path with `404 {"error": "not found"}`; update it.

The port changes whenever the helper restarts (app relaunch, crash recovery, Restart Worker). After a connection error, read `status.json` again rather than retrying the old port.

## Conventions

- **Base URL** `http://127.0.0.1:<port>`. Every response is JSON with sorted keys; failures are `{"error": "<message>"}` with a non-200 status. Messages are written for people and are safe to show verbatim.
- **Security.** The helper binds IPv4 loopback only and has no authentication: any process on this Mac can call it, nothing off the Mac can. It refuses what a web page could send: any request with an `Origin` header (403), a `Host` other than `127.0.0.1:<port>` or `localhost:<port>` (403, blocks DNS rebinding), and a POST whose `Content-Type` is not `application/json` (415, blocks form posts that skip CORS preflight). All three are checked before the body is read. Do not forward the port to other machines.
- **Concurrency.** Requests are served one at a time. Concurrent clients are safe (each request is atomic; an unload never lands in the middle of a judge) but do not run in parallel, so throughput comes from batching items into one request, not from parallel requests. A request that needs a model waits while it loads.
- **Limits.** A request body may be up to 64 MB. Each model has a context limit in tokens (`context` in `/v1/models`: 8,192 for the Laya models and Von 1.2, 2,048 for Von 1.1). An item that does not fit gets a per-item `error`; items are never truncated, and the rest of the request still runs. Clients send at most a few hundred items per request (the clients use 256).
- **Time.** A model's first use downloads its weights (0.6–1.6 GB) inside the request and loading takes a few seconds; allow minutes for a first request (the clients wait up to 600 s). A loaded model answers in milliseconds per item.
- **Versioning.** Paths under `/v1/` keep their meaning; additions (new optional fields, new endpoints) do not bump the version. `"api"` in `/v1/status` changes only with an incompatible change. The original unversioned paths (`/judge`, `/status`, `/load`, `/unload`, `/delete`, `/settings`) remain as aliases for older clients.

## Endpoints

| Method | Path | Does |
|---|---|---|
| POST | `/v1/judge` | Answer typed questions about items |
| GET | `/v1/status` | Port, loaded models, memory, Keep Hot settings, recent unloads, the raw catalog |
| GET | `/v1/models` | Catalog with each model's state, precision and measured figures |
| POST | `/v1/load` | Load a model, optionally at a precision |
| POST | `/v1/unload` | Unload a model |
| POST | `/v1/delete` | Unload a model and delete its downloaded weights |
| POST | `/v1/settings` | Keep Hot windows and the Memory mode of the running helper |

`/shed`, `/trim` and `/quit` are internal: the app uses them for memory pressure and shutdown. They are not versioned and may change.

## POST /v1/judge

```json
{
  "items": ["I was charged twice for March, please refund the duplicate.",
            {"subject": "App crash", "body": "The app crashes when I open settings."},
            {"image": "/tmp/receipt.png"}],
  "questions": {
    "refund":  {"type": "noul", "instructions": "Does the writer ask for money back?"},
    "dept":    {"type": "choice", "instructions": "Which team should handle this?",
                "criteria": {"billing": "charges, invoices, refunds", "tech": "bugs, crashes, outages", "other": "none of these"}},
    "urgency": {"type": "score", "instructions": "How urgent is this?",
                "criteria": ["routine question", "needs an answer this week", "blocking work today"]}
  }
}
```

| Field | Type | |
|---|---|---|
| `items` | nonempty list | Strings, or any JSON value. An object is judged as its JSON text (Laya) or `key: value` lines (Von), in the key order you send, so name the fields. A string stays a string even when it looks like JSON. An object with an `image`, `images`, `audio`, `video` or `videos` key gets a per-item error: Verdict judges text. |
| `questions` | nonempty object | Question id → question. Every question is answered for every item in the same pass. Ids and labels are compared as exact strings. |
| `model` | string, optional | `"auto"` (default) or a model id from `/v1/models`. `auto` sends an item whose letters are ≥ 99.5% ASCII to `laya-english` and anything else to `laya-multilingual`; one request can use both. |
| `bits` | integer, optional | A whole number (`4.9` is refused, not truncated; `null` is the same as leaving it out). Run the model(s) at this precision: Laya 16, 8 or 4; Von 32, 16, 8 or 4; `0` means the model's native precision (Laya 16, Von 32). A model loaded at another precision is reloaded and stays at the new precision while it stays loaded; after an unload, a load without `bits` uses `precision.selected` again. Checked for every model the request uses before anything loads. |

A question is `{"type", "instructions", "criteria"}`:

| `type` | `criteria` | Answer |
|---|---|---|
| `noul` (yes/no) | optional `{"true": "…", "false": "…"}` | `noul`: P(true); `confidence` |
| `choice` | object label → description (`null` = the bare label), or a list of labels | `choice`: the most probable label; `probabilities` per label; `confidence` |
| `score` | list of levels, lowest first | `score`: the expected level, 0…n-1 (fractional); `probabilities` per level index; `confidence` |

These shapes follow the TypeSafe/Laya convention, so questions written for Jev work unchanged. `confidence` (0–1) says how peaked the answer's distribution is; for a `noul` it is max(p, 1 − p).

Response: one result per item, in item order. `model` is the model that judged it; `ms` is the wall time per item for that model's share of the request. An item that could not be judged has `error` instead of `answers`:

```json
{
  "results": [
    {"answers": {"dept": {"choice": "billing", "confidence": 0.8828, "probabilities": {"billing": 0.9762, "other": 0.0096, "tech": 0.0142}},
                 "refund": {"confidence": 0.8801, "noul": 0.8801},
                 "urgency": {"confidence": 0.2337, "probabilities": {"0": 0.1035, "1": 0.2289, "2": 0.6677}, "score": 1.5642}},
     "model": "laya-english", "ms": 14.0},
    {"answers": {"dept": {"choice": "tech", "confidence": 0.9153, "probabilities": {"billing": 0.0062, "other": 0.0099, "tech": 0.9839}},
                 "refund": {"confidence": 0.907, "noul": 0.093},
                 "urgency": {"confidence": 0.5136, "probabilities": {"0": 0.0138, "1": 0.1753, "2": 0.8109}, "score": 1.7971}},
     "model": "laya-english", "ms": 14.0},
    {"error": "Verdict judges text; image, audio and video items are not supported.", "model": null, "ms": 0}
  ]
}
```

Per-item errors (the request still returns 200):

```json
{"error": "Item needs about 9026 tokens; laya-english accepts 8192. Shorten it or split it.", "model": "laya-english", "ms": 0}
```

Request-level errors (nothing is judged): `400` for a malformed body, an empty `items` or `questions`, an unknown question type (`Unknown question type 'maybe'`), an unknown or hosted-only model (`Unknown or hosted-only model 'laya-englsh'; loadable: laya-english, laya-multilingual, …`) or an invalid `bits`; `507` when a model the request needs does not fit in free memory (see [Errors](#errors)).

## GET /v1/status

The helper's live state (the same object it writes to `status.json`, plus `catalog`, the raw `models.json`). Abridged:

```json
{
  "api": 1, "port": 58245, "pid": 88420, "started": 1790372212.99,
  "calls": 1, "items": 2, "last_ms": 14.0, "last_used": 1790372223.96,
  "loading": null, "downloading": false, "error": null, "refused": null, "evictions": [],
  "manual_idle_minutes": 0, "on_demand_idle_minutes": 5, "allow_swap": false,
  "gpu": {"chip": "M5 Max", "architecture": "applegpu_g17s", "generation": 17, "macos": "26.6.0", "neural_accelerators": true},
  "memory": {"rss_mb": 760.0, "mlx_active_mb": 1486.0, "mlx_cache_mb": 503.0, "available_mb": 81742.0},
  "installed": {"laya-english": {"bytes": 842611261}, "laya-multilingual": {"bytes": 643837515}},
  "models": {
    "laya-english": {"bits": 0, "context": 8192, "device": "mlx", "engine": "optimized", "engine_reason": null,
                     "load_s": 0.1, "memory_estimate_mb": 1271.0, "residency": "on_demand", "last_used": 1790372223.96,
                     "optimizations": {"attention": "windowed", "matmul": "neural accelerators", "optimized": true, "tokenizer": "fast"}}
  }
}
```

- `models`: loaded models. `bits` as loaded (`0` = native). `residency`: `manual` (loaded from the menu or with `"manual": true`; loaded again at the next launch) or `on_demand` (a request needed it). `engine`: `optimized` (Verdict's fast tokenizer and windowed attention, self-tested at load on this Mac) or `mlx` with `engine_reason`.
- `loading` / `downloading`: the model being loaded and whether its weights are downloading. `error`: the last load failure.
- `memory.available_mb`: what the Memory check counts as free now. `refused`: the last memory refusal (`model`, `message`, `at`); `evictions`: the last 20 models unloaded by the helper (`model`, `residency`, `reason`, `at`).
- `manual_idle_minutes`, `on_demand_idle_minutes` (0 = never unload for idleness), `allow_swap`: see [settings](#post-v1settings).
- Times are Unix seconds.

## GET /v1/models

Every catalog model with what you need to choose one. Figures are measured on Verdict's 25-task suite; `benchmark` is at the selected precision, `benchmarks` has every measured precision with `deltas` against the recommended one (the lowest energy within 0.5 accuracy points of the native precision). Abridged:

```json
{"models": [
  {"id": "laya-english", "name": "Laya · English", "family": "Laya", "inputs": ["text"], "params": "…", "context": 8192,
   "languages": "…", "license": "…", "state": "hot", "loadable": true,
   "precision": {"selected": 16, "default": 16, "loaded": 16, "options": [16, 8, 4]},
   "benchmark": {"accuracy": 0.508, "accuracy_en": 0.545, "accuracy_ml": 0.42, "ece": 0.208, "ms": 7.71, "items_per_s": 608.0,
                 "j_per_1k": 373.5, "memory_mb": 1271, "n_tasks": 25, "sets": {"ag_news": 0.963, …},
                 "source": "measured", "date": "2026-09-25", "hardware": "Apple M5 Max, macOS 26.6"},
   "benchmarks": {"16": {…}, "8": {…, "deltas": {…}},
                  "4": {"accuracy": 0.497, "ms": 8.45, "j_per_1k": 428.8, "memory_mb": 712, …,
                        "deltas": {"accuracy": "−1.1 pt", "ece": "−0.011", "energy": "15% more energy", "speed": "10% slower"}}},
   "links": {"upstream": "https://…", "weights": "https://huggingface.co/aac6fef/laya-mlx", …},
   "recommendation": "…"}
]}
```

- `state`: `hot` (loaded), `downloaded`, `available` (downloads on first use) or `hosted` (a reference model that cannot be loaded; `loadable: false`, `precision: null`).
- `precision` (bits): `selected` is what a load without `bits` uses: the app's Models table choice (read from `config.json` at each load, so a choice made while Verdict runs applies to the next load), else `default`. A loaded model is not reloaded when the choice changes; `loaded` shows what it runs at, or `null`. `default` is the recommended precision.
- `benchmark` fields: `accuracy` (0–1; `accuracy_en`/`accuracy_ml` for the English and multilingual tasks, `sets` per task), `ece` (calibration error, lower is better), `ms` (single-item p50), `items_per_s` (batched), `j_per_1k` (energy per 1,000 judgements, batched), `memory_mb` (loaded footprint). A field that was not measured is absent.

## POST /v1/load

```json
{"model": "von-1.2", "bits": 8, "manual": true}      →      {"loaded": ["laya-multilingual", "von-1.2"]}
```

Loads a model (downloading it the first time) and returns the loaded ids. `bits` (optional, a whole number; `null` = omitted) reloads it at that precision even if it is loaded; without it, a model that is not loaded loads at `precision.selected` from `/v1/models`. `manual` (optional, default false) loads it like the menu's Load: it joins the launch set and follows the "Manually loaded" Keep Hot window; a reload keeps a manual model manual. Without `manual` it is an on-demand load, unloaded after the on-demand idle window. Errors: `400` (unknown model, invalid bits), `507` (does not fit in free memory). A refused precision change leaves the loaded model as it was.

## POST /v1/unload

`{"model": "laya-english"}` → `{"loaded": ["laya-multilingual"]}`. Unloading a model that is not loaded is not an error. The next request that needs it loads it again. Only the menu's Unload removes a model from the launch set.

## POST /v1/delete

`{"model": "laya-typed-decisions"}` → `{"installed": {"laya-english": {"bytes": 842611261}, …}}`. Unloads the model and deletes its downloaded weights from the Hugging Face cache; returns what remains downloaded.

## POST /v1/settings

```json
{"manual_idle_minutes": 0, "on_demand_idle_minutes": 15, "allow_swap": false}
→ {"allow_swap": false, "idle_minutes": 0, "manual_idle_minutes": 0, "on_demand_idle_minutes": 15}
```

Any subset of the fields (`null` = omitted). Idle windows are whole minutes without a request after which a model of that class unloads (`0` = never). `allow_swap: false` is "Fit in free memory": before a load, Verdict checks that the model fits in memory that is free at that moment, unloads idle models to make room (on-demand before manual, least recently used first, never one the current request needs) or refuses with 507. It avoids swap on a best-effort basis: memory use can change after the check. `allow_swap: true` skips the check. The change applies to the running helper only; the app's menu choices are saved and apply at the next launch.

## Errors

| Status | When | Example message |
|---|---|---|
| 400 | Malformed JSON, missing or invalid field, unknown model or question type, invalid precision, a fraction where a whole number is required | `laya-english: Laya precision must be 16, 8 or 4 bits`, `bits must be a whole number, not 4.9` |
| 403 | An `Origin` header, or a `Host` other than `127.0.0.1:<port>` / `localhost:<port>` | `cross-origin requests are not accepted` |
| 404 | Unknown path or wrong method | `not found: GET /v1/nothing`, `/v1/judge takes POST` |
| 415 | POST without `Content-Type: application/json` | `Content-Type must be application/json` |
| 507 | A model does not fit in free memory ("Fit in free memory" mode) | `laya-typed-decisions at 16-bit needs ~1.9 GB; ~1.0 GB free without swapping. Pick 8-bit or allow swap in Verdict → Memory.` |

A 507 says what the load needs, what is free, and the ways out that exist right now (unloading named idle models, a lower precision, allowing swap). Per-item problems (over-long or media items) are not request errors: they come back in that item's result.

## Clients

### curl

```sh
STATUS="$HOME/Library/Application Support/Verdict/status.json"
[ -f "$STATUS" ] && kill -0 "$(plutil -extract pid raw -o - "$STATUS")" 2>/dev/null || { open -g -a Verdict; sleep 3; }
PORT=$(plutil -extract port raw -o - "$STATUS")

curl -s "http://127.0.0.1:$PORT/v1/judge" -H 'Content-Type: application/json' -d '{
  "items": ["I was charged twice, please refund the duplicate.", "Do you ship to Canada?"],
  "questions": {"refund": {"type": "noul", "instructions": "Does the writer ask for money back?"}}}'
```

### The `verdict` command

Installed at `~/.local/bin/verdict` (a link to `Verdict.app/Contents/Helpers/verdict`). JSONL in, one short line per item out:

```sh
$ verdict judge --questions q.json --field text --sort refund < tickets.jsonl
#0  refund=0.88  dept=billing(0.88)  | I was charged twice for March, please refund the duplicate.
#1  refund=0.09  dept=tech(0.86)  | The app crashes when I open settings.
#2  refund=0.00  dept=other(0.17)  | Do you ship to Canada?
```

`--json` prints each row with every probability; `--top N`, `--min X` (with `--sort`), `--model ID` and `--bits N` do what they say. Also `verdict status`, `verdict models [--all] [--json]`, `verdict info MODEL [--json]`, `verdict load ID [--bits N] [--manual]`, `verdict unload ID`, `verdict skill [--install DIR]`; `verdict --help` lists them.

### Python (standard library)

The installed library wraps discovery, launching and batching:

```python
import sys, os; sys.path.insert(0, os.path.expanduser("~/.local/share/verdict"))
from verdict import judge, Noul, Choice

r = judge("please refund me", {"refund": Noul("Does the writer ask for money back?"),
                               "dept": Choice("Which team?", billing="charges, refunds", other="anything else")})
r.refund > 0.7, r.dept == "billing", r.dept.probabilities
```

Or the API with nothing but `urllib`:

```python
import json, os, urllib.error, urllib.request

status = json.load(open(os.path.expanduser("~/Library/Application Support/Verdict/status.json")))
body = {"items": ["please refund me"], "questions": {"refund": {"type": "noul", "instructions": "Does the writer ask for money back?"}}}
request = urllib.request.Request(f"http://127.0.0.1:{status['port']}/v1/judge", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(request, timeout=600) as response:
        print(json.load(response)["results"][0]["answers"]["refund"]["noul"])
except urllib.error.HTTPError as error:
    print(error.code, json.load(error)["error"])
```

### Swift (VerdictKit)

VerdictKit is a library product of this package (Foundation only; resolving the package also fetches the engine's dependencies, but only VerdictKit is built). macOS 14+.

```swift
// Package.swift: .package(url: "https://github.com/TobyNoSkillSon/Verdict", branch: "main")
//                .product(name: "VerdictKit", package: "Verdict")
import VerdictKit

let verdict = try await Verdict()            // finds the running app, or launches it and waits (90 s)
let results = try await verdict.judge(tickets, [
    "refund": .noul("Does the writer ask for money back?"),
    "dept": .choice("Which team should handle this?", ["billing": "charges, refunds", "tech": "bugs, crashes", "other": "none of these"]),
    "urgency": .score("How urgent is this?", levels: ["routine", "this week", "blocking today"]),
])
for (ticket, r) in zip(tickets, results) {
    guard r.ok else { print("skipped:", r.error!); continue }
    if (r["refund"]?.noul ?? 0) > 0.7, r["dept"]?.choice == "billing" { route(ticket) }
}

try await verdict.load("von-1.2", bits: 16, manual: false)
let models = try await verdict.models()        // [Model]: state, precision, benchmark, benchmarks, links
let status = try await verdict.status()        // Status: models, memory, evictions, refused, …
```

Items are `String`s or `Item`s (`["subject": "…", "body": "…"]` keeps its key order). `judge(_:_:model:bits:)` returns one `Judgement` per item (`answers`, `error`, `model`, `ms`); API errors throw `VerdictError.api(status:message:)` with the message verbatim, and `VerdictError.unavailable` when Verdict cannot be reached or started. `Verdict(launch: false)` never starts the app.

### JavaScript (Node 18+)

```js
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const { port } = JSON.parse(readFileSync(`${homedir()}/Library/Application Support/Verdict/status.json`, "utf8"));
const response = await fetch(`http://127.0.0.1:${port}/v1/judge`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    items: ["please refund me", "Do you ship to Canada?"],
    questions: { refund: { type: "noul", instructions: "Does the writer ask for money back?" } },
  }),
});
const reply = await response.json();
if (!response.ok) throw new Error(`${response.status}: ${reply.error}`);
for (const r of reply.results) console.log(r.error ?? r.answers.refund.noul);
```

Node's `fetch` sends no `Origin` header, so the helper accepts it. A browser page cannot call the API: browsers always send `Origin`.
