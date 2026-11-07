#!/usr/bin/env bash
# Native OS toast + terminal bell for Claude Code Notification hooks.
# Invoked from ~/.claude/settings.json hooks block. Fire-and-forget; never blocks Claude.
set -u

title="${1:-Claude Code}"
msg="${2:-needs attention}"

# Under WezTerm, WezTerm raises the toast itself from an OSC 777 notification: skipped for
# the pane you're looking at (notification_handling), and it reaches Windows from a remote
# host too, since TERM=wezterm crosses ssh. zellij swallows OSC 777, so not inside it.
# `;` separates the sequence's fields, so the text loses those and control characters.
if [ -z "${ZELLIJ:-}" ] && { [ "${TERM_PROGRAM:-}" = WezTerm ] || [ "${TERM:-}" = wezterm ]; } &&
  { printf '\033]777;notify;%s;%s\033\\' "$(printf '%s' "$title" | tr ';[:cntrl:]' ', ')" \
    "$(printf '%s' "$msg" | tr ';[:cntrl:]' ', ')" >/dev/tty; } 2>/dev/null; then
  :
elif [ -n "${WSL_DISTRO_NAME:-}" ]; then
  # PowerShell single-quoted strings: a quote is written twice, so the text can't end the string.
  pt=${title//\'/\'\'}
  pm=${msg//\'/\'\'}
  if [ "${NOTIFY_NO_MODAL:-}" = 1 ]; then
    # a caller that must never block (ws-agent): BurntToast, else a plain WinRT toast, never a dialog
    toast="[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > \$null;"
    toast+=" \$t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);"
    toast+=" \$x = \$t.GetElementsByTagName('text'); \$x.Item(0).AppendChild(\$t.CreateTextNode('$pt')) > \$null;"
    toast+=" \$x.Item(1).AppendChild(\$t.CreateTextNode('$pm')) > \$null;"
    toast+=" [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe').Show([Windows.UI.Notifications.ToastNotification]::new(\$t))"
    powershell.exe -NoProfile -Command "New-BurntToastNotification -Text '$pt','$pm'" >/dev/null 2>&1 ||
      powershell.exe -NoProfile -Command "$toast" >/dev/null 2>&1 ||
      true
  else
    powershell.exe -NoProfile -Command "New-BurntToastNotification -Text '$pt','$pm'" >/dev/null 2>&1 ||
      powershell.exe -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('$pm','$pt') | Out-Null" >/dev/null 2>&1 ||
      true
  fi
else
  notify-send --urgency=critical "$title" "$msg" >/dev/null 2>&1 || true
fi

{ printf '\a' >/dev/tty; } 2>/dev/null || printf '\a' 2>/dev/null
exit 0
