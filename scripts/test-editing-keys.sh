#!/usr/bin/env bash
# test-editing-keys.sh: the "Editing keys" blocks of zshrc.tera and bashrc.tera. Each shell
# runs interactively on a pty (driven by zsh's zpty module) with only its block loaded, and
# each key arrives as the escape sequence a terminal sends: Delete, Home/End in all four
# forms, Insert, Ctrl/Alt+arrows, Ctrl+Delete, Alt+Backspace, Ctrl+W and PageUp. Words stop
# at punctuation in both shells, and Ctrl+W deletes back to a space. The two blocks bind
# the same keys. Skipped without zsh (CI installs it).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/zdot"
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
    printf '%s\n' "$OUT" | cat -v | sed 's/^/      /'
    fail=$((fail + 1))
  fi
}
has() { [[ $OUT == *"$1"* ]]; }
lacks() { [[ $OUT != *"$1"* ]]; }
# twice <s>: OUT holds <s> exactly twice.
twice() {
  local rest="${OUT#*"$1"}"
  [[ $rest == *"$1"* && ${rest#*"$1"} != *"$1"* ]]
}

if ! command -v zsh >/dev/null 2>&1; then
  echo "zsh not installed: editing-key cases skipped (they run on zsh's pty module)"
  exit 0
fi

block() { awk '/^# --- Editing keys/ { p = 1; print; next } p && /^# --- / { p = 0 } p' "$1"; }
block "$ROOT/dotfiles/zshrc.tera" >"$T/zsh.sh"
block "$ROOT/dotfiles/bashrc.tera" >"$T/bash.sh"

# The keys each block binds, in bash's spelling (zsh's ^[ is bash's \e); Ctrl+W is zsh-only
# (bash's default already deletes back to a space).
zkeys="$(grep -oE "^ +'[^']+'" "$T/zsh.sh" | tr -d " '" | sed 's/\^\[/\\e/g' | grep -vx '\^W' | sort)"
bkeys="$(grep -oE "^bind '\"[^\"]+\"" "$T/bash.sh" | sed "s/^bind '\"//; s/\"\$//" | sort)"
OUT="zsh:"$'\n'"$zkeys"$'\n'"bash:"$'\n'"$bkeys"
check "zshrc.tera and bashrc.tera bind the same keys (17 of them)" \
  eval '[ "$zkeys" = "$bkeys" ] && [ "$(printf "%s\n" "$zkeys" | wc -l)" -eq 17 ]'

cat >"$T/zdot/.zshrc" <<EOF
. '$T/zsh.sh'
PS1='READY> '
t() { print -r -- "<<\$*>>"; }
EOF
cat >"$T/bashrc" <<EOF
. '$T/bash.sh'
PS1='READY> '
HISTFILE='$T/home/.bash_history'
t() { printf '<<%s>>\n' "\$*"; }
EOF

# The driver starts the shell on a pty and waits for its prompt. For each argument it types
# the keys, then Ctrl+E and "; echo '@'@END" and Enter, and waits for @@END (printed only
# by the command, never echoed as typed) and the next prompt, so every line is typed while
# the line editor reads raw keys. It prints what the pty shows, and gives up on a wait after
# 20 s, so a shell stuck on a question still shows it.
cat >"$T/drive.zsh" <<'EOF'
zmodload zsh/zpty zsh/datetime zsh/zselect || exit 2
zpty S "$1" || exit 2
shift
read_until() {
  local chunk buf='' end=$((EPOCHREALTIME + 20))
  until [[ $buf == ${~1} ]]; do
    if ((EPOCHREALTIME > end)); then
      print -r -- "${buf}[gave up waiting for $1]"
      return 1
    fi
    if zpty -r -t S chunk; then buf+=$chunk; else zselect -t 2; fi
  done
  print -rn -- "$buf"
}
read_until '*READY> *' || exit 1
for keys in "$@"; do
  zpty -w -n S "$keys"$'\x05'"; echo '@'@END"$'\r'
  read_until '*@@END*READY> *' || exit 1
done
zpty -w -n S $'exit\r'
zpty -d S
EOF

# run <shell>: the cases below, typed into that shell, in one session.
run() {
  local cmd
  case "$1" in
  # -d skips the distro's global rc files, as INPUTRC=/dev/null does /etc/inputrc for bash:
  # Ubuntu's /etc/zsh/zshrc runs compinit, which on GitHub's runner stops to ask about
  # insecure directories, and binds keys of its own.
  zsh) cmd="env -i HOME='$T/home' ZDOTDIR='$T/zdot' TERM=xterm-256color PATH=/usr/bin:/bin zsh -d -i" ;;
  bash) cmd="env -i HOME='$T/home' INPUTRC=/dev/null TERM=xterm-256color PATH=/usr/bin:/bin bash --noprofile --rcfile '$T/bashrc' -i" ;;
  esac
  OUT="$(timeout 120 zsh -f "$T/drive.zsh" "$cmd" \
    $'t abc/def\e[1;5DX' \
    $'t abc/dee\e[1;3DY' \
    $'t abcd\e[D\e[D\e[3~' \
    $'h1\e[Ht \e[Fz' \
    $'h2\eOHt \eOFz' \
    $'h3\e[1~t \e[4~z' \
    $'h4\e[7~t \e[8~z' \
    $'t keep a/b-c\x17' \
    $'t a/b-c\e\x7f' \
    $'t abc def\e[1;5D\e[1;5D\e[3;5~' \
    $'t ab cd\e[H\e[1;5C\e[1;5CX' \
    $'t ef gh\e[H\e[1;3C\e[1;3CW' \
    't one-pg' \
    't two-pg' \
    $'t o\e[5~' \
    $'t pqr\e[1;5D\e[2~XY' 2>&1)"
}

for sh in zsh bash; do
  echo "$sh:"
  run "$sh"
  check "$sh: Ctrl+Left stops at the /" has '<<abc/Xdef>>'
  check "$sh: Alt+Left stops at the /" has '<<abc/Ydee>>'
  check "$sh: Delete deletes the character under the cursor" has '<<abd>>'
  check "$sh: Home and End (xterm)" has '<<h1z>>'
  check "$sh: Home and End (application cursor mode)" has '<<h2z>>'
  check "$sh: Home and End (linux console, tmux)" has '<<h3z>>'
  check "$sh: Home and End (rxvt)" has '<<h4z>>'
  check "$sh: Ctrl+W deletes back to a space" has '<<keep>>'
  check "$sh: Alt+Backspace stops at the -" has '<<a/b->>'
  check "$sh: Ctrl+Delete deletes the next word" has '<<def>>'
  if [ "$sh" = zsh ]; then
    check "zsh: Ctrl+Right goes to the next word's start" has '<<ab Xcd>>'
    check "zsh: Alt+Right goes to the next word's start" has '<<ef Wgh>>'
  else
    check "bash: Ctrl+Right goes to the word's end" has '<<abX cd>>'
    check "bash: Alt+Right goes to the word's end" has '<<efW gh>>'
  fi
  check "$sh: PageUp recalls the last line starting with what's typed" twice '<<one-pg>>'
  check "$sh: Insert switches to overwriting" has '<<XYr>>'
  check "$sh: no stray characters or unknown commands" lacks 'not found'
done

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[0;32m✓ all %d editing-key cases passed\033[0m\n' "$pass"
  exit 0
fi
printf '\033[0;31m✗ %d/%d editing-key cases failed\033[0m\n' "$fail" "$((pass + fail))"
exit 1
