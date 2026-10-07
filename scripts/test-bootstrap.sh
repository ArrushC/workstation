#!/usr/bin/env bash
# Offline tests for bootstrap.sh: identity prompts and the config.local.toml
# writer, the sudo decision (stubbed sudo), the login shell for local and
# directory (SSSD) accounts (stubbed getent/sudo), the --reinstall confirmation,
# and tasks/update's sudo skip (U1/U2).
# Sources bootstrap.sh with WORKSTATION_BOOTSTRAP_LIB=1 so main does not run.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() {
  printf 'FAIL: %s\n' "$*"
  exit 1
}

# Stub sudo first on PATH: the tests never reach the real one.
mkdir -p "$T/bin"
cat >"$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"${FAKE_SUDO_LOG:-/dev/null}"
case "$1" in
-n) exit "${FAKE_SUDO_N:-1}" ;; # -n true: cached / NOPASSWD?
-v)
  if [ "${FAKE_SUDO_V:-1}" = int ]; then # Ctrl-C: SIGINT hits the whole process group
    kill -INT "$PPID"
    kill -INT $$
  fi
  exit "${FAKE_SUDO_V:-1}"
  ;; # the password prompt
esac
exit 0
EOF
chmod +x "$T/bin/sudo"
export PATH="$T/bin:$PATH"

# run <case-dir> <stdin-for-fd3|-> [VAR=value ...] — resolve_host_config and
# resolve_system_steps in a fresh shell with REPO_DIR=<case-dir>; prints SYSTEM. "-" means no
# fd 3 (an inherited one is closed) and setsid removes the controlling terminal.
run() {
  local dir=$1 input=$2
  shift 2
  if [ "$input" = - ]; then
    env "$@" WORKSTATION_BOOTSTRAP_LIB=1 REPO_DIR_OVERRIDE="$dir" setsid -w bash -c \
      'source "$0"; REPO_DIR=$REPO_DIR_OVERRIDE; resolve_host_config; resolve_system_steps; echo "SYSTEM=$SYSTEM"' "$root/bootstrap.sh" </dev/null 3<&- 2>&1
  else
    env "$@" WORKSTATION_BOOTSTRAP_LIB=1 REPO_DIR_OVERRIDE="$dir" setsid -w bash -c \
      'source "$0"; REPO_DIR=$REPO_DIR_OVERRIDE; resolve_host_config; resolve_system_steps; echo "SYSTEM=$SYSTEM"' "$root/bootstrap.sh" 3<<<"$input" </dev/null 2>&1
  fi
}

# S1. sudo -n works: yes, saved, no prompt.
mkdir -p "$T/s1"
: >"$T/sudo.log"
out=$(run "$T/s1" - FAKE_SUDO_N=0 FAKE_SUDO_LOG="$T/sudo.log") || fail "S1: exit — $out"
grep -q '^SYSTEM=yes$' <<<"$out" || fail "S1: $out"
grep -q '^sudo = "yes"$' "$T/s1/config.local.toml" || fail "S1: sudo = yes not saved"
grep -q 'sudo -v' "$T/sudo.log" && fail "S1: prompted although sudo -n worked"
# S2. terminal, prompt succeeds: yes, saved.
mkdir -p "$T/s2"
out=$(run "$T/s2" $'Ann\nann@x' FAKE_SUDO_N=1 FAKE_SUDO_V=0) || fail "S2: exit — $out"
grep -q '^SYSTEM=yes$' <<<"$out" || fail "S2: $out"
grep -q '^sudo = "yes"$' "$T/s2/config.local.toml" || fail "S2: not saved"
# S3. terminal, prompt fails: no, saved, warning names how to apply later.
mkdir -p "$T/s3"
out=$(run "$T/s3" $'Ann\nann@x' FAKE_SUDO_N=1 FAKE_SUDO_V=1) || fail "S3: exit — $out"
grep -q '^SYSTEM=no$' <<<"$out" || fail "S3: $out"
grep -q '^sudo = "no"$' "$T/s3/config.local.toml" || fail "S3: no not saved"
grep -q 're-run ./bootstrap.sh' <<<"$out" || fail "S3: no how-to: $out"
# S7. Ctrl-C at the password prompt: counts as no, saved, the run continues.
mkdir -p "$T/s7"
out=$(run "$T/s7" $'Ann\nann@x' FAKE_SUDO_N=1 FAKE_SUDO_V=int) || fail "S7: exit — $out"
grep -q '^SYSTEM=no$' <<<"$out" || fail "S7: $out"
grep -q '^sudo = "no"$' "$T/s7/config.local.toml" || fail "S7: no not saved"
grep -q 're-run ./bootstrap.sh' <<<"$out" || fail "S7: no how-to: $out"
# S4. no terminal, no cached sudo: no for this run, nothing saved.
mkdir -p "$T/s4"
out=$(run "$T/s4" - FAKE_SUDO_N=1) || fail "S4: exit — $out"
grep -q '^SYSTEM=no$' <<<"$out" || fail "S4: $out"
grep -q '^sudo = ' "$T/s4/config.local.toml" 2>/dev/null && fail "S4: saved a decision without asking"
# S5. no sudo binary: no, saved.
mkdir -p "$T/s5" "$T/nosudo"
for c in awk sed grep mktemp mv mkdir dirname cat; do ln -sf "$(command -v $c)" "$T/nosudo/$c"; done
out=$(env PATH="$T/nosudo" WORKSTATION_BOOTSTRAP_LIB=1 REPO_DIR_OVERRIDE="$T/s5" "$(command -v setsid)" -w "$(command -v bash)" -c 'source "$0"; REPO_DIR=$REPO_DIR_OVERRIDE; resolve_system_steps; echo "SYSTEM=$SYSTEM"' "$root/bootstrap.sh" </dev/null 3<&- 2>&1) || fail "S5: exit — $out"
grep -q '^SYSTEM=no$' <<<"$out" || fail "S5: $out"
# S6. the saved decision through scripts/lib/bootstrap-fn.sh (what tasks/update
# reads): missing is empty (treated as yes), a saved "no" with a comment is no.
printf '[vars]\nname = "N"\n' >"$T/s6.toml"
[ -z "$("$root/scripts/lib/bootstrap-fn.sh" config_get "$T/s6.toml" sudo)" ] || fail "S6: a missing sudo isn't empty"
printf '[vars]\nsudo = "no" # no sudo here\n' >"$T/s6.toml"
[ "$("$root/scripts/lib/bootstrap-fn.sh" config_get "$T/s6.toml" sudo)" = no ] || fail "S6: saved no not read"
# 6. config_set keeps other tables and escapes quotes; config_get reads back.
mkdir -p "$T/c6"
printf '[vars]\nname = "Old"\n\n[dotfiles]\n"~/.x" = { source = "x", mode = "copy", enabled = false }\n' >"$T/c6/config.local.toml"
WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$0"; config_set "$1" name "Q \"q\""; config_set "$1" sudo yes; config_get "$1" name' \
  "$root/bootstrap.sh" "$T/c6/config.local.toml" >"$T/c6/got" || fail "config_set/get failed"
grep -q '^\[dotfiles\]$' "$T/c6/config.local.toml" || fail "config_set dropped [dotfiles]"
grep -q '^sudo = "yes"$' "$T/c6/config.local.toml" || fail "config_set did not add sudo"
[ "$(grep -c '^name = ' "$T/c6/config.local.toml")" = 1 ] || fail "config_set duplicated name"
grep -qF 'name = "Q \"q\""' "$T/c6/config.local.toml" || fail "config_set did not escape quotes"

# 8. Under a REAL pty (fd 3 NOT pre-opened, so open_prompt_fd has to exec
# 3</dev/tty itself), the name prompt and a later stderr write must both
# still be visible. Regression test for the Critical bug where a bare
# `exec 3</dev/tty 2>/dev/null` (no command word) redirects fd 2 to
# /dev/null PERMANENTLY the moment /dev/tty opens, silencing every later
# message (including a later `fail`) for the rest of the run.
if command -v script >/dev/null 2>&1; then
  mkdir -p "$T/c8"
  inner="env WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source \"$root/bootstrap.sh\"; REPO_DIR=\"$T/c8\"; resolve_host_config; echo probe >&2'"
  out=$(printf 'A\na@x\n' | timeout 15 script -qec "$inner" /dev/null 2>&1) || true
  grep -q 'Name:' <<<"$out" || fail "pty: name prompt missing (stderr clobbered?): $out"
  grep -q 'probe' <<<"$out" || fail "pty: stderr write after the prompt missing (stderr clobbered): $out"
  grep -q '^name = "A"$' "$T/c8/config.local.toml" || fail "pty: prompt answer not saved"
else
  echo "SKIP: pty regression case (no 'script' binary on PATH)"
fi

# 9. A [vars] header with a trailing space and a CRLF line ending is still
# recognized: config_set must not append a duplicate [vars] table, and the
# existing value must still be readable.
mkdir -p "$T/c9"
printf '[vars] \r\nname = "Old"\r\n' >"$T/c9/config.local.toml"
WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$0"; config_set "$1" sudo yes; config_get "$1" name' \
  "$root/bootstrap.sh" "$T/c9/config.local.toml" >"$T/c9/got" || fail "CRLF header: config_set/get failed"
[ "$(grep -c '^\[vars\]' "$T/c9/config.local.toml")" = 1 ] || fail "CRLF header: duplicate [vars] table"
grep -q '^sudo = "yes"$' "$T/c9/config.local.toml" || fail "CRLF header: sudo not added"
grep -qx 'Old' "$T/c9/got" || fail "CRLF header: config_get did not read back the existing value"

# 10. confirm_reinstall reads the --reinstall confirmation from fd 3, not
# plain stdin (which under curl | bash is the piped script itself, so a
# plain `read` there hits EOF and set -e used to exit silently — the bug
# this guards against). YES=true bypasses the prompt entirely; "n" aborts;
# "y" proceeds; with no fd 3 and no terminal it fails with the --yes hint.
confirm() { # confirm <stdin-for-fd3|-> -> EXIT=0|1 (or the fail() message)
  local input=$1
  if [ "$input" = - ]; then
    env WORKSTATION_BOOTSTRAP_LIB=1 setsid -w bash -c \
      'source "$0"; YES=false; if confirm_reinstall; then echo EXIT=0; else echo EXIT=$?; fi' \
      "$root/bootstrap.sh" </dev/null 3<&- 2>&1
  else
    env WORKSTATION_BOOTSTRAP_LIB=1 setsid -w bash -c \
      'source "$0"; YES=false; if confirm_reinstall; then echo EXIT=0; else echo EXIT=$?; fi' \
      "$root/bootstrap.sh" 3<<<"$input" </dev/null 2>&1
  fi
}

out=$(env WORKSTATION_BOOTSTRAP_LIB=1 setsid -w bash -c \
  'source "$0"; YES=true; if confirm_reinstall; then echo EXIT=0; else echo EXIT=$?; fi' \
  "$root/bootstrap.sh" </dev/null 3<&- 2>&1) || fail "confirm YES=true: exit $? — $out"
grep -q 'EXIT=0$' <<<"$out" || fail "YES=true did not bypass the prompt: $out"

out=$(confirm n) || fail "confirm n: exit $? — $out"
grep -q 'EXIT=1$' <<<"$out" || fail "'n' did not abort: $out"

out=$(confirm y) || fail "confirm y: exit $? — $out"
grep -q 'EXIT=0$' <<<"$out" || fail "'y' did not proceed: $out"

if out=$(confirm -); then fail "no-terminal reinstall confirm succeeded: $out"; fi
grep -q 'Re-run with --yes' <<<"$out" || fail "no-terminal reinstall confirm missing --yes hint: $out"

# 11. config_get reads hand-edited TOML: a trailing comment, literal
# ('single-quoted') strings, a '#' inside quotes, escapes in basic strings.
mkdir -p "$T/c11"
cat >"$T/c11/config.local.toml" <<'TOML'
[vars]
editor = "hx" # laptop
name = 'O\x "q"'   # literal: no escapes
email = "a # b" # not part of the value
k1 = "Q \"q\" \\ z"
k2 = 'lit'
k3 = "t"	# tab before the comment
TOML
get() { WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$0"; config_get "$1" "$2"' "$root/bootstrap.sh" "$T/c11/config.local.toml" "$1"; }
[ "$(get editor)" = 'hx' ] || fail "config_get: trailing comment after a basic string: got [$(get editor)]"
[ "$(get name)" = 'O\x "q"' ] || fail "config_get: literal string: got [$(get name)]"
[ "$(get email)" = 'a # b' ] || fail "config_get: '#' inside quotes: got [$(get email)]"
[ "$(get k1)" = 'Q "q" \ z' ] || fail "config_get: basic-string escapes: got [$(get k1)]"
[ "$(get k2)" = 'lit' ] || fail "config_get: literal string without comment: got [$(get k2)]"
[ "$(get k3)" = 't' ] || fail "config_get: tab before a comment: got [$(get k3)]"

# 12. --reinstall without a terminal still wipes (nothing to ask first), and the
# "Will REMOVE" list names config.local.toml (name, email, sudo).
reinstall() { # reinstall <dir> [VAR=value ...] -> wipe outcome
  local dir=$1
  shift
  env "$@" WORKSTATION_BOOTSTRAP_LIB=1 REPO_DIR_OVERRIDE="$dir" setsid -w bash -c \
    'source "$0"; REPO_DIR=$REPO_DIR_OVERRIDE; YES=true; do_reinstall; echo "REINSTALL-DONE"' \
    "$root/bootstrap.sh" </dev/null 3<&- 2>&1
}
mkdir -p "$T/c12/repo" && : >"$T/c12/repo/config.local.toml"
out=$(reinstall "$T/c12/repo") || fail "--reinstall failed: $out"
grep -q 'REINSTALL-DONE' <<<"$out" || fail "--reinstall did not finish: $out"
grep -q 'config.local.toml (name, email, sudo)' <<<"$out" || fail "--reinstall REMOVE list: $out"
[ ! -e "$T/c12/repo" ] || fail "--reinstall did not wipe the checkout"

# L1-L7. set_login_shell: a local account goes through usermod; a directory
# (SSSD) account gets a per-host sss_override plus an sssd restart; a directory
# account outside SSSD gets an explanation. Stubs: getent answers from FAKE_ACCT
# (local|sss|other) and the shell in $T/ls.shell; sudo logs and simulates
# usermod, sss_override (pending until `systemctl restart sssd`), dnf; rpm
# answers for sssd-tools from FAKE_SSSD_TOOLS.
LB="$T/ls-bin"
mkdir -p "$LB"
printf '#!/usr/bin/env bash\nexit 0\n' >"$LB/zsh"
cat >"$LB/getent" <<'EOF'
#!/usr/bin/env bash
src=all
[ "$1" = -s ] && { src=$2; shift 2; }
case "$src:${FAKE_ACCT:-local}" in
files:local | sss:sss | all:*) printf '%s:x:1000:1000::/home/%s:%s\n' "$USER" "$USER" "$(cat "$FAKE_SHELL_FILE")" ;;
*) exit 2 ;;
esac
EOF
cat >"$LB/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"$FAKE_LOG"
case "$1 ${2:-}" in
"usermod -s")
  if [ -n "${FAKE_USERMOD_FAIL:-}" ]; then
    echo "usermod: user '$4' does not exist in /etc/passwd" >&2
    exit 6
  fi
  echo "$3" >"$FAKE_SHELL_FILE"
  ;;
"sss_override user-add") echo "$5" >"$FAKE_SHELL_FILE.pending" ;;
"systemctl restart")
  [ -z "${FAKE_RESTART_NOOP:-}" ] && [ -f "$FAKE_SHELL_FILE.pending" ] && mv "$FAKE_SHELL_FILE.pending" "$FAKE_SHELL_FILE"
  ;;
esac
exit 0
EOF
cat >"$LB/rpm" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "-q sssd-tools" ] && [ -n "${FAKE_SSSD_TOOLS:-}" ]
EOF
chmod +x "$LB"/*
# ls_run <start-shell> [VAR=value ...]: set_login_shell for user `tuser`.
ls_run() {
  echo "$1" >"$T/ls.shell"
  rm -f "$T/ls.shell.pending"
  : >"$T/ls.log"
  env "${@:2}" PATH="$LB:$PATH" USER=tuser FAKE_LOG="$T/ls.log" FAKE_SHELL_FILE="$T/ls.shell" \
    WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$0"; set_login_shell; echo "SHELL_CHANGED=$SHELL_CHANGED"' "$root/bootstrap.sh" 2>&1
}
out=$(ls_run /bin/bash FAKE_ACCT=local)
grep -qx "sudo usermod -s $LB/zsh tuser" "$T/ls.log" || fail "L1: no usermod: $(cat "$T/ls.log")"
[ "$(cat "$T/ls.shell")" = "$LB/zsh" ] || fail "L1: shell not set"
grep -q 'Default shell set to zsh' <<<"$out" || fail "L1: $out"
grep -qx 'SHELL_CHANGED=true' <<<"$out" || fail "L1: SHELL_CHANGED not set (the closing tip would be missing)"
out=$(ls_run /bin/bash FAKE_ACCT=local FAKE_USERMOD_FAIL=1)
grep -q "does not exist in /etc/passwd" <<<"$out" || fail "L2: usermod's error hidden: $out"
out=$(ls_run /bin/bash FAKE_ACCT=sss FAKE_SSSD_TOOLS=1)
grep -q usermod "$T/ls.log" && fail "L3: usermod tried for a directory account"
grep -qx "sudo sss_override user-add tuser -s $LB/zsh" "$T/ls.log" || fail "L3: no override: $(cat "$T/ls.log")"
grep -qx 'sudo systemctl restart sssd' "$T/ls.log" || fail "L3: sssd not restarted: $(cat "$T/ls.log")"
grep -q 'install' "$T/ls.log" && fail "L3: sssd-tools reinstalled"
[ "$(cat "$T/ls.shell")" = "$LB/zsh" ] || fail "L3: shell not set"
grep -q 'SSSD override' <<<"$out" || fail "L3: $out"
out=$(ls_run /bin/bash FAKE_ACCT=sss)
[ "$(head -1 "$T/ls.log")" = 'sudo dnf install -y sssd-tools' ] || fail "L4: sssd-tools not installed first: $(cat "$T/ls.log")"
[ "$(cat "$T/ls.shell")" = "$LB/zsh" ] || fail "L4: shell not set"
out=$(ls_run /bin/bash FAKE_ACCT=sss FAKE_SSSD_TOOLS=1 FAKE_RESTART_NOOP=1)
grep -q 'still reports /bin/bash' <<<"$out" || fail "L5: no warning when the override didn't take: $out"
grep -qx 'SHELL_CHANGED=false' <<<"$out" || fail "L5: SHELL_CHANGED set although nothing changed"
out=$(ls_run /bin/bash FAKE_ACCT=other)
[ -s "$T/ls.log" ] && fail "L6: sudo ran for a non-SSSD directory account: $(cat "$T/ls.log")"
grep -q 'directory account outside SSSD' <<<"$out" || fail "L6: $out"
out=$(ls_run "$LB/zsh" FAKE_ACCT=sss)
[ -s "$T/ls.log" ] && fail "L7: sudo ran although the shell is already zsh: $(cat "$T/ls.log")"
grep -q 'already zsh' <<<"$out" || fail "L7: $out"
grep -qx 'SHELL_CHANGED=false' <<<"$out" || fail "L7: SHELL_CHANGED set on a re-run (the tip would repeat)"

# U1/U2. tasks/update: runs the full bootstrap when sudo is unset; passes
# --skip packages,files when sudo = "no".
U="$T/u"
mkdir -p "$U/repo/tasks" "$U/repo/scripts/lib" "$U/bin"
cp "$root/tasks/update" "$U/repo/tasks/update"
cp "$root/bootstrap.sh" "$U/repo/"
cp "$root/scripts/lib/mise-env.sh" "$root/scripts/lib/bootstrap-fn.sh" "$U/repo/scripts/lib/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$U/repo/scripts/lib/mise-install.sh"
chmod +x "$U/repo/scripts/lib/mise-install.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$U/bin/git"
printf '#!/usr/bin/env bash\necho "mise $*" >>"%s/mise.log"\n' "$U" >"$U/bin/mise"
chmod +x "$U/bin/git" "$U/bin/mise"
printf '[vars]\nname = "N"\n' >"$U/repo/config.local.toml"
: >"$U/mise.log"
env PATH="$U/bin:$PATH" XDG_CONFIG_HOME="$U/xdg" bash -c 'mkdir -p "$XDG_CONFIG_HOME/mise"; "$0"' "$U/repo/tasks/update" >/dev/null 2>&1 || fail "U1: update failed"
grep -qx 'mise bootstrap --yes' "$U/mise.log" || fail "U1: expected a full bootstrap: $(cat "$U/mise.log")"
printf '[vars]\nsudo = "no"\n' >"$U/repo/config.local.toml"
: >"$U/mise.log"
env PATH="$U/bin:$PATH" XDG_CONFIG_HOME="$U/xdg" "$U/repo/tasks/update" >/dev/null 2>&1 || fail "U2: update failed"
grep -qx 'mise bootstrap --yes --skip packages,files' "$U/mise.log" || fail "U2: expected the skip: $(cat "$U/mise.log")"

echo "PASS: bootstrap.sh identity prompts, sudo decision (cached, prompt ok/fail, interrupted prompt, no terminal, no binary, saved state), login shell (local usermod, SSSD override, other directory), pty stderr safety, CRLF header, config.local.toml writer, hand-edited TOML, --reinstall, update sudo skip"
