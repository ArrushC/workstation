---
name: workstation-tui-phase2-carryforwards
description: Post-v1 backlog for the SHIPPED workstation TUI (all 6 phases merged 2026-08-07) — deferred polish + follow-ups with final-review rulings
metadata:
  type: project
---

Updated 2026-08-06 after Phase 2 (headless CLI, branch `feat/workstation-tui-phase2`). Phase 2 CLOSED the Phase-1 blockers: `read_hosts` never-raises, `_detect_group` failure branches tested, `tui/pyrightconfig.json` added, `tui/uv.lock` dropped+gitignored, plus final-review hardenings (loud failure on invalid `WORKSTATION_REPO`, `provision` rejects `VAR=value` args, `dotfiles apply` gates on diff rc).

**PROJECT STATUS (2026-08-07):** all six phases merged — the TUI is v1-complete (README §tui is the user doc; the spec has an as-built-deltas section). Items below are the POST-V1 backlog, all triaged non-blocking.

**Phase-6 additions:** real dashboard health rollup (card is a static pointer; Summary has no health fields); per-command result hook on run_task_sequence if run-all recording is wanted; health-write interleave under rapid runs (self-heals); unavailable-with-stale-cache rows keep last glyph; services_reader called when line renders a reason; health run-one dev-mode fallback pre-summary; $-echo can become cached summary; interop check lacks the spec powershell.exe probe.

**Why kept:** each was ruled cosmetic/deferrable at its final review; none block daily use.

**How to apply (Phase 3+ — address in the phase that touches the area):**
- **Phase 4+ (from Phase 3 final review):** adopt worker `is_cancelled` checks + named worker groups as the standard pattern when more workers land; harden `test_refresh_calls_provider_again` with `await app.workers.wait_for_complete()`; give dashboard cards an error state (they stay "loading…" on provider failure); reconcile spec-vs-implementation drift in the final phase (identity line lives in header not footer, no hostname/EL family, no `[?]` help binding); keep `markup=False` for subprocess-derived strings and `escape()` for exception-derived strings as the rendering precedent.
- **Phase 5+ (from Phase 4 final review):** dedup guard for ProvisionPanel.set_unavailable re-logging on each refresh of a no-make host; SudoModal double-submit re-entrancy (disabled Input + checking state); keepalive linux guard; runner cancel-during-spawn-failure cancelled=False edge; shared "cancelled" toast wording for modal-decline vs task-cancel; app-suspend flow for timestamp_timeout=0 sudoers still deferred (recorded deviation).
- **Phase 6+ (from Phase 5 final review):** parity-pair follow-up — manage-hosts host_exists/remove use unanchored regex grep (a host named web.01 matches web-01 rows); switch to grep -F/anchored literal in BOTH .sh and .ps1 (one commit). Also: add-flow collision e2e test; preserve table cursor by row key across re-renders (fleet+dotfiles); dotfiles _apply_refresh re-logs in-sync/warnings per cycle (needs the once-per-change guard its unavailable path has); _apply_diff lacks the unavailable guard; double refresh_panel per mutation still doubles read+probe cost; probe_states never pruned; ssh option-injection class pre-exists in update-hosts.sh push path (user@ip) — fleet-shared hosts.conf is the vector.
- **Windows CLI degradation:** `doctor`/`updates`/`provision` on Windows emit raw `command not found: make` (rc 127) instead of the spec's "not available here: <reason>" honesty — gate on `HostContext.has_make` when the platform-gating phase lands.
- **Docs drift:** `docs/claude/file-care.md`'s completions entry predates `_workstation` — add its Click-generated/parity-EXEMPT note (CLAUDE.md already has it).
- **Small hardening/polish:** document in `core/chezmoi.py` that chezmoi surfaces deliberately ignore `WORKSTATION_REPO` (mutations target the user's real chezmoi config); `hosts list` prints nothing for empty list (add a "no hosts" line); `read_status` timeout message lacks read_inventory's timeout-specific text; `_capture` helper duplicated across two CLI test files (conftest candidate); provision detected-mode fallback branch untested.
- **Windows Doctor cosmetics:** `bootstrap.ps1` `-Doctor` python-env block gates on wpy shim only, omits `workstation.cmd` (Invoke-PythonEnv self-heals; cosmetic).
- **Still-open fleet design question:** `dot_bashrc.tmpl`'s interactive-guard sits ABOVE its `~/.local/bin` PATH export, so no user-level tool is reachable over non-interactive ssh on prod (python-env recipe works around it via DEST PATH-prepend). Phase 5's fleet push/probe will hit it — consider moving the export above the guard (parity pair: zshrc↔bashrc).
