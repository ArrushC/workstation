# TUI Phase B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the three Phase-B fleet-ops features: parallel push dashboard (per-host multi-runner), host drill-in quick-stats, guided SSH key distribution.

**Architecture:** A new asyncio `MultiRunner` (core, textual-free) runs `update-hosts.sh --name <host>` per host under a semaphore; `PushScreen` renders per-host rows live and returns outcomes to the Fleet panel (`last_push` column). Quick-stats is one BatchMode ssh emitting delimited `key value` sections parsed by a never-raise parser into a read-only screen. Key distribution composes `manage-hosts.sh --copy-id --name` sequentially under app-suspend behind an injectable seam. Pushes and local tasks are mutually exclusive via a new `_push_inflight` gate.

**Tech Stack:** Python ≥3.14, Textual 8.x, pytest + pytest-asyncio, uv.

**Spec:** `docs/superpowers/specs/2026-08-10-tui-phase-b-design.md` — its numbered sections are the binding contracts; this plan adds task boundaries and test obligations.

## Global Constraints

- Branch: `feat/tui-phase-b` (created off main; spec already on main). Push after every commit. PR targets main.
- Established disciplines: core never imports textual; never-raise seams; markup-inert dynamic text (remote/user text `Text()`-wrapped in tables, `markup=False` in logs/statics, `escape()` for exception text); ssh children killed AND reaped on cancellation (probe_setup discipline); worker groups — new `push` and `host-stats` join `task`/`summary`/`probes`/`fleet-refresh`/`fleet-confirm`/`health-refresh`/`health-write`/`watch`.
- ssh argv hardening: `-o BatchMode=yes -o ConnectTimeout=3` and `--` BEFORE the destination, always.
- Notifications: toast messages carry COUNTS AND DURATION ONLY — never host names or any hosts.conf-derived text (notify.sh WSL interpolation, parked minor).
- Env scrub for all subprocess env: MAKEFLAGS/MFLAGS/MAKELEVEL (existing `_SCRUB` in core/runner.py).
- Suite enters at 221 passed; env-independent (no real ssh/subprocess/suspend/notify in tests; autouse `_no_real_notifier` fixture already exists).
- Pre-commit invariant hook stays green; never `--no-verify`. Conventional-commit subjects as given.
- Footer/help discipline: any new key lands in PANEL_KEYS (app.py) + HelpScreen in the same task.

---

### Task 1: MultiRunner core (spec §1 "core/multirun.py")

**Files:** Create `tui/src/workstation_tui/core/multirun.py`; modify `tui/src/workstation_tui/core/runner.py` (export `scrubbed_env()`); tests `tui/tests/test_multirun.py`.

**Interfaces produced (later tasks rely on these exact names):**
- `runner.scrubbed_env() -> dict[str, str]` — os.environ minus `_SCRUB`; refactor the existing runner to call it (behavior unchanged).
- `@dataclass class HostRun`: `name: str`, `state: str` (`"queued"|"running"|"done"|"failed"|"cancelled"`), `rc: int | None = None`, `started: float | None = None`, `finished: float | None = None`, `lines: list[str]` (default_factory); `elapsed(now: float) -> float | None` (None until started; finished-started once finished).
- `class MultiRunner`: ctor `(commands: dict[str, list[str]], *, limit: int = 4, exec_fn=asyncio.create_subprocess_exec)`; attribute `runs: dict[str, HostRun]` (same insertion order as `commands`); `async def run(self, on_update: Callable[[str], None]) -> None`; `def cancel(self) -> None`.

Binding contract = spec §1. Implementation notes:
- `run()` starts every command through an `asyncio.Semaphore(limit)`; per host: state→running (stamp `started` via `time.monotonic()`), spawn with `stdout=PIPE, stderr=STDOUT, env=scrubbed_env()`, stream lines (`await proc.stdout.readline()`), decode `errors="replace"`, `.rstrip("\n")`, append to `lines` capped at 5000 (drop oldest), `on_update(name)` after every appended line and every state change.
- rc 0 → `done`, else `failed`; stamp `finished`. Spawn failure (OSError etc.) → state `failed`, `rc=None`, the exception's `type(exc).__name__: {exc}` text as the single log line — never raises.
- `cancel()`: for running procs `proc.kill()` then reap (`await proc.wait()` under `contextlib.suppress(Exception)` inside the still-running `run()` — implementation: cancel() sets a flag/cancels an Event; the per-host coroutine handles `asyncio.CancelledError` kill+reap exactly like `probe_setup`); unstarted (still `queued`) → `cancelled`. Running hosts that were killed → `cancelled` (not failed). `run()` returns normally after cancel (no exception to the caller).
- No textual imports; module docstring notes it is deliberately separate from the single-flight runner.

Tests (8, all with fake `exec_fn` — the `probe_setup` fake-subprocess pattern in test_fleet.py is the model): concurrency cap respected (track max simultaneous fakes with an event-controlled fake); state transitions queued→running→done and →failed by rc; lines streamed + on_update fired per line; line cap at 5000; spawn-failure → failed rc=None with exception text line; cancel kills running (fake records kill) + reaps + marks cancelled; cancel marks queued as cancelled; insertion order of `runs` matches `commands`.

Commit: `feat(tui): MultiRunner — capped parallel subprocess engine`. Suite → REAL count (~229).

---

### Task 2: PushScreen + p/P wiring (spec §1 "PushScreen", first half)

**Files:** Create `tui/src/workstation_tui/app/widgets/push_screen.py`; modify `tui/src/workstation_tui/core/fleet.py` (tighten `push_command`), `tui/src/workstation_tui/app/panels/fleet.py` (rewire p/P), `tui/src/workstation_tui/app/theme.py` (PUSH_ICONS), `tui/tests/test_fleet.py` (push_command signature), new `tui/tests/test_push_screen.py`.

**Interfaces:**
- Consumes Task 1: `MultiRunner`, `HostRun`.
- Produces: `class PushScreen(Screen[dict[str, str] | None])` — ctor `(commands: dict[str, list[str]], *, runner_factory=MultiRunner)`; dismisses with `{host_name: final_state}` (states from HostRun) or None if closed before starting (cannot happen via UI; None reserved). `push_command(repo_root: Path, name: str) -> list[str]` (name now REQUIRED — bare/all form removed).

Binding contract = spec §1. Implementation notes:
- `push_command`: drop `name: str | None` → `name: str`; always `["<repo>/scripts/update-hosts.sh", "--name", name]`. Update the existing `test_push_command` accordingly (the `None` assertion is removed — this is the ONE sanctioned existing-test change).
- Fleet panel: `action_push_selected` → `_linux_only_gate` → selected entry → ConfirmModal(`f"push {entry.name}?"`) → open screen with `{entry.name: push_command(root, entry.name)}`. `action_push_all` → gate → hosts non-empty → ConfirmModal(`f"push ALL {len(self.hosts)} host(s)?"`) → `{e.name: push_command(root, e.name) for e in self.hosts}`. Both via a worker that `await self.app.push_screen_wait(PushScreen(cmds))` then hands the outcome dict to `_apply_push_outcomes(outcomes)` — a stub in THIS task (stores nothing yet, just calls `self.refresh_panel()`); Task 3 fleshes it out. `_confirm_and_run` remains for remove-host.
- PushScreen UI: DataTable (`cursor_type="row"`, row key = host name) columns `st` (width 2), `host` (18), `time` (7), `last line` (rest); summary Static `#push-summary` beneath (`markup=False`), text `"N running · N done · N failed · N queued"` (include `· N cancelled` only when >0). Every cell `Text()`-wrapped; state glyph via new theme dict `PUSH_ICONS: {"queued": ("·", M["overlay0"]), "running": ("●", M["blue"]), "done": ("✓", M["green"]), "failed": ("✗", M["red"]), "cancelled": ("–", M["yellow"])}` rendered through the existing `icon()`.
- Lifecycle: `on_mount` starts an on-loop worker (group `"push"`, exclusive=True) running `await self._runner.run(self._on_update)`; on_update re-renders that host's row + summary (same loop — direct widget access). A 1s `set_interval` re-renders elapsed for running rows; stopped when the run completes. Elapsed renders `m:ss`.
- Keys (screen BINDINGS): `enter` → TextViewScreen(`"\n".join(run.lines)`, title=host name) for the cursor row (markup-inert body is TextViewScreen's existing contract); `x` → ConfirmModal("cancel push?") → `runner.cancel()`; `escape` → if any run `queued`/`running`: ConfirmModal("push still running — cancel and close?") → yes: cancel + dismiss(outcomes), no: stay; else dismiss(outcomes). `outcomes = {name: run.state for name, run in runner.runs.items()}`.
- PANEL_KEYS: fleet keeps `("p", "Push"), ("P", "Push all")` (labels unchanged); HelpScreen fleet section gains a line describing the dashboard keys (`enter log · x cancel · esc close`).

Tests (6): p on cursor host → confirm → screen opened with exactly that one command dict; P → all hosts; rows render with queued glyphs before run; scripted fake runner_factory drives done/failed states → summary counts + glyphs update; enter opens TextViewScreen with that host's lines; esc while running asks (decline stays), esc when finished dismisses with the outcomes dict. Inject `runner_factory` returning a scripted fake (records commands, exposes runs, fires on_update on demand) — no real MultiRunner/subprocess.

Commit: `feat(tui): push dashboard screen (per-host rows + drill-in log)`. Suite → REAL count (~235).

---

### Task 3: Push integration — mutual exclusion, last-push column, notification (spec §1 rest)

**Files:** Modify `tui/src/workstation_tui/app/app.py`, `tui/src/workstation_tui/app/panels/fleet.py`, `tui/src/workstation_tui/app/widgets/push_screen.py` (notify hook), `tui/src/workstation_tui/app/widgets/help_screen.py`; tests `tui/tests/test_push_integration.py`.

**Interfaces:**
- Consumes: Task 2's PushScreen + `_apply_push_outcomes` stub.
- Produces: app attr `_push_inflight: bool` (False default); fleet attr `last_push: dict[str, tuple[str, float]]`; pure helper `fleet.py (panel module) def rel_age(delta_secs: float) -> str`.

Binding contract = spec §1 (mutual exclusion + last_push + notification). Implementation notes:
- App: `_push_inflight = False` in ctor. `launch_task` and `run_task_sequence` refuse when `self._push_inflight` (`notify("push running", severity="warning")`) — add to the existing `_task_inflight or self._runner.busy` checks. `_watch_tick` also returns early when `_push_inflight`.
- PushScreen sets/clears it: `self.app._push_inflight = True` when the run worker starts, cleared in a `finally:` when `run()` returns (NOT when the screen closes — a finished dashboard left open must not block local tasks). Entry guard: the fleet actions refuse to open the screen when `app._task_inflight or app._runner.busy` (`notify("task running", severity="warning")`) — checked before the ConfirmModal.
- `_apply_push_outcomes(outcomes: dict[str, str])`: stamp `self.last_push[name] = (state, time.time())` for every outcome, `self._render_rows()`, `self.refresh_panel()` (re-probe).
- Fleet table gains column `push` (key="push", width 7) between `repo` and `name`: `icon(state, PUSH_ICONS)` + `Text(f" {rel_age(now - ts)}", style=...)` — implement as a single assembled `Text`; never-pushed hosts render dim `–`. `rel_age`: `<60s → "42s"`, `<3600 → "7m"`, `<86400 → "3h"`, else `"2d"` (int floor). Pure function, unit-tested.
- Notification: when the run completes (same place `_push_inflight` clears), compose counts: `n_ok` (done), `n_failed` (failed), duration = max finished − min started (0 if none ran). Any failed → ALWAYS `app.notifier("workstation", f"push — {n_ok} ok, {n_failed} failed ({int(dur)}s)")`; all ok → same message only when `dur >= app.notify_threshold_secs`; all cancelled → no toast. NEVER include host names.
- HelpScreen fleet section notes the push column glyphs.

Tests (6): launch_task refused while `_push_inflight` (toast recorded, runner untouched); push entry refused while `_task_inflight`; `_watch_tick` skips while `_push_inflight`; `_apply_push_outcomes` populates last_push + push column renders glyph+age (freeze time via injected `now` or monkeypatched time.time); rel_age boundaries (59s/60s/3599s/3600s/86400s); notification rules (failed→always, ok-long→yes, ok-short→no, cancelled→none) via injected notifier.

Commit: `feat(tui): push mutual-exclusion + fleet last-push column + push notify`. Suite → REAL count (~241).

---

### Task 4: Quick-stats core (spec §2 "core/hoststats.py")

**Files:** Create `tui/src/workstation_tui/core/hoststats.py`; tests `tui/tests/test_hoststats.py`.

**Interfaces produced:**
- `STATS_REMOTE_SCRIPT: str` (module constant), `stats_command(entry: HostEntry) -> list[str]`, `@dataclass class HostStats` (all fields `str | None` default None, except `repo_present: bool | None`), `parse_stats(text: str) -> HostStats`.

Binding contract = spec §2. Implementation notes:
- `stats_command` = `["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "--", f"{entry.user}@{entry.address}", STATS_REMOTE_SCRIPT]`.
- `STATS_REMOTE_SCRIPT` — ONE POSIX-sh string emitting `key value` lines under section markers (keys make parsing robust; every probe degrades to a `missing` value, the script itself never exits non-zero on a partial host). Verbatim:

```sh
echo '===vitals==='
echo "uptime $(uptime 2>/dev/null || echo missing)"
echo "mem $(free -m 2>/dev/null | awk 'NR==2 {print $3"/"$2"MB"}' || echo missing)"
echo "disk $(df -P / 2>/dev/null | awk 'NR==2 {print $3"/"$2" ("$5")"}' || echo missing)"
echo "kernel $(uname -sr 2>/dev/null || echo missing)"
echo "os $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo missing)"
echo '===workstation==='
repo="$HOME/.local/share/chezmoi"
if [ -d "$repo" ]; then
  echo "repo present"
  echo "commit $(git -C "$repo" log -1 --format='%h %cr' 2>/dev/null || echo missing)"
  echo "branch $(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo missing)"
  echo "dirty $(git -C "$repo" status --porcelain 2>/dev/null | wc -l)"
else
  echo "repo absent"
fi
stampdir="$HOME/.local/share/workstation-install"
newest=$(ls -t "$stampdir" 2>/dev/null | head -1)
if [ -n "$newest" ]; then
  echo "stamp $(stat -c %Y "$stampdir/$newest" 2>/dev/null || echo missing)"
else
  echo "stamp missing"
fi
cz="$(command -v chezmoi || echo "$HOME/.local/bin/chezmoi")"
echo "drift $("$cz" status 2>/dev/null | wc -l | tr -d ' ' || echo missing)"
echo '===session==='
echo "users $(who 2>/dev/null | wc -l | tr -d ' ' || echo missing)"
echo "names $(who 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || echo missing)"
echo '===tools==='
echo "chezmoi $("$cz" --version 2>/dev/null | head -1 || echo missing)"
echo "git $(git --version 2>/dev/null || echo missing)"
echo "make $(make --version 2>/dev/null | head -1 || echo missing)"
```

- `HostStats` fields: `uptime, mem, disk, kernel, os, commit, branch, dirty, stamp_epoch, drift, users, names, tool_chezmoi, tool_git, tool_make` (all `str | None`), `repo_present: bool | None`.
- `parse_stats`: iterate lines; `===...===` switches section (tracked but keys are globally unique, so the section is informational); `key<space>rest` maps onto fields (`repo present/absent` → bool); value `"missing"` or empty → None; unknown keys and garbled lines IGNORED; empty/None input → all-None HostStats. Never raises (whole body defensive; a line without a space is skipped).
- The chezmoi PATH fallback (`$HOME/.local/bin/chezmoi`) exists because non-interactive prod ssh doesn't source the rc PATH (known repo constraint).

Tests (7): argv exact (incl. `--` position + script as final single arg); full happy-path sample text → every field; partial (vitals only) → others None; `repo absent` → repo_present False + git fields None; garbled/binary junk → all-None, no raise; `missing` values → None; dirty/drift numeric strings preserved as str.

Commit: `feat(tui): host stats command + never-raise parser`. Suite → REAL count (~248).

---

### Task 5: HostStatsScreen + enter routing (spec §2 rest)

**Files:** Create `tui/src/workstation_tui/app/widgets/host_stats.py`; modify `tui/src/workstation_tui/app/panels/fleet.py` (row-selected routing), `tui/src/workstation_tui/app/app.py` (PANEL_KEYS), `tui/src/workstation_tui/app/widgets/help_screen.py`, `tui/tests/test_footer_keys.py` (carve-out extends to fleet); tests `tui/tests/test_host_stats_screen.py`.

**Interfaces:**
- Consumes Task 4: `stats_command`, `parse_stats`, `HostStats`.
- Produces: `class HostStatsScreen(ModalScreen[None])` — ctor `(entry: HostEntry, *, exec_fn=asyncio.create_subprocess_exec, probe=probe_host)`.

Binding contract = spec §2. Implementation notes:
- Routing: `FleetPanel.on_data_table_row_selected` (the dotfiles/health precedent — DataTable consumes enter) → resolve entry → `self.app.push_screen(HostStatsScreen(entry))`. PANEL_KEYS fleet gains `("enter", "Stats")`; `test_footer_keys.py`'s carve-out `("health", "dotfiles")` → `("health", "dotfiles", "fleet")`. HelpScreen fleet gains the `↵ Stats` line.
- Screen: TextViewScreen-style 90% box; title `host stats — <name>` (Text/markup-inert). Body = key/value rows (two-column grid of Statics, `markup=False`): sections Vitals (uptime/mem/disk/kernel/os), Workstation (repo/commit/branch/dirty/stamp age/drift), Session (users/names + `latency`), Tools (3 versions). None → `–`. `stamp_epoch` renders as rel-age via Task 3's `rel_age(time.time() - int(epoch))` (guard non-numeric → `–`).
- Worker (on-loop async, group `"host-stats"`, exclusive=True, started on_mount and by `R`): stage 1 `t0=monotonic; state=await probe(entry.address); rtt=monotonic-t0` → latency `f"{rtt*1000:.0f}ms"`; `"down"` → render an `unreachable` banner state (no ssh attempted). Stage 2: spawn `stats_command(entry)` via `exec_fn` with `stdout=PIPE, stderr=DEVNULL`, `await asyncio.wait_for(proc.communicate(), 15.0)`; timeout/OSError → kill+reap (probe_setup discipline) → `unreachable` banner; else `parse_stats(stdout.decode(errors="replace"))` → render. A `loading…` state shows until the worker lands. `escape` closes (cancel the worker group; the CancelledError kill+reap path per probe_setup).
- No caching; closing discards (screen instance owns all state).

Tests (5): enter on a fleet row opens the screen for that entry (fake providers); happy path — injected fake exec_fn returns sample bytes → rendered values appear (query Statics); probe "down" → unreachable banner, exec_fn NEVER called; timeout → unreachable + fake proc killed; `R` re-runs (exec_fn called twice).

Commit: `feat(tui): host drill-in quick-stats screen`. Suite → REAL count (~253).

---

### Task 6: Guided key distribution (spec §3)

**Files:** Create `tui/src/workstation_tui/app/widgets/keydist_modal.py`; modify `tui/src/workstation_tui/app/app.py` (`copy_id_fn` seam + default impl + PANEL_KEYS), `tui/src/workstation_tui/app/panels/fleet.py` (`k` action + resume flow), `tui/src/workstation_tui/core/fleet.py` (`copy_id_command` builder), `tui/src/workstation_tui/app/widgets/help_screen.py`; tests `tui/tests/test_keydist.py`.

**Interfaces:**
- Produces: `core/fleet.py::copy_id_command(repo_root: Path, name: str) -> list[str]` = `["bash", str(repo_root / "scripts" / "manage-hosts.sh"), "--copy-id", "--name", name]`; app ctor param `copy_id_fn: Callable[[list[HostEntry]], list[tuple[str, int]]] | None = None`; `class KeyDistModal(ModalScreen[list[str] | None])` — ctor `(hosts: list[HostEntry], probe_states: dict[str, tuple[str, str | None]], key_present: bool)`, dismisses selected names or None.

Binding contract = spec §3. Implementation notes:
- Modal: `SelectionList` of hosts (prompt = `Text` of `name  <net glyph><repo glyph>` — markup-inert; SelectionList accepts Text prompts), initial selection = names whose probe repo-state == `"ssh-failed"`. Header Static: key path + `present` / `MISSING — the script will offer to generate one` (`markup=False`). Keys: SelectionList's own space toggle; `a` → toggle all (all selected → clear, else select all); `enter` → selected values; zero selected → `notify("no hosts selected", severity="warning")`, stay open; `escape` → None.
- Fleet `k` (`action_distribute_keys`): `_linux_only_gate` → hosts non-empty → key_present = `(Path.home() / ".ssh" / "id_ed25519.pub").exists()` (wrapped try/except → False); worker awaits the modal; on selection: refuse when `app._task_inflight or app._push_inflight` (toast) else run `app.copy_id_fn(entries)` via `asyncio.to_thread` (the default impl blocks in suspend).
- Default `copy_id_fn` (app method `_default_copy_id`, used when ctor param None): `with self.suspend():` loop entries — print banner `=== {name} ({i}/{n}) ===`, `rc = subprocess.run(copy_id_command(root, entry.name)).returncode`, collect `(name, rc)`. (Suspend must run on the app loop: implement like `ssh_to` — a plain method; the to_thread wrapper applies ONLY to injected fns. Resolve: if `copy_id_fn` injected → call directly; else call `_default_copy_id` synchronously from the worker via `call_later`-safe path — implementer: follow `ssh_to`'s "plain method on the loop" precedent; the worker awaits a small asyncio.Event the method sets when done, or simply run the whole flow in the action (not a worker) after the modal callback, mirroring how `ssh_to` is invoked directly from `action_ssh_selected`. Document the chosen shape in the report.)
- Resume flow: per host `panel.append_log(f"copy-id {name}: ok" | f"copy-id {name}: failed (rc={rc})")`; `refresh_panel()` (re-probe heals ssh-failed glyphs); ONE toast `f"key distribution — {n_ok} ok, {n_failed} failed"` (counts only, via app.notify — in-app toast, not the OS notifier; OS notifier NOT used here: the user was just present at the terminal doing password entry).
- PANEL_KEYS fleet gains `("k", "Keys")`; HelpScreen fleet gains it; footer drift test already carves fleet out for enter — `k` is a REAL binding so no carve-out needed.

Tests (6): preselect = exactly the ssh-failed hosts; `a` toggles all; zero-selected confirm → warning + modal stays; confirm → injected copy_id_fn receives entries in TABLE ORDER; resume → per-host rc log lines + re-probe called + counts-only toast (no host name in toast text); `k` gated on `_push_inflight` (toast, copy_id_fn not called).

Commit: `feat(tui): guided key distribution (picker + suspend copy-id)`. Suite → REAL count (~259).

---

### Task 7: Docs + gate

**Files:** `README.html`, `CLAUDE_CHANGELOG.md`.

- README §tui (read the shipped code first — docs must match it exactly): push-dashboard paragraph (p/P open the dashboard; keys inside: enter log, x cancel, esc close; per-host parallel `update-hosts.sh --name`, cap 4; fleet `push` column glyph+age), quick-stats paragraph (`enter` on a fleet row; one BatchMode ssh; sections; unreachable degrade), key-distribution paragraph (`k`; ssh-failed preselect; suspends for password prompts; script's generate-key offer), keys-table rows (`enter` Stats, `k` Keys; p/P descriptions updated). Balance check: every opened tag closed.
- CLAUDE_CHANGELOG row following the existing table format: `| TUI Phase B: push dashboard (p/P, per-host parallel), host quick-stats (enter), guided key distribution (k) | Yes | §tui keys + behavior paragraphs |`
- Gate: `make -C makefile lint MODE=prod && make -C makefile tui-test MODE=prod && bash scripts/check-templates.sh`; live `workstation status`.
- Commit `docs: phase-B README + changelog`. (PR creation is the controller's job after the final whole-branch review.)
