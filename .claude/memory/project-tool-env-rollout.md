---
name: project-tool-env-rollout
description: Host state of the locked Python/LSP environments (scripts/tool-env.py), merged in #112 on 2026-11-03; #112's lazy specialist tools were reverted to the full eager toolbelt the same day.
metadata:
  type: project
---

Update on 2026-11-03: PR #112 merged as `8e52725`. The user then requested restoring
the full default toolbelt for consistency. The follow-up removes the 68 newly lazy
declarations; only the pre-existing cht.sh/graft exceptions remain lazy. Locked
environments, shared installation, and Windows maintenance stay in place. Do not
reintroduce the smaller default. After the merge, WSL's `ws update` published python
`ebd7de6a` and lsp `c7239507` (`tool-env.py status` exit 2: 4 superseded items, 0 runtimes,
for `--clean`), and every eager tool was already installed there. After #113 (`6e0a751`) all
three hosts ran `ws update` on 2026-11-03: WSL and Windows (python `d4860b36`, lsp `8b371edf`)
had every declared tool, and atc-cache-dev10 built `ebd7de6a`/`c7239507` for the first time and
installed process-compose and restic. `--clean` hasn't run on any host. The bullets below are
the pre-merge snapshot.

Earlier on 2026-11-03 the simplification (lazy specialist tools, `environments/{python,lsp}` locks,
`scripts/tool-env.py`, Windows `bootstrap.ps1 -MaintenanceOnly` from `ws update`) was committed
on branch `tool-env-environments` and opened as a PR, not merged. The Windows checkout was
clean at 1952628 with no work of its own, so it carries over through an ordinary merge and then
`ws update` on Windows. Neither host had run the new code's `ws update` yet.

- WSL/Linux: active. Generations `de655584` (python) and `140b9933` (lsp), built by the final
  script. Kept for rollback: Codex's `aa3a10f8`/`f7a2d704` and the pre-generation venv at
  `~/.local/share/workstation-python/{bin,lib,lib64,pyvenv.cfg}` (inert). Backups:
  `~/.local/state/workstation/environment-backup-20261102T080300Z` (pre-change launchers) and
  `-20261102T083420Z` (Codex's launchers).
- Windows: not active. The upgrade was rehearsed on a scratch copy of the real layout (31/31
  checks pass). The only host change made was removing the stale npm `.ps1` shims
  ([[project-windows-ps1-shadows-cmd]]).
- Windows renames: `atomic_write` skips unchanged files and retries a rename for up to 1 s on
  WinError 5/32, because Check Point's scan-on-close blocks renames
  ([[project-windows-checkpoint-rename-race]]).
- mise 2026.9.9 lazy semantics, verified in a scratch home: `mise install`, `mise run` and
  `mise bootstrap --only tools` skip `lazy = true` tools, and the shim installs on first use. So
  `lazy_bins` must name every command a tool ships (age-keygen, ug+, decorate and hsql were missing).

**Why:** the next session needs to know Windows still needs `ws update` after the merge, and that
superseded generations are left until someone runs `mise run tool-env --clean` by hand.
**How to apply:** check `git log` before assuming any of this is still uncommitted.
