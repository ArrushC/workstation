#!/usr/bin/env bash
# test-zellij-plugin.sh — makefile/lib/zellij-plugin.sh must land the plugin
# where zellij's RELATIVE `file:<name>.wasm` lookup finds it: the data dir
# (~/.local/share/zellij/plugins), never ~/.config/zellij/plugins. The first
# cut installed to the latter and every session showed "ERROR IN PLUGIN"
# (2026-09-13) while `zellij action dump-layout` looked fine. Offline: a fake
# module with the \0asm magic served over file://, in a scratch HOME.
#
# Run by scripts/check-invariants.sh (check_zellij_plugin_installer); usable
# on its own: bash scripts/test-zellij-plugin.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/makefile/lib/zellij-plugin.sh"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
printf '\0asm\1\0\0\0' >"$scratch/fake.wasm"
printf 'not wasm' >"$scratch/fake.html"
mkdir -p "$scratch/home/.config/zellij/plugins"
: >"$scratch/home/.config/zellij/plugins/probe.wasm" # stale first-cut copy

# 1. lands in the data dir, with the stale copy gone
HOME="$scratch/home" ZELLIJ_PLUGIN_DIR='' "$lib" probe "file://$scratch/fake.wasm"
[ -f "$scratch/home/.local/share/zellij/plugins/probe.wasm" ] ||
  {
    echo "FAIL: plugin not at \$HOME/.local/share/zellij/plugins/probe.wasm"
    exit 1
  }
[ ! -e "$scratch/home/.config/zellij/plugins/probe.wasm" ] ||
  {
    echo "FAIL: stale ~/.config/zellij/plugins copy not removed"
    exit 1
  }
[ ! -e "$scratch/home/.config/zellij/plugins" ] ||
  {
    echo "FAIL: emptied ~/.config/zellij/plugins dir not removed"
    exit 1
  }

# 2. honours an explicit ZELLIJ_PLUGIN_DIR
HOME="$scratch/home" ZELLIJ_PLUGIN_DIR="$scratch/custom" "$lib" probe "file://$scratch/fake.wasm"
[ -f "$scratch/custom/probe.wasm" ] || {
  echo "FAIL: ZELLIJ_PLUGIN_DIR override ignored"
  exit 1
}

# 3. refuses a non-wasm payload (a GitHub error page, a truncated download)
if HOME="$scratch/home" ZELLIJ_PLUGIN_DIR="$scratch/bad" "$lib" probe "file://$scratch/fake.html" 2>/dev/null; then
  echo "FAIL: non-wasm payload was installed"
  exit 1
fi
[ ! -e "$scratch/bad/probe.wasm" ] || {
  echo "FAIL: non-wasm payload left on disk"
  exit 1
}

echo "PASS: zellij-plugin.sh installs to the data dir, honours ZELLIJ_PLUGIN_DIR, rejects non-wasm"
