#!/usr/bin/env bash
# Offline tests for bootstrap.sh: identity prompts and the config.local.toml
# writer, the sudo decision (stubbed sudo), the --reinstall confirmation.
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
-v) exit "${FAKE_SUDO_V:-1}" ;;  # the password prompt
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
# S6. sudo_state: missing means yes; saved no is no.
printf '[vars]\nname = "N"\n' >"$T/s6.toml"
[ "$(WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$0"; sudo_state "$1"' "$root/bootstrap.sh" "$T/s6.toml")" = yes ] || fail "S6: missing is not yes"
printf '[vars]\nsudo = "no" # no sudo here\n' >"$T/s6.toml"
[ "$(WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$0"; sudo_state "$1"' "$root/bootstrap.sh" "$T/s6.toml")" = no ] || fail "S6: saved no not read"
# T1. the stale mode line is dropped (indented, commented, CRLF), the rest kept; WORKSTATION_MODE is ignored with a note.
mkdir -p "$T/t1"
printf '[vars]\r\n  mode = "owned" # laptop\r\nname = "N"\r\nemail = "e@x"\r\n' >"$T/t1/config.local.toml"
out=$(run "$T/t1" - FAKE_SUDO_N=0 WORKSTATION_MODE=shared) || fail "T1: exit — $out"
grep -q 'mode' "$T/t1/config.local.toml" && fail "T1: mode line kept: $(cat "$T/t1/config.local.toml")"
grep -q '^name = "N"' "$T/t1/config.local.toml" || fail "T1: name lost"
grep -q 'WORKSTATION_MODE is no longer used' <<<"$out" || fail "T1: no note for WORKSTATION_MODE: $out"

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
mode = "owned" # laptop
name = 'O\x "q"'   # literal: no escapes
email = "a # b" # not part of the value
k1 = "Q \"q\" \\ z"
k2 = 'shared'
k3 = "t"	# tab before the comment
TOML
get() { WORKSTATION_BOOTSTRAP_LIB=1 bash -c 'source "$0"; config_get "$1" "$2"' "$root/bootstrap.sh" "$T/c11/config.local.toml" "$1"; }
[ "$(get mode)" = 'owned' ] || fail "config_get: trailing comment after a basic string: got [$(get mode)]"
[ "$(get name)" = 'O\x "q"' ] || fail "config_get: literal string: got [$(get name)]"
[ "$(get email)" = 'a # b' ] || fail "config_get: '#' inside quotes: got [$(get email)]"
[ "$(get k1)" = 'Q "q" \ z' ] || fail "config_get: basic-string escapes: got [$(get k1)]"
[ "$(get k2)" = 'shared' ] || fail "config_get: literal string without comment: got [$(get k2)]"
[ "$(get k3)" = 't' ] || fail "config_get: tab before a comment: got [$(get k3)]"

# 12. --reinstall without a terminal still wipes (no mode to ask), and the
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

# U1/U2. tasks/update: drops a stale mode line and runs the full bootstrap when
# sudo is unset; passes --skip packages,files when sudo = "no".
U="$T/u"
mkdir -p "$U/repo/tasks" "$U/repo/scripts/lib" "$U/bin"
cp "$root/tasks/update" "$U/repo/tasks/update"
cp "$root/bootstrap.sh" "$U/repo/"
cp "$root/scripts/lib/mise-env.sh" "$U/repo/scripts/lib/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$U/repo/scripts/lib/mise-install.sh"
chmod +x "$U/repo/scripts/lib/mise-install.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$U/bin/git"
printf '#!/usr/bin/env bash\necho "mise $*" >>"%s/mise.log"\n' "$U" >"$U/bin/mise"
chmod +x "$U/bin/git" "$U/bin/mise"
printf '[vars]\nmode = "owned"\nname = "N"\n' >"$U/repo/config.local.toml"
: >"$U/mise.log"
env PATH="$U/bin:$PATH" XDG_CONFIG_HOME="$U/xdg" bash -c 'mkdir -p "$XDG_CONFIG_HOME/mise"; "$0"' "$U/repo/tasks/update" >/dev/null 2>&1 || fail "U1: update failed"
grep -q 'mode' "$U/repo/config.local.toml" && fail "U1: mode line kept"
grep -qx 'mise bootstrap --yes' "$U/mise.log" || fail "U1: expected a full bootstrap: $(cat "$U/mise.log")"
printf '[vars]\nsudo = "no"\n' >"$U/repo/config.local.toml"
: >"$U/mise.log"
env PATH="$U/bin:$PATH" XDG_CONFIG_HOME="$U/xdg" "$U/repo/tasks/update" >/dev/null 2>&1 || fail "U2: update failed"
grep -qx 'mise bootstrap --yes --skip packages,files' "$U/mise.log" || fail "U2: expected the skip: $(cat "$U/mise.log")"

echo "PASS: bootstrap.sh identity prompts, sudo decision (cached, prompt ok/fail, no terminal, no binary, saved state), stale mode cleanup, pty stderr safety, CRLF header, config.local.toml writer, hand-edited TOML, --reinstall"
