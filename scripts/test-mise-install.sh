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
# mise-install.sh's disk check (fake df/du, a temp disk-budget.toml): (10) too
# little room stops before installing and lists the largest folders; (11) what
# is already installed lowers the need; (12) a shared host needs less than an
# owned one; (13) WORKSTATION_SKIP_DISK_CHECK=1 goes ahead with a warning; (14)
# an unreadable df and (15) a missing budget skip the check; (16) a CRLF budget
# file is still read. tasks/optional-packages (fake rpm/sudo): (17) nothing
# missing means no sudo; (18) a missing package goes to dnf with strict=0 and an
# absent one is reported as skipped, exit 0. (19) verify-binary.sh honours
# WORKSTATION_GLIBC_FLOOR.
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
# df/du stubs, so the disk check never depends on the real disk: 100 GB free
# and nothing installed unless a case sets FAKE_FREE_KB / FAKE_USED_KB.
cat >"$T/bin/df" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_DF_FAIL:-}" ] && exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fake 999999999 1 %s 1%% /\n' "${FAKE_FREE_KB:-104857600}"
EOF
cat >"$T/bin/du" <<'EOF'
#!/usr/bin/env bash
case "$1" in
-sk) printf '%s\t%s\n' "${FAKE_USED_KB:-0}" "$2" ;;
*) printf '11G\t%s\n7.5G\t%s/.cache\n2.8G\t%s/.vscode-server\n' "$HOME" "$HOME" "$HOME" ;;
esac
EOF
chmod +x "$T/bin/df" "$T/bin/du"
export PATH="$T/bin:$PATH" HOME="$T/home" XDG_STATE_HOME="$T/home/.local/state" MISE_ENV=linux,owned,host,wsl
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

# 10-15. The disk check, run from a copy of the script in a temp repo whose
# disk-budget.toml says owned 5000 MB, shared 2500 MB (the real file changes
# weekly). 1 GB = 1048576 KB.
gbkb() { awk -v g="$1" 'BEGIN { printf "%d", g * 1048576 }'; }
R="$T/repo"
mkdir -p "$R/scripts/lib"
cp "$root/scripts/lib/mise-install.sh" "$R/scripts/lib/"
printf 'linux-owned = 5000\nlinux-shared = 2500\nwindows-owned = 3000\n' >"$R/disk-budget.toml"
mi="$R/scripts/lib/mise-install.sh"
installs="$HOME/.local/share/mise/installs"
# 10. owned, nothing installed, 1 GB free: needs 5000 + 1024 MB, stops before installing.
: >"$FAKE_LOG"
rc10=0
out10="$(FAKE_FREE_KB="$(gbkb 1)" bash "$mi" 2>&1)" || rc10=$?
[ "$rc10" = 1 ] || fail "disk check (1 GB free, owned): expected exit 1, got $rc10"
grep -q install "$FAKE_LOG" && fail "disk check (1 GB free, owned): mise install ran"
printf '%s\n' "$out10" | grep -q 'Not enough disk space for the mise tools: 1.0 GB free.*about 5.9 GB needed' ||
  fail "disk check (1 GB free, owned): wrong message: $out10"
printf '%s\n' "$out10" | grep -q '7.5G.*/.cache' || fail "disk check: the largest folders are not listed: $out10"
printf '%s\n' "$out10" | grep -q "11G.*$HOME\$" && fail "disk check: the home total is listed as a folder: $out10"
# 11. owned with 4 GB already installed needs 5000 - 4096 + 1024 = 1928 MB: 2 GB free is enough.
mkdir -p "$installs"
: >"$FAKE_LOG"
FAKE_FREE_KB="$(gbkb 2)" FAKE_USED_KB="$(gbkb 4)" bash "$mi" >/dev/null 2>&1 ||
  fail "disk check: what is already installed must lower the need (2 GB free, 4 GB installed)"
grep -qx install "$FAKE_LOG" || fail "disk check (2 GB free, 4 GB installed): mise install did not run"
rm -rf "$installs"
# 12. 4.5 GB free, nothing installed: enough for shared (3524 MB), not owned (6024 MB).
: >"$FAKE_LOG"
MISE_ENV=linux FAKE_FREE_KB="$(gbkb 4.5)" bash "$mi" >/dev/null 2>&1 ||
  fail "disk check: 4.5 GB must be enough for a shared host"
rc12=0
FAKE_FREE_KB="$(gbkb 4.5)" bash "$mi" >/dev/null 2>&1 || rc12=$?
[ "$rc12" = 1 ] || fail "disk check: 4.5 GB must not be enough for an owned host"
# 13. the override goes ahead, with a warning.
: >"$FAKE_LOG"
out13="$(WORKSTATION_SKIP_DISK_CHECK=1 FAKE_FREE_KB="$(gbkb 1)" bash "$mi" 2>&1)" ||
  fail "disk check: WORKSTATION_SKIP_DISK_CHECK=1 must go ahead"
grep -qx install "$FAKE_LOG" || fail "disk check override: mise install did not run"
printf '%s\n' "$out13" | grep -q 'WORKSTATION_SKIP_DISK_CHECK=1, so going ahead' || fail "disk check override: no warning: $out13"
# 14. an unreadable df skips the check.
: >"$FAKE_LOG"
FAKE_DF_FAIL=1 FAKE_FREE_KB="$(gbkb 1)" bash "$mi" >/dev/null 2>&1 || fail "disk check: an unreadable df must not stop the install"
grep -qx install "$FAKE_LOG" || fail "disk check (no df): mise install did not run"
# 15. no figure for this host type in disk-budget.toml skips the check, with a warning.
printf 'linux-shared = 2500\n' >"$R/disk-budget.toml"
: >"$FAKE_LOG"
out15="$(FAKE_FREE_KB="$(gbkb 1)" bash "$mi" 2>&1)" || fail "disk check: a missing budget must not stop the install"
grep -qx install "$FAKE_LOG" || fail "disk check (no budget): mise install did not run"
printf '%s\n' "$out15" | grep -q 'disk check skipped: no linux-owned figure' || fail "disk check (no budget): no warning: $out15"
# 16. a CRLF budget file (as a Windows checkout writes it) is still read, not skipped.
printf 'linux-owned = 5000\r\nlinux-shared = 2500\r\n' >"$R/disk-budget.toml"
rc16=0
FAKE_FREE_KB="$(gbkb 1)" bash "$mi" >/dev/null 2>&1 || rc16=$?
[ "$rc16" = 1 ] || fail "disk check: a CRLF disk-budget.toml must still be read (expected exit 1 at 1 GB free, got $rc16)"

# 17-18. tasks/optional-packages (fake rpm/sudo): installs only what is missing,
# with dnf's strict=0, and a package this release lacks is skipped, not fatal.
O="$T/opt-bin"
mkdir -p "$O"
cat >"$O/rpm" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_RPM_HAS:-}" ]
EOF
cat >"$O/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"$FAKE_LOG"
EOF
chmod +x "$O/rpm" "$O/sudo"
: >"$FAKE_LOG"
out17="$(FAKE_RPM_HAS=1 PATH="$O:$PATH" bash "$root/tasks/optional-packages" 2>&1)" || fail "optional-packages (present): non-zero exit"
[ -s "$FAKE_LOG" ] && fail "optional-packages (present): sudo ran: $(cat "$FAKE_LOG")"
printf '%s\n' "$out17" | grep -q 'optional packages present: bear' || fail "optional-packages (present): $out17"
: >"$FAKE_LOG"
out18="$(PATH="$O:$PATH" bash "$root/tasks/optional-packages" 2>&1)" || fail "optional-packages (missing): non-zero exit"
grep -qx 'sudo dnf install -y --setopt=strict=0 bear' "$FAKE_LOG" || fail "optional-packages (missing): wrong dnf call: $(cat "$FAKE_LOG")"
printf '%s\n' "$out18" | grep -q "bear isn't packaged for" || fail "optional-packages (missing): no skip note: $out18"

# 19. verify-binary.sh: WORKSTATION_GLIBC_FLOOR judges a binary against that glibc,
# not this host's (CI checks every Linux asset against EL8's 2.28 this way).
if command -v objdump >/dev/null 2>&1 || command -v readelf >/dev/null 2>&1; then
  sysbin="$(command -v ls)"
  bash "$root/scripts/lib/verify-binary.sh" "$sysbin" >/dev/null 2>&1 || fail "verify-binary: $sysbin fails on its own host"
  rc19=0
  out19="$(WORKSTATION_GLIBC_FLOOR=2.0 bash "$root/scripts/lib/verify-binary.sh" "$sysbin" 2>&1)" || rc19=$?
  [ "$rc19" = 1 ] || fail "verify-binary: WORKSTATION_GLIBC_FLOOR=2.0 must fail $sysbin (got $rc19)"
  printf '%s\n' "$out19" | grep -q 'checked against glibc 2.0 (WORKSTATION_GLIBC_FLOOR)' || fail "verify-binary floor: $out19"
fi

echo "PASS: mise-install.sh installs/forces-node-once-on-change; verify-tools fails loudly on a broken mise bin-paths; an unreadable tools.node declaration forces the reinstall and writes NO marker; the disk check stops a too-full disk before installing (budgets from disk-budget.toml, installed tools counted, override, unreadable df or missing budget skipped); optional-packages installs only what's missing with strict=0 and skips what the release lacks; verify-binary honours WORKSTATION_GLIBC_FLOOR"
