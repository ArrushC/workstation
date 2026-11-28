#!/usr/bin/env bash
# test-bump-lock-retry.sh — bump-versions.sh's lock_platform waits out a server error
# before it gives up on a pin, and drop_incomplete_bumps puts back a pin whose new release
# lacks a platform the lock had. Runs the real functions with a stand-in `mise lock`.
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

# A release without one platform's build: note_locked and drop_incomplete_bumps, as written,
# against lock files in a scratch directory.
sed -n '/^lock_has() {$/,/^}$/p; /^note_locked() {$/,/^}$/p; /^drop_incomplete_bumps() {$/,/^}$/p' \
  "$ROOT/scripts/bump-versions.sh" >"$T/drop.sh"
grep -q '^drop_incomplete_bumps() {$' "$T/drop.sh" || {
  echo "FAIL: drop_incomplete_bumps not found in scripts/bump-versions.sh"
  exit 1
}
# entry <tool> <platform>...: a lock block as mise writes it (the name quoted).
entry() {
  local tool="$1" plat
  shift
  printf '[[tools."%s"]]\nversion = "x"\n' "$tool"
  for plat in "$@"; do printf '[tools."%s"."platforms.%s"]\nurl = "u"\n' "$tool" "$plat"; done
}
# drop <after: platforms the new lock has for github:o/tool>: before the lock it had both;
# bat (a bare key) keeps both; linuxonly never had Windows. Sets RC, REVERTED, REFUSED_OUT, LEFT.
drop() {
  mkdir -p "$T/d" && : >"$T/reverted"
  (
    cd "$T/d" || exit 1
    bumped='- `github:o/tool` (config.toml): 1.0.0 → 2.0.0\n- `bat` (config.toml): 1 → 2\n'
    refused=""
    failed=""
    declare -A had relock
    declare -A bump_file=(["github:o/tool"]=config.toml ["bat"]=config.toml ["linuxonly"]=config.linux.toml)
    declare -A bump_cur=(["github:o/tool"]=1.0.0 ["bat"]=1 ["linuxonly"]=1)
    declare -A bump_new=(["github:o/tool"]=2.0.0 ["bat"]=2 ["linuxonly"]=2)
    set_pin() { echo "$2 $3 $4" >>"$T/reverted"; }
    # shellcheck disable=SC1091
    . "$T/drop.sh"
    {
      entry github:o/tool linux-x64 windows-x64
      printf '[[tools.bat]]\n[tools.bat."platforms.linux-x64"]\n[tools.bat."platforms.windows-x64"]\n'
    } >mise.lock
    entry linuxonly linux-x64 >mise.linux.lock
    note_locked
    {
      # shellcheck disable=SC2086  # the platforms, as words
      entry github:o/tool "$@"
      printf '[[tools.bat]]\n[tools.bat."platforms.linux-x64"]\n[tools.bat."platforms.windows-x64"]\n'
    } >mise.lock
    drop_incomplete_bumps 2>"$T/stderr"
    echo "$?" >"$T/rc"
    printf '%s' "$refused" >"$T/refused"
    printf '%s|%s|%s' "$bumped" "${!bump_cur[*]}" "${!relock[*]}" >"$T/left"
  )
  RC="$(cat "$T/rc")"
  CALLS=0
  REVERTED="$(cat "$T/reverted")"
  REFUSED_OUT="$(cat "$T/refused")"
  LEFT="$(cat "$T/left")"
}

drop linux-x64 windows-x64
check "a release with every platform: nothing reverted" \
  test "$RC/$REVERTED/$REFUSED_OUT" = "1//"

drop linux-x64
check "a release without the Windows build: its pin goes back, and the caller locks again" \
  test "$RC/$REVERTED" = "0/github:o/tool 2.0.0 1.0.0"
case "$REFUSED_OUT" in
*'`github:o/tool`: 1.0.0 → 2.0.0'*"no windows-x64 build"*) pass=$((pass + 1)) ;;
*)
  fail=$((fail + 1))
  echo "FAIL: the summary names the missing platform: '$REFUSED_OUT'"
  ;;
esac
case "$LEFT" in
'- `bat` (config.toml): 1 → 2\n|'*'|github:o/tool')
  case "${LEFT#*|}" in
  *github:o/tool*'|'*) fail=$((fail + 1)) && echo "FAIL: the reverted tool is still counted as bumped: '$LEFT'" ;;
  *) pass=$((pass + 1)) ;;
  esac
  ;;
*)
  fail=$((fail + 1))
  echo "FAIL: only the incomplete bump leaves the summary, and it is marked to lock alone: '$LEFT'"
  ;;
esac

echo "test-bump-lock-retry: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
