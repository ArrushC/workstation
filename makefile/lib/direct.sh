#!/usr/bin/env bash
# direct.sh — install a raw binary from a single URL.
#
# Usage:
#   direct.sh <name> <url>
#
#   name  Destination filename under $DEST (e.g. nb, jq, broot).
#   url   Direct URL to the binary (no archive).
#
# Env:
#   DEST  Destination directory (required).
#
# Downloads to a temp file first so a half-downloaded binary can't be
# observed under $DEST. install(1) does an atomic-ish move with mode 0755.

set -euo pipefail

: "${DEST:?direct.sh: DEST not set}"

if (( $# != 2 )); then
  printf 'direct.sh: usage: %s <name> <url>\n' "$0" >&2
  exit 2
fi

name="$1"
url="$2"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$url"
install -D -m 0755 "$tmp" "$DEST/$name"
