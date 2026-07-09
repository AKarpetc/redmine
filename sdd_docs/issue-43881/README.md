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

## AI workflow — prompts

The prompts used to produce these docs are saved under [`prompts/`](prompts/) as AI-workflow
artifacts:

| Prompt | Used for |
| --- | --- |
| [prompts/1. spec-generate.md](prompts/1.%20spec-generate.md) | Generating the spec/plan/decomposition — the `[DOCS ONLY]` prompt with the full challenge requirements and grounding constraints |
| [prompts/2. docs-review-prompts.md](prompts/2.%20docs-review-prompts.md) | The Principal-Architect review pass over the spec (flexibility + availability / graceful-degradation focus) that drove the fail-open + failover revisions |

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
- [ ] Plan approved
- [ ] Implementation started
