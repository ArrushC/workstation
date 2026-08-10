# TUI Phase A — Daily-Driver Wins — Design

**Date:** 2026-08-10
**Status:** Approved (roadmap Phase A: auto-refresh watch, provision multi-select, per-file dotfiles apply, desktop notifications)

## Goal

Four small, independent daily-use improvements to the shipped TUI, per the
approved roadmap recorded in project memory.

## 1. Auto-refresh watch mode

- `w` toggles watch mode; default OFF. When ON, a Textual `set_interval`
  timer fires `action_refresh()` every `watch_interval_secs` (ctor param,
  default 30.0, test-overridable).
- Ticks are SKIPPED while a task is in flight (`_task_inflight` or
  `runner.busy`) — no competition with streaming output; the timer pauses
  on toggle-off (pause/resume, not recreate).
- Header identity line gains a `· watch 30s` suffix while active (rendered
  from the actual interval value). `w` joins GLOBAL_KEYS (footer) and the
  HelpScreen global list.
- Refresh economics unchanged: probes remain Fleet-visibility-gated, so
  watching from the Dashboard stays cheap.

## 2. Provision multi-select

- `space` toggles a mark on the cursor row; marks render in a new narrow
  leading column using the theme's `sel_marker` (`●` blue / `·` dim) —
  the vocabulary shipped for exactly this.
- `r` runs ALL marked tools in ONE make invocation (goals = marked tool
  names, in table order); with NO marks, `r` keeps today's cursor-row
  behavior. `c` stays cursor-row-only. `esc` clears all marks; marks also
  clear after a successful run (rc 0), persist across a failed one.
- Sudo gate unchanged in formula, applied to the set: any marked non-user
  tool → `needs_sudo` (dev mode).
- Mark count surfaces next to the filter input (`N marked`, hidden at 0).
- Marks are keyed by tool name and survive re-renders/filtering (a filtered-
  out marked tool stays marked and still runs).

## 3. Per-file dotfiles apply

- `enter` on a pending row applies JUST that file: ConfirmModal
  ("apply <path>?") → `launch_task(apply_target_command(path),
  log_to=panel, on_done=refresh)`. Declining aborts. `a` (apply all)
  unchanged.
- New builder `core/chezmoi.py::apply_target_command(path) -> list[str]` =
  `["chezmoi", "apply", "--force", str(Path.home() / path)]` — same
  CWD-safety discipline as `target_diff`/`re_add_command`; `--force` per the
  established prompts-never-fire policy (the user just saw the diff in the
  pane and confirmed in-app).

## 4. Desktop notifications

- Task completion notifies via the repo's existing `~/.claude/notify.sh`
  (`title msg` argv, fire-and-forget, WSL→Windows toast already handled):
  - failure (rc != 0, not cancelled): ALWAYS notify.
  - success: notify only when `duration_secs >= notify_threshold_secs`
    (ctor param, default 10.0).
  - cancelled: never notify.
- Injectable `notifier: Callable[[str, str], None] | None` ctor param;
  default implementation resolves `Path.home() / ".claude/notify.sh"` and
  `subprocess.Popen([script, title, msg])` fire-and-forget with DEVNULL
  streams; silently no-ops when the script is missing. Never raises; never
  blocks the event loop (Popen, not run).
- Title `"workstation"`; message e.g. `"make fzf — done (rc=0, 42s)"` /
  `"chezmoi apply — failed (rc=1)"` (command summary = first two argv
  tokens joined, duration rounded).
- Wired into BOTH `launch_task`'s `_task_flow` and `run_task_sequence`'s
  `_sequence_flow` completion paths.

## Error handling

Established patterns: notifier never raises and is fire-and-forget; watch
ticks are no-ops under load; all new dynamic text follows the markup-inert
discipline (OS toasts are outside Textual entirely).

## Testing

Pilot tests per feature: watch (toggle on/off, tick fires refresh, tick
skipped while busy, header marker); multi-select (mark/unmark glyphs, run
marked = one invocation with all names, fallback to cursor row, esc clears,
clear-on-success/persist-on-failure, marks survive filtering); per-file
apply (confirm → argv with absolutized path, decline → no run); notifier
(failure notifies, long success notifies, quick success and cancelled do
not; injectable capture — no real Popen in tests). Suite enters at 194.

## Docs

README §tui: watch-mode sentence + `w` in keys, multi-select sentences,
per-file apply sentence, notifications sentence + threshold. HelpScreen
updates. CLAUDE_CHANGELOG row.
