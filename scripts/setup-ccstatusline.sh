#!/usr/bin/env bash
# setup-ccstatusline.sh — interactive setup of the Claude Code statusline
# via ccstatusline. Four options: use tracked / this machine / set global /
# skip. Invoked by `make -C makefile claude-statusline MODE=dev` and at
# the tail of `bootstrap.sh --dev`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHEZMOI_SRC="$REPO_ROOT/chezmoi"
IGNORE_TMPL="$CHEZMOI_SRC/.chezmoiignore.tmpl"
WIDGET_TRACKED_SRC="$CHEZMOI_SRC/dot_config/ccstatusline/settings.json"
WIDGET_DEST="$HOME/.config/ccstatusline/settings.json"
CLAUDE_SETTINGS_TRACKED_SRC="$CHEZMOI_SRC/private_dot_claude/private_settings.json.tmpl"
CLAUDE_SETTINGS_DEST="$HOME/.claude/settings.json"

BOLD=$'\033[1m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

HOST="$(hostname -s)"
SENTINEL_START='# CCSTATUSLINE:START'
SENTINEL_END='# CCSTATUSLINE:END'
CCSTATUSLINE_VERSION="${CCSTATUSLINE_VERSION:-2.2.19}"

# --- preflight --------------------------------------------------------------

preflight() {
  if ! command -v npx >/dev/null 2>&1; then
    printf '%bnpx not found.%b ccstatusline runs via npx; install Node.js first:\n' "$YELLOW" "$RESET"
    printf '  Fedora/RHEL: %bsudo dnf install -y nodejs%b\n' "$YELLOW" "$RESET"
    printf '  Debian/Ubuntu: %bsudo apt install -y nodejs npm%b\n' "$YELLOW" "$RESET"
    printf 'Then re-run: %bmake -C makefile claude-statusline MODE=dev%b\n' "$YELLOW" "$RESET"
    exit 0
  fi
  if [ ! -f "$HOME/.config/chezmoi/chezmoi.toml" ]; then
    printf '%bchezmoi not initialized — run ./bootstrap.sh --dev first.%b\n' "$RED" "$RESET" >&2
    exit 1
  fi
}

# --- options (skeletons; filled in by later tasks) -------------------------

option_use_tracked()  { printf '%boption 1 (use tracked) — not yet implemented.%b\n' "$YELLOW" "$RESET"; }
option_this_machine() { printf '%boption 2 (this machine) — not yet implemented.%b\n' "$YELLOW" "$RESET"; }
option_set_global()   { printf '%boption 3 (set new global) — not yet implemented.%b\n' "$YELLOW" "$RESET"; }
option_skip()         { printf '%bSkipped.%b\n' "$YELLOW" "$RESET"; }

# --- menu -------------------------------------------------------------------

show_menu() {
  printf '\n%bccstatusline setup%b (host: %b%s%b, version: %b%s%b)\n' \
    "$BOLD" "$RESET" "$YELLOW" "$HOST" "$RESET" "$YELLOW" "$CCSTATUSLINE_VERSION" "$RESET"
  printf '  1) Use the chezmoi-tracked status line (same as every host)\n'
  printf '  2) Define a new status line for this machine (with persist sub-prompt)\n'
  printf '  3) Set a new global status line (configure + commit + push)\n'
  printf '  4) Skip\n\n'
  printf '%bChoice [1-4]: %b' "$BOLD" "$RESET"
}

# --- main -------------------------------------------------------------------

main() {
  preflight
  show_menu
  local choice
  read -r choice </dev/tty
  case "$choice" in
    1)        option_use_tracked  ;;
    2)        option_this_machine ;;
    3)        option_set_global   ;;
    4|"")     option_skip         ;;
    *)        printf '%bInvalid choice.%b\n' "$RED" "$RESET" >&2; exit 1 ;;
  esac
}

main "$@"
