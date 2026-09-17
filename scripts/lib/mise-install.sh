#!/usr/bin/env bash
# mise-install.sh — install every tool the active MISE_ENV declares.
#
# node's npm postinstall carries the language servers; mise re-runs it only on
# a (re)install, so a changed postinstall string with an unchanged node pin
# would otherwise never land. Marker = cksum of node's declaration under
# ~/.local/state/workstation/; when node was ALREADY installed and the marker
# is stale, node is force-reinstalled once. Then `mise prune` drops versions no
# config references. User-level; never sudo. Used by `make tools` (PR1) and by
# tasks/bootstrap (PR2+).
set -euo pipefail
: "${MISE_ENV:?mise-install.sh: MISE_ENV must be set (scripts/lib/mise-env.sh <dev|prod>)}"
state="${XDG_STATE_HOME:-$HOME/.local/state}/workstation"
mkdir -p "$state"
export MISE_YES=1

had_node=false
if mise where node >/dev/null 2>&1; then had_node=true; fi

mise install

if mise where node >/dev/null 2>&1; then
  decl="$(mise config get tools.node 2>/dev/null || true)"
  sum="$(printf '%s' "$decl" | cksum | cut -d' ' -f1)"
  if $had_node && [ ! -f "$state/node-postinstall.$sum" ]; then
    printf '  node already installed but its declaration changed — reinstalling so the npm postinstall re-runs\n'
    mise install --force node
  fi
  rm -f "$state"/node-postinstall.*
  : >"$state/node-postinstall.$sum"
fi

mise prune
mise reshim
printf '  ✓ mise tools installed (MISE_ENV=%s)\n' "$MISE_ENV"
