#!/usr/bin/env bash
# test-bump-lock-retry.sh — bump-versions.sh's lock_platform waits out a server error
# before it gives up on a pin. Runs the real function with a stand-in `mise lock`.
# run() sets variables that only the sourced lock_platform reads:
# shellcheck disable=SC2034
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
pass=0
fail=0

# The function, as written in the script.
sed -n '/^lock_platform() {$/,/^}$/p' "$ROOT/scripts/bump-versions.sh" >"$T/fn.sh"
[ -s "$T/fn.sh" ] || {
  echo "FAIL: lock_platform not found in scripts/bump-versions.sh"
  exit 1
}

SERVER='mise WARN  HTTP GET https://api.github.com/repos/o/r/releases attempt 3 failed after 11.05s (transient): HTTP status server error (504 Gateway Timeout) for url
mise ERROR failed to resolve codex@2.0.0 for linux-x64; refusing to replace locked version(s) 1.0.0 that support this platform'
REFUSED='mise ERROR failed to resolve codex@2.0.0 for linux-x64; refusing to replace locked version(s) 1.0.0 that support this platform'

# run <outcome>...: each `mise lock` call takes the next outcome (ok | server | refused);
# the last one repeats. Sets RC, CALLS, REVERTED, REFUSED_OUT.
run() {
  printf '%s\n' "$@" >"$T/plan"
  : >"$T/calls"
  : >"$T/reverted"
  (
    # shellcheck disable=SC2034  # read by lock_platform, sourced below
    NO_SLSA=""
    bumped='- `codex` (config.toml): 1.0.0 → 2.0.0\n'
    refused=""
    declare -A bump_file=(["codex"]=config.toml) bump_cur=(["codex"]=1.0.0) bump_new=(["codex"]=2.0.0)
    mise_global() {
      local n outcome
      echo x >>"$T/calls"
      n="$(wc -l <"$T/calls")"
      outcome="$(sed -n "${n}p" "$T/plan")"
      [ -n "$outcome" ] || outcome="$(tail -n1 "$T/plan")"
      case "$outcome" in
      ok) return 0 ;;
      server) printf '%s\n' "$SERVER" >&2 ;;
      refused) printf '%s\n' "$REFUSED" >&2 ;;
      esac
      return 1
    }
    set_pin() { echo "$2 $3 $4" >>"$T/reverted"; }
    # shellcheck disable=SC1091
    . "$T/fn.sh"
    BUMP_LOCK_RETRY_WAIT=0 lock_platform linux linux-x64 2>"$T/stderr"
    echo "$?" >"$T/rc"
    printf '%s' "$refused" >"$T/refused"
  )
  RC="$(cat "$T/rc")"
  CALLS="$(wc -l <"$T/calls")"
  REVERTED="$(cat "$T/reverted")"
  REFUSED_OUT="$(cat "$T/refused")"
}
check() { # check <name> <condition...>
  local name="$1"
  shift
  if "$@"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $name (rc=$RC calls=$CALLS reverted='$REVERTED' refused='$REFUSED_OUT')"
    sed 's/^/    /' "$T/stderr"
  fi
}

run server ok
check "one server error: waits, locks, keeps the pin" \
  test "$RC/$CALLS/$REVERTED" = "0/2/"

run server server ok
check "two server errors: still keeps the pin" \
  test "$RC/$CALLS/$REVERTED" = "0/3/"

run server server server ok
check "a third server error reverts the pin, then locks the rest" \
  test "$RC/$CALLS/$REVERTED" = "0/4/codex 2.0.0 1.0.0"
case "$REFUSED_OUT" in
*"server error"*"lock it by hand"*) pass=$((pass + 1)) ;;
*)
  fail=$((fail + 1))
  echo "FAIL: the summary names the server error: '$REFUSED_OUT'"
  ;;
esac

run refused ok
check "a real refusal reverts at once, without waiting" \
  test "$RC/$CALLS/$REVERTED" = "0/2/codex 2.0.0 1.0.0"
case "$REFUSED_OUT" in
*"refusing to replace"*"mise -v lock"*) pass=$((pass + 1)) ;;
*)
  fail=$((fail + 1))
  echo "FAIL: a real refusal keeps mise's reason: '$REFUSED_OUT'"
  ;;
esac

echo "test-bump-lock-retry: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
