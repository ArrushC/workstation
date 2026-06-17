#!/usr/bin/env bash
# archive.sh — install one or more binaries from a release archive.
#
# Downloads URL, extracts based on file extension (.tar.gz/.tar.bz2/.tar.xz/
# .zip), then for each name in the colon-separated binary spec finds the
# matching file inside the extracted tree and installs it to $DEST with mode
# 0755.
#
# Usage:
#   archive.sh <binary_spec> <url>
#
#   binary_spec  Single name, or colon-separated for multi-binary archives:
#                  'gitui'                   install just gitui
#                  'yazi:ya'                 install BOTH yazi AND ya from one archive
#                  'sg:ast-grep'             install BOTH sg AND ast-grep
#                  'nnn-musl-static=nnn'     find `nnn-musl-static`, install as `nnn`
#
#   url          Direct URL to the archive. Format inferred from extension.
#
# Env:
#   DEST         Destination directory for binaries (required).
#
# The find-based binary discovery handles every archive layout we've seen:
# top-level (lazygit), `./binary` (gitui, eza), wrapper directory (glow,
# fd, bat, btop), nested `bin/` (gh). No `include:` filter to misalign, no
# guessing about the internal path.

set -euo pipefail

: "${DEST:?archive.sh: DEST not set}"

if (($# != 2)); then
  printf 'archive.sh: usage: %s <binary_spec> <url>\n' "$0" >&2
  exit 2
fi

bin_spec="$1"
url="$2"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

archive="$tmp/archive"
curl -fsSL --retry 3 --retry-delay 2 -o "$archive" "$url"

case "$url" in
*.tar.gz | *.tgz) tar -xzf "$archive" -C "$tmp" ;;
*.tar.bz2 | *.tbz2) tar -xjf "$archive" -C "$tmp" ;;
*.tar.xz | *.txz) tar -xJf "$archive" -C "$tmp" ;;
*.zip) unzip -q "$archive" -d "$tmp" ;;
*)
  printf 'archive.sh: unrecognised archive extension in %s\n' "$url" >&2
  exit 1
  ;;
esac
rm -f "$archive"

IFS=':' read -ra names <<<"$bin_spec"
for name in "${names[@]}"; do
  src="${name%%=*}" # part before '=' (whole string if no '=')
  dst="${name##*=}" # part after  '=' (whole string if no '=')
  # -print -quit stops the walk on first match (faster than | head -1)
  found=$(find "$tmp" -type f -name "$src" -print -quit)
  if [[ -z "$found" ]]; then
    printf "archive.sh: binary '%s' not found inside %s\n" "$src" "$url" >&2
    exit 1
  fi
  install -D -m 0755 "$found" "$DEST/$dst"
done
