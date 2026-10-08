#!/usr/bin/env bash
# test-nu-init.sh: scripts/nu-init.nu writes one init file per tool into a vendor
# autoload dir, leaves unchanged files alone, drops a missing tool's file, keeps the
# last good file when a tool fails, never touches files it doesn't own, imports
# Nushell's history into atuin once, labels atuin's background jobs so starship's
# jobs gear skips them, and always exits 0. The tools are stubs on PATH.
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
  # mise.nu wraps mise's output (see the mise.nu cases below); the rest are verbatim.
  if [ "$t" = mise ]; then has="grep -qx '# mise init' '$DIR/mise.nu'"; else has="[ \"\$(cat '$DIR/$t.nu')\" = '# $t init' ]"; fi
  check "$t.nu written from '$t' (no BOM)" bash -c "$has && [ \"\$(head -c3 '$DIR/$t.nu' | od -An -tx1 | tr -d ' \n')\" != efbbbf ]"
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
# in_session <file> <nu code> [NAME=value...]: source <file> in a session whose PATH is
# /live/x:/usr/bin:/bin and that has no mise state of its own, then run <nu code>.
in_session() {
  local file="$1" code="$2"
  shift 2
  env -u __MISE_ORIG_PATH -u __MISE_DIFF -u __MISE_SESSION -u MISE_SHELL PATH="/live/x:/usr/bin:/bin" "$@" \
    "$NU" --no-config-file --commands "source '$file'; $code" 2>&1
}
check "mise.nu: mise's output is kept verbatim, between nu-init's prologue and epilogue" bash -c "[[ \"\$(cat '$M')\" == *\"\$(cat '$T/mise-activate.nu')\"* ]] && head -n1 '$M' | grep -q '^# nu-init:' && tail -n1 '$M' | grep -q '^hide-env __NU_INIT_PATH'"
check "mise.nu: no warning for mise's output" bash -c "! printf '%s' \"\$1\" | grep -q warning" _ "$OUT"
LIVE="$(in_session "$M" 'print ($env.PATH | str join ":")')"
check "sourcing mise.nu keeps the session's PATH (/live/x) and drops the snapshot (/snap/a)" bash -c "printf '%s' \"\$1\" | grep -q '/live/x' && ! printf '%s' \"\$1\" | grep -q '/snap/a'" _ "$LIVE"
check "sourcing mise.nu: __MISE_ORIG_PATH is the session's PATH" [ "$(in_session "$M" 'print $env.__MISE_ORIG_PATH')" = "/live/x:/usr/bin:/bin" ]
check "sourcing mise.nu: a parent shell's __MISE_ORIG_PATH is kept" [ "$(in_session "$M" 'print $env.__MISE_ORIG_PATH' __MISE_ORIG_PATH=/parent/p)" = "/parent/p" ]
check "sourcing mise.nu: mise's other rows still apply, and nu-init leaves no variables behind" \
  [ "$(in_session "$M" 'print ([($env.GOBIN? | default gone) $env.MISE_SHELL ($env | columns | where $it =~ "^__NU_INIT" | length)] | str join " ")' GOBIN=/go/bin)" = "gone nu 0" ]

# Run outside a mise session (a fresh sign-in, CI), mise's update block is empty: no
# set,PATH row. The snapshot line is still there and must still be undone.
sed -e "/^  'hide,GOBIN,\$/,/^hide,MISE_SHELL,' | parse vars | update-env\$/c\\
  '' | parse vars | update-env" "$T/mise-activate.nu" >"$T/mise-activate-fresh.nu"
printf '#!/usr/bin/env bash\ncat "%s"\n' "$T/mise-activate-fresh.nu" >"$BIN/mise"
rm -rf "$DIR"
run
check "mise.nu, no set,PATH row: wrapped verbatim, no warning" bash -c "[[ \"\$(cat '$M')\" == *\"\$(cat '$T/mise-activate-fresh.nu')\"* ]] && ! printf '%s' \"\$1\" | grep -q warning" _ "$OUT"
LIVE="$(in_session "$M" 'print ($env.PATH | str join ":")')"
check "mise.nu, no set,PATH row: sourcing keeps the session's PATH" bash -c "printf '%s' \"\$1\" | grep -q '/live/x' && ! printf '%s' \"\$1\" | grep -q '/snap/a'" _ "$LIVE"
check "mise.nu, no set,PATH row: __MISE_ORIG_PATH is the session's PATH" [ "$(in_session "$M" 'print $env.__MISE_ORIG_PATH')" = "/live/x:/usr/bin:/bin" ]

# Nothing depends on the exact form of mise's output: any other output is wrapped too.
printf '#!/usr/bin/env bash\nprintf "# some other format\\n"\n' >"$BIN/mise"
run
check "mise.nu: any other output is wrapped the same way, without a warning" bash -c "grep -qx '# some other format' '$M' && head -n1 '$M' | grep -q '^# nu-init:' && ! printf '%s' \"\$1\" | grep -q warning" _ "$OUT"
check "mise.nu, any other output: sourcing keeps the session's PATH" [ "$(in_session "$M" 'print ($env.PATH | str join ":")')" = "/live/x:/usr/bin:/bin" ]

# The real mise's output (CI's templates job has it). $T/snap is only on the generator's
# PATH, so it marks mise's snapshot: sourcing drops it, keeps the session's PATH, and
# mise's prompt hook rebuilds PATH from the session's PATH, never the snapshot.
REAL_MISE="$(command -v mise || true)"
if [ -n "$REAL_MISE" ]; then
  mkdir -p "$T/realbin" "$T/snap"
  ln -sf "$REAL_MISE" "$T/realbin/mise"
  # Without __MISE_ORIG_PATH in the environment mise writes it into the file (as on
  # Windows); with it inherited, mise omits the line. Both shapes must be undone.
  # env -i drops the caller's mise session (__MISE_DIFF, __MISE_SESSION), so this
  # runs the same here as on a fresh CI runner.
  for orig in unset inherited; do
    rm -rf "$DIR"
    gen=(env -i HOME="$HOME" PATH="$T/snap:$T/realbin:/usr/bin:/bin" XDG_CONFIG_HOME="$T/cfg")
    [ "$orig" = inherited ] && gen+=(__MISE_ORIG_PATH=/usr/bin:/bin)
    OUT="$("${gen[@]}" "$NU" --no-config-file "$ROOT/scripts/nu-init.nu" --dir "$DIR" --state-dir "$STATE" 2>&1)"
    check "real mise ($orig __MISE_ORIG_PATH): its output is wrapped, snapshot and all, no warning" bash -c "head -n1 '$M' | grep -q '^# nu-init:' && grep -qF '$T/snap' '$M' && ! printf '%s' \"\$1\" | grep -q warning" _ "$OUT"
    LIVE="$(in_session "$M" 'print ($env.PATH | str join ":")')"
    check "real mise ($orig __MISE_ORIG_PATH): sourcing mise.nu keeps the session's PATH" [ "$LIVE" = "/live/x:/usr/bin:/bin" ]
    HOOKED="$(in_session "$M" 'mise_hook; print ($env.PATH | str join ":")')"
    check "real mise ($orig __MISE_ORIG_PATH): mise's prompt hook keeps the session's PATH, not the snapshot" bash -c "printf '%s' \"\$1\" | grep -q '/live/x' && ! printf '%s' \"\$1\" | grep -qF '$T/snap'" _ "$HOOKED"
  done
else
  echo "  SKIP real mise: not on PATH"
fi

# atuin's hooks start background jobs (`history end` on every prompt, the search index
# at startup), and starship.nu counts `job list` for its jobs gear, so the gear showed on
# nearly every prompt; in zsh atuin's work isn't a shell job. atuin.nu labels its jobs
# and starship.nu leaves them out of the count.
cat >"$T/atuin-init.nu" <<'EOF'
let _atuin_pre_prompt = {||
    if (version).minor >= 104 or (version).major > 0 {
        job spawn {
            ^atuin history end --hook -- $env.ATUIN_HISTORY_ID | complete
        } | ignore
    }
}
if (version).minor >= 104 or (version).major > 0 {
    with-env { ATUIN_SHELL: nu } {
        job spawn {
            atuin __internal prepare-search-index | complete
        } | ignore
    }
}
EOF
cat >"$T/starship-init.nu" <<'EOF'
export-env { $env.PROMPT_COMMAND = {||
    ^starship prompt ...(
        if (which "job list" | where type == built-in | is-not-empty) {
            ["--jobs", (job list | length)]
        } else { [] }
    )
} }
EOF
printf '#!/usr/bin/env bash\nif [ "$1" = import ]; then exit 0; fi\ncat "%s"\n' "$T/atuin-init.nu" >"$BIN/atuin"
printf '#!/usr/bin/env bash\ncat "%s"\n' "$T/starship-init.nu" >"$BIN/starship"
chmod +x "$BIN/atuin" "$BIN/starship"
rm -rf "$DIR"
run
A="$DIR/atuin.nu"
S="$DIR/starship.nu"
check "atuin.nu: both of atuin's job spawns carry --description atuin" bash -c "[ \"\$(grep -c 'job spawn --description atuin {' '$A')\" -eq 2 ] && ! grep -q 'job spawn {' '$A'"
check "starship.nu: the jobs count leaves atuin's jobs out" bash -c "grep -qF \"(job list | where description? != 'atuin' | length)\" '$S' && ! grep -qF '(job list | length)' '$S'"
check "atuin.nu / starship.nu: no warning for the expected format" bash -c "! printf '%s' \"\$1\" | grep -qE '(atuin|starship)\\.nu: unexpected'" _ "$OUT"
GEAR="$("$NU" --no-config-file --commands "job spawn --description atuin { sleep 2sec } | ignore; print (job list | where description? != 'atuin' | length); job spawn { sleep 2sec } | ignore; print (job list | where description? != 'atuin' | length)" 2>&1 | tr '\n' ' ')"
check "an atuin-labelled job isn't counted, the user's own job is ('0 1', got '$GEAR')" [ "$GEAR" = "0 1 " ]
# A changed format is written as-is, with a warning (the gear may then show atuin's jobs).
printf 'job spawn --other {\n  x\n} | ignore\n' >"$T/atuin-init.nu"
printf 'let n = (job list | where x | length)\n' >"$T/starship-init.nu"
run
check "atuin.nu / starship.nu: an unexpected format is kept, with a warning each" bash -c "grep -q 'job spawn --other {' '$A' && grep -qF '(job list | where x | length)' '$S' && printf '%s' \"\$1\" | grep -q 'atuin.nu: unexpected' && printf '%s' \"\$1\" | grep -q 'starship.nu: unexpected'" _ "$OUT"

# The real atuin and starship (where installed): the patterns must still match theirs.
REAL_ATUIN="$(command -v atuin || true)"
REAL_STARSHIP="$(command -v starship || true)"
if [ -n "$REAL_ATUIN" ] && [ -n "$REAL_STARSHIP" ]; then
  mkdir -p "$T/realbin2"
  ln -sf "$REAL_ATUIN" "$T/realbin2/atuin"
  ln -sf "$REAL_STARSHIP" "$T/realbin2/starship"
  rm -rf "$DIR"
  OUT="$(env -i HOME="$HOME" PATH="$T/realbin2:/usr/bin:/bin" XDG_CONFIG_HOME="$T/cfg" "$NU" --no-config-file "$ROOT/scripts/nu-init.nu" --dir "$DIR" --state-dir "$STATE" 2>&1)"
  check "real atuin + starship: atuin's jobs labelled, starship skips them, no warning" bash -c "grep -q 'job spawn --description atuin {' '$A' && ! grep -q 'job spawn {' '$A' && grep -qF \"(job list | where description? != 'atuin' | length)\" '$S' && ! printf '%s' \"\$1\" | grep -qE '(atuin|starship)\\.nu: unexpected'" _ "$OUT"
else
  echo "  SKIP real atuin + starship: not both on PATH"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[0;32m✓ all %d nu-init cases passed\033[0m\n' "$pass"
  exit 0
fi
printf '\033[0;31m✗ %d/%d nu-init cases failed\033[0m\n' "$fail" "$((pass + fail))"
exit 1
