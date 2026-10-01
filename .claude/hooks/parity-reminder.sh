#!/usr/bin/env bash
# parity-reminder.sh — Claude Code PostToolUse hook (Edit|Write|MultiEdit).
#
# Repo-specific. Two pairs in this repo must change in lock-step (CLAUDE.md
# "Parity pairs"): zshrc.tera <-> bashrc.tera, and the nushell config.nu.tera <->
# the PowerShell profile. When Claude edits one side, inject a reminder naming
# the other. Pure nudge: never blocks, never edits, always exits 0.
set -u

# shellcheck source=.claude/hooks/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" 2>/dev/null || exit 0

f="$(hook_field '.tool_input.file_path')"
[ -n "$f" ] || exit 0
norm="${f//\\//}"

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
esac
[ -n "$msg" ] || exit 0

hook_context PostToolUse "$msg"
exit 0
