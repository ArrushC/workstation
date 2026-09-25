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

echo "PASS: bootstrap.sh mode resolution (saved, WORKSTATION_MODE, prompt, no-terminal failure, config.local.toml writer)"
