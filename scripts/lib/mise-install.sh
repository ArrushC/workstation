#!/usr/bin/env bash
# mise-install.sh — install every tool the active MISE_ENV declares.
#
# node's npm postinstall carries the language servers; mise re-runs it only on
# a (re)install, so a changed postinstall string with an unchanged node pin
# would otherwise never land. Marker = cksum of node's declaration under
# ~/.local/state/workstation/; when node was ALREADY installed and the marker
# is stale, node is force-reinstalled once. Then `mise prune` drops versions no
# config references. User-level; never sudo. Used directly by bootstrap.sh's
# run_bootstrap() (PR2+), ahead of `mise bootstrap` itself.
#
# The declaration is read with an explicit `-f config.owned.toml`: a bare
# `mise config get tools.node` reads only the HIGHEST-PRECEDENCE loaded file,
# which since PR2 is config.host.toml/config.wsl.toml (they declare no tools),
# so it errors and the cksum would silently be the empty-input constant —
# freezing the marker and disabling the re-run mechanism entirely. An
# unreadable declaration force-reinstalls instead of assuming "unchanged":
# re-running the postinstall is cheap, skipping it leaves stale LSP servers.
set -euo pipefail
: "${MISE_ENV:?mise-install.sh: MISE_ENV must be set (scripts/lib/mise-env.sh <dev|prod>)}"
repo="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
state="${XDG_STATE_HOME:-$HOME/.local/state}/workstation"
mkdir -p "$state"
export MISE_YES=1

had_node=false
if mise where node >/dev/null 2>&1; then had_node=true; fi

mise install

if mise where node >/dev/null 2>&1; then
  decl="$(mise config get -f "$repo/config.owned.toml" tools.node 2>/dev/null || true)"
  if [ -z "$decl" ]; then
    printf '  ! could not read tools.node from %s — forcing the node reinstall so the npm postinstall cannot be silently skipped\n' \
      "$repo/config.owned.toml" >&2
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
printf '  ✓ mise tools installed (MISE_ENV=%s)\n' "$MISE_ENV"
