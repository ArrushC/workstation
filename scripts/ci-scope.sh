#!/usr/bin/env bash
# ci-scope.sh: which of lint.yml's jobs a change needs. Reads the changed paths on stdin (one
# per line, relative to the repository root) and prints one `name=true|false` line per scope:
#
#   ws          scripts/test-ws.sh, the ws suite inside the invariants job
#   templates   the templates job (check-templates.sh, test-nu-init.sh, test-config-nu.sh)
#   powershell  the powershell job (PSScriptAnalyzer)
#   windows     the windows-http job (scripts/test-*.ps1 under 5.1 and pwsh)
#   tool_env    the dependency-environments jobs (scripts/test-tool-env*.py, both OSes)
#
# The rest of the invariants job (check-invariants.sh) always runs: it holds the cross-file
# rules, so no path is outside it.
#
# `--all` (or no paths at all) turns every scope on. So does a path no rule below names: a
# new top-level file or directory runs everything until it is given a line here. Add a
# path a test starts reading to that test's scope, and a case to scripts/test-ci-scope.sh.
set -euo pipefail

SCOPES=(ws templates powershell windows tool_env)
declare -A on=()
all=0

need() {
  local s
  for s in "$@"; do on["$s"]=1; done
}

classify() {
  # PowerShell: every script is linted, and the Windows tests load functions out of the
  # scripts. Wherever the file lives; the rules below add what else reads it.
  case "$1" in
  *.ps1 | PSScriptAnalyzerSettings.psd1) need powershell windows ;;
  esac
  case "$1" in
  # The workflow and this map decide what runs: a change to either runs everything.
  .github/workflows/lint.yml | scripts/ci-scope.sh) all=1 ;;

  scripts/update.ps1) need ws ;; # test_commands reads it
  bootstrap.ps1 | scripts/*.ps1 | PSScriptAnalyzerSettings.psd1) ;;

  # The catalogue: tools (the runtimes tool-env builds on), [dotfiles], hooks, winget apps.
  config.toml | config.*.toml) need ws templates windows tool_env ;;

  # Dotfiles render in the templates job; ws's tests read the rc files, the launchers and
  # zellij's layouts; the Windows tests read the Windows tree, wezterm.lua and the Claude
  # settings layers.
  dotfiles/windows/* | dotfiles/config/wezterm/* | dotfiles/claude/settings.* | dotfiles/local/bin/ws-agent)
    need ws templates windows
    ;;
  dotfiles/*) need ws templates ;;

  # Tasks are the bootstrap hooks the bulk apply runs; ws lists and runs them.
  tasks/*) need ws templates ;;

  # ws itself: the palette and reconcile (config.nu's tests, the dotfiles hooks) and the
  # Windows ws-agent forwarder's argv decoding.
  scripts/ws/* | scripts/test-ws.sh) need ws templates windows ;;

  scripts/tool-env.py | scripts/test-tool-env.py | scripts/test-tool-env-real.py | environments/*) need tool_env ;;

  scripts/check-templates.sh | scripts/test-nu-init.sh | scripts/test-config-nu.sh | scripts/*.nu) need templates ;;

  # Sourced by tasks and hooks (mise-env.sh, bootstrap-fn.sh, claude-settings-merge.sh, ...).
  scripts/lib/*) need templates windows ;;

  # bootstrap.ps1's free-space check reads the budget.
  disk-budget.toml) need windows ;;

  # Covered by the invariants job alone: its own checks, the shell self-tests it runs
  # (test-bootstrap.sh, test-mise-install.sh, ...), shellcheck, shfmt and gitleaks.
  bootstrap.sh | scripts/*.sh) ;;
  README.md | CLAUDE.md | docs/* | .claude/* | .gitignore | .gitleaks.toml) ;;
  mise.lock | mise.*.lock | locks/* | configs/*) ;;
  .github/workflows/*) ;;

  *) all=1 ;;
  esac
}

if [ "${1:-}" = --all ]; then
  all=1
else
  n=0
  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    n=$((n + 1))
    classify "$path"
  done
  [ "$n" -gt 0 ] || all=1
fi

for s in "${SCOPES[@]}"; do
  if [ "$all" -eq 1 ] || [ -n "${on[$s]:-}" ]; then
    printf '%s=true\n' "$s"
  else
    printf '%s=false\n' "$s"
  fi
done
