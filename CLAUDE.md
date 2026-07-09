# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Installed skills

This project ships two Ruby on Rails skills under [.claude/skills/](.claude/skills/):

- **rails-code-architect** — [.claude/skills/rails-code-architect/SKILL.md](.claude/skills/rails-code-architect/SKILL.md)
  Architects idiomatic, maintainable Rails code (Evil Martians / Layered Rails style):
  thin controllers, domain-driven naming, database integrity, and the modern stack
  (Hotwire, ViewComponent, ActionPolicy).

- **rails-debugger** — [.claude/skills/rails-debugger/SKILL.md](.claude/skills/rails-debugger/SKILL.md)
  Systematic root-cause debugging for Rails: exceptions, failing specs, N+1 queries,
  ActiveRecord issues, and performance problems.

## When to use these skills

**Use `rails-code-architect`** whenever writing or refactoring Rails code — models,
controllers, routes, migrations, jobs, or views — and when making architectural or
"where should this logic live?" decisions. Follow its conventions for any new Rails code.

**Use `rails-debugger`** whenever investigating a bug: a Rails error/stack trace, a
failing or flaky test, a slow endpoint, an N+1 query, or any unexpected behavior.
Follow its 4-phase process (reproduce → isolate → understand → fix & verify) instead of
patching symptoms.

Invoke a skill explicitly with `/rails-code-architect` or `/rails-debugger`, or let it
activate automatically when the task matches its description above.
