#!/usr/bin/env bash
# check-templates.sh — render the chezmoi templates for each host group and
# syntax-check the rendered output. Catches Go-template errors and shell/nu/
# gitconfig syntax errors at lint time instead of at `chezmoi apply` time on
# a live host (where a broken .zshrc breaks every new shell).
#
# Renders happen on Linux, so `.chezmoi.os` is "linux": Linux-target files
# get full render+syntax coverage; Windows-target files (config.nu, the
# PowerShell profile) still get template-PARSE coverage plus a syntax check
# of their linux-rendered body (both barely branch on OS — see CLAUDE.md).
#
# Checkers soft-skip when absent (mirrors check-invariants.sh): zsh, nu and
# pwsh may be missing locally; CI (lint.yml `templates` job) installs them
# all, so the full matrix always enforces there.
#
# Usage: bash scripts/check-templates.sh          (from anywhere; repo-relative)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO_ROOT/chezmoi"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

fails=0
hdr() { printf '%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
ok() { printf ' %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
bad() {
  printf ' %s✗%s %s\n' "$RED" "$RESET" "$*"
  fails=$((fails + 1))
}
note() { printf ' · %s\n' "$*"; }

command -v chezmoi >/dev/null 2>&1 || {
  note "chezmoi not installed — cannot render templates (CI enforces)"
  exit 0
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Synthetic chezmoi config per group. The templates under test reference
# .name / .email / .group (plus runtime .chezmoi.* values chezmoi provides).
make_cfg() { # $1=group → prints config path
  local cfg="$WORK/chezmoi-$1.toml"
  cat >"$cfg" <<EOF
[data]
  group = "$1"
  name = "Template Check"
  email = "check@example.invalid"
EOF
  printf '%s' "$cfg"
}

# render <group> <source-relative-template> <out-file>
render() {
  local cfg
  cfg="$(make_cfg "$1")"
  chezmoi --config "$cfg" --source "$SRC" execute-template \
    <"$SRC/$2" >"$3" 2>"$WORK/render-err"
}

# check <group> <template> <label> <checker-cmd...>   (checker gets $out appended)
check() {
  local group=$1 tmpl=$2 label=$3
  shift 3
  local out="$WORK/out"
  if ! render "$group" "$tmpl" "$out"; then
    bad "$label [$group]: template render failed: $(head -1 "$WORK/render-err")"
    return
  fi
  if [ "$#" -eq 0 ]; then
    ok "$label [$group]: renders"
    return
  fi
  if "$@" "$out" >"$WORK/check-err" 2>&1; then
    ok "$label [$group]: renders + syntax OK"
  else
    bad "$label [$group]: syntax check failed: $(head -1 "$WORK/check-err")"
  fi
}

zsh_check() { zsh -n "$1"; }
bash_check() { bash -n "$1"; }
git_check() { git config --file "$1" --list >/dev/null; }
nu_check() { nu --no-config-file --commands "if (nu-check '$1') { exit 0 } else { exit 1 }"; }
pwsh_check() {
  pwsh -NoProfile -Command \
    "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$1',[ref]\$null,[ref]\$e); if (\$e) { \$e | ForEach-Object { \$_.Message }; exit 1 }"
}

hdr "rendered-template syntax checks (dev_machine + prod_machine)"
for group in dev_machine prod_machine; do
  if command -v zsh >/dev/null 2>&1; then
    check "$group" dot_zshrc.tmpl ".zshrc" zsh_check
  else
    note ".zshrc [$group]: zsh not installed — render-only"
    check "$group" dot_zshrc.tmpl ".zshrc(render)"
  fi
  check "$group" dot_bashrc.tmpl ".bashrc" bash_check
  check "$group" dot_gitconfig.tmpl ".gitconfig" git_check
  check "$group" .chezmoiignore.tmpl ".chezmoiignore"
done

# Windows-target files: group-independent content; render once as dev_machine.
if command -v nu >/dev/null 2>&1; then
  check dev_machine AppData/Roaming/nushell/config.nu.tmpl "config.nu" nu_check
else
  note "config.nu: nu not installed — render-only (CI enforces)"
  check dev_machine AppData/Roaming/nushell/config.nu.tmpl "config.nu(render)"
fi
if command -v pwsh >/dev/null 2>&1; then
  check dev_machine Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl "PS profile" pwsh_check
else
  note "PS profile: pwsh not installed — render-only (CI enforces)"
  check dev_machine Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl "PS profile(render)"
fi

hdr "summary"
if ((fails > 0)); then
  printf '   %d failure(s)\n' "$fails"
  exit 1
fi
printf '   all rendered templates pass\n'
