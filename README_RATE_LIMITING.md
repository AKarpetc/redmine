# API Rate Limiting (Redmine #43881, pillar 3)

A pluggable, configurable API rate limiter for Redmine. Over-limit API callers get
`HTTP 429 Too Many Requests`; every API response also carries `X-RateLimit-*` headers so
well-behaved clients can self-throttle before they are rejected.

This is **one pillar** of the six-part [#43881 — Strengthen API authentication](https://www.redmine.org/issues/43881)
ticket, shipped as a self-contained, tested slice. The other pillars are deferred (§8).

---

## 1. What this is

The limiter runs on every API request (`format=xml|json`), keyed per caller
(`user:<id>` when authenticated, `ip:<remote_ip>` when anonymous). Two things are
configurable **without touching code**, and one cross-cutting property is guaranteed:

1. **Where** counters are stored — a swappable cache store (§3).
2. **Which** algorithm enforces the limit — a Strategy chosen by `Setting` (§4).
3. **Availability** — a storage fault degrades to *allow*, never to a 500 (§5).

## 2. How it works

```
ApplicationController
  └─ include ApiRateLimitable          # before_action (post-auth), headers, 429, FAIL-OPEN rescue
       └─ Redmine::ApiRateLimiter      # facade: reads Settings, resolves store + strategy
            ├─ .store                  # <- config.redmine_api_rate_limit_cache_store
            ├─ REGISTRY {algo => class}
            └─ Strategies::{FixedWindow, SlidingWindowCounter, TokenBucket}
                 -> Result(allowed?, limit, remaining, reset_at, retry_after)
```

- The concern is included into `ApplicationController` **after** the auth `before_action`
  chain, so `User.current` is already resolved and authenticated callers are keyed by id.
- The facade reads every `Setting` fresh per request (changes apply without a restart),
  resolves the store, picks the strategy, and returns a `Result`.
- The `Result` value object carries all four header values, and its `#to_headers` is the
  single source of header truth used on **both** the allowed (2xx) and denied (429) paths,
  so headers are always internally consistent and identical across algorithms.

### 429 response contract (identical for every algorithm)

```
HTTP/1.1 429 Too Many Requests
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 1770043766      # UTC epoch seconds when capacity returns
Retry-After: 60                    # integer seconds (RFC 7231)
Content-Type: application/json     # or application/xml — caller's format

{
  "error": "Rate limit exceeded",
  "message": "You have exceeded the rate limit of 100 requests per minute. Try again in 60 seconds."
}
```

Redmine's generic `render_error` emits `head @status` (no body) for API formats, so the
limiter ships a small dedicated `render_rate_limit_error` to produce the structured body
above. This deviation is deliberate and localized.

## 3. Configuring storage (flexibility axis #1)

One line in `config/application.rb`, mirroring Redmine's existing `redmine_search_cache_store`:

```ruby
config.redmine_api_rate_limit_cache_store = :memory_store   # default
```

The limiter uses only the **portable subset** of the `ActiveSupport::Cache` API
(`increment`, `read`, `write` with `expires_in`), so any Rails-supported store works with
zero code changes:

| Store | Topology | Notes |
|---|---|---|
| `:memory_store` | Single process | Per-process counters; fastest; **default** |
| `:file_store` | Single host, multi-process | Shared via filesystem; slower |
| `:mem_cache_store` | Multi-host | Shared; requires the `dalli` gem |
| `:redis_cache_store` | Multi-host, high volume | Shared; requires the `redis` gem |
| custom | anything | Any `ActiveSupport::Cache::Store` subclass |

Redmine's Gemfile ships **no** `redis`/`dalli` gem, so those backends require the operator
to add the gem — documented, not bundled, to avoid forcing a dependency on the core.

**Correctness depends on the store:** a single shared store (Redis/memcached) enforces one
true global limit; a per-process store (`:memory_store`) enforces the limit *per process*,
so the effective global limit becomes `limit × processes`. Multi-instance operators should
switch to a shared store.

**Bounded latency for shared stores:** configure explicit client timeouts so a *slow* (not
dead) backend costs a bounded per-request penalty before failing open, e.g.

```ruby
config.redmine_api_rate_limit_cache_store = ActiveSupport::Cache::RedisCacheStore.new(
  url: ENV['REDIS_URL'],
  connect_timeout: 0.2, read_timeout: 0.2, write_timeout: 0.2, reconnect_attempts: 0
)
```

## 4. Configuring the algorithm (flexibility axis #2)

Selected at runtime by `Setting.rest_api_rate_limit_algorithm`. Adding an algorithm = one
class conforming to `Strategy.consume(store:, key:, now:, **params) => Result` + one
registry entry; no controller changes.

| Algorithm | Boundary burst | Portable via cache API? | Status |
|---|---|---|---|
| **Fixed Window** | Yes (up to 2×) | ✅ atomic `increment` | **Shipped — default** |
| **Sliding Window Counter** | No (smoothed) | ✅ two counters + `increment` | **Shipped** |
| **Token Bucket** | No (absorbs organic bursts) | ⚠️ approximate (RMW race) | **Shipped, with caveat** |
| Sliding Window Log | No | ❌ needs a sorted set | Deferred (Redis-native) |
| Leaky Bucket | No (shapes) | ⚠️ RMW | Deferred |

**Fixed Window uses a rotating key** (the window index is part of the cache key; TTL is
only for GC). This gives *identical* reset semantics on `:memory_store`, `:file_store`, and
Redis despite each store treating `increment`+TTL differently — proven by a test
parameterized across memory and file stores. Invariant for every counter strategy:
**increment first, then compare** (never read-then-increment — that races even on an atomic
store).

**Token Bucket is approximate on shared stores.** It is a read-modify-write over the
generic cache API (read `{tokens, updated_at}` → refill → write), so under concurrency two
requests can read the same stale count and both pass. It is **exact on a single-process
`:memory_store`** and approximate elsewhere. The exact fix (Redis `WATCH`/`MULTI` or a Lua
script) can't be expressed through the generic cache API and is a named deferred extension.
Its unit tests assert steady-state behavior sequentially and deliberately do **not** assert
an exact ceiling under simulated concurrency.

### Parameters (all `Setting` rows — no migration)

| Setting | Default | Applies to |
|---|---|---|
| `rest_api_rate_limit_enabled` | `1` | all |
| `rest_api_rate_limit_algorithm` | `fixed_window` | selector |
| `rest_api_rate_limit_requests` | `100` | fixed / sliding-window (max requests) |
| `rest_api_rate_limit_window` | `60` | fixed / sliding-window (seconds) |
| `rest_api_rate_limit_burst` | `100` | token bucket (capacity) |
| `rest_api_rate_limit_refill_rate` | `1.67` | token bucket (tokens/sec ≈ 100/60) |

Unknown/blank algorithm falls back to `fixed_window`. Irrelevant parameters are ignored.
All are editable on **Administration → Settings → API**.

## 5. Availability & failover

The limiter sits in the hot path of every API request, so it must never turn a storage
outage into an application outage. **Enforcement is sacrificed before availability.**

**Layer 1 — fail-open (shipped).** Store failure behavior is not uniform, so both paths are
handled:
- `RedisCacheStore` has an internal `failsafe` that **rescues connection errors and returns
  `nil`** — strategies treat a `nil` counter as "allow".
- `:mem_cache_store` (Dalli) / custom stores may **raise** — the concern has a blanket
  `rescue` that instruments an `api_rate_limiter.error` notification and allows the request.

Pinned by a test: with the store stubbed to raise, the request returns `200` (not `500`)
and the notification fires.

**Layer 2 — `FailoverStore` circuit breaker (designed; not wired in this slice).** Because
every strategy takes the store as a parameter, failover is a **store decorator**, not a
strategy or controller change. `lib/redmine/api_rate_limiter/failover_store.rb` implements
the portable subset over a **primary** (e.g. Redis) and a **fallback** (`MemoryStore`)
behind a monotonic-clock circuit breaker (consecutive primary errors trip it → route to
fallback → cooldown half-opens to probe recovery → success closes it). It ships fully
implemented but unwired; the core already fails open, so availability does not depend on it.

Honest degradation semantics (why it is not simply "fully open"):
- failover from a **shared** store to a **per-process** fallback silently changes the
  guarantee from one global limit to `limit × processes`;
- the fallback starts at **zero**, so a burst is briefly allowed at the moment of failover;
- breaker state is shared across Puma threads and is mutex-guarded.

Degrading to a per-process ceiling is deliberately preferred over fully open (defense in
depth); breaker transitions are instrumented so a silent degradation is still alertable.

## 6. Why this design (vs. off-the-shelf)

| Option | Verdict |
|---|---|
| Rails 7.2 built-in `rate_limit` | Rejected — key embeds `controller_path` (per-controller buckets, no global API limit; `name:` only in Rails 8), single hard-coded algorithm, no pluggable storage. |
| `Rack::Attack` | Rejected for this slice — adds a gem, runs **pre-auth** so it can't key by authenticated user (Basic/OAuth callers collapse to IP), and its throttle model isn't a clean multi-algorithm surface. |
| **Custom facade + Strategy classes over a configurable cache store** | **Chosen** — zero new mandatory dependencies, exact post-auth identity, and the only option delivering both pluggability axes. |

## 7. Limits (accepted trade-offs)

1. **Counted post-auth.** An over-limit request still pays routing + the auth DB lookup.
   Consequence: an **anonymous flood keyed by IP still runs `find_current_user` (a DB
   lookup)** before the limiter can shed it — this is an abuse/fairness limiter for
   authenticated callers, **not** a DoS shield for the auth/DB layer. A cheap Rack-level IP
   throttle is the complementary front line and is deferred (§8).
2. **Store determines the guarantee** — shared store = one global limit; `:memory_store` =
   per-process limit.
3. **Fixed window (default) allows up to 2× across a boundary** — chosen for its minimal
   memory and portability; switch to sliding-window counter for smoothing.
4. **Token bucket is approximate** on shared stores without server-side atomicity.
5. **Fail-open** — a storage outage lets requests through rather than 500-ing.
6. **Anonymous keying trusts `request.remote_ip`** — behind a misconfigured proxy,
   `X-Forwarded-For` spoofing can rotate IPs to bypass the anon limit, or spoof a victim's
   IP to throttle them. The guarantee is only as good as Redmine's trusted-proxy config.

## 8. Deferred

- **Other #43881 pillars:** personal access tokens with expiration, scoped permissions,
  audit logging (the limiter `before_action` is a natural hook), granular endpoint control,
  CORS configuration.
- **Two more algorithms:** Sliding Window Log and Leaky Bucket (interface already fits).
- **Redis-native atomic (Lua) strategies** for an exact token bucket under concurrency.
- **`FailoverStore` wiring** (Layer 2 above — implemented, not wired).
- **A cheap Rack-level IP throttle** as a pre-auth front line for anonymous floods.

## 9. Run & verify

```bash
# clone the fork, check out the branch, off tag 6.1.2
bundle install
bin/rails db:migrate            # no new migrations — Setting rows only

# tests
bin/rails test \
  test/unit/lib/redmine/api_rate_limiter_test.rb \
  test/integration/api_test/rate_limit_test.rb

# manual demo (limiter on by default, 100/60s)
bin/rails s
KEY=<your api key>
for i in $(seq 1 105); do
  curl -s -o /dev/null -w "%{http_code} " \
       -H "X-Redmine-API-Key: $KEY" http://localhost:3000/projects.json
done; echo   # expect trailing 429s after request 100
```

Flip the algorithm to sliding window, or the store to Redis, without code changes:

```ruby
# console
Setting.rest_api_rate_limit_algorithm = 'sliding_window_counter'
# config/application.rb (needs the `redis` gem)
config.redmine_api_rate_limit_cache_store = :redis_cache_store
```

## 10. AI workflow

Built with Claude Code. The planning artifacts (feature spec, task decomposition,
implementation plan) and the prompts that produced them live under
`sdd_docs/issue-43881/` (mirrored into `docs/ai/`). Commits are made per task so the git
history doubles as a workflow record.
