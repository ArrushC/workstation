#!/usr/bin/env bash
# test-nu-init.sh: scripts/nu-init.nu writes one init file per tool into a vendor
# autoload dir, leaves unchanged files alone, drops a missing tool's file, keeps the
# last good file when a tool fails, never touches files it doesn't own, imports
# Nushell's history into atuin once, and always exits 0. The tools are stubs on PATH.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v nu >/dev/null 2>&1; then
  echo "nu not installed: skipped (CI's templates job installs the pinned nu)"
  exit 0
fi
NU="$(command -v nu)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"
DIR="$T/autoload"
STATE="$T/state"
LOG="$T/calls.log"
mkdir -p "$BIN"
pass=0
fail=0

# stub <tool> [exit-code]: records its args, then prints "# <tool> init" (or fails).
stub() {
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s"\n[ "%s" -eq 0 ] || exit %s\nprintf "# %s init\\n"\n' \
    "$1" "$LOG" "${2:-0}" "${2:-0}" "$1" >"$BIN/$1"
  chmod +x "$BIN/$1"
}
# atuin's stub answers `import` with $ATUIN_IMPORT_RC and anything else with an init.
stub_atuin() {
  printf '#!/usr/bin/env bash\necho "atuin $*" >>"%s"\nif [ "$1" = import ]; then exit "${ATUIN_IMPORT_RC:-0}"; fi\nprintf "# atuin init\\n"\n' \
    "$LOG" >"$BIN/atuin"
  chmod +x "$BIN/atuin"
}
run() {
  OUT="$(PATH="$BIN:/usr/bin:/bin" XDG_CONFIG_HOME="$T/cfg" "$NU" --no-config-file "$ROOT/scripts/nu-init.nu" --dir "$DIR" --state-dir "$STATE" 2>&1)"
  RC=$?
}
check() {
  local name="$1"
  shift
  if "$@"; then
    printf '  \033[0;32mPASS\033[0m %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  \033[0;31mFAIL\033[0m %s\n' "$name"
    printf '%s\n' "$OUT" | sed 's/^/      /'
    fail=$((fail + 1))
  fi
}
# stub_bad prints a partial init and exits 1; stub_empty exits 0 with no output.
stub_bad() {
  printf '#!/usr/bin/env bash\nprintf "# partial\\n"\nexit 1\n' >"$BIN/$1"
  chmod +x "$BIN/$1"
}
stub_empty() {
  printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/$1"
  chmod +x "$BIN/$1"
}
has_out() { printf '%s' "$OUT" | grep -qF -- "$1"; }
file_is() { [ "$(cat "$DIR/$1")" = "$2" ]; }
calls() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }

for t in starship mise zoxide; do stub "$t"; done
stub_atuin

# No Nushell history file yet: the marker is written without importing.
run
check "no history: exits 0, marker written, nothing imported" bash -c "[ $RC -eq 0 ] && [ -f '$STATE/.atuin-nu-imported' ] && [ \"\$(grep -c 'atuin import' '$LOG')\" -eq 0 ]"
check "no history: says there is nothing to import" has_out 'nothing to import'
rm -rf "$STATE" "$DIR"
: >"$LOG"

mkdir -p "$DIR" "$T/cfg/nushell"
printf 'ls\n' >"$T/cfg/nushell/history.txt"
printf '$env.FOO = 1\n' >"$DIR/omp-env.nu"

run
check "first run exits 0" [ "$RC" -eq 0 ]
for t in starship mise zoxide atuin; do
  check "$t.nu written from '$t' (no BOM)" bash -c "[ \"\$(cat '$DIR/$t.nu')\" = '# $t init' ] && [ \"\$(head -c3 '$DIR/$t.nu' | od -An -tx1 | tr -d ' \n')\" != efbbbf ]"
done
check "mise is called with -C <home> activate nu" grep -qE '^mise -C /.+ activate nu$' "$LOG"
check "atuin init uses --disable-up-arrow" grep -qF 'atuin init nu --disable-up-arrow' "$LOG"
check "atuin imports Nushell history on the first run" [ "$(calls 'atuin import nu')" -eq 1 ]
check "the import marker is written" [ -f "$STATE/.atuin-nu-imported" ]

before="$(stat -c %Y "$DIR"/*.nu | tr '\n' ' ')"
sleep 1
run
check "second run exits 0" [ "$RC" -eq 0 ]
check "second run rewrites nothing (mtimes unchanged)" [ "$(stat -c %Y "$DIR"/*.nu | tr '\n' ' ')" = "$before" ]
check "second run reports every file unchanged" [ "$(printf '%s' "$OUT" | grep -c 'unchanged')" -eq 4 ]
check "atuin import runs only once" [ "$(calls 'atuin import nu')" -eq 1 ]
check "an unowned file (omp-env.nu) survives" file_is omp-env.nu '$env.FOO = 1'

rm -rf "$DIR"
run
check "output dir deleted: files regenerated, no re-import" bash -c "[ $RC -eq 0 ] && [ -f '$DIR/starship.nu' ] && [ \"\$(grep -c 'atuin import nu' '$LOG')\" -eq 1 ]"

stub starship 1
run
check "a failing tool: still exits 0" [ "$RC" -eq 0 ]
check "a failing tool: its last good file is kept" file_is starship.nu '# starship init'
check "a failing tool: a warning names it" has_out 'warning: starship'
stub_bad starship
run
check "a tool that prints then exits 1: last good file kept" file_is starship.nu '# starship init'
stub_empty starship
run
check "a tool that prints nothing: last good file kept" file_is starship.nu '# starship init'
stub starship

rm "$BIN/zoxide"
run
check "a missing tool: still exits 0" [ "$RC" -eq 0 ]
check "a missing tool: its file is removed" [ ! -e "$DIR/zoxide.nu" ]
check "a missing tool: the others stay" bash -c "[ -f '$DIR/starship.nu' ] && [ -f '$DIR/mise.nu' ] && [ -f '$DIR/atuin.nu' ]"

rm -rf "$DIR" "$STATE"
: >"$LOG"
export ATUIN_IMPORT_RC=1
run
check "atuin import fails: exits 0 and leaves no marker" bash -c "[ $RC -eq 0 ] && [ ! -e '$STATE/.atuin-nu-imported' ]"
check "atuin import fails: the warning says it retries" has_out 'warning: atuin import nu exited 1; the next run retries'
export ATUIN_IMPORT_RC=0
run
check "atuin import retried and succeeded: marker written" [ -f "$STATE/.atuin-nu-imported" ]

# Read-only output dir: warnings, still exit 0.
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIP read-only output dir cases (running as root: chmod a-w does not block root)"
else
  rm -rf "$DIR"
  mkdir -p "$DIR"
  chmod a-w "$DIR"
  run
  chmod u+w "$DIR"
  check "read-only output dir: exits 0 with a warning" bash -c "[ $RC -eq 0 ]" && check "read-only output dir: the warning carries the detail" has_out 'failed: I/O error: Permission denied'
fi

# Default output dir: $nu.data-dir/vendor/autoload (XDG_DATA_HOME on Linux).
rm -rf "$DIR"
OUT="$(PATH="$BIN:/usr/bin:/bin" XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$T/cfg" "$NU" --no-config-file "$ROOT/scripts/nu-init.nu" --state-dir "$STATE" 2>&1)"
RC=$?
check "no --dir: writes under the data dir's vendor/autoload" bash -c "[ $RC -eq 0 ] && [ -f '$T/data/nushell/vendor/autoload/starship.nu' ]"

rm -f "$BIN"/*
rm -rf "$DIR"
run
check "no tools at all: exits 0 and writes no init file" bash -c "[ $RC -eq 0 ] && [ -z \"\$(ls '$DIR'/*.nu 2>/dev/null)\" ]"

# mise.nu keeps the session's PATH. `mise activate nu` bakes the PATH it sees into
# the file; sourced as-is, every Nushell session would get that snapshot instead of
# the PATH its terminal passed down. The stub prints the same shape as mise 2026.9.9.
cat >"$T/mise-activate.nu" <<'EOF'
def "parse vars" [] {
  $in | from csv --noheaders --no-infer | rename 'op' 'name' 'value'
}
def --env "update-env" [] {
  for $var in $in {
    if $var.op == "set" {
      if ($var.name =~ '(?i)^path$') {
        $env.PATH = ($var.value | split row (char esep))
      } else {
        load-env {($var.name): $var.value}
      }
    } else if $var.op == "hide" {
      try { hide-env $var.name }
    }
  }
}
export-env {
  $env.__MISE_ORIG_PATH = r#'/snap/a:/snap/b'#
  $env.PATH = (r#'/snap/shims:/snap/a:/snap/b'# | split row (char esep))

  'hide,GOBIN,
set,PATH,/snap/shims:/snap/a:/snap/b
hide,MISE_SHELL,' | parse vars | update-env
  $env.MISE_SHELL = "nu"
}
EOF
printf '#!/usr/bin/env bash\ncat "%s"\n' "$T/mise-activate.nu" >"$BIN/mise"
chmod +x "$BIN/mise"
rm -rf "$DIR"
run
M="$DIR/mise.nu"
check "mise.nu: __MISE_ORIG_PATH comes from the session (or its parent shell)" grep -qF '$env.__MISE_ORIG_PATH = ($env.__MISE_ORIG_PATH? | default ($env.PATH | str join (char esep)))' "$M"
check "mise.nu: the baked __MISE_ORIG_PATH line is gone" bash -c "! grep -q \"__MISE_ORIG_PATH = r#\" '$M'"
check "mise.nu: no line overwrites PATH with the snapshot" bash -c "! grep -qE '^[[:space:]]*\\\$env\\.PATH = \\(r#' '$M'"
check "mise.nu: the snapshot's set,PATH row is neutralised" bash -c "! grep -q 'set,PATH,' '$M' && grep -q 'hide,__MISE_NO_PATH_SNAPSHOT,' '$M'"
check "mise.nu: everything else is kept" bash -c "grep -q 'hide,GOBIN,' '$M' && grep -q 'MISE_SHELL = \"nu\"' '$M'"
check "mise.nu: no warning for mise's expected format" bash -c "! printf '%s' \"\$1\" | grep -q 'mise.nu: unexpected'" _ "$OUT"
LIVE="$(env -u __MISE_ORIG_PATH PATH="/live/x:/usr/bin:/bin" "$NU" --no-config-file --commands "source '$M'; print (\$env.PATH | str join ':')" 2>&1)"
check "sourcing mise.nu keeps the session's PATH (/live/x) and drops the snapshot (/snap/a)" bash -c "printf '%s' \"\$1\" | grep -q '/live/x' && ! printf '%s' \"\$1\" | grep -q '/snap/a'" _ "$LIVE"

# An unexpected format is written as-is, with a warning.
printf '#!/usr/bin/env bash\nprintf "# some other format\\n"\n' >"$BIN/mise"
run
check "mise.nu: an unexpected format is kept as-is, with a warning" bash -c "[ \"\$(cat '$M')\" = '# some other format' ] && printf '%s' \"\$1\" | grep -q 'mise.nu: unexpected'" _ "$OUT"

# The real mise's output (CI's templates job has it): the rewrite must still match it.
REAL_MISE="$(command -v mise || true)"
if [ -n "$REAL_MISE" ]; then
  mkdir -p "$T/realbin"
  ln -sf "$REAL_MISE" "$T/realbin/mise"
  # Without __MISE_ORIG_PATH in the environment mise writes it into the file (as on
  # Windows); with it inherited, mise omits the line. Both shapes must be rewritten.
  for orig in unset inherited; do
    rm -rf "$DIR"
    if [ "$orig" = unset ]; then
      OUT="$(env -u __MISE_ORIG_PATH PATH="$T/realbin:/usr/bin:/bin" XDG_CONFIG_HOME="$T/cfg" "$NU" --no-config-file "$ROOT/scripts/nu-init.nu" --dir "$DIR" --state-dir "$STATE" 2>&1)"
    else
      OUT="$(__MISE_ORIG_PATH=/usr/bin:/bin PATH="$T/realbin:/usr/bin:/bin" XDG_CONFIG_HOME="$T/cfg" "$NU" --no-config-file "$ROOT/scripts/nu-init.nu" --dir "$DIR" --state-dir "$STATE" 2>&1)"
    fi
    check "real mise ($orig __MISE_ORIG_PATH): the rewrite matches its output" bash -c "grep -qF '__MISE_ORIG_PATH = (\$env.__MISE_ORIG_PATH? | default (\$env.PATH | str join (char esep)))' '$M' && ! grep -q 'set,PATH,' '$M' && ! printf '%s' \"\$1\" | grep -q 'mise.nu: unexpected'" _ "$OUT"
    LIVE="$(env -u __MISE_ORIG_PATH PATH="/live/x:$T/realbin:/usr/bin:/bin" "$NU" --no-config-file --commands "source '$M'; print (\$env.PATH | str join ':')" 2>&1)"
    check "real mise ($orig __MISE_ORIG_PATH): sourcing mise.nu keeps the session's PATH" bash -c "printf '%s' \"\$1\" | grep -q '/live/x'" _ "$LIVE"
  done
else
  echo "  SKIP real mise: not on PATH"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[0;32m✓ all %d nu-init cases passed\033[0m\n' "$pass"
  exit 0
fi
printf '\033[0;31m✗ %d/%d nu-init cases failed\033[0m\n' "$fail" "$((pass + fail))"
exit 1
