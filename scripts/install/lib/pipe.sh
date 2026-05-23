#!/usr/bin/env bash
# pipe.sh — run an upstream "curl | sh" installer, but auditably.
#
# Usage:
#   pipe.sh <name> <url> [-- <installer args>...]
#
#   name  Display label for the tool (e.g. chezmoi). Used in errors only.
#   url   URL of the installer script.
#   --    Optional separator before installer-specific arguments.
#
# Env:
#   DEST  Destination directory (passed via installer flags — chezmoi takes
#         -b, others may not respect it).
#
# We download the installer to a temp file and then run it with stdin
# closed. That's strictly more auditable than `curl | sh` (you could `cat
# $tmp` mid-run if something fails) and avoids race conditions in the
# curl→sh pipeline.

set -euo pipefail

: "${DEST:?pipe.sh: DEST not set}"

if (( $# < 2 )); then
  printf 'pipe.sh: usage: %s <name> <url> [-- args...]\n' "$0" >&2
  exit 2
fi

name="$1"; shift
url="$1"; shift
if [[ "${1:-}" == '--' ]]; then shift; fi
# Remaining "$@" are installer args.

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$url"
sh "$tmp" "$@" </dev/null
