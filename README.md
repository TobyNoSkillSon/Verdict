<p align="center">
  <img src="docs/images/icon.png" alt="" width="64">
</p>

<h1 align="center">Verdict</h1>

<p align="center">Local decision models, kept hot in your menu bar. Your scripts and agents get calibrated yes/no, choice and score answers in milliseconds.</p>

<p align="center">
  <a href="#install"><img src="docs/images/install.svg" alt="Install Verdict" width="152" height="42"></a>
  &nbsp;
  <a href="https://github.com/sponsors/TobyNoSkillSon"><img src="docs/images/support.svg" alt="Support Verdict on GitHub Sponsors" width="176" height="42"></a>
</p>

<p align="center">
  <a href="#how-it-works">How it works</a> ·
  <a href="#models">Models</a> ·
  <a href="#questions">Questions</a> ·
  <a href="docs/USAGE.md">User guide</a>
</p>

A decision model answers typed questions about a piece of text — *which bucket, how urgent, is this true* — in one forward pass with a calibrated probability. It never generates text, so there is nothing to parse and nothing to hallucinate. One judgement costs about 6 ms on Apple Silicon; loading the model costs 20 seconds, which is why nobody calls it from a two-second script.

Verdict pays that cost once. It lives in your menu bar, keeps the models you choose resident, and answers on loopback. Your agent stops reading garbage, because deciding what to read is free now. Nothing leaves your Mac.

<p align="center">
  <img src="docs/images/menu-current.png" alt="Verdict menu: models hot, memory in use, judgement count" width="322">
</p>

- **Ask many things at once.** All questions about an item are answered in one pass; 100 items with three questions each take about a quarter of a second.
- **Choose your models.** Laya for text (English or 100+ languages), Gemma E2B for images, audio and video. Precision per model, in place.
- **Know what you are getting.** The model table shows accuracy and calibration measured on this class of Mac, not marketing numbers.
- **Stays out of the way.** Unloads after an idle period you choose, sheds under memory pressure, reloads on the next call.

## Install

**Apple Silicon · macOS 14 or newer · Python 3.12–3.14**

```sh
git clone https://github.com/TobyNoSkillSon/Verdict && cd Verdict
scripts/build.sh
cp -R dist/Verdict.app /Applications && open /Applications/Verdict.app
```

Builds with Apple's free Command Line Tools; no developer membership. `build.sh` also installs the `verdict` command into `~/.local/bin`. On first launch Verdict sets up its own Python runtime (MLX, ~285 MB, no PyTorch) and downloads **Laya English (~843 MB)** from Hugging Face, then keeps it hot. Whatever is hot when you quit is loaded again next time.

<details>
<summary>Updating an existing installation</summary>

Pull, rerun `scripts/build.sh`, copy the app again. Downloaded models, settings and the runtime are kept under `~/Library/Application Support/Verdict`; `build.sh` refuses to replace the app while a model is loading. Rerun `scripts/setup-backend.sh` only when the pinned runtime changes.

</details>

## How it works

Write questions in code; Verdict answers them for every item.

```python
from verdict import judge, Choice, Score, Noul

questions = {
    "fit":    Score("How well does this job match a SwiftUI developer who wants remote B2B work?", ["poor", "partial", "strong"]),
    "remote": Noul("Is the job fully remote?"),
    "dept":   Choice("Which team?", billing="invoices, refunds", tech="bugs, outages", other="anything else"),
}
results = judge(job_ads, questions)                      # 100 ads → about 0.25 s
best = sorted(zip(job_ads, results), key=lambda p: -p[1].fit)[:20]
for ad, r in best:
    if r.remote > 0.8 and r.dept != "other": print(ad)   # answers compare like values; r.fit.probabilities has the detail
```

Or from the shell, JSONL in and JSONL out:

```sh
verdict judge --questions q.json --sort fit --top 20 < jobs.jsonl
verdict status
```

Question classes use the same names and fields as TypeSafe's Jev SDK, so questions written for Jev work unchanged (plain dicts work too). Three types, answered together in one pass per item:

| Type | Criteria | Returns | Notes |
|---|---|---|---|
| `Noul` | none | probability the statement is true | most reliable |
| `Choice` | `{"label": "description"}` | label + probability per option | keep to ≤ 20; always include an escape option |
| `Score` | `["low", "mid", "high"]` | expected level 0…n-1 | ordinal; the fuzziest |

Every answer carries a **confidence** — a calibrated probability, not a verdict. Sort and shortlist by it; check a threshold on ~30 labelled examples before trusting it to auto-reject anything. `judge()` warns when a question breaks the conventions the field has settled on (no escape option, "and" in a yes/no, counting).

If Verdict is not running, `judge()` launches it and waits. Non-ASCII text routes to the multilingual model; items with `image`, `audio` or `video` paths route to Gemma. An item over a model's context comes back as an error in its position — nothing is truncated silently. **Copy Skill for Your Agent** in the menu puts the full usage note on your clipboard for a coding agent.

<p align="center">
  <img src="docs/images/models-current.png" alt="Verdict model table: inputs, context, bits, accuracy, calibration, speed" width="780">
</p>

## Models

Measured here, on an Apple M-series Mac, through Verdict itself: accuracy is the mean over two public sets (AG News, 4 topics; DAIR Emotion, 6 labels; 500 test items each, zero-shot, one `Choice` question), calibration is expected calibration error over both (lower is better), speed is the median per item. `scripts/benchmark.py` reproduces the table.

| Model | Inputs | Params | Context | Languages | Accuracy | Calibration | Speed |
|---|---|---|---|---|---|---|---|
| **Laya · English** | text | 421M | 8k | English | 76.4% | 0.096 | 6 ms |
| Laya · Typed decisions | text | 421M | 8k | English | 76.3% | 0.252 ⚠ | 6 ms |
| **Laya · Multilingual** | text | 322M | 8k | 100+ | 71.7% | 0.113 | 4 ms |
| **Gemma E2B · RLCD** | text, image, audio, video | 5B (4-bit) | 128k | 140+ | 65.7% | 0.315 ⚠ | 37 ms text · ~0.2 s image · ~2 s audio |
| Jev · TypeSafe (hosted, reference) | text | — | 64k | English | 69.5%† | 0.246† | 256 ms† |

⚠ Confidence is not trustworthy for these: use the answers, not the probabilities, until a temperature is fitted on your data. † Published figures for Jev 1.13.0, not measured here; shown so you can see what the local models give up or gain. Our AG News number reproduces Laya's published 0.950 exactly.

<details>
<summary>Context, precision and honest limits</summary>

**Context.** Laya ships with a 512-token budget in its config; its encoder takes 8,192 and measured accuracy holds all the way (300 long BBC articles with the decisive text after 800 tokens of filler: 26% at 512 — truncation — vs 91% at 1,024 and up). Verdict runs every model at its real limit and never truncates.

**Precision.** fp16 is the default and the fastest; fp32 is identical in accuracy; 8-bit loses 0.2 points and saves ~350 MB per model; 4-bit loses a point and saves ~530 MB. Switch per model in the table; a hot model reloads in place.

**Limits, from Laya's model card and our tests.** Strong on general classification, weak on niche zero-shot rules (an ad in Polish saying *praca zdalna* still got `remote = 0.02`); choice questions collapse past ~20 options; it does not count, do arithmetic or dates, reason across items, or know anything outside the text. For a rule that matters, label 50–500 examples and fine-tune — that is the intended path.

**More models.** The catalog is `Resources/models.json`; candidates need open weights, a typed-question interface with per-answer probabilities, and an Apple-Silicon runtime that loads in seconds. Watched: [Von 1.0](https://huggingface.co/wfzyx/von-1.0) (no MLX port yet, licence unconfirmed), [OpenJev Verdict](https://huggingface.co/heman10x/rlcd-modernbert-151m) (ONNX only), [GLiClass v3](https://github.com/Knowledgator/GLiClass) (uncalibrated). See [docs/USAGE.md](docs/USAGE.md#adding-models).

</details>

## Questions

<details>
<summary>Does anything leave my Mac?</summary>

No. The worker binds to `127.0.0.1` on a random port; model weights are downloaded once from Hugging Face into its cache. There is no telemetry.

</details>

<details>
<summary>How much memory does it use?</summary>

About 0.9 GB per hot English model, 0.7 GB multilingual, 3.6 GB for Gemma; the menu shows the live figure. Under **Keep Hot** choose Always or an idle window (15 min, 1 h, 4 h) after which models are freed and reloaded on the next call. When the Mac runs low on memory Verdict drops its cache first, then keeps one model and sheds the rest.

</details>

<details>
<summary>Can it judge screenshots?</summary>

Yes, through Gemma E2B: pass `{"image": path}` as the item and ask coarse questions — is the layout broken, which screen is this, is an error shown. It cannot read small text or count elements. Its answers are usable; its confidence is not calibrated.

</details>

<details>
<summary>Where are the files, and how do I uninstall?</summary>

`~/Library/Application Support/Verdict` holds `config.json`, `status.json`, `worker.log` and the Python runtime; weights live in `~/.cache/huggingface`. Quit Verdict, delete the app, that folder and `~/.local/bin/verdict`; delete downloaded models from the table first if you want the cache gone.

</details>

## Licence

[Apache-2.0](LICENSE). Keep the [NOTICE](NOTICE) when you redistribute. Laya weights © Convai Innovations (Apache-2.0), MLX conversions by [mizorewww](https://github.com/mizorewww/laya-mlx); Gemma E2B RLCD by [larkooo](https://huggingface.co/larkooo/gemma-e2b-rlcd) (Apache-2.0; Gemma terms apply to the base weights).
