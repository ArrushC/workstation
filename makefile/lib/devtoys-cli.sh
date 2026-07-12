#!/usr/bin/env bash
# devtoys-cli.sh — install DevToys CLI (the command-line half of DevToys) from
# the self-contained portable release zip published by DevToys-app/DevToys.
#
# Usage:
#   devtoys-cli.sh <version>
#
#   version   Release version WITHOUT the leading 'v', e.g. 2.0.9.0 (tags are
#             vX.Y.Z.0).
#
# Env:
#   DEST      Destination directory (required; provided by scope.mk).
#
# Why the *_portable zip (not the plain CLI zip): the plain zip is
# framework-dependent (needs a system .NET 8 runtime); the portable zip is
# self-contained. Why not EGET_TOOL: the zip is NOT a single binary — the
# single-file DevToys.CLI executable REQUIRES its sibling Plugins/ tree
# (Plugins/DevToys.Tools), so the whole tree must stay together.
#
# Layout mirrors lib/pwndbg.sh: extract the whole tree to
# $DEST/_devtoys-cli-<ver>/, strip older _devtoys-cli-* trees first
# (idempotent re-install), chmod the executable (zip extraction drops +x),
# gate on verify-binary.sh, then symlink $DEST/devtoys.cli -> the executable
# (command-name parity with Windows, where DevToys.CLI.exe is invoked as
# `devtoys.cli`). Sudo is the Makefile's job (the SUDO wrapper from scope.mk).

set -euo pipefail

: "${DEST:?devtoys-cli.sh: DEST not set}"

if (($# != 1)); then
  printf 'devtoys-cli.sh: usage: %s <version>\n' "$0" >&2
  exit 2
fi

version="$1"

arch="$(uname -m)"
case "$arch" in
x86_64) dt_arch="x64" ;;
aarch64 | arm64) dt_arch="arm" ;;
*)
  printf 'devtoys-cli.sh: unsupported arch %s\n' "$arch" >&2
  exit 1
  ;;
esac

zip="devtoys.cli_linux_${dt_arch}_portable.zip"
url="https://github.com/DevToys-app/DevToys/releases/download/v${version}/${zip}"
install_dir="${DEST}/_devtoys-cli-${version}"

mkdir -p "$DEST"

# Strip any older _devtoys-cli-* trees so re-installs don't accumulate.
for old in "$DEST"/_devtoys-cli-*; do
  [ -e "$old" ] || continue # no matches → glob stays literal, skip
  rm -rf "$old"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf '  ↓ %s\n' "$url"
curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/$zip" "$url"

printf '  ↪ extracting to %s\n' "$install_dir"
mkdir -p "$install_dir"
unzip -q "$tmp/$zip" -d "$install_dir"

# DevToys.CLI sits at the zip root today; tolerate a wrapper dir (cf. the
# tree-layout flatten in bootstrap.ps1 and the find in pwndbg.sh).
exe="$install_dir/DevToys.CLI"
if [ ! -f "$exe" ]; then
  exe="$(find "$install_dir" -type f -name 'DevToys.CLI' 2>/dev/null | head -1)"
fi
if [ -z "$exe" ] || [ ! -f "$exe" ]; then
  printf 'devtoys-cli.sh: DevToys.CLI not found under %s\n' "$install_dir" >&2
  exit 1
fi
chmod 0755 "$exe" # zip extraction drops the executable bit

# Same non-executing capability gate the TOOL/EGET_TOOL macros apply: wrong
# arch / missing loader / too-new glibc fails the install before the stamp.
"$(dirname "$0")/verify-binary.sh" "$exe"

ln -sfn "$exe" "$DEST/devtoys.cli"
printf '  ✓ devtoys.cli %s ready at %s/devtoys.cli\n' "$version" "$DEST"
