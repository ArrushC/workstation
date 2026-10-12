#!/usr/bin/env bash
# test-term-fallback.sh: the "TERM=wezterm fallbacks" block of zshrc.tera and bashrc.tera
# (byte-identical) keeps TERM=wezterm only where its terminfo entry exists, wraps sudo when
# root's lookup can't see the entry, and has ssh probe a host before sending TERM=wezterm,
# only for a session that gets a pty, skipping option values. The block runs under bash
# and zsh with infocmp, ssh and sudo stubs on PATH.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"
mkdir -p "$BIN" "$T/home"
pass=0
fail=0
OUT=''

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

block() { awk '/^# --- TERM=wezterm fallbacks/ { p = 1 } /^# --- History/ { p = 0 } p' "$1"; }
block "$ROOT/dotfiles/zshrc.tera" >"$T/block.sh"
block "$ROOT/dotfiles/bashrc.tera" >"$T/block-bash.sh"
check "the block is byte-identical in zshrc.tera and bashrc.tera" cmp -s "$T/block.sh" "$T/block-bash.sh"
check "the block defines the ssh and sudo wrappers" grep -q '^  ssh() {' "$T/block.sh"

# infocmp knows wezterm system-wide when $STUB/system exists, and from ~/.terminfo when
# $STUB/user exists and HOME is the real one (the sudo test sets HOME=/nonexistent).
cat >"$BIN/infocmp" <<'EOF'
#!/bin/sh
[ "$1" = wezterm ] || exit 1
[ -e "$STUB/system" ] && exit 0
[ "$HOME" != /nonexistent ] && [ -e "$STUB/user" ] && exit 0
exit 1
EOF
# ssh logs its TERM and arguments. A BatchMode probe succeeds for a destination listed in
# $STUB/good (the probe's destination is its second-to-last argument).
cat >"$BIN/ssh" <<'EOF'
#!/bin/sh
echo "TERM=$TERM $*" >>"$STUB/log"
case " $* " in
*" BatchMode=yes "*)
  prev='' dest=''
  for a; do dest=$prev; prev=$a; done
  grep -qxF -- "$dest" "$STUB/good"
  ;;
esac
EOF
cat >"$BIN/sudo" <<'EOF'
#!/bin/sh
echo "TERM=$TERM sudo $*" >>"$STUB/log"
EOF
chmod +x "$BIN/infocmp" "$BIN/ssh" "$BIN/sudo"
printf 'good\nme@good\n' >"$T/good"

# run <shell> <command...>: sources the block with TERM=wezterm (or $START_TERM), runs the
# command, then prints the shell's TERM; the stubs' log lands in $LOG.
run() {
  local sh="$1"
  shift
  : >"$T/log"
  local flags=(--norc --noprofile)
  [ "$sh" = zsh ] && flags=(-f)
  OUT="$(env -i PATH="$BIN:/usr/bin:/bin" HOME="$T/home" STUB="$T" TERM="${START_TERM:-wezterm}" \
    "$sh" "${flags[@]}" -c ". '$T/block.sh'; $*; echo \"shell TERM=\$TERM\"" 2>&1)"
  LOG="$(cat "$T/log")"
  OUT="$OUT"$'\n'"log:"$'\n'"$LOG"
}
probes() { printf '%s\n' "$LOG" | grep -c 'BatchMode=yes' || true; }
last_term() { printf '%s\n' "$LOG" | tail -1 | sed 's/ .*//'; }
out_has() { printf '%s' "$OUT" | grep -qF -- "$1"; }

shells=(bash)
if command -v zsh >/dev/null 2>&1; then
  shells+=(zsh)
else
  echo "  zsh not installed: the block runs under bash only"
fi

for sh in "${shells[@]}"; do
  echo "$sh:"
  rm -f "$T/system"
  touch "$T/user"

  run "$sh" true
  check "$sh: the entry exists, TERM stays wezterm" out_has 'shell TERM=wezterm'
  run "$sh" sudo id
  check "$sh: sudo runs with xterm-256color (root has no entry)" [ "$LOG" = 'TERM=xterm-256color sudo id' ]

  # ssh <args> | probes | final TERM
  while IFS='|' read -r args want_probes want_term; do
    run "$sh" "ssh $args"
    check "$sh: ssh $args: $want_probes probe(s), TERM=$want_term" \
      [ "$(probes)" = "$want_probes" -a "$(last_term)" = "TERM=$want_term" ]
  done <<'CASES'
good|1|wezterm
bad|1|xterm-256color
me@good|1|wezterm
-p 2222 good|1|wezterm
-p2222 good|1|wezterm
-tp 22 good|1|wezterm
-o User=me good|1|wezterm
-L 8080:host:80 good|1|wezterm
-t good htop|1|wezterm
good ls -l|0|xterm-256color
-G good|0|xterm-256color
-O exit good|0|xterm-256color
-N -L 1:host:2 good|0|xterm-256color
-V|0|xterm-256color
CASES
  run "$sh" "ssh -p 2222 good"
  check "$sh: the probe asks the destination, not an option value" out_has 'BatchMode=yes -o ConnectTimeout=5 -n -T good infocmp wezterm'
  check "$sh: ssh gets the user's arguments unchanged" out_has 'TERM=wezterm -p 2222 good'

  touch "$T/system"
  run "$sh" sudo id
  check "$sh: a system-wide entry leaves sudo alone" [ "$LOG" = 'TERM=wezterm sudo id' ]

  rm -f "$T/user" "$T/system"
  run "$sh" "ssh good"
  check "$sh: no entry: TERM becomes xterm-256color" out_has 'shell TERM=xterm-256color'
  check "$sh: no entry: ssh is not wrapped" [ "$(probes)" = 0 -a "$(last_term)" = 'TERM=xterm-256color' ]

  touch "$T/user"
  START_TERM=xterm-256color run "$sh" "ssh good; sudo id"
  check "$sh: another TERM: nothing is wrapped" [ "$(probes)" = 0 -a "$LOG" = $'TERM=xterm-256color good\nTERM=xterm-256color sudo id' ]
done

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[0;32m✓ all %d TERM-fallback cases passed\033[0m\n' "$pass"
  exit 0
fi
printf '\033[0;31m✗ %d/%d TERM-fallback cases failed\033[0m\n' "$fail" "$((pass + fail))"
exit 1
