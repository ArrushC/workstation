#!/usr/bin/env bash
# Offline tests for bootstrap.sh's mode resolution: saved mode, WORKSTATION_MODE,
# the prompt (fd 3), and the no-terminal failure. Sources bootstrap.sh with
# WORKSTATION_BOOTSTRAP_LIB=1 so main does not run.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() {
  printf 'FAIL: %s\n' "$*"
  exit 1
}

# run <case-dir> <stdin-for-fd3|-> [VAR=value ...] — resolve_host_config in a
# fresh shell with REPO_DIR=<case-dir>; prints MODE on success. "-" means no
# fd 3 is supplied (and setsid removes the controlling terminal).
run() {
  local dir=$1 input=$2
  shift 2
  if [ "$input" = - ]; then
    env "$@" WORKSTATION_BOOTSTRAP_LIB=1 REPO_DIR_OVERRIDE="$dir" setsid -w bash -c \
      'source "$0"; REPO_DIR=$REPO_DIR_OVERRIDE; resolve_host_config; echo "MODE=$MODE"' "$root/bootstrap.sh" </dev/null 2>&1
  else
    env "$@" WORKSTATION_BOOTSTRAP_LIB=1 REPO_DIR_OVERRIDE="$dir" setsid -w bash -c \
      'source "$0"; REPO_DIR=$REPO_DIR_OVERRIDE; resolve_host_config; echo "MODE=$MODE"' "$root/bootstrap.sh" 3<<<"$input" </dev/null 2>&1
  fi
}

# 1. A saved mode wins over WORKSTATION_MODE.
mkdir -p "$T/c1"
printf '[vars]\nname = "N"\nemail = "e@x"\nmode = "shared"\n' >"$T/c1/config.local.toml"
out=$(run "$T/c1" - WORKSTATION_MODE=owned) || fail "saved mode: exit $? — $out"
grep -q '^MODE=shared$' <<<"$out" || fail "saved mode did not win: $out"

# 2. WORKSTATION_MODE is used and saved (name/email from fd 3).
mkdir -p "$T/c2"
out=$(run "$T/c2" $'Ann\nann@x' WORKSTATION_MODE=owned) || fail "env mode: exit — $out"
grep -q '^MODE=owned$' <<<"$out" || fail "env mode not used: $out"
grep -q '^mode = "owned"$' "$T/c2/config.local.toml" || fail "env mode not saved"
grep -q '^name = "Ann"$' "$T/c2/config.local.toml" || fail "name not saved"

# 3. An invalid WORKSTATION_MODE is rejected.
mkdir -p "$T/c3"
if out=$(run "$T/c3" - WORKSTATION_MODE=prod); then fail "invalid env accepted: $out"; fi
grep -q 'expected owned or shared' <<<"$out" || fail "invalid env message: $out"

# 4. No saved mode, no variable, no terminal -> fails with both ways to answer.
mkdir -p "$T/c4"
if out=$(run "$T/c4" -); then fail "no-terminal case succeeded: $out"; fi
grep -q 'No terminal to ask the setup mode on' <<<"$out" || fail "no-terminal message: $out"
grep -q 'WORKSTATION_MODE=shared' <<<"$out" || fail "no-terminal hint: $out"

# 5. A prompt answer is saved; an invalid answer re-asks.
mkdir -p "$T/c5"
out=$(run "$T/c5" $'x\n2\nBea\nbea@x') || fail "prompt: exit — $out"
grep -q '^MODE=shared$' <<<"$out" || fail "prompt answer not used: $out"
grep -q 'Please answer 1 or 2' <<<"$out" || fail "invalid answer not re-asked: $out"
grep -q '^mode = "shared"$' "$T/c5/config.local.toml" || fail "prompt answer not saved"

# 6. config_set keeps other tables and escapes quotes; config_get reads back.
mkdir -p "$T/c6"
printf '[vars]\nname = "Old"\n\n[dotfiles]\n"~/.x" = { source = "x", mode = "copy", enabled = false }\n' >"$T/c6/config.local.toml"
WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$0"; config_set "$1" name "Q \"q\""; config_set "$1" mode owned; config_get "$1" name' \
  "$root/bootstrap.sh" "$T/c6/config.local.toml" >"$T/c6/got" || fail "config_set/get failed"
grep -q '^\[dotfiles\]$' "$T/c6/config.local.toml" || fail "config_set dropped [dotfiles]"
grep -q '^mode = "owned"$' "$T/c6/config.local.toml" || fail "config_set did not add mode"
[ "$(grep -c '^name = ' "$T/c6/config.local.toml")" = 1 ] || fail "config_set duplicated name"
grep -qF 'name = "Q \"q\""' "$T/c6/config.local.toml" || fail "config_set did not escape quotes"

# 7. No terminal but WORKSTATION_MODE set and no identity: mode saved, warning only.
mkdir -p "$T/c7"
out=$(run "$T/c7" - WORKSTATION_MODE=shared) || fail "unattended shared failed: $out"
grep -q '^mode = "shared"$' "$T/c7/config.local.toml" || fail "unattended mode not saved"
grep -q 'name/email' <<<"$out" || fail "missing identity warning: $out"

# 8. Under a REAL pty (fd 3 NOT pre-opened, so open_prompt_fd has to exec
# 3</dev/tty itself), the prompt menu and a later stderr write must both
# still be visible. Regression test for the Critical bug where a bare
# `exec 3</dev/tty 2>/dev/null` (no command word) redirects fd 2 to
# /dev/null PERMANENTLY the moment /dev/tty opens, silencing every later
# message (including a later `fail`) for the rest of the run.
if command -v script >/dev/null 2>&1; then
  mkdir -p "$T/c8"
  inner="env WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source \"$root/bootstrap.sh\"; REPO_DIR=\"$T/c8\"; resolve_host_config; echo probe >&2'"
  out=$(printf '2\nA\na@x\n' | timeout 15 script -qec "$inner" /dev/null 2>&1) || true
  grep -q 'Is this host yours?' <<<"$out" || fail "pty: prompt menu missing (stderr clobbered?): $out"
  grep -q 'probe' <<<"$out" || fail "pty: stderr write after the prompt missing (stderr clobbered): $out"
  grep -q '^mode = "shared"$' "$T/c8/config.local.toml" || fail "pty: prompt answer not saved"
else
  echo "SKIP: pty regression case (no 'script' binary on PATH)"
fi

# 9. A [vars] header with a trailing space and a CRLF line ending is still
# recognized: config_set must not append a duplicate [vars] table, and the
# existing value must still be readable.
mkdir -p "$T/c9"
printf '[vars] \r\nname = "Old"\r\n' >"$T/c9/config.local.toml"
WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$0"; config_set "$1" mode owned; config_get "$1" name' \
  "$root/bootstrap.sh" "$T/c9/config.local.toml" >"$T/c9/got" || fail "CRLF header: config_set/get failed"
[ "$(grep -c '^\[vars\]' "$T/c9/config.local.toml")" = 1 ] || fail "CRLF header: duplicate [vars] table"
grep -q '^mode = "owned"$' "$T/c9/config.local.toml" || fail "CRLF header: mode not added"
grep -qx 'Old' "$T/c9/got" || fail "CRLF header: config_get did not read back the existing value"

# 10. confirm_reinstall reads the --reinstall confirmation from fd 3, not
# plain stdin (which under curl | bash is the piped script itself, so a
# plain `read` there hits EOF and set -e used to exit silently — the bug
# this guards against). YES=true bypasses the prompt entirely; "n" aborts;
# "y" proceeds; with no fd 3 and no terminal it fails with the --yes hint.
confirm() { # confirm <stdin-for-fd3|-> -> EXIT=0|1 (or the fail() message)
  local input=$1
  if [ "$input" = - ]; then
    env WORKSTATION_BOOTSTRAP_LIB=1 setsid -w bash -c \
      'source "$0"; YES=false; if confirm_reinstall; then echo EXIT=0; else echo EXIT=$?; fi' \
      "$root/bootstrap.sh" </dev/null 2>&1
  else
    env WORKSTATION_BOOTSTRAP_LIB=1 setsid -w bash -c \
      'source "$0"; YES=false; if confirm_reinstall; then echo EXIT=0; else echo EXIT=$?; fi' \
      "$root/bootstrap.sh" 3<<<"$input" </dev/null 2>&1
  fi
}

out=$(env WORKSTATION_BOOTSTRAP_LIB=1 setsid -w bash -c \
  'source "$0"; YES=true; if confirm_reinstall; then echo EXIT=0; else echo EXIT=$?; fi' \
  "$root/bootstrap.sh" </dev/null 2>&1) || fail "confirm YES=true: exit $? — $out"
grep -q 'EXIT=0$' <<<"$out" || fail "YES=true did not bypass the prompt: $out"

out=$(confirm n) || fail "confirm n: exit $? — $out"
grep -q 'EXIT=1$' <<<"$out" || fail "'n' did not abort: $out"

out=$(confirm y) || fail "confirm y: exit $? — $out"
grep -q 'EXIT=0$' <<<"$out" || fail "'y' did not proceed: $out"

if out=$(confirm -); then fail "no-terminal reinstall confirm succeeded: $out"; fi
grep -q 'Re-run with --yes' <<<"$out" || fail "no-terminal reinstall confirm missing --yes hint: $out"

echo "PASS: bootstrap.sh mode resolution (saved, WORKSTATION_MODE, prompt, no-terminal failure, pty stderr safety, CRLF header, config.local.toml writer, --reinstall confirmation)"
