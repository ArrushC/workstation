---
name: project_windows_apply_via_wsl_gotchas
description: Driving the Windows chezmoi/bootstrap from WSL — non-interactive chezmoi hangs, the bootstrap lock collision, and targeted-apply dir quirk.
metadata:
  type: project
---

When applying a change to the Windows host from this WSL box (same physical
machine), I drive it via `powershell.exe`. Hard-won gotchas from the 2026-06-19
Nushell rollout:

- **Reaching Windows:** `powershell.exe` resolves at
  `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe` (works even
  with `appendWindowsPath=false` — see [[project_wsl_appendwindowspath_false]]).
  The Windows chezmoi clone is `/mnt/c/Users/arrush.chaturvedi/.local/share/chezmoi`.
  A WSL-spawned `powershell.exe` runs in the **user's interactive session
  (SessionId 1)** — same session as WindowsTerminal — so `WM_FONTCHANGE` and
  other `HWND_BROADCAST` messages from it DO reach running GUI apps. Prefer
  [[project_winterop_wsl_windows_interop]] (`winterop`) for simple calls.

- **`chezmoi init --apply` HANGS non-interactively.** Run from a WSL-spawned
  `powershell.exe` (no attached console), `chezmoi init --apply` blocked
  indefinitely (~16 min) while **holding the persistent-state lock**. Plain
  `chezmoi apply` completes but is slow (~60-90s, likely the
  `modify_private_settings.json` merge-template). Fixes: use **`chezmoi apply`**
  not `init --apply` for re-applies; wrap the call in PowerShell
  `Start-Job` + `Wait-Job -Timeout 60` so it can't hang the turn; redirect the
  outer powershell stdin from `/dev/null`. (Complements
  [[feedback_windows_chezmoi_check_before_apply]].)

- **Never run `bootstrap.ps1` concurrently.** My background bootstrap was
  mid-`chezmoi apply` (holding the lock) when a second manual run started → the
  manual run died with `chezmoi: timeout obtaining persistent state lock` and a
  half-applied state. One Windows apply at a time. To recover a stuck lock:
  `Get-Process chezmoi | Stop-Process -Force` (force-kill releases the boltdb
  flock), then re-apply.

- **Targeted apply won't create a missing parent dir.** `chezmoi apply <one new
  target>` for a brand-new source file failed with `open ...: The system cannot
  find the path specified` because the parent dir didn't exist yet. Pre-create
  the dir (`New-Item -ItemType Directory -Force`) then targeted-apply, or run a
  full apply.

**How to verify an apply landed** without re-running chezmoi: read the target
files directly over `/mnt/c/...`, and for nu config validity run the installed
`nu.exe -c` ... no — `nu -c` does NOT load `config.nu`; instead `source` it from
a throwaway `.nu` script (`nu --no-config-file test.nu` where test.nu does
`source 'C:\...\config.nu'`) — that surfaces real parse errors with line/col.
