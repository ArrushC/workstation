#!/usr/bin/env bash
# lint-root.sh <live checkout>: print the tree `mise run lint` should check.
#
# mise finds the lint task in the live checkout (~/.config/mise) wherever it is run from, so a
# commit made in a worktree used to be checked against the live checkout's files. The tree to
# check is the one lint was started in (MISE_ORIGINAL_CWD; a commit hook starts at its top),
# when that is a checkout of this same repository carrying the check script. Anything else,
# another repository included, gets the live checkout: its script is never run from here.
set -u

live="$(cd "$1" && pwd -P)"
from="${MISE_ORIGINAL_CWD:-$PWD}"

common() { # the repository a directory belongs to (its shared .git), or nothing
  local d
  d="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  (cd "$d" 2>/dev/null && pwd -P)
}

top="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
  git -C "$from" rev-parse --show-toplevel 2>/dev/null)" || top=""
if [ -n "$top" ] && [ -x "$top/scripts/check-invariants.sh" ] &&
  mine="$(common "$live")" && theirs="$(common "$top")" && [ "$mine" = "$theirs" ]; then
  (cd "$top" && pwd -P)
else
  printf '%s\n' "$live"
fi
