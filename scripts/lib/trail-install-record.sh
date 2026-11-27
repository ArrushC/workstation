#!/usr/bin/env bash
# trail-install-record.sh: point trail's install record at the pinned trail.
#
# `trail init` wires Claude Code for the whole account: hooks in ~/.claude/settings.json
# that run ~/.claude/helpers/graft-hooks.cjs (trail's own name for it). That shim finds
# trail's code through ~/.trail/install.json (`claudeDist`, an absolute path), then
# through a `trail` on PATH that links into the package, then `npm root -g`. Under mise
# the record is a versioned install path that only `trail init` rewrites, and mise's
# `trail` shim links to mise, not into the package. So after a version bump the hooks
# would run the old version while it is on disk, and nothing once it is pruned: in a repo
# with learnings the shim then tells Claude trail isn't installed and to offer
# `npm install -g`, a second copy.
#
# Run by tasks/claude on every bootstrap and update. Does nothing until `trail init` has
# put the shim there (trail is opt-in per account), keeps the record's other keys, and
# rewrites the file only when the path changes. The shim ignores a record that isn't ours
# or that group or others can write, so it is written 0600. Every failure warns and
# exits 0. TRAIL_BIN stands in for `mise which trail` (scripts/test-trail-install-record.sh).
set -uo pipefail

shim="$HOME/.claude/helpers/graft-hooks.cjs"
[ -f "$shim" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
  echo "  ! trail: jq not found, install record left as it is" >&2
  exit 0
fi
bin="${TRAIL_BIN:-$(mise which trail 2>/dev/null)}"
if [ -z "$bin" ] || [ ! -e "$bin" ]; then
  echo "  trail not installed (mise install): install record left as it is (retries next run)" >&2
  exit 0
fi
# mise's bin is node_modules/.bin/trail, a launcher script beside the package's link
# (node_modules/@trailhq/trail-code); npm's is a link to <package>/dist/bin/trail.js.
pkg="$(dirname "$bin")/../@trailhq/trail-code"
if [ -d "$pkg/dist/claude" ]; then
  dist="$(readlink -f "$pkg")/dist/claude"
else
  dist="$(dirname "$(dirname "$(readlink -f "$bin")")")/claude"
fi
if [ ! -f "$dist/hooks.js" ]; then
  echo "  ! trail: no hooks.js in $dist, install record left as it is" >&2
  exit 0
fi

home="${TRAIL_HOME:-$HOME/.trail}"
record="$home/install.json"
current='{}'
if [ -f "$record" ]; then
  current="$(jq -c 'if type == "object" then . else {} end' "$record" 2>/dev/null)" || current='{}'
  [ -n "$current" ] || current='{}'
fi
if [ "$(printf '%s' "$current" | jq -r '.claudeDist // ""')" = "$dist" ]; then
  exit 0
fi

mkdir -p "$home" 2>/dev/null && tmp="$(mktemp "$home/.install.json.XXXXXX" 2>/dev/null)" || {
  echo "  ! trail: could not write in $home, install record left as it is" >&2
  exit 0
}
if printf '%s' "$current" | jq --arg d "$dist" '.claudeDist = $d' >"$tmp" 2>/dev/null &&
  chmod 0600 "$tmp" && mv -f "$tmp" "$record"; then
  echo "  trail hooks -> $dist"
else
  rm -f "$tmp"
  echo "  ! trail: could not write $record, left as it is" >&2
fi
exit 0
