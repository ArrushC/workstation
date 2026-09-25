#!/usr/bin/env bash
# setup-ccstatusline.sh — interactive setup of the Claude Code statusline
# via ccstatusline. Four options: use tracked / this machine / set global /
# skip. Invoked by `mise run statusline` and at the tail of `bootstrap.sh --dev`.
#
# The widget config is a mise [dotfiles] entry (config.owned.toml,
# `~/.config/ccstatusline/settings.json`, mode = "copy" — like every
# `[dotfiles]` entry now, 2026-09-22 copy-migration; this one was already
# copy before that, I4/final-fix-brief.md, so nothing here changed behavior)
# — the live file is an independent COPY of dotfiles/config/ccstatusline/
# settings.json, not a symlink into the checkout, so editing it in place does
# NOT dirty the repo (ruling 8 is retired) and does NOT round-trip on its own
# — `mise dot add`/option 3 below is the only way back. A host that wants a
# private, untracked config opts OUT of that entry entirely via
# config.local.toml (mode = "copy", enabled = false — see the opt-out
# primitives below, and note it deliberately matches the base entry's own
# mode), which is what makes "define a new status line for THIS machine"
# (option 2) mean something: once opted out, mise never touches the live
# file again, so it's free to diverge for good.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIDGET_SOURCE="dotfiles/config/ccstatusline/settings.json"
WIDGET_TRACKED_SRC="$REPO_ROOT/$WIDGET_SOURCE"
WIDGET_DEST="$HOME/.config/ccstatusline/settings.json"
# Deliberately literal ~ — this is the [dotfiles] TARGET key (config.owned.toml
# / config.local.toml) and the string `mise dot apply`/`mise dot add` expect
# on the command line, not a path for the shell to expand.
# shellcheck disable=SC2088
WIDGET_TARGET='~/.config/ccstatusline/settings.json'
LOCAL_CONFIG="$REPO_ROOT/config.local.toml"
# `mise dot` commands below run from wherever this script was invoked from —
# deliberately NOT `cd "$REPO_ROOT"` first. mise resolves the global config
# via $HOME/.config/mise (this checkout IS that, by this whole project's
# design), independent of cwd; verified in a scratch repo copy that `cd`ing
# into a SECOND checkout of this same config before `mise dot add` makes it
# fail to recognize the target as already-managed (it seeds a brand new
# entry under a default ~/.dotfiles root instead of updating the real
# source) even though `mise dot apply` tolerates the same `cd`. Simplest fix
# that works for both commands: never `cd` here at all.

BOLD=$'\033[1m'
YELLOW=$'\033[33m'
GREEN=$'\033[32m'
RED=$'\033[31m'
RESET=$'\033[0m'

HOST="$(hostname -s)"
SENTINEL_START='# CCSTATUSLINE-OPTOUT:START'
SENTINEL_END='# CCSTATUSLINE-OPTOUT:END'

# --- preflight --------------------------------------------------------------

preflight() {
  if ! command -v ccstatusline >/dev/null 2>&1; then
    printf '%bccstatusline not found%b — %bmise install npm:ccstatusline%b installs it (npm:ccstatusline in config.owned.toml)\n' "$YELLOW" "$RESET" "$YELLOW" "$RESET"
    exit 0
  fi
  # WSL trap: if `ccstatusline` resolves to a Windows-side install (PATH
  # passthrough through /mnt/c/...), the Windows-side binary can't operate
  # from a WSL working directory (UNC path failure — CMD.EXE refuses
  # \\wsl.localhost\… and falls back to the Windows directory, breaking the
  # TUI before it can render). Detect and bail with a useful install hint.
  local ccstatusline_path
  ccstatusline_path="$(command -v ccstatusline)"
  case "$ccstatusline_path" in
  /mnt/*)
    printf '%bccstatusline resolves to a Windows-side install (%s).%b\n' "$YELLOW" "$ccstatusline_path" "$RESET"
    printf 'A Windows-side ccstatusline cannot run from a WSL working directory (UNC path failure).\n'
    printf 'Install the mise-managed Linux-native ccstatusline inside this WSL distro:\n'
    printf '  %bmise install npm:ccstatusline%b\n' "$YELLOW" "$RESET"
    printf 'Then re-run: %bmise run statusline%b\n' "$YELLOW" "$RESET"
    exit 0
    ;;
  esac
  if [ ! -f "$WIDGET_TRACKED_SRC" ]; then
    printf '%bmissing %s — is this a full checkout?%b\n' "$RED" "$WIDGET_TRACKED_SRC" "$RESET" >&2
    exit 1
  fi
}

# --- opt-out primitives ------------------------------------------------------
# Per-host opt-out (ruling 2, docs/superpowers/plans/2026-09-19-mise-dotfiles.md):
# there is no `state = "absent"` key, and `{ enabled = false }` alone is
# silently ignored — disabling an inherited [dotfiles] entry needs `enabled =
# false` PLUS a repeated `mode`. config.local.toml is per-host and
# git-ignored already (unlike the old shared .chezmoiignore.tmpl, which had
# to embed the hostname inside sentinel-delimited lines because ONE file was
# committed for every host) — so nothing here is hostname-conditional; the
# sentinel block just marks OUR entry as ours to add/remove idempotently
# without disturbing anything else a human or another tool put in
# config.local.toml.

optout_present() {
  [ -f "$LOCAL_CONFIG" ] && grep -qxF "$SENTINEL_START" "$LOCAL_CONFIG"
}

optout_add() {
  if optout_present; then return 0; fi
  if [ ! -f "$LOCAL_CONFIG" ]; then
    printf '# %s — per-host overrides, git-ignored (see CLAUDE.md)\n' "$(basename "$LOCAL_CONFIG")" >"$LOCAL_CONFIG"
  fi
  if ! grep -qxF '[dotfiles]' "$LOCAL_CONFIG"; then
    {
      echo
      echo '[dotfiles]'
    } >>"$LOCAL_CONFIG"
  fi
  local tmp
  tmp="$(mktemp)"
  awk -v start="$SENTINEL_START" -v end="$SENTINEL_END" -v target="$WIDGET_TARGET" -v source="$WIDGET_SOURCE" '
    $0 == "[dotfiles]" && !done {
      print
      print start
      printf "\"%s\" = { source = \"%s\", mode = \"copy\", enabled = false }\n", target, source
      print end
      done = 1
      next
    }
    { print }
  ' "$LOCAL_CONFIG" >"$tmp"
  mv "$tmp" "$LOCAL_CONFIG"
}

optout_remove() {
  if ! optout_present; then return 0; fi
  local tmp
  tmp="$(mktemp)"
  awk -v start="$SENTINEL_START" -v end="$SENTINEL_END" '
    $0 == start { inblock = 1; next }
    $0 == end   { inblock = 0; next }
    inblock { next }
    { print }
  ' "$LOCAL_CONFIG" >"$tmp"
  mv "$tmp" "$LOCAL_CONFIG"
}

# --- options -----------------------------------------------------------------

option_use_tracked() {
  local tracked_content
  tracked_content="$(cat "$WIDGET_TRACKED_SRC")"
  # Empty tracked widget config (the initial `{}` seed) — bail with a hint
  # instead of applying an empty config over the user's local one.
  if [ "$(printf '%s' "$tracked_content" | tr -d '[:space:]')" = '{}' ]; then
    printf '%bTracked widget config is empty (just `{}`).%b Pick option 3 first to seed it from a real configuration.\n' "$YELLOW" "$RESET"
    return 0
  fi
  if optout_present; then
    printf '%bRemoving this host from config.local.toml opt-out...%b\n' "$BOLD" "$RESET"
    optout_remove
  fi
  printf '%bApplying the tracked ccstatusline config...%b\n' "$GREEN" "$RESET"
  # --force: this host's live file may be a real, independent file left over
  # from a prior opt-out (option 2/3) rather than the managed symlink — mise
  # refuses to overwrite a pre-existing real file otherwise (ruling 1). Safe
  # here: a single target, explicitly chosen by the person running this menu
  # — not the fleet-wide `--force-dotfiles` gate bootstrap.sh applies elsewhere.
  mise dot apply --yes --force "$WIDGET_TARGET"
  printf '%bDone.%b\n' "$GREEN" "$RESET"
}
option_this_machine() {
  if ! optout_present; then
    printf '%bOpting this host out of the tracked config (config.local.toml)...%b\n' "$BOLD" "$RESET"
    optout_add
  fi
  # Once opted out, mise no longer manages the target — if it's still a
  # symlink an OLD chezmoi-era deploy (or a pre-I4 host that never re-applied
  # after `mode` flipped to copy) left behind, materialize it into a real,
  # independent file before the TUI edits it in place. Dead on any host
  # bootstrapped since I4/the 2026-09-22 copy-migration (this target — like
  # every `[dotfiles]` entry now — is `copy`, never `symlink`, so a fresh
  # apply never leaves a symlink here to begin with); kept as one-time
  # migration safety for a host that hasn't re-applied yet, harmless
  # (`[ -L ]` on a regular file or nothing is just false) once it has.
  if [ -L "$WIDGET_DEST" ]; then
    local content
    content="$(cat "$WIDGET_DEST")"
    rm -f "$WIDGET_DEST"
    mkdir -p "$(dirname "$WIDGET_DEST")"
    printf '%s' "$content" >"$WIDGET_DEST"
  fi
  printf '%bLaunching ccstatusline TUI...%b\n' "$BOLD" "$RESET"
  if ! ccstatusline </dev/tty; then
    printf '%bTUI exited non-zero or was cancelled — no changes.%b\n' "$YELLOW" "$RESET"
    return 0
  fi
  printf '%bKeep this machine-local config permanently (opt out of future updates)? (y/N): %b' "$BOLD" "$RESET"
  local ans
  read -r ans </dev/tty
  case "${ans,,}" in
  y | yes)
    printf '%bStaying opted out in config.local.toml — future `mise bootstrap`/`mise dot apply` runs will leave this file alone.%b\n' "$GREEN" "$RESET"
    ;;
  *)
    # Reclaim it NOW, not "on the next apply": the TUI just materialized the
    # symlink into a real file, and a later plain `mise dot apply` (or a
    # bulk one, once Task 4 wires `mise bootstrap` into bootstrap.sh) refuses
    # to overwrite a pre-existing real file (ruling 1) — a bulk apply would
    # abort every OTHER dotfile along with it. --force is safe here: a
    # single target the person running this menu just explicitly chose to
    # give up.
    printf '%bRemoving the opt-out and reclaiming the tracked config now...%b\n' "$YELLOW" "$RESET"
    optout_remove
    mise dot apply --yes --force "$WIDGET_TARGET"
    ;;
  esac
}
option_set_global() {
  if ! optout_present; then
    printf '%bOpting this host out of the tracked config while you edit it...%b\n' "$BOLD" "$RESET"
    optout_add
  fi
  # Same one-time migration safety as option_this_machine above — dead on
  # any host bootstrapped since the copy migration.
  if [ -L "$WIDGET_DEST" ]; then
    local content
    content="$(cat "$WIDGET_DEST")"
    rm -f "$WIDGET_DEST"
    mkdir -p "$(dirname "$WIDGET_DEST")"
    printf '%s' "$content" >"$WIDGET_DEST"
  fi
  printf '%bLaunching ccstatusline TUI...%b\n' "$BOLD" "$RESET"
  if ! ccstatusline </dev/tty; then
    printf '%bTUI exited non-zero or was cancelled — no changes.%b\n' "$YELLOW" "$RESET"
    return 0
  fi
  # NOTE: only the widget config is captured back. ~/.claude/settings.json is
  # NOT touched here — ccstatusline's TUI "Install to Claude Code" path
  # overwrites that file with a statusLine-only block, which would strip
  # every other key on every save. The statusLine command mise enforces
  # there is edited directly in dotfiles/claude/settings.enforced.json (see
  # scripts/lib/claude-settings-merge.sh); the pin is `npm:ccstatusline` in
  # config.owned.toml.
  # Remove the opt-out BEFORE `mise dot add`: while it's still active,
  # config.local.toml's disabled entry (not config.owned.toml's real one) is
  # what mise sees for this target, so `mise dot add` doesn't recognize it
  # as already-managed and seeds a brand new entry instead (verified in a
  # scratch config) — remove it first so `add` updates the real source.
  printf '%bRemoving the opt-out — every host converges back onto the tracked config on its next apply...%b\n' "$BOLD" "$RESET"
  optout_remove
  printf '%bPulling this machine'"'"'s widget config back into the tracked source...%b\n' "$GREEN" "$RESET"
  mise dot add --yes "$WIDGET_TARGET"
  cd "$REPO_ROOT"
  # config.local.toml is never committed — .gitignore'd on purpose (per-host).
  git add "$WIDGET_SOURCE"
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
  printf '\n%bccstatusline setup%b (host: %b%s%b)\n' \
    "$BOLD" "$RESET" "$YELLOW" "$HOST" "$RESET"
  printf '  1) Use the tracked status line (same as every host)\n'
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
