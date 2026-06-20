#!/usr/bin/env bash
# pwndbg.sh — install pwndbg (a GDB front-end) from the self-contained portable
# release tarball published by pwndbg/pwndbg.
#
# Usage:
#   pwndbg.sh <version>
#
#   version   Release tag (no leading 'v'), e.g. 2026.02.18.
#
# Env:
#   DEST      Destination directory (required; provided by scope.mk).
#
# Why the portable tarball (not ./setup.sh): pwndbg's setup.sh builds a Python
# venv and pulls distro packages, which is neither pinnable nor reproducible.
# The portable tarball bundles its OWN Python + a `pwndbg` launcher, so it
# installs as a single standalone `pwndbg` command and — crucially — does NOT
# touch ~/.gdbinit. Plain `gdb` therefore keeps loading GEF (the chezmoi-tracked
# ~/.gdbinit), and the two front-ends never collide: `gdb` → GEF, `pwndbg` →
# pwndbg.
#
# Layout mirrors lib/node.sh: extract the whole tree to $DEST/_pwndbg-<ver>/,
# strip any older _pwndbg-* trees first (idempotent re-install), then symlink
# $DEST/pwndbg -> the bundled launcher. Sudo is the Makefile's job (the SUDO
# wrapper from scope.mk); this script assumes it can write $DEST and reads DEST
# from env.

set -euo pipefail

: "${DEST:?pwndbg.sh: DEST not set}"

if (($# != 1)); then
  printf 'pwndbg.sh: usage: %s <version>\n' "$0" >&2
  exit 2
fi

version="$1"

arch="$(uname -m)"
case "$arch" in
x86_64) pd_arch="x86_64" ;;
aarch64 | arm64) pd_arch="arm64" ;;
*)
  printf 'pwndbg.sh: unsupported arch %s\n' "$arch" >&2
  exit 1
  ;;
esac

tarball="pwndbg_${version}_${pd_arch}-portable.tar.xz"
url="https://github.com/pwndbg/pwndbg/releases/download/${version}/${tarball}"
install_dir="${DEST}/_pwndbg-${version}"

mkdir -p "$DEST"

# Strip any older _pwndbg-* trees so re-installs don't accumulate.
for old in "$DEST"/_pwndbg-*; do
  [ -e "$old" ] || continue # no matches → glob stays literal, skip
  rm -rf "$old"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf '  ↓ %s\n' "$url"
curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/$tarball" "$url"

printf '  ↪ extracting to %s\n' "$install_dir"
mkdir -p "$install_dir"
tar -xJf "$tmp/$tarball" -C "$install_dir"

# The portable tarball nests everything under a top-level pwndbg/ dir; locate
# the launcher robustly rather than hardcoding the internal path (cf. archive.sh
# walking the extracted tree to find the binary). Prefer a launcher under a
# bin/ dir, then fall back to any file named `pwndbg`.
launcher="$(find "$install_dir" -type f -name pwndbg -path '*bin*' 2>/dev/null | head -1)"
[ -n "$launcher" ] || launcher="$(find "$install_dir" -type f -name pwndbg 2>/dev/null | head -1)"
if [ -z "$launcher" ]; then
  printf 'pwndbg.sh: no pwndbg launcher found under %s\n' "$install_dir" >&2
  exit 1
fi
chmod +x "$launcher" 2>/dev/null || true

ln -sfn "$launcher" "$DEST/pwndbg"
printf '  ✓ pwndbg %s ready at %s/pwndbg\n' "$version" "$DEST"
