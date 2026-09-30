# DeskMind roadmap

[Project overview](README.md) · [中文概览](README.zh-CN.md) · [Contributing](https://github.com/deskmind-ai/.github/blob/main/CONTRIBUTING.md)

**Proposal for maintainer review · September 30, 2026.** These are candidate priorities and acceptance criteria, not committed release dates or promises of support.

The direction is a complete, local-first computer-use system for Apple Silicon. Component quality and end-to-end usefulness are evaluated separately, then connected through reproducible experiments.

## 1. Make the first result reproducible

Proposed work:
- Publish an explicit availability matrix for code, model weights, evaluation artifacts and App builds.
- Pin a compatible Brain/Hands/Bench configuration and document the first typed request, then one disposable-folder task.
- Verify clean-machine setup, model access, required permissions and interruption/retry behavior.
- Provide one reviewed demo with the exact environment, every attempt and a sanitized result bundle.

Acceptance evidence:
- A contributor with the documented access reproduces the first request and task without maintainer intervention.
- The report names source revisions, weight hashes, harness/suite version, hardware, OS and locale.
- Public installation is claimed only when anonymous artifact access and the published flow are verified.

## 2. Measure Brain under defined constraints

Proposed work:
- Compare standalone 0.8B, standalone 4B and the router as separate systems.
- Freeze the eligible model cohort and exact parameter-count definition before comparison.
- Add held-out calibration and risk/coverage measurements; report false DONE and missed approval separately.
- Pursue official or independently administered evaluation alongside public-set results.

Acceptance evidence:
- A dated eligibility manifest, pinned inference settings, item-level results where permitted, uncertainty estimates and failure analysis.
- Validation-only threshold fitting; no sealed-test tuning.
- Any leadership statement identifies metric, cohort, protocol and date. Incomplete coverage is described as “among the models evaluated.”

## 3. Measure Eyes where it is deployed

Proposed work:
- Benchmark the shipped local setting separately from GPU research runs: 4-bit MLX, ≤2 MP and point_2d.
- Keep one-pass and two-pass results separate.
- Evaluate small targets, creative-app icons, absent targets and parse failures.
- Audit dataset provenance and redistribution permissions for intended artifacts.

Acceptance evidence:
- Paired comparisons with fixed checkpoint hashes, preprocessing, coordinate mapping, decoding and scoring.
- Quality, latency and memory measured on named Apple Silicon hardware.
- No transfer of GPU scores into local-Mac claims without a matching measurement.

## 4. Strengthen the complete task loop

Proposed work:
- Expand task and app coverage with held-out families and more than one device/locale.
- Test cancellation, stale targets, denied permissions, approval boundaries and recovery using disposable fixtures.
- Compare component swaps under one frozen harness and record whether Eyes was invoked.
- Report full task duration, interventions, side effects and strict success alongside planner latency.

Acceptance evidence:
- Every attempted run is accounted for; environment errors and exclusions are visible.
- A final-state grader checks outcomes independently of the agent's “done” response.
- A known failure is preserved as a regression test before claiming it is resolved.
- Unsupported cases and manual interventions remain explicit in demos.

## 5. Make contribution useful

Proposed work:
- Keep project-level questions and reproduction reports in this front-door repository.
- Route isolated component bugs to the corresponding repository and cross-link rather than duplicate.
- Add reviewed starter tasks with bounded fixtures, a clear output and acceptance criteria.
- Maintain English/Chinese front-door parity and a verified path from each component back here.

Acceptance evidence:
- A first-time contributor can identify a suitable task, reproduce its scope and submit a reviewable change.
- Reproduction reports can disagree with project results and still be recorded in full.
- A private vulnerability-reporting route is selected and documented before broad public onboarding.

## What would count as progress

Independent reproductions, working integrations, repeated external contributions, clean-install success, and more reliable complete tasks matter most. Stars and downloads are useful discovery signals, but do not establish adoption or correctness.

SOTA remains an aspiration under defined constraints. A useful, reproducible system and an honest negative result are both worth publishing.

## Owner decisions still needed

- Which repositories and artifacts may become public, and with which verified access paths?
- Which initial supported tasks, devices and locales should be documented?
- Which model-size/openness cohorts should bound Brain and Eyes comparisons?
- Which proposed work has an owner and should become an issue?
- Which private security contact and general discussion channel should contributors use?

No dates, issue assignments or public release commitments are set by this proposal.
