# API Rate Limiting (Redmine #43881, pillar 3)

A pluggable, configurable API rate limiter for Redmine. Over-limit API callers get
`HTTP 429 Too Many Requests`; every API response also carries `X-RateLimit-*` headers so
well-behaved clients can self-throttle before they are rejected.

This is **one pillar** of the six-part [#43881 — Strengthen API authentication](https://www.redmine.org/issues/43881)
ticket, shipped as a self-contained, tested slice. The other pillars are deferred (§9).

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

**Token Bucket is approximate under concurrency.** It is a read-modify-write over the
generic cache API (read `{tokens, updated_at}` → refill → write) with an unsynchronized gap
between the read and the write, so two requests can read the same stale count and both pass.
It is **exact only sequentially (a single-threaded caller)**; under a multi-threaded server
(e.g. Puma) it races even on a single-process `:memory_store`, and races further on a shared
store. The exact fix (Redis `WATCH`/`MULTI` or a Lua
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
   throttle is the complementary front line and is deferred (§9).
2. **Store determines the guarantee** — shared store = one global limit; `:memory_store` =
   per-process limit.
3. **Fixed window (default) allows up to 2× across a boundary** — chosen for its minimal
   memory and portability; switch to sliding-window counter for smoothing.
4. **Token bucket is approximate** on shared stores without server-side atomicity.
5. **Fail-open** — a storage outage lets requests through rather than 500-ing.
6. **Anonymous keying trusts `request.remote_ip`** — behind a misconfigured proxy,
   `X-Forwarded-For` spoofing can rotate IPs to bypass the anon limit, or spoof a victim's
   IP to throttle them. The guarantee is only as good as Redmine's trusted-proxy config.
7. **Only `format=xml|json` requests are limited.** `api_request?` keys off the request
   *format* (URL suffix `.json`/`.xml` or `?format=`), matching Redmine's existing API
   convention. A client that negotiates JSON purely via an `Accept: application/json`
   header on an extension-less path is served as API but is **not** rate-limited. Clients
   that hit the limiter should use the explicit `.json`/`.xml` suffix.
8. **Settings are range-clamped, not range-validated.** The `Setting` layer validates
   integer-ness but not range, so the facade clamps at read time (`window` floors at 1s to
   avoid a divide-by-zero; counts/rates floor at 0). A `requests` of `0` therefore blocks
   all API traffic by design rather than raising.

## 8. Assumptions

Defaults and scope decisions made for this slice (overridable — each is a `Setting` or a
one-line config change unless noted):

1. **Enabled by default** at 100 requests / 60 s. Core Redmine might ship it *off* for strict
   backward compatibility; "on" demonstrates the feature out of the box and is the safer
   posture for an API-hardening ticket. Flip `rest_api_rate_limit_enabled` to `0` to disable.
2. **`fixed_window` is the default algorithm** — lowest memory and portable across every
   store. Operators wanting boundary smoothing switch to `sliding_window_counter`.
3. **`:memory_store` is the default backend**, matching the single-process common case and
   the existing `redmine_search_cache_store` default. Multi-process/multi-host deployments
   are assumed to switch to a shared store (§3) for one true global limit.
4. **Per-user identity, IP for anonymous.** Redmine 6.1.2 has one API key per user, so a
   per-user key is the correct granularity until personal access tokens (a deferred pillar)
   exist; anonymous callers fall back to `request.remote_ip`.
5. **No schema migration.** All configuration lives in `Setting` key/value rows, so the slice
   installs with `db:migrate` as a no-op and no new tables.
6. **Counting happens post-auth**, inside `ApplicationController`, so identity is already
   resolved — accepting the trade-off in §7 (item 1) that it is not a pre-auth DoS shield.

## 9. Deferred

- **Other #43881 pillars:** personal access tokens with expiration, scoped permissions,
  audit logging (the limiter `before_action` is a natural hook), granular endpoint control,
  CORS configuration.
- **Two more algorithms:** Sliding Window Log and Leaky Bucket (interface already fits).
- **Redis-native atomic (Lua) strategies** for an exact token bucket under concurrency.
- **`FailoverStore` wiring** (Layer 2 above — implemented, not wired).
- **A cheap Rack-level IP throttle** as a pre-auth front line for anonymous floods.

## 10. Run & verify

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

### Testing each algorithm manually

The algorithm and its parameters are `Setting` rows, so you switch algorithms **live** — no
restart, no code change. Set them from **Administration → Settings → API**, or from the
console (`bin/rails runner "<line>"`). All three examples below use small limits so the 429
is easy to observe, and this shared setup:

```bash
KEY=<your api key>                       # My account -> API access key
URL=http://localhost:3000/projects.json

# reusable loop: fire N requests, print the status code of each
hammer () { for i in $(seq 1 "$1"); do
  curl -s -o /dev/null -w "req $i -> %{http_code}\n" -H "X-Redmine-API-Key: $KEY" "$URL"
done; }

# see the headers/body of a single (rejected) call
peek () { curl -s -D - -H "X-Redmine-API-Key: $KEY" "$URL" | \
  grep -iE "HTTP/|X-RateLimit|Retry-After|error|message"; }
```

Between runs, reset the counters: on `:memory_store` restart the server (or wait out the
window / refill); on Redis run `redis-cli -n <db> flushdb`.

#### 1. Fixed Window (default)

```bash
bin/rails runner "Setting.rest_api_rate_limit_enabled='1';
  Setting.rest_api_rate_limit_algorithm='fixed_window';
  Setting.rest_api_rate_limit_requests='5'; Setting.rest_api_rate_limit_window='60'"
```

```bash
hammer 7      # req 1-5 -> 200, req 6-7 -> 429
peek          # X-RateLimit-Limit: 5, Remaining: 0, Retry-After: <secs to window end>
              # "...rate limit of 5 requests per minute..."
```

Note the boundary behaviour: because the window is fixed, up to `2 × limit` can slip through
across a window edge (5 at the end of one window + 5 at the start of the next).

#### 2. Sliding Window Counter

```bash
bin/rails runner "Setting.rest_api_rate_limit_algorithm='sliding_window_counter';
  Setting.rest_api_rate_limit_requests='5'; Setting.rest_api_rate_limit_window='60'"
```

```bash
hammer 7      # req 1-5 -> 200, req 6-7 -> 429
```

Same limit as fixed window, but the previous window is weighted by how much of it still
overlaps the current one, so the boundary burst is smoothed — a caller that maxed out the
last window is rejected early in the next one instead of getting a fresh full allowance.

#### 3. Token Bucket

```bash
bin/rails runner "Setting.rest_api_rate_limit_algorithm='token_bucket';
  Setting.rest_api_rate_limit_burst='10'; Setting.rest_api_rate_limit_refill_rate='0.1667'"
# burst 10 = 10 immediate requests; refill 0.1667/s ~= 10 per minute
```

```bash
hammer 12     # req 1-10 -> 200 (the burst), req 11-12 -> 429
peek          # X-RateLimit-Limit: 10, Remaining: 0, Retry-After: ~6
              # "...rate limit of 10 requests per minute. Try again in 6 seconds."
sleep 6; hammer 1   # one token refilled -> 200 again
```

The bucket absorbs an organic burst (up to `burst`) then throttles to the sustained
`refill_rate`. Note the documented caveat: token bucket is **exact only sequentially** and
**approximate under concurrency** — even single-process on a multi-threaded server (§4).

> Postman: import any curl above via **Import → Raw text**, then use the **Collection Runner**
> (set *Iterations* to e.g. 12) to fire it repeatedly and watch the 200 → 429 transition and
> the `X-RateLimit-*` headers count down.

### Using Redis storage (and inspecting the counters)

The default `:memory_store` keeps counters per process. Point the limiter at **Redis** to get
a single shared limit across all processes/hosts — and to watch the counters directly.

**1. Add the gem** (Redis is operator-added, not bundled with core Redmine):

```ruby
# Gemfile
gem "redis", "~> 5.0"
# ActiveSupport 7.2's RedisCacheStore uses the connection_pool 2.x API; pin it
# if bundler resolves 3.x (whose ConnectionPool.new signature is incompatible).
gem "connection_pool", "~> 2.5"
```

```bash
bundle install
```

**2. Point the store at Redis** — in `config/application.rb` (the documented axis), or a small
initializer for a local/demo override. A DB index keeps the counters isolated from other data:

```ruby
# config/initializers/rate_limit_redis.rb  (or the config line in application.rb)
Rails.application.config.redmine_api_rate_limit_cache_store =
  ActiveSupport::Cache::RedisCacheStore.new(
    url: "redis://localhost:6379/0",         # /0 = default DB most GUIs show; use /15 to isolate
    connect_timeout: 0.2, read_timeout: 0.2, write_timeout: 0.2, reconnect_attempts: 0
  )
```

Restart the server. Counters now live in Redis; a Redis outage still **fails open** (§5).

**3. Inspect the counters** while hitting the API. The limiter namespaces every key under
`rl:` and the shape encodes the algorithm (`<caller>` is `user:<id>` or `ip:<addr>`):

| Algorithm | Redis key(s) | Value |
|---|---|---|
| `fixed_window` | `rl:fw:<caller>:<window-index>` | integer count |
| `sliding_window_counter` | `rl:swc:<caller>:<window-index>` (current + previous) | integer counts |
| `token_bucket` | `rl:tb:<caller>` | serialized `{tokens, updated_at}` |

```bash
KEY=<your api key>
DB=0                      # match the DB in the URL above
RCLI="redis-cli -n $DB"   # or: docker exec <redis-container> redis-cli -n $DB

# generate traffic (token bucket, burst 10)
for i in $(seq 1 12); do
  curl -s -o /dev/null -w "%{http_code} " -H "X-Redmine-API-Key: $KEY" \
       http://localhost:3000/projects.json
done; echo            # 200 x10 then 429

$RCLI keys 'rl:*'         # list the limiter's keys
$RCLI get  rl:tb:user:1   # inspect the bucket (tb = a Ruby-marshalled hash; fw/swc = plain ints)
$RCLI ttl  rl:tb:user:1   # remaining TTL (idle keys are GC'd)
$RCLI del  rl:tb:user:1   # reset this caller's bucket
```

Switch algorithms and re-run to watch `rl:fw:*` / `rl:swc:*` counters increment instead. On a
shared Redis this count is the single global limit — the correctness upgrade over per-process
memory counters (§3).

## 11. AI workflow

Built with Claude Code. The planning artifacts (feature spec, task decomposition,
implementation plan) and the prompts that produced them live under
`sdd_docs/issue-43881/` (mirrored into `docs/ai/`). Commits are made per task so the git
history doubles as a workflow record.
