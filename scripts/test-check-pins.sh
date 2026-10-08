#!/usr/bin/env bash
# test-check-pins.sh — check_pins passes on this repo's files and fails on each kind of drift.
# Each case runs `check-invariants.sh --only check_pins` against a temp copy of the files it reads.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
files=(bootstrap.sh bootstrap.ps1 config.toml config.linux.toml
  dotfiles/zshrc.tera dotfiles/bashrc.tera tasks/vcpkg tasks/check-updates
  scripts/bump-versions.sh scripts/gen-tool-memory.sh scripts/check-invariants.sh
  .github/workflows/lint.yml .github/workflows/version-bumps.yml)
pass=0
fail=0
T=""

fresh() {
  [ -n "$T" ] && rm -rf "$T"
  T="$(mktemp -d)" || exit 1
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
sed -i -E 's/^([[:space:]]*version:[[:space:]]*)[0-9.]+/\10.0.1/' "$T/.github/workflows/version-bumps.yml"
pins
case_ "a workflow's mise-action version drift fails" 1 "mise drift"

fresh
sed -i -E '/^[[:space:]]*version:[[:space:]]*[0-9.]+/d' "$T/.github/workflows/lint.yml"
pins
case_ "a mise-action step without a version fails" 1 "mise drift"

fresh
sed -i -E 's#(VCPKG_ROOT=")[^"]*#\1/opt/vcpkg#' "$T/dotfiles/bashrc.tera"
pins
case_ "bashrc VCPKG_ROOT drift fails" 1 "VCPKG_ROOT drift"

fresh
sed -i -E 's/^zellij = "[0-9.]+"/zellij = "0.1.0"/' "$T/config.linux.toml"
pins
case_ "zellij below the zjstatus floor fails" 1 "is below"

fresh
sed -i -E 's/typescript@[0-9.]+/typescript@7.0.0/' "$T/config.toml"
pins
case_ "typescript major 7 fails" 1 "major 7 > 5"

fresh
sed -i -E '/^\[vars\]/,/^\[/{/^vcpkg_version/d}' "$T/config.toml"
pins
case_ "no [vars] *_version key found fails" 1 "<none found>"

fresh
sed -i -E 's/^("github:dj95\/zjstatus" = \{ )version = "[0-9.]+"/\1version = ""/' "$T/config.linux.toml"
pins
case_ "unreadable zjstatus pin fails" 1 "zjstatus pin unreadable"

fresh
sed -i -E 's/typescript-language-server@[0-9.]+ //' "$T/config.toml"
pins
case_ "typescript-language-server missing from postinstall fails" 1 "missing from node's postinstall"

fresh
sed -i -E 's/^(COUPLED_AUTO=".*) node"/\1"/' "$T/scripts/bump-versions.sh"
pins
case_ "node missing from COUPLED_AUTO fails" 1 "node"

fresh
sed -i '/^\[vars\]/a foo_version = "1.0"' "$T/config.toml"
pins
case_ "uncovered [vars] *_version pin fails" 1 "foo_version"

fresh
sed -i 's/vcpkg_version/vcpkg_ver/g' "$T/scripts/bump-versions.sh"
pins
case_ "a [vars] pin bump-versions.sh doesn't bump fails" 1 "vcpkg_version(bump-versions.sh)"

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

OUT="$(bash "$T/scripts/check-invariants.sh" --only 2>&1)"
RC=$?
case_ "--only with no names exits 2" 2 "usage"

OUT="$(bash "$T/scripts/check-invariants.sh" --only ok 2>&1)"
RC=$?
case_ "--only without the check_ prefix exits 2" 2 "unknown check"

OUT="$(bash "$T/scripts/check-invariants.sh" --only check_pins check_nope 2>&1)"
RC=$?
case_ "--only validates every name before running any" 2 "unknown check"
if printf '%s' "$OUT" | grep -q "pins recorded"; then
  RC=1
  OUT="a check ran before validation"
else
  RC=0
fi
case_ "--only unknown name: nothing ran" 0

if [ "${1:-}" != --no-self ]; then
  before="$(git -C "$ROOT" diff --cached --name-only | sort | md5sum)"
  OUT="$(GIT_INDEX_FILE="$ROOT/.git/index" GIT_DIR="$ROOT/.git" bash "$ROOT/scripts/check-invariants.sh" --only check_self_tests 2>&1)"
  RC=$?
  after="$(git -C "$ROOT" diff --cached --name-only | sort | md5sum)"
  case_ "self-tests pass under a pre-commit-like env" 0 "hook assertions passed"
  [ "$before" = "$after" ]
  RC=$?
  OUT="index changed"
  case_ "self-tests leave the real index alone" 0
fi

rm -rf "$T"
echo
if [ "$fail" -eq 0 ]; then
  printf '\033[0;32m✓ all %d check_pins cases passed\033[0m\n' "$pass"
  exit 0
fi
printf '\033[0;31m✗ %d/%d check_pins cases failed\033[0m\n' "$fail" "$((pass + fail))"
exit 1
