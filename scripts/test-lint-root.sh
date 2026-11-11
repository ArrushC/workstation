#!/usr/bin/env bash
# test-lint-root.sh: which checkout `mise run lint` (and so the pre-commit hook) checks.
# mise finds the lint task in the live checkout (~/.config/mise) wherever it is run from, so
# tasks/lint asks scripts/lib/lint-root.sh for the tree to check: a worktree of this repository
# when run from one, the live checkout otherwise.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/lint-root.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
unset "${!GIT_@}"
pass=0
fail=0

case_() { # name, want, got
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"
  fi
}

repo() { # dir: a repository with a check script
  git init -q "$1"
  mkdir -p "$1/scripts"
  printf '#!/bin/sh\n' >"$1/scripts/check-invariants.sh"
  chmod +x "$1/scripts/check-invariants.sh"
  git -C "$1" -c user.name=t -c user.email=t@example.invalid add -A
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m seed
}

live="$T/live"
repo "$live"
git -C "$live" worktree add -q "$T/wt" -b work
git -C "$live" worktree add -q "$T/bare-wt" -b bare
rm "$T/bare-wt/scripts/check-invariants.sh"
repo "$T/other"
mkdir -p "$T/wt/scripts/deep" "$T/plain"

from() { MISE_ORIGINAL_CWD="$1" bash "$LIB" "$live"; }

case_ "the live checkout checks itself" "$live" "$(from "$live")"
case_ "a worktree checks itself" "$T/wt" "$(from "$T/wt")"
case_ "from a subdirectory of a worktree" "$T/wt" "$(from "$T/wt/scripts/deep")"
case_ "another repository is never run" "$live" "$(from "$T/other")"
case_ "outside any repository" "$live" "$(from "$T/plain")"
case_ "a worktree without the check script" "$live" "$(from "$T/bare-wt")"
case_ "no directory given" "$live" "$(cd "$T/plain" && env -u MISE_ORIGINAL_CWD bash "$LIB" "$live")"
# what git exports to a commit hook run in the worktree
gd="$(git -C "$T/wt" rev-parse --absolute-git-dir)"
case_ "inside a commit hook in a worktree" "$T/wt" \
  "$(GIT_DIR="$gd" GIT_INDEX_FILE="$gd/index" MISE_ORIGINAL_CWD="$T/wt" bash "$LIB" "$live")"
case_ "a commit hook in the live checkout" "$live" \
  "$(GIT_DIR="$live/.git" GIT_INDEX_FILE="$live/.git/index" MISE_ORIGINAL_CWD="$live" bash "$LIB" "$live")"

if [ "$fail" -eq 0 ]; then
  printf 'all %d lint-root cases passed\n' "$pass"
  exit 0
fi
printf '%d of %d lint-root cases failed\n' "$fail" "$((pass + fail))"
exit 1
