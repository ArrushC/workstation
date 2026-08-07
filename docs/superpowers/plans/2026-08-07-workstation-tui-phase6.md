# Workstation TUI — Phase 6 (Health Panel + README §tui) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the last panel — Health (check rows with cached last results + age; run one/all; live services + WSL-interop state) — finish the spec's remaining shell polish (`?` help overlay), close out the two easiest cross-panel carry-forwards, and write the README §tui section that documents the finished TUI.

**Architecture:** `core/health.py` defines a declarative check registry (name, command builder or native probe, availability predicate) — Textual-free like every reader; results cache to `~/.cache/workstation-tui/health.json` (the spec's sanctioned cache dir; written atomically, never a mutation of repo state). `HealthPanel` renders the registry as a table (state glyph, name, age, summary), runs checks through the existing runner (`group="task"` — checks ARE tasks: one at a time), streams into its log pane, and re-reads services/interop live (cheap native probes, no subprocess for interop). A `HelpScreen` modal satisfies the spec's `[?]` binding. README gains §tui documenting all five panels + headless CLI + platform matrix, written against the AS-BUILT truth (header identity line, not the spec's footer wording — the recorded Phase-3 drift).

**Tech Stack:** Python ≥3.14, asyncio, Textual 8.x, pydantic v2, pytest + pytest-asyncio, uv.

**Spec:** `docs/superpowers/specs/2026-08-05-workstation-tui-design.md` §screens (Health), §Error handling (cache dir), plus the README/§docs touchpoints. **Recorded scope decisions:** (1) check runs reuse the runner serially — no parallel check execution in v1 (spec's one-mutation-at-a-time discipline extends to checks; `[R]` run-all is a `run_task_sequence`). (2) The services rows read `systemctl is-active` via a native reader, not the runner (read-only, instant). (3) `sudo -n` keepalive/gate does NOT apply — every health check runs unprivileged (doctor/check-updates/lint are MODE=prod-safe).

## Global Constraints

- Branch: `feat/workstation-tui-phase6` (created off main). Push after every commit. PR targets main.
- Nothing under `core/` imports `textual`. All readers never raise; all subprocess text renders `markup=False`/`Text()`-wrapped; dynamic notify text `markup=False`.
- Worker groups: checks through `group="task"` (runner discipline); panel refresh reads in `group="health-refresh"` (thread, exclusive); no new groups beyond these.
- Cache: `~/.cache/workstation-tui/health.json` — atomic write (tmp + rename), corrupt/missing cache → empty results, never an error. Timestamps via `time.time()` at write; ages rendered from wall clock at display.
- The Health panel is the LAST placeholder swap: the placeholder test in test_app_shell.py is DELETED this time (no placeholders remain), with a comment-worthy explanation in the commit body — pre-authorized.
- Availability gating per check (not per panel): each check row carries a predicate over `HostContext` (e.g. services need `has_systemctl and not is_wsl and mode == "dev"`; template render needs repo checkout; doctor needs `has_make`); unavailable rows render dimmed with the reason — the panel itself always shows.
- Tests: `cd tui && uv run pytest -q`; suite enters at 154 passed; env-independent (inject everything; cache tests use tmp_path).
- README §tui documents AS-BUILT behavior; every claim must be true of the merged code (verify against the running app where read-only). README.css/js untouched unless the nav needs the new section link (check how other sections register — likely `README.js` scroll-spy is selector-driven, verify).
- Pre-commit invariant hook stays green; never `--no-verify`. Conventional-commit subjects as given.

---

### Task 1: Health core — check registry, cache, service/interop readers

**Files:**
- Modify: `tui/src/workstation_tui/core/models.py` (append)
- Create: `tui/src/workstation_tui/core/health.py`
- Test: `tui/tests/test_health_core.py`

**Interfaces:**
- `CheckResult(BaseModel)`: `check_id: str`, `ok: bool`, `summary: str`, `finished_at: float` (epoch), `returncode: int`.
- `HealthCheck(BaseModel)`: `check_id: str`, `label: str`, `kind: Literal["make", "script"]`, `goals: list[str]` (make goals or script argv relative to repo root).
- `health.CHECKS: list[HealthCheck]` — exactly: `doctor` (make doctor), `check-updates` (make check-updates), `invariants` (script `scripts/check-invariants.sh`), `templates` (script `scripts/check-templates.sh`).
- `health.check_available(check: HealthCheck, ctx: HostContext) -> str | None` — None = available; else reason string. Rules: `make`-kind needs `ctx.has_make`; script-kind always available on linux, unavailable on windows (`"bash scripts are Linux-side"`).
- `health.check_command(repo_root: Path, check: HealthCheck, mode: str) -> list[str]` — make-kind → `make_command(repo_root, check.goals, mode)`; script-kind → `["bash", str(repo_root / check.goals[0]), *check.goals[1:]]`.
- `health.load_cache(path: Path) -> dict[str, CheckResult]` / `health.save_cache(path: Path, results: dict[str, CheckResult]) -> None` — JSON round-trip; load returns `{}` on missing/corrupt; save writes atomically (`path.with_suffix(".tmp")` + `os.replace`), creating parents.
- `health.read_services(*, run=subprocess.run) -> dict[str, str]` — for `docker`, `dozzle`, `cockpit`, `rsyslog`: `systemctl is-active <unit>` (units: `docker`, `dozzle`, `cockpit.socket`, `rsyslog`) → "active"/"inactive"/"unknown" (rc 0 → active; rc != 0 → inactive; exception → unknown). Never raises.
- `health.read_wsl_interop() -> str` — reads `/proc/sys/fs/binfmt_misc/WSLInterop`: first line `enabled` → `"enabled"`; readable-but-other → `"disabled"`; unreadable/absent → `"absent"`. Never raises.

- [ ] **Step 1: Write the failing tests**

`tui/tests/test_health_core.py`:

```python
import subprocess
import time
from pathlib import Path

from workstation_tui.core.health import (
    CHECKS,
    check_available,
    check_command,
    load_cache,
    read_services,
    read_wsl_interop,
    save_cache,
)
from workstation_tui.core.models import CheckResult, HostContext

CTX = HostContext(
    os="linux", is_wsl=True, group="dev_machine", mode="dev",
    has_make=True, has_chezmoi=True, has_systemctl=True, has_sudo=True,
)


def test_registry_has_the_four_checks() -> None:
    assert [c.check_id for c in CHECKS] == [
        "doctor", "check-updates", "invariants", "templates",
    ]


def test_availability_rules(tmp_path: Path) -> None:
    no_make = CTX.model_copy(update={"has_make": False})
    windows = CTX.model_copy(update={"os": "windows", "has_make": False})
    doctor = CHECKS[0]
    invariants = CHECKS[2]
    assert check_available(doctor, CTX) is None
    assert check_available(doctor, no_make) is not None
    assert check_available(invariants, CTX) is None
    assert check_available(invariants, windows) is not None


def test_check_commands(tmp_path: Path) -> None:
    doctor_cmd = check_command(tmp_path, CHECKS[0], "prod")
    assert doctor_cmd[-2:] == ["doctor", "MODE=prod"]
    inv_cmd = check_command(tmp_path, CHECKS[2], "prod")
    assert inv_cmd[0] == "bash"
    assert inv_cmd[1].endswith("scripts/check-invariants.sh")


def test_cache_round_trip_and_corruption(tmp_path: Path) -> None:
    cache = tmp_path / "sub" / "health.json"
    results = {
        "doctor": CheckResult(check_id="doctor", ok=True, summary="31/31 ok",
                              finished_at=time.time(), returncode=0),
    }
    save_cache(cache, results)
    loaded = load_cache(cache)
    assert loaded["doctor"].ok is True
    assert load_cache(tmp_path / "missing.json") == {}
    cache.write_text("{corrupt")
    assert load_cache(cache) == {}


def test_read_services_mapping() -> None:
    def fake_run(cmd, **kwargs):
        rc = 0 if "docker" in cmd else 3
        return subprocess.CompletedProcess(cmd, rc, stdout="", stderr="")

    states = read_services(run=fake_run)
    assert states["docker"] == "active"
    assert states["dozzle"] == "inactive"

    def raising_run(cmd, **kwargs):
        raise FileNotFoundError("systemctl")

    assert set(read_services(run=raising_run).values()) == {"unknown"}


def test_read_wsl_interop_states(tmp_path: Path, monkeypatch) -> None:
    import workstation_tui.core.health as health_mod

    p = tmp_path / "WSLInterop"
    monkeypatch.setattr(health_mod, "_INTEROP_PATH", p)
    assert read_wsl_interop() == "absent"
    p.write_text("enabled\n")
    assert read_wsl_interop() == "enabled"
    p.write_text("disabled\n")
    assert read_wsl_interop() == "disabled"
```

- [ ] **Step 2: Run to verify failure** — module missing.

- [ ] **Step 3: Implement** — `models.py` appends `CheckResult` + `HealthCheck` (HealthCheck may live in health.py if models.py would need a Literal import churn — implementer's choice, document it; tests import CheckResult from models and CHECKS from health). `health.py` per the Interfaces block; `_INTEROP_PATH = Path("/proc/sys/fs/binfmt_misc/WSLInterop")` module constant (monkeypatchable); service units mapping `{"docker": "docker", "dozzle": "dozzle", "cockpit": "cockpit.socket", "rsyslog": "rsyslog"}`; docstring notes checks run unprivileged (MODE=prod-safe) and the cache is the only file the TUI writes.

- [ ] **Step 4: Run to verify pass** — full suite `160 passed` (154 + 6). **Step 5: Commit** `feat(tui): health core — check registry, cache, service/interop readers`, push.

---

### Task 2: Health panel

**Files:**
- Create: `tui/src/workstation_tui/app/panels/health.py`
- Modify: `tui/src/workstation_tui/app/app.py` (swap last placeholder; wire providers + cache path)
- Modify: `tui/tests/test_app_shell.py` (DELETE the placeholder test — pre-authorized; no placeholders remain)
- Test: `tui/tests/test_health_panel.py`

**Interfaces:**
- `HealthPanel(Static)` id `#health`: DataTable `#health-table` (state glyph via `bool_marker`-style mapping — ✓ green ok / ✗ red failed / — dim never-ran/unavailable, label, age (`"2h ago"`/`"never"`), summary — ALL cells Text-wrapped), services line `#health-services` (markup=True with themed glyphs, service names are static so safe), interop line `#health-interop`, RichLog `#health-log` (markup=False, max_lines=5000) + `log_lines` mirror, key bar.
- Bindings: `enter` run selected check, `R` run all (sequence), `o` open last log in TextViewScreen.
- App ctor grows: `health_cache_path: Path | None = None` (None → `Path.home() / ".cache/workstation-tui/health.json"`), `services_reader=read_services`, `interop_reader=read_wsl_interop` (injectable).
- Run-one flow: availability check → refuse with notify if unavailable → `launch_task(check_command(...), log_to=panel.append_log, on_done=...)`; result recording happens via a completion callback capturing rc: extend `launch_task` minimally? NO — instead the panel wraps `log_to` and `on_done`; rc capture: `run_task_sequence`/`launch_task` don't expose rc to on_done. DESIGN: add an optional `on_result: Callable[[TaskResult], None] | None = None` parameter to `launch_task`/`_task_flow` (called with the TaskResult before on_done; same pattern as on_done — minimal, backward-compatible). Panel's `on_result` writes the CheckResult (ok = rc==0, summary = last non-empty log line truncated to 80 chars, finished_at = now) into the cache via save_cache and re-renders.
- `[R]` run-all: filters available checks, `run_task_sequence([...])` with a combined on_done that re-runs a full refresh; per-check results NOT individually recorded in v1 run-all (sequence has no per-command rc hook) — instead run-all records only into the log, and rows refresh from individual runs; DOCUMENT this limitation in the panel docstring and the README (recorded scope decision).
- `refresh_panel()`: thread worker (`group="health-refresh"`, exclusive) reading cache + services + interop, applied via call_from_thread; availability from `app.summary.context` (fallback: all rows shown, dimmed reasons blank until summary lands).
- Services/interop rows only render live states when the context allows (services: has_systemctl and not is_wsl and mode=="dev", else the line shows the reason muted; interop: only when is_wsl).

- [ ] **Step 1: Write the failing tests**

`tui/tests/test_health_panel.py`:

```python
import time
from pathlib import Path

from workstation_tui.app.app import WorkstationApp
from workstation_tui.core.models import CheckResult
from tests.test_app_shell import FAKE_SUMMARY, fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider


def make_app(tmp_path: Path, runner=None, services=None, interop="enabled"):
    return WorkstationApp(
        summary_provider=fake_provider, runner=runner or FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        health_cache_path=tmp_path / "health.json",
        services_reader=lambda: (services or {"docker": "active", "dozzle": "inactive",
                                             "cockpit": "unknown", "rsyslog": "active"}),
        interop_reader=lambda: interop,
    )


async def test_table_lists_four_checks_with_never_age(tmp_path: Path) -> None:
    app = make_app(tmp_path)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        for _ in range(3):
            await pilot.pause()
        table = app.query_one("#health-table")
        assert table.row_count == 4
        panel = app.query_one("#health")
        assert "never" in panel.rendered_text()


async def test_cached_result_shows_age_and_state(tmp_path: Path) -> None:
    from workstation_tui.core.health import save_cache
    save_cache(tmp_path / "health.json", {
        "doctor": CheckResult(check_id="doctor", ok=True, summary="31/31 ok",
                              finished_at=time.time() - 7200, returncode=0),
    })
    app = make_app(tmp_path)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        for _ in range(3):
            await pilot.pause()
        text = app.query_one("#health").rendered_text()
        assert "31/31 ok" in text
        assert "2h ago" in text


async def test_run_selected_check_records_result(tmp_path: Path) -> None:
    runner = FakeRunner()
    app = make_app(tmp_path, runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        for _ in range(3):
            await pilot.pause()
        app.query_one("#health-table").focus()
        await pilot.press("enter")
        for _ in range(5):
            await pilot.pause()
    assert runner.commands, "check never ran"
    from workstation_tui.core.health import load_cache
    cached = load_cache(tmp_path / "health.json")
    assert "doctor" in cached
    assert cached["doctor"].ok is True


async def test_services_and_interop_lines(tmp_path: Path) -> None:
    app = make_app(tmp_path, interop="disabled")
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        for _ in range(3):
            await pilot.pause()
        text = app.query_one("#health").rendered_text()
        # FAKE_SUMMARY is WSL dev → services line shows the reason, interop shows state
        assert "disabled" in text


async def test_run_all_streams_sequence(tmp_path: Path) -> None:
    runner = FakeRunner()
    app = make_app(tmp_path, runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        for _ in range(3):
            await pilot.pause()
        app.query_one("#health-table").focus()
        await pilot.press("R")
        for _ in range(8):
            await pilot.pause()
    assert len(runner.commands) == 4  # all four checks (linux dev ctx, all available)
```

NOTE: `rendered_text()` is a plain-text aggregation helper on the panel (cells + services/interop lines + log), same rationale as prior panels' helpers. FAKE_SUMMARY is is_wsl=True → the services line must show the muted reason (WSL) rather than live states; the test only asserts interop text.

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement** — panel per Interfaces; `launch_task`/`_task_flow` gain the optional `on_result` param (backward-compatible — all existing call sites unchanged; document in app.py docstring); age formatting helper `_age(epoch: float) -> str` ("never" handled by caller; <60s "just now", <1h "Nm ago", <24h "Nh ago", else "Nd ago"); placeholder import removed from app.py when the last PlaceholderPanel goes; DELETE `test_placeholder_panels_name_their_phase` from test_app_shell.py (commit body explains: last placeholder gone).

- [ ] **Step 4: Run to verify pass** — full suite `165 passed` (160 + 5, and the deleted placeholder test −1 → verify exact count at runtime; adjust the arithmetic in your report, the REAL number is what pytest prints). **Step 5: Commit** `feat(tui): health panel — check rows, cache ages, services + interop lines`, push.

---

### Task 3: Help overlay + cross-panel polish carry-forwards

**Files:**
- Create: `tui/src/workstation_tui/app/widgets/help_screen.py`
- Modify: `tui/src/workstation_tui/app/app.py` (add `?` binding)
- Modify: `tui/src/workstation_tui/app/panels/dotfiles.py` (repeated-log guard carry-forward)
- Test: `tui/tests/test_help_and_polish.py`

**Interfaces:**
- `HelpScreen(ModalScreen[None])` — static keymap reference built from theme `kb()`/`action_line()` helpers: global keys (1-5/g/q/?), then per-panel key lists (provision r/c/u/R/x, dotfiles a/U/A/d, fleet s/p/P/a/e/x, health enter/R/o). Escape/q/? dismisses. Content is STATIC text — markup=True with theme markup is safe here.
- `?` binding on WorkstationApp → `push_screen(HelpScreen())` (plain push, no wait — nothing returns).
- Dotfiles carry-forward: `_apply_refresh`'s "in sync"/warning lines get the once-per-change guard (mirror the unavailable-message pattern): track last-logged state; only log on CHANGE.

- [ ] **Step 1: Write the failing tests**

`tui/tests/test_help_and_polish.py`:

```python
from pathlib import Path

from workstation_tui.app.app import WorkstationApp
from workstation_tui.core.models import GitState, PendingChange
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider


async def test_question_mark_opens_help_and_escape_closes() -> None:
    app = WorkstationApp(
        summary_provider=fake_provider, runner=FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("?")
        await pilot.pause()
        assert type(app.screen).__name__ == "HelpScreen"
        await pilot.press("escape")
        await pilot.pause()
        assert type(app.screen).__name__ != "HelpScreen"


async def test_dotfiles_in_sync_logged_once_across_refreshes() -> None:
    app = WorkstationApp(
        summary_provider=fake_provider, runner=FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        pending_provider=lambda: ([], []),
        git_state_provider=lambda root: (
            GitState(branch="main", dirty=False, ahead=0, behind=0), []),
        target_diff_fn=lambda path: ("", None),
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        panel = app.query_one("#dotfiles")
        baseline = sum("in sync" in l for l in panel.log_lines)
        assert baseline == 1
        await pilot.press("g")          # summary refresh triggers panel refresh
        for _ in range(4):
            await pilot.pause()
        assert sum("in sync" in l for l in panel.log_lines) == 1
```

- [ ] **Step 2: Verify failure. Step 3: Implement. Step 4: verify pass** — full suite ~`167 passed` (real count from pytest). **Step 5: Commit** `feat(tui): help overlay + dotfiles log dedup`, push.

---

### Task 4: README §tui + docs sweep

**Files:**
- Modify: `README.html` (new §tui section + nav registration if needed)
- Modify: `docs/README/README.js` ONLY if section nav requires registration (verify first — scroll-spy may be selector-driven)
- Modify: `CLAUDE.md` (TUI mention in the docs table + §daily pointer)
- Modify: `CLAUDE_CHANGELOG.md` (final row)
- Modify: `docs/superpowers/specs/2026-08-05-workstation-tui-design.md` (as-built annotations)

**Interfaces:** none (docs only).

- [ ] **Step 1: Recon the README structure** — `rg -n '<section id=' README.html`; read one full section (e.g. §hosts) to copy its exact markup idioms (heading levels, card/table classes, code blocks, data-tips). Check `docs/README/README.js` for how the sidebar nav/scroll-spy discovers sections (hardcoded list vs querySelectorAll) — touch it only if hardcoded.

- [ ] **Step 2: Write §tui** (placed after §daily, before §adding — daily-workflow adjacency). Content, all AS-BUILT:
- What it is: `workstation` — TUI + headless CLI in the blessed python-env; editable install (updates ride `chezmoi update`); launchers per platform.
- Launch: bare `workstation` (TTY-gated, stdin+stdout), headless subcommands list with one-line descriptions and the `--json` pair.
- The five panels: one short block each (Dashboard cards/Enter-jump; Provision table/filter/log + r/c/u/R/x + sudo overlay behavior incl. cached-timestamp short-circuit; Dotfiles diff→confirm→--force + a/U/A/d; Fleet probes/ssh/push/add-edit-remove + collision guard + non-interactive manage-hosts remove; Health check rows/ages/R limitation (run-all doesn't record per-row results — rows update on individual runs) + services/interop lines).
- Keys: global (1-5/g/q/?) + per-panel table.
- Platform matrix: dev/prod/Windows/WSL rows matching the shipped gating (provision hidden-degraded on no-make; push/ssh linux-only; services dev+non-WSL; sudo overlay dev-Linux).
- Troubleshooting: 2-3 entries (TUI won't launch → TTY gating + env repair `make python-env-rebuild`; sudo overlay loops → timestamp_timeout=0 named-command fallback; stale tool table → g refresh + stamp dir note).

- [ ] **Step 3: CLAUDE.md** — docs table row for §tui ("TUI + headless CLI" → `README.html` §tui); one sentence in the python-env invariant bullet noting the TUI is COMPLETE (five panels) and README §tui is the user-facing doc.

- [ ] **Step 4: CLAUDE_CHANGELOG.md** — final row: `| workstation TUI Phase 6: Health panel (check rows/cache ages/services+interop), help overlay, README §tui (full TUI + CLI + platform matrix documented) | Yes | new §tui section after §daily; troubleshooting entries for TTY gate, sudo fallback, stale table |`

- [ ] **Step 5: Spec as-built annotations** — append a short `## As-built deltas (2026-08-07)` section to the spec listing the recorded deviations: header (not footer) identity line without hostname/EL-family; timestamp_timeout=0 message instead of app-suspend; edit=remove+add; run-all no per-row recording; Windows UAC deferred (no elevated Windows action exists); `?` help landed in phase 6.

- [ ] **Step 6: Verify** — README renders (open in browser if possible; at minimum an HTML-balance check via python html.parser like prior reviews); `rg -n 'tui' docs/README/README.js` confirms nav; full gate:

```bash
make -C makefile lint MODE=prod
make -C makefile tui-test MODE=prod
bash scripts/check-templates.sh
```

- [ ] **Step 7: Commit** `docs: README §tui + phase-6 changelog + spec as-built deltas`, push.

---

### Task 5: Gate + PR

- [ ] **Step 1: Full suite + live smokes**

```bash
make -C makefile lint MODE=prod && make -C makefile tui-test MODE=prod && bash scripts/check-templates.sh
~/.local/bin/workstation status && ~/.local/bin/workstation hosts list >/dev/null && echo CLI-OK
```

- [ ] **Step 2: PR** — `gh pr create --base main` titled `feat(tui): workstation TUI Phase 6 — health panel + README §tui (final phase)`; body summarizing panel, help overlay, docs; `gh pr checks --watch`. Hand to the user: the interactive smoke for this phase is the Health panel (`5`, run doctor via Enter, `R` run-all, `?` help overlay) in a real terminal.
