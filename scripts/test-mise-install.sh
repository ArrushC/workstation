#!/usr/bin/env bash
# test-mise-install.sh — offline behavioural tests, no real mise/network needed.
# scripts/lib/mise-install.sh (fake `mise` on PATH): (1) fresh install writes
# the marker without forcing; (2) unchanged declaration → no force; (3) changed
# declaration with node already present → exactly one `install --force node`.
# tasks/verify-tools: (5) a failing `mise bin-paths` exits 1 with the failure
# message instead of silently reporting zero binaries.
# mise-install.sh: (9) an unreadable `tools.node` declaration must force the
# node reinstall and write NO marker, never the empty-input cksum (a constant
# marker name froze the whole re-run mechanism).
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

echo "PASS: mise-install.sh installs/forces-node-once-on-change; verify-tools fails loudly on a broken mise bin-paths; an unreadable tools.node declaration forces the reinstall and writes NO marker"
