---
name: feedback-windows-chezmoi-check-before-apply
description: "Before applying a sync on the Windows host, first check whether chezmoi.exe exists; if present apply via interop, if missing deploy the files manually. Never substitute the WSL Linux chezmoi for the Windows state."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 75adcff1-9685-4bff-8370-2ed8061f1305
---

When a workstation-repo change needs to land on the Windows host (`SLO-LT-4CWHKL3`), do NOT assume `chezmoi apply` will work there. ALWAYS first check whether the native Windows `chezmoi` binary exists — via WSL interop, e.g. `powershell.exe -NoProfile -Command 'Get-Command chezmoi'` (or `Test-Path "$env:LOCALAPPDATA\workstation\bin\chezmoi.exe"`, the location `bootstrap.ps1` installs it to). Then branch:

- **chezmoi.exe present** → drive the normal flow over interop: `git pull` in the Windows clone (`C:\Users\arrush.chaturvedi\.local\share\chezmoi`), `chezmoi diff` to review, then `chezmoi apply`.
- **chezmoi.exe missing** → I deploy the change MANUALLY: hand-produce the Windows-correct content for each affected target (applying the OS-gated logic myself) and copy it into `%USERPROFILE%` via interop. Then flag that the Windows chezmoi needs reinstalling — re-run `bootstrap.ps1` (it reinstalls chezmoi admin-free via the official `get.chezmoi.io` binary installer into `%LOCALAPPDATA%\workstation\bin`). Do NOT point the WSL chezmoi at the Windows state as a shortcut.

**Why:** Two independent reasons.
1. The Windows `chezmoi.exe` is unreliable on this corporate device — it vanished mid-session once (most likely an EDR/AV quarantine), so its presence must be verified, not assumed. (Historically it lived under choco's `chocoportable\bin\`; `bootstrap.ps1` now installs it admin-free to `%LOCALAPPDATA%\workstation\bin`.)
2. The WSL `chezmoi` is a *Linux* binary: `.chezmoi.os` is baked to the running binary's OS (`linux`) with no override flag. Aiming it at the Windows source + `%USERPROFILE%` mis-renders every OS-gated template — it would re-add the ssh `ControlMaster` block (re-breaking Windows ssh — see the "SSH connection multiplexing is gated out on Windows" invariant in CLAUDE.md) and invert `.chezmoiignore.tmpl` (Linux dotfiles into the Windows profile, Windows-only paths dropped), plus write LF endings. Only a Windows-native chezmoi renders the Windows profile correctly.

**How to apply:**
- Run the existence check first, every time a change must reach Windows — before any `chezmoi apply` attempt there.
- Manual fallback works cleanly for targeted fixes (e.g. the ssh config's Windows form is just the template minus the `{{ if ne .chezmoi.os "windows" }}` block); prefer reinstalling chezmoi when the change set is broad.
- Git-over-SSH on Windows may itself be broken by the same multiplexing bug before the fix is applied; use `GIT_SSH_COMMAND="ssh -o ControlMaster=no -o ControlPath=none" git pull` as the escape hatch (CLAUDE.md invariant).
- Standing push rule still applies — see [[feedback-always-push-after-commit]] — and `.claude/` changes are routine tracked content per [[feedback-commit-claude-dir-routinely]].
