#!/usr/bin/env bash
# zellij-plugin.sh — install a zellij WASM plugin into the user's plugin dir.
#
# Invoked by makefile/tools.mk's USER_TOOL entries (NOT directly).
#
# Usage:
#   zellij-plugin.sh <name> <url>
#
#   name  Plugin basename; lands at $ZELLIJ_PLUGIN_DIR/<name>.wasm
#   url   Direct URL to the .wasm release asset.
#
# Env:
#   ZELLIJ_PLUGIN_DIR  Destination dir (default: ~/.config/zellij/plugins).
#     That default is zellij's own lookup path for RELATIVE `file:` plugin
#     locations, which is why config.kdl can say `file:<name>.wasm` on every
#     host without a template — and why the permission-cache key
#     (~/.cache/zellij/permissions.kdl is keyed by that location string) is
#     identical fleet-wide. An absolute or ~ path would expand per host.
#
# USER-LEVEL like pip.sh — never under sudo. ~/.config/zellij is chezmoi's
# target dir; chezmoi leaves files it does not manage alone, so the plugin
# survives every `chezmoi apply`.
#
# Downloads to a temp file, checks the WebAssembly magic (\0asm) so a GitHub
# error page or a truncated download can never be installed, then install(1)s
# with mode 0644 (plugins are data zellij loads, not executables).

set -euo pipefail

if (($# != 2)); then
  printf 'zellij-plugin.sh: usage: %s <name> <url>\n' "$0" >&2
  exit 2
fi

name="$1"
url="$2"
dir="${ZELLIJ_PLUGIN_DIR:-$HOME/.config/zellij/plugins}"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$url"

magic=$(head -c 4 "$tmp" | od -An -tx1 | tr -d ' \n')
if [ "$magic" != "0061736d" ]; then
  printf 'zellij-plugin.sh: %s is not a WebAssembly module (magic %s) — refusing to install\n' "$url" "$magic" >&2
  exit 1
fi

install -D -m 0644 "$tmp" "$dir/$name.wasm"
