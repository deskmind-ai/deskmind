<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/social/README-bilingual-dark.svg">
    <img src="brand/social/README-bilingual-light.svg" alt="DeskMind 得心 · 得心，应手。" width="760">
  </picture>
</p>

# DeskMind · 得心

**Small models that operate your Mac, locally, with a probability for every decision.**

A 0.8B model decides each step and hands the unsure ones to a 4B. Every decision comes with probabilities. When a goal is ambiguous, it asks before it writes. On our real-desktop bench (v25, router G18b, 13 tasks × 3 runs) it never reported a task as done when it wasn't: 0 false DONE in 39 runs.

[中文](README.zh-CN.md) · [Website](https://deskmind.dev) · [Models](https://huggingface.co/deskmind) · [Discussions](https://github.com/orgs/deskmind-ai/discussions) · [Roadmap](ROADMAP.md) · [Contributing](https://github.com/deskmind-ai/.github/blob/main/CONTRIBUTING.md)

<!-- TODO(launch): replace with footage of the released model that passed acceptance (real, unedited takes); keep the speed labels visible. -->
<p align="center"><img src="assets/demo.gif" alt="DeskMind running real tasks on a Mac: copying a table, asking before writing an ambiguous record, playing the live version of a song" width="760"></p>

## Try it in three steps

This runs the **4B alone** (release G18b) on an Apple Silicon Mac. It answers one step of a desktop task; it does not drive the desktop by itself.

```bash
# Terminal 1: get Brain and the model, then serve it
git clone https://github.com/deskmind-ai/brain && cd brain && uv sync --extra mlx
uv run hf download deskmind/brain-4b --revision g18b-q8 --local-dir models/brain-4b
uv run deskmind-brain-serve --predictor mlx:models/brain-4b --port 8793 --two-stage
```

The model is a 4.2 GB download. If it fails with a `CAS Client Error`, rerun the download with `HF_HUB_DISABLE_XET=1`.

```bash
# Terminal 2 (in the same brain folder): ask for the next step of a real desktop task
curl -s localhost:8793/v1/systemone -H 'Content-Type: application/json' -d @examples/request.json
```

Success looks like a typed decision with a probability for every option, e.g.
`{"answers": {"operation": {"choice": "CLICK", "probabilities": {"CLICK": 0.96, "OPEN": 0.005, …}}, "click_target": {…}}}`.
A probability is the model's weighting of the options, not a guarantee that the step is right.

**The router (0.8B → 4B), as released:** also download `deskmind/brain-0.8b --revision g18b-q8` into `models/brain-0.8b`, then serve
`uv run deskmind-brain-serve --predictor mlx:models/brain-0.8b --escalate-to mlx:models/brain-4b --two-stage --port 8796`.
The threshold (0.96) ships with the weights; each reply adds a `routing` record such as `{"by": "strong", "reason": "low_conf", "fast_conf": 0.956}`.

To drive the desktop, add [Hands](https://github.com/deskmind-ai/hands). The Mac app is not public yet.

## What's inside

| | Role | |
|---|---|---|
| [Brain](https://github.com/deskmind-ai/brain) | decides the next step | 0.8B and 4B, MLX, optional 0.8B → 4B routing |
| [Eyes](https://github.com/deskmind-ai/eyes) | finds the target on screen | 4B visual grounder |
| [Hands](https://github.com/deskmind-ai/hands) | observes and acts on macOS | accessibility and vision modes, budgets, cancellation |
| [Bench](https://github.com/deskmind-ai/bench) | checks what really happened | sandbox tasks with strict final-state graders |
| App | brings it to your Mac | native app; not public yet |

## Results

| What | Setting | Result |
|---|---|---|
| Real-desktop tasks | Bench v25, router G18b (0.8B → 4B, 8-bit, threshold 0.96), through the app, M4 Pro, 13 tasks × 3 runs | **39/39**, 0 false DONE; decision p50 0.48 s when the 0.8B answers, 3.6 s when the 4B checks (~70% of steps); not full-task time |
| Same-harness comparison | Bench v23 (earlier release G14), one environment-error run excluded per system | DeskMind **35/38** · Jev 33/38 |
| Decision quality | JevBench v1.4.2, 231 public items | Brain 4B **0.835** · Brain 0.8B **0.723** (G18b; G14 4B was 0.866) |
| Visual grounding | ScreenSpot-Pro, 1,581 items, GPU, one pass | Eyes **67.7%** (base 64.8%) |

Our own runs; methods and full tables: [Bench reference](https://github.com/deskmind-ai/bench/blob/main/results/reference.md) · [Brain](https://github.com/deskmind-ai/brain/blob/main/docs/results.md) · [Eyes](https://github.com/deskmind-ai/eyes/blob/main/docs/results.md).

## Limits

A small diagnostic suite on one Mac and one locale; most steps currently go to the 4B, so a typical decision takes about 3 s; the release gave up some general judgement on JevBench's hard tier; the local 4-bit Eyes setting has no benchmark score yet; public-set scores are not a sealed JevBench result. Inference stays on your Mac by default, but model downloads and networked apps use the network. What we are working on: [ROADMAP](ROADMAP.md).

## Meet Xiaofang · 小方

The frame from our logo, come to life. Artwork in [brand/](brand/), rules in [BRAND.md](BRAND.md).

## License

Docs in this repository: [CC BY 4.0](LICENSE). Code: each component's LICENSE and NOTICE. Model weights and datasets carry their own terms. Brand: [BRAND.md](BRAND.md).
