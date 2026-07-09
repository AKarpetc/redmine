# Task Decomposition

> **Scope note.** Adding two pluggability axes (storage + algorithm), resilience
> (fail-open + rotating-key portability), and three shipped algorithms is genuinely more
> than the challenge's ~2h "small slice" guideline — closer to **~3.5–4h** done properly.
> This is a deliberate trade requested for open-source flexibility and availability. The
> table below is time-boxed into a **~2.5h core** (ships a complete, tested, pluggable,
> *fail-open* limiter with the default algorithm) and an **extension tier** (the extra
> algorithms + admin UI). If the guideline is hard, cut from the bottom of the extension
> tier — never from the resilience floor (see cut lines).

Commits are made per task so the git history doubles as an AI-workflow artifact.

## Core tier (~2h) — a shippable, defensible slice on its own

| # | Task | Details | Time |
|---|---|---|---|
| 1 | **Repo setup** | Fetch upstream tag `6.1.2` into the fork, branch `feature/43881-api-rate-limiting`, confirm `bundle install` + `db:migrate` + suite boots | 10 min |
| 2 | **Storage backend** | `config.redmine_api_rate_limit_cache_store` (mirrors `redmine_search_cache_store`); limiter resolves + uses portable cache API | 15 min |
| 3 | **Strategy interface + Fixed Window** | `ApiRateLimiter` facade, `Result` (incl. `disabled`/nil-safe), `Strategies::Base` (nil counter → allow), `Strategies::FixedWindow` **rotating-key** (default, §3c), algorithm registry, increment-first invariant | 35 min |
| 4 | **Controller wiring + settings** | `ApiRateLimitable` concern into `ApplicationController` (post-auth); **fail-open `rescue` + instrumentation (§3b Layer 1)**; `skip_rate_limit` exemption hook; full `X-RateLimit-*` on allowed+denied; settings defaults; locale strings | 30 min |
| 5 | **Tests (core)** | Integration: 429 path, per-caller isolation, disabled flag, headers (+ header survival), HTML exemption, window reset, **fail-open (store raises → 200), exempt action**. Unit: FixedWindow **across `:memory_store` + `:file_store`** (portability) | 35 min |
| 6 | **README + AI artifacts** | Approach / done / deferred / assumptions / run & verify / limits / **availability & failover** (fail-open + `FailoverStore` design); transcripts into `docs/ai/` | 25 min |

**Core subtotal: 155 min.** The resilience items (fail-open, rotating-key portability,
multi-store test) are folded into the core because they are correctness/availability
essentials, not polish — a limiter that 500s when Redis blinks fails the "maximum
availability" goal outright.

## Extension tier (if time allows)

| # | Task | Details | Time |
|---|---|---|---|
| 7 | **Sliding Window Counter strategy** | `Strategies::SlidingWindowCounter` + unit tests | 25 min |
| 8 | **Token Bucket strategy** | `Strategies::TokenBucket` (+ documented RMW caveat) + unit tests | 30 min |
| 9 | **Admin UI** | Algorithm dropdown + param fields on Settings → API tab | 20 min |

**Extension subtotal: 75 min.** Full build ≈ 230 min.

> The **`FailoverStore` circuit breaker** (feature-spec §2.1 Layer 2 / plan §3b Layer 2)
> is **designed, not built** in this challenge — per the design-judgment scope decision.
> Its pseudo-code and degradation semantics are the deliverable artifact; wiring it in is a
> named post-slice extension. The core already fails open, so availability does not depend
> on it shipping.

## Cut lines (drop from bottom of extension tier first)

1. Task 9 (admin UI) — settings still work via `Setting` defaults / console.
2. Task 8 (token bucket) — the approximate one; least clean fit.
3. Task 7 (sliding window counter) — leaves a fully working Fixed-Window-only limiter,
   which alone satisfies the required core.

**Not cuttable** — fail-open (§3b), rotating-key fixed window (§3c), and the multi-store
portability test moved into the **core** (tasks 3–5). They are the availability/correctness
floor, not extensions.

## Explicitly not started

Deferred pillars and the two deferred algorithms — see
[feature-specification.md](feature-specification.md#7-deferred-pillars).
