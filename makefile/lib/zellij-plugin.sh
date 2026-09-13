#!/usr/bin/env bash
# zellij-plugin.sh — install a zellij WASM plugin where zellij looks for it.
#
# Invoked by makefile/tools.mk's USER_TOOL entries (NOT directly).
#
# Usage:
#   zellij-plugin.sh <name> <url>
#
#   name  Plugin basename; lands at <plugin dir>/<name>.wasm
#   url   URL of the .wasm release asset (https://…, or file:///… in tests).
#
# Where the file goes — and why it matters:
#   zellij resolves a RELATIVE `file:<name>.wasm` plugin location (the form
#   config.kdl uses, so the ~/.cache/zellij/permissions.kdl key is identical
#   on every host) by trying, in order: the system dir (/usr/share/zellij/
#   plugins), then ITS DATA DIR's plugins folder (~/.local/share/zellij/
#   plugins — what `zellij setup --check` prints as [PLUGIN DIR]), then the
#   bare name against the cwd. It never looks in ~/.config/zellij/plugins —
#   the first cut of this script installed there and every session showed
#   "ERROR IN PLUGIN" (2026-09-13). So the destination is, in order:
#     1. $ZELLIJ_PLUGIN_DIR if set (tests / odd hosts),
#     2. the [PLUGIN DIR] zellij itself reports, when zellij is on PATH,
#     3. $HOME/.local/share/zellij/plugins (zellij's default data dir).
#   Verify a load with the LOG, not with `zellij action dump-layout` — the
#   latter echoes the location string whether or not the file was found:
#     grep "Loaded plugin 'zjstatus.wasm'" /tmp/zellij-$UID/zellij-log/zellij.log
#
# USER-LEVEL like pip.sh — never under sudo. Nothing under ~/.local/share is
# chezmoi-managed, so `chezmoi apply` never touches the plugin.
#
# Downloads to a temp file, checks the WebAssembly magic (\0asm) so a GitHub
# error page or a truncated download can never be installed, then install(1)s
# with mode 0644 (plugins are data zellij loads, not executables). Also removes
# a stale copy left by the first cut under ~/.config/zellij/plugins/.

set -euo pipefail

if (($# != 2)); then
  printf 'zellij-plugin.sh: usage: %s <name> <url>\n' "$0" >&2
  exit 2
fi

name="$1"
url="$2"

dir="${ZELLIJ_PLUGIN_DIR:-}"
if [ -z "$dir" ] && command -v zellij >/dev/null 2>&1; then
  dir=$(timeout 10 zellij setup --check 2>/dev/null | sed -n 's/^\[PLUGIN DIR\]: "\(.*\)"$/\1/p' | head -1 || true)
fi
: "${dir:=$HOME/.local/share/zellij/plugins}"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$url"

magic=$(head -c 4 "$tmp" | od -An -tx1 | tr -d ' \n')
if [ "$magic" != "0061736d" ]; then
  printf 'zellij-plugin.sh: %s is not a WebAssembly module (magic %s) — refusing to install\n' "$url" "$magic" >&2
  exit 1
fi

install -D -m 0644 "$tmp" "$dir/$name.wasm"
# First-cut location (never resolved by zellij): drop the stale copy, and the
# directory once empty so the wrong path stops looking like a real one.
rm -f "$HOME/.config/zellij/plugins/$name.wasm"
rmdir "$HOME/.config/zellij/plugins" 2>/dev/null || true
