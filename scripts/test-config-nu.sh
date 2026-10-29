#!/usr/bin/env bash
# test-config-nu.sh: the Windows Nushell config's own behaviour, run on Linux with the
# pinned nu and stubs on PATH: an alias completes as its whole expansion, Tab's menu grows
# to the terminal's width, wse/wsd/wss are defs (tracked-target completion, wss as a table,
# arguments passed through), wsa is ws apply, fssh follows ~/.ssh/config's Include lines
# (in zsh and bash too), the command-not-found hook asks mise, no transient prompt, and the
# history and timestamp settings.
# shellcheck disable=SC2016,SC2088  # nu code in single quotes; ~/... are mise target strings
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
HOMEDIR="$T/home"
CFG="$T/config.nu"
LOG="$T/calls.log"
mkdir -p "$BIN" "$HOMEDIR/.ssh"
pass=0
fail=0

# The template's only tera tags are in its header comment.
sed 's/{{[^}]*}}//g' "$ROOT/dotfiles/windows/AppData/Roaming/nushell/config.nu.tera" >"$CFG"

# mise: `dot status --json` prints the fixture; `which` answers from MISE_WHICH_*;
# anything else echoes its arguments.
cat >"$T/status.json" <<'JSON'
{
  "files": [
    { "target": "~/.gitconfig", "mode": "template", "state": "applied", "origin": { "config_root": "/h" } },
    { "target": "~/.zshrc", "mode": "template", "state": "differs", "origin": { "config_root": "/h" } }
  ],
  "edits": [],
  "history": []
}
JSON
cat >"$BIN/mise" <<EOF
#!/usr/bin/env bash
echo "mise \$*" >>"$LOG"
case " \$* " in
  *" dot status --json "*) cat "$T/status.json" ;;
  *" which "*) printf '%s' "\${MISE_WHICH_OUT:-}"; printf '%s' "\${MISE_WHICH_ERR:-}" >&2; exit "\${MISE_WHICH_RC:-0}" ;;
  *" bootstrap "*) echo "mise \$*"; exit "\${MISE_BOOTSTRAP_RC:-0}" ;;
  *) echo "mise \$*" ;;
esac
EOF
# carapace: one completion whose value is the argument list it was given.
cat >"$BIN/carapace" <<'EOF'
#!/usr/bin/env bash
printf '[{"value":"%s"}]\n' "$*"
EOF
# fzf: "picks" every candidate, sorted and comma-joined; ssh prints what it was asked to reach.
cat >"$BIN/fzf" <<'EOF'
#!/usr/bin/env bash
sort | paste -sd, -
EOF
cat >"$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh:$*"
EOF
chmod +x "$BIN"/*

write_ssh_config() {
  cat >"$HOMEDIR/.ssh/config" <<'EOF'
Include config.local
Host *
  User someone
Host zeta
  HostName zeta.example
Host sp?am
EOF
  cat >"$HOMEDIR/.ssh/config.local" <<'EOF'
Host alpha beta
  HostName alpha.example
Host !neg
EOF
}
write_ssh_config

# run_nu <nu code>: sources the rendered config.nu, then runs the code.
# NU_PRELUDE, when set, runs first (a def there shadows a builtin the config calls).
run_nu() {
  OUT="$(cd "$T" && PATH="$BIN:/usr/bin:/bin" HOME="$HOMEDIR" USERPROFILE="$HOMEDIR" \
    "$NU" --no-config-file --commands "${NU_PRELUDE:-}source '$CFG'; $1" 2>&1)"
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
has() { [ "$RC" -eq 0 ] && [[ "$OUT" == *"$1"* ]]; }
is() { [ "$RC" -eq 0 ] && [ "$OUT" = "$1" ]; }

echo "test-config-nu: $CFG"

echo "-- completion"
run_nu 'do $env.config.completions.external.completer ["gco" "ma"] | get value.0'
check "an alias completes as its whole expansion (gco ma -> git checkout ma)" is "git nushell git checkout ma"
run_nu 'alias gx = git.exe log; do $env.config.completions.external.completer ["gx" ""] | get value.0'
check "the expansion's first word loses its .exe" is "git nushell git log "
run_nu 'do $env.config.completions.external.completer ["git" "sta"] | get value.0'
check "a plain command is passed as typed" is "git nushell git sta"
# The menu-width hook, picked out by its source; it reports the menu's limit after it runs.
MENU_HOOK='do --env ($env.config.hooks.pre_prompt | where {|h| view source $h | str contains max_completion_width } | first); $env.config.menus | where name == ide_completion_menu | get 0.type.max_completion_width'
NU_PRELUDE='def "term size" [] { {columns: 140, rows: 40} }; ' run_nu "$MENU_HOOK"
check "Tab's menu may grow to the terminal's width less a description's (140 -> 124)" is "124"
NU_PRELUDE='def "term size" [] { {columns: 30, rows: 40} }; ' run_nu "$MENU_HOOK"
check "...but never below 20 columns" is "20"

run_nu 'wsh'
check "without mise's Python, wsh says how to get it" has "mise's Python isn't installed"
run_nu 'wsa'
check "...and so does wsa" has "mise's Python isn't installed"

echo "-- ws (scripts/ws/ws.py, as the stubbed mise's python)"
WSPY=""
for p in wpy python3; do
  if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import tomllib' 2>/dev/null; then
    WSPY="$(command -v "$p")"
    break
  fi
done
if [ -n "$WSPY" ]; then
  mkdir -p "$HOMEDIR/.config" "$T/proj dir/.git"
  ln -sfn "$ROOT" "$HOMEDIR/.config/mise" # WORKSTATION_REPO, as on Windows
  export MISE_WHICH_OUT="$WSPY"

  echo "-- ws* commands"
  run_nu 'ws-targets | str join ","'
  check "ws-targets lists the tracked targets" is "~/.gitconfig,~/.zshrc"
  run_nu 'ws status | columns | str join ","'
  check "wss is a table of target, mode and state" is "target,mode,state"
  run_nu 'wss | where state == differs | get target.0'
  check "wss can be filtered by state" is "~/.zshrc"
  run_nu 'wss --foo'
  check "an argument to wss passes through to mise" has "dot status --foo"
  run_nu 'wse ~/.zshrc --apply'
  check "wse passes its arguments through" has "dot edit"
  check "wse passes mise's flags through" bash -c '[[ "$1" =~ dot\ edit\ .*\.zshrc\ --apply ]]' _ "$OUT"
  run_nu 'wsd'
  check "wsd with no argument diffs everything" has "dot diff"

  run_nu 'wsh'
  check "wsh prints the catalogue for Nushell (its per-machine override dir)" has 'nushell\autoload'
  check "...and no other shell's" bash -c '[[ "$1" != *".zshrc.local"* ]]' _ "$OUT"
  run_nu "ws open --cd '$T/proj dir'; pwd"
  check "ws open --cd changes Nushell's directory (def --env)" has "$T/proj dir"
  run_nu "ws-complete 'ws re'"
  check "ws completes its subcommands" has "reconcile"
  run_nu 'wsa --force-dotfiles'
  check "wsa is ws apply, which refuses a config root other than this home (exit 1)" \
    bash -c '[ "$1" -eq 1 ] && [[ "$2" == *"would apply the wrong checkout"* ]]' _ "$RC" "$OUT"
  sed "s|\"/h\"|\"$HOMEDIR\"|" "$T/status.json" >"$T/status.home.json" && mv "$T/status.json" "$T/status.h.json"
  cp "$T/status.home.json" "$T/status.json"
  : >"$LOG"
  run_nu 'wsa --force-dotfiles'
  check "...and otherwise applies, with wsa's flags" grep -q -- "bootstrap --only dotfiles --yes --force-dotfiles" "$LOG"
  ls "${TMPDIR:-/tmp}"/ws-out.* >"$T/ws-out.before" 2>/dev/null
  MISE_BOOTSTRAP_RC=4 run_nu 'wsa; print "not reached"'
  check "...exiting with mise's status when the apply fails, and stopping there" \
    bash -c '[ "$1" -eq 4 ] && [[ "$2" != *"not reached"* ]]' _ "$RC" "$OUT"
  ls "${TMPDIR:-/tmp}"/ws-out.* >"$T/ws-out.after" 2>/dev/null
  check "...and ws removes its WS_OUT file even then" cmp -s "$T/ws-out.before" "$T/ws-out.after"
  mv "$T/status.h.json" "$T/status.json"
  unset MISE_WHICH_OUT
else
  echo "  (no python with tomllib: skipped)"
fi

echo "-- fssh"
run_nu 'fssh'
check "fssh offers the hosts of ~/.ssh/config and the files it Includes, no patterns" is "ssh:alpha,beta,zeta"
rm "$HOMEDIR/.ssh/config"
run_nu 'fssh'
check "fssh without a config does nothing" is ""
write_ssh_config

# zsh's and bash's fssh: the function alone, from the rc templates.
rc_fssh() { awk '/^fssh\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ROOT/dotfiles/$1"; }
if command -v zsh >/dev/null 2>&1; then
  OUT="$(cd "$T" && PATH="$BIN:/usr/bin:/bin" HOME="$HOMEDIR" zsh -c "$(rc_fssh zshrc.tera); fssh" 2>&1)"
  RC=$?
  check "zsh's fssh follows Include and drops patterns" is "ssh:alpha,beta,zeta"
else
  echo "  SKIP zsh's fssh (zsh not installed)"
fi
OUT="$(cd "$T" && PATH="$BIN:/usr/bin:/bin" HOME="$HOMEDIR" bash -c "$(rc_fssh bashrc.tera); fssh" 2>&1)"
RC=$?
check "bash's fssh follows Include and drops patterns" is "ssh:alpha,beta,zeta"

echo "-- command not found"
MISE_WHICH_RC=0 MISE_WHICH_OUT='/tools/jq' run_nu 'do $env.config.hooks.command_not_found "jq"'
check "a mise-installed tool that isn't on PATH is named" has "mise installs jq"
check "...with the way out" has "mise reshim"
MISE_WHICH_RC=1 MISE_WHICH_ERR='mise ERROR nope is not a mise bin' run_nu 'do $env.config.hooks.command_not_found "nope" | describe'
check "an unknown command adds nothing" is "nothing"
MISE_WHICH_RC=1 MISE_WHICH_ERR='mise ERROR mise 2026.9.9 is older than min_version 2026.10.1' run_nu 'do $env.config.hooks.command_not_found "jq"'
check "a mise older than min_version points at bootstrap.ps1" has "bootstrap.ps1"

echo "-- prompt and settings"
# #84 added a transient prompt; the user dropped it as not worth having. Every prompt stays whole.
run_nu '$env.TRANSIENT_PROMPT_COMMAND? | describe'
check "no transient prompt: an entered line keeps its full prompt" is "nothing"
run_nu '$env.config.history.file_format'
check "history is kept in SQLite" is "sqlite"
run_nu '$env.config.datetime_format.table'
check "tables show absolute timestamps, as ll does" is "%Y-%m-%d %H:%M"

echo
echo "test-config-nu: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
