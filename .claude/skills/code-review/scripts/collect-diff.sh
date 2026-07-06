#!/bin/sh
# collect-diff.sh — portable, install-free diff collector for code review.
# Depends only on git + POSIX sh. No node, python, or project tooling required.
#
# Usage:
#   sh collect-diff.sh            # uncommitted changes (working tree + staged), default
#   sh collect-diff.sh staged     # staged changes only
#   sh collect-diff.sh branch     # this branch vs the default branch (PR-style)
#   sh collect-diff.sh <ref>      # changes vs an explicit git ref (e.g. main, HEAD~3, a tag)
#
# Output: a header, the list of changed files with stats, then the unified diff.

set -eu

mode="${1:-working}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: not inside a git repository" >&2
  exit 1
fi

# Resolve the repository's default branch (origin/HEAD), falling back sensibly.
default_branch() {
  ref="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$ref" ]; then
    echo "${ref#refs/remotes/origin/}"
    return
  fi
  for b in main master trunk develop; do
    if git show-ref --verify --quiet "refs/remotes/origin/$b" 2>/dev/null; then
      echo "$b"; return
    fi
    if git show-ref --verify --quiet "refs/heads/$b" 2>/dev/null; then
      echo "$b"; return
    fi
  done
  echo "main"
}

# Base to diff against for working/staged. Normally HEAD, but a repo with no
# commits yet (unborn HEAD) has no HEAD — fall back to the empty tree so new
# files still show up as additions instead of erroring out.
head_base="HEAD"
if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  head_base="$(git hash-object -t tree /dev/null)"   # empty-tree object id
fi

case "$mode" in
  working)
    label="uncommitted changes (working tree + staged)"
    diff_args="$head_base"
    ;;
  staged|cached)
    label="staged changes"
    diff_args="--cached $head_base"
    ;;
  branch|pr)
    db="$(default_branch)"
    base="origin/$db"
    git rev-parse --verify --quiet "$base" >/dev/null 2>&1 || base="$db"
    mb="$(git merge-base "$base" HEAD 2>/dev/null || echo "$base")"
    label="branch vs $base (merge-base: $(git rev-parse --short "$mb" 2>/dev/null || echo "$mb"))"
    diff_args="$mb"
    ;;
  *)
    # Treat the argument as an explicit git ref.
    if ! git rev-parse --verify --quiet "$mode" >/dev/null 2>&1; then
      echo "error: '$mode' is not a valid git ref or known mode" >&2
      echo "modes: working (default) | staged | branch | <git-ref>" >&2
      exit 1
    fi
    label="changes vs $mode"
    diff_args="$mode"
    ;;
esac

echo "=== Code review scope: $label ==="
echo
echo "--- Changed files ---"
# shellcheck disable=SC2086
git diff --stat $diff_args
echo
echo "--- Unified diff ---"
# shellcheck disable=SC2086
git diff $diff_args

# Surface untracked files in working-tree mode so new code isn't silently missed.
if [ "$mode" = "working" ]; then
  untracked="$(git ls-files --others --exclude-standard)"
  if [ -n "$untracked" ]; then
    echo
    echo "--- Untracked (new) files, not in the diff above — review these too ---"
    echo "$untracked"
  fi
fi
