#!/usr/bin/env bash
# Native OS toast + terminal bell for Claude Code Notification hooks.
# Invoked from ~/.claude/settings.json hooks block. Fire-and-forget; never blocks Claude.
set -u

title="${1:-Claude Code}"
msg="${2:-needs attention}"

if [ -n "${WSL_DISTRO_NAME:-}" ]; then
  powershell.exe -NoProfile -Command "New-BurntToastNotification -Text '$title','$msg'" >/dev/null 2>&1 ||
    powershell.exe -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('$msg','$title') | Out-Null" >/dev/null 2>&1 ||
    true
else
  notify-send --urgency=critical "$title" "$msg" >/dev/null 2>&1 || true
fi

{ printf '\a' >/dev/tty; } 2>/dev/null || printf '\a' 2>/dev/null
exit 0
