#!/usr/bin/env bash
# node.sh — install Node.js (+ npm + npx, and corepack on Node <25) from the
# official nodejs.org tarball.
#
# Usage:
#   node.sh <version>
#
#   version   Numeric version (no leading 'v'), e.g. 24.16.0.
#
# Env:
#   DEST      Destination directory (required; provided by scope.mk).
#
# Behavior:
#   1. Detect arch (x86_64 -> x64, aarch64/arm64 -> arm64).
#   2. Download https://nodejs.org/dist/v<VER>/node-v<VER>-linux-<ARCH>.tar.xz.
#   3. Extract to $DEST/_node-v<VER>/  (full tree — node + npm + npx use
#      relative symlinks into ../lib/node_modules/, so we can't just pluck
#      out the binaries).
#   4. Strip any older $DEST/_node-* trees first (idempotent re-install,
#      no orphan version dirs after bumps).
#   5. Symlink $DEST/{node,npm,npx} (+ corepack on Node <25) ->
#      _node-v<VER>/bin/<binary>, dropping any stale symlink the new tarball
#      no longer ships (corepack was unbundled in Node 25).
#
# Sudo is the Makefile's job (SUDO wrapper from scope.mk); this script
# assumes it can write to $DEST and read DEST from env.

set -euo pipefail

: "${DEST:?node.sh: DEST not set}"

if (($# != 1)); then
  printf 'node.sh: usage: %s <version>\n' "$0" >&2
  exit 2
fi

version="$1"

arch="$(uname -m)"
case "$arch" in
x86_64) node_arch="x64" ;;
aarch64 | arm64) node_arch="arm64" ;;
*)
  printf 'node.sh: unsupported arch %s\n' "$arch" >&2
  exit 1
  ;;
esac

tarball="node-v${version}-linux-${node_arch}.tar.xz"
url="https://nodejs.org/dist/v${version}/${tarball}"
install_dir="${DEST}/_node-v${version}"

mkdir -p "$DEST"

# Strip any older _node-* trees so re-installs don't accumulate.
for old in "$DEST"/_node-*; do
  [ -e "$old" ] || continue # no matches → glob stays literal, skip
  rm -rf "$old"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf '  ↓ %s\n' "$url"
curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/$tarball" "$url"

printf '  ↪ extracting to %s\n' "$install_dir"
tar -xJf "$tmp/$tarball" -C "$tmp"
mv "$tmp/node-v${version}-linux-${node_arch}" "$install_dir"

# corepack was removed from the Node release tarballs in v25, so only link the
# binaries this tarball actually ships; clear any stale symlink the tarball no
# longer provides (e.g. a corepack left over from a pre-25 install) so nothing
# dangling remains in $DEST.
for bin in node npm npx corepack; do
  if [ -e "${install_dir}/bin/${bin}" ]; then
    ln -sfn "${install_dir}/bin/${bin}" "${DEST}/${bin}"
  else
    rm -f "${DEST}/${bin}"
  fi
done

printf '  ✓ node-v%s ready at %s/node\n' "$version" "$DEST"
