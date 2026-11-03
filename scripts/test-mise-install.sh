#!/usr/bin/env bash
# test-mise-install.sh — offline behavioural tests, no real mise/network needed.
# Installs runtimes without forcing Node or pruning rollback versions; checks
# disk preflight, binary compatibility, optional packages and EL repositories.
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
"install --dry-run-code") [ -n "${FAKE_NOTHING_MISSING:-}" ] && exit 0 || exit 1 ;;
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
export PATH="$T/bin:$PATH" HOME="$T/home" XDG_STATE_HOME="$T/home/.local/state"
export FAKE_LOG="$T/log" FAKE_NODE="$T/node-installed" FAKE_DECL='{ version = "26.8.1", postinstall = "npm install -g a@1" }'
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
# 1. fresh
bash "$root/scripts/lib/mise-install.sh" >/dev/null
grep -qx install "$FAKE_LOG" || fail "first run did not install"
grep -q 'install --force' "$FAKE_LOG" && fail "fresh install forced node"
# Repeated installs never reinstall Node merely for a dependency change.
: >"$FAKE_LOG"
bash "$root/scripts/lib/mise-install.sh" >/dev/null
grep -q 'install --force' "$FAKE_LOG" && fail "repeat install forced node"

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

# 10-15. The disk check, run from a copy of the script in a temp repo whose
# disk-budget.toml says linux 5000 MB (the real file changes
# weekly). 1 GB = 1048576 KB.
gbkb() { awk -v g="$1" 'BEGIN { printf "%d", g * 1048576 }'; }
R="$T/repo"
mkdir -p "$R/scripts/lib"
cp "$root/scripts/lib/mise-install.sh" "$R/scripts/lib/"
printf 'linux = 5000\nwindows = 3000\n' >"$R/disk-budget.toml"
mi="$R/scripts/lib/mise-install.sh"
installs="$HOME/.local/share/mise/installs"
# 10. nothing installed, 1 GB free: needs 5000 + 1024 MB, stops before installing.
: >"$FAKE_LOG"
rc10=0
out10="$(FAKE_FREE_KB="$(gbkb 1)" bash "$mi" 2>&1)" || rc10=$?
[ "$rc10" = 1 ] || fail "disk check (1 GB free): expected exit 1, got $rc10"
grep -q install "$FAKE_LOG" && fail "disk check (1 GB free): mise install ran"
printf '%s\n' "$out10" | grep -q 'Not enough disk space for the mise tools: 1.0 GB free.*about 5.9 GB needed' ||
  fail "disk check (1 GB free): wrong message: $out10"
printf '%s\n' "$out10" | grep -q '7.5G.*/.cache' || fail "disk check: the largest folders are not listed: $out10"
printf '%s\n' "$out10" | grep -q "11G.*$HOME\$" && fail "disk check: the home total is listed as a folder: $out10"
# 11. with 4 GB already installed needs 5000 - 4096 + 1024 = 1928 MB: 2 GB free is enough.
mkdir -p "$installs"
: >"$FAKE_LOG"
FAKE_FREE_KB="$(gbkb 2)" FAKE_USED_KB="$(gbkb 4)" bash "$mi" >/dev/null 2>&1 ||
  fail "disk check: what is already installed must lower the need (2 GB free, 4 GB installed)"
grep -qx install "$FAKE_LOG" || fail "disk check (2 GB free, 4 GB installed): mise install did not run"
rm -rf "$installs"
# 12. just short: 4.5 GB free, nothing installed, needs 5000 + 1024 MB.
rc12=0
FAKE_FREE_KB="$(gbkb 4.5)" bash "$mi" >/dev/null 2>&1 || rc12=$?
[ "$rc12" = 1 ] || fail "disk check: 4.5 GB must not be enough (linux budget 5000 MB + 1 GB), got $rc12"
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
# 15. no linux figure in disk-budget.toml skips the check, with a warning.
printf 'windows = 3000\n' >"$R/disk-budget.toml"
: >"$FAKE_LOG"
out15="$(FAKE_FREE_KB="$(gbkb 1)" bash "$mi" 2>&1)" || fail "disk check: a missing budget must not stop the install"
grep -qx install "$FAKE_LOG" || fail "disk check (no budget): mise install did not run"
printf '%s\n' "$out15" | grep -q 'disk check skipped: no linux figure' || fail "disk check (no budget): no warning: $out15"
# 16. a CRLF budget file (as a Windows checkout writes it) is still read, not skipped.
printf 'linux = 5000\r\nwindows = 3000\r\n' >"$R/disk-budget.toml"
rc16=0
FAKE_FREE_KB="$(gbkb 1)" bash "$mi" >/dev/null 2>&1 || rc16=$?
[ "$rc16" = 1 ] || fail "disk check: a CRLF disk-budget.toml must still be read (expected exit 1 at 1 GB free, got $rc16)"
# 28. nothing to install (every tool installed, the caches outside `installs`):
# 1 GB free is enough, as mise install writes nothing.
: >"$FAKE_LOG"
out28="$(FAKE_NOTHING_MISSING=1 FAKE_FREE_KB="$(gbkb 1)" bash "$mi" 2>&1)" ||
  fail "disk check: nothing to install must not stop the run: $out28"
grep -qx install "$FAKE_LOG" || fail "disk check (nothing to install): mise install did not run"
printf '%s\n' "$out28" | grep -q 'disk space' && fail "disk check (nothing to install): still warned: $out28"

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
printf 'ID="almalinux"\nVERSION_ID="9.6"\nPRETTY_NAME="Alma 9.6"\n' >"$T/os-opt9"
export WORKSTATION_OS_RELEASE="$T/os-opt9"
: >"$FAKE_LOG"
out17="$(FAKE_RPM_HAS=1 PATH="$O:$PATH" bash "$root/tasks/optional-packages" 2>&1)" || fail "optional-packages (present): non-zero exit"
[ -s "$FAKE_LOG" ] && fail "optional-packages (present): sudo ran: $(cat "$FAKE_LOG")"
printf '%s\n' "$out17" | grep -q 'optional packages present: bear' || fail "optional-packages (present): $out17"
: >"$FAKE_LOG"
out18="$(PATH="$O:$PATH" bash "$root/tasks/optional-packages" 2>&1)" || fail "optional-packages (missing): non-zero exit"
grep -qx 'sudo dnf install -y --setopt=strict=0 bear' "$FAKE_LOG" || fail "optional-packages (missing): wrong dnf call: $(cat "$FAKE_LOG")"
printf '%s\n' "$out18" | grep -q "bear isn't packaged for Alma 9.6" || fail "optional-packages (missing): no skip note: $out18"
unset WORKSTATION_OS_RELEASE

# 20-24. enable-el-repos.sh picks the CRB repo from the host (os-release fixture,
# fake rpm/dnf/sudo; a package counts as installed unless FAKE_RPM_MISSING names it).
E="$T/el-bin"
mkdir -p "$E" "$T/el-subman"
cat >"$E/rpm" <<'EOF'
#!/usr/bin/env bash
case " ${FAKE_RPM_MISSING:-} " in *" $2 "*) exit 1 ;; esac
EOF
cat >"$E/dnf" <<'EOF'
#!/usr/bin/env bash
[ "$1" = repolist ] && { printf '%s\n' "${FAKE_REPOLIST:-}"; exit 0; }
echo "dnf $*" >>"$FAKE_LOG"
EOF
cat >"$E/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"$FAKE_LOG"
[ "${FAKE_SUDO_RC:-0}" = 0 ] || echo "Error: fake sudo failure" >&2
exit "${FAKE_SUDO_RC:-0}"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/el-subman/subscription-manager"
chmod +x "$E"/* "$T/el-subman/subscription-manager"
printf 'ID="rhel"\nID_LIKE="fedora"\nVERSION_ID="8.10"\nPRETTY_NAME="RHEL 8.10"\n' >"$T/os-rhel8"
printf 'ID="almalinux"\nID_LIKE="rhel centos fedora"\nVERSION_ID="8.10"\nPRETTY_NAME="Alma 8.10"\n' >"$T/os-alma8"
printf 'ID="almalinux"\nID_LIKE="rhel centos fedora"\nVERSION_ID="9.6"\nPRETTY_NAME="Alma 9.6"\n' >"$T/os-alma9"
# el <fixture> [VAR=value...]: run the script with subscription-manager on PATH.
el() { env PATH="$E:$T/el-subman:$PATH" WORKSTATION_OS_RELEASE="$T/os-$1" "${@:2}" bash "$root/scripts/lib/enable-el-repos.sh" 2>&1; }
arch="$(uname -m)"
: >"$FAKE_LOG"
out20="$(el rhel8)" || fail "enable-el-repos (RHEL 8): non-zero exit: $out20"
grep -qx "sudo subscription-manager repos --enable codeready-builder-for-rhel-8-$arch-rpms" "$FAKE_LOG" ||
  fail "enable-el-repos (RHEL 8): wrong enable: $(cat "$FAKE_LOG")"
: >"$FAKE_LOG"
out21="$(el alma8)" || fail "enable-el-repos (Alma 8): non-zero exit: $out21"
grep -qx 'sudo dnf config-manager --set-enabled powertools' "$FAKE_LOG" || fail "enable-el-repos (Alma 8): $(cat "$FAKE_LOG")"
: >"$FAKE_LOG"
out22="$(el alma9)" || fail "enable-el-repos (Alma 9): non-zero exit: $out22"
grep -qx 'sudo dnf config-manager --set-enabled crb' "$FAKE_LOG" || fail "enable-el-repos (Alma 9): $(cat "$FAKE_LOG")"
: >"$FAKE_LOG"
out23="$(el rhel8 FAKE_REPOLIST="codeready-builder-for-rhel-8-$arch-rpms  Red Hat CodeReady Linux Builder")" || fail "enable-el-repos (enabled): non-zero exit"
[ -s "$FAKE_LOG" ] && fail "enable-el-repos (enabled): sudo ran: $(cat "$FAKE_LOG")"
printf '%s\n' "$out23" | grep -q 'CRB already enabled' || fail "enable-el-repos (enabled): $out23"
rc24=0
out24="$(el rhel8 FAKE_SUDO_RC=1)" || rc24=$?
[ "$rc24" = 1 ] || fail "enable-el-repos (enable fails): expected exit 1, got $rc24"
printf '%s\n' "$out24" | grep -q "Enable it with: sudo subscription-manager repos --enable codeready-builder-for-rhel-8-$arch-rpms" ||
  fail "enable-el-repos (enable fails): no command named: $out24"
printf '%s\n' "$out24" | grep -q 'Error: fake sudo failure' || fail "enable-el-repos (enable fails): the error is hidden: $out24"
crb_on="codeready-builder-for-rhel-8-$arch-rpms  Red Hat CodeReady Linux Builder"
: >"$FAKE_LOG"
el rhel8 FAKE_RPM_MISSING=epel-release FAKE_REPOLIST="$crb_on" >/dev/null || fail "enable-el-repos (RHEL EPEL): non-zero exit"
grep -qx 'sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm' "$FAKE_LOG" ||
  fail "enable-el-repos (RHEL EPEL): $(cat "$FAKE_LOG")"
: >"$FAKE_LOG"
el alma9 FAKE_RPM_MISSING=epel-release FAKE_REPOLIST="crb  CRB" >/dev/null || fail "enable-el-repos (Alma EPEL): non-zero exit"
grep -qx 'sudo dnf install -y epel-release' "$FAKE_LOG" || fail "enable-el-repos (Alma EPEL): $(cat "$FAKE_LOG")"
# 27. tasks/optional-packages on EL8: bear (EL9+) is skipped without a sudo prompt.
: >"$FAKE_LOG"
out27="$(env PATH="$E:$PATH" WORKSTATION_OS_RELEASE="$T/os-alma8" FAKE_RPM_MISSING=bear bash "$root/tasks/optional-packages" 2>&1)" ||
  fail "optional-packages (EL8): non-zero exit"
[ -s "$FAKE_LOG" ] && fail "optional-packages (EL8): sudo ran: $(cat "$FAKE_LOG")"
printf '%s\n' "$out27" | grep -q "bear isn't packaged before EL9; skipped on Alma 8.10" || fail "optional-packages (EL8): $out27"

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

echo "PASS: runtime installs, disk preflight, binary compatibility and EL package handling"
