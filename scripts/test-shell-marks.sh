#!/usr/bin/env bash
# test-shell-marks.sh: the "Terminal shell integration" blocks of zshrc.tera and bashrc.tera
# send OSC 133 prompt marks (A, B, C, D;<exit>) and the OSC 7 cwd in every terminal but
# Warp and TERM=dumb/linux, keep the exit status for starship, and add ConEmu's OSC 9
# sequences (9;4 progress, WT's 9;9 cwd) only under Windows Terminal or WezTerm outside
# zellij. Each block runs in its own shell (zsh's in zsh, bash's in bash) with a wslpath stub.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"
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
# has <s>... / lacks <s>...: OUT holds every / none of them.
has() {
  local s
  for s; do [[ $OUT == *"$s"* ]] || return 1; done
}
lacks() {
  local s
  for s; do [[ $OUT != *"$s"* ]] || return 1; done
}
ends_with() { [[ $OUT == *"$1" ]]; }
# The prompt carries exactly one B mark, at its end.
one_b() { [[ $OUT == *"PROMPT=> "*"133;B"* && $OUT != *"133;B"*"133;B"* ]]; }

block() { awk '/^# --- Terminal shell integration/ { p = 1 } /^# --- zellij: name the tab/ { p = 0 } p' "$1"; }
block "$ROOT/dotfiles/zshrc.tera" >"$T/zsh.sh"
block "$ROOT/dotfiles/bashrc.tera" >"$T/bash.sh"
check "zshrc.tera has the block" grep -q '_wt_prompt_end' "$T/zsh.sh"
check "bashrc.tera has the block" grep -q '_wt_prompt_end' "$T/bash.sh"
printf '#!/bin/sh\necho "C:\\\\wsl$2"\n' >"$T/bin/wslpath"
chmod +x "$T/bin/wslpath"

# A prompt cycle after a command that exited 3: the prompt hook (its status printed as
# rc=), the prompt-end hook (the prompt printed), then for zsh the preexec hook for
# `make all`. Sourced twice, as a re-sourced rc file would be.
script_zsh=". '$T/zsh.sh'; . '$T/zsh.sh'; PROMPT='> '
(exit 3); _wt_precmd; echo \"rc=\$?\"; _wt_prompt_end; _wt_prompt_end
print -r -- \"PROMPT=\$PROMPT\"; _wt_preexec 'make all'
print -r -- \"hooks=\${(j:,:)precmd_functions},\${(j:,:)preexec_functions}\""
script_bash=". '$T/bash.sh'; . '$T/bash.sh'; PS1='> '
(exit 3); _wt_prompt_cmd; echo \"rc=\$?\"; _wt_prompt_end; _wt_prompt_end
printf 'PROMPT=%s\n' \"\$PS1\"; printf 'PS0=%s\n' \"\$PS0\"; printf 'hooks=%s\n' \"\$PROMPT_COMMAND\""

# run <shell> <env assignments...>: the cycle above under that environment.
run() {
  local sh="$1" script flags=(--norc --noprofile)
  shift
  script=$script_bash
  [ "$sh" = zsh ] && flags=(-f) && script=$script_zsh
  OUT="$(cd "$T/home" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" "$@" "$sh" "${flags[@]}" -c "$script" 2>&1)"
}

shells=(bash)
if command -v zsh >/dev/null 2>&1; then
  shells+=(zsh)
else
  echo "  zsh not installed: only bashrc.tera's block runs"
fi
host="$(uname -n)"
osc7=$'\e]7;file://'"$host$T/home"$'\e\\'

for sh in "${shells[@]}"; do
  echo "$sh:"
  # Under WezTerm: marks, OSC 7, progress; no 9;9 (WezTerm reads OSC 7).
  run "$sh" TERM=wezterm TERM_PROGRAM=WezTerm
  check "$sh: WezTerm: D;3 then OSC 7 then A, and the status survives" \
    has $'\e]133;D;3\a'"$osc7"$'\e]133;A\a'
  check "$sh: WezTerm: rc=3 after the hook" has 'rc=3'
  check "$sh: WezTerm: progress cleared at the prompt" has $'\e]9;4;0;0\a'
  check "$sh: WezTerm: no 9;9 (WezTerm reads OSC 7)" lacks $'\e]9;9'
  check "$sh: the prompt ends with one B mark" one_b
  if [ "$sh" = zsh ]; then
    check "zsh: preexec sends C and progress for make" has $'\e]133;C\a\e]9;4;3;0\a'
    check "zsh: sourcing twice registers each hook once" ends_with 'hooks=_wt_precmd,_wt_prompt_end,_wt_preexec'
  else
    check "bash: PS0 sends C" has 'PS0=\e]133;C\a'
    check "bash: sourcing twice registers each hook once" ends_with 'hooks=_wt_prompt_cmd; _wt_prompt_end'
  fi

  # Another terminal (or ssh where TERM fell back): marks and OSC 7, nothing from OSC 9.
  run "$sh" TERM=xterm-256color
  check "$sh: other terminal: marks and OSC 7" has $'\e]133;D;3\a'"$osc7"$'\e]133;A\a'
  check "$sh: other terminal: no OSC 9" lacks $'\e]9;'
  if [ "$sh" = zsh ]; then
    check "zsh: other terminal: preexec sends C" has $'\e]133;C\a'
    check "zsh: other terminal: no progress for make" lacks '9;4;3'
  fi

  # Windows Terminal: also its 9;9 cwd, a Windows path from wslpath.
  run "$sh" TERM=xterm-256color WT_SESSION=x
  check "$sh: Windows Terminal: 9;9 from wslpath -w, then A and the progress clear" \
    has $'\e]9;9;C:\\wsl'"$T/home"$'\a\e]133;A\a\e]9;4;0;0\a'

  # Inside zellij: marks and OSC 7 still go out (zellij drops them); OSC 9 doesn't.
  run "$sh" TERM=wezterm TERM_PROGRAM=WezTerm ZELLIJ=0
  check "$sh: zellij: marks and OSC 7" has $'\e]133;A\a' "$osc7"
  check "$sh: zellij: no OSC 9" lacks $'\e]9;'

  # Warp, dumb and the console: nothing defined, nothing sent.
  for env in TERM_PROGRAM=WarpTerminal TERM=dumb TERM=linux; do
    run "$sh" TERM=xterm-256color "$env"
    check "$sh: $env: no sequences" lacks $'\e]'
    check "$sh: $env: no hooks" has 'not found'
  done
done

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[0;32m✓ all %d shell-mark cases passed\033[0m\n' "$pass"
  exit 0
fi
printf '\033[0;31m✗ %d/%d shell-mark cases failed\033[0m\n' "$fail" "$((pass + fail))"
exit 1
