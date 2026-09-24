#!/usr/bin/env bash
# parity-reminder.sh — Claude Code PostToolUse hook (Edit|Write|MultiEdit).
#
# Repo-specific. Several files in this repo must change in lock-step (CLAUDE.md
# "parity pairs" / "version-pin dual/triple-edits"). When Claude edits one side,
# inject a reminder naming the sibling(s). Pure nudge: never blocks, never edits,
# always exits 0. Worst case (if PostToolUse additionalContext is ignored) the
# reminder is simply dropped — no harm.
set -u

INPUT="$(cat)"
hookfield() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | HF="$1" python3 -c 'import os,sys,json
p=os.environ["HF"].lstrip(".").split(".")
try:
    v=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in p:
    v=v.get(k) if isinstance(v,dict) else None
print(v if isinstance(v,str) else "")' 2>/dev/null
  fi
}

f="$(hookfield '.tool_input.file_path')"
[ -n "$f" ] || exit 0
norm="${f//\\//}"
base="${norm##*/}"

msg=""
case "$norm" in
*/dotfiles/zshrc.tera)
  msg="Parity pair: you edited zshrc.tera — mirror any interactive-shell change in bashrc.tera (or add a PARITY NOTE explaining the zsh-only divergence). Change both in the same commit. See CLAUDE.md."
  ;;
*/dotfiles/bashrc.tera)
  msg="Parity pair: you edited bashrc.tera — mirror the change in zshrc.tera. Change both in the same commit. See CLAUDE.md."
  ;;
*/dotfiles/windows/AppData/Roaming/nushell/config.nu.tera)
  msg="Parity pair: you edited the nushell config's ws*/g* alias block — mirror it in Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera. Change both in the same commit. See CLAUDE.md."
  ;;
*/dotfiles/windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera)
  msg="Parity pair: you edited the PowerShell profile's ws*/g* alias block — mirror it in AppData/Roaming/nushell/config.nu.tera. Change both in the same commit. See CLAUDE.md."
  ;;
# A dotfiles/** target's OWN config file (helix/herdr/tealdeer/…) is not
# mise's own config*.toml — exclude the whole dotfiles/ tree before the glob
# below, which would otherwise also match "*/dotfiles/config/helix/config.toml"
# etc. (both end in "/config.toml").
*/dotfiles/*) ;;
*/config.toml)
  msg="config.toml [vars]: python_version is a three-way pin with tools.python and bootstrap.ps1 \$PythonEnvVersion; nerd_font_version triple-edits scripts/lib/font.sh (SHA arm) and scripts/install-nerd-fonts.ps1."
  ;;
*/config.linux.toml | */config.dev.toml)
  msg="Tool pins changed. jq/gh/helix (config.linux.toml) and opencode/omp/DevToys (config.dev.toml) dual-edit bootstrap.ps1 \$PortableTools; min_version dual-edits MISE_VERSION in bootstrap.sh + bootstrap.ps1. Refresh mise.lock: \`mise lock --global --platform linux-x64,windows-x64\`."
  ;;
esac
if [ -z "$msg" ]; then
  case "$base" in
  python-env.sh)
    msg="Parity pair: python-env.sh (PY_LIBS list) mirrors Invoke-PythonEnv in bootstrap.ps1 (\$PythonLibs). Change both in the same commit. See CLAUDE.md."
    ;;
  bootstrap.ps1)
    msg="If you touched Invoke-PythonEnv (the \$PythonLibs list), mirror it in scripts/lib/python-env.sh (PY_LIBS). Change both in the same commit. See CLAUDE.md."
    ;;
  esac
fi
[ -n "$msg" ] || exit 0

if command -v jq >/dev/null 2>&1; then
  jq -nc --arg c "$msg" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c},suppressOutput:true}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"},"suppressOutput":true}\n' "$msg"
fi
exit 0
