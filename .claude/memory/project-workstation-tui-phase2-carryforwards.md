---
name: workstation-tui-phase2-carryforwards
description: Deferred items for TUI Phase 3+ (dashboard/panels), updated after Phase 2 (headless CLI) closed the Phase-1 blockers
metadata:
  type: project
---

Updated 2026-08-06 after Phase 2 (headless CLI, branch `feat/workstation-tui-phase2`). Phase 2 CLOSED the Phase-1 blockers: `read_hosts` never-raises, `_detect_group` failure branches tested, `tui/pyrightconfig.json` added, `tui/uv.lock` dropped+gitignored, plus final-review hardenings (loud failure on invalid `WORKSTATION_REPO`, `provision` rejects `VAR=value` args, `dotfiles apply` gates on diff rc).

**Why:** Phase 2's final review triaged the rest as non-blocking; two matter when Phase 3+ touches their area.

**How to apply (Phase 3+ — address in the phase that touches the area):**
- **Phase 4+ (from Phase 3 final review):** adopt worker `is_cancelled` checks + named worker groups as the standard pattern when more workers land; harden `test_refresh_calls_provider_again` with `await app.workers.wait_for_complete()`; give dashboard cards an error state (they stay "loading…" on provider failure); reconcile spec-vs-implementation drift in the final phase (identity line lives in header not footer, no hostname/EL family, no `[?]` help binding); keep `markup=False` for subprocess-derived strings and `escape()` for exception-derived strings as the rendering precedent.
- **Windows CLI degradation:** `doctor`/`updates`/`provision` on Windows emit raw `command not found: make` (rc 127) instead of the spec's "not available here: <reason>" honesty — gate on `HostContext.has_make` when the platform-gating phase lands.
- **Docs drift:** `docs/claude/file-care.md`'s completions entry predates `_workstation` — add its Click-generated/parity-EXEMPT note (CLAUDE.md already has it).
- **Small hardening/polish:** document in `core/chezmoi.py` that chezmoi surfaces deliberately ignore `WORKSTATION_REPO` (mutations target the user's real chezmoi config); `hosts list` prints nothing for empty list (add a "no hosts" line); `read_status` timeout message lacks read_inventory's timeout-specific text; `_capture` helper duplicated across two CLI test files (conftest candidate); provision detected-mode fallback branch untested.
- **Windows Doctor cosmetics:** `bootstrap.ps1` `-Doctor` python-env block gates on wpy shim only, omits `workstation.cmd` (Invoke-PythonEnv self-heals; cosmetic).
- **Still-open fleet design question:** `dot_bashrc.tmpl`'s interactive-guard sits ABOVE its `~/.local/bin` PATH export, so no user-level tool is reachable over non-interactive ssh on prod (python-env recipe works around it via DEST PATH-prepend). Phase 5's fleet push/probe will hit it — consider moving the export above the guard (parity pair: zshrc↔bashrc).
