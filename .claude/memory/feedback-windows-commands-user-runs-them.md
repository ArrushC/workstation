---
name: feedback-windows-commands-user-runs-them
description: Interactive/long-running Windows-side commands (bootstrap.ps1, chezmoi init/apply) — ask the user to run them, don't drive them through interop pipes
metadata:
  type: feedback
---

When a Windows-side command is interactive or long-running (`bootstrap.ps1`, `chezmoi init`/`apply` without `--force`), do NOT run it via `powershell.exe` through a WSL interop pipe — ask the user to run it instead (suggest the `!` prefix so output lands in the conversation, or a real Windows terminal). Read-only interop probes (Test-Path, Get-CimInstance, registry reads) remain fine to run directly.

**Why:** Piped interop sessions have no console — any hidden prompt blocks forever with zero output (bit PR #86 validation: `chezmoi init --apply` inside a piped `bootstrap.ps1` hung >30 min on the known overwrite prompt from [[project-windows-apply-via-wsl-gotchas]]; had to Stop-Process the tree). The user also explicitly asked to be the one running such commands ("Ask me to run the command instead", 2026-07-15).

**How to apply:** Before invoking anything Windows-side that could prompt or take minutes, hand the exact command to the user and wait. Same pattern as [[feedback-sudo-not-passwordless]] (hand sudo prompts to the user via `!`). Diagnose stuck state read-only first (process tree via `Get-CimInstance Win32_Process`, config/file presence) before asking for a kill.
