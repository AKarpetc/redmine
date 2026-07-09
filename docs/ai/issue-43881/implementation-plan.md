# Implementation Plan — Pluggable API Rate Limiting

Branch: `feature/43881-api-rate-limiting`, off tag `6.1.2` (Rails 7.2.3).

## 1. Architecture at a glance

```
ApplicationController
  └─ include ApiRateLimitable            # concern: before_action, key building, 429 render,
        │                                #          FAIL-OPEN rescue (§3b)
        └─ Redmine::ApiRateLimiter       # facade: reads Settings, resolves store + strategy
              ├─ .store                  # <- config.redmine_api_rate_limit_cache_store
              │      (optionally wrapped by FailoverStore — §3b Layer 2, deferred)
              ├─ registry {algo => class}
              └─ Strategies::
                   ├─ Base               # interface + shared cache-key helpers (nil-safe)
                   ├─ FixedWindow        # default, portable (rotating-key window, §3c)
                   ├─ SlidingWindowCounter (ext)  portable
                   └─ TokenBucket         (ext)   portable-approx
              returns Result(allowed?, retry_after, remaining, limit)
```

Availability is a first layer of the concern, not an afterthought: the `before_action`
never lets a storage fault escape as a 500 (§3b), and the store may be transparently
wrapped by a circuit-breaking `FailoverStore` without any strategy change.

Two axes are independent: **storage** is `Redmine::ApiRateLimiter.store`;
**algorithm** is the class chosen from the registry by setting. Strategies receive the
store, so any strategy runs on any store (subject to the §Feature-spec-3 caveats).

## 2. Files

| File | Action | Purpose |
|---|---|---|
| `lib/redmine/api_rate_limiter.rb` | **create** | Facade: `.check(key)`, `.store`, `.strategy_for`, registry; reads Settings |
| `lib/redmine/api_rate_limiter/result.rb` | **create** | Value object: `allowed?`, `limit`, `remaining`, `reset_at`, `retry_after`, `window_label`, `to_headers`; `allowed`/`disabled`/rejected constructors |
| `lib/redmine/api_rate_limiter/strategies/base.rb` | **create** | Interface + `cache_key` helper |
| `lib/redmine/api_rate_limiter/strategies/fixed_window.rb` | **create** | Default algorithm |
| `lib/redmine/api_rate_limiter/strategies/sliding_window_counter.rb` | **create** (ext) | Smooths boundary burst |
| `lib/redmine/api_rate_limiter/strategies/token_bucket.rb` | **create** (ext) | Handles organic bursts; **read-modify-write, approximate under concurrency** (see §Token bucket) |
| `lib/redmine/api_rate_limiter/failover_store.rb` | **document** (ext, §3b Layer 2) | Circuit-breaking primary→fallback decorator over the portable cache subset; design specified, not built in the slice |
| `app/controllers/concerns/api_rate_limitable.rb` | **create** | `before_action`, key building, `Result#to_headers` (2xx + 429), **dedicated `render_rate_limit_error`** (structured body, §3d), **fail-open `rescue`** (§3b), `skip_rate_limit` exemption hook |
| `test/unit/lib/redmine/api_rate_limiter_test.rb` | **create** | Facade + strategy unit tests |
| `test/integration/api_test/rate_limit_test.rb` | **create** | End-to-end 429 behavior |
| `README_RATE_LIMITING.md` | **create** | Deliverable README (avoids clobbering `README.rdoc`) |
| `docs/ai/` | **create** | AI-workflow artifacts |
| `config/application.rb` | modify | Add `config.redmine_api_rate_limit_cache_store = :memory_store` |
| `app/controllers/application_controller.rb` | modify | `include ApiRateLimitable` **after** `user_setup` before_action |
| `config/settings.yml` | modify | 6 settings (§Feature-spec-4) w/ `security_notifications: 1` |
| `config/locales/en.yml` | modify | `setting_rest_api_rate_limit_*` labels + algorithm option labels + `error_api_rate_limit_short` / `error_api_rate_limit_exceeded` (parameterized message, §3d) |
| `app/views/settings/_api.html.erb` | modify (ext) | Toggle + algorithm select + param fields |

**No migrations** — `Setting` rows only; "clone, install, migrate, verify" works stock.

## 3. Key interfaces

### Facade
```ruby
module Redmine
  module ApiRateLimiter
    mattr_accessor :store            # defaults to configured store at boot; injectable in tests
    REGISTRY = { "fixed_window" => Strategies::FixedWindow, ... }

    def self.check(key)
      return Result.disabled unless Setting.rest_api_rate_limit_enabled?
      strategy_for(Setting.rest_api_rate_limit_algorithm)
        .consume(store: store, key: key, **params, now: Time.current)
    end
    # Note: `Result.disabled` carries nil `limit` so the concern emits no
    # `X-RateLimit-*` headers when the limiter is off. Strategies treat a nil
    # counter (RedisCacheStore failsafe) as an allowed Result (§3b).
    # `Time.current` (not `Time.now`) keeps parity with Redmine + test time travel.
  end
end
```

### Strategy (all algorithms conform)
```ruby
# returns Redmine::ApiRateLimiter::Result
def self.consume(store:, key:, limit:, window:, now:, **opts); end
```

### Concern
```ruby
module ApiRateLimitable
  extend ActiveSupport::Concern
  included { before_action :check_api_rate_limit, if: :rate_limit_applicable? }

  class_methods do
    # opt a controller/action out of limiting (health checks, monitoring)
    def skip_rate_limit(**opts) = skip_before_action(:check_api_rate_limit, **opts)
  end

  private

  def rate_limit_applicable? = api_request?

  def check_api_rate_limit
    key    = rate_limit_key
    result = Redmine::ApiRateLimiter.check(key)
    result.to_headers.each { |h, v| response.headers[h] = v }  # allowed AND denied
    return if result.allowed?
    render_rate_limit_error(result)         # §3d: structured body, 429
  rescue => e
    # FAIL OPEN (§3b): availability > enforcement. Never turn a storage fault into a 500.
    ActiveSupport::Notifications.instrument("api_rate_limiter.error", error: e)
    Rails.logger.error("[api_rate_limiter] failing open: #{e.class}: #{e.message}")
    true                                    # allow the request
  end

  def rate_limit_key
    User.current.logged? ? "user:#{User.current.id}" : "ip:#{request.remote_ip}"
  end

  # §3d — dedicated 429 renderer: the exact contract in feature-spec §1.1,
  # in the caller's format. Deliberately NOT render_error (whose {"errors":[…]}
  # envelope differs); headers already set above survive because we only render a body.
  def render_rate_limit_error(result)
    message = l(:error_api_rate_limit_exceeded,
                limit: result.limit, window: result.window_label,
                retry_after: result.retry_after)
    body = { error: l(:error_api_rate_limit_short), message: message }
    respond_to do |format|
      format.json { render json: body, status: 429 }
      format.xml  { render xml:  body, root: "error", status: 429 }
      format.any  { render json: body, status: 429 }
    end
  end
end
```

`Result#to_headers` returns `{}` when the limiter is disabled (nil `limit`), the full
`X-RateLimit-*` set on allowed responses, and additionally `Retry-After` on denials — so
the header logic lives in one place and every algorithm gets identical output.

## 3a. Token bucket: read-modify-write (RMW) approximation

Fixed Window and Sliding Window Counter enforce exactly because they only ever call the
store's **atomic** `increment` — count-only, no gap. Token Bucket cannot: each request
must (1) **read** the bucket `{tokens, updated_at}`, (2) **modify** it in Ruby (refill by
elapsed time, subtract 1), (3) **write** it back. Those are three separate cache calls
with no lock across the gap, so two concurrent requests on a shared store can both read
the same stale token count and both be allowed — a lost-update **race** that lets a few
requests slip past the limit under load.

Implications encoded in the build:

- `token_bucket.rb` implements the plain RMW form (`store.read` → compute →
  `store.write` with `expires_in`). It is **exact on a single-process `:memory_store`**
  (no concurrency) and **approximate on shared stores** under contention.
- The **exact** fix (atomic server-side RMW via Redis `WATCH`/`MULTI` or a Lua script) is
  **out of this slice** — it can't be expressed through the generic
  `ActiveSupport::Cache` API and belongs in a future Redis-native strategy.
- **Test constraint:** token-bucket unit tests assert steady-state behavior
  (refill/consume/`retry_after`) **sequentially**; they do **not** assert an exact ceiling
  under simulated concurrency, since the approximation is expected there. This limitation
  is called out in the README's "Limits" section, not hidden.

## 3b. Availability: fail-open (core) + FailoverStore (documented extension)

The limiter runs on every API request, so a storage fault must degrade to *allow*, never
to a 500. Two layers.

### Layer 1 — fail-open (ships in the core)

Store failure behavior is **not uniform**, so both paths are handled:

- `RedisCacheStore` wraps ops in an internal `failsafe` that **rescues connection errors
  and returns `nil`** — it does not raise. Strategies therefore treat a `nil` counter as
  "allow" (`Base` normalizes `nil → allowed Result`), or they would `NoMethodError` on
  `nil` and 500.
- `:mem_cache_store` (Dalli) / custom stores may **raise** — so the concern's
  `check_api_rate_limit` also has a blanket `rescue` (shown in §3) that instruments and
  allows.

Pinned by a test (§5): with a store stubbed to raise, the request returns `200`, not
`500`, and an `api_rate_limiter.error` notification fires.

### Layer 1b — bounded latency

A *slow* (not dead) shared store must not hang every request. Redis/memcached stores are
configured with explicit client timeouts at boot, e.g.

```ruby
ActiveSupport::Cache::RedisCacheStore.new(
  url: ..., connect_timeout: 0.2, read_timeout: 0.2, write_timeout: 0.2,
  reconnect_attempts: 0
)
```

so a degraded backend costs a bounded per-request penalty and then fails open, rather than
blocking on a dead socket. (`Timeout.timeout` around the client is intentionally **not**
used — it can corrupt the connection; client-level timeouts + the breaker below are the
correct tools.)

### Layer 2 — FailoverStore circuit breaker (design specified; deferred, not built in slice)

Because every strategy takes the store as a parameter, **failover is a store decorator, not
a strategy or controller concern** — the strategies are unchanged. `FailoverStore`
implements the same portable subset (`increment`, `read`, `write`) over a **primary**
(e.g. Redis) and a **fallback** (`MemoryStore`) behind a circuit breaker:

```ruby
# lib/redmine/api_rate_limiter/failover_store.rb  (design — deferred)
class Redmine::ApiRateLimiter::FailoverStore
  def initialize(primary:, fallback:, error_threshold: 5, cooldown: 30)
    @primary, @fallback = primary, fallback
    @error_threshold, @cooldown = error_threshold, cooldown
    @mutex = Mutex.new                 # Puma is multi-threaded: breaker state must be safe
    @failures = 0
    @open_until = nil                  # nil = closed; set = tripped-open deadline
  end

  %i[increment read write].each do |op|
    define_method(op) do |*args, **kw|
      store = choose_store             # closed → primary; open → fallback; cooldown → half-open probe
      begin
        result = store.public_send(op, *args, **kw)
        record_success if store.equal?(@primary)
        result
      rescue => e
        if store.equal?(@primary)
          record_failure                # trip after error_threshold
          @fallback.public_send(op, *args, **kw)   # degrade THIS call too
        else
          raise                         # fallback (MemoryStore) failing is unexpected → let fail-open catch it
        end
      end
    end
  end

  private

  def choose_store
    @mutex.synchronize do
      return @primary if @open_until.nil?
      if monotonic >= @open_until then @open_until = nil; @primary  # half-open probe
      else @fallback end                                            # still open → shed
    end
  end

  def record_failure
    @mutex.synchronize do
      @failures += 1
      if @failures >= @error_threshold
        @open_until = monotonic + @cooldown
        ActiveSupport::Notifications.instrument("api_rate_limiter.circuit_open")
      end
    end
  end

  def record_success
    @mutex.synchronize { @failures = 0; @open_until = nil }
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)   # NTP-safe
end
```

Wired at boot (deferred):

```ruby
Redmine::ApiRateLimiter.store = Redmine::ApiRateLimiter::FailoverStore.new(
  primary:  ActiveSupport::Cache.lookup_store(config.redmine_api_rate_limit_cache_store),
  fallback: ActiveSupport::Cache::MemoryStore.new(size: 32.megabytes)
)
```

**Honest degradation semantics (documented in the README):** failover from a *shared*
store to a *per-process* fallback silently changes the guarantee from one global limit to
`limit × processes`; the fallback starts at zero (a burst is briefly allowed at the moment
of failover); primary/fallback counts diverge until recovery. Degrading to a local limit
is deliberately preferred over "fully open" — it keeps a per-process ceiling during the
outage (defense in depth). Breaker transitions are instrumented so a silent degradation is
still an alertable event.

## 3c. Fixed Window: rotating key (portability fix)

The naive "`increment(key, expires_in: window)` and reset via TTL" is **not portable** —
`MemoryStore#increment` rewrites the entry with `expires_in` on *every* call, sliding the
TTL forward, so a continuously-active caller's window **never resets**; `RedisCacheStore`
sets the TTL only when absent, so it *does* reset. Identical code → different semantics,
and the **default** store (`:memory_store`) gets the wrong, more-punishing one.

Fix: put the window boundary in the **key**, not the TTL, and use TTL only as garbage
collection:

```ruby
bucket = now.to_i / window                       # integer window index
ckey   = "rl:fw:#{key}:#{bucket}"
count  = store.increment(ckey, 1, expires_in: window * 2)  # increment-FIRST (atomic)
# count.nil? → store failed open → allow; else deny when count > limit
```

This yields identical semantics on `:memory_store`, `:file_store`, and Redis, and is
verified by the multi-store test (§5, no longer first on the cut list). **Invariant for
all counter strategies: increment first, then compare** — never read-then-increment (that
would race even on an atomic store).

## 3d. 429 response contract (algorithm-independent)

The exact wire contract is fixed in feature-spec §1.1; the header *values* per algorithm
are in feature-spec §3.1. Two mechanics pin it here:

**`Result#to_headers`** is the single source of header truth (used on 2xx and 429):

```ruby
def to_headers
  return {} if limit.nil?                       # disabled → emit nothing
  h = { "X-RateLimit-Limit"     => limit.to_s,
        "X-RateLimit-Remaining" => remaining.to_s,
        "X-RateLimit-Reset"     => reset_at.to_i.to_s }
  h["Retry-After"] = retry_after.to_s unless allowed?
  h
end
```

**Body** — the structured JSON/XML from §1.1, via the dedicated `render_rate_limit_error`
(concern §3), not `render_error`. Locale strings (`config/locales/en.yml`):

```yaml
error_api_rate_limit_short: "Rate limit exceeded"
error_api_rate_limit_exceeded: >-
  You have exceeded the rate limit of %{limit} requests per %{window}.
  Try again in %{retry_after} seconds.
```

`Result#window_label` renders the human window ("minute" for 60 s, else "%{n} seconds") so
the message reads naturally across algorithms; token bucket phrases it as "%{limit}
requests" using `burst` as the ceiling. Pinned by tests (§5): a 429 body parses in both
formats and contains `error` + `message`; the four headers match the `Result`.

## 4. Storage configuration (the flexibility axis)

Boot resolves the store from `config.redmine_api_rate_limit_cache_store` — same idiom and
same "switch to a shared store for multiple processes" guidance as the existing
`redmine_search_cache_store`. Operators change one line; Redis/memcached also require
adding the `redis`/`dalli` gem (documented in README, not bundled).

## 5. Testing strategy

**Coverage mandate: every piece of logic we add is covered by tests.** No branch ships
untested. Concretely, that means each of the following has at least one assertion:

- **Facade** (`Redmine::ApiRateLimiter`): enabled vs. disabled short-circuit; store
  resolution from config; algorithm selection from `Setting`; **unknown/blank algorithm
  falls back to `fixed_window`**; parameter reading from `Setting`.
- **Each shipped strategy** (`FixedWindow`, `SlidingWindowCounter`, `TokenBucket`):
  under-limit allow, at-limit boundary, over-limit deny, window/refill reset, and the
  **header-value derivation of feature-spec §3.1** — `limit` / `remaining` (0 at reject) /
  `reset_at` (epoch s) / `retry_after` (positive integer) on the returned `Result`;
  **`nil` counter (store-failed) → allowed `Result`** (fail-open at the strategy layer).
- **`Result`** value object: `allowed?`, the `allowed` / `disabled` / rejected
  constructors (`disabled` carries nil `limit`), and **`to_headers`** ({} when disabled,
  full set on allow, `+Retry-After` on reject).
- **Concern** (`ApiRateLimitable`): key building (`user:<id>` vs `ip:<remote_ip>`), the
  `if: :rate_limit_applicable?` guard (HTML exempt), the `skip_rate_limit` exemption hook,
  the 429 render path, and **header survival** — `X-RateLimit-*` / `Retry-After` set
  before `render_error` are present on the final response.
- **Fail-open** (§3b Layer 1): with the store stubbed to **raise**, the request returns
  `200` (not `500`) and an `api_rate_limiter.error` notification fires; with the store
  returning **`nil`** (RedisCacheStore failsafe simulation), the request is allowed.
- **Every accepted trade-off is pinned by a test** so it is a documented behavior, not an
  accident: fixed-window boundary burst, disabled flag, per-caller isolation, HTML
  exemption. The one exception is stated explicitly (token-bucket exact ceiling under
  concurrency — see §3a), so the coverage gap is deliberate and visible, not silent.

Mechanics: Minitest. `Redmine::ApiRateLimiter.store` is injected with a fresh
`MemoryStore` in setup (test env is `:null_store`, which cannot count). Limits stubbed low
(e.g. 3/60). Time-dependent cases use travel/short windows for determinism (no `sleep`).

**Integration** (`Redmine::ApiTest::Base`):

| # | Case | Assertion |
|---|---|---|
| 1 | Under limit | all `200` |
| 2 | Over limit | `429` + `Retry-After` + `X-RateLimit-Limit/Remaining(=0)/Reset`; body parses in caller's format with `error` + `message` (§3d) |
| 3 | Two users | isolated buckets |
| 4 | Anonymous | keyed by IP |
| 5 | `enabled = 0` | never 429, no `X-RateLimit-*` headers |
| 6 | HTML request | never throttled |
| 7 | Window reset | counter clears after window |
| 8 | Store raises | request returns `200` (fail-open), not `500` |
| 9 | Under-limit headers | `X-RateLimit-Limit/Remaining/Reset` present on a `200` |
| 10 | Exempt action (`skip_rate_limit`) | never throttled even over limit |

**Unit** (per strategy): monotonic counting, reset semantics, `retry_after` correctness;
FixedWindow in core, SlidingWindowCounter/TokenBucket with their tiers. TokenBucket is
tested **sequentially only** — no exact-ceiling-under-concurrency assertion (see §3a).

**Multi-store portability (no longer optional).** Because the rotating-key fixed window
(§3c) exists specifically to paper over `increment`+TTL divergence between stores, the
FixedWindow test is **parameterized across `:memory_store` and `:file_store`** to prove
identical reset semantics. This asserts the load-bearing portability claim rather than
assuming it, and is why the multi-store test is **removed from the cut list**.

Run: `bin/rails test test/unit/lib/redmine/api_rate_limiter_test.rb test/integration/api_test/rate_limit_test.rb`

## 6. Manual verification (for README)

```bash
bin/rails s
for i in $(seq 1 105); do
  curl -s -o /dev/null -w "%{http_code} " \
       -H "X-Redmine-API-Key: $KEY" http://localhost:3000/projects.json
done; echo   # expect trailing 429s after request 100
```

## 7. Deliverable README outline

1. **What this is** — pillar 3 of #43881: a pluggable, configurable rate limiter.
2. **How it works** — post-auth per-caller counting; configurable store × algorithm;
   429 + `Retry-After`/`X-RateLimit-*`.
3. **Configuring storage** — `config.redmine_api_rate_limit_cache_store`; table of
   store→topology; Redis/memcached gem note + client timeouts; single-vs-shared-store
   correctness.
4. **Configuring the algorithm** — settings; the five algorithms, three shipped;
   storage×algorithm interaction.
5. **Availability & failover** — fail-open policy (storage fault → allow, never 500);
   bounded latency via client timeouts; the `FailoverStore` circuit-breaker design
   (deferred) with its honest degradation semantics (shared→per-process guarantee change,
   zero-start fallback burst, thread-safety, instrumentation).
6. **Why this design** — off-the-shelf rejection (built-in `rate_limit`, Rack::Attack)
   and why pluggability forced a custom abstraction.
7. **Limits** — post-auth cost + **anonymous floods still hit the auth DB** (not a DoS
   shield; Rack-level IP throttle is the deferred front line); per-process vs shared
   store; fixed-window boundary burst; token-bucket approximation; **IP keying trusts
   trusted-proxy config** (X-Forwarded-For spoofing risk).
8. **Deferred** — remaining pillars + two deferred algorithms + `FailoverStore` +
   Rack-level IP throttle, each with the hook it leaves behind.
9. **Run & verify** — clone/branch/bundle/migrate, test command, curl demo, how to flip
   store to Redis and algorithm to sliding-window.
10. **AI workflow** — tools (Claude Code), transcripts in `docs/ai/`, commit narrative.
