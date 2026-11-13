#!/usr/bin/env bash
# mise-install.sh — install every tool this host's config set (miserc.toml) declares.
# It first checks there is room for them (check_disk below). It never prunes: the
# published Python/LSP environments still run on the old runtimes until the
# post-tools hook moves them, so cleanup is `mise run tool-env --clean`.
set -euo pipefail
repo="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
export MISE_YES=1

# Room for the tools before installing any: a disk that fills mid-install leaves
# tools half-extracted that mise still counts as installed (a go without its std
# sources). The budget is what a fresh install writes on Linux, as
# measured by .github/workflows/disk-budget.yml into disk-budget.toml; less the
# installed versions the config still asks for, plus 1 GB of headroom. A
# superseded version doesn't count: an update installs its replacement beside it,
# and counting it let a pin bump of the large tools (zig, pwndbg) pass with 1.8 GB
# free and fill the disk. Without jq or a readable `mise ls`, everything under
# `installs` counts, as before. Nothing to install needs no room: the budget
# also counts the caches, which `installs` doesn't, so a host with every tool
# already installed would otherwise still need about 2 GB free for an update that
# writes nothing. WORKSTATION_SKIP_DISK_CHECK=1 goes ahead anyway; a missing
# budget or an unreadable df skips the check.
gb() { awk -v mb="$1" 'BEGIN { printf "%.1f GB", mb / 1024 }'; }
# KB held by the installed versions the config asks for (mise's `active`); fails
# when that can't be told.
current_kb() {
  local paths path kb total=0
  command -v jq >/dev/null 2>&1 || return 1
  paths="$(mise ls --installed --json 2>/dev/null |
    jq -r '.[][] | select(.installed and .active) | .install_path' 2>/dev/null)" || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    kb="$(du -sk "$path/" 2>/dev/null | cut -f1)" || true
    total=$((total + ${kb:-0}))
  done <<<"$paths"
  printf '%s\n' "$total"
}
check_disk() {
  local data budget used=0 kb need probe have
  # Exit 1 when something would install (or mise fails), which keeps the check.
  if mise install --dry-run-code >/dev/null 2>&1; then return 0; fi
  data="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
  budget="$(tr -d '\r' <"$repo/disk-budget.toml" 2>/dev/null | sed -n 's/^linux *= *\([0-9][0-9]*\) *$/\1/p' || true)"
  if [ -z "$budget" ]; then
    printf '  ! disk check skipped: no linux figure in %s\n' "$repo/disk-budget.toml" >&2
    return 0
  fi
  if [ -d "$data/installs" ]; then
    kb="$(current_kb)" || kb=""
    if [ -z "$kb" ]; then kb="$(du -sk "$data/installs" 2>/dev/null | cut -f1)" || true; fi
    used=$((${kb:-0} / 1024))
  fi
  need=$((budget > used ? budget - used + 1024 : 1024))
  probe="$data"
  until [ -e "$probe" ]; do probe="$(dirname "$probe")"; done
  have="$(df -Pk "$probe" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }')" || true
  if [ -z "$have" ] || [ "$have" -ge "$need" ]; then return 0; fi
  if [ "${WORKSTATION_SKIP_DISK_CHECK:-}" = 1 ]; then
    printf '  ! %s free for the mise tools, about %s needed; WORKSTATION_SKIP_DISK_CHECK=1, so going ahead\n' \
      "$(gb "$have")" "$(gb "$need")" >&2
    return 0
  fi
  {
    printf '  ✗ Not enough disk space for the mise tools: %s free on the filesystem holding %s, about %s needed.\n' \
      "$(gb "$have")" "$data" "$(gb "$need")"
    printf '    Nothing was installed. Free some space (the largest folders in %s are below), then re-run.\n' "$HOME"
    printf '    WORKSTATION_SKIP_DISK_CHECK=1 skips this check.\n'
    du -xh --max-depth=1 "$HOME" 2>/dev/null | sort -rh | sed -n '2,6p' | sed 's/^/      /' || true
    # Caches their tools rebuild on demand: safe to clear, and often all an update is short of.
    printf '    Caches that are safe to clear (they are rebuilt on demand):\n'
    printf '      mise cache clear\n'
    if command -v uv >/dev/null 2>&1; then printf '      uv cache clean\n'; fi
    if command -v go >/dev/null 2>&1; then printf '      go clean -cache\n'; fi
    printf '    After a successful update, this removes the old tool versions it leaves behind:\n'
    printf '      mise run tool-env --clean\n'
  } >&2
  exit 1
}
check_disk

mise install
mise reshim
printf '  ✓ mise tools installed\n'
