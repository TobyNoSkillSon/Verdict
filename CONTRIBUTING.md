# Contributing to Verdict

Bug reports, model proposals, fixes and speed-ups are welcome. This file covers building and testing, the evidence a pull request needs, and how review works. Questions and early ideas belong in [Discussions](https://github.com/TobyNoSkillSon/Verdict/discussions); security problems go through [SECURITY.md](SECURITY.md).

## Build from source

You need an Apple Silicon Mac and two toolchains:

- **Command Line Tools with Swift 6.3.3** (`xcode-select --install`; check with `/Library/Developer/CommandLineTools/usr/bin/swift --version`). All Swift code is compiled with it.
- **Full Xcode with its Metal Toolchain** (`xcodebuild -downloadComponent MetalToolchain`). Xcode only compiles MLX's Metal shaders, with `MTL_FAST_MATH=NO`.

The split is deliberate. Xcode 27's Swift 6.4 emits a runtime symbol (`_swift_initBorrow`) that macOS 26 does not have, so its binaries abort at launch. The shader setting is part of the qualified numerics (see [Dependencies](#dependencies)). The scripts do both halves:

```sh
scripts/build-helper.sh      # .build/release-helper/verdict-helper + mlx.metallib; smoke-runs /status with stub models
scripts/build.sh             # dist/Verdict.app (app, helper, metallib, `verdict` CLI); installs nothing
VERDICT_BUILD=source scripts/install.sh   # build this checkout and install it
```

`swift build -c release` builds every product with whichever Swift you run it with; it is fine for compiling and for tests, not for shipping.

## Test

```sh
scripts/build-helper.sh      # once, and after changing Sources/VerdictHelper or VerdictEngine
xcrun swift test
```

The tests never touch your installed app, its settings or the model cache. The ones that need a helper start `.build/release-helper/verdict-helper` with `VERDICT_STUB_MODELS=1` in a temporary support directory. Stub models need no weights and do no GPU work: they return fixed answers but report load state, engine labels, fallbacks, residency and memory accounting through the real service code. Without a built helper those tests are skipped, not failed. CI runs the same build and tests on every pull request.

Real-model parity and benchmarks need downloaded weights and a quiet GPU. The maintainer runs them on the reference Mac (an M5 Max) before a change that affects numerics is merged.

## Layout

| Path | What |
|---|---|
| `Sources/Verdict` | The menu-bar app: UI and helper supervision. No MLX. |
| `Sources/VerdictHelper` | `verdict-helper`, the loopback HTTP service the app launches. |
| `Sources/VerdictEngine` | Laya and Von on MLX, tokenizers, windowed attention and their self-tests. |
| `Sources/VerdictCore` | App logic shared with tests: catalog, precision, memory, labels. |
| `Sources/VerdictKit`, `Sources/VerdictCLI` | The Swift client library (Foundation only) and the `verdict` command. |
| `clients/python/verdict.py` | The Python library (standard library only). |
| `Resources/` | `models.json` (catalog), `benchmarks.json` (measured figures), `SKILL.md` (agent skill). |

## Pull requests

Open an issue first for anything larger than a fix, so we can agree on the approach before you spend time on it. Then:

- Keep one change per pull request, matching the style of the surrounding code.
- Run `swift test` and `scripts/build.sh`.
- Update the docs your change touches (README, `docs/USAGE.md`, `docs/API.md`, `Resources/SKILL.md`) and add a line to `CHANGELOG.md` for anything a user would notice.
- Add no new dependencies without discussing them first. VerdictKit and the Python library have none, on purpose.
- Measure performance claims and say on what hardware (chip, memory, macOS). An unmeasured speed-up will not be merged.

The pull request template asks for these.

### Proposing a model

Start with a **New model request** issue. A catalog model needs open weights with a licence that allows local use, typed questions (yes/no, choice, score) with a probability for every answer, and an architecture that mlx-swift can run.

An implementation adds a `Resources/models.json` entry, a `DecisionModel` and `ModelLoader` in `Sources/VerdictEngine`, and the registration in `Sources/VerdictHelper/Registry.swift`. The pull request must show:

1. **Parity.** Run the model's reference implementation (its SDK or the authors' code, at a named version or commit) and Verdict on the same fixed inputs, covering all three question types and long inputs. Give the largest absolute difference in any probability at each precision you offer. The current models match their references to within 0.0001 at native precision; explain anything larger. Include the script and inputs so the result can be reproduced.
2. **Numbers.** Accuracy and calibration on a public task set, single-item latency, batched throughput and memory, with the chip, memory and macOS they were measured on.

Before a model's figures go into `Resources/benchmarks.json`, the maintainer measures it with Verdict's 25-task suite on the reference Mac, so every row of the table is comparable.

### Chip-specific optimizations

Verdict's optimized paths (the fast tokenizers, windowed attention and batching) are meant to work on every Apple Silicon Mac. So far they have only been verified on an M5 Max. If a path is slow or disabled on your chip and you can fix it, you are welcome to:

- Put the new path **behind a load-time self-test on that chip family**, the way the windowed attention already is (`LayaWindowedAttention.selfTest`, `VonWindowedAttention.selfTest`). The test compares it with the stock MLX path on fixed inputs when a model loads. If the test fails, or the path fails during a request, Verdict must fall back to the stock path and report why in `/v1/status`, which is what the app's "MLX" label and `verdict diagnose` show.
- Leave other chips' paths unchanged. Answers must stay within the parity tolerance above.
- Attach `verdict diagnose` output from before and after the change on that chip, and name every chip you tested on. The maintainer checks the reference Mac for regressions.

### Dependencies

mlx-swift (a pinned revision), swift-transformers and swift-collections are pinned on purpose. That combination, with the Swift 6.3.3 compiler and `MTL_FAST_MATH=NO`, is the one whose outputs were checked against each model's reference implementation. Changing any of them means running that parity check again. Dependency updates therefore come through a pull request with parity evidence, not through Dependabot, which only updates the GitHub Actions used by CI.

## AI-assisted contributions

Pull requests written with AI tools are welcome. Use a strong frontier model, read and understand every line before you submit, and say which model you used in the pull request. You are responsible for the change: the tests, the measurements and the answers to review comments.

Nothing is merged automatically. An AI reviewer may comment on pull requests, but a human maintainer reviews and merges every change.

## Licence

Verdict is licensed under [Apache-2.0](LICENSE). By submitting a contribution you agree that it is licensed under the same terms (section 5 of the licence); there is no separate contributor agreement. "Verdict" and its icon are the project's name and mark and are not covered by the licence, so a fork you distribute should use another name and icon.

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
