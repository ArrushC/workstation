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
*/chezmoi/dot_zshrc.tmpl)
  msg="Parity pair: you edited dot_zshrc.tmpl — mirror any interactive-shell change in dot_bashrc.tmpl (or add a PARITY NOTE explaining the zsh-only divergence). Change both in the same commit. See CLAUDE.md."
  ;;
*/chezmoi/dot_bashrc.tmpl)
  msg="Parity pair: you edited dot_bashrc.tmpl — mirror the change in dot_zshrc.tmpl. Change both in the same commit. See CLAUDE.md."
  ;;
# A chezmoi-managed dotfile's OWN config.toml (helix/herdr/tealdeer/…) is not
# mise's config*.toml — exclude it before the glob below, which would
# otherwise also match "*/dot_config/helix/config.toml" etc. (both end in
# "/config.toml").
*/chezmoi/dot_config/*) ;;
*/config.toml)
  msg="config.toml [vars]: python_version is a three-way pin with tools.python and bootstrap.ps1 \$PythonEnvVersion; nerd_font_version triple-edits scripts/lib/font.sh (SHA arm) and scripts/install-nerd-fonts.ps1."
  ;;
*/config.linux.toml | */config.dev.toml)
  msg="Tool pins changed. jq/gh/helix (config.linux.toml) and opencode/omp/DevToys (config.dev.toml) dual-edit bootstrap.ps1 \$PortableTools; min_version dual-edits MISE_VERSION in bootstrap.sh + bootstrap.ps1. Refresh mise.lock: \`mise lock --global --platform linux-x64,windows-x64\`."
  ;;
*/chezmoi/.chezmoiignore.tmpl)
  msg="Reminder: .chezmoiignore patterns are matched against TARGET paths (.bashrc, .config/zsh, .claude, .config/ccstatusline) — NOT source-state names (dot_*/private_dot_*/*.tmpl), which silently ignore nothing. Verify with 'chezmoi ignored'."
  ;;
esac
if [ -z "$msg" ]; then
  case "$base" in
  manage-hosts.sh)
    msg="Parity pair: manage-hosts.sh and manage-hosts.ps1 must stay feature-identical (flags, menu, prompts, glyphs). Change both in the same commit."
    ;;
  manage-hosts.ps1)
    msg="Parity pair: manage-hosts.ps1 and manage-hosts.sh must stay feature-identical. Change both in the same commit. (Also keep the UTF-8 BOM on the .ps1.)"
    ;;
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
