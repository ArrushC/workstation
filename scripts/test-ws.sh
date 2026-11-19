#!/usr/bin/env bash
# test-ws.sh: scripts/ws's tests (reconcile's classification, templates, directory entries,
# backups and hooks; the palette's catalogue and dispatch; workspace identity and what
# `ws open` runs), on fixtures in scratch homes, plus one end-to-end run against the real
# mise when it is installed. Needs a Python with tomllib (3.11+); skipped without one.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY=""
for p in wpy python3; do
  if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import tomllib' 2>/dev/null; then
    PY="$p"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "no python with tomllib (3.11+): skipped (CI runs it)"
  exit 0
fi
# A commit hook runs this with git's own variables exported (the committer's identity, the index of
# the commit in progress). The tests' scratch repositories must not see them.
unset "${!GIT_@}"
# One test class per worker process (scripts/ws/tests/run_parallel.py): the classes share
# nothing, and in one process the suite takes over a minute. The PASS line carries the skip
# count and each reason gets a line above it, so a host (or CI runner) that lacks svn, bwrap,
# fzf or pueue shows what it didn't test.
if out=$(cd "$ROOT/scripts/ws/tests" && PYTHONDONTWRITEBYTECODE=1 "$PY" run_parallel.py 2>&1); then
  printf '%s\n' "$out" | grep -E '^skipped [0-9]+: ' | sed 's/^/  /'
  printf 'PASS: ws: %s\n' "$(printf '%s\n' "$out" | sed -n 's/^Ran \([0-9]* tests .*\)$/\1/p' | tail -1)"
else
  printf '%s\n' "$out" | grep -E -A12 '^(FAIL|ERROR):' | sed 's/^/  /'
  printf 'FAIL: ws: %s\n' "$(printf '%s\n' "$out" | grep -E '^FAILED' | tail -1)"
  exit 1
fi
