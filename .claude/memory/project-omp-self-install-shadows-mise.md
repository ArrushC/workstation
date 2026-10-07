---
name: project-omp-self-install-shadows-mise
description: "oh-my-pi's own installer/self-update put %LOCALAPPDATA%\\omp on the Windows User PATH (twice), shadowing mise's pinned omp; removed 2026-10-01"
metadata:
  type: project
---

On the Windows host, `omp` resolved to `%LOCALAPPDATA%\omp\omp.exe`, not mise's shim. oh-my-pi's own installer/self-update had put that directory on the User PATH twice, ahead of `%LOCALAPPDATA%\mise\shims` (the dir also held `omp.exe.*.bak` and `omp.exe.broken` from 2026-09-07). This repo never installed it there (`git log -S` finds nothing), so the old portable-tool cleanup (since removed) never knew about it.

The user had both entries removed on 2026-10-01, after the PR 4 live run. The directory itself was left in place.

**Why:** a self-updating tool that also has a mise pin can quietly win on PATH, and the pin then means nothing.

**How to apply:** if `Get-Command omp` (or another self-updating CLI) on Windows stops pointing at the mise shim, check the User PATH for a vendor dir ahead of the shims before you suspect mise. An `omp` self-update may re-add the entry. Remove it only when the user asks; it's their PATH. Related: [[project-mise-runtimes-shipped]].
