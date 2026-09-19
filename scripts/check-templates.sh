#!/usr/bin/env bash
# check-templates.sh — render ALL tracked chezmoi templates for each host
# group and syntax-check the rendered output: rc files, .chezmoiscripts/*.tmpl,
# dot_config/dotfile/AppData templates. Catches Go-template errors and
# shell/nu/gitconfig/yaml/toml syntax errors at lint time instead of at
# `chezmoi apply` time on a live host (where a broken .zshrc breaks every new
# shell). Only .chezmoi.toml.tmpl is excluded: it's the CONFIG template
# (needs promptStringOnce data, not renderable with the synthetic config).
#
# Renders happen on Linux, so `.chezmoi.os` is "linux": Linux-target files
# get full render+syntax coverage; Windows-target files (config.nu, the
# PowerShell profile + ps1 script, helix config.toml) still get
# template-PARSE coverage plus a syntax check of their linux-rendered body
# (they barely branch on OS — see CLAUDE.md).
#
# Checkers soft-skip when absent (mirrors check-invariants.sh): zsh, nu,
# pwsh, yq and python3-with-tomllib (3.11+) may be missing locally; CI (lint.yml
# `templates` job) has them all, so the full matrix always enforces there
# (ubuntu-latest ships yq + python 3.12 — no extra install steps needed).
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
  local out="$WORK/out" err
  if ! render "$group" "$tmpl" "$out"; then
    err="$(head -1 "$WORK/render-err")"
    bad "$label [$group]: template render failed: ${err:-(no stderr)}"
    return
  fi
  if [ "$#" -eq 0 ]; then
    ok "$label [$group]: renders"
    return
  fi
  if "$@" "$out" >"$WORK/check-err" 2>&1; then
    ok "$label [$group]: renders + syntax OK"
  else
    err="$(head -1 "$WORK/check-err")"
    bad "$label [$group]: syntax check failed: ${err:-(no stderr)}"
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
yaml_check() { yq eval '.' "$1" >/dev/null; }
toml_check() { python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$1"; }

hdr "rendered-template syntax checks (dev_machine + prod_machine)"
for group in dev_machine prod_machine; do
  if command -v zsh >/dev/null 2>&1; then
    check "$group" dot_zshrc.tmpl ".zshrc" zsh_check
    check "$group" dot_zshenv.tmpl ".zshenv" zsh_check
  else
    note ".zshrc [$group]: zsh not installed — render-only"
    check "$group" dot_zshrc.tmpl ".zshrc(render)"
    note ".zshenv [$group]: zsh not installed — render-only"
    check "$group" dot_zshenv.tmpl ".zshenv(render)"
  fi
  check "$group" dot_bashrc.tmpl ".bashrc" bash_check
  check "$group" dot_gitconfig.tmpl ".gitconfig" git_check
  check "$group" .chezmoiignore.tmpl ".chezmoiignore"
  # chezmoi scripts: every .sh body must be valid bash in every group render
  # (a gated-out render is an empty file — bash -n passes trivially).
  for s in "$SRC"/.chezmoiscripts/*.sh.tmpl; do
    check "$group" ".chezmoiscripts/$(basename "$s")" "$(basename "$s" .tmpl)" bash_check
  done
  # environment.d conf: MISE_ENV branches on .group — render both ways. Its
  # output is a plain KEY=value line — render-only, no syntax checker.
  check "$group" dot_config/environment.d/10-mise.conf.tmpl "10-mise.conf"
done

# Group-independent Linux-target files: render once as dev_machine.
if command -v yq >/dev/null 2>&1; then
  check dev_machine dot_config/cheat/conf.yml.tmpl "cheat conf.yml" yaml_check
else
  note "cheat conf.yml: yq not installed — render-only (CI enforces)"
  check dev_machine dot_config/cheat/conf.yml.tmpl "cheat conf.yml(render)"
fi
check dev_machine dot_gdbinit.tmpl ".gdbinit"
check dev_machine private_dot_ssh/private_config.tmpl "ssh config"

# Windows-target files: group-independent content; render once as dev_machine.
if python3 -c 'import tomllib' 2>/dev/null; then
  check dev_machine AppData/Roaming/helix/config.toml.tmpl "helix config.toml" toml_check
else
  note "helix config.toml: python3 tomllib (3.11+) unavailable — render-only (CI enforces)"
  check dev_machine AppData/Roaming/helix/config.toml.tmpl "helix config.toml(render)"
fi
if command -v nu >/dev/null 2>&1; then
  check dev_machine AppData/Roaming/nushell/config.nu.tmpl "config.nu" nu_check
else
  note "config.nu: nu not installed — render-only (CI enforces)"
  check dev_machine AppData/Roaming/nushell/config.nu.tmpl "config.nu(render)"
fi
if command -v pwsh >/dev/null 2>&1; then
  check dev_machine Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl "PS profile" pwsh_check
  check dev_machine .chezmoiscripts/run_onchange_after_remind-wslconfig-restart.ps1.tmpl "wslconfig ps1" pwsh_check
else
  note "PS profile: pwsh not installed — render-only (CI enforces)"
  check dev_machine Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl "PS profile(render)"
  check dev_machine .chezmoiscripts/run_onchange_after_remind-wslconfig-restart.ps1.tmpl "wslconfig ps1(render)"
fi

hdr "summary"
if ((fails > 0)); then
  printf '   %d failure(s)\n' "$fails"
  exit 1
fi
printf '   all rendered templates pass\n'
