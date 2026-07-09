# Feature Specification — Pluggable API Rate Limiting (Redmine #43881, pillar 3)

## 0. Design goals

Redmine is open source and self-hosted by organizations with wildly different
deployment topologies (a single Puma process on a VM through to many processes across
many hosts behind a load balancer). The rate limiter is therefore built for
**scalability and flexibility** as first-class goals: every operator can configure

1. **where** counters are stored (storage backend), and
2. **which** algorithm enforces the limit, and
3. the **parameters** of that algorithm,

without touching code. The two pluggability axes and their honest interaction are the
core of this spec.

A fourth, cross-cutting goal is **availability under storage failure**. The limiter sits
in the hot path of every API request, so it must never turn a storage outage into an
application outage. It therefore **fails open** — a storage error allows the request
rather than raising — and defines a **failover** extension point (§2.1) that degrades a
failed shared store to a per-process in-memory store and auto-recovers. Enforcement is
sacrificed before availability, never the reverse.

## 1. Slice scope

**Core (required): a pluggable, configurable API rate limiter returning HTTP 429**,
applied to every API request (`format=xml|json`), keyed per caller
(`user:<id>` when authenticated, else `ip:<remote_ip>`), with:

- a **configurable storage backend** (§2),
- a **configurable algorithm** via a Strategy pattern (§3),
- **per-algorithm configurable parameters** via Redmine `Setting`s (§4),
- a **429 response** with the full standard header set + structured body (§1.1),
  **identical regardless of the active algorithm**; the same `X-RateLimit-*` headers are
  also emitted on **allowed** responses so clients can self-throttle before hitting 429,
- **fail-open** behavior on any storage error (§2.1) so the limiter never takes down the
  API.

### 1.1 Response contract (algorithm-independent)

Every rejected request returns the same shape; only the values differ. The **`Result`
value object carries all four rate-limit values, and every strategy is responsible for
populating them** (§3.1), so the concern renders one contract for all algorithms:

```
HTTP/1.1 429 Too Many Requests
X-RateLimit-Limit: 100          # ceiling for the window/bucket
X-RateLimit-Remaining: 0        # requests left now (0 on a 429)
X-RateLimit-Reset: 1770043766   # epoch seconds when capacity returns (UTC)
Retry-After: 60                 # seconds to wait (integer; RFC 7231)
Content-Type: application/json  # or application/xml — caller's format

{
  "error": "Rate limit exceeded",
  "message": "You have exceeded the rate limit of 100 requests per minute. Try again in 60 seconds."
}
```

- `X-RateLimit-*` headers are also set on **2xx** responses (`Remaining` counts down,
  `Retry-After` omitted). This follows the de-facto `RateLimit` header convention used by
  GitHub and others; the `X-`-prefixed variant is chosen for compatibility with existing
  Redmine API clients.
- The **body** is rendered in the caller's format (`json`/`xml`) with a stable machine
  string (`error`) plus a human, parameterized `message`. See §3.1 for the derivation of
  each value per algorithm, and the implementation plan §3d for the exact renderer (a
  small dedicated `render_rate_limit_error`, since Redmine's generic `render_error` emits
  a different `{"errors":[…]}` envelope — the deviation is deliberate and documented).

**Optional pillar included:** admin fields on the existing
**Administration → Settings → API** tab to toggle the limiter, pick the algorithm, and
tune parameters.

## 2. Storage backend — flexibility axis #1

### Mechanism

A dedicated, operator-swappable cache store, mirroring Redmine's **existing** precedent
`config.redmine_search_cache_store` (`config/application.rb:84-90` — a separate,
documented, swappable store for search results):

```ruby
# config/application.rb (new line, same idiom as redmine_search_cache_store)
config.redmine_api_rate_limit_cache_store = :memory_store   # default
```

The limiter resolves its store from this config at boot and uses **only the portable
subset** of the `ActiveSupport::Cache` API (`increment`, `read`, `write` with
`expires_in`). Because it targets the standard cache interface, it accepts any
Rails-supported store with zero code changes:

| Store | Deployment topology | Notes |
|---|---|---|
| `:memory_store` | Single process | Per-process counters; fastest; **default** |
| `:file_store` | Single host, multi-process | Shared via filesystem; file-locked, slower |
| `:mem_cache_store` | Multi-host | Shared; requires the `dalli` gem (operator adds it) |
| `:redis_cache_store` | Multi-host, high volume | Shared; requires the `redis` gem (operator adds it) |
| custom | anything | Any `ActiveSupport::Cache::Store` subclass |

Redmine's Gemfile ships **no** `redis`/`dalli` gem, so Redis/memcached backends require
the operator to add the gem — this is documented, not bundled, to avoid forcing a
dependency on the dependency-conservative core.

### Default and rationale

Default is `:memory_store` (matches the `redmine_search_cache_store` default and the
single-instance common case). The README instructs multi-instance operators to switch to
`:redis_cache_store` / `:mem_cache_store` for a **shared** counter — otherwise each
process enforces its own limit and the effective global limit is `limit × processes`.

### 2.1 Availability: fail-open + failover (the resilience axis)

"Configurable storage" is not the same as "resilient storage." A shared store (Redis /
memcached) is a network dependency in the hot path of every API request, so its failure
must be contained. Two layers, in increasing scope:

**Layer 1 — fail-open (ships in the core).** Every storage call is wrapped so that a
raised error *or* a `nil` return degrades to **allow**, never to a 500. This matters
because store failure behavior is not uniform:

- `ActiveSupport::Cache::RedisCacheStore` has an internal `failsafe` that **rescues
  connection errors and returns `nil`** — it does not raise, so strategies must treat a
  `nil` counter as "allow," or they `NoMethodError` on `nil` → 500.
- `:mem_cache_store` (Dalli) and a custom store may **raise** instead — so the concern
  also `rescue`s, instruments the error, and allows the request.

The policy is stated once and pinned by a test: **enforcement is sacrificed before
availability.** A slow (not dead) store is bounded by client timeouts so a degraded store
cannot hang every request (see implementation plan §3b).

**Layer 2 — failover store (documented extension point, not built in the slice).** A
`FailoverStore` decorator implementing the same portable cache subset (`increment`,
`read`, `write`) wraps a **primary** (e.g. Redis) and a **fallback**
(`MemoryStore`) behind a **circuit breaker**: consecutive primary errors trip the breaker
and route calls to the fallback; a monotonic-clock cooldown then half-opens to probe
recovery, and a success closes the breaker. This turns "Redis down" into "degrade to a
per-process limit" instead of "fail fully open." Its honest degradation semantics —
covered in the deliverable README — are:

- failover from a **shared** store to a **per-process** fallback silently changes the
  guarantee from one global limit to `limit × processes`;
- fallback counters start at **zero**, so a burst is briefly allowed at the moment of
  failover, and primary/fallback counts diverge until recovery;
- breaker state is shared across Puma threads and must be thread-safe.

The full design and pseudo-code live in the implementation plan (§3b); the slice ships
Layer 1 and documents Layer 2 as the named availability extension point (same treatment
as the deferred Redis-native Lua strategy).

## 3. Algorithm — flexibility axis #2

### Mechanism: Strategy pattern

`Redmine::ApiRateLimiter::Strategies::*`, each a small class with one interface:

```ruby
# consume one request; pure function of (store, key, config, now)
Strategy.consume(store:, key:, limit:, window:, now:, **opts)
  # => Result(allowed:, limit:, remaining:, reset_at:, retry_after:)
```

Selected at runtime by `Setting.rest_api_rate_limit_algorithm`. Adding an algorithm =
adding one class + one entry in the algorithm registry; no controller changes.

### 3.1 Every strategy populates the response-header values

The `Result` returned by **every** strategy carries the four values the §1.1 contract
needs, so the concern renders one uniform response no matter which algorithm is active.
Each algorithm derives them as follows:

| `Result` field | Fixed Window | Sliding Window Counter | Token Bucket |
|---|---|---|---|
| `limit` (`X-RateLimit-Limit`) | `requests` setting | `requests` setting | `burst` (bucket capacity) |
| `remaining` (`X-RateLimit-Remaining`) | `max(0, limit − count)` | `max(0, limit − weighted_count)`, floored | `tokens.floor` after consume |
| `reset_at` (`X-RateLimit-Reset`, epoch s) | end of current window: `(bucket + 1) × window` | end of current window | now + time to refill 1 token (when empty) / to full |
| `retry_after` (`Retry-After`, integer s) | `⌈reset_at − now⌉` | `⌈reset_at − now⌉` | `⌈(1 − tokens) / refill_rate⌉` |

Rules the `Result` enforces so headers are always well-formed: `remaining` is a
non-negative integer (0 on a 429); `reset_at` is UTC epoch seconds; `retry_after` is a
positive integer (`ceil`, never 0 on a reject) so a client never busy-loops. `Result`
provides a `to_headers` helper the concern uses for both allowed and denied paths.

### Storage × algorithm interaction (the honest constraint)

Not every algorithm is portable across every store. The generic `ActiveSupport::Cache`
API offers atomic `increment` but **not** atomic multi-key read-modify-write or sorted
sets. So:

- **Counter-based** algorithms need only atomic `increment` → portable across **all**
  stores above.
- **Token bucket** needs atomic read-modify-write of `{tokens, updated_at}`; on a shared
  store this races under contention unless done in a server-side script (Redis Lua). Via
  the generic API it is approximate under high concurrency.
- **Sliding-window log** needs a sorted set (Redis `ZADD`/`ZREMRANGEBYSCORE`) — not
  expressible through the generic cache API at all.

### What ships vs. what is a documented extension point

The five algorithms from the design comparison, mapped to this slice:

| Algorithm | Memory | Boundary burst | Portable via cache API? | This slice |
|---|---|---|---|---|
| **Fixed Window** | Extremely low | High | ✅ (atomic `increment`) | **Ship — default** |
| **Sliding Window Counter** | Low | No | ✅ (two counters + `increment`) | **Ship** |
| **Token Bucket** | Low | No (handles organic bursts) | ⚠️ approximate (RMW race) | **Ship, with documented caveat** |
| Sliding Window Log | High | No | ❌ (needs sorted set) | Interface defined; **deferred** (Redis-native strategy) |
| Leaky Bucket | Low | No (smooths) | ⚠️ (RMW, shaping semantics) | Interface defined; **deferred** |

Shipping three real, portable-or-caveated strategies proves the pluggability; the
remaining two are honest extension points with the interface already accommodating them.

## 4. Configurable parameters

All via `Setting` rows (no migration — `Setting` is key/value):

| Setting | Default | Applies to |
|---|---|---|
| `rest_api_rate_limit_enabled` | `1` | all |
| `rest_api_rate_limit_algorithm` | `fixed_window` | selector |
| `rest_api_rate_limit_requests` | `100` | fixed / sliding-window counter (max requests) |
| `rest_api_rate_limit_window` | `60` | fixed / sliding-window counter (seconds) |
| `rest_api_rate_limit_burst` | `100` | token bucket (bucket capacity) |
| `rest_api_rate_limit_refill_rate` | `1.67` | token bucket (tokens/sec ≈ 100/60) |

Unknown/blank algorithm falls back to `fixed_window`. Parameters irrelevant to the
selected algorithm are ignored.

## 5. Strategy vs. off-the-shelf (why our own abstraction)

| Option | Verdict |
|---|---|
| Rails 7.2 built-in `rate_limit` | **Rejected** — key embeds `controller_path` (per-controller buckets, no global API limit; `name:` only in Rails 8), single hard-coded algorithm, no pluggable storage. Cannot meet the flexibility goals. |
| `Rack::Attack` | **Rejected for this slice** — good, but adds a gem, runs pre-auth so it can't key by authenticated user (Basic/OAuth callers collapse to IP), and its throttle model is not a clean multi-algorithm strategy surface. |
| **Custom `Redmine::ApiRateLimiter` (facade) + Strategy classes over a configurable cache store** | **Chosen** — zero new mandatory dependencies, exact post-auth identity, and it is the only option that delivers both pluggability axes the goals demand. |

## 6. Accepted trade-offs (defended in the deliverable README)

1. **Counted post-auth** — an over-limit request still pays routing + the auth DB lookup.
   Rack-level rejection is cheaper but cannot see caller identity; traded away. Deeper
   consequence: an **anonymous flood keyed by IP still runs `find_current_user` (a DB
   lookup) before the limiter can shed it**, so this is an abuse/fairness limiter for
   authenticated callers, **not** a DoS shield for the auth/DB layer. A cheap Rack-level
   IP throttle is the complementary front line and is named as a deferred layer (§7).
2. **Store determines the correctness guarantee** — single shared store (Redis/memcached)
   = one true global limit; per-process store (`:memory_store`) = limit enforced per
   process. Documented prominently.
3. **Fixed window** (the default) allows up to 2× burst across a window boundary — chosen
   as the default for its extremely low memory and portability; operators wanting
   smoothing switch to sliding-window counter via one setting.
4. **Token bucket is approximate** on shared stores without server-side atomicity; noted
   at point of use.
5. **Fail-open on storage error** (§2.1) — a storage outage lets requests through rather
   than 500-ing. Availability is chosen over enforcement, deliberately and testably.
6. **Anonymous keying trusts `request.remote_ip`** — behind a misconfigured proxy,
   `X-Forwarded-For` spoofing can rotate IPs to bypass the anon limit, or spoof a
   victim's IP to throttle them. The guarantee is only as good as Redmine's trusted-proxy
   configuration; called out in the README "Limits" section.

## 7. Deferred pillars

Personal access tokens (1), scopes (2), audit logging (4 — the limiter `before_action`
is a natural hook), granular endpoint control (5), CORS (6). Plus the two deferred
algorithms (§3), Redis-native atomic (Lua) strategy implementations, the **`FailoverStore`
circuit-breaker** (§2.1 Layer 2, design fully specified), and a **cheap Rack-level IP
throttle** as a pre-auth front line for anonymous floods (§6.1).

## 8. Judgment calls (overridable before implementation)

- **Default enabled**, `fixed_window`, 100 req / 60 s, `:memory_store`. Core Redmine
  might default off for backward compatibility; "on" demos better and single-instance
  memory store is the safest zero-config default.
- **Per-user identity** (not per-token/IP): Redmine 6.1.2 has one API key per user, so
  finer granularity buys nothing until personal access tokens (pillar 1) exist.
