# Spec — Redmine #43881: Strengthen API Authentication (Rate-Limiting Slice)

Planning documents for the TaxDome technical challenge based on the open Redmine ticket
[#43881 — Strengthen API authentication](https://www.redmine.org/issues/43881).
The challenge brief is according to tech task.

## Documents

| Document | Contents |
| --- | --- |
| [feature-specification.md](feature-specification.md) | Scope; the two pluggability axes (configurable **storage backend** + configurable **algorithm**) with per-algorithm parameters; the **availability axis** (§2.1: fail-open + `FailoverStore` failover); strategy choice; trade-offs; deferred pillars |
| [task-decomposition.md](task-decomposition.md) | Task breakdown split into a **~2.5h core** (incl. the resilience floor) and an **extension tier**, with time allocations and cut lines |
| [implementation-plan.md](implementation-plan.md) | Technical plan: architecture, files created/modified, key interfaces, storage config, **fail-open + failover design (§3b)**, **rotating-key fixed window (§3c)**, testing strategy, verification, deliverable README outline |

## Enabling & configuring the rate limiter

Full reference: [`README_RATE_LIMITING.md`](../../README_RATE_LIMITING.md) at the repo root.
Quick guide below.

### Enable / disable

The limiter is **enabled by default** (100 requests / 60 s, fixed window, per-process
memory store). Toggle it from **Administration → Settings → API**, or from the console:

```ruby
Setting.rest_api_rate_limit_enabled = '1'   # '0' to disable
```

When disabled the `before_action` short-circuits and no `X-RateLimit-*` headers are emitted.

### Configure the algorithm & parameters

All are `Setting` rows (no migration) — editable on the **Settings → API** tab or console:

| Setting | Default | Applies to |
| --- | --- | --- |
| `rest_api_rate_limit_enabled` | `1` | all |
| `rest_api_rate_limit_algorithm` | `fixed_window` | selector (`fixed_window`, `sliding_window_counter`, `token_bucket`) |
| `rest_api_rate_limit_requests` | `100` | fixed / sliding-window — max requests |
| `rest_api_rate_limit_window` | `60` | fixed / sliding-window — window seconds |
| `rest_api_rate_limit_burst` | `100` | token bucket — capacity |
| `rest_api_rate_limit_refill_rate` | `1.67` | token bucket — tokens/sec |

Unknown/blank algorithm falls back to `fixed_window`; irrelevant parameters are ignored.

```ruby
Setting.rest_api_rate_limit_algorithm = 'sliding_window_counter'
Setting.rest_api_rate_limit_requests  = '200'
Setting.rest_api_rate_limit_window    = '60'
```

### Configure storage (the flexibility axis)

One line in `config/application.rb`, mirroring the existing `redmine_search_cache_store`:

```ruby
config.redmine_api_rate_limit_cache_store = :memory_store   # default
```

| Store | Topology | Notes |
| --- | --- | --- |
| `:memory_store` | Single process | Per-process counters; fastest; **default** |
| `:file_store` | Single host, multi-process | Shared via filesystem; slower |
| `:mem_cache_store` | Multi-host | Shared; add the `dalli` gem |
| `:redis_cache_store` | Multi-host, high volume | Shared; add the `redis` gem |
| custom | anything | Any `ActiveSupport::Cache::Store` subclass |

**Correctness depends on the store:** a single shared store (Redis/memcached) enforces one
global limit; a per-process store enforces the limit *per process*, so the effective global
limit is `limit × processes`. Multi-instance deployments should use a shared store. Redis /
memcached require the operator to add the gem (documented, not bundled).

### Availability options

The limiter is in the hot path of every API request, so **enforcement is sacrificed before
availability** — a storage fault degrades to *allow*, never to a 500.

1. **Fail-open (always on).** Any storage error — a raised exception *or* a `nil` return
   (e.g. `RedisCacheStore`'s internal `failsafe`) — allows the request, fires an
   `api_rate_limiter.error` notification, and logs it. Nothing to configure.
2. **Bounded latency for shared stores.** Give the store explicit client timeouts so a
   *slow* (not dead) backend costs a bounded per-request penalty before failing open:

   ```ruby
   config.redmine_api_rate_limit_cache_store = ActiveSupport::Cache::RedisCacheStore.new(
     url: ENV['REDIS_URL'],
     connect_timeout: 0.2, read_timeout: 0.2, write_timeout: 0.2, reconnect_attempts: 0
   )
   ```
3. **`FailoverStore` circuit breaker (implemented, opt-in / not wired by default).** Wrap the
   store to degrade a failed shared primary to a per-process fallback and auto-recover:

   ```ruby
   Redmine::ApiRateLimiter.store = Redmine::ApiRateLimiter::FailoverStore.new(
     primary:  ActiveSupport::Cache.lookup_store(config.redmine_api_rate_limit_cache_store),
     fallback: ActiveSupport::Cache::MemoryStore.new(size: 32.megabytes)
   )
   ```

   Honest degradation: shared→per-process failover changes the guarantee to `limit ×
   processes`, the fallback starts at zero (a brief burst is allowed at failover), and
   breaker transitions are instrumented (`api_rate_limiter.circuit_open`) so the degradation
   is alertable.

### Verify

```bash
bin/rails s
KEY=<your api key>
for i in $(seq 1 105); do
  curl -s -o /dev/null -w "%{http_code} " \
       -H "X-Redmine-API-Key: $KEY" http://localhost:3000/projects.json
done; echo   # expect trailing 429s after request 100
```

## AI workflow — prompts

The prompts used to produce these docs are saved under [`prompts/`](prompts/) as AI-workflow
artifacts:

| Prompt | Used for |
| --- | --- |
| [prompts/1. spec-generate.md](prompts/1.%20spec-generate.md) | Generating the spec/plan/decomposition — the `[DOCS ONLY]` prompt with the full challenge requirements and grounding constraints |
| [prompts/2. docs-review-prompts.md](prompts/2.%20docs-review-prompts.md) | The Principal-Architect review pass over the spec (flexibility + availability / graceful-degradation focus) that drove the fail-open + failover revisions |
| [prompts/3. code-review.md](prompts/3.%20code-review.md) | The post-implementation deep code review (correctness, architecture, SOLID/DRY, security/resilience, tests, docs) whose findings were then fixed — settings clamping, DRY/naming cleanups, `FailoverStore` tests, extra integration coverage, and doc-accuracy fixes |

## Context in one paragraph

Redmine #43881 asks for six API-security improvements: personal access tokens with
expiration, scoped permissions, **rate limiting**, audit logging, granular endpoint
control, and CORS configuration. The challenge requires shipping only the rate-limiting
pillar as a working slice (over-limit callers get HTTP 429), branched off Redmine tag
`6.1.2`, in roughly two hours, with AI-workflow artifacts and a README defending the
design.

## Grounding facts (verified against the `6.1.2` tag)

- Redmine 6.1.2 runs **Rails 7.2.3** (`Gemfile`).
- API requests are identified by `api_request?` — `params[:format]` is `xml` or `json`
  (`app/controllers/application_controller.rb`).
- Authentication resolves in `find_current_user`: API key via `params[:key]` /
  `X-Redmine-API-Key` header, HTTP Basic, or OAuth (Doorkeeper).
- Settings are key/value rows managed through `config/settings.yml`; an
  **Administration → Settings → API** tab already exists (`app/views/settings/_api.html.erb`).
- Redmine already ships a **dedicated, operator-swappable cache store** precedent:
  `config.redmine_search_cache_store` (`config/application.rb:84-90`), documented to point
  at a shared store for multi-process deploys — the exact idiom mirrored for the
  configurable rate-limit storage backend.
- Store failure behavior is **not uniform**: `ActiveSupport::Cache::RedisCacheStore` wraps
  operations in an internal `failsafe` that rescues connection errors and returns `nil`
  (does not raise); Dalli/`:mem_cache_store` and custom stores may raise. Both `increment`
  TTL semantics and failure modes differ per store — hence the fail-open handling (plan
  §3b) and rotating-key fixed window (plan §3c).
- The Gemfile ships **no** `redis`/`dalli` gem, so Redis/memcached backends require the
  operator to add the gem (documented, not bundled).
- An API integration test suite exists under `test/integration/api_test/`
  (Minitest, `Redmine::ApiTest::Base`).
- The fork `AKarpetc/redmine` carries no tags; tag `6.1.2` must be fetched from
  upstream `redmine/redmine` (already done in the local clone).

## Status

- [x] Plan drafted (these documents)
- [x] Plan approved
- [x] Implementation complete (rate-limiting core: 3 algorithms, fail-open, 429 contract, admin UI)
- [x] Tests passing (48 tests — 13 integration + 35 unit, incl. `FailoverStore` coverage)
- [x] Code review complete and findings addressed (prompt 3; see commit history)
