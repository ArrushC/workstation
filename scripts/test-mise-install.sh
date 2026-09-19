#!/usr/bin/env bash
# test-mise-install.sh — offline behavioural tests, no real mise/network needed.
# scripts/lib/mise-install.sh (fake `mise` on PATH): (1) fresh install writes
# the marker without forcing; (2) unchanged declaration → no force; (3) changed
# declaration with node already present → exactly one `install --force node`.
# tasks/migrate-legacy: (4) a removal that cannot happen (read-only dir, no
# sudo) withholds the idempotency marker, reports "legacy sweep incomplete",
# still exits 0, and never touches /usr/local (no-sudo hosts skip it entirely
# — prod never installed there). (6) a fully-writable ~/.local/bin sweep with
# no sudo completes, writes both PR1 + PR2 markers, and reports "already done"
# on the next run — host-independent, since /usr/local (which this real dev
# box's own leftover root-owned installs would otherwise poison) is out of the
# walk; the PR2 half also fully removes the pre-mise stamps dir.
# tasks/verify-tools: (5) a failing `mise bin-paths` exits 1 with the failure
# message instead of silently reporting zero binaries.
# mise-install.sh: (9) an unreadable `tools.node` declaration must force the
# node reinstall and write NO marker, never the empty-input cksum (a constant
# marker name froze the whole re-run mechanism).
# tasks/migrate-legacy: (7) sudo present but requiring a password (a
# non-interactive fleet run) prints exactly one "sudo needs a password"
# line, withholds both markers, exits 0, and never attempts an /usr/local or
# /etc/profile.d path. (8) a PR1 marker left over from before this PR2 second
# block existed must not block the PR2 sweep — only a block's OWN marker may
# skip it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"
cat >"$T/bin/mise" <<'EOF'
#!/usr/bin/env bash
log="${FAKE_LOG:?}"
case "$1 ${2:-}" in
"where node") [ -f "$FAKE_NODE" ] && exit 0 || exit 1 ;;
"install --force") echo "install --force $3" >>"$log"; exit 0 ;;
"install ") echo "install" >>"$log"; : >"$FAKE_NODE"; exit 0 ;;
"config get") [ -n "${FAKE_DECL_FAIL:-}" ] && { echo "mise ERROR Key not found: tools.node" >&2; exit 1; }; printf '%s\n' "$FAKE_DECL"; exit 0 ;;
"prune "|"reshim ") exit 0 ;;
esac
echo "fake mise: unexpected args: $*" >&2; exit 99
EOF
chmod +x "$T/bin/mise"
export PATH="$T/bin:$PATH" HOME="$T/home" XDG_STATE_HOME="$T/home/.local/state" MISE_ENV=linux,dev,host,wsl
export FAKE_LOG="$T/log" FAKE_NODE="$T/node-installed" FAKE_DECL='{ version = "26.8.1", postinstall = "npm install -g a@1" }'
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
# 1. fresh
bash "$root/scripts/lib/mise-install.sh" >/dev/null
grep -qx install "$FAKE_LOG" || fail "first run did not install"
grep -q 'install --force' "$FAKE_LOG" && fail "fresh install forced node"
ls "$XDG_STATE_HOME/workstation"/node-postinstall.* >/dev/null || fail "marker not written"
# 2. unchanged
: >"$FAKE_LOG"
bash "$root/scripts/lib/mise-install.sh" >/dev/null
grep -q 'install --force' "$FAKE_LOG" && fail "unchanged declaration forced node"
# 3. changed
FAKE_DECL='{ version = "26.8.1", postinstall = "npm install -g a@2" }' bash "$root/scripts/lib/mise-install.sh" >/dev/null
[ "$(grep -c 'install --force node' "$FAKE_LOG")" = 1 ] || fail "changed declaration should force node exactly once"

# 4. migrate-legacy: a removal that cannot happen must withhold the marker.
# One legacy path lives under a directory we make read-only (555, no write
# bit), so rm_p's `[ -w "$(dirname "$p")" ]` check fails and — with no sudo on
# this scratch host — falls into the no-sudo branch: failed>0, marker withheld.
L="$T/legacy-home"
mkdir -p "$L/.local/bin"
: >"$L/.local/bin/fzf"
chmod 555 "$L/.local/bin"
rc4=0
out4="$(HOME="$L" XDG_STATE_HOME="$L/.local/state" MISE_ENV=linux bash "$root/tasks/migrate-legacy" 2>&1)" || rc4=$?
chmod 755 "$L/.local/bin"
[ "$rc4" = 0 ] || fail "migrate-legacy (read-only dir): expected exit 0, got $rc4"
[ -f "$L/.local/state/workstation/legacy-tools-swept" ] && fail "migrate-legacy (read-only dir): marker written despite a failed removal"
printf '%s\n' "$out4" | grep -q 'legacy sweep incomplete' || fail "migrate-legacy (read-only dir): missing 'legacy sweep incomplete' message"
printf '%s\n' "$out4" | grep -q '/usr/local left untouched' || fail "migrate-legacy (read-only dir): missing '/usr/local left untouched' message"
printf '%s\n' "$out4" | grep -E '^  (- removed|! failed to remove|! cannot remove) ' | grep -q '/usr/local' &&
  fail "migrate-legacy (read-only dir): touched /usr/local despite no sudo"

# 5. verify-tools: a failing `mise bin-paths` must fail loudly, not report 0.
V="$T/verify-bin"
mkdir -p "$V"
cat >"$V/mise" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "bin-paths" ]; then
  echo "boom: bin-paths enumeration failed" >&2
  exit 3
fi
exit 0
EOF
chmod +x "$V/mise"
rc5=0
out5="$(PATH="$V:$PATH" bash "$root/tasks/verify-tools" 2>&1)" || rc5=$?
[ "$rc5" = 1 ] || fail "verify-tools (mise bin-paths failure): expected exit 1, got $rc5"
printf '%s\n' "$out5" | grep -q 'verify-tools: mise bin-paths failed' || fail "verify-tools (mise bin-paths failure): missing failure message"

# 6. migrate-legacy: a fully-writable ~/.local/bin sweep (no sudo) completes
# and writes the marker — host-independent version of the brief's original
# scratch test: with /usr/local skipped entirely when there is no sudo, this
# no longer depends on what this real host's own /usr/local/bin happens to
# hold (round-1 concern).
S="$T/sweep-home"
mkdir -p "$S/.local/bin" "$S/.local/share/workstation-install"
: >"$S/.local/bin/fzf"
: >"$S/.local/bin/mise"
: >"$S/.local/bin/wpy"
: >"$S/.local/share/workstation-install/fzf-0.74.3.done"
: >"$S/.local/share/workstation-install/python-env-3.14.7-1.done"
HOME="$S" XDG_STATE_HOME="$S/.local/state" MISE_ENV=linux bash "$root/tasks/migrate-legacy" >/dev/null
[ -e "$S/.local/bin/fzf" ] && fail "migrate-legacy (writable sweep): fzf not removed"
[ -f "$S/.local/bin/mise" ] || fail "migrate-legacy (writable sweep): mise was removed"
[ -f "$S/.local/bin/wpy" ] || fail "migrate-legacy (writable sweep): wpy was removed"
[ -f "$S/.local/share/workstation-install/fzf-0.74.3.done" ] && fail "migrate-legacy (writable sweep): fzf stamp not removed"
[ -e "$S/.local/share/workstation-install" ] && fail "migrate-legacy (writable sweep): old stamps dir not removed by the PR2 sweep (superseded — tasks/{python-env,fonts,vcpkg} stamp \$state now)"
[ -f "$S/.local/state/workstation/legacy-tools-swept" ] || fail "migrate-legacy (writable sweep): PR1 marker not written"
[ -f "$S/.local/state/workstation/legacy-host-swept" ] || fail "migrate-legacy (writable sweep): PR2 marker not written"
out6b="$(HOME="$S" XDG_STATE_HOME="$S/.local/state" MISE_ENV=linux bash "$root/tasks/migrate-legacy" 2>&1)"
printf '%s\n' "$out6b" | grep -q 'already done' || fail "migrate-legacy (writable sweep): second run did not print 'already done'"

# 7. migrate-legacy: sudo present but requires a password (non-interactive
# fleet run) must never block on a prompt or touch /usr/local — one clear
# message, marker withheld, exit 0, no /usr/local paths attempted at all.
P="$T/sudo-home"
mkdir -p "$P/.local/bin" "$T/sudobin"
: >"$P/.local/bin/fzf"
cat >"$T/sudobin/sudo" <<'SUDOEOF'
#!/usr/bin/env bash
if [ "$1" = "-n" ] && [ "$2" = "true" ]; then
  exit 1
fi
echo "fake sudo: unexpected args: $*" >&2
exit 99
SUDOEOF
chmod +x "$T/sudobin/sudo"
rc7=0
out7="$(PATH="$T/sudobin:$PATH" HOME="$P" XDG_STATE_HOME="$P/.local/state" MISE_ENV=linux,dev,host,wsl bash "$root/tasks/migrate-legacy" 2>&1)" || rc7=$?
[ "$rc7" = 0 ] || fail "migrate-legacy (sudo needs password): expected exit 0, got $rc7"
[ -f "$P/.local/state/workstation/legacy-tools-swept" ] && fail "migrate-legacy (sudo needs password): marker written despite withheld sudo"
[ "$(printf '%s\n' "$out7" | grep -c 'sudo needs a password')" = 1 ] || fail "migrate-legacy (sudo needs password): expected exactly one 'sudo needs a password' line"
printf '%s\n' "$out7" | grep -q 'no sudo on this host' && fail "migrate-legacy (sudo needs password): should not also print the no-sudo message"
printf '%s\n' "$out7" | grep -E '^  (- removed|! failed to remove|! cannot remove) ' | grep -q '/usr/local' &&
  fail "migrate-legacy (sudo needs password): touched /usr/local despite the password prompt"

# 8. migrate-legacy: a PR1 marker left over from before the PR2 second block
# existed must not block the PR2 sweep — only a block's OWN marker skips it.
# No /usr/local, /etc or systemd interaction: MISE_ENV=linux (no host token,
# no sudo) and no pueued unit file in this sandbox, so this stays fully
# offline like every other case above.
M="$T/premarked-home"
mkdir -p "$M/.local/state/workstation" "$M/.local/share/workstation-install"
: >"$M/.local/state/workstation/legacy-tools-swept"
: >"$M/.local/share/workstation-install/python-env-3.14.7-1.done"
out8="$(HOME="$M" XDG_STATE_HOME="$M/.local/state" MISE_ENV=linux bash "$root/tasks/migrate-legacy" 2>&1)"
printf '%s\n' "$out8" | grep -q 'legacy sweep already done' || fail "migrate-legacy (PR1 pre-marked): PR1 half did not report already-done"
[ -f "$M/.local/state/workstation/legacy-host-swept" ] || fail "migrate-legacy (PR1 pre-marked): PR2 sweep did not run despite the PR1 marker"
[ -e "$M/.local/share/workstation-install" ] && fail "migrate-legacy (PR1 pre-marked): old stamps dir not removed by the PR2 sweep"

# 9. mise-install.sh: an UNREADABLE node declaration (the real failure mode —
# `mise config get tools.node` without `-f` reads only the highest-precedence
# config file, which since PR2 declares no tools, so it errors) must NOT settle
# on the empty-input cksum. Before the fix that constant marker froze the
# mechanism: node would never force-reinstall again on a postinstall change.
: >"$FAKE_LOG"
rm -f "$XDG_STATE_HOME/workstation"/node-postinstall.*
: >"$FAKE_NODE" # node already installed
FAKE_DECL_FAIL=1 bash "$root/scripts/lib/mise-install.sh" >/dev/null 2>&1
[ "$(grep -c 'install --force node' "$FAKE_LOG")" = 1 ] ||
  fail "unreadable declaration must force the node reinstall (never assume unchanged)"
empty_sum="$(printf '' | cksum | cut -d' ' -f1)"
[ -e "$XDG_STATE_HOME/workstation/node-postinstall.$empty_sum" ] &&
  fail "unreadable declaration wrote the empty-cksum marker ($empty_sum) — the mechanism would freeze"
ls "$XDG_STATE_HOME/workstation"/node-postinstall.* >/dev/null 2>&1 &&
  fail "unreadable declaration must write no marker at all, so the next run retries"
# and it recovers: a readable declaration on the next run writes a real marker
: >"$FAKE_LOG"
bash "$root/scripts/lib/mise-install.sh" >/dev/null
ls "$XDG_STATE_HOME/workstation"/node-postinstall.* >/dev/null ||
  fail "a readable declaration after a failure must write the marker again"

echo "PASS: mise-install.sh installs/forces-node-once-on-change; migrate-legacy withholds its markers on a failed removal, skips /usr/local+/etc/profile.d entirely with no sudo, sweeps + marks-done cleanly (both PR1 and PR2) when everything is writable, never blocks on a sudo password prompt, and runs its PR2 half even when only the PR1 marker pre-exists; verify-tools fails loudly on a broken mise bin-paths; an unreadable tools.node declaration forces the reinstall and writes NO marker"
