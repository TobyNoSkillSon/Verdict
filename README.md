<p align="center">
  <img src="docs/images/icon.png" alt="" width="64">
</p>

<h1 align="center">Verdict</h1>

<p align="center">Local decision models, kept ready for your coding agent.</p>

<p align="center">
  <a href="#install"><img src="docs/images/install.svg" alt="Install Verdict" width="152" height="42"></a>
  &nbsp;
  <a href="https://github.com/sponsors/TobyNoSkillSon"><img src="docs/images/support.svg" alt="Support Verdict on GitHub Sponsors" width="176" height="42"></a>
</p>

<p align="center">
  <a href="#the-problem">The problem</a> ·
  <a href="#for-your-agent">For your agent</a> ·
  <a href="#the-app">The app</a> ·
  <a href="#models">Models</a> ·
  <a href="#questions">Questions</a> ·
  <a href="docs/USAGE.md">User guide</a>
</p>

**Verdict is a macOS menu-bar app for developers who use coding agents.** It keeps small local models in memory so an agent can filter, classify and score a whole collection from a script, then read only the items that matter. You install it once and give your agent the included skill; the app stays out of the way.

## The problem

Ask a coding agent to work through hundreds of search results or thousands of transcript turns and it either reads everything, filling its context, or samples and guesses.

Decision models are built for this work. Instead of writing prose, they answer typed questions about each item: is this relevant, which category fits, where does it fall on a rubric? Laya English takes about **6 ms per text item** in the recorded benchmark, and about 2 ms per item when a batch shares the same questions. But loading a model takes 5–20 seconds, and a script runs for two — so nobody calls one from a script.

Verdict keeps the models hot — loaded and ready. The agent sends items and questions over loopback through a Python client or the `verdict` CLI, then sorts or filters the answers in code. Judgements stay on your Mac.

**The agent stops reading garbage, because deciding what to read is free now.** No hosted inference bill; local compute, memory and mistakes still have a cost.

For example, an agent can:

- Filter 800 grep hits for relevance before opening files.
- Flag shell commands for review before execution — not replace permissions or a sandbox.
- Mine 40,000 transcript turns for user corrections.
- Sort 300 screenshots into broken layouts, empty states and other screens.
- Triage 5,000 feed items before preparing a shortlist.

These are example workloads, not measured end-to-end results.

## For your agent

After [installing Verdict](#install), open its menu, choose **Copy Skill for Your Agent**, and paste it into your coding agent. The copied `SKILL.md` teaches the agent when to use Verdict, how to call it and how to write questions.

This is the pattern it uses: ask the same questions of every item, keep the answers in order, and shortlist in code. Here `hits` is a list of search-result strings or dictionaries; the threshold is illustrative, not validated for your task.

```python
import sys
sys.path.insert(0, "/path/to/Verdict/client")  # your cloned repository
from verdict import judge, Noul, Choice, Score

questions = {
    "relevant": Noul("Is this hit about the authentication flow?"),
    "kind": Choice(
        "What kind of file is this?",
        source="application code",
        test="tests or fixtures",
        other="anything else or unclear",
    ),
    "risk": Score("What would a change here affect?", [
        "an isolated helper",
        "a shared module",
        "a public interface or migration",
    ]),
}

shortlist = []
for hit, result in zip(hits, judge(hits, questions)):
    if result.error:
        raise RuntimeError(result.error)  # do not silently discard failed items
    if result.relevant > 0.6 and result.kind == "source":
        shortlist.append((hit, float(result.risk)))

shortlist.sort(key=lambda item: item[1], reverse=True)
# The agent reads the shortlisted hits, rather than every search result.
```

| Question | Answer |
|---|---|
| `Noul` | Probability that a yes/no proposition is true |
| `Choice` | A label, with probabilities for the options |
| `Score` | Expected level on an ordered rubric, starting at zero |

Answers compare like values; `.confidence` and `.probabilities` expose the detail. Confidence is not a guarantee. Check thresholds on labelled examples from your own task, especially before using a result to gate an action.

<details>
<summary>CLI, routing and errors</summary>

The CLI reads JSONL and writes JSONL. For example, save a question to `q.json`:

```json
{"relevant": {"type": "noul", "instructions": "Is this hit about the authentication flow?"}}
```

Then sort the results by relevance:

```sh
verdict judge --questions q.json --sort relevant < hits.jsonl
verdict status
```

`judge()` launches the installed app if necessary. Auto-routing selects the multilingual model for non-ASCII text and Gemma for dictionaries containing local `image`, `audio` or `video` paths. You can also select a model explicitly.

Items that exceed a model's context return an error in their original position; they are not silently truncated. An unavailable worker raises `VerdictError`. The client warns about question shapes such as a choice without an “other” option or a request to count.

To choose a model, `verdict models` lists the catalog with measured numbers and weights links, and `verdict info <model>` shows the benchmark breakdown and links to the upstream model card, weights and runtime (`--json` on both, or `models()` in Python), so an agent can read the model cards and decide.

See [the user guide](docs/USAGE.md) for the client, CLI and worker protocol.

</details>

## The app

The menu shows which models are hot, memory use and judgement count. **Copy Skill for Your Agent** is the handoff; **Launch at Login** keeps Verdict available without opening it yourself.

<p align="center">
  <img src="docs/images/menu-current.png" alt="Verdict menu with model status, memory use and Copy Skill for Your Agent" width="322">
</p>

**Models…** opens the catalog. With nothing downloaded, local models show **Get**. First launch downloads Laya English automatically; use **Get** for additional models. The grey hosted row is a reference, not a service Verdict calls.

<p align="center">
  <img src="docs/images/models-fresh.png" alt="Model catalog before any weights are downloaded, with Get buttons" width="900">
</p>

Downloading and loading happen before a model can answer. The table shows the operation in progress; this capture shows Laya English loading after its weights are present on disk.

<p align="center">
  <img src="docs/images/models-downloading.png" alt="Laya English loading, with a progress indicator in the table footer" width="900">
</p>

A flame marks a hot model. Here English, Multilingual and Gemma are ready; **Unload** frees a model's memory without deleting its weights. The table also exposes per-model precision: Laya supports 16-, 8- and 4-bit settings; Gemma uses 4-bit weights. Changing a hot Laya model's precision reloads it.

<p align="center">
  <img src="docs/images/models-current.png" alt="English, Multilingual and Gemma hot, with precision controls and benchmark columns" width="900">
</p>

**Keep Hot** chooses between staying resident and unloading after an idle window. Unloaded models load again on the next judgement. Under memory pressure, Verdict drops its cache first, then sheds models rather than keeping them all resident.

<p align="center">
  <img src="docs/images/keep-hot.png" alt="Keep Hot menu: Always or unload after an idle window" width="360">
</p>

## Install

**Apple Silicon · macOS 14 or newer · Python 3.12–3.14**

With Apple's Command Line Tools installed:

```sh
git clone https://github.com/TobyNoSkillSon/Verdict && cd Verdict
scripts/build.sh
cp -R dist/Verdict.app /Applications
open /Applications/Verdict.app
```

No Apple developer membership is required. The build also installs the `verdict` CLI into `~/.local/bin`; add that directory to your shell's `PATH` if needed. Python scripts import `client/verdict.py` from the clone, as in the example above.

On first launch, Verdict installs its own Python runtime and downloads **Laya English (~843 MB)** from Hugging Face. Wait for it to become hot, enable **Launch at Login** if wanted, then choose **Copy Skill for Your Agent**. Models hot when you quit are remembered for the next launch.

<details>
<summary>Updating an existing installation</summary>

Pull the repository, rerun `scripts/build.sh`, and copy the app again. Downloaded models, settings and the runtime are retained. The build refuses to replace the app while a model is loading. Rerun `scripts/setup-backend.sh` only when the pinned runtime changes.

</details>

## Models

Verdict runs the Laya text models on MLX and Gemma E2B RLCD for text, image, audio and video judgements.

The recorded text benchmarks compare topic classification on AG News and emotion classification on DAIR Emotion, zero-shot with a `Choice` question. Accuracy is the mean across those sets; calibration is expected calibration error (lower is better); speed is median time per item. The benchmark file records `n = 500` for each Laya model and `n = 200` for Gemma. These results do not establish accuracy on your task. `scripts/benchmark.py` is the reproduction entry point.

| Model | Inputs | Params | Context | Languages | Accuracy | Calibration | Speed |
|---|---|---|---|---|---|---|---|
| **Laya · English** | text | 421M | 8k | English | 76.4% | 0.096 | 6 ms |
| Laya · Typed decisions | text | 421M | 8k | English | 76.3% | 0.252 ⚠ | 6 ms |
| **Laya · Multilingual** | text | 322M | 8k | 100+ | 71.7% | 0.113 | 4 ms |
| **Gemma E2B · RLCD** | text, image, audio, video | 5B (4-bit) | 128k | 140+ | 65.7% | 0.315 ⚠ | 37 ms text · ~0.2 s image · ~2 s audio |
| Jev · TypeSafe (hosted, reference) | text | — | 64k | English | 69.5%† | 0.246† | 256 ms† |


⚠ Laya Typed decisions and Gemma have poorly calibrated confidence in these results. Do not treat their probabilities as reliable thresholds without validation on your data. † Jev figures are published reference results, not measured here; Verdict cannot load or call it. The image and audio timings are approximate, not part of the recorded text benchmark.

<details>
<summary>Context, precision and limits</summary>

**Context.** Laya runs at its encoder's real limit of 8,192 tokens (its shipped config says 512; on 300 long BBC articles with the decisive text after 800 tokens of filler, accuracy was 26% at 512 and 91% at 1,024 and above). Gemma takes 131,072. Questions count toward the budget. Over-limit items return errors rather than truncated judgements.

**Precision.** Laya defaults to 16-bit (fp32 measured identical; 8-bit costs 0.2 points and saves ~350 MB per model, 4-bit costs a point and saves ~530 MB; neither is faster). Change it per model in the table. Gemma is published only as 4-bit weights.

**Limits.** Each judgement sees one item, not the whole collection. Sort scores in code; do not expect cross-item reasoning. Use ordinary code for counting, arithmetic and date comparisons. Keep choice labels distinct, include an escape option, and write rubric levels as checkable situations. Test domain-specific rules on labelled examples before relying on them.

**Catalog.** Models and recorded text measurements live in [`Resources/models.json`](Resources/models.json) and [`Resources/benchmarks.json`](Resources/benchmarks.json). See [adding models](docs/USAGE.md#adding-models) for the runtime and interface requirements.

</details>

## Questions

<details>
<summary>Does anything leave my Mac?</summary>

Judgement inputs stay local. The worker listens on `127.0.0.1`; setup downloads runtime dependencies and model weights. There is no telemetry or hosted inference fallback.

</details>

<details>
<summary>Does it keep using memory when I am not working?</summary>

With **Keep Hot → Always**, loaded models stay resident. Choose an idle window to release their memory between tasks; the next request pays the load time again. The menu shows live memory use. Quitting Verdict stops the worker.

</details>

<details>
<summary>Can it judge screenshots?</summary>

Yes. Pass `{"image": "/path/to/screenshot.png"}` to `judge()` with your questions; auto-routing selects Gemma E2B RLCD. Use it for coarse classification, such as identifying an error screen, not precise small-text reading or element counting. Validate its answers and do not assume its confidence is calibrated.

</details>

<details>
<summary>Where are the files, and how do I uninstall?</summary>

`~/Library/Application Support/Verdict` holds settings, status, logs and the Python runtime. Model weights live in `~/.cache/huggingface`.

To remove downloaded weights, delete the models from the table first. Then quit Verdict and remove `/Applications/Verdict.app`, its Application Support folder and `~/.local/bin/verdict`. Do not delete the whole Hugging Face cache if other tools use it.

</details>

## Licence

[Apache-2.0](LICENSE). Keep the [NOTICE](NOTICE) when you redistribute. Laya weights © Convai Innovations (Apache-2.0), MLX conversions by [mizorewww](https://github.com/mizorewww/laya-mlx); Gemma E2B RLCD by [larkooo](https://huggingface.co/larkooo/gemma-e2b-rlcd) (Apache-2.0; Gemma terms apply to the base weights).
