#!/usr/bin/env bash
# test-ci-scope.sh: scripts/ci-scope.sh's path -> job map. Each case is a change (paths
# separated by spaces) and the scopes it must turn on, in ci-scope.sh's order; `-` is none.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALL="ws templates powershell windows tool_env"
n=0
fails=0

# scopes <path>... -> the scopes ci-scope.sh turns on, space-separated
scopes() {
  printf '%s\n' "$@" | bash "$ROOT/scripts/ci-scope.sh" | sed -n 's/=true$//p' | tr '\n' ' ' | sed 's/ $//'
}

expect() {
  local want="$1" got
  shift
  [ "$want" = - ] && want=""
  # shellcheck disable=SC2086  # the case's paths, one argument each
  got="$(scopes $1)"
  n=$((n + 1))
  if [ "$got" != "$want" ]; then
    fails=$((fails + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "${want:-(none)}" "${got:-(none)}"
  fi
}

# Invariants only: docs, memory, locks, shell scripts and their tests, the other workflows.
expect - "README.md"
expect - "CLAUDE.md docs/claude/verification.md .claude/memory/MEMORY.md"
expect - "mise.lock mise.linux.lock locks/npm/x/package-lock.json"
expect - "bootstrap.sh scripts/test-bootstrap.sh"
expect - "scripts/bump-versions.sh scripts/test-bump-lock-retry.sh"
expect - "scripts/check-invariants.sh"
expect - ".github/workflows/disk-budget.yml .github/workflows/version-bumps.yml"
expect - "configs/wsl/wsl.conf"

# Documents are documents wherever they sit, except under dotfiles/ and tasks/.
expect - "CHANGELOG.md notes.html"
expect - "scripts/ws/README.md newdir/page.htm"
expect "ws templates" "dotfiles/claude/CLAUDE.md"
expect "ws templates" "tasks/notes.md"

# A pin bump touches the catalogue: everything that reads it, not the PowerShell lint.
expect "ws templates windows tool_env" "config.linux.toml mise.linux.lock"
expect "ws templates windows tool_env" "config.toml"
expect "ws templates windows tool_env" "config.windows.toml"

# PowerShell.
expect "powershell windows" "bootstrap.ps1"
expect "powershell windows" "scripts/test-curl.ps1"
expect "powershell windows" "scripts/lib/test-helpers.ps1"
expect "powershell windows" "PSScriptAnalyzerSettings.psd1"
expect "ws powershell windows" "scripts/update.ps1"
expect "ws templates powershell windows" "dotfiles/windows/local/bin/ws-agent.ps1"
expect "ws templates powershell windows" "dotfiles/windows/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"

# Dotfiles and tasks.
expect "ws templates" "dotfiles/zshrc.tera"
expect "ws templates" "dotfiles/config/nvim/init.lua"
expect "ws templates" "tasks/health"
expect "ws templates windows" "dotfiles/config/wezterm/wezterm.lua"
expect "ws templates windows" "dotfiles/claude/settings.enforced.json"
expect "ws templates windows" "dotfiles/local/bin/ws-agent"
expect "ws templates windows" "dotfiles/windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera"

# ws, tool-env, the templates job's own scripts, the shared shell library.
expect "ws templates windows" "scripts/ws/wslib/agent.py"
expect "ws templates windows" "scripts/ws/tests/test_store.py scripts/test-ws.sh"
expect "tool_env" "scripts/tool-env.py"
expect "tool_env" "environments/python/uv.lock scripts/test-tool-env-real.py"
expect "templates" "scripts/check-templates.sh"
expect "templates" "scripts/nu-init.nu scripts/test-nu-init.sh"
expect "templates windows" "scripts/lib/claude-settings-merge.sh"
expect "templates windows" "scripts/lib/claude-settings-merge.jq"
expect "windows" "disk-budget.toml"

# Scopes add up across a change.
expect "ws templates powershell windows tool_env" "scripts/tool-env.py dotfiles/bashrc.tera bootstrap.ps1"
expect "powershell windows" "README.md scripts/wezterm-nightly.ps1"

# Everything: the workflow, the map itself, a path no rule names, --all, no paths.
expect "$ALL" ".github/workflows/lint.yml"
expect "$ALL" "README.md scripts/ci-scope.sh"
expect "$ALL" "some-new-top-level-file"
expect "$ALL" "newdir/thing.txt README.md"
n=$((n + 2))
got="$(bash "$ROOT/scripts/ci-scope.sh" --all </dev/null | sed -n 's/=true$//p' | tr '\n' ' ' | sed 's/ $//')"
[ "$got" = "$ALL" ] || {
  fails=$((fails + 1))
  echo "FAIL: --all turned on: ${got:-(none)}"
}
got="$(bash "$ROOT/scripts/ci-scope.sh" </dev/null | sed -n 's/=true$//p' | tr '\n' ' ' | sed 's/ $//')"
[ "$got" = "$ALL" ] || {
  fails=$((fails + 1))
  echo "FAIL: no paths turned on: ${got:-(none)}"
}

# Every tracked file has a rule: none falls through to "run everything" by accident.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  n=$((n + 1))
  unruled=""
  while IFS= read -r f; do
    case "$f" in .github/workflows/lint.yml | scripts/ci-scope.sh) continue ;; esac
    [ "$(scopes "$f")" != "$ALL" ] || unruled="$unruled $f"
  done < <(git -C "$ROOT" ls-files | sed -E 's#^(dotfiles|docs|\.claude|locks|scripts/ws)/.*#\1/x#' | sort -u)
  # A file may truly need every scope; none does today.
  [ -z "$unruled" ] || {
    fails=$((fails + 1))
    echo "FAIL: no rule in ci-scope.sh for:$unruled"
  }
fi

if [ "$fails" -eq 0 ]; then
  echo "all $n ci-scope cases passed"
else
  echo "$fails of $n ci-scope cases failed"
  exit 1
fi
