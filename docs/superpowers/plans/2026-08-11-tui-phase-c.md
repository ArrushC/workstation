# TUI Phase C Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the three Phase-C features: command palette (Textual built-in + custom providers), parsed check-updates table with cache + dashboard line, task history store + browser + re-run.

**Architecture:** Two new textual-free core modules (`updates.py` parser/cache, `history.py` store) feed three new modal screens (`UpdatesScreen`, `HistoryScreen`) and three palette `Provider`s (`app/palette.py`) that only ever call existing action methods. Recording hooks tee task output at the existing `_task_flow`/`_sequence_flow` choke points plus PushScreen/keydist completion. Every default on-disk path is routed through a monkeypatchable module function so the suite never touches the real `~/.cache`.

**Tech Stack:** Python ≥3.14, Textual 8.2.8 (`textual.command` Provider/Hit/DiscoveryHit API), pydantic models, pytest + pytest-asyncio, uv.

**Spec:** `docs/superpowers/specs/2026-08-11-tui-phase-c-design.md` — its numbered sections are the binding contracts; this plan adds task boundaries, exact interfaces, and test obligations.

## Global Constraints

- Branch: `feat/tui-phase-c` (created off main; spec already on main). Push after every commit. PR targets main.
- Established disciplines: core never imports textual; never-raise seams (stores, parsers, providers — a provider exception would break the palette, so providers catch and yield nothing); markup-inert dynamic text (`Text()` cells, `markup=False` statics/logs, `escape()` for exception text; palette hits use `matcher.highlight(<plain str>)` and static `help` strings only); worker groups — new `history`, `updates` join the vocabulary; `_task_inflight`/`_push_inflight` gates apply to palette-launched actions because the palette calls the same methods.
- On-disk defaults: `~/.cache/workstation-tui/updates.json` and `~/.cache/workstation-tui/history/` — BOTH resolved via module-level functions (`_default_updates_cache_path()`, `_default_history_root()` in app.py) that an AUTOUSE conftest fixture monkeypatches to `tmp_path` (the Phase-A notifier lesson: un-injected tests must never reach real per-user state).
- Toast/notify text: counts, durations, static words only — no host names in OS toasts (notify.sh WSL interpolation unfixed).
- Suite enters at 266; env-independent (no real make/ssh/subprocess/suspend/notify).
- Pre-commit invariant hook stays green; never `--no-verify`. Conventional-commit subjects as given.
- Footer/help discipline: any new key lands in GLOBAL_KEYS/PANEL_KEYS + HelpScreen in the same task.
- Post-#141 facts: startup refresh is deferred via `call_after_refresh`; `ProvisionPanel` has a `_composed` guard (deliberately only that panel). Palette entity reads use panel LIST attributes (populated regardless of mount); cursor moves happen only on user selection (post-mount) — no new guards needed.

---

### Task 1: Updates core — porcelain argv, parser, cache (spec §2 core)

**Files:** Modify `tui/src/workstation_tui/core/makeiface.py` (`check_updates_command`); create `tui/src/workstation_tui/core/updates.py`; tests `tui/tests/test_updates.py` (+ adjust `tui/tests/test_makeiface.py` if it pins the old argv).

**Interfaces produced:**
- `check_updates_command(repo_root: Path, mode: str, *, porcelain: bool = True) -> list[str]` = `make_command(repo_root, ["check-updates"], mode) + (["CHECK_UPDATES_PORCELAIN=1"] if porcelain else [])`. CHECK the headless CLI (`cli.py`): if `workstation updates` calls this builder for human-readable output, pass `porcelain=False` explicitly THERE so CLI output is unchanged (pin with a test if a CLI test covers it).
- `class UpdateRow(BaseModel)`: `status: str` (`ok|update|ahead|rolling|unknown`), `name: str`, `detail: str`, `pinned: str | None = None`, `latest: str | None = None`.
- `parse_updates(text: str) -> list[UpdateRow]`: split lines; each `status|name|detail` (split on `|`, maxsplit=2) with status in the known set → row; for `status == "update"` match `detail` against `^(\S+) → (\S+)$` → `pinned`/`latest`; any other line ignored; never raises (whole body defensive, non-str → []).
- `class UpdatesCache(BaseModel)`: `checked_at: str | None = None` (ISO-8601 UTC), `rows: list[UpdateRow] = []`.
- `load_updates_cache(path: Path) -> UpdatesCache` (missing/corrupt/schema-mismatch → empty `UpdatesCache()`; never raises); `save_updates_cache(path: Path, cache: UpdatesCache) -> bool` (mkdir parents, write `path.with_suffix(".tmp")` then `os.replace` — the health-cache discipline; False on failure, never raises).
- `STATUS_ORDER: dict[str, int] = {"update": 0, "ahead": 1, "unknown": 2, "ok": 3, "rolling": 4}` and `sort_rows(rows, key: str) -> list[UpdateRow]` (`key="status"` → (STATUS_ORDER, name); `key="name"` → name; unknown key → status order).

Binding contract = spec §2 (core paragraphs). Tests (8): porcelain argv appends the var as the LAST token + `porcelain=False` omits it; parser happy path all five statuses; `update` detail split into pinned/latest, other statuses keep None; garbage/blank/non-str → []; unknown status skipped; cache round-trip through tmp_path; corrupt JSON → empty; sort_rows both keys.

Commit: `feat(tui): check-updates porcelain argv + parser + cache`. Suite → REAL count (~274).

---

### Task 2: UpdatesScreen + `u` rewiring + dashboard line (spec §2 screen + dashboard)

**Files:** Create `tui/src/workstation_tui/app/widgets/updates_screen.py`; modify `tui/src/workstation_tui/app/app.py` (`updates_cache_path` ctor param + `_default_updates_cache_path()` + `_make_context()` helper), `tui/src/workstation_tui/app/panels/provision.py` (`action_updates`), `tui/src/workstation_tui/app/panels/dashboard.py` (provision card line), `tui/src/workstation_tui/app/theme.py` (`UPDATE_ICONS`), `tui/src/workstation_tui/app/widgets/help_screen.py`, `tui/tests/conftest.py` (autouse fixture); tests `tui/tests/test_updates_screen.py`.

**Interfaces:**
- Consumes Task 1.
- Produces: app attr `updates_cache_path: Path`; module fn `_default_updates_cache_path() -> Path` (`Path.home() / ".cache/workstation-tui/updates.json"`); app helper `_make_context() -> tuple[Path, str]` — extracted from `run_make_goals`'s existing repo-root/mode resolution (refactor, behavior unchanged); `class UpdatesScreen(ModalScreen[None])` ctor `()` (reads everything from `self.app`).

Implementation notes:
- conftest autouse fixture: monkeypatch `app_mod._default_updates_cache_path` to return `tmp_path / "updates.json"` (module-attribute patch, same shape as `_no_real_notifier`).
- `action_updates` (provision): keep the `unavailable` guard, then `self.app.push_screen(UpdatesScreen())`.
- Screen: TextViewScreen-style 90% box. Title `check updates`. Banner Static `#updates-banner` (`markup=False`) + DataTable `#updates-table` (columns `st` w2, `tool` w20, `pinned` w14, `latest` w14, `detail`) + summary Static `#updates-summary` (`markup=False`). `UPDATE_ICONS` in theme: `update ("↑", yellow)`, `ok ("✓", green)`, `ahead ("!", yellow)`, `rolling ("·", overlay0)`, `unknown ("?", red)`. All cells `Text()`.
- on_mount: `self._cache = load_updates_cache(app.updates_cache_path)`; render (rows sorted by current sort key, default `"status"`); summary `f"{n_update} updates · {n_ok} ok · {n_rolling} rolling · {n_unchecked} unchecked · checked {age}"` where unchecked = ahead+unknown, age = `rel_age(now - checked_at)` or `never`; then `_start_check()`.
- `_start_check()`: if `app._task_inflight or app._runner.busy or app._push_inflight` → banner `task running — showing cached results`; else `root, mode = app._make_context()`; `buffer: list[str] = []`; `provision = app.query_one("#provision", ProvisionPanel)`; `tee = lambda line: (buffer.append(line), provision.append_log(line))`; `app.launch_task(check_updates_command(root, mode), log_to=tee, on_result=self._on_check_result)`; banner `checking…`.
- `_on_check_result(result)`: rc 0 and not cancelled → `rows = parse_updates("\n".join(buffer))`; `cache = UpdatesCache(checked_at=datetime.now(UTC).isoformat(), rows=rows)`; `save_updates_cache(path, cache)`; if `self.is_attached` → `self._cache = cache`, re-render, banner cleared. rc ≠ 0 → banner `last check failed (rc=N)` (cache untouched). Cancelled → banner `check cancelled`.
- Keys: `s` → cycle sort key `status → name → status`, re-render; `R` → `_start_check()`; `escape` → dismiss (a running check keeps running — launch_task owns it; `_on_check_result` still caches).
- Dashboard `update_summary`: append a 4th line to the provision card: `cache = load_updates_cache(app.updates_cache_path)`; `n = sum(r.status == "update" for r in cache.rows)`; line `[yellow]↑ N updates[/] · checked <age>` when checked (muted when n==0), else muted `updates: never checked`; plain text mirror appended to `prov_plain`. Import `rel_age` from `core.fleet`.
- HelpScreen: provision `u` line now says "updates table"; add the screen keys line (`s sort · R re-check · esc close`).

Tests (7): `u` opens UpdatesScreen (unavailable → toast, no screen); cache pre-seeded in tmp_path → rows render sorted status-first with glyphs + summary text; fresh check: FakeRunner scripted to emit porcelain lines rc 0 → cache file written + table re-rendered; rc ≠ 0 → banner + cache unchanged; `s` toggles to name order; entry gated while `_task_inflight` (banner, runner untouched); dashboard card shows `↑ 2 updates` from a seeded cache and `never checked` when absent.

Commit: `feat(tui): parsed check-updates table + cache + dashboard line`. Suite → REAL count (~281).

---

### Task 3: History core — entry model + store (spec §3 core)

**Files:** Create `tui/src/workstation_tui/core/history.py`; tests `tui/tests/test_history.py`.

**Interfaces produced:**
- `class HistoryEntry(BaseModel)`: `id: str`, `started_at: str` (ISO-8601 UTC), `kind: str` (`task|sequence|push|keydist`), `command: list[str] | None`, `summary: str`, `returncode: int | None`, `duration_secs: float`, `cancelled: bool = False`, `outcome: str` (`ok|failed|cancelled`), `needs_sudo: bool = False`.
- `outcome_for(returncode: int | None, cancelled: bool) -> str` (`cancelled` → `"cancelled"`; `returncode == 0` → `"ok"`; else `"failed"`).
- `new_entry_id(now: datetime) -> str` = `now.strftime("%Y%m%d-%H%M%S") + "-" + secrets.token_hex(2)`.
- `class HistoryStore`: ctor `(root: Path)`; `append(entry, log_lines: list[str]) -> bool` (mkdir root; append one JSON line to `root/"index.jsonl"`; write `root/f"{entry.id}.log"` joined by `\n`); `load(limit: int = 200) -> list[HistoryEntry]` (parse each line, skip corrupt, NEWEST FIRST = reversed file order, then `[:limit]`); `read_log(entry_id: str) -> str` (`""` when missing; refuse ids containing `/` or `..` → `""`); `prune(keep: int = 200) -> int` (keep the LAST `keep` index lines, rewrite index via tmp+`os.replace`, unlink dropped entries' `.log` files, return removed count); `record(entry, log_lines, keep: int = 200) -> bool` = `append` then `prune`. Every method never raises (broad try/except → falsy/empty return).

Binding contract = spec §3 core. Tests (7): append+load round-trip newest-first; load skips a corrupt line; read_log returns content / `""` missing / `""` for `../x`; prune keeps N newest + deletes the dropped logs + returns count; record = append+prune; unwritable root (chmod 0 dir, or a FILE where the dir should be) → append False, load [], no raise; outcome_for table; new_entry_id shape regex.

Commit: `feat(tui): history entry model + never-raise store`. Suite → REAL count (~288).

---

### Task 4: History recording hooks (spec §3 recording)

**Files:** Modify `tui/src/workstation_tui/app/app.py` (`history_store` ctor param, `_default_history_root()`, `record_history`, tee in `_task_flow` + `_sequence_flow`), `tui/src/workstation_tui/app/widgets/push_screen.py` (push entry on completion), `tui/src/workstation_tui/app/panels/fleet.py` (`_apply_copy_id_results` keydist entry), `tui/tests/conftest.py` (autouse fixture); tests `tui/tests/test_history_recording.py`.

**Interfaces:**
- Consumes Task 3.
- Produces: app attr `history_store: HistoryStore`; module fn `_default_history_root() -> Path` (`Path.home() / ".cache/workstation-tui/history"`); app method `record_history(entry: HistoryEntry, log_lines: list[str]) -> None` (fire-and-forget: `asyncio.create_task(asyncio.to_thread(self.history_store.record, entry, list(log_lines)))` wrapped so it never raises; when no running loop, call synchronously); app helper `_history_entry(kind, command, result: TaskResult, needs_sudo, started_at: datetime) -> HistoryEntry` (summary via `_command_summary`).

Implementation notes:
- conftest autouse fixture: monkeypatch `app_mod._default_history_root` → `tmp_path / "history"`.
- `_task_flow`: `started_at = datetime.now(UTC)` before `_runner.run`; wrap `log` as `captured: list[str]` tee (cap 5000, drop oldest) — the `$ cmd` echo line included; after `result` is known (including the cancelled branch): `self.record_history(self._history_entry("task", command, result, needs_sudo, started_at), captured)`. NOT recorded: sudo-gate refusal, TaskBusyError, spawn exception (no TaskResult exists).
- `_sequence_flow`: per command, same tee + entry with `kind="sequence"`, `needs_sudo=False`.
- PushScreen: at the completion point (where `_notify_completion` runs): `runs = self._runner.runs.values()`; `n_ok/n_failed/n_cancelled`; `outcome = "failed" if n_failed else ("cancelled" if n_cancelled == len(runs) else "ok")`; entry `kind="push"`, `command=None`, `summary=f"push — {n_ok} ok, {n_failed} failed"`, `returncode=None`, `duration` = the same max(finished)−min(started), `cancelled = outcome == "cancelled"`, `started_at` = wall clock captured at on_mount; log = for each run: `f"=== {name} ({state}, rc={rc}) ==="` + its lines. `self.app.record_history(entry, lines)`.
- Fleet `_apply_copy_id_results(results)`: entry `kind="keydist"`, `summary=f"key distribution — {n_ok} ok, {n_failed} failed"`, `returncode=None`, `duration_secs=0.0`, `outcome = "failed" if n_failed else "ok"`, log = the per-host `copy-id <name>: ok|failed (rc=N)` lines; `self.app.record_history(...)`.
- Only PushScreen/fleet need a guard for bare-App test harnesses that lack `record_history` (`getattr(self.app, "record_history", None)`), mirroring Task 3-B's harness pattern — check `test_push_screen.py`'s Host harness and extend it rather than guarding, if simpler.

Tests (6): launch_task rc 0 → one `task` entry in the tmp store with summary/rc/duration + log containing the streamed lines; cancelled task → outcome cancelled; sequence of two → two `sequence` entries in order; sudo-refused/busy → nothing recorded; push completion → one `push` entry with per-host log sections; keydist results → one `keydist` entry. (Await `app.workers.wait_for_complete()` / poll the store briefly since recording is to_thread.)

Commit: `feat(tui): record tasks, sequences, pushes and key distribution to history`. Suite → REAL count (~294).

---

### Task 5: HistoryScreen + `H` + re-run (spec §3 screen)

**Files:** Create `tui/src/workstation_tui/app/widgets/history_screen.py`; modify `tui/src/workstation_tui/app/app.py` (`H` binding, `action_history`, `rerun_history_entry`, GLOBAL_KEYS), `tui/src/workstation_tui/app/theme.py` (`OUTCOME_ICONS`), `tui/src/workstation_tui/app/widgets/help_screen.py`; tests `tui/tests/test_history_screen.py`.

**Interfaces:**
- Consumes Tasks 3–4.
- Produces: app method `rerun_history_entry(entry: HistoryEntry) -> bool` — `task`/`sequence` kinds with a command → `launch_task(entry.command, needs_sudo=entry.needs_sudo)` and True; else `notify("re-run from the Fleet panel", severity="warning")` and False. `class HistoryScreen(ModalScreen[None])` ctor `()`. `action_history()` on the app pushes it.

Implementation notes:
- App BINDINGS gains `Binding("H", "history", "History")` (capital H = shift+h; verify no panel binds it); GLOBAL_KEYS gains `("H", "History")`; HelpScreen global list.
- Screen: 90% box, title `task history`; DataTable `#history-table` columns `when` w6, `st` w2, `kind` w9, `summary` (rest), `rc` w4, `time` w6; rows keyed by `entry.id`, newest first; `OUTCOME_ICONS`: `ok ("✓", green)`, `failed ("✗", red)`, `cancelled ("–", yellow)`; `when` = `rel_age(now − started_at)`; `time` = `m:ss`. Empty store → single muted line `no history yet`. Load in a thread worker (group `history`, exclusive) on mount: `entries = store.load(200)` → `call_from_thread(self._render, entries)`. All cells `Text()`.
- Keys: `enter` (via `on_data_table_row_selected`, the dotfiles/health precedent — DataTable owns enter) → `text = await asyncio.to_thread(store.read_log, id)` → `push_screen(TextViewScreen(text, title=entry.summary))`; `r` → cursor entry → if re-runnable: ConfirmModal(`f"re-run {entry.summary}?"`) (worker, group `history-confirm`) → `app.rerun_history_entry(entry)` → dismiss on True; else the toast; `escape` → dismiss.
- The footer drift test: `H` is a real App binding — no carve-out.

Tests (6): `H` opens the screen; seeded store → rows newest-first with glyphs/rel-age; enter opens TextViewScreen with the log text; `r` on a task entry → confirm → `launch_task` receives the exact argv + needs_sudo (assert via FakeRunner.commands or the sudo_status_fn seam); `r` on a push entry → warning toast, runner untouched; empty store → `no history yet`.

Commit: `feat(tui): task history browser with log view + gated re-run`. Suite → REAL count (~300).

---

### Task 6: Command palette providers (spec §1)

**Files:** Create `tui/src/workstation_tui/app/palette.py`; modify `tui/src/workstation_tui/app/app.py` (`COMMANDS`, `get_system_commands`, palette CSS in APP_CSS, GLOBAL_KEYS), the four panels (`select_row` helper each), `tui/src/workstation_tui/app/widgets/help_screen.py`, `tui/tests/test_footer_keys.py` (ctrl+p handling — see below); tests `tui/tests/test_palette.py`.

**Interfaces:**
- Consumes: Tasks 2 and 5 (`UpdatesScreen`, `action_history`, `rerun_history_entry`, `history_store`).
- Produces: panels gain `select_row(key: str) -> bool` (DataTable `get_row_index(key)` → `move_cursor(row=idx)`; False when the key is absent / table not composed); `ActionsProvider`, `EntitiesProvider`, `HistoryProvider` in `app/palette.py`; `WorkstationApp.COMMANDS = App.COMMANDS | {ActionsProvider, EntitiesProvider, HistoryProvider}`.

Implementation notes (Textual 8.2.8 API, verified): `Provider.__init__(screen, match_style=None)`; `async def search(self, query) -> Hits` yields `Hit(score, match_display, command, text=None, help=None)`; `async def discover(self) -> Hits` yields `DiscoveryHit(display, command, text=None, help=None)`; `self.matcher(query)` → `Matcher` with `.match(candidate) -> float` (0 = no match) and `.highlight(candidate) -> Text`; `self.app` is the WorkstationApp. The app's palette binding is `COMMAND_PALETTE_BINDING = "ctrl+p"` (already active — `ENABLE_COMMAND_PALETTE` is True).
- `ActionsProvider._commands() -> list[tuple[str, str, Callable]]` (name, help, callback): `go to dashboard|provision|dotfiles|fleet|health` → `app.switch_panel(id)`; `refresh` → `app.action_refresh`; `toggle watch` → `app.action_toggle_watch`; `check updates` → `app.push_screen(UpdatesScreen())` (respecting the provision `unavailable` guard: call the panel's `action_updates`); `task history` → `app.action_history`; `help` → the existing help action; `quit` → `app.action_quit`; `provision all` → provision `action_full_provision`; `apply all pending` → dotfiles `action_apply_pending`; `push all hosts` → fleet `action_push_all`; `run all health checks` → health `action_run_all`; `distribute keys` → fleet `action_distribute_keys`. Panel-action callbacks FIRST `switch_panel(<owner>)` then call the action (gates/confirms inside the action apply unchanged). `search`: matcher over the name; `discover`: every command.
- `EntitiesProvider`: builds `(name, help, callback)` from panel lists: provision `tools` → `run <tool>` (`switch_panel("provision")`, `select_row(name)`, `action_run_tool`) and `clean <tool>` (`action_clean_tool`); fleet `hosts` → `push <name>` (`action_push_selected`), `ssh <name>` (`action_ssh_selected`), `stats <name>` (`push_screen(HostStatsScreen(entry))`); dotfiles `pending` → `apply <path>` (`select_row(path)` + `action_apply_selected`) and `diff <path>` (`switch_panel("dotfiles")` + `select_row(path)` ONLY — the panel's per-file diff pane follows the cursor row; there is no per-file diff action, and `d`/`action_full_diff` is the whole-tree diff, NOT equivalent); health `CHECKS` → `run check <label>` (`_run_check(check_id)`). `search` only (no `discover` — entities appear as typed). Names are user/file-derived: they enter ONLY via `matcher.highlight(name)` (a Text — never markup-parsed) and `help` stays a static string.
- `HistoryProvider`: `entries = await asyncio.to_thread(app.history_store.load, 20)`; re-runnable kinds only; name `re-run: <summary> (<rel_age>, rc <rc>)`; callback `app.rerun_history_entry(entry)`; `search` only.
- Every provider wraps its body in `try/except Exception: return` (yield nothing) — never raises into the palette.
- `get_system_commands(self, screen)` override yields ONLY `SystemCommand("Quit", "Quit the application", self.action_quit)`.
- CSS (APP_CSS): `CommandPalette > Vertical {{ background: {M['mantle']}; }}`, `CommandPalette #--input {{ border: hkey {M['surface1']}; }}`, `CommandPalette > .command-palette--highlight {{ color: {M['mauve']}; text-style: bold; }}`, `CommandPalette > .command-palette--help-text {{ color: {M['overlay0']}; }}` — implementer verifies each selector against `textual.command.CommandPalette.DEFAULT_CSS` and adjusts to whatever exists in 8.2.8.
- GLOBAL_KEYS gains `("ctrl+p", "Palette")` FIRST in the list; HelpScreen global list. Footer drift test: `ctrl+p` is Textual's `COMMAND_PALETTE_BINDING`, injected at App init rather than listed in `App.BINDINGS` — if the drift test validates GLOBAL_KEYS against the class-level BINDINGS, add `ctrl+p` to its exemption set with a comment naming `COMMAND_PALETTE_BINDING` (narrow carve-out, health-enter precedent); if it validates against the runtime `app._bindings`, no change.

Tests (8, all inside `app.run_test()` with injected providers/FakeRunner): `ctrl+p` opens the palette (`isinstance(app.screen, CommandPalette)`); `get_system_commands` yields exactly `["Quit"]`; ActionsProvider `search("fleet")` yields `go to fleet` and calling its command switches the panel; `discover` lists every action; EntitiesProvider `search("run fz")` yields `run fzf` whose command switches to provision, moves the cursor to fzf, and reaches the run seam (FakeRunner command or sudo gate); `search("push web")` yields `push web-01` → confirm modal appears on fleet; a hostile name (`[red]x[/red]`) in hits renders literally (`hit.match_display.plain`); HistoryProvider surfaces a seeded re-runnable entry and not a push entry; a provider whose panel query raises yields nothing (monkeypatch a panel attr to raise).

Commit: `feat(tui): command palette — actions, entities, history providers`. Suite → REAL count (~308).

---

### Task 7: Docs + gate

**Files:** `README.html`, `CLAUDE_CHANGELOG.md`.

- README §tui (read the shipped code first): palette paragraph (`ctrl+p`; what's searchable — navigation, panel actions, every tool/host/pending file/health check, recent re-runnable tasks; same gates/confirms as keys); updates-table paragraph (`u` opens the table; porcelain `CHECK_UPDATES_PORCELAIN=1`; cache at `~/.cache/workstation-tui/updates.json`; dashboard line; `s`/`R`/`esc`; read-only by design — pins are manual `versions.mk` edits); history paragraph (`H`; what's recorded incl. pushes/key distribution; `enter` log / `r` re-run through the sudo gate; 200-entry retention at `~/.cache/workstation-tui/history/`); key rows (`ctrl+p`, `H`, `u` description update, screen keys). Balance check: every opened tag closed.
- CLAUDE_CHANGELOG row following the existing table format: `| TUI Phase C: command palette (ctrl+p), parsed check-updates table + cache + dashboard line (u), task history browser with re-run (H) | Yes | §tui keys + behavior paragraphs |`
- Gate: `make -C makefile lint MODE=prod && make -C makefile tui-test MODE=prod && bash scripts/check-templates.sh`; live `workstation status`.
- Commit `docs: phase-C README + changelog`. (PR creation is the controller's job after the final whole-branch review.)
