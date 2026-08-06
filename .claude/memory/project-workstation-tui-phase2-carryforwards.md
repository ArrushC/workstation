---
name: workstation-tui-phase2-carryforwards
description: Deferred items from TUI Phase 1 (PR #116) that Phase 2+ must pick up, with the final-review rulings
metadata:
  type: project
---

Phase 1 of the workstation TUI (spec `docs/superpowers/specs/2026-08-05-workstation-tui-design.md`, PR #116, 2026-08-05) merged with these deliberately deferred items. Address them in the phase that touches the area:

**Why:** the final whole-branch review triaged all as non-blocking for Phase 1, but two become real bugs the moment Phase 2's CLI consumes the readers.

**How to apply:**
- **Before any CLI/panel consumes them (Phase 2, blocking):** `read_hosts` still raises on missing/undecodable hosts.conf — align with `read_inventory`'s never-raise `(rows, errors)` contract; add tests for `_detect_group`'s failure branches (rc!=0, malformed JSON, non-string group).
- Phase 2 CLI work: add `tui/pyrightconfig.json` (venv `.venv`, extraPaths `src`) to silence repo-level basedpyright noise; decide `tui/uv.lock` keep-vs-drop (if kept, CI should use `uv run --locked` — currently the lock enforces nothing).
- Windows: `bootstrap.ps1` `-Doctor` python-env block gates on wpy shim only and omits `workstation.cmd` from message (Invoke-PythonEnv self-heals, so cosmetic).
- Cosmetics: unused `MagicMock` import in test_makeiface.py; python-env recipe's tab-indented comment line echoes on rebuild (not `@`-prefixed); `versions.py` docstring cites a pin contract versions.mk's header doesn't state; parity-reminder hook's new python-env.sh/bootstrap.ps1 cases have no test-hooks assertions.
- Fleet-wide design question flagged by the final review: `dot_bashrc.tmpl`'s interactive-guard sits ABOVE its `~/.local/bin` PATH export, so NO user-level tool is reachable over non-interactive ssh on prod (python-env recipe now works around it via a DEST PATH-prepend). Phase 2's fleet push/probe features will hit this again — consider moving the export above the guard (parity pair: zshrc↔bashrc).
