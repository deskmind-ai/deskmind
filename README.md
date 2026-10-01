<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/social/README-bilingual-dark.svg">
    <img src="brand/social/README-bilingual-light.svg" alt="DeskMind 得心 · 得心，应手。" width="760">
  </picture>
</p>

# DeskMind · 得心

**Small models that operate your Mac, locally, and know how sure they are.**

A 0.8B model decides each step and hands the unsure ones to a 4B. Every decision comes with probabilities. When a goal is ambiguous, it asks before it writes. On our real-desktop bench it never reported a task as done when it wasn't.

[中文](README.zh-CN.md) · [Website](https://deskmind.dev) · [Models](https://huggingface.co/deskmind) · [Discussions](https://github.com/orgs/deskmind-ai/discussions) · [Roadmap](ROADMAP.md) · [Contributing](https://github.com/deskmind-ai/.github/blob/main/CONTRIBUTING.md)

<!-- TODO(launch): replace with the real, unedited demo recording (G18b takes); keep the speed labels visible. -->
<p align="center"><img src="assets/demo.gif" alt="DeskMind running real tasks on a Mac: copying a table, asking before writing an ambiguous record, playing the live version of a song" width="760"></p>

## Try it in three steps

```bash
# 1. Get Brain and a model   (release G18b; drop --revision once HF main points to g18b-q8)
git clone https://github.com/deskmind-ai/brain && cd brain && uv sync --extra mlx
uv run hf download deskmind/brain-4b --revision g18b-q8 --local-dir models/brain-4b

# 2. Serve it on your Mac
uv run deskmind-brain-serve --predictor mlx:models/brain-4b --port 8793 --two-stage

# 3. Ask it for the next step of a real desktop task
curl -s localhost:8793/v1/systemone -H 'Content-Type: application/json' -d @examples/request.json
```

The reply is a typed decision (operation and target) with a probability for every option. To drive the desktop, add [Hands](https://github.com/deskmind-ai/hands); for the full experience, the [Mac app](https://github.com/deskmind-ai/app). <!-- TODO(launch): confirm App availability wording -->

## What's inside

| | Role | |
|---|---|---|
| [Brain](https://github.com/deskmind-ai/brain) | decides the next step | 0.8B and 4B, MLX, optional 0.8B → 4B routing |
| [Eyes](https://github.com/deskmind-ai/eyes) | finds the target on screen | 4B visual grounder |
| [Hands](https://github.com/deskmind-ai/hands) | observes and acts on macOS | accessibility and vision modes, budgets, cancellation |
| [Bench](https://github.com/deskmind-ai/bench) | checks what really happened | sandbox tasks with strict final-state graders |
| [App](https://github.com/deskmind-ai/app) | brings it to your Mac | native app |

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
