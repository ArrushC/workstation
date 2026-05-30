---
name: project-wsl-appendwindowspath-false
description: "On WSL hosts, exec.LookPath-heavy tools (chezmoi, and thus czt) are slow because appendWindowsPath=true puts ~90 /mnt/c dirs on $PATH and each failed lookup stat-walks them over slow drvfs. Fix = appendWindowsPath=false in /etc/wsl.conf + a WSL-gated rc re-add of just PowerShell + system32."
metadata:
  node_type: memory
  type: project
---

On WSL hosts in this repo, any tool that does `exec.LookPath` / `command -v` for a binary that **isn't installed** is slow, because WSL2's default `appendWindowsPath=true` (in `/etc/wsl.conf`) tacks the entire Windows `%PATH%` (~90 `/mnt/c` dirs) onto `$PATH`, and a not-found lookup stat-walks *every* dir over the slow 9p/drvfs mount (~1–3 ms each cold). chezmoi probes for clipboard tools (`wl-copy`/`xclip`/`xsel`/`termux-clipboard-set`/`pwsh`) at startup — none exist on the Windows side — so **every `chezmoi` invocation costs ~1.6 s** (strace: ~660 stats, ~580 ENOENT). `czt` (the `chezit` TUI) fires several chezmoi calls on launch/refresh, so it felt multi-second laggy. It is NOT network, subprocess, or template-render cost — `time` shows ~15% CPU, the rest blocked on stats.

The adopted fix (this host, May 2026):
1. **Host-global:** `appendWindowsPath=false` under `[interop]` in `/etc/wsl.conf`, then `wsl --shutdown` from a Windows terminal so the distro re-reads it. NOT repo-tracked (chezmoi owns `$HOME` only; `/etc/wsl.conf` is outside scope). Needs sudo — run via `!` in the session, since the agent has no TTY for the sudo password.
2. **Repo-tracked:** a WSL-gated PATH block in `chezmoi/dot_zshrc.tmpl` + `chezmoi/dot_bashrc.tmpl` (parity pair — see [[feedback ... ]] nothing; just keep both in lockstep per CLAUDE.md) (keep both files in lockstep per the CLAUDE.md parity-pair rule) that re-adds back ONLY the two Windows dirs still called from WSL: `…/WindowsPowerShell/v1.0` (for `~/.claude/notify.sh`'s `powershell.exe` toast — see [[feedback-windows-chezmoi-check-before-apply]] for the broader WSL/Windows-interop context) and `…/system32` (`clip.exe`). The `case` guard has both `:$_wd:` and `:$_wd/:` arms because Windows lists these dirs with a trailing slash — without the second arm it's not a true no-op on un-migrated hosts.

**Why it matters:** the rc change alone is **inert** until `appendWindowsPath=false` is set and WSL restarted — it only *re-adds* dirs that the flip strips. Both halves are required. Verified end-state: `chezmoi status` 1.6 s → 0.1 s, `$PATH` `/mnt` entries 89 → 2, `powershell.exe` still resolves.

**How to apply:**
- If a user reports chezmoi/`czt`/`cz*` (or any LookPath-heavy CLI) feeling slow on a WSL host, check `grep appendWindowsPath /etc/wsl.conf` and `echo $PATH | tr ':' '\n' | grep -c /mnt/` (~89 = not fixed) before theorizing. Confirm with `time chezmoi status` (~1.6 s and low CPU = this issue).
- Other WSL hosts each need their own `wsl.conf` flip + restart; the tracked rc re-add reaches them via `czu`/`cza` but is a no-op until they flip.
- Trade-off accepted: other Windows `.exe`s (`explorer.exe`, VS Code `code`) leave the WSL `$PATH`; re-add per-host in `~/.zshrc.local`.
- Documented in README §troubleshooting ("`czt` / chezmoi feels slow on WSL") + a `CLAUDE_CHANGELOG.md` row.
