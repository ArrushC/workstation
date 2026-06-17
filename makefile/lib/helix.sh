#!/usr/bin/env bash
# helix.sh — install the helix editor: the `hx` binary AND its runtime tree.
#
# Helix is the only tool in the installer that lays down more than just a
# binary. The runtime/ directory (grammars, themes, queries) must land at
# $HELIX_RUNTIME_DEST/runtime — helix looks there for syntax highlighting
# and language servers. Putting just the binary somewhere isn't enough.
#
# Usage:
#   helix.sh <version>
#
#   version  Release tag, e.g. 25.07.1 (no leading v).
#
# Env:
#   DEST                Where the `hx` binary goes (required).
#   HELIX_RUNTIME_DEST  Parent dir for runtime/ (required). The runtime
#                       subdir is placed *inside* this, not next to it —
#                       i.e. $HELIX_RUNTIME_DEST/runtime/ is the final
#                       location of grammars.so / themes / etc.

set -euo pipefail

: "${DEST:?helix.sh: DEST not set}"
: "${HELIX_RUNTIME_DEST:?helix.sh: HELIX_RUNTIME_DEST not set}"

if (($# != 1)); then
  printf 'helix.sh: usage: %s <version>\n' "$0" >&2
  exit 2
fi

version="$1"
url="https://github.com/helix-editor/helix/releases/download/${version}/helix-${version}-x86_64-linux.tar.xz"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

archive="$tmp/helix.tar.xz"
curl -fsSL --retry 3 --retry-delay 2 -o "$archive" "$url"
tar -xJf "$archive" -C "$tmp"
rm -f "$archive"

# Helix tarball unpacks to helix-<version>-x86_64-linux/{hx,runtime,...}
src_dir=$(find "$tmp" -maxdepth 1 -type d -name "helix-*" -print -quit)
if [[ -z "$src_dir" ]]; then
  printf 'helix.sh: extracted layout not recognised — no helix-* directory under %s\n' "$tmp" >&2
  exit 1
fi

# Binary
install -D -m 0755 "$src_dir/hx" "$DEST/hx"

# Runtime tree. Wipe-and-replace semantics so grammars/themes removed
# upstream don't linger. cp -a preserves perms + symlinks.
mkdir -p "$HELIX_RUNTIME_DEST"
rm -rf "$HELIX_RUNTIME_DEST/runtime"
cp -a "$src_dir/runtime" "$HELIX_RUNTIME_DEST/runtime"
