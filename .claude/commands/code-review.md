---
description: Install-free, language-agnostic code review of a diff (uncommitted, staged, or vs the default branch).
argument-hint: "[working|staged|branch|<git-ref>]"
allowed-tools:
  - "Bash(git *)"
  - "Bash(sh *)"
  - "Read"
  - "Grep"
  - "Glob"
---

Perform a code review using the `code-review` skill. Requires no installation or
build — only git and reading files.

Scope: `$ARGUMENTS` (default: `working` = uncommitted changes). Valid values:
`working`, `staged`, `branch` (vs the default branch, PR-style), or an explicit
git ref.

Steps:
1. Collect the diff:
   `sh .claude/skills/code-review/scripts/collect-diff.sh $ARGUMENTS`
   If it reports no changes, say so and stop.
2. For each non-trivial file, read the surrounding code before judging a hunk.
3. Review against `.claude/skills/code-review/references/review-checklist.md`,
   weighting the categories that match the change.
4. Rank findings with `.claude/skills/code-review/references/severity-rubric.md`
   and report most-severe first. Each finding: **file:line**, the defect in one
   line, and a concrete failure scenario. Suggest fixes; don't edit files unless
   asked. If the diff is clean, say so plainly.
