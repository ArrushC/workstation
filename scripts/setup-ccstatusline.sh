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
# shellcheck disable=SC2034  # documents the tracked settings source; pairs with CLAUDE_SETTINGS_DEST
CLAUDE_SETTINGS_TRACKED_SRC="$CHEZMOI_SRC/private_dot_claude/modify_private_settings.json"
CLAUDE_SETTINGS_DEST="$HOME/.claude/settings.json"

BOLD=$'\033[1m'
YELLOW=$'\033[33m'
GREEN=$'\033[32m'
RED=$'\033[31m'
RESET=$'\033[0m'

HOST="$(hostname -s)"
# shellcheck disable=SC2034  # symmetry with SENTINEL_END; awk patterns below match the literal string
SENTINEL_START='# CCSTATUSLINE:START'
SENTINEL_END='# CCSTATUSLINE:END'
CCSTATUSLINE_VERSION="${CCSTATUSLINE_VERSION:-2.2.19}"

# --- preflight --------------------------------------------------------------

preflight() {
  if ! command -v npx >/dev/null 2>&1; then
    printf '%bnpx not found.%b ccstatusline runs via npx; install Node.js first:\n' "$YELLOW" "$RESET"
    printf '  Recommended: %bmake -C makefile mise-runtimes MODE=dev%b (this repo; node is mise-managed, pinned in versions.mk)\n' "$YELLOW" "$RESET"
    printf '  Then re-run: %bmake -C makefile claude-statusline MODE=dev%b\n' "$YELLOW" "$RESET"
    exit 0
  fi
  # WSL trap: if `npx` resolves to a Windows-side install (PATH passthrough
  # through /mnt/c/... or *.exe), the Windows node can't operate from a WSL
  # working directory (UNC path failure — CMD.EXE refuses \\wsl.localhost\…
  # and falls back to the Windows directory, breaking the TUI before it can
  # render). Detect and bail with a useful install hint.
  local npx_path
  npx_path="$(command -v npx)"
  case "$npx_path" in
  /mnt/* | */node.exe | *.exe)
    printf '%bnpx resolves to a Windows-side install (%s).%b\n' "$YELLOW" "$npx_path" "$RESET"
    printf 'Windows node cannot run from a WSL working directory (UNC path failure).\n'
    printf 'Install Linux-native Node.js inside this WSL distro:\n'
    printf '  %bmake -C makefile mise-runtimes MODE=dev%b\n' "$YELLOW" "$RESET"
    printf 'Then re-run: %bmake -C makefile claude-statusline MODE=dev%b\n' "$YELLOW" "$RESET"
    exit 0
    ;;
  esac
  if [ ! -f "$HOME/.config/chezmoi/chezmoi.toml" ]; then
    printf '%bchezmoi not initialized — run ./bootstrap.sh --dev first.%b\n' "$RED" "$RESET" >&2
    exit 1
  fi
}

# --- sentinel block primitives ----------------------------------------------
# Manages per-host opt-out lines between # CCSTATUSLINE:START / END markers
# inside chezmoi/.chezmoiignore.tmpl. Each opted-out host contributes one
# line of the form:
#   {{ if eq .chezmoi.hostname "<host>" }}.config/ccstatusline/settings.json{{ end }}
# NOTE: the path is the TARGET path (.config/ccstatusline/...), not the
# source-state name (dot_config/...) — chezmoi matches .chezmoiignore against
# target paths, so the dot_ form would silently match nothing.

sentinel_contains() {
  local host="$1"
  awk -v host="$host" '
    /^# CCSTATUSLINE:START$/ { inblock=1; next }
    /^# CCSTATUSLINE:END$/   { inblock=0 }
    inblock && index($0, "\"" host "\"") > 0 { found=1; exit }
    END { exit !found }
  ' "$IGNORE_TMPL"
}

sentinel_add() {
  local host="$1"
  if sentinel_contains "$host"; then return 0; fi
  local stanza
  stanza="$(printf '{{ if eq .chezmoi.hostname "%s" }}.config/ccstatusline/settings.json{{ end }}' "$host")"
  local tmp
  tmp="$(mktemp)"
  awk -v end="$SENTINEL_END" -v stanza="$stanza" '
    $0 == end { print stanza; print; next }
    { print }
  ' "$IGNORE_TMPL" >"$tmp"
  mv "$tmp" "$IGNORE_TMPL"
}

sentinel_remove() {
  local host="$1"
  if ! sentinel_contains "$host"; then return 0; fi
  local tmp
  tmp="$(mktemp)"
  awk -v host="$host" '
    /^# CCSTATUSLINE:START$/ { inblock=1; print; next }
    /^# CCSTATUSLINE:END$/   { inblock=0; print; next }
    inblock && index($0, "\"" host "\"") > 0 { next }
    { print }
  ' "$IGNORE_TMPL" >"$tmp"
  mv "$tmp" "$IGNORE_TMPL"
}

# --- options (skeletons; filled in by later tasks) -------------------------

option_use_tracked() {
  local tracked_content
  tracked_content="$(cat "$WIDGET_TRACKED_SRC")"
  # Empty tracked widget config (the initial `{}` seed) — bail with a hint
  # instead of applying an empty config over the user's local one.
  if [ "$(printf '%s' "$tracked_content" | tr -d '[:space:]')" = '{}' ]; then
    printf '%bTracked widget config is empty (just `{}`).%b Pick option 3 first to seed it from a real configuration.\n' "$YELLOW" "$RESET"
    return 0
  fi
  if sentinel_contains "$HOST"; then
    printf '%bRemoving %s from local-persist sentinel block...%b\n' "$BOLD" "$HOST" "$RESET"
    sentinel_remove "$HOST"
  fi
  printf '%bApplying tracked ccstatusline + Claude Code settings...%b\n' "$GREEN" "$RESET"
  chezmoi apply "$WIDGET_DEST" "$CLAUDE_SETTINGS_DEST"
  printf '%bDone.%b\n' "$GREEN" "$RESET"
}
option_this_machine() {
  printf '%bLaunching ccstatusline TUI (v%s)...%b\n' "$BOLD" "$CCSTATUSLINE_VERSION" "$RESET"
  if ! npx -y "ccstatusline@$CCSTATUSLINE_VERSION" </dev/tty; then
    printf '%bTUI exited non-zero or was cancelled — no changes.%b\n' "$YELLOW" "$RESET"
    return 0
  fi
  printf '%bPersist this machine-local config across chezmoi updates? (y/N): %b' "$BOLD" "$RESET"
  local ans
  read -r ans </dev/tty
  case "${ans,,}" in
  y | yes)
    sentinel_add "$HOST"
    printf '%bAdded %s to local-persist sentinel block — subsequent `chezmoi apply` runs will leave your local widget config alone.%b\n' "$GREEN" "$HOST" "$RESET"
    ;;
  *)
    printf '%bEphemeral — next `chezmoi update` will overwrite your local widget config with the tracked version.%b\n' "$YELLOW" "$RESET"
    ;;
  esac
}
option_set_global() {
  printf '%bLaunching ccstatusline TUI (v%s)...%b\n' "$BOLD" "$CCSTATUSLINE_VERSION" "$RESET"
  if ! npx -y "ccstatusline@$CCSTATUSLINE_VERSION" </dev/tty; then
    printf '%bTUI exited non-zero or was cancelled — no changes.%b\n' "$YELLOW" "$RESET"
    return 0
  fi
  if sentinel_contains "$HOST"; then
    printf '%bRemoving %s from local-persist sentinel block (setting global overrides prior local-persist)...%b\n' "$BOLD" "$HOST" "$RESET"
    sentinel_remove "$HOST"
  fi
  printf '%bPulling widget config back into chezmoi source...%b\n' "$GREEN" "$RESET"
  # NOTE: only the widget config is re-added. ~/.claude/settings.json is NOT
  # re-added because ccstatusline's TUI "Install to Claude Code" path
  # overwrites the local file with a statusLine-only block, which would
  # strip every other key (skipAutoPermissionPrompt, tui, theme, etc.) on
  # every save. That merge-template is hand-managed via direct edits to
  # chezmoi/private_dot_claude/modify_private_settings.json; statusline
  # version bumps are a dual-edit with versions.mk per CLAUDE.md.
  chezmoi re-add "$WIDGET_DEST"
  cd "$REPO_ROOT"
  git add \
    chezmoi/dot_config/ccstatusline/settings.json \
    chezmoi/.chezmoiignore.tmpl
  if git diff --cached --quiet; then
    printf '%bNo changes to commit — local config matched tracked.%b\n' "$YELLOW" "$RESET"
    return 0
  fi
  git commit -m "$(printf 'feat(claude): update ccstatusline tracked config\n\nUpdated via setup-ccstatusline.sh on %s.\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>' "$HOST")"
  printf '%bPushing to origin...%b\n' "$GREEN" "$RESET"
  git push origin "$(git symbolic-ref --short HEAD)"
  printf '%bDone.%b\n' "$GREEN" "$RESET"
}
option_skip() { printf '%bSkipped.%b\n' "$YELLOW" "$RESET"; }

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
  1) option_use_tracked ;;
  2) option_this_machine ;;
  3) option_set_global ;;
  4 | "") option_skip ;;
  *)
    printf '%bInvalid choice.%b\n' "$RED" "$RESET" >&2
    exit 1
    ;;
  esac
}

main "$@"
