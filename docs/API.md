# Verdict HTTP API (v1)

Verdict is a local System One server. Its main API is TypeSafe's **System One API** — the one Jev serves at `api.typesafe.ai` and OpenRouter at `openrouter.ai/api` — so code written for Jev, with the official SDKs or plain HTTP, runs on Verdict by changing the base URL and the model name. Verdict adds a **batch extension** (`/v1/judge`: many items, one request) and **management endpoints** (status, loading, precision, memory settings). Everything else is a client of this API: the menu-bar app, the `verdict` command, the Swift library VerdictKit and the Python library `verdict.py`.

| Method | Path | Does |
|---|---|---|
| POST | `/v1/systemone` | **System One API**: answer typed questions about one state (TypeSafe's API) |
| GET | `/v1/models` | **System One API**: the model names `model` accepts, with Verdict's catalog fields |
| POST | `/v1/judge` | **Batch extension**: the same questions for many items in one request |
| GET | `/v1/status` | Port, loaded models, memory, Keep Hot settings, recent unloads, the raw catalog |
| POST | `/v1/load` | Load a model, optionally at a precision |
| POST | `/v1/unload` | Unload a model |
| POST | `/v1/delete` | Unload a model and delete its downloaded weights |
| POST | `/v1/settings` | Keep Hot windows and the Memory mode of the running helper |

`/shed`, `/trim` and `/quit` are internal: the app uses them for memory pressure and shutdown. They are not versioned and may change.

Contents: [Base URL](#base-url) · [System One API](#system-one-api) ([request](#post-v1systemone), [answers](#answers), [models](#get-v1models), [errors](#system-one-errors), [differences from Jev](#differences-from-jev), [concurrency](#concurrent-requests), [SDKs](#using-the-typesafe-sdks)) · [Batch extension](#batch-extension-post-v1judge) · [Management](#management) · [Conventions](#conventions) · [Errors (batch and management)](#errors-batch-and-management) · [Clients](#batch-and-management-clients)

## Base URL

The helper listens on a random loopback port chosen at each start; the base URL is `http://127.0.0.1:<port>`. The quickest ways to get it:

```sh
verdict url                                   # http://127.0.0.1:58245 (starts the app if needed)
```

```python
import sys, os; sys.path.insert(0, os.path.expanduser("~/.local/share/verdict"))
import verdict; verdict.base_url()            # the same, from Python
```

VerdictKit's `SystemOneClient()` finds it by itself. By hand: the helper writes its port and process id to

```
~/Library/Application Support/Verdict/status.json      (VERDICT_SUPPORT_DIR overrides the directory)
{"api": 1, "port": 58245, "pid": 88420, "models": {…}, …}
```

1. Read `port` and `pid` from `status.json`. The API is up when both are set and the process `pid` is alive (`kill(pid, 0)` succeeds). After a clean shutdown `port` is `null`.
2. If it is not up, start the app in the background: `open -g /Applications/Verdict.app` (or `~/Applications/Verdict.app`; `scripts/install.sh` records the installed path in `~/.local/share/verdict/app-path`). Poll `status.json` until step 1 succeeds: usually one to three seconds; allow 90.
3. Optionally check `GET /v1/status` → `"api": 1` (and `"version"`, the app version). A Verdict from before the versioned API answers every `/v1/…` path with `404 {"error": "not found"}`; update it.

The port changes whenever the helper restarts (app relaunch, crash recovery, Restart Worker). After a connection error, get the base URL again rather than retrying the old port.

## System One API

### POST /v1/systemone

One state and any number of named, typed questions about it; every question sees the same state and all are answered in one pass. The request and response are TypeSafe's ([OpenAPI](https://api.typesafe.ai/openapi.json), [API reference](https://docs.typesafe.ai/api)).

```sh
curl -s "$(verdict url)/v1/systemone" \
  -H "Authorization: Bearer anything" -H "Content-Type: application/json" -d '{
  "model": "auto",
  "state": {"subject": "Duplicate charge", "message": "I was charged twice for March. Please refund the duplicate today."},
  "questions": {
    "refund":  {"type": "noul", "instructions": "Does the customer ask for money back?"},
    "team":    {"type": "choice", "instructions": "Which team should handle this?",
                "criteria": {"billing": "Charges, invoices, refunds", "technical": "Bugs, outages, integrations", "other": null}},
    "urgency": {"type": "score", "instructions": "How urgent is this?",
                "criteria": ["Can wait", "Needs attention this week", "Needs attention today"]}
  }}'
```

```json
{"answers": {"refund":  {"noul": 0.8591, "type": "noul"},
             "team":    {"choice": "billing", "confidence": 0.7168, "probabilities": {"billing": 0.9262, "other": 0.0478, "technical": 0.026}, "type": "choice"},
             "urgency": {"confidence": 0.5969, "legend": {"0": "Can wait", "1": "Needs attention this week", "2": "Needs attention today"},
                         "probabilities": {"0": 0.0137, "1": 0.1226, "2": 0.8636}, "score": 1.8499, "type": "score"}},
 "model": "laya-english",
 "usage": {"input_tokens": 184, "output_tokens": 0}}
```

| Field | Type | |
|---|---|---|
| `model` | string, required | `"auto"` or a model id from [`/v1/models`](#get-v1models): `laya-english`, `laya-multilingual`, `laya-typed-decisions`, `von-1.2`, `von-1.1`. `auto` picks `laya-english` when the state's letters are ≥ 99.5% ASCII and `laya-multilingual` otherwise; the response's `model` says which. |
| `state` | string, object or array, required | The content every question is about: one shared state (not a list of items; for many items use the [batch extension](#batch-extension-post-v1judge)). An object or array reaches Laya as its JSON text and Von as `key: value` lines, in the key order you send, so name the fields. An object with an `image`, `images`, `audio`, `video` or `videos` key is refused: Verdict judges text. |
| `questions` | object, required, nonempty | Question name → question. The names come back as the answers' keys; they are not shown to the model. Names and labels are compared as exact strings. |
| `bits` | integer, optional | **Verdict extension**: run the model at this precision (Laya 16, 8 or 4; Von 32, 16, 8 or 4; `0` = native). A model loaded at another precision is reloaded and stays at the new one while it stays loaded. With the TypeSafe SDKs, pass it as `extra_body={"bits": 8}` (Python) or `extraBody` in VerdictKit. |

A question is `{"type", "instructions", "criteria"}`. `instructions` (optional) and every description may be a string, an object or an array; structured values reach the model as their JSON text. Unknown fields in a question are ignored.

| `type` | `criteria` | Answer |
|---|---|---|
| `noul` (yes/no) | optional `{"true": …, "false": …}`: what counts as yes and no | `{"type": "noul", "noul": P(yes)}` |
| `choice` | required object: option → description, `null` for the bare option | `{"type": "choice", "choice", "confidence", "probabilities"}` |
| `score` | required nonempty list of level descriptions, lowest first | `{"type": "score", "score", "confidence", "legend", "probabilities"}` |

### Answers

- `noul`: the probability of yes (0–1). No `confidence`: the probability is the answer.
- `choice`: the most probable option, `probabilities` per option (summing to ~1), and `confidence` (0–1; how peaked the distribution is).
- `score`: the expected level, 0…n−1 and fractional; `probabilities` per level (`"0"`, `"1"`, …), `legend` mapping each level back to the description you sent (as sent, structure included), and `confidence`.
- `model`: the model that answered (for `auto`, the one it chose). `usage.input_tokens`: tokens the model read for this request, summed over its questions (each question is its own pass over the state); `usage.output_tokens` is always 0: nothing is generated.
- Every response (errors too) carries an `x-typesafe-request-id` header (`req_` + 32 hex digits), which the SDKs expose as `result.request_id`.

### GET /v1/models

TypeSafe's listing: every name the `model` field accepts, the `auto` alias first.

```json
{"models": [
  {"name": "auto", "alias": true, "release_date": "2026-09-19",
   "description": "Alias: laya-english for English text (letters at least 99.5% ASCII), laya-multilingual for anything else."},
  {"name": "laya-english", "release_date": "2026-09-19",
   "description": "Laya · English: Best English accuracy. MLX port of convaiinnovations/laya. ModernBERT-large (421M), English, 8,192 tokens.",
   "id": "laya-english", "display_name": "Laya · English", "state": "hot", "precision": {…}, "benchmark": {…}, …},
  …],
 "references": [{"name": "jev", "display_name": "Jev · TypeSafe", "state": "hosted", "loadable": false, …}]}
```

`name`, `description` and `release_date` are TypeSafe's fields. Each local model also carries Verdict's catalog fields ([below](#verdicts-fields-in-get-v1models)); `references` holds hosted models Verdict shows for comparison but does not serve.

### System One errors

Request validation failures are `422` with FastAPI's `HTTPValidationError`, as TypeSafe's API returns them: a `detail` list whose entries name the offending field (`loc`), say what is wrong (`msg`) and classify it (`type`: `missing`, `json_invalid`, `too_short`, `union_tag_invalid`, `value_error`, …).

```json
{"detail": [{"loc": ["body", "questions", "team", "choice", "criteria"], "msg": "Field required", "type": "missing",
             "input": {"type": "choice", "instructions": "?"}}]}
```

| Status | When | Example |
|---|---|---|
| 422 | Invalid JSON; a missing or wrong-typed field; an empty `questions`; an unknown question type; a choice without options; a score without levels; an unknown model | `model: Value error, unknown model 'gpt-5'; Verdict serves: auto, laya-english, …` |
| 422 | TypeSafe's hosted model names (`jev`, `jev-latest`, `jev-1.13`, …) | `model: Value error, 'jev-latest' is TypeSafe's hosted model and does not run in Verdict; use one of: auto, …` |
| 422 | A state over the model's context (nothing is truncated), media in the state, a reserved token (Von's `[MASK]`) | `state: Value error, State needs about 9066 tokens; laya-english accepts 8192. Shorten it or split it.` |
| 422 | An invalid `bits` | `bits: Value error, laya-english: Laya precision must be 16, 8 or 4 bits` |
| 403, 415 | The loopback protections ([Conventions](#conventions)) | `{"detail": {"error_type": "permission_error", "message": "cross-origin requests are not accepted"}}` |
| 405 | `GET /v1/systemone` | `{"detail": "Method Not Allowed"}` |
| 507 | The model does not fit in free memory ("Fit in free memory" mode) | `{"detail": {"error_type": "insufficient_memory_error", "message": "laya-typed-decisions at 16-bit needs ~1.9 GB; ~1.0 GB free without swapping. …"}}` |
| 500 | The model failed to load (a download failure) or produced invalid output | `{"detail": {"error_type": "api_error", "message": "…"}}` |

The messages shown are how the SDKs print them (`field: msg`). The Python SDK retries 5xx answers (twice by default), so a 507 is tried again before it reaches you.

### Differences from Jev

- **Models.** Verdict runs open models on your Mac: `auto` and the ids in `/v1/models`, not `jev-latest`. They are smaller than Jev and less accurate on Verdict's benchmark ([README](../README.md#models)); try your questions on both before switching a decision that matters.
- **No key.** Any `Authorization` header is accepted and ignored (the SDKs insist on a key; pass any, such as `"local"`). There is no 401, 429 or 529.
- **Limits.** Context is the model's: 8,192 tokens for the Laya models and Von 1.2, 2,048 for Von 1.1 (Jev: 32,000); the state plus each question must fit. Verdict does not apply Jev's 255-option and 10-level caps, but Laya fits each question into a 192-token budget and shortens long instructions and option descriptions to fit; keep choices to about 20 options. One request carries one state; bodies up to 64 MB.
- **`bits`** is a Verdict extension (above). Unknown top-level fields are ignored.
- **Usage.** `input_tokens` counts what Verdict's model read; `output_tokens` is 0. There is no `cost`.
- **First use** of a model downloads it (0.6–1.6 GB) inside the request and loading takes a few seconds; the SDKs' default 10 s timeout can expire on that first call. `verdict load <id>` beforehand, or raise the timeout.
- **Structured instructions and descriptions** (objects, arrays) reach the model as JSON text. TypeSafe documents that form for Jev; the local models' authors do not, so compare with plain sentences on your task.

### Concurrent requests

Send as many at once as you like. Requests for the same model and precision that arrive while the GPU is busy are merged into its next pass and each gets its own answers back; a request that finds the GPU idle runs at once, so one request at a time costs no extra latency. Answers do not depend on what else was merged: rows are processed in length-sorted chunks exactly as in a [batch](#batch-extension-post-v1judge), and a merged answer can differ from the same request sent alone only as batched answers do, because the GPU's arithmetic depends on the chunk shape (measured: at most 0.0018 in any probability, no answer changed, over 500 requests). Measured on an M5 Max with Laya English, 500 job ads × 2 questions: 500 concurrent calls through the Python SDK's async client ran at ~490 items/s, about 80% of one 500-item batch request (~600/s) and 3× the rate without merging; one request alone takes ~7 ms. For many items you already have together, the batch extension is still the fastest path.

### Using the TypeSafe SDKs

The official SDKs work unchanged: set the base URL, any key, and a Verdict model name.

```python
# pip install typesafe-sdk
from typesafe_sdk import TypeSafeClient, Noul, Choice, Score

client = TypeSafeClient(api_key="local", base_url="http://127.0.0.1:58245", model="auto")   # base_url: `verdict url`
result = client.system_one("I was charged twice. Please help ASAP.", {
    "billing": Noul(instructions="Is this about billing?"),
    "tone": Choice(instructions="What is the tone?", criteria={"calm": None, "angry": None}),
    "urgency": Score(instructions="How urgent is this?", criteria=["low", "medium", "high"]),
})
print(result.nouls["billing"].noul, result.choices["tone"].choice, result.scores["urgency"].score)
```

`AsyncTypeSafeClient` takes the same arguments. `TYPESAFE_BASE_URL=$(verdict url) TYPESAFE_API_KEY=local TYPESAFE_DEFAULT_MODEL=auto` does the same through the environment for both SDKs.

```js
// npm install @typesafe-ai/sdk   (Node 20+)
import { TypeSafeClient, noul, choice, score } from "@typesafe-ai/sdk";

const client = new TypeSafeClient({ apiKey: "local", baseURL: "http://127.0.0.1:58245", defaultModel: "auto" });
const result = await client.systemOne({
  state: "I was charged twice. Please help ASAP.",
  questions: {
    billing: noul("Is this about billing?"),
    tone: choice("What is the tone?", { calm: null, angry: null }),
    urgency: score("How urgent is this?", ["low", "medium", "high"]),
  },
});
console.log(result.answers.billing.noul, result.answers.tone.choice, result.answers.urgency.score);
```

Use `127.0.0.1`, not `localhost`: the helper listens on IPv4 only. Node's `fetch` sends no `Origin` header, so the helper accepts it; a browser page cannot call the API.

```swift
// VerdictKit: finds or launches the local Verdict; SystemOneClient(baseURL:apiKey:model:) talks to any System One server
import VerdictKit

let client = SystemOneClient()
let result = try await client.systemOne(state: "I was charged twice. Please help ASAP.", questions: [
    "billing": .noul("Is this about billing?"),
    "tone": .choice("What is the tone?", options: ["calm": nil, "angry": nil]),
    "urgency": .score("How urgent is this?", levels: ["low", "medium", "high"]),
])
print(result.nouls["billing"]?.noul, result.choices["tone"]?.choice, result.scores["urgency"]?.score)
```

## Batch extension: POST /v1/judge

Verdict's own endpoint for many items with the same questions: each item is its own state, and one request carries up to a few hundred of them. It is the fastest way through a pile you already have (the clients send 256 items per request). Questions and answers use the System One shapes, with Verdict's older answer format: no `type` field, `confidence` on every answer (for a `noul`, max(p, 1 − p)), and no `legend`.


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

These are the System One question shapes, so questions written for Jev work unchanged (a `choice` may also take a plain list of labels here). `confidence` (0–1) says how peaked the answer's distribution is; for a `noul` it is max(p, 1 − p).

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

Request-level errors (nothing is judged): `400` for a malformed body, an empty `items` or `questions`, an unknown question type (`Unknown question type 'maybe'`), an unknown or hosted-only model (`Unknown or hosted-only model 'laya-englsh'; loadable: laya-english, laya-multilingual, …`) or an invalid `bits`; `507` when a model the request needs does not fit in free memory (see [Errors](#errors-batch-and-management)).

## Management

### GET /v1/status

The helper's live state (the same object it writes to `status.json`, plus `catalog`, the raw `models.json`). Abridged:

```json
{
  "api": 1, "version": "0.3.0", "port": 58245, "pid": 88420, "started": 1790372212.99,
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

- `version`: the app version (`null` for a helper run outside the app and a checkout).
- `models`: loaded models. `bits` as loaded (`0` = native). `residency`: `manual` (loaded from the menu or with `"manual": true`; loaded again at the next launch) or `on_demand` (a request needed it). `engine`: `optimized` (Verdict's fast tokenizer and windowed attention, self-tested at load on this Mac) or `mlx` with `engine_reason`.
- `loading` / `downloading`: the model being loaded and whether its weights are downloading. `error`: the last load failure.
- `memory.available_mb`: what the Memory check counts as free now. `refused`: the last memory refusal (`model`, `message`, `at`); `evictions`: the last 20 models unloaded by the helper (`model`, `residency`, `reason`, `at`).
- `manual_idle_minutes`, `on_demand_idle_minutes` (0 = never unload for idleness), `allow_swap`: see [settings](#post-v1settings).
- Times are Unix seconds.

### Verdict's fields in GET /v1/models

Each local model's entry in [`/v1/models`](#get-v1models) also carries what you need to choose it, and hosted models shown for comparison (Jev) are listed under `references` with the same fields. Figures are measured on Verdict's 25-task suite; `benchmark` is at the selected precision, `benchmarks` has every measured precision with `deltas` against the recommended one (the lowest energy within 0.5 accuracy points of the native precision). Abridged:

```json
{"models": [
  {"name": "auto", "alias": true, …},
  {"name": "laya-english", "description": "…", "release_date": "2026-09-19",
   "id": "laya-english", "display_name": "Laya · English", "family": "Laya", "inputs": ["text"], "params": "…", "context": 8192,
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
],
 "references": [{"name": "jev", "id": "jev", "display_name": "Jev · TypeSafe", "state": "hosted", "loadable": false, …}]}
```

- `state`: `hot` (loaded), `downloaded`, `available` (downloads on first use) or `hosted` (a reference model that cannot be loaded; `loadable: false`, `precision: null`).
- `precision` (bits): `selected` is what a load without `bits` uses: the app's Models table choice (read from `config.json` at each load, so a choice made while Verdict runs applies to the next load), else `default`. A loaded model is not reloaded when the choice changes; `loaded` shows what it runs at, or `null`. `default` is the recommended precision.
- `benchmark` fields: `accuracy` (0–1; `accuracy_en`/`accuracy_ml` for the English and multilingual tasks, `sets` per task), `ece` (calibration error, lower is better), `ms` (single-item p50), `items_per_s` (batched), `j_per_1k` (energy per 1,000 judgements, batched), `memory_mb` (loaded footprint). A field that was not measured is absent.

### POST /v1/load

```json
{"model": "von-1.2", "bits": 8, "manual": true}      →      {"loaded": ["laya-multilingual", "von-1.2"]}
```

Loads a model (downloading it the first time) and returns the loaded ids. `bits` (optional, a whole number; `null` = omitted) reloads it at that precision even if it is loaded; without it, a model that is not loaded loads at `precision.selected` from `/v1/models`. `manual` (optional, default false) loads it like the menu's Load: it joins the launch set and follows the "Manually loaded" Keep Hot window; a reload keeps a manual model manual. Without `manual` it is an on-demand load, unloaded after the on-demand idle window. Errors: `400` (unknown model, invalid bits), `507` (does not fit in free memory). A refused precision change leaves the loaded model as it was.

### POST /v1/unload

`{"model": "laya-english"}` → `{"loaded": ["laya-multilingual"]}`. Unloading a model that is not loaded is not an error. The next request that needs it loads it again. Only the menu's Unload removes a model from the launch set.

### POST /v1/delete

`{"model": "laya-typed-decisions"}` → `{"installed": {"laya-english": {"bytes": 842611261}, …}}`. Unloads the model and deletes its downloaded weights from the Hugging Face cache; returns what remains downloaded.

### POST /v1/settings

```json
{"manual_idle_minutes": 0, "on_demand_idle_minutes": 15, "allow_swap": false}
→ {"allow_swap": false, "idle_minutes": 0, "manual_idle_minutes": 0, "on_demand_idle_minutes": 15}
```

Any subset of the fields (`null` = omitted). Idle windows are whole minutes without a request after which a model of that class unloads (`0` = never). `allow_swap: false` is "Fit in free memory": before a load, Verdict checks that the model fits in memory that is free at that moment, unloads idle models to make room (on-demand before manual, least recently used first, never one the current request needs) or refuses with 507. It avoids swap on a best-effort basis: memory use can change after the check. `allow_swap: true` skips the check. The change applies to the running helper only; the app's menu choices are saved and apply at the next launch.

## Conventions

- **JSON.** Every response is JSON with sorted keys. `/v1/systemone` and `/v1/models` fail in TypeSafe's format ([above](#system-one-errors)); the other endpoints fail with `{"error": "<message>"}` and a non-200 status. Messages are written for people and are safe to show verbatim.
- **Security.** The helper binds IPv4 loopback only and has no authentication: any process on this Mac can call it, nothing off the Mac can. An `Authorization` header is accepted and ignored. It refuses what a web page could send: any request with an `Origin` header (403), a `Host` other than `127.0.0.1:<port>` or `localhost:<port>` (403, blocks DNS rebinding), and a POST whose `Content-Type` is not `application/json` (415, blocks form posts that skip CORS preflight). All three are checked before the body is read. Do not forward the port to other machines.
- **Concurrency.** Requests are safe to send concurrently; each is atomic (an unload never lands in the middle of a judgement). Concurrent `/v1/systemone` requests share GPU passes ([above](#concurrent-requests)); other requests run one at a time. A request that needs a model waits while it loads. Each connection carries one request (`Connection: close`).
- **Limits.** A request body may be up to 64 MB; chunked request bodies are refused (send `Content-Length`). Each model has a context limit in tokens (`context` in `/v1/models`: 8,192 for the Laya models and Von 1.2, 2,048 for Von 1.1). Nothing is truncated: an over-long state is a 422 in `/v1/systemone` and a per-item `error` in `/v1/judge`, where the rest of the request still runs.
- **Time.** A model's first use downloads its weights (0.6–1.6 GB) inside the request and loading takes a few seconds; allow minutes for a first request (the Verdict clients wait up to 600 s). A loaded model answers in milliseconds.
- **Versioning.** Paths under `/v1/` keep their meaning; additions (new optional fields, new endpoints) do not bump the version. `"api"` in `/v1/status` changes only with an incompatible change. The original unversioned paths (`/judge`, `/status`, `/load`, `/unload`, `/delete`, `/settings`) remain as aliases for older clients. With the System One API, `/v1/models` became TypeSafe's listing: an entry's `name` is now the model id (the human name moved to `display_name`), the `auto` alias leads the list, and hosted models moved to `references`.

## Errors (batch and management)

| Status | When | Example message |
|---|---|---|
| 400 | Malformed JSON, missing or invalid field (`/v1/judge` and the management endpoints; `/v1/systemone` answers 422, see [its errors](#system-one-errors)), unknown model or question type, invalid precision, a fraction where a whole number is required | `laya-english: Laya precision must be 16, 8 or 4 bits`, `bits must be a whole number, not 4.9` |
| 403 | An `Origin` header, or a `Host` other than `127.0.0.1:<port>` / `localhost:<port>` | `cross-origin requests are not accepted` |
| 404 | Unknown path or wrong method | `not found: GET /v1/nothing`, `/v1/judge takes POST` |
| 415 | POST without `Content-Type: application/json` | `Content-Type must be application/json` |
| 507 | A model does not fit in free memory ("Fit in free memory" mode) | `laya-typed-decisions at 16-bit needs ~1.9 GB; ~1.0 GB free without swapping. Pick 8-bit or allow swap in Verdict → Memory.` |

A 507 says what the load needs, what is free, and the ways out that exist right now (unloading named idle models, a lower precision, allowing swap). Per-item problems (over-long or media items) are not request errors: they come back in that item's result.

## Batch and management clients

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

`--json` prints each row with every probability; `--top N`, `--min X` (with `--sort`), `--model ID` and `--bits N` do what they say. Also `verdict status`, `verdict models [--all] [--json]`, `verdict info MODEL [--json]`, `verdict load ID [--bits N] [--manual]`, `verdict unload ID`, `verdict url` (the base URL for SDKs), `verdict skill [--install DIR]`; `verdict --help` lists them.

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

let client = SystemOneClient()                // the local Verdict, found or launched on the first request
let results = try await client.judge(items: tickets, questions: [
    "refund": .noul("Does the writer ask for money back?"),
    "dept": .choice("Which team should handle this?", ["billing": "charges, refunds", "tech": "bugs, crashes", "other": "none of these"]),
    "urgency": .score("How urgent is this?", levels: ["routine", "this week", "blocking today"]),
])
for (ticket, r) in zip(tickets, results) {
    guard r.ok else { print("skipped:", r.error!); continue }
    if (r["refund"]?.noul ?? 0) > 0.7, r["dept"]?.choice == "billing" { route(ticket) }
}

let verdict = client.verdict                   // management: Verdict(launch:timeout:app:supportDirectory:)
try await verdict.load("von-1.2", bits: 16, manual: false)
let models = try await verdict.models()        // [Model]: state, precision, benchmark, benchmarks, links
let status = try await verdict.status()        // Status: models, memory, evictions, refused, …
```

Items are `String`s or `Item`s (`["subject": "…", "body": "…"]` keeps its key order). `judge(items:questions:model:bits:)` returns one `Judgement` per item (`answers`, `error`, `model`, `ms`); API errors throw `VerdictError.api(status:message:)` with the message verbatim, and `VerdictError.unavailable` when Verdict cannot be reached or started. `Verdict(launch: false)` never starts the app (`SystemOneClient(verdict: Verdict(unchecked: false))` for the client).

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
