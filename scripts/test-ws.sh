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
if out=$(cd "$ROOT/scripts/ws/tests" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m unittest discover -t . -p 'test_*.py' 2>&1); then
  printf 'PASS: ws: %s\n' "$(printf '%s\n' "$out" | sed -n 's/^Ran \([0-9]*\) tests\{0,1\} .*/\1 tests/p')"
else
  printf '%s\n' "$out" | grep -E -A12 '^(FAIL|ERROR):' | sed 's/^/  /'
  printf 'FAIL: ws: %s\n' "$(printf '%s\n' "$out" | grep -E '^FAILED' | tail -1)"
  exit 1
fi
