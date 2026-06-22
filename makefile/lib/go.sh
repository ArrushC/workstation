#!/usr/bin/env bash
# go.sh — install the Go toolchain from the official go.dev tarball.
#
# Usage:   go.sh <version>        (version with no leading 'go', e.g. 1.24.4)
# Env:     DEST                   destination dir (required; from scope.mk)
#
# Extracts the full tree to $DEST/_go-<ver>/ (go needs its bundled std + pkg
# next to the binary, like node), strips older _go-* trees, then symlinks
# $DEST/{go,gofmt} -> _go-<ver>/bin/<binary>. Sudo is the Makefile's job.
set -euo pipefail

: "${DEST:?go.sh: DEST not set}"

if (($# != 1)); then
  printf 'go.sh: usage: %s <version>\n' "$0" >&2
  exit 2
fi

version="$1"

arch="$(uname -m)"
case "$arch" in
x86_64) go_arch="amd64" ;;
aarch64 | arm64) go_arch="arm64" ;;
*)
  printf 'go.sh: unsupported arch %s\n' "$arch" >&2
  exit 1
  ;;
esac

tarball="go${version}.linux-${go_arch}.tar.gz"
url="https://go.dev/dl/${tarball}"
install_dir="${DEST}/_go-${version}"

mkdir -p "$DEST"

# Strip older _go-* trees so re-installs don't accumulate.
for old in "$DEST"/_go-*; do
  [ -e "$old" ] || continue
  rm -rf "$old"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf '  ↓ %s\n' "$url"
curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/$tarball" "$url"

printf '  ↪ extracting to %s\n' "$install_dir"
tar -xzf "$tmp/$tarball" -C "$tmp" # extracts a top-level ./go/
mv "$tmp/go" "$install_dir"

for bin in go gofmt; do
  if [ -e "${install_dir}/bin/${bin}" ]; then
    ln -sfn "${install_dir}/bin/${bin}" "${DEST}/${bin}"
  else
    rm -f "${DEST}/${bin}"
  fi
done

printf '  ✓ go%s ready at %s/go\n' "$version" "$DEST"
