# Verdict HTTP API (v1)

Verdict is a local System One server. Its main endpoint is compatible with the **System One API (TypeSafe Jev)** and works with the TypeSafe SDK, so code written for Jev, with the SDK or plain HTTP, runs on Verdict by changing the base URL and the model name. Verdict is independent of TypeSafe. Verdict adds a **batch extension** (`/v1/judge`: many items, one request) and **management endpoints** (status, loading, precision, memory settings). Everything else is a client of this API: the menu-bar app, the `verdict` command, the Swift library VerdictKit and the Python library `verdict.py`.

| Method | Path | Does |
|---|---|---|
| POST | `/v1/systemone` | **System One API**: answer typed questions about one state |
| GET | `/v1/models` | **System One API**: the model names `model` accepts, with Verdict's catalog fields |
| POST | `/v1/judge` | **Batch extension**: the same questions for many items in one request |
| GET | `/v1/status` | Port, loaded models, memory, Keep Hot settings, recent unloads, the raw catalog |
| POST | `/v1/load` | Load a model, optionally at a precision |
| POST | `/v1/unload` | Unload a model |
| POST | `/v1/delete` | Unload a model and delete its downloaded weights |
| POST | `/v1/settings` | Keep Hot windows and the Memory mode of the running helper |

`/shed`, `/trim` and `/quit` are internal: the app uses them for memory pressure and shutdown. They are not versioned and may change.

Contents: [Base URL](#base-url) · [System One API](#system-one-api) ([request](#post-v1systemone), [answers](#answers), [models](#get-v1models), [errors](#system-one-errors), [differences from Jev](#differences-from-jev), [concurrency](#concurrent-requests), [SDKs](#using-the-typesafe-sdk)) · [Batch extension](#batch-extension-post-v1judge) · [Management](#management) · [Conventions](#conventions) · [Errors (batch and management)](#errors-batch-and-management) · [Clients](#batch-and-management-clients)

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

One state and any number of named, typed questions about it; every question sees the same state and all are answered in one pass. Request and response follow the System One API; TypeSafe's [API reference](https://docs.typesafe.ai/api) is the reference for the full schema.

```sh
curl -s "$(verdict url)/v1/systemone" \
  -H "Content-Type: application/json" -H "Authorization: Bearer local" -d '{
  "model": "auto",
  "state": {"title": "Checkout button does nothing on Safari 17",
            "body": "Clicking Pay shows a spinner forever. Chrome works. It started after Tuesday'"'"'s deploy."},
  "questions": {
    "regression": {"type": "noul", "instructions": "Did this start after a recent change?"},
    "component":  {"type": "choice", "instructions": "Which component is at fault?",
                   "criteria": {"payments": "Checkout, cards, invoices", "frontend": "Pages, buttons, browser quirks", "infra": null}},
    "severity":   {"type": "score", "instructions": "How badly are users blocked?",
                   "criteria": ["Cosmetic", "A workaround exists", "Users cannot finish"]}
  }}'
```

```json
{"answers": {"component":  {"choice": "frontend", "confidence": 0.1628, "probabilities": {"frontend": 0.623, "infra": 0.1607, "payments": 0.2163}, "type": "choice"},
             "regression": {"noul": 0.7696, "type": "noul"},
             "severity":   {"confidence": 0.5691, "legend": {"0": "Cosmetic", "1": "A workaround exists", "2": "Users cannot finish"},
                            "probabilities": {"0": 0.0346, "1": 0.8646, "2": 0.1008}, "score": 1.0663, "type": "score"}},
 "model": "laya-english",
 "usage": {"input_tokens": 218, "output_tokens": 0}}
```

| Field | Type | |
|---|---|---|
| `model` | string, required | `"auto"` or a model id from [`/v1/models`](#get-v1models): `laya-english`, `laya-multilingual`, `laya-typed-decisions`, `von-1.2`, `von-1.1`. `auto` picks `laya-english` when the state's letters are ≥ 99.5% ASCII and `laya-multilingual` otherwise; the response's `model` says which. |
| `state` | string, object or array, required | The content every question is about: one shared state (not a list of items; for many items use the [batch extension](#batch-extension-post-v1judge)). An object or array reaches Laya as its JSON text and Von as `key: value` lines, in the key order you send, so name the fields. An object with an `image`, `images`, `audio`, `video` or `videos` key is refused: Verdict judges text. |
| `questions` | object, required, nonempty | Question name → question. The names come back as the answers' keys; they are not shown to the model. Names and labels are compared as exact strings. |
| `bits` | integer, optional | **Verdict extension**: the precision this request requires (Laya 16, 8 or 4; Von 32, 16, 8 or 4; `0` = native). A model runs at one precision for every client — the one it is loaded at, else `precision.selected` in `/v1/models` — so a request never changes it: other bits get `409` (`conflict_error`) and nothing reloads. To change it for everyone, `POST /v1/load` with `bits` (the menu's Reload). With the TypeSafe SDK, pass it as `extra_body={"bits": 8}` (Python) or `extraBody` in VerdictKit. |
| `merge` | boolean, optional | **Verdict extension**: `false` runs this request in a GPU pass of its own, so its answers are exactly what it gets sent alone ([Concurrent requests](#concurrent-requests)). Default `true`. |

Every reply that ran on a model carries an `x-verdict-bits` header with the precision that answered (effective bits: `16`, not `0`).

A question is `{"type", "instructions", "criteria"}`. `instructions` (optional) and each description can be text or structured JSON (an object or array), which the model reads as its JSON text. Unknown fields in a question are ignored.

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

The System One API's model listing: every name the `model` field accepts, the `auto` alias first.

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

`name`, `description` and `release_date` are the System One API's fields. Each local model also carries Verdict's catalog fields ([below](#verdicts-fields-in-get-v1models)); `references` holds hosted models Verdict shows for comparison but does not serve. The `auto` entry carries the same catalog fields with neutral values (`"state": "alias"`, `"loadable": false`, empty `benchmarks`), so clients that read those fields from every entry keep working; skip the entry with `"alias": true` when you list models.

### System One errors

Request validation failures are `422` with FastAPI's `HTTPValidationError`, the System One API's validation error: a `detail` list whose entries name the offending field (`loc`), say what is wrong (`msg`) and classify it (`type`: `missing`, `json_invalid`, `too_short`, `union_tag_invalid`, `value_error`, …).

```json
{"detail": [{"loc": ["body", "questions", "team", "choice", "criteria"], "msg": "Field required", "type": "missing",
             "input": {"type": "choice", "instructions": "?"}}]}
```

| Status | When | Example |
|---|---|---|
| 422 | Invalid JSON; a missing or wrong-typed field; an empty `questions`; an unknown question type; a choice without options; a score without levels; an unknown model | `model: Value error, unknown model 'gpt-5'; Verdict serves: auto, laya-english, …` |
| 422 | TypeSafe's hosted model names (`jev`, `jev-latest`, `jev-1.13`, …) | `model: Value error, 'jev-latest' is TypeSafe's hosted model and does not run in Verdict; use one of: auto, …` |
| 422 | A state over the model's context (nothing is truncated), media in the state, a reserved token (Von's `[MASK]`) | `state: Value error, State needs about 9066 tokens; laya-english accepts 8192. Shorten it or split it.` |
| 422 | An invalid `bits` or `merge` | `bits: Value error, laya-english: Laya precision must be 16, 8 or 4 bits` |
| 409 | `bits` other than the precision the model runs at | `{"detail": {"error_type": "conflict_error", "message": "laya-english is loaded at 16-bit for every client; this request asked for 8-bit. …"}}` |
| 403, 415 | The loopback protections ([Conventions](#conventions)) | `{"detail": {"error_type": "permission_error", "message": "cross-origin requests are not accepted"}}` |
| 405 | `GET /v1/systemone`, `POST /v1/models` | `{"detail": "Method Not Allowed"}` |
| 404 | A `/v1` path Verdict does not serve, including a trailing slash (`/v1/systemone/`) | `{"detail": "Not Found"}` |
| 507 | The model does not fit in free memory ("Fit in free memory" mode) | `{"detail": {"error_type": "insufficient_memory_error", "message": "laya-typed-decisions at 16-bit needs ~1.9 GB; ~1.0 GB free without swapping. …"}}` |
| 500 | The model failed to load (a download failure) or produced invalid output | `{"detail": {"error_type": "api_error", "message": "…"}}` |

The messages shown are how the SDKs print them (`field: msg`). The Python SDK retries 5xx answers (twice by default), so a 507 is tried again before it reaches you.

### Differences from Jev

- **Models.** Verdict runs open models on your Mac: `auto` and the ids in `/v1/models`, not `jev-latest`. They are smaller than Jev and less accurate on Verdict's benchmark ([README](../README.md#models)); try your questions on both before switching a decision that matters.
- **No key.** Any `Authorization` header is accepted and ignored (the SDKs insist on a key; pass any, such as `"local"`). There is no 401, 429 or 529.
- **Limits.** Context is the model's: 8,192 tokens for the Laya models and Von 1.2, 2,048 for Von 1.1 (Jev: 32,000); the state plus each question must fit. Verdict does not apply Jev's 255-option and 10-level caps, but Laya fits each question into a 192-token budget and shortens long instructions and option descriptions to fit; keep choices to about 20 options. One request carries one state; bodies up to 64 MB.
- **`bits` and `merge`** are Verdict extensions (above). Unknown top-level fields are ignored.
- **Empty choices.** A `choice` with `criteria: {}` is a 422 (`a choice needs at least one option`). The OpenAPI schema does not forbid an empty object, but there is nothing to choose from.
- **Usage.** `input_tokens` counts what Verdict's model read; `output_tokens` is 0. There is no `cost`.
- **First use** of a model downloads it (0.6–1.6 GB) inside the request and loading takes a few seconds; the SDK's default 10 s timeout can expire on that first call. `verdict load <id>` beforehand, or raise the timeout.
- **Merging** of concurrent requests can move an answer slightly ([below](#concurrent-requests)); `"merge": false` opts out per request.
- **Structured instructions and descriptions** (objects, arrays) reach the model as JSON text. The System One API allows that form; the local models' authors do not document it, so compare with plain sentences on your task.

### Concurrent requests

Requests for the same model that arrive while the GPU is busy are merged into its next pass, and each gets its own answers back; a request that finds the GPU idle runs at once, so one request at a time costs no extra latency. Every request in a pass runs at the model's one precision (a request asking for another gets `409`, above), so merging never reloads a model and one client's `bits` never changes another client's answers. Measured on an M5 Max with Laya English, 500 job ads × 2 questions: 500 concurrent calls through the Python SDK's async client ran at ~490 items/s, about 80% of one 500-item batch request (~600/s) and 3× the rate without merging; one request alone takes ~7 ms.

**Merged answers are close to, not identical with, the answer alone.** Rows are processed in length-sorted chunks exactly as in a [batch](#batch-extension-post-v1judge), and the model's arithmetic depends on what shares its chunk. Measured on an M5 Max, the same state judged alone and in one pass with 20–200 states of other lengths moved by up to **0.0296** in a probability with Laya English at 16-bit (0.015 at 8-bit, 0.002 at 4-bit; at most 0.0001 with Laya Multilingual and with Von 1.2). In a realistic mixed concurrent run the largest move was 0.003, and one yes/no answer near the threshold flipped: **0.5007 alone, 0.4998 merged**. This is the models' own batch dependence, not a Verdict bug: the Python reference implementation moves by the identical 0.0296, and Verdict's answers equal the reference's both alone and batched. `/v1/judge` behaves the same way, since an item there shares its pass with the other items of its request. So a merged answer can differ from the same request sent alone by up to about 0.03; do not treat a value within that of a threshold as settled. When you need the single-request result exactly, send `"merge": false` (`extra_body={"merge": False}` with the SDK): that request gets a pass of its own and the answer it gets alone, at the cost of the merging speed-up.

**Many requests at once with the SDK.** The server keeps up, but the client's own queue can outlast its timeout. With the Python SDK's async client at its defaults (10 s timeout, two retries), 500 and 2,000 simultaneous calls all succeeded; 5,000 at once left about 600 with `TypeSafeAPITimeoutError`, because calls waited in the client for longer than the timeout and retry budget (the server's call count matched the successful calls, so nothing was answered twice). For thousands of calls, raise the timeout (`AsyncTypeSafeClient(..., timeout=120)`) or bound the calls in flight (an `asyncio.Semaphore` of a few hundred). For thousands of items you already have together, the batch extension is faster still: one `/v1/judge` request per few hundred items.

### Using the TypeSafe SDK

Verdict works with the TypeSafe SDK: set the base URL, any key, and a Verdict model name.

```python
# pip install typesafe-sdk
from typesafe_sdk import TypeSafeClient, Noul, Choice, Score

client = TypeSafeClient(api_key="local", base_url="http://127.0.0.1:58245", model="auto")   # base_url: `verdict url`
review = client.system_one("Update 3.2 logs me out every time I switch apps.", {
    "bug": Noul(instructions="Does the writer report something broken?"),
    "kind": Choice(instructions="What kind of message is this?", criteria={"bug": None, "feature": None, "question": None}),
    "priority": Score(instructions="How soon does it need a fix?", criteria=["whenever", "this sprint", "today"]),
})
print(review.nouls["bug"].noul, review.choices["kind"].choice, review.scores["priority"].score)   # 0.7707 bug 1.7577
```

`AsyncTypeSafeClient` takes the same arguments. `TYPESAFE_BASE_URL=$(verdict url) TYPESAFE_API_KEY=local TYPESAFE_DEFAULT_MODEL=auto` does the same through the environment, in Python and in JavaScript.

```js
// npm install @typesafe-ai/sdk   (Node 20+)
import { TypeSafeClient, noul, choice, score } from "@typesafe-ai/sdk";

const local = new TypeSafeClient({ apiKey: "local", baseURL: "http://127.0.0.1:58245", defaultModel: "auto" });
const review = await local.systemOne({
  state: "Update 3.2 logs me out every time I switch apps.",
  questions: {
    bug: noul("Does the writer report something broken?"),
    kind: choice("What kind of message is this?", { bug: null, feature: null, question: null }),
    priority: score("How soon does it need a fix?", ["whenever", "this sprint", "today"]),
  },
});
console.log(review.answers.bug.noul, review.answers.kind.choice, review.answers.priority.score);
```

Use `127.0.0.1`, not `localhost`: the helper listens on IPv4 only. Node's `fetch` sends no `Origin` header, so the helper accepts it; a browser page cannot call the API.

```swift
// VerdictKit: finds or launches the local Verdict; SystemOneClient(baseURL:apiKey:model:) talks to any compatible server
import VerdictKit

let client = SystemOneClient()
let review = try await client.systemOne(state: "Update 3.2 logs me out every time I switch apps.", questions: [
    "bug": .noul("Does the writer report something broken?"),
    "kind": .choice("What kind of message is this?", labels: ["bug", "feature", "question"]),
    "priority": .score("How soon does it need a fix?", levels: ["whenever", "this sprint", "today"]),
])
print(review.nouls["bug"]?.noul, review.choices["kind"]?.choice, review.scores["priority"]?.score)
```

## Batch extension: POST /v1/judge

Verdict's own endpoint for many items with the same questions: each item is its own state, and one request carries up to a few hundred of them. It is the fastest way through a pile you already have (the clients send 256 items per request). Questions and answers use the System One shapes, with Verdict's older answer format: no `type` field, `confidence` on every answer (for a `noul`, max(p, 1 − p)), and no `legend`.


```json
{
  "items": ["The Pay button spins forever since Tuesday's deploy; nobody can check out.",
            {"title": "Dark mode", "body": "Would love a dark theme for the dashboard."},
            {"image": "/tmp/screenshot.png"}],
  "questions": {
    "bug":      {"type": "noul", "instructions": "Does the writer report something broken?"},
    "kind":     {"type": "choice", "instructions": "What kind of message is this?",
                 "criteria": {"bug": "something is broken", "feature": "a request for something new", "question": "asks for information"}},
    "priority": {"type": "score", "instructions": "How soon does it need a fix?", "criteria": ["whenever", "this sprint", "today"]}
  }
}
```

| Field | Type | |
|---|---|---|
| `items` | nonempty list | Strings, or any JSON value. An object is judged as its JSON text (Laya) or `key: value` lines (Von), in the key order you send, so name the fields. A string stays a string even when it looks like JSON. An object with an `image`, `images`, `audio`, `video` or `videos` key gets a per-item error: Verdict judges text. |
| `questions` | nonempty object | Question id → question. Every question is answered for every item in the same pass. Ids and labels are compared as exact strings. |
| `model` | string, optional | `"auto"` (default) or a model id from `/v1/models`. `auto` sends an item whose letters are ≥ 99.5% ASCII to `laya-english` and anything else to `laya-multilingual`; one request can use both. |
| `bits` | integer, optional | A whole number (`4.9` is refused, not truncated; `null` is the same as leaving it out): the precision the request requires, Laya 16, 8 or 4; Von 32, 16, 8 or 4; `0` means the model's native precision (Laya 16, Von 32). Every model the request uses must already run at it (as loaded, else `precision.selected`), checked before anything loads; otherwise `409` and nothing runs. A request never changes a model's precision; [`/v1/load`](#post-v1load) with `bits` does, for every client. |

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
    {"answers": {"bug": {"confidence": 0.9377, "noul": 0.9377},
                 "kind": {"choice": "bug", "confidence": 0.8938, "probabilities": {"bug": 0.9789, "feature": 0.0102, "question": 0.0109}},
                 "priority": {"confidence": 0.0013, "probabilities": {"0": 0.3285, "1": 0.3568, "2": 0.3147}, "score": 0.9862}},
     "model": "laya-english", "ms": 5.8},
    {"answers": {"bug": {"confidence": 0.9998, "noul": 0.0002},
                 "kind": {"choice": "feature", "confidence": 0.621, "probabilities": {"bug": 0.0456, "feature": 0.8918, "question": 0.0626}},
                 "priority": {"confidence": 0.0283, "probabilities": {"0": 0.2354, "1": 0.3266, "2": 0.438}, "score": 1.2026}},
     "model": "laya-english", "ms": 5.8},
    {"error": "Verdict judges text; image, audio and video items are not supported.", "model": null, "ms": 0}
  ]
}
```

Per-item errors (the request still returns 200):

```json
{"error": "Item needs about 9026 tokens; laya-english accepts 8192. Shorten it or split it.", "model": "laya-english", "ms": 0}
```

Request-level errors (nothing is judged): `400` for a malformed body, an empty `items` or `questions`, an unknown question type (`Unknown question type 'maybe'`), an unknown or hosted-only model (`Unknown or hosted-only model 'laya-englsh'; loadable: laya-english, laya-multilingual, …`) or an invalid `bits`; `409` when `bits` differs from the precision a model it uses runs at; `507` when a model the request needs does not fit in free memory (see [Errors](#errors-batch-and-management)).

## Management

### GET /v1/status

The helper's live state (the same object it writes to `status.json`, plus `catalog`, the raw `models.json`). Abridged:

```json
{
  "api": 1, "version": "0.3.0", "mlx": "0.32.0 (mlx-swift 9019419)", "port": 58245, "pid": 88420, "started": 1790372212.99,
  "calls": 1, "items": 2, "last_ms": 14.0, "last_used": 1790372223.96,
  "loading": null, "downloading": false, "error": null, "refused": null, "evictions": [],
  "manual_idle_minutes": 0, "on_demand_idle_minutes": 5, "allow_swap": false,
  "gpu": {"chip": "M5 Max", "architecture": "applegpu_g17s", "generation": 17, "macos": "26.6.0", "neural_accelerators": true},
  "memory": {"rss_mb": 760.0, "mlx_active_mb": 1486.0, "mlx_cache_mb": 503.0, "available_mb": 81742.0},
  "installed": {"laya-english": {"bytes": 842611261}, "laya-multilingual": {"bytes": 643837515}},
  "models": {
    "laya-english": {"bits": 0, "context": 8192, "device": "mlx", "engine": "optimized", "engine_reason": null,
                     "kernel": "windowed-attention (L>=768, self-test max diff 1.2e-06)",
                     "load_s": 0.1, "memory_estimate_mb": 1271.0, "residency": "on_demand", "last_used": 1790372223.96,
                     "optimizations": {"attention": "windowed", "matmul": "neural accelerators", "optimized": true, "tokenizer": "fast"}}
  }
}
```

- `version`: the app version (`null` for a helper run outside the app and a checkout). `mlx`: the MLX core version and the pinned mlx-swift revision.
- `models`: loaded models. `bits` as loaded (`0` = native). `residency`: `manual` (loaded from the menu or with `"manual": true`; loaded again at the next launch) or `on_demand` (a request needed it). `engine`: `optimized` (Verdict's fast tokenizer and windowed attention, self-tested at load on this Mac) or `mlx` with `engine_reason`. `kernel`: the attention path and its load-time self-test result.
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
- `precision` (bits): `selected` is what a load without `bits` uses: the app's Models table choice (read from `config.json` at each load, so a choice made while Verdict runs applies to the next load), else `default`. A loaded model is not reloaded when the choice changes; `loaded` shows what it runs at, or `null`. `default` is the recommended precision. A request's `bits` never changes either: every request runs at `loaded` (or, when the model is not loaded, `selected`).
- `benchmark` fields: `accuracy` (0–1; `accuracy_en`/`accuracy_ml` for the English and multilingual tasks, `sets` per task), `ece` (calibration error, lower is better), `ms` (single-item p50), `items_per_s` (batched), `j_per_1k` (energy per 1,000 judgements, batched), `memory_mb` (loaded footprint). A field that was not measured is absent.

### POST /v1/load

```json
{"model": "von-1.2", "bits": 8, "manual": true}      →      {"loaded": ["laya-multilingual", "von-1.2"]}
```

Loads a model (downloading it the first time) and returns the loaded ids. `bits` (optional, a whole number; `null` = omitted) reloads it at that precision even if it is loaded, and every client's requests then run at it (this and the menu's Reload are the only ways a loaded model's precision changes); without it, a model that is not loaded loads at `precision.selected` from `/v1/models`. `manual` (optional, default false) loads it like the menu's Load: it joins the launch set and follows the "Manually loaded" Keep Hot window; a reload keeps a manual model manual. Without `manual` it is an on-demand load, unloaded after the on-demand idle window. Errors: `400` (unknown model, invalid bits), `507` (does not fit in free memory). A refused precision change leaves the loaded model as it was.

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

- **JSON.** Every response is JSON with sorted keys. `/v1/systemone`, `/v1/models` and `/v1` paths Verdict does not serve fail in the System One API's (FastAPI's) format ([above](#system-one-errors)): `{"detail": [...]}` for validation, `{"detail": {"error_type", "message"}}` otherwise, `{"detail": "Not Found"}` / `{"detail": "Method Not Allowed"}` for an unknown path or `POST /v1/models`. The other endpoints fail with `{"error": "<message>"}` and a non-200 status. Messages are written for people and are safe to show verbatim.
- **Security.** The helper binds IPv4 loopback only and has no authentication: any process on this Mac can call it, nothing off the Mac can. An `Authorization` header is accepted and ignored. It refuses what a web page could send: any request with an `Origin` header (403), a `Host` other than `127.0.0.1:<port>` or `localhost:<port>` (403, blocks DNS rebinding), and a POST whose `Content-Type` is not `application/json` (415, blocks form posts that skip CORS preflight). All three are checked before the body is read. Do not forward the port to other machines.
- **Concurrency.** Requests are safe to send concurrently; each is atomic (an unload never lands in the middle of a judgement). Concurrent `/v1/systemone` requests for the same model share GPU passes ([above](#concurrent-requests)); other requests run one at a time. A request that needs a model waits while it loads. Each connection carries one request (`Connection: close`).
- **Limits.** A request body may be up to 64 MB; chunked request bodies are refused (send `Content-Length`). Each model has a context limit in tokens (`context` in `/v1/models`: 8,192 for the Laya models and Von 1.2, 2,048 for Von 1.1). Nothing is truncated: an over-long state is a 422 in `/v1/systemone` and a per-item `error` in `/v1/judge`, where the rest of the request still runs.
- **Time.** A model's first use downloads its weights (0.6–1.6 GB) inside the request and loading takes a few seconds; allow minutes for a first request (the Verdict clients wait up to 600 s). A loaded model answers in milliseconds.
- **Versioning.** Paths under `/v1/` keep their meaning; additions (new optional fields, new endpoints) do not bump the version. `"api"` in `/v1/status` changes only with an incompatible change. The original unversioned paths (`/judge`, `/status`, `/load`, `/unload`, `/delete`, `/settings`) remain as aliases for older clients. `/v1/models` became the System One API's listing within `"api": 1`: an entry's `name` is now the model id (the human name moved to `display_name`), the `auto` alias leads the list, and hosted models moved to `references`. Every field an earlier client read is still on every entry, the alias included, so those clients keep working; code that displayed `name` now shows the id (use `display_name`), and code that looked for hosted models in `models` finds them in `references`.

## Errors (batch and management)

| Status | When | Example message |
|---|---|---|
| 400 | Malformed JSON, missing or invalid field (`/v1/judge` and the management endpoints; `/v1/systemone` answers 422, see [its errors](#system-one-errors)), unknown model or question type, invalid precision, a fraction where a whole number is required | `laya-english: Laya precision must be 16, 8 or 4 bits`, `bits must be a whole number, not 4.9` |
| 403 | An `Origin` header, or a `Host` other than `127.0.0.1:<port>` / `localhost:<port>` | `cross-origin requests are not accepted` |
| 404 | Unknown path or wrong method (an unknown `/v1` path answers `{"detail": "Not Found"}`, above) | `not found: GET /nothing`, `/v1/judge takes POST` |
| 409 | `/v1/judge` with `bits` other than the precision a model runs at | `laya-english is loaded at 16-bit for every client; this request asked for 8-bit. …` |
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
  "items": ["The Pay button spins forever since Tuesday'"'"'s deploy.", "Is there an annual plan with a discount?"],
  "questions": {"bug": {"type": "noul", "instructions": "Does the writer report something broken?"}}}'
```

### The `verdict` command

Installed at `~/.local/bin/verdict` (a link to `Verdict.app/Contents/Helpers/verdict`). JSONL in, one short line per item out:

```sh
$ verdict judge --questions q.json --field text --sort bug < feedback.jsonl
#0  bug=0.94  kind=bug(0.89)  | The Pay button spins forever since Tuesday's deploy; nobody…
#1  bug=0.00  kind=feature(0.69)  | Would love a dark theme for the dashboard.
#2  bug=0.00  kind=question(0.31)  | Is there an annual plan with a discount?
```

`--json` prints each row with every probability; `--top N`, `--min X` (with `--sort`) and `--model ID` do what they say, and `--bits N` refuses to run unless the model runs at N bits. Also `verdict status`, `verdict models [--all] [--json]`, `verdict info MODEL [--json]`, `verdict load ID [--bits N] [--manual]`, `verdict unload ID`, `verdict url` (the base URL for SDKs), `verdict skill [--install DIR]`; `verdict --help` lists them.

### Python (standard library)

The installed library wraps discovery, launching and batching:

```python
import sys, os; sys.path.insert(0, os.path.expanduser("~/.local/share/verdict"))
from verdict import judge, Noul, Choice

r = judge("The export button does nothing", {"bug": Noul("Does the writer report something broken?"),
                                            "kind": Choice("What kind of message is this?", bug="something is broken", other="anything else")})
r.bug > 0.7, r.kind == "bug", r.kind.probabilities
```

Or the API with nothing but `urllib`:

```python
import json, os, urllib.error, urllib.request

status = json.load(open(os.path.expanduser("~/Library/Application Support/Verdict/status.json")))
body = {"items": ["The export button does nothing"], "questions": {"bug": {"type": "noul", "instructions": "Does the writer report something broken?"}}}
request = urllib.request.Request(f"http://127.0.0.1:{status['port']}/v1/judge", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(request, timeout=600) as response:
        print(json.load(response)["results"][0]["answers"]["bug"]["noul"])
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
let results = try await client.judge(items: reviews, questions: [
    "bug": .noul("Does the writer report something broken?"),
    "kind": .choice("What kind of message is this?", ["bug": "something is broken", "feature": "a request for something new", "question": "asks for information"]),
    "priority": .score("How soon does it need a fix?", levels: ["whenever", "this sprint", "today"]),
])
for (review, r) in zip(reviews, results) {
    guard r.ok else { print("skipped:", r.error!); continue }
    if (r["bug"]?.noul ?? 0) > 0.7, r["kind"]?.choice == "bug" { file(review) }
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
    items: ["The export button does nothing", "Is there an annual plan with a discount?"],
    questions: { bug: { type: "noul", instructions: "Does the writer report something broken?" } },
  }),
});
const reply = await response.json();
if (!response.ok) throw new Error(`${response.status}: ${reply.error}`);
for (const r of reply.results) console.log(r.error ?? r.answers.bug.noul);
```

Node's `fetch` sends no `Origin` header, so the helper accepts it. A browser page cannot call the API: browsers always send `Origin`.
