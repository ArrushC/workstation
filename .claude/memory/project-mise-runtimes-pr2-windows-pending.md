---
name: project-mise-runtimes-pr2-windows-pending
description: mise-runtimes PR 1 (Linux) shipped 2026-09-16; PR 2 (Windows half — spec decisions 10–14) is designed but NOT yet planned or implemented
metadata:
  type: project
---

The mise consolidation landed in two halves. PR 1 (Linux, branch `feat/mise-runtimes`, 2026-09-16) is done and verified on the WSL dev host. **PR 2 (Windows) is still open work**: spec `docs/superpowers/specs/2026-09-13-mise-runtimes-design.md` decisions 10–14 (portable mise with a new `BinSubdir = "bin"` field — the zip nests `mise.exe` + `mise-shim.exe`; `Invoke-MiseRuntimes` after chezmoi apply; `vendor\autoload\mise.nu` for Nushell + `mise activate pwsh` in the profile; `Invoke-PythonEnv` resolving uv via `mise which uv`; retire `UV_VERSION`'s `bootstrap.ps1` dual-edit and add `MISE_VERSION`'s, swapping them in `bump-versions.sh` EXCLUDE + `check_version_pins`). No plan file exists yet — next step is `superpowers:writing-plans` against those decisions.

**Why:** the user chose "Include Windows now" during brainstorming; only the sequencing (Linux first) deferred it. Until PR 2 merges, Windows still installs uv directly and gets no node/go/LSP servers, while the dev conf.d already deploys there (mise will warn about missing tools once `mise` is installed on Windows).

**How to apply:** when the user returns to this work, start from the spec (not the Linux plan), keep the `.ps1` BOM + `Invoke-CurlRequest` parity constraints, and remember the Linux-side facts that bit PR 1: `mise ls --json` lists declared-but-uninstalled tools (use `mise where`), TypeScript must stay on the 5.x line for ts-ls (`TYPESCRIPT_VERSION` is bumper-EXCLUDEd), and the ts-ls `initialize` probe needs stdin held open.
