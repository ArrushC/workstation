#!/usr/bin/env bash
# mise-install.sh — install every tool this host's config set (miserc.toml) declares.
# It first checks there is room for them (check_disk below).
#
# node's npm postinstall carries the language servers; mise re-runs it only on
# a (re)install, so a changed postinstall string with an unchanged node pin
# would otherwise never land. Marker = cksum of node's declaration under
# ~/.local/state/workstation/; when node was ALREADY installed and the marker
# is stale, node is force-reinstalled once. Then `mise prune` drops versions no
# config references. User-level; never sudo. Used directly by bootstrap.sh's
# apply(), ahead of `mise bootstrap` itself.
#
# The declaration is read with an explicit `-f config.toml`: a bare
# `mise config get tools.node` reads only the HIGHEST-PRECEDENCE loaded file,
# which is config.linux.toml (it declares no node),
# so it errors and the cksum would silently be the empty-input constant —
# freezing the marker and disabling the re-run mechanism entirely. An
# unreadable declaration force-reinstalls instead of assuming "unchanged":
# re-running the postinstall is cheap, skipping it leaves stale LSP servers.
set -euo pipefail
repo="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
state="${XDG_STATE_HOME:-$HOME/.local/state}/workstation"
mkdir -p "$state"
export MISE_YES=1

# Room for the tools before installing any: a disk that fills mid-install leaves
# tools half-extracted that mise still counts as installed (a go without its std
# sources). The budget is what a fresh install writes on Linux, as
# measured by .github/workflows/disk-budget.yml into disk-budget.toml; less what
# is already installed, plus 1 GB for the new versions an update installs before
# `mise prune` drops the old ones. WORKSTATION_SKIP_DISK_CHECK=1 goes ahead
# anyway; a missing budget or an unreadable df skips the check.
gb() { awk -v mb="$1" 'BEGIN { printf "%.1f GB", mb / 1024 }'; }
check_disk() {
  local data budget used=0 kb need probe have
  data="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
  budget="$(tr -d '\r' <"$repo/disk-budget.toml" 2>/dev/null | sed -n 's/^linux *= *\([0-9][0-9]*\) *$/\1/p' || true)"
  if [ -z "$budget" ]; then
    printf '  ! disk check skipped: no linux figure in %s\n' "$repo/disk-budget.toml" >&2
    return 0
  fi
  if [ -d "$data/installs" ]; then
    kb="$(du -sk "$data/installs" 2>/dev/null | cut -f1)" || true
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
  } >&2
  exit 1
}
check_disk

had_node=false
if mise where node >/dev/null 2>&1; then had_node=true; fi

mise install

if mise where node >/dev/null 2>&1; then
  decl="$(mise config get -f "$repo/config.toml" tools.node 2>/dev/null || true)"
  if [ -z "$decl" ]; then
    printf '  ! could not read tools.node from %s — forcing the node reinstall so the npm postinstall cannot be silently skipped\n' \
      "$repo/config.toml" >&2
    sum=""
  else
    sum="$(printf '%s' "$decl" | cksum | cut -d' ' -f1)"
  fi
  if $had_node && { [ -z "$sum" ] || [ ! -f "$state/node-postinstall.$sum" ]; }; then
    printf '  node already installed but its declaration changed — reinstalling so the npm postinstall re-runs\n'
    mise install --force node
  fi
  # No marker when the declaration was unreadable: the next run must retry,
  # never settle on a constant name.
  if [ -n "$sum" ]; then
    rm -f "$state"/node-postinstall.*
    : >"$state/node-postinstall.$sum"
  fi
fi

mise prune
mise reshim
printf '  ✓ mise tools installed\n'
