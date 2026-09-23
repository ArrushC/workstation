---
name: project-winterop-wsl-windows-interop
description: From WSL / a Linux-on-Windows shell, reach the Windows host via `winterop` (~/.local/bin) instead of hand-rolling powershell.exe/wslpath calls.
metadata:
  type: project
---

When working from WSL (or any Linux-on-Windows shell) and you need to touch the
Windows side, use **`winterop`** (`~/.local/bin/winterop`; source at
`dotfiles/local/bin/winterop`) instead of hand-rolling
`powershell.exe` / `wslpath` / `clip.exe` calls.

**Command map:**
- `winterop` — detected env (WSL2 vs Hyper-V/VMware/VirtualBox VM) + live interop channels
- `winterop run <cmd>` — run on the Windows side (PowerShell); `winterop exe <prog>` — run a `.exe` directly
- `winterop path [-w|-u] <p>` — WSL↔Windows path convert
- `winterop clip [get|set]` — Windows clipboard; `winterop open <path|url>` — open on Windows (Start-Process)
- `winterop host` / `winterop env <VAR>` / `winterop ps` / `winterop reg <key>` / `winterop notify <msg>`
- `winterop selftest` — read-only probes; `winterop help` — full list

**Why:** built 2026-06-15 after repeatedly hand-wiring interop this session. It
centralizes the detection (mirrors `is_wsl()`) and is robust to fleet quirks —
e.g. `open` uses `Start-Process`, not `explorer.exe`, so it survives
`appendWindowsPath=false` (which trims `C:\Windows` off PATH — see
[[project-wsl-appendwindowspath-false]]).

**How to apply:**
- In a plain Linux VM on Windows (not WSL) the live subcommands intentionally
  refuse and point you at SSH / shared-folder / RDP — heed that, don't force interop.
- For applying changes on the Windows side, [[project-windows-apply-via-wsl-gotchas]] governs (never render Windows targets with the WSL-side mise; applies are the user's to run).
- Deployed only on Linux/WSL (`~/.local` is ignored on Windows); after a fresh clone it lands via `wsa` / `./bootstrap.sh` (a `copy`-mode `[dotfiles]` entry for `~/.local/bin`).
