#!/usr/bin/env bash
# test-check-pins.sh — check_pins passes on this repo's files and fails on each kind of drift.
# Each case runs `check-invariants.sh --only check_pins` against a temp copy of the files it reads.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
files=(bootstrap.sh bootstrap.ps1 config.toml config.linux.toml config.owned.toml
  dotfiles/zshrc.tera dotfiles/bashrc.tera tasks/vcpkg tasks/check-updates
  scripts/bump-versions.sh scripts/gen-tool-memory.sh scripts/check-invariants.sh)
pass=0
fail=0

fresh() {
  [ -n "${T:-}" ] && rm -rf "$T"
  T="$(mktemp -d)"
  local f
  for f in "${files[@]}"; do
    mkdir -p "$T/$(dirname "$f")"
    cp -p "$ROOT/$f" "$T/$f"
  done
}
pins() {
  OUT="$(env "$@" bash "$T/scripts/check-invariants.sh" --only check_pins 2>&1)"
  RC=$?
}
case_() { # case_ <name> <want-rc> [grep-pattern]
  local name="$1" want="$2" pat="${3:-}"
  if [ "$RC" -eq "$want" ] && { [ -z "$pat" ] || printf '%s' "$OUT" | grep -qF -- "$pat"; }; then
    printf '  \033[0;32mPASS\033[0m %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  \033[0;31mFAIL\033[0m %s (rc=%s)\n%s\n' "$name" "$RC" "$OUT" | sed '2,$s/^/      /'
    fail=$((fail + 1))
  fi
}

fresh
pins
case_ "unchanged repo passes" 0 "mise @"
case_ "unchanged repo: VCPKG_ROOT row" 0 "VCPKG_ROOT @"

fresh
sed -i -E 's/^(MISE_VERSION=")[0-9.]+/\10.0.1/' "$T/bootstrap.sh"
pins
case_ "bootstrap.sh MISE_VERSION drift fails" 1 "mise drift"

fresh
sed -i -E 's/^\$MiseVersion( *=)/$MiseVer\1/' "$T/bootstrap.ps1"
pins
case_ "pattern stops matching (empty value) fails" 1 "mise drift"

fresh
sed -i -E 's#(VCPKG_ROOT=")[^"]*#\1/opt/vcpkg#' "$T/dotfiles/bashrc.tera"
pins
case_ "bashrc VCPKG_ROOT drift fails" 1 "VCPKG_ROOT drift"

fresh
sed -i -E 's/^zellij = "[0-9.]+"/zellij = "0.1.0"/' "$T/config.linux.toml"
pins
case_ "zellij below the zjstatus floor fails" 1 "zellij for zjstatus"

fresh
sed -i -E 's/typescript@[0-9.]+/typescript@7.0.0/' "$T/config.owned.toml"
pins
case_ "typescript major 7 fails" 1 "typescript"

fresh
sed -i -E 's/^(COUPLED_AUTO=".*) node"/\1"/' "$T/scripts/bump-versions.sh"
pins
case_ "node missing from COUPLED_AUTO fails" 1 "node"

fresh
sed -i '/^\[vars\]/a foo_version = "1.0"' "$T/config.toml"
pins
case_ "uncovered [vars] *_version pin fails" 1 "foo_version"

fresh
sed -i -E 's#(VCPKG_ROOT=")[^"]*#\1/opt/vcpkg#' "$T/dotfiles/bashrc.tera"
pins CHECK_INVARIANTS_NO_PY=1
case_ "no python: non-TOML rows still fail on drift" 1 "VCPKG_ROOT drift"

fresh
pins CHECK_INVARIANTS_NO_PY=1
case_ "no python: clean repo passes with a skip note" 0 "skipped"

fresh
OUT="$(bash "$T/scripts/check-invariants.sh" --only check_nope 2>&1)"
RC=$?
case_ "--only with an unknown check exits 2" 2 "unknown check"

rm -rf "$T"
echo
if [ "$fail" -eq 0 ]; then
  printf '\033[0;32m✓ all %d check_pins cases passed\033[0m\n' "$pass"
  exit 0
fi
printf '\033[0;31m✗ %d/%d check_pins cases failed\033[0m\n' "$fail" "$((pass + fail))"
exit 1
