---
name: code-review
description: >-
  Review a code diff for correctness, security, and maintainability with zero
  setup — no npm/pnpm/pip install, no build, no project dependencies. Works in
  any language or repository using only git and file reads. Use when the user
  asks to review code, review a diff or PR, check staged/uncommitted changes,
  "look over my changes", or wants feedback before committing or merging.
allowed-tools:
  - "Bash(git *)"
  - "Bash(sh *)"
  - "Read"
  - "Grep"
  - "Glob"
---

# Code Review (install-free, universal)

Review a set of changes and report findings ranked by severity. The goal is a
**high-signal review**: real defects a maintainer would want fixed, plus a few
worthwhile cleanups — not a lint dump and not vague praise.

This skill relies on **nothing but `git` and reading files**. Do not run
`npm install`, `pnpm install`, `pip install`, `bundle`, `cargo build`, or any
setup step. If a project's own linters/tests happen to be already installed you
may use them, but never require them — the review must work in a fresh clone.

## 1. Gather the diff

Pick the scope from what the user asked for. When unsure, review the current
uncommitted work. Use the helper to collect a diff portably:

```sh
sh .claude/skills/code-review/scripts/collect-diff.sh          # uncommitted (default)
sh .claude/skills/code-review/scripts/collect-diff.sh staged   # staged only
sh .claude/skills/code-review/scripts/collect-diff.sh branch   # vs default branch (PR-style)
sh .claude/skills/code-review/scripts/collect-diff.sh <ref>    # vs an explicit git ref
```

The script prints the changed files and a unified diff. If it reports no
changes, tell the user and stop — there is nothing to review.

## 2. Understand before judging

Read the diff, then **open the surrounding code** for any file with non-trivial
changes. A hunk in isolation hides its callers, its invariants, and whether an
edge case is handled elsewhere. Most false-positive review comments come from
judging a hunk without reading the function it lives in.

## 3. What to look for

Work through `references/review-checklist.md` — correctness, security, error
handling, concurrency, API/contract changes, tests, and maintainability. Focus
on the **changed lines and what they touch**; do not review the whole codebase.

Weight toward the categories that match the change: a SQL query → injection and
N+1; an auth path → access control; a parser → malformed input; a refactor →
behavior preservation.

## 4. Rank and report

Score each finding with `references/severity-rubric.md` and report most-severe
first. For every finding give: **file:line**, a one-line statement of the
defect, and a concrete failure scenario (input/state → wrong result). Prefer
one solid example over a hand-wave. Only claim something is a bug if you can
name how it breaks; otherwise mark it as a question or a nit.

Suggest fixes, but do not edit files unless the user asked you to apply changes.

Keep it honest: if the change is clean, say so plainly and stop. A short review
of a good diff is a success, not a failure.

## Gotchas

- **Don't railroad on green tests.** "Tests pass" is not "correct" — the tests
  may not cover the changed path. Reason about the code directly.
- **Deleted/renamed files** show as large diffs; confirm intent before flagging
  "missing code" — it may have simply moved.
- **Generated / vendored / lockfiles** (`dist/`, `*.min.js`, `package-lock.json`,
  `go.sum`, `vendor/`) are noise. Note them, don't line-review them.
- **Whitespace-only and formatting-only hunks** rarely warrant a comment; don't
  pad the review with them.
- **Respect the diff's scope.** Pre-existing issues outside the changed lines
  are at most a brief aside, not the review.
- **No network, no install.** If a check would require fetching or installing
  something, reason about it statically instead.
