# TUI Phase A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the four Phase-A daily-driver features: desktop notifications, auto-refresh watch mode, provision multi-select, per-file dotfiles apply.

**Architecture:** Notifications are an injectable app seam (`notifier`) fired from both task-completion paths; watch mode is a pausable Textual interval calling the existing refresh; multi-select is panel-local mark state keyed by tool name feeding the existing `run_make_goals`; per-file apply is one new core builder + a panel `enter` flow reusing ConfirmModal/launch_task. Every feature independently testable with the established injection patterns.

**Tech Stack:** Python ≥3.14, Textual 8.x, pytest + pytest-asyncio, uv.

**Spec:** `docs/superpowers/specs/2026-08-10-tui-phase-a-design.md` — its numbered sections are the binding contracts; this plan adds only task boundaries and test obligations.

## Global Constraints

- Branch: `feat/tui-phase-a` (created off main; spec committed). Push after every commit. PR targets main.
- Established disciplines: core never imports textual; never-raise seams; markup-inert dynamic text; worker groups (`task`/`summary`/`probes`); `_task_inflight` single-flight; `Text()` cells; footer PANEL_KEYS/GLOBAL_KEYS registries + HelpScreen updated together with any new key.
- Suite enters at 194 passed; env-independent (inject notifier/providers; no real Popen/make/chezmoi in tests).
- Pre-commit invariant hook stays green; never `--no-verify`. Conventional-commit subjects as given.

---

### Task 1: Desktop notifications (spec §4)

**Files:** `tui/src/workstation_tui/app/app.py`; tests `tui/tests/test_notifications.py`.

Binding contract = spec §4. Implementation notes:
- `notifier: Callable[[str, str], None] | None = None` ctor param; `self.notify_threshold_secs = 10.0` attribute; default `_default_notifier(title, msg)` module function — resolves `Path.home() / ".claude/notify.sh"`, missing → return; else `subprocess.Popen([str(script), title, msg], stdout=DEVNULL, stderr=DEVNULL)` inside try/except Exception (never raises).
- `_maybe_notify(result: TaskResult)` helper: cancelled → no; rc!=0 → notify `"<cmd summary> — failed (rc=N)"`; rc==0 and duration >= threshold → `"<cmd summary> — done (rc=0, Ns)"`; cmd summary = `" ".join(result.command[:2])`, duration rounded to int.
- Called at the end of `_task_flow` (after the existing notify toast, before on_done) and per-command in `_sequence_flow`'s completion path? NO — sequences: call once at sequence end for the LAST result only when the sequence completed or aborted (aborted = failure notify; cancelled = none). Keep it simple and DOCUMENT it.
- Tests (5): failure notifies; success ≥ threshold notifies; quick success doesn't; cancelled doesn't; sequence-abort notifies once. Inject a capturing notifier; threshold set tiny/large per test via the attribute.

Commit: `feat(tui): desktop notifications on task completion`. Suite → REAL count (~199).

---

### Task 2: Auto-refresh watch mode (spec §1)

**Files:** `tui/src/workstation_tui/app/app.py`, `tui/src/workstation_tui/app/widgets/help_screen.py`; tests `tui/tests/test_watch_mode.py`.

Binding contract = spec §1. Implementation notes:
- `watch_interval_secs: float = 30.0` ctor param; `w` binding → `action_toggle_watch`; timer created lazily on first enable via `self.set_interval(self.watch_interval_secs, self._watch_tick, pause=False)`, `.pause()`/`.resume()` thereafter; `self.watch_enabled: bool`.
- `_watch_tick`: `if self._task_inflight or self._runner.busy: return`; else `self.action_refresh()`.
- Header suffix: `_apply_summary`'s header render gains `· watch {int}s` when enabled; ALSO re-render the header immediately on toggle (the toggle shouldn't wait for the next refresh — call the header-update helper directly; extract one if needed).
- `w` joins GLOBAL_KEYS (`("w", "Watch")`) + HelpScreen global list.
- Tests (4): toggle flips state + header marker appears (use a tiny interval + injected providers); tick triggers a provider re-call (counting provider, interval 0.05, wait ~0.2); tick skipped while busy (set `_task_inflight = True`, assert no provider re-call); footer/global keys include `w`.

Commit: `feat(tui): auto-refresh watch mode`. Suite → REAL count (~203).

---

### Task 3: Provision multi-select (spec §2)

**Files:** `tui/src/workstation_tui/app/panels/provision.py`, `tui/src/workstation_tui/app/app.py` (PANEL_KEYS provision entry), `help_screen.py`; tests `tui/tests/test_provision_multiselect.py`.

Binding contract = spec §2. Implementation notes:
- `self.marked: set[str]` keyed by tool name; `space` binding on the panel (`action_toggle_mark`) toggles the cursor row's tool; `esc` (`action_clear_marks`) clears; mark column = NEW first column (width 2) rendered via `sel_marker(name in self.marked)`; `_render_rows` keeps marks across filters/re-renders (marks are name-keyed state, not row state).
- `action_run_tool`: marked set non-empty → `run_make_goals(ordered_marked_names, user_kind=all(kind=="user" for marked))` — wait, needs_sudo formula: `user_kind=False` unless ALL marked are user-kind (any non-user → gate). Compute `user_kind = all(self._tool_kind(n) == "user" for n in ordered)`. Ordered = table order (iterate self.tools, filter marked).
- Clear-on-success: marks cleared when the run's rc==0 — wire via launch_task's `on_result` (already exists): panel passes `on_result=lambda r: self._on_run_result(r)` clearing marks only when `r.returncode == 0 and not r.cancelled`. run_make_goals doesn't take on_result — CHECK: run_make_goals signature; if it doesn't pass through, add passthrough kwargs (`run_make_goals(..., on_result=None)` forwarding to launch_task) — minimal, backward-compatible.
- Mark-count indicator: a small Static next to the filter input (`#provision-marks`), text `N marked` when N>0 else "" (markup-inert).
- PANEL_KEYS provision entry gains `("space", "Mark")` (+ HelpScreen); keep the footer registry ⊆ BINDINGS drift test green (space/escape are real bindings).
- Tests (6): space marks + glyph renders; run with marks = ONE invocation containing all marked names in table order; run without marks = cursor row (existing behavior pinned); esc clears; marks survive filtering; clear-on-success vs persist-on-failure (scripted runner rcs).

Commit: `feat(tui): provision multi-select (mark + bulk run)`. Suite → REAL count (~209).

---

### Task 4: Per-file dotfiles apply (spec §3)

**Files:** `tui/src/workstation_tui/core/chezmoi.py`, `tui/src/workstation_tui/app/panels/dotfiles.py`, `app.py` (PANEL_KEYS dotfiles entry), `help_screen.py`; tests `tui/tests/test_chezmoi.py` (builder) + `tui/tests/test_dotfiles_panel.py` (flow).

Binding contract = spec §3. Implementation notes:
- `apply_target_command(path) -> ["chezmoi", "apply", "--force", str(Path.home() / path)]` (docstring: CWD-safety + prompts-never-fire policy; user confirmed after seeing the pane diff).
- Dotfiles panel `enter` binding (`action_apply_selected`): selected pending path → ConfirmModal(f"apply {path}?") → launch_task(apply_target_command(path), log_to=panel.append_log, on_done=panel.refresh_panel). Guard: no selection / unavailable → notify. NOTE the table-focus interplay: DataTable consumes enter (RowSelected) — bind on the PANEL (bindings resolve up the DOM from the focused table) and verify Pilot-wise; if DataTable's own enter handling swallows it, use the panel's `on_data_table_row_selected` handler instead (the health panel precedent) — implementer picks what the test proves, documents choice.
- PANEL_KEYS dotfiles gains `("enter", "Apply file")` (+ HelpScreen; drift-test carve-out like health's enter if needed).
- Tests (4): builder argv (absolutized, --force); enter+confirm → exact argv launched; decline → nothing; no-selection guard.

Commit: `feat(tui): per-file dotfiles apply`. Suite → REAL count (~213).

---

### Task 5: Docs + gate + PR

**Files:** `README.html`, `CLAUDE_CHANGELOG.md`.

- README §tui: watch-mode sentence + `w` key row; multi-select sentences (space/esc, one-invocation bulk run, clear-on-success) + `space` key row; per-file apply sentence + `enter` key row (dotfiles); notifications sentence (failures always, successes ≥10s, via notify.sh). Accuracy rule: read the shipped code first. HTML balance check.
- CLAUDE_CHANGELOG row: `| TUI Phase A: watch mode (w), provision multi-select (space), per-file dotfiles apply (enter), desktop notifications via notify.sh | Yes | §tui keys + behavior sentences |`
- Gate: `make -C makefile lint MODE=prod && make -C makefile tui-test MODE=prod && bash scripts/check-templates.sh`; live `workstation status`.
- Commit `docs: phase-A README + changelog`; PR `feat(tui): phase A — watch mode, multi-select, per-file apply, notifications` to main; `gh pr checks --watch`. Hand to user (interactive smoke: w toggle feel, space marking, enter-apply, a real >10s task toast).
