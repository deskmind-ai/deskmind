<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/social/README-bilingual-dark.svg">
    <img src="brand/social/README-bilingual-light.svg" alt="DeskMind 得心 · 得心，应手。" width="760">
  </picture>
</p>

# DeskMind · 得心

**Small enough to run on your Mac. Smart enough to ask.**

Open-source computer use for your Mac. DeskMind reads the screen, works out the next step and acts, all with small models running on your Mac. When a task could mean two things, it asks you instead of guessing.

[中文](README.zh-CN.md) · [Website](https://deskmind.dev) · [Docs](https://deskmind.dev/docs/) · [Download for Mac](https://github.com/deskmind-ai/app/releases/latest) · [Models](https://huggingface.co/deskmind) · [Discussions](https://github.com/deskmind-ai/deskmind/discussions) · [Roadmap](ROADMAP.md)

**[Watch the 56-second demo on deskmind.dev](https://deskmind.dev)**: a real recording with the released model. Two orders match "Lisa Wong", so it asks which one before writing.

## What makes it different

**A small model, on your Mac.** A 0.8B model decides each step and a 4B checks the hard ones. Both run on your Mac: no cloud round-trip, no per-step bill. The 0.8B decides in about 0.5 s; the 4B checks in about 3.6 s (median decision times).

**System One: choices, not guesses.** Each step is a multiple-choice question. The model scores every option instead of writing text, so every option gets a probability. Unsure steps go to the 4B or to you, and any agent can call it through `POST /v1/systemone`. In 39 real-desktop runs it never said "done" when the task was not done.

**Open, from eyes to hands.** Eyes, Brain, Hands and the Mac app are open source, along with Bench, which grades them. Every result below comes with its sample size, so you can reproduce it.

## Get started

**Use the Mac app.** [Download DeskMind for Mac](https://github.com/deskmind-ai/app/releases/latest) (macOS 15+, Apple Silicon, signed and notarized). v0.3.0 ships the G18b release models; the earlier v0.2.0 shipped G14. On first run it downloads the models (about 5.3 GB) and walks you through the permissions: [Install the app](https://deskmind.dev/docs/start/install-the-app/).

**Or run the model yourself.** This runs the 4B alone (release G18b). It answers one step of a desktop task; it does not drive the desktop by itself.

```bash
# Terminal 1: get Brain and the model, then serve it
git clone https://github.com/deskmind-ai/brain && cd brain && uv sync --extra mlx
uv run hf download deskmind/brain-4b --revision g18b-q8 --local-dir models/brain-4b
uv run deskmind-brain-serve --predictor mlx:models/brain-4b --port 8793 --two-stage
```

The 4B is about 4.5 GB to download. If the download fails with a `CAS Client Error`, rerun it with `HF_HUB_DISABLE_XET=1` in front. In mainland China, ModelScope carries the same files:
`uvx modelscope download --model gxcsoccer/brain-4b --revision g18b-q8 --local-dir models/brain-4b`.

```bash
# Terminal 2 (in the same brain folder): ask for the next step of a real desktop task
curl -s localhost:8793/v1/systemone -H 'Content-Type: application/json' -d @examples/request.json
```

Success looks like a typed decision with a probability for every option, e.g.
`{"answers": {"operation": {"choice": "CLICK", "probabilities": {"CLICK": 0.96, "OPEN": 0.005, …}}, "click_target": {…}}}`.
A probability is the model's weighting of the options, not a guarantee that the step is right.

**The router (0.8B → 4B), as released:** also download `deskmind/brain-0.8b --revision g18b-q8` into `models/brain-0.8b` (0.8 GB), then serve
`uv run deskmind-brain-serve --predictor mlx:models/brain-0.8b --escalate-to mlx:models/brain-4b --two-stage --port 8796`.
The threshold (0.96) ships with the weights; each reply adds a `routing` record such as `{"by": "strong", "reason": "low_conf", "fast_conf": 0.956}`.

Step by step, with the full reply explained: [Quickstart](https://deskmind.dev/docs/start/quickstart/). To drive the desktop, add [Hands](https://github.com/deskmind-ai/hands).

## Components

| | Role | |
|---|---|---|
| [Eyes](https://github.com/deskmind-ai/eyes) | finds the target on screen | 4B visual grounder, for apps without an accessibility tree |
| [Brain](https://github.com/deskmind-ai/brain) | decides the next step | 0.8B and 4B, MLX, 0.8B → 4B routing, `/v1/systemone` |
| [Hands](https://github.com/deskmind-ai/hands) | observes and acts on macOS | accessibility and vision modes, budgets, cancellation |
| [App](https://github.com/deskmind-ai/app) | brings it to your Mac | native app with a background helper; [download](https://github.com/deskmind-ai/app/releases/latest) |
| [Bench](https://github.com/deskmind-ai/bench) | checks what really happened | sandbox desktop tasks with strict final-state graders |

Models: [huggingface.co/deskmind](https://huggingface.co/deskmind) (`brain-0.8b`, `brain-4b`, `eyes-4b`). Website: [deskmind.dev](https://deskmind.dev). Docs: [deskmind.dev/docs](https://deskmind.dev/docs/).

## Results, with the sample size

| What | Setting | Result |
|---|---|---|
| Real-desktop tasks | Bench v25, 13 tasks × 3 runs, strict graders; router G18b (0.8B → 4B, 8-bit, threshold 0.96), through the app, one M4 Pro (48 GB) | **39/39** passed; **0** false "done" |
| Decision time | the same 39 runs, 208 decisions | median **0.48 s** when the 0.8B answers (about 30% of steps), **3.6 s** when the 4B checks (about 70%); 2.85 s overall, slowest 5% 9.82 s. Per decision, not per task |
| Decision quality | JevBench v1.4.2, 231 public items | Brain 4B **0.835** · Brain 0.8B 0.723 · router 0.797; no sealed score yet |
| Visual grounding | ScreenSpot-Pro, 1,581 items, one pass | Eyes 4B **67.7%** on a GPU (bf16, native resolution; base model 64.8%); **50.9%** as the Mac app runs it (4-bit MLX, ≤ 2 MP) |

- **Small sample.** 13 tasks on one Mac with a Chinese system language. Runs cluster by task (almost every task passes 3/3 or 0/3), so the effective sample is closer to 13 tasks than to 39 runs.
- **One task was not clean.** In all 3 runs of the Chinese exact-text task the file was right, but the model never said "done" and used its full step budget. The grader checks the final state, so these count as passes.
- **G18b traded some general judgement for the desktop.** The 4B's JevBench public score fell from 0.866 (G14) to 0.835, mostly on the hard tier. The previous release, G14, passed 36/39 on the same bench.
- **Eyes' GPU score is not the app's setting.** The app runs a 4-bit MLX conversion at up to 2 MP, which has no benchmark score yet.

Our own runs. Methods and full tables: [Brain results](https://github.com/deskmind-ai/brain/blob/main/docs/results.md) · [Bench reference](https://github.com/deskmind-ai/bench/blob/main/results/reference.md) · [Eyes results](https://github.com/deskmind-ai/eyes/blob/main/docs/results.md) · [Results and limits](https://deskmind.dev/docs/explanation/results-and-limits/).

## Still hard

- Copying long tables (more than about four rows) or only the rows that match a condition.
- Filling a form from a photographed receipt.
- Steps the 4B has to check take a few seconds, and most steps go to the 4B today.

What we are working on next: [ROADMAP](ROADMAP.md).

## Your Mac does the thinking

Inference runs locally by default. The models download once, from Hugging Face or ModelScope; after that, deciding a step needs no network. A cloud model is opt-in: the app never calls one, but if you point the router's escalation tier at one yourself, the steps routed to it go to that service. Apps that DeskMind drives, such as a web page or a music app, still talk to their own servers.

## Contribute

- Questions and design discussion: [Discussions](https://github.com/deskmind-ai/deskmind/discussions).
- Cross-component problems, reproduction reports and project direction: [issues here](https://github.com/deskmind-ai/deskmind/issues). A bug isolated to one component goes to that repository.
- How to help, and what a good report contains: [Contributing](https://deskmind.dev/docs/project/contributing/). A reproduction that disagrees with our numbers is welcome.
- Security problems: not in public; see [SECURITY.md](https://github.com/deskmind-ai/.github/blob/main/SECURITY.md).

## Meet Xiaofang · 小方

<img src="brand/xiaofang/done.png" alt="Xiaofang, the DeskMind companion, with a task done" width="120" align="right">

The frame from our logo, come to life. Artwork in [brand/](brand/), rules in [BRAND.md](BRAND.md).

## License

- Text and documentation in this repository: [CC BY 4.0](LICENSE).
- **Not covered by that licence:** the DeskMind and 得心 names, the DeskMind logo, the Xiaofang (小方) character and the other files under [brand/](brand/). Their use is governed by [BRAND.md](BRAND.md).
- Code lives in the component repositories and is licensed Apache-2.0; see each repository's LICENSE and NOTICE.
- Model weights, base models and datasets follow their own terms.
