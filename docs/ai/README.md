# AI workflow artifacts — Redmine #43881 (rate-limiting slice)

Built with **Claude Code**. This folder is the AI-workflow record for the pluggable API
rate limiter (pillar 3 of #43881). The deliverable README is `README_RATE_LIMITING.md` at
the repository root.

## Approach — Spec-Driven Development (SDD)

This slice was built **spec-first**: instead of jumping straight to code, each phase produced
a reviewed document before the next began —
**feature specification → task decomposition → implementation plan → code → code review**.
Every phase is captured as a durable artifact in this folder (specs) and under
[`issue-43881/prompts/`](issue-43881/prompts/) (the prompts that drove each phase), and the
git history commits one step per decomposition task, so the plan and the code stay traceable
to each other.

## Agents & models

Two models were used, each for the stage it fits best:

| Stage | Agent / model | Why |
|---|---|---|
| Code & task decomposition | **Claude Code — Opus 4.8** | Long-context reasoning over the Redmine codebase: implementing the slice and decomposing the work into small, committable tasks |
| Prompt preparation | **Gemini 3.1 Pro** | Drafting and refining the prompts (spec generation, architect review, code review) that drove each SDD phase |

## Contents

The per-issue artifacts live under [`issue-43881/`](issue-43881/README.md) — **start there**
for the full spec index, one-paragraph context, and the facts verified against tag `6.1.2`.

| File | What it is |
|---|---|
| [issue-43881/README.md](issue-43881/README.md) | Spec index, context, and grounding facts verified against `6.1.2` — **start here** |
| [issue-43881/feature-specification.md](issue-43881/feature-specification.md) | Scope; the two pluggability axes (storage + algorithm) and the availability axis (fail-open + `FailoverStore`); strategy choice; trade-offs; deferred pillars |
| [issue-43881/implementation-plan.md](issue-43881/implementation-plan.md) | Architecture, files, key interfaces, fail-open + failover design (§3b), rotating-key fixed window (§3c), 429 contract (§3d), testing strategy |
| [issue-43881/task-decomposition.md](issue-43881/task-decomposition.md) | Core (~2.5h) vs. extension tiers, time-boxing, cut lines |
| [issue-43881/prompts/](issue-43881/prompts/) | The prompts used to generate the planning docs, the architect review pass, and the post-implementation code review |

## Process

1. **Plan (docs only).** Prompt 1 (`issue-43881/prompts/1. spec-generate.md`) produced the
   spec, plan, and decomposition, grounded against the `6.1.2` tag (facts listed in the spec).
2. **Architect review.** A Principal-Architect review pass (prompt 2) drove the
   fail-open + `FailoverStore` failover revisions and the rotating-key portability fix.
3. **Implement per task.** Commits are made per decomposition task so the git history
   doubles as a workflow artifact.
4. **Code review.** A deep code-review pass (prompt 3, `issue-43881/prompts/3. code-review.md`)
   audited the implementation, tests, and docs; its findings were then fixed (see the commit
   history) — settings clamping, DRY/naming cleanups, `FailoverStore` tests, extra
   integration coverage, and doc-accuracy fixes.

## Verification note

The core algorithm logic (`Result`, Fixed Window, Sliding Window Counter, Token Bucket,
multi-store portability, fail-open on nil/raise) was validated against real
`ActiveSupport::Cache` `MemoryStore` and `FileStore` instances, plus the full Rails
integration suite for the controller wiring, 429 contract, and settings.
