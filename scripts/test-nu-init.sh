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
  OUT="$(PATH="$BIN:/usr/bin:/bin" "$NU" --no-config-file "$ROOT/scripts/nu-init.nu" --dir "$DIR" 2>&1)"
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
has_out() { printf '%s' "$OUT" | grep -qF -- "$1"; }
file_is() { [ "$(cat "$DIR/$1")" = "$2" ]; }
no_bom() { [ "$(head -c3 "$DIR/$1" | od -An -tx1 | tr -d ' \n')" != efbbbf ]; }
calls() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }

for t in starship mise zoxide; do stub "$t"; done
stub_atuin
mkdir -p "$DIR"
printf '$env.FOO = 1\n' >"$DIR/omp-env.nu"

run
check "first run exits 0" [ "$RC" -eq 0 ]
for t in starship mise zoxide atuin; do
  check "$t.nu written from '$t' (no BOM)" bash -c "[ \"\$(cat '$DIR/$t.nu')\" = '# $t init' ] && [ \"\$(head -c3 '$DIR/$t.nu' | od -An -tx1 | tr -d ' \n')\" != efbbbf ]"
done
check "mise is called with -C <home> activate nu" grep -qE '^mise -C /.+ activate nu$' "$LOG"
check "atuin init uses --disable-up-arrow" grep -qF 'atuin init nu --disable-up-arrow' "$LOG"
check "atuin imports Nushell history on the first run" [ "$(calls 'atuin import nu')" -eq 1 ]
check "the import marker is written" [ -f "$DIR/.atuin-nu-imported" ]

before="$(stat -c %Y "$DIR"/*.nu | tr '\n' ' ')"
sleep 1
run
check "second run exits 0" [ "$RC" -eq 0 ]
check "second run rewrites nothing (mtimes unchanged)" [ "$(stat -c %Y "$DIR"/*.nu | tr '\n' ' ')" = "$before" ]
check "second run reports every file unchanged" [ "$(printf '%s' "$OUT" | grep -c 'unchanged')" -eq 4 ]
check "atuin import runs only once" [ "$(calls 'atuin import nu')" -eq 1 ]
check "an unowned file (omp-env.nu) survives" file_is omp-env.nu '$env.FOO = 1'

stub starship 1
run
check "a failing tool: still exits 0" [ "$RC" -eq 0 ]
check "a failing tool: its last good file is kept" file_is starship.nu '# starship init'
check "a failing tool: a warning names it" has_out 'warning: starship'
stub starship

rm "$BIN/zoxide"
run
check "a missing tool: still exits 0" [ "$RC" -eq 0 ]
check "a missing tool: its file is removed" [ ! -e "$DIR/zoxide.nu" ]
check "a missing tool: the others stay" bash -c "[ -f '$DIR/starship.nu' ] && [ -f '$DIR/mise.nu' ] && [ -f '$DIR/atuin.nu' ]"

rm -rf "$DIR"
: >"$LOG"
export ATUIN_IMPORT_RC=1
run
check "atuin import fails: exits 0, no marker, a warning" bash -c "[ $RC -eq 0 ] && [ ! -e '$DIR/.atuin-nu-imported' ]"
check "atuin import fails: the warning says it retries" has_out 'the next run retries'
export ATUIN_IMPORT_RC=0
run
check "atuin import retried and succeeded: marker written" [ -f "$DIR/.atuin-nu-imported" ]

rm -f "$BIN"/*
rm -rf "$DIR"
run
check "no tools at all: exits 0 and writes no init file" bash -c "[ $RC -eq 0 ] && [ -z \"\$(ls '$DIR'/*.nu 2>/dev/null)\" ]"

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[0;32m✓ all %d nu-init cases passed\033[0m\n' "$pass"
  exit 0
fi
printf '\033[0;31m✗ %d/%d nu-init cases failed\033[0m\n' "$fail" "$((pass + fail))"
exit 1
