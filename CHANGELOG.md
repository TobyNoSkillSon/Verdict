# Changelog

## 0.3.0 (unreleased)

### Added

- `POST /v1/systemone` and `GET /v1/models`, compatible with the System One API (TypeSafe Jev); Verdict works with the TypeSafe SDK. Concurrent requests for the same model share GPU passes. See [docs/API.md](docs/API.md#system-one-api).
- `"merge": false` on `/v1/systemone` runs that request in a GPU pass of its own, so its answers are exactly the ones it gets sent alone. A merged answer can differ from that by up to about 0.03 in a probability (Laya English at 16-bit; see [Concurrent requests](docs/API.md#concurrent-requests)).
- An `x-verdict-bits` header on `/v1/systemone` replies says which precision answered.
- VerdictKit's `SystemOneClient` and the Python library's `base_url()` for the TypeSafe SDK.

### Changed

- **`/v1/judge`: structured `instructions` are read.** An object or array given as a question's `instructions` used to be dropped silently: the model saw empty instructions. It now reads their JSON text, as `/v1/systemone` does, so answers to such questions change. In one comparison with `{"q": "refund?"}` as the instructions, a yes/no answer went from 0.4303 to 0.0001 and another from 0.7089 to 0.9361. Questions with plain-text instructions are unaffected.
- **`/v1/judge`: structured score levels are answered.** A `score` level given as an object (`{"level": "high", "examples": […]}`) used to be a 400; it is now judged as its JSON text.
- **`bits` requires a precision; it no longer switches one.** A model runs at one precision for every client. `bits` on `/v1/judge` or `/v1/systemone` must match it (the loaded precision, else the selected one), or the request gets `409` and nothing reloads; before, it reloaded the model and left it at that precision for everyone. Change the precision with `POST /v1/load` and `bits` (`verdict load ID --bits N`, the menu's Reload). The Python `judge(bits=…)`, VerdictKit `judge(…, bits:)` and `verdict judge --bits` follow.
- **`GET /v1/models`** is the System One API's listing: `name` is the model id (the human name is `display_name`), the `auto` alias comes first, and hosted models are under `references`. Every earlier field is still present on every entry, the alias included, so earlier clients keep working; `api` stays 1.
- Unknown `/v1` paths (including a trailing slash, `/v1/systemone/`) answer `404 {"detail": "Not Found"}` and `POST /v1/models` answers `405 {"detail": "Method Not Allowed"}`, as FastAPI does. Unversioned paths and Verdict's own endpoints keep `{"error": …}`.
