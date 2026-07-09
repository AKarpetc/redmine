# AI workflow artifacts — Redmine #43881 (rate-limiting slice)

Built with **Claude Code**. This folder is the AI-workflow record for the pluggable API
rate limiter (pillar 3 of #43881). The deliverable README is `README_RATE_LIMITING.md` at
the repository root.

## Contents

| File | What it is |
|---|---|
| [feature-specification.md](feature-specification.md) | Scope; the two pluggability axes (storage + algorithm) and the availability axis (fail-open + `FailoverStore`); strategy choice; trade-offs; deferred pillars |
| [implementation-plan.md](implementation-plan.md) | Architecture, files, key interfaces, fail-open + failover design (§3b), rotating-key fixed window (§3c), 429 contract (§3d), testing strategy |
| [task-decomposition.md](task-decomposition.md) | Core (~2.5h) vs. extension tiers, time-boxing, cut lines |
| [prompts/](prompts/) | The prompts used to generate the planning docs and the architect review pass |

## Process

1. **Plan (docs only).** The prompts in `prompts/` produced the spec, plan, and
   decomposition, grounded against the `6.1.2` tag (verified facts listed in the spec).
2. **Architect review.** A Principal-Architect review pass (prompt 2) drove the
   fail-open + `FailoverStore` failover revisions and the rotating-key portability fix.
3. **Implement per task.** Commits are made per decomposition task so the git history
   doubles as a workflow artifact.

## Verification note

The core algorithm logic (`Result`, Fixed Window, Sliding Window Counter, Token Bucket,
multi-store portability, fail-open on nil/raise) was validated against real
`ActiveSupport::Cache` `MemoryStore` and `FileStore` instances, plus the full Rails
integration suite for the controller wiring, 429 contract, and settings.
