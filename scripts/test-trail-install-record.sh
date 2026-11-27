#!/usr/bin/env bash
# test-trail-install-record.sh: scripts/lib/trail-install-record.sh against a stand-in
# trail package (TRAIL_BIN, laid out as mise's npm backend leaves it) in a scratch HOME. Never
# the real ~/.trail or a real trail.
#   Nothing until `trail init` has put its hook shim in ~/.claude/helpers; then the record
#   names the package's dist/claude, 0600; a record for another version is moved to this
#   one and keeps its other keys; an up-to-date record isn't rewritten; a record that isn't
#   JSON is replaced; no trail, or a package without hooks.js, leaves the record alone.
#   Exit 0 every time.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/lib/trail-install-record.sh"
if ! command -v jq >/dev/null 2>&1; then
  echo "test-trail-install-record: jq missing, skipped"
  exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() {
  printf '  FAIL  %s\n' "$1" >&2
  fails=$((fails + 1))
}
check() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

home="$tmp/home"
record="$home/.trail/install.json"
mkdir -p "$home"
# pkg <version>: a stand-in package; prints the link mise's node_modules/.bin would hold.
# The layout mise's npm backend leaves: the package in node_modules/.mise/..., a link to it at
# node_modules/@trailhq/trail-code, and node_modules/.bin/trail a launcher script (not a link).
pkg() {
  local nm="$tmp/installs/$1/node_modules"
  local p="$nm/.mise/@trailhq+trail-code@$1/node_modules/@trailhq/trail-code"
  mkdir -p "$p/dist/bin" "$p/dist/claude" "$nm/.bin" "$nm/@trailhq"
  : >"$p/dist/bin/trail.js"
  : >"$p/dist/claude/hooks.js"
  ln -sfn "$p" "$nm/@trailhq/trail-code"
  printf '#!/bin/sh\n' >"$nm/.bin/trail"
  printf '%s\n' "$nm/.bin/trail"
}
dist() { printf '%s\n' "$tmp/installs/$1/node_modules/.mise/@trailhq+trail-code@$1/node_modules/@trailhq/trail-code/dist/claude"; }
run() { HOME="$home" TRAIL_HOME='' TRAIL_BIN="$1" bash "$script" >"$tmp/out" 2>&1; }
names() { [ "$(jq -r .claudeDist "$record" 2>/dev/null)" = "$(dist "$1")" ]; }
absent() { [ ! -e "$1" ]; }

old="$(pkg 0.30.5)"
new="$(pkg 0.31.0)"

check "before trail init: exit 0" run "$new"
check "before trail init: no record written" absent "$record"

mkdir -p "$home/.claude/helpers"
: >"$home/.claude/helpers/graft-hooks.cjs"
check "after trail init: exit 0" run "$old"
check "the record names the package's dist/claude" names 0.30.5
check "the record is 0600" test "$(stat -c %a "$record")" = 600

jq '.other = "kept"' "$record" >"$tmp/r" && mv "$tmp/r" "$record"
check "a newer pin: exit 0" run "$new"
check "the record moves to the new version" names 0.31.0
check "its other keys stay" test "$(jq -r .other "$record")" = kept
check "it says so" grep -q 'trail hooks -> ' "$tmp/out"

touch -d '2020-01-01' "$record"
check "an up-to-date record: exit 0" run "$new"
check "an up-to-date record isn't rewritten" test "$(stat -c %Y "$record")" = "$(date -d '2020-01-01' +%s)"
check "and nothing is said" test ! -s "$tmp/out"

check "no trail installed: exit 0" run "$tmp/none"
check "no trail installed: the record is left" names 0.31.0

rm "$(dist 0.30.5)/hooks.js"
check "a package without hooks.js: exit 0" run "$old"
check "a package without hooks.js: the record is left" names 0.31.0

# npm's layout: the bin is a link into the package.
npm_pkg="$tmp/npm/lib/node_modules/@trailhq/trail-code"
mkdir -p "$npm_pkg/dist/bin" "$npm_pkg/dist/claude" "$tmp/npm/bin"
: >"$npm_pkg/dist/bin/trail.js"
: >"$npm_pkg/dist/claude/hooks.js"
ln -s "$npm_pkg/dist/bin/trail.js" "$tmp/npm/bin/trail"
check "a bin that links into the package: exit 0" run "$tmp/npm/bin/trail"
check "a bin that links into the package: its dist/claude" test "$(jq -r .claudeDist "$record")" = "$npm_pkg/dist/claude"

printf '{"claudeDist": ' >"$record"
check "a record that isn't JSON: exit 0" run "$new"
check "a record that isn't JSON is replaced" names 0.31.0

if [ "$fails" -gt 0 ]; then
  echo "test-trail-install-record: $fails failed" >&2
  exit 1
fi
echo "test-trail-install-record: all passed"
