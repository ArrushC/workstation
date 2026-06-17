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
*/makefile/versions.mk)
  msg="versions.mk changed. Dual/triple-edit pins that have NO template bridge: CCSTATUSLINE_VERSION -> ccstatusline@ in private_settings.json.tmpl; JETBRAINSMONO_NERD_VERSION -> lib/font.sh SHA arm + install-nerd-fonts.ps1; HELIX_VERSION -> bootstrap.ps1 download URL. If you touched any of those pins, update its paired file(s) in the same commit."
  ;;
*/makefile/scope.mk)
  msg="scope.mk changed. If you touched HELIX_RUNTIME_DEST, mirror the value in the HELIX_RUNTIME rc literal in BOTH dot_zshrc.tmpl and dot_bashrc.tmpl (no template var bridges them). See CLAUDE.md."
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
  private_settings.json.tmpl)
    msg="If you changed the ccstatusline@ pin here, mirror it in CCSTATUSLINE_VERSION in makefile/versions.mk (dual-edit, no bridge)."
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
