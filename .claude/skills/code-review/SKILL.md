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

When a change alters a function or method's signature, return value/type,
nullability, units, thrown/rejected errors, or side effects, Grep for its call
sites and read the ones that still use the old contract — an unchanged caller
relying on it is a bug the diff introduced, not a pre-existing issue (see
severity-rubric.md's "materially worse" carve-out), and belongs in the review at
full severity. If the symbol is used pervasively (a core utility, a
widely-implemented interface), sample a representative few callers across
different modules rather than reading every occurrence — the goal is to catch the
realistic break, not to audit the whole codebase.

## 3. What to look for

Work through `references/review-checklist.md` — correctness, security, error
handling, concurrency, API/contract changes, tests, and maintainability. Focus
on the **changed lines and what they touch**; do not review the whole codebase.

Weight toward the categories that match the change: a SQL query → injection and
N+1; an auth path → access control; a parser → malformed input; a refactor →
behavior preservation; shared state or async code → races and unawaited work; a
webhook/retry/payment path → idempotency and double-processing; a delete or
migration → data loss and reversibility; a token/password/hash → crypto misuse.
The last four rarely look wrong in the hunk itself — check them deliberately
against how the code runs, not just by reading the diff.

## 4. Rank and report

Score each finding with `references/severity-rubric.md` and report most-severe
first. For every finding give: **file:line**, its **severity level** (from
`references/severity-rubric.md`: Critical / High / Medium / Low-Nit / Question),
a one-line statement of the defect, and a concrete failure scenario (input/state
→ wrong result). Prefer one solid example over a hand-wave. Only claim something
is a confirmed bug if you can name how it breaks. If you can't confirm it and it
has no behavioral impact, it's a nit. If you can't confirm it but it could be a
real security, data-loss, concurrency, or crash bug, raise it as a Question at
the severity it would carry if true — don't downgrade an unconfirmed suspicion to
a nit just because you can't fully prove it.

The converse also holds: don't assert a defect you cannot see. This applies to
**any** claim that depends on the behavior of referenced-but-unshown code — a
validator's internals, a type/interface definition, an imported symbol or file, or
a guard layer (route decorators, middleware, a shared auth wrapper). The primary
action is **READ, not downgrade**: if the referenced code exists in the repo,
Read/Grep it before asserting how it behaves — reading either confirms the defect
(assert at full severity) or refutes it (drop). Two concrete patterns that fail
this way:
- Claiming a validator rejects an omitted/`undefined` field — e.g. that a PATCH
  field just became required — without having read that validator. Read it first;
  it may treat the field as optional.
- Flagging an import, type, or file that is absent from a partial diff as a
  compile-time break without Grepping for it. It may exist unchanged outside the
  diff.
- For missing auth/IDOR: Grep for the guard layer — absence from the diff is not
  absence from the codebase. If you find the guard, drop the concern; if you
  searched and the route is genuinely unprotected, flag at full severity.

Only when the code is **genuinely absent AND not readable** do you fall back to
raising it as a Question, at the severity it would carry if true ("Is this route
covered by the auth middleware? If not, this is an IDOR — attacker passes another
customer's id and reads their orders") — not as a definite High. **Exception:**
where the defect follows from well-established language/runtime semantics — e.g. a
newly-added struct field defaulting to its zero value and thereby changing runtime
behavior at an unshown call site — you may assert it at full severity without
reading the external caller. Don't over-hedge that zero-value case into a Question;
the semantics are known, so it is a confirmed finding.

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
- **Binary files** (images, `.so`/`.jar`/`.wasm`, PDFs, other compiled assets)
  show in the stat as `Bin N -> M bytes` and in the diff as "Binary files ...
  differ" — their contents aren't in the diff and can't be line-reviewed. Don't
  pad the review with them. Do raise a finding only when a binary doesn't fit the
  change — e.g., an executable or shared library added in a docs- or config-only
  PR — which can be a supply-chain risk worth a manual/provenance check.
- **Whitespace-only and formatting-only hunks** rarely warrant a comment; don't
  pad the review with them.
- **Respect the diff's scope.** Pre-existing issues outside the changed lines
  are at most a brief aside, not the review.
- **No network, no install.** If a check would require fetching or installing
  something, reason about it statically instead.
