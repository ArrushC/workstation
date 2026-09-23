---
name: project-windows-apply-via-wsl-gotchas
description: Reaching the Windows host from WSL — powershell.exe session facts, never render Windows targets with the WSL-side tool, never let a /mnt/c cwd pick the checkout, one bootstrap.ps1 at a time, verifying nu config.
metadata:
  type: project
---

When a change must land on the Windows host from this WSL box (same physical
machine), the apply itself is the user's to run (`.\bootstrap.ps1` or `wsa` in
a Windows terminal — see [[feedback-windows-commands-user-runs-them]]). What I
drive via `powershell.exe` is read-only probing. Gotchas that survive the
chezmoi→mise migration (PR #157, 2026-09-23):

- **Reaching Windows:** `powershell.exe` resolves at
  `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe` (works even
  with `appendWindowsPath=false` — see [[project-wsl-appendwindowspath-false]]).
  The Windows checkout is `/mnt/c/Users/arrush.chaturvedi/.config/mise`.
  A WSL-spawned `powershell.exe` runs in the **user's interactive session
  (SessionId 1)** — same session as WindowsTerminal — so `WM_FONTCHANGE` and
  other `HWND_BROADCAST` messages from it DO reach running GUI apps. Prefer
  [[project-winterop-wsl-windows-interop]] (`winterop`) for simple calls.

- **Never render Windows targets with the WSL-side (Linux) mise.** Templates
  branch on `os()`, which is the running binary's OS; a Linux mise aimed at the
  Windows checkout renders every `.tera` as Linux — e.g. it re-adds the ssh
  `ControlMaster` block that `dotfiles/ssh/config.tera` gates out on Windows
  (breaks every Windows ssh, incl. git). Only the Windows-native mise (installed
  by `bootstrap.ps1`) renders the Windows profile correctly. (Same lesson the old
  chezmoi.exe-vs-WSL-chezmoi memory carried; that memory was deleted as stale.)

- **The converse bit the WSL host on 2026-09-22:** mise walks UP from cwd to find
  its config root, so an unpinned `wsa` run from `/mnt/c/Users/<user>` rendered
  the Linux `$HOME` from the stale Windows clone, and DrvFs's 0744-on-everything
  made seven dotfiles executable. Fixed by pinning every `ws*` command to
  `mise -C "$HOME"` (70309f9). When running mise by hand, pin `-C` too.

- **Never run `bootstrap.ps1` concurrently.** A second run racing the first
  (historically a chezmoi state-lock timeout) leaves a half-applied state. One
  Windows apply at a time. Relatedly, `mise install --force node` fails with os
  error 32 while any process holds a file under the node install —
  `Invoke-MiseRuntimes` falls back to re-running node's postinstall (74737d2).

**How to verify an apply landed:** read the target files directly over
`/mnt/c/...`, or `mise dot status` via Windows mise from a Windows cwd. For nu
config validity: `nu -c` does NOT load `config.nu`; instead `source` it from a
throwaway `.nu` script (`nu --no-config-file test.nu` where test.nu does
`source 'C:\...\config.nu'`) — that surfaces real parse errors with line/col.
