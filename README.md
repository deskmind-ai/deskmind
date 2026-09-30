<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/social/README-bilingual-dark.svg">
    <img src="brand/social/README-bilingual-light.svg" alt="DeskMind 得心 · 得心，应手。" width="760">
  </picture>
</p>

# DeskMind · 得心

**得心，应手。 · See. Think. Act.**

**Small models that know how sure they are.** A 0.8B model decides each step and hands the step to a 4B model when it is unsure. Every decision is typed, with a probability for each option. When a goal could mean more than one thing, DeskMind asks before it writes. On our real-desktop bench (v25, router-g14-q8, 13 tasks × 3 runs) it passed 36 of 39 runs and never reported a task as done when it was not (0 false DONE).

A local-first computer-use stack for Apple Silicon: small models for decisions and visual grounding, a macOS execution loop, reproducible evaluation, and a native Mac app.

[中文](README.zh-CN.md) · [Roadmap](ROADMAP.md) · [Contributing](https://github.com/deskmind-ai/.github/blob/main/CONTRIBUTING.md) · [Brand](BRAND.md)

DeskMind is being built as a complete desktop-agent system. Brain, Eyes, Hands, Bench and App have separate interfaces so you can study, replace or use a component on its own. The aim is a useful end-to-end experience backed by independently measurable components.

**Development snapshot · September 30, 2026.** The source repositories are currently private. Project documentation also identifies the release model repositories as private. The links below require the relevant access; they are not a public-install promise. Availability will be updated after public artifacts and clean-install instructions have been verified.

## The stack

| Component | Role | Current scope |
|---|---|---|
| [Brain](https://github.com/deskmind-ai/brain) | Choose the next step | 0.8B and 4B typed-decision models; local MLX serving; optional two-tier routing |
| [Eyes](https://github.com/deskmind-ai/eyes) | Locate a target in a screenshot | 4B visual grounder, training/evaluation tools and an experimental local server |
| [Hands](https://github.com/deskmind-ai/hands) | Observe and act on macOS | Desktop loop, accessibility-based observations, visual fallback, execution budgets and cancellation |
| [Bench](https://github.com/deskmind-ai/bench) | Check what actually happened | Sandbox tasks, fixtures, strict graders and versioned reference summaries |
| [App](https://github.com/deskmind-ai/app) | Bring the stack to a Mac user | Native macOS app and permission-bearing helper; packaged development release |

A task starts in App or a developer client. Hands observes the desktop, Brain selects a typed action, and Hands executes it and observes again. Eyes can help locate a target when needed. Bench evaluates the resulting state in controlled tasks.

Not every task invokes Eyes. Finder and TextEdit can use synthetic accessibility projections, so success on those tasks does not by itself demonstrate screenshot-only grounding or Eyes' contribution.

## Choose your entry point

- **Try the Mac experience:** start with [App requirements and setup](https://github.com/deskmind-ai/app/blob/main/README.md). The documented target is Apple Silicon with macOS 15+. Current builds need access to private models. A packaged release exists; a public, independently verified clean-install path is still to be established.
- **Build with one component:** start with [Brain's typed-decision API](https://github.com/deskmind-ai/brain/blob/main/README.md), [Eyes' grounding interface](https://github.com/deskmind-ai/eyes/blob/main/README.md), or [Hands](https://github.com/deskmind-ai/hands). Brain can be tested with a supplied request before controlling a desktop.
- **Reproduce or challenge a result:** start with [Bench](https://github.com/deskmind-ai/bench) and the exact [reference configuration](https://github.com/deskmind-ai/bench/blob/main/results/reference.md). Use the benchmark submission form in this repository once these templates are adopted.

Keep experiments inside a disposable test folder and explicitly selected apps. Check the component's permissions and data paths before running it.

## What is demonstrated today

Repository reports cover scoped Finder tasks such as creating a folder and moving a file, exact TextEdit edits, ambiguity handling and cancellation. These are candidates for a reproducible demo; a reviewed public recording and downloadable demo bundle are not linked yet.

Besides Finder and TextEdit (accessibility projection), Hands has a vision mode for apps that expose no usable accessibility tree: it reads the screen with OCR and Eyes, and Brain decides from that. Development runs include searching for and playing a specific version of a song in a desktop music app in this mode. These runs are not yet part of a published Bench suite.

The next demo should show the goal, permitted apps/folder, observed state, selected action, final file state and any intervention. It should identify when projection or vision is used and include failures. A proposed multi-app showcase remains a development goal until its exact run is recorded and verified.

**Known limits:** the diagnostic web-extraction task remains unsolved; the reported real-desktop evaluation used one Mac and locale; generalization to other apps and environments needs more testing.

## Evidence and its boundaries

The following are project-reported measurements, not independent replications.

### End-to-end desktop tasks

The latest Bench reference reports **36/39 strict passes (92%)**, no environment errors and no false DONE for **v25, router-g14-q8**: 0.8B → 4B, 8-bit, Apple M4 Pro with 48 GB memory. The suite contains 13 tasks repeated three times, with the projection layer enabled.

Planner-decision latency is **0.57 s p50 / 5.25 s p95**. These are not full-task completion times. Repeated runs cluster by task, and this small diagnostic suite does not establish broad desktop reliability.

The earlier same-harness **v23** comparison reports DeskMind **35/38** versus Jev **33/38**, with one environment-error run excluded for each system. No matched v25 Jev result is reported in the inspected reference table. Do not pool or rank results across harness versions.

[Reference results and definitions](https://github.com/deskmind-ai/bench/blob/main/results/reference.md)

### Brain decision quality

Brain 4B reports **0.866** accuracy and Brain 0.8B **0.706** on **231 public JevBench v1.4.2 items**. These are public-set scores; an official sealed/composite score has not been established. Typed probability outputs are an interface property; held-out calibration is a separate evaluation requirement.

[Brain methods, results and limitations](https://github.com/deskmind-ai/brain/blob/main/docs/results.md)

### Eyes visual grounding

On **1,581 ScreenSpot-Pro items**, Eyes reports **67.7% one-pass, no zoom**, compared with **64.8%** for its GUI-Owl base and **66.1%** for the tested KV-Ground comparator on the same stack. The **77.5% two-pass zoom** result uses a separate compute budget.

These runs used a single GPU, vLLM 0.19, bf16, greedy decoding, native-resolution images and the Qwen3-VL computer-use tool prompt. The local server uses **4-bit MLX, ≤2 MP images and a point_2d prompt**; **there is no measured benchmark score for that deployed setting yet**.

[Full Eyes results and failure slices](https://github.com/deskmind-ai/eyes/blob/main/docs/results.md)

### Where we want to go

We aim for leading small-model decision quality and visual grounding under explicitly defined size, openness and compute constraints, alongside reliable complete tasks. **SOTA is a research goal, not a current claim.** Before making a leadership claim, we need a current eligible-model comparison, pinned protocols, public evidence, rights review and independent reproduction. [Proposed priorities](ROADMAP.md)

## Local-first operation

The default local model-serving path is designed to keep inference on the Mac. Model downloads use the network; actions in networked apps can also transmit data. Developer configurations can enable a remote escalation tier, which receives the requests sent to it.

Review the exact configuration and component documentation. Local inference alone does not establish a security guarantee or imply that every action is offline. Share only sanitized logs and screenshots in reports.

## Contribute

Start here for cross-stack questions, reproducibility reports and project direction. If a bug is isolated to Brain, Eyes, Hands, Bench or App, open it in that component's repository when you have access and link any related front-door issue. If the component is unclear, report it here.

Use [CONTRIBUTING.md](https://github.com/deskmind-ai/.github/blob/main/CONTRIBUTING.md) for report contents and routing. If GitHub Discussions is enabled later, general Q&A and design conversations can use it; this README does not assume it is available.

## Meet Xiaofang · 小方

Xiaofang is the frame from our logo, come to life. Existing artwork is in [brand/](brand/); usage is governed by [BRAND.md](BRAND.md).

## License

- Text and documentation in this repository are licensed under [CC BY 4.0](LICENSE).
- Code is licensed in each component repository; consult its LICENSE and NOTICE.
- Model weights, base models and datasets have their own terms. Code licensing alone does not establish permission to redistribute every artifact.
- DeskMind, 得心, the logo and Xiaofang are governed separately by [BRAND.md](BRAND.md).
