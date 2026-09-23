---
name: project-wsl-appendwindowspath-false
description: "On WSL hosts, exec.LookPath-heavy tools are slow because appendWindowsPath=true puts ~90 /mnt/c dirs on $PATH and each failed lookup stat-walks them over slow drvfs. Fix = appendWindowsPath=false in /etc/wsl.conf + a WSL-gated rc re-add of just PowerShell + system32."
metadata:
  node_type: memory
  type: project
---

On WSL hosts in this repo, any tool that does `exec.LookPath` / `command -v` for a binary that **isn't installed** is slow, because WSL2's default `appendWindowsPath=true` (in `/etc/wsl.conf`) tacks the entire Windows `%PATH%` (~90 `/mnt/c` dirs) onto `$PATH`, and a not-found lookup stat-walks *every* dir over the slow 9p/drvfs mount (~1–3 ms each cold). Found in May 2026 via chezmoi (since removed), which probed for clipboard tools at startup and cost ~1.6 s per invocation (strace: ~660 stats, ~580 ENOENT; ~15% CPU, the rest blocked on stats) — NOT network, subprocess, or template-render cost.

The adopted fix:
1. **Host-global:** `appendWindowsPath=false` under `[interop]` in `/etc/wsl.conf`, then `wsl --shutdown` from a Windows terminal so the distro re-reads it. Repo-deployed as the `[bootstrap.files."/etc/wsl.conf"]` entry in `config.wsl.toml` (source `configs/wsl/wsl.conf`, gated by the `wsl` `MISE_ENV` token; mise elevates itself, so the live run needs the user — see [[feedback-sudo-not-passwordless]]). `wsl --shutdown` is still required afterward.
2. **Repo-tracked:** a WSL-gated PATH block near the top of `dotfiles/zshrc.tera` + `dotfiles/bashrc.tera` (parity pair — keep both in lockstep) that re-adds back ONLY the two Windows dirs still called from WSL: `…/WindowsPowerShell/v1.0` (for `~/.claude/notify.sh`'s `powershell.exe` toast) and `…/system32` (`clip.exe`). The `case` guard has both `:$_wd:` and `:$_wd/:` arms because Windows lists these dirs with a trailing slash — without the second arm it's not a true no-op on un-migrated hosts.

**Why it matters:** the rc change alone is **inert** until `appendWindowsPath=false` is set and WSL restarted — it only *re-adds* dirs that the flip strips. Both halves are required. Verified end-state (May 2026): a LookPath-heavy call 1.6 s → 0.1 s, `$PATH` `/mnt` entries 89 → 2, `powershell.exe` still resolves.

**How to apply:**
- If a user reports shell startup or any LookPath-heavy CLI feeling slow on a WSL host, check `grep appendWindowsPath /etc/wsl.conf` and `echo $PATH | tr ':' '\n' | grep -c /mnt/` (~89 = not fixed) before theorizing. Confirm with `time` on the slow command (~1–2 s and low CPU = this issue).
- Other WSL hosts get the `wsl.conf` flip from `./bootstrap.sh --dev` (the `wsl` token loads `config.wsl.toml`), then still need a `wsl --shutdown`; the tracked rc re-add is a no-op until the restart.
- Trade-off accepted: other Windows `.exe`s (`explorer.exe`, VS Code `code`) leave the WSL `$PATH`; re-add per-host in `~/.zshrc.local`.
- Documented in README §troubleshooting ("Shell startup / a PATH-scanning command feels slow on WSL") + a `CLAUDE_CHANGELOG.md` row.
