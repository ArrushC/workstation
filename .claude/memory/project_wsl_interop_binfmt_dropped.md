---
name: project-wsl-interop-binfmt-dropped
description: When WSL->Windows interop fails with "Exec format error" on every .exe, the WSLInterop binfmt_misc handler is unregistered (systemd-on-WSL drop); re-register it to restore interop.
metadata:
  type: project
---

On this WSL2 host, Windows-binary interop can silently break: every `.exe`
(`powershell.exe`, `cmd.exe`, `chezmoi.exe`, the `winterop` helper) fails with
`cannot execute binary file: Exec format error`, even though `/etc/wsl.conf` has
`[interop] enabled=true`. Root cause: the `binfmt_misc` **`WSLInterop` handler is
unregistered** in the running session (`/proc/sys/fs/binfmt_misc/WSLInterop`
missing) — a known interaction with `[boot] systemd=true`. `binfmt_misc` is still
mounted (`register` + `status` present) and `/init` exists; only the handler
entry is gone.

**Fix (needs root):**

```
sudo sh -c 'echo ":WSLInterop:M::MZ::/init:PF" > /proc/sys/fs/binfmt_misc/register'
```

In-memory, benign, reverts on next `wsl --shutdown`. `sudo` here is NOT
passwordless ([[feedback-sudo-not-passwordless]]) so it hangs if Claude runs it —
hand it to the user via the `!` prefix. Once registered
(`cat /proc/sys/fs/binfmt_misc/WSLInterop` -> `enabled`), interop works for all
processes including Claude's subsequent Bash calls. Also note: inside an actual
`powershell.exe` invocation use native Windows paths (`$env:LOCALAPPDATA\...`),
NOT `/mnt/c/...` (PowerShell mis-parses the latter as a module path).

**Why:** Hit 2026-06-28 doing a Windows-side `chezmoi apply` to verify the Zed
nushell-shell change. Diagnose before theorizing: `ls
/proc/sys/fs/binfmt_misc/WSLInterop` (missing = this bug) + `cmd.exe /c echo ok`.
This precedes the apply-via-WSL steps in
[[project-windows-apply-via-wsl-gotchas]] and the chezmoi.exe-exists check in
[[feedback-windows-chezmoi-check-before-apply]]; reach Windows via
[[project-winterop-wsl-windows-interop]] once interop is back.
