# Redmine — Pluggable API Rate Limiter (issue #43881)

This fork adds **API rate limiting** to Redmine — the required core of
[redmine.org #43881 — Strengthen API authentication](https://www.redmine.org/issues/43881).
Work lives on branch `feature/issue-43881-rate-limiter`, branched off tag `6.1.2`
(Rails 7.2.3). Over-limit API callers receive an HTTP `429` with `Retry-After` and
`X-RateLimit-*` headers.

## Documentation

Design and planning docs are under [`issue-43881/`](issue-43881/README.md):

| Document | What it covers |
| --- | --- |
| [README.md](issue-43881/README.md) | Index, one-paragraph context, and grounding facts verified against tag `6.1.2` — **start here** |
| [feature-specification.md](issue-43881/feature-specification.md) | Scope; the pluggability axes (storage backend + algorithm) and the availability axis (fail-open + failover); the 429 contract; trade-offs; deferred pillars |
| [implementation-plan.md](issue-43881/implementation-plan.md) | Architecture, files created/modified, key interfaces, fail-open + failover design, testing strategy, deliverable README outline |
| [task-decomposition.md](issue-43881/task-decomposition.md) | Task breakdown into a core tier and an extension tier, with time-boxing and cut lines |

➡️ **Full spec index: [`issue-43881/README.md`](issue-43881/README.md)**

## Upstream Redmine

For Redmine's own project documentation, see [README.rdoc](../README.rdoc).
