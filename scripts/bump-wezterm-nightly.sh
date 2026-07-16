#!/usr/bin/env bash
# bump-wezterm-nightly.sh — rewrite the WezTerm pin (Version/Url/Sha256) inside
# bootstrap.ps1's $PortableTools entry. Used by
# .github/workflows/wezterm-nightly.yml (weekly mirror job); runnable locally.
#
# Usage: bump-wezterm-nightly.sh <version> <url> <sha256> [file]
#   version  nightly build string, e.g. 20260716-081015-abc123
#   url      immutable mirror asset URL
#   sha256   sha256 of the mirrored zip (lowercase hex)
#   file     target (default: repo bootstrap.ps1; overridable for tests)
#
# Edits ONLY the three pin lines between the entry's `Name ... = "WezTerm"`
# line and its closing `},`. sed (not awk) on purpose: gawk 5.1+ silently
# strips a UTF-8 BOM from its input, and bootstrap.ps1's BOM is load-bearing
# for PowerShell 5.1. Exits non-zero if any of the three values didn't land
# or the BOM was lost, so the workflow fails loudly instead of PRing a dud.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="${1:?usage: bump-wezterm-nightly.sh <version> <url> <sha256> [file]}"
URL="${2:?missing url}"
SHA256="${3:?missing sha256}"
FILE="${4:-$ROOT/bootstrap.ps1}"

[ -f "$FILE" ] || {
  echo "target not found: $FILE" >&2
  exit 1
}
grep -q 'Name[[:space:]]*= "WezTerm"' "$FILE" || {
  echo "WezTerm entry anchor not found in $FILE — aborting" >&2
  exit 1
}

sed -i -e '/^[[:space:]]*Name[[:space:]]*= "WezTerm"$/,/^[[:space:]]*},[[:space:]]*$/ {
  s|^\([[:space:]]*Version[[:space:]]*= \).*|\1"'"$VERSION"'"|
  s|^\([[:space:]]*Url[[:space:]]*= \).*|\1"'"$URL"'"|
  s|^\([[:space:]]*Sha256[[:space:]]*= \).*|\1"'"$SHA256"'"|
}' "$FILE"

for needle in "\"$VERSION\"" "\"$URL\"" "\"$SHA256\""; do
  grep -qF "$needle" "$FILE" || {
    echo "bump failed: $needle not present after edit (anchor drift?)" >&2
    exit 1
  }
done

[ "$(head -c 3 "$FILE" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] || {
  echo "UTF-8 BOM lost from $FILE — refusing" >&2
  exit 1
}

echo "WezTerm pin -> $VERSION"
