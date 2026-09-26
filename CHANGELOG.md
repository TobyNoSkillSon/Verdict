# Changelog

## 0.3.0 (2026-09-26)

### Added

- Updates from the app: when a newer release is published, an orange **Update to X.Y.Z…** item appears under Support the developer…; its popup shows the release notes and **Update Now** downloads, verifies (SHA-256, code signature) and installs it, waits while a model is loading, keeps settings and models, restarts Verdict, and restores the previous version if the new one does not start. `verdict update [--check]` does the same from a terminal. Verdict checks at launch and every 24 hours with one request to the GitHub releases API.
- `scripts/install-release.sh` replaces only the Verdict.app in its install directory (`VERDICT_INSTALL_DIR`, `VERDICT_SUPPORT_DIR` for tests), quits it by process rather than by name, and waits for the new version's worker.
- `verdict diagnose [--load] [--json]`: a report for bug reports (chip, macOS, Verdict and MLX versions, each loaded model's engine, fallbacks, self-test, precision, timing on 20 built-in items, and for Laya English at 16-bit how many answers match reference answers from the reference Mac) with a link that opens a prefilled GitHub bug report. `/v1/status` reports `mlx` (MLX core version and mlx-swift revision) and each model's `kernel` (attention path and self-test).
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
