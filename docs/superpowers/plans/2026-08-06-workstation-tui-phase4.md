# Workstation TUI — Phase 4 (Runner + Sudo Overlay + Provision Panel) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the async execution engine (streaming, one-mutation-at-a-time, cancel), the in-TUI sudo overlay (validate → cached-timestamp → keepalive, with the timestamp_timeout=0 suspend fallback), and a live Provision panel (tool table + filter + log pane + run/clean/updates/full-provision actions).

**Architecture:** `core/runner.py` (asyncio subprocess engine — no Textual) + `core/sudo.py` (status/validate helpers — no Textual) stay pure; `app/widgets/sudo_modal.py` is a ModalScreen with an injectable validator; `app/panels/provision.py` replaces the placeholder with a DataTable + filter + RichLog; `WorkstationApp` owns the runner, the sudo gate, and the keepalive. Every collaborator is injectable so Pilot tests never touch real make/sudo. Windows/prod degrade via `HostContext` (no make → placeholder text; prod/user-kind targets → no sudo gate).

**Tech Stack:** Python ≥3.14, asyncio, Textual 8.x, click, pydantic v2, pytest + pytest-asyncio, uv.

**Spec:** `docs/superpowers/specs/2026-08-05-workstation-tui-design.md` §Execution engine, §screens (Provision). Phase 4 implements the LINUX sudo overlay; Windows UAC is deferred until a Windows-visible elevated action exists (the Provision panel is hidden on Windows per the gating table). **Recorded deviation:** for the `timestamp_timeout=0` sudoers edge the spec says "offer app-suspend and run in the raw terminal"; this phase ships an error message naming the exact command instead — the full suspend-and-run flow is deferred (carry-forward memory) until a real host exhibits that sudoers config.

## Global Constraints

- Branch: `feat/workstation-tui-phase4` (created off main). Push after every commit. PR targets main.
- Nothing under `core/` may import `textual`. `runner.py`/`sudo.py` are core.
- ONE mutation at a time: a busy runner REFUSES a second task (`TaskBusyError`) — never queues (spec).
- Cancel = SIGINT to the process group, SIGKILL after a 5s grace (spec).
- The password exists only transiently: never logged, never stored on the app/model, passed straight from the Input to `sudo -S -v` stdin.
- Sudo gate applies only when `context.mode == "dev"` AND the target kind is not `"user"` (prod's `SUDO` is empty; user-tools never sudo). `sudo -n -v` short-circuits the prompt when the timestamp is already valid.
- All subprocess env scrubbed of MAKEFLAGS/MFLAGS/MAKELEVEL (established precedent).
- Rendering precedent (Phase 3 final review): subprocess-derived text renders `markup=False`; exception-derived text gets `escape()`.
- Worker discipline (Phase 3 carry-forward): thread/async workers check cancellation before applying results; UI mutation only via the UI thread.
- Tests: `cd tui && uv run pytest -q`. Suite enters at 81 passed. Pilot tests never run real make/sudo — fakes only. Runner unit tests use real subprocesses (`sys.executable -c …`, `bash -c …`) which are safe and fast.
- Pre-commit invariant hook stays green; never `--no-verify`. Conventional-commit subjects as given.

---

### Task 1: TaskResult model + sudo helpers (`core/sudo.py`)

**Files:**
- Modify: `tui/src/workstation_tui/core/models.py` (append)
- Create: `tui/src/workstation_tui/core/sudo.py`
- Test: `tui/tests/test_sudo.py`, `tui/tests/test_models.py` (append)

**Interfaces:**
- Produces: `TaskResult(BaseModel)`: `command: list[str]`, `returncode: int`, `duration_secs: float`, `cancelled: bool = False`.
- `sudo.sudo_status(*, run=subprocess.run) -> Literal["valid", "needs_password", "no_sudo"]` — `sudo -n -v`: rc 0 → valid; rc != 0 → needs_password; FileNotFoundError/OSError → no_sudo.
- `sudo.sudo_validate(password: str, *, run=subprocess.run) -> bool` — `sudo -S -v` with `input=password + "\n"`, 15s timeout; rc 0 → True; any failure/exception → False. Never raises; never logs the password.

- [ ] **Step 1: Write the failing tests**

Append to `tui/tests/test_models.py`:

```python
def test_task_result_defaults() -> None:
    from workstation_tui.core.models import TaskResult

    r = TaskResult(command=["make", "fzf"], returncode=0, duration_secs=1.5)
    assert r.cancelled is False
```

`tui/tests/test_sudo.py`:

```python
import subprocess

from workstation_tui.core.sudo import sudo_status, sudo_validate


def _fake_run(rc: int):
    def run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, rc, stdout="", stderr="")
    return run


def test_sudo_status_valid() -> None:
    assert sudo_status(run=_fake_run(0)) == "valid"


def test_sudo_status_needs_password() -> None:
    assert sudo_status(run=_fake_run(1)) == "needs_password"


def test_sudo_status_no_sudo() -> None:
    def run(cmd, **kwargs):
        raise FileNotFoundError("sudo")
    assert sudo_status(run=run) == "no_sudo"


def test_sudo_validate_success_and_password_reaches_stdin() -> None:
    seen = {}

    def run(cmd, **kwargs):
        seen["cmd"] = cmd
        seen["input"] = kwargs.get("input")
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    assert sudo_validate("s3cret", run=run) is True
    assert seen["cmd"] == ["sudo", "-S", "-v"]
    assert seen["input"] == "s3cret\n"


def test_sudo_validate_wrong_password() -> None:
    assert sudo_validate("nope", run=_fake_run(1)) is False


def test_sudo_validate_never_raises() -> None:
    def run(cmd, **kwargs):
        raise subprocess.TimeoutExpired(cmd, 15)
    assert sudo_validate("x", run=run) is False
```

- [ ] **Step 2: Run to verify failure** — module missing.

- [ ] **Step 3: Implement**

Append to `models.py`:

```python
class TaskResult(BaseModel):
    """Outcome of one runner task."""

    command: list[str]
    returncode: int
    duration_secs: float
    cancelled: bool = False
```

`tui/src/workstation_tui/core/sudo.py`:

```python
"""sudo timestamp helpers for the TUI's privileged-command gate.

The overlay flow (spec §Execution engine): `sudo -n -v` short-circuits when
the timestamp is already valid; otherwise the app collects a password and
validates it via `sudo -S -v` — the real command then runs unmodified and
make's internal $(SUDO) calls hit the cached timestamp. The password is
passed straight to stdin and never stored or logged.
"""

import subprocess
from typing import Literal


def sudo_status(*, run=subprocess.run) -> Literal["valid", "needs_password", "no_sudo"]:
    try:
        proc = run(["sudo", "-n", "-v"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return "no_sudo"
    return "valid" if proc.returncode == 0 else "needs_password"


def sudo_validate(password: str, *, run=subprocess.run) -> bool:
    try:
        proc = run(
            ["sudo", "-S", "-v"],
            input=password + "\n",
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return proc.returncode == 0
```

- [ ] **Step 4: Run to verify pass** — full suite `88 passed` (81 + 7).

- [ ] **Step 5: Commit**

```bash
git add tui/src/workstation_tui/core/models.py tui/src/workstation_tui/core/sudo.py tui/tests/test_sudo.py tui/tests/test_models.py
git commit -m "feat(tui): TaskResult model + sudo status/validate helpers"
git push -u origin feat/workstation-tui-phase4
```

---

### Task 2: Async runner engine (`core/runner.py`)

**Files:**
- Create: `tui/src/workstation_tui/core/runner.py`
- Test: `tui/tests/test_runner.py`

**Interfaces:**
- Produces:
  - `class TaskBusyError(RuntimeError)` — message `"task running"`.
  - `class Runner:` with `busy: bool` property; `async def run(self, command: list[str], on_line: Callable[[str], None]) -> TaskResult` — refuses with `TaskBusyError` when busy; spawns via `asyncio.create_subprocess_exec` with `stdout=PIPE, stderr=STDOUT, start_new_session=True`, env scrubbed of MAKEFLAGS/MFLAGS/MAKELEVEL; streams decoded lines (rstrip newline) to `on_line`; returns `TaskResult` with wall duration; missing binary → `TaskResult(returncode=127)` with a `command not found` line to `on_line` (never raises).
  - `def cancel(self) -> None` — no-op when idle; SIGINT to the process group, then SIGKILL after `self.kill_grace` (default 5.0, overridable for tests) if still alive; the in-flight `run` returns `TaskResult(..., cancelled=True)`.
  - `loop_time` injectable not required — use `time.monotonic`.

- [ ] **Step 1: Write the failing tests**

`tui/tests/test_runner.py`:

```python
import asyncio
import sys

import pytest

from workstation_tui.core.runner import Runner, TaskBusyError


async def test_run_streams_lines_and_rc() -> None:
    r = Runner()
    lines: list[str] = []
    result = await r.run(
        ["bash", "-c", "echo one; echo two >&2; exit 3"], lines.append
    )
    assert result.returncode == 3
    assert result.cancelled is False
    assert result.duration_secs >= 0
    assert "one" in lines and "two" in lines  # stderr merged
    assert r.busy is False


async def test_busy_refusal() -> None:
    r = Runner()
    started = asyncio.Event()

    async def long_task():
        return await r.run(
            [sys.executable, "-c", "import time; print('go', flush=True); time.sleep(5)"],
            lambda line: started.set(),
        )

    task = asyncio.create_task(long_task())
    await asyncio.wait_for(started.wait(), timeout=5)
    with pytest.raises(TaskBusyError):
        await r.run(["bash", "-c", "true"], lambda _: None)
    r.cancel()
    result = await task
    assert result.cancelled is True


async def test_cancel_kills_process_group() -> None:
    r = Runner()
    r.kill_grace = 0.5
    started = asyncio.Event()

    async def long_task():
        return await r.run(
            ["bash", "-c",
             "trap '' INT; echo up; sleep 30"],  # ignores SIGINT → forces SIGKILL path
            lambda line: started.set(),
        )

    task = asyncio.create_task(long_task())
    await asyncio.wait_for(started.wait(), timeout=5)
    r.cancel()
    result = await asyncio.wait_for(task, timeout=10)
    assert result.cancelled is True
    assert r.busy is False


async def test_missing_binary_is_127_not_raise() -> None:
    r = Runner()
    lines: list[str] = []
    result = await r.run(["definitely-not-a-binary-xyz"], lines.append)
    assert result.returncode == 127
    assert any("command not found" in line for line in lines)


async def test_env_scrubbed(monkeypatch) -> None:
    monkeypatch.setenv("MAKEFLAGS", "w -j8 --jobserver-auth=3,4")
    r = Runner()
    lines: list[str] = []
    await r.run(
        [sys.executable, "-c",
         "import os; print('MAKEFLAGS' in os.environ)"],
        lines.append,
    )
    assert "False" in lines
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement `core/runner.py`**

```python
"""Async subprocess engine: streaming, one task at a time, cancellable.

Spec §Execution engine: a busy runner REFUSES (never queues) a second
mutation; cancel sends SIGINT to the whole process group and escalates to
SIGKILL after a grace period; stdout/stderr are merged and streamed
line-by-line to the caller's on_line callback. Env is scrubbed of make's
jobserver variables (established precedent in proc.py/read_inventory).
"""

import asyncio
import os
import signal
import time
from typing import Callable

from workstation_tui.core.models import TaskResult

_SCRUB = ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")


class TaskBusyError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("task running")


class Runner:
    def __init__(self) -> None:
        self._proc: asyncio.subprocess.Process | None = None
        self._cancelled = False
        self.kill_grace = 5.0

    @property
    def busy(self) -> bool:
        return self._proc is not None

    async def run(self, command: list[str], on_line: Callable[[str], None]) -> TaskResult:
        if self.busy:
            raise TaskBusyError()
        env = {k: v for k, v in os.environ.items() if k not in _SCRUB}
        start = time.monotonic()
        self._cancelled = False
        try:
            proc = await asyncio.create_subprocess_exec(
                *command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                start_new_session=True,
                env=env,
            )
        except FileNotFoundError:
            on_line(f"workstation: command not found: {command[0]}")
            return TaskResult(command=command, returncode=127,
                              duration_secs=time.monotonic() - start)
        except OSError as exc:
            on_line(f"workstation: cannot execute {command[0]}: {exc}")
            return TaskResult(command=command, returncode=126,
                              duration_secs=time.monotonic() - start)
        self._proc = proc
        try:
            assert proc.stdout is not None
            while True:
                raw = await proc.stdout.readline()
                if not raw:
                    break
                on_line(raw.decode(errors="replace").rstrip("\n"))
            returncode = await proc.wait()
        finally:
            self._proc = None
        return TaskResult(
            command=command,
            returncode=returncode,
            duration_secs=time.monotonic() - start,
            cancelled=self._cancelled,
        )

    def cancel(self) -> None:
        proc = self._proc
        if proc is None or proc.returncode is not None:
            return
        self._cancelled = True
        try:
            os.killpg(proc.pid, signal.SIGINT)
        except (ProcessLookupError, PermissionError):
            return
        asyncio.get_running_loop().call_later(self.kill_grace, self._force_kill, proc)

    def _force_kill(self, proc: asyncio.subprocess.Process) -> None:
        if proc.returncode is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
```

- [ ] **Step 4: Run to verify pass** — `cd tui && uv run pytest tests/test_runner.py -q` → `5 passed`; full suite → `93 passed`.

- [ ] **Step 5: Commit**

```bash
git add tui/src/workstation_tui/core/runner.py tui/tests/test_runner.py
git commit -m "feat(tui): async runner engine — streaming, busy refusal, group cancel"
git push
```

---

### Task 3: Sudo modal widget

**Files:**
- Create: `tui/src/workstation_tui/app/widgets/__init__.py`
- Create: `tui/src/workstation_tui/app/widgets/sudo_modal.py`
- Test: `tui/tests/test_sudo_modal.py`

**Interfaces:**
- Produces: `SudoModal(ModalScreen[bool])` — constructor `SudoModal(*, validator: Callable[[str], bool])`. Password `Input(password=True)`; Enter submits: validator(password) → True dismisses with `True`; False shows inline red error `authentication failed — try again` and clears the input. Escape dismisses with `False`. The password is read from the Input at submit time and passed only to the validator (validator runs in a thread via `run_worker(thread=True)` so a slow real `sudo -S -v` can't freeze the UI; result applied via `call_from_thread`).

- [ ] **Step 1: Write the failing tests**

`tui/tests/test_sudo_modal.py`:

```python
from textual.app import App

from workstation_tui.app.widgets.sudo_modal import SudoModal


class Host(App):
    def __init__(self, validator):
        super().__init__()
        self.validator = validator
        self.result: bool | None = None

    def on_mount(self) -> None:
        # push_screen_wait requires a WORKER context — on_mount is not one.
        self.run_worker(self._ask())

    async def _ask(self) -> None:
        self.result = await self.push_screen_wait(SudoModal(validator=self.validator))


async def test_correct_password_dismisses_true() -> None:
    app = Host(lambda pw: pw == "hunter2")
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press(*"hunter2")
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
    assert app.result is True


async def test_wrong_password_shows_error_and_retries() -> None:
    attempts: list[str] = []

    def validator(pw: str) -> bool:
        attempts.append(pw)
        return pw == "right"

    app = Host(validator)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press(*"wrong")
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
        error = str(app.query_one("#sudo-error").content)
        assert "authentication failed" in error
        await pilot.press(*"right")
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
    assert attempts == ["wrong", "right"]
    assert app.result is True


async def test_escape_dismisses_false() -> None:
    app = Host(lambda pw: True)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
    assert app.result is False
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement**

`tui/src/workstation_tui/app/widgets/__init__.py`:

```python
"""Reusable Textual widgets (modals, panes)."""
```

`tui/src/workstation_tui/app/widgets/sudo_modal.py`:

```python
"""Password overlay for the sudo gate (spec §Execution engine).

The password lives only in the Input widget and the validator call — never
on the app, never in a model, never logged.
"""

from typing import Callable

from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Input, Static

from workstation_tui.app.theme import M, muted


class SudoModal(ModalScreen[bool]):
    DEFAULT_CSS = f"""
    SudoModal {{
        align: center middle;
    }}
    #sudo-box {{
        width: 60;
        height: auto;
        padding: 1 2;
        background: {M['surface0']};
        border: solid {M['surface1']};
    }}
    #sudo-error {{
        color: {M['red']};
        height: auto;
    }}
    """

    BINDINGS = [("escape", "dismiss_false", "Cancel")]

    def __init__(self, *, validator: Callable[[str], bool]) -> None:
        super().__init__()
        self._validator = validator

    def compose(self) -> ComposeResult:
        with Vertical(id="sudo-box"):
            yield Static(f"[bold {M['mauve']}]sudo password required[/]", markup=True)
            yield Static(muted("privileged make targets need a valid sudo timestamp"),
                         markup=True)
            yield Input(password=True, placeholder="password", id="sudo-input")
            yield Static("", id="sudo-error", markup=False)

    def on_mount(self) -> None:
        self.query_one("#sudo-input", Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        password = event.value
        self.run_worker(lambda: self._check(password), thread=True, exclusive=True)

    def _check(self, password: str) -> None:
        ok = self._validator(password)
        self.app.call_from_thread(self._apply, ok)

    def _apply(self, ok: bool) -> None:
        if ok:
            self.dismiss(True)
        else:
            self.query_one("#sudo-error", Static).update(
                "authentication failed — try again"
            )
            field = self.query_one("#sudo-input", Input)
            field.value = ""
            field.focus()

    def action_dismiss_false(self) -> None:
        self.dismiss(False)
```

- [ ] **Step 4: Run to verify pass** — `3 passed`; full suite → `96 passed`.

- [ ] **Step 5: Commit**

```bash
git add tui/src/workstation_tui/app/widgets/ tui/tests/test_sudo_modal.py
git commit -m "feat(tui): sudo password modal with injectable validator"
git push
```

---

### Task 4: Provision panel + app task plumbing

**Files:**
- Create: `tui/src/workstation_tui/app/panels/provision.py`
- Modify: `tui/src/workstation_tui/app/app.py`
- Test: `tui/tests/test_provision_panel.py`

**Interfaces:**
- Consumes: `Runner`/`TaskBusyError`, `ToolStatus`, `read_inventory`+`scan`+`DEFAULT_STAMP_DIR`, `make_command`, theme.
- Produces:
  - `WorkstationApp` constructor grows `runner: Runner | None = None` and `tools_provider: Callable[[], tuple[list[ToolStatus], list[str]]] | None = None` (None → real: `rows, errs = read_inventory(root, mode); scan(DEFAULT_STAMP_DIR, rows), errs`; repo root from `find_repo_root()`; on None root returns `([], ["workstation repo not found"])`).
  - `app.launch_task(command: list[str], *, needs_sudo: bool = False) -> None` — refuses with a footer notification `task running` when the runner is busy (catches `TaskBusyError`); otherwise streams via an app-level async worker into the Provision log (`markup=False` lines), then notifies `done (rc=N)` / `cancelled` and refreshes summary + tools. (The sudo gate half of `needs_sudo` is Task 5 — in this task the flag is accepted and ignored with a `TODO(phase4-task5)` comment.)
  - `ProvisionPanel(Static)` with: filter `Input` (id `provision-filter`), `DataTable` (id `provision-table`, columns state/name/kind/version, rows from tools provider, glyphs via `STAMP_ICONS`), `RichLog` (id `provision-log`), bindings on the panel: `r` run selected tool, `c` clean+reinstall selected (`make -j1 clean-<t> <t>`), `u` check-updates, `R` full provision, `x` cancel running task. `refresh_tools()` reloads; filter narrows by substring on name.
  - Methods for tests/app: `panel.append_log(line: str)`, `panel.selected_tool() -> str | None`.

- [ ] **Step 1: Write the failing tests**

`tui/tests/test_provision_panel.py`:

```python
import asyncio

from workstation_tui.app.app import WorkstationApp
from workstation_tui.core.models import StampState, TaskResult, ToolStatus
from tests.test_app_shell import fake_provider

TOOLS = [
    ToolStatus(name="fzf", kind="scope", version="0.74.2", state=StampState.FRESH),
    ToolStatus(name="zellij", kind="scope", version="0.44.3", state=StampState.STALE),
    ToolStatus(name="glances", kind="user", version="latest", state=StampState.MISSING),
]


def tools_provider():
    return TOOLS, []


class FakeRunner:
    def __init__(self) -> None:
        self.commands: list[list[str]] = []
        self.busy = False

    async def run(self, command, on_line):
        self.commands.append(command)
        on_line("==> fake output")
        return TaskResult(command=command, returncode=0, duration_secs=0.1)

    def cancel(self) -> None:
        pass


def make_app() -> tuple[WorkstationApp, FakeRunner]:
    runner = FakeRunner()
    app = WorkstationApp(
        summary_provider=fake_provider,
        runner=runner,
        tools_provider=tools_provider,
    )
    return app, runner


async def test_table_lists_tools_and_filter() -> None:
    app, _ = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        table = app.query_one("#provision-table")
        assert table.row_count == 3
        app.query_one("#provision-filter").value = "zel"
        await pilot.pause()
        assert table.row_count == 1


async def test_run_selected_tool_streams_to_log() -> None:
    app, runner = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        await pilot.pause()
        assert runner.commands, "runner never invoked"
        cmd = runner.commands[0]
        assert cmd[-2:] == ["fzf", f"MODE={app.summary.context.mode}"] or "fzf" in cmd
        log_lines = app.query_one("#provision").log_lines
        assert any("fake output" in line for line in log_lines)


async def test_busy_refusal_notifies() -> None:
    app, runner = make_app()

    class BusyRunner(FakeRunner):
        def __init__(self):
            super().__init__()
            self.busy = True

        async def run(self, command, on_line):
            from workstation_tui.core.runner import TaskBusyError
            raise TaskBusyError()

    app._runner = BusyRunner()  # swap before mount wiring
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        # refusal shows as a notification, not a crash
        assert app.is_running
```

NOTE for the implementer: `#provision-panel-obj` / `log_lines` — expose the panel instance under a queryable id and keep a plain `log_lines: list[str]` mirror of what went into the RichLog (RichLog content isn't introspectable across Textual versions; the mirror is our test surface). Adapt test-selector details minimally if needed and document.

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement**

`tui/src/workstation_tui/app/panels/provision.py`:

```python
"""Provision panel: tool table + filter + streamed task log."""

from typing import Callable

from textual.app import ComposeResult
from textual.containers import Vertical
from textual.widgets import DataTable, Input, RichLog, Static

from workstation_tui.app.theme import M, STAMP_ICONS, kb, muted
from workstation_tui.core.models import ToolStatus

PROVISION_CSS = f"""
ProvisionPanel {{
    padding: 0 1;
}}
#provision-filter {{
    margin: 0;
}}
#provision-table {{
    height: 1fr;
}}
#provision-log {{
    height: 12;
    background: {M['mantle']};
    border-top: solid {M['surface1']};
}}
#provision-keys {{
    height: 1;
    color: {M['subtext0']};
}}
"""


class ProvisionPanel(Static):
    DEFAULT_CSS = PROVISION_CSS

    BINDINGS = [
        ("r", "run_tool", "Run"),
        ("c", "clean_tool", "Clean+reinstall"),
        ("u", "updates", "Check updates"),
        ("R", "full_provision", "Full provision"),
        ("x", "cancel_task", "Cancel task"),
    ]

    def __init__(self, *, id: str) -> None:  # noqa: A002 - Textual API
        super().__init__(id=id)
        self.tools: list[ToolStatus] = []
        self.errors: list[str] = []
        self.log_lines: list[str] = []
        self.can_focus = True

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Input(placeholder="filter tools…", id="provision-filter")
            yield DataTable(id="provision-table", cursor_type="row",
                            zebra_stripes=True)
            yield Static(kb(("r", "Run"), ("c", "Clean+reinstall"),
                            ("u", "Updates"), ("R", "Full provision"),
                            ("x", "Cancel")),
                         id="provision-keys", markup=True)
            yield RichLog(id="provision-log", markup=False, wrap=False)

    def on_mount(self) -> None:
        table = self.query_one("#provision-table", DataTable)
        table.add_column("", key="state", width=3)
        table.add_column("tool", key="tool", width=24)
        table.add_column("kind", key="kind", width=8)
        table.add_column("version", key="version", width=20)

    def set_tools(self, tools: list[ToolStatus], errors: list[str]) -> None:
        self.tools = tools
        self.errors = errors
        self._render_rows()

    def _render_rows(self) -> None:
        from workstation_tui.app.theme import icon

        table = self.query_one("#provision-table", DataTable)
        table.clear()
        needle = self.query_one("#provision-filter", Input).value.strip().lower()
        for t in self.tools:
            if needle and needle not in t.name.lower():
                continue
            table.add_row(icon(t.state.value, STAMP_ICONS), t.name, t.kind,
                          t.version, key=t.name)
        for err in self.errors:
            self.append_log(f"warning  {err}")

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "provision-filter":
            self._render_rows()

    def append_log(self, line: str) -> None:
        self.log_lines.append(line)
        self.query_one("#provision-log", RichLog).write(line)

    def selected_tool(self) -> str | None:
        table = self.query_one("#provision-table", DataTable)
        if table.row_count == 0 or table.cursor_row is None:
            return None
        row_key = table.coordinate_to_cell_key((table.cursor_row, 0)).row_key
        return str(row_key.value) if row_key and row_key.value else None

    def _tool_kind(self, name: str) -> str:
        for t in self.tools:
            if t.name == name:
                return t.kind
        return "scope"

    # -- actions delegate to the app (which owns runner + repo/mode) ----------

    def action_run_tool(self) -> None:
        tool = self.selected_tool()
        if tool is not None:
            self.app.run_make_goals(  # type: ignore[attr-defined]
                [tool], user_kind=self._tool_kind(tool) == "user")

    def action_clean_tool(self) -> None:
        tool = self.selected_tool()
        if tool is not None:
            self.app.run_make_goals(  # type: ignore[attr-defined]
                ["-j1", f"clean-{tool}", tool],
                user_kind=self._tool_kind(tool) == "user")

    def action_updates(self) -> None:
        self.app.run_make_goals(["check-updates"], user_kind=True)  # type: ignore[attr-defined]

    def action_full_provision(self) -> None:
        self.app.run_make_goals(["provision"], user_kind=False)  # type: ignore[attr-defined]

    def action_cancel_task(self) -> None:
        self.app.cancel_task()  # type: ignore[attr-defined]
```

In `app.py`:

- Imports: `Runner`, `TaskBusyError`, `make_command`, `read_inventory`, `scan`, `DEFAULT_STAMP_DIR`, `ToolStatus`, `ProvisionPanel`.
- Constructor: add `runner: Runner | None = None`, `tools_provider=None`; store `self._runner = runner or Runner()`, `self.tools_provider = tools_provider or self._default_tools`.
- `_default_tools(self)`: root = `find_repo_root()`; if None → `([], ["workstation repo not found"])`; else `rows, errs = read_inventory(root, self.summary.context.mode if self.summary else detect_context().mode)`; return `(scan(DEFAULT_STAMP_DIR, rows), errs)`.
- Swap `PlaceholderPanel("Provision", id="provision")` → `ProvisionPanel(id="provision")` — the panel object IS `#provision`, which the tests query directly for `log_lines`.
- `action_refresh` also reloads tools in the same thread worker: after summary, call `self.tools_provider()` and apply via `call_from_thread` to the provision panel's `set_tools`.
- `run_make_goals(self, goals: list[str], *, user_kind: bool) -> None`: repo root check (notify error if None); build `cmd = make_command(root, goals, mode)`; `needs_sudo = (mode == "dev") and not user_kind` (gate consumed in Task 5 — for now pass through to `launch_task`); `self.launch_task(cmd, needs_sudo=needs_sudo)`.
- `launch_task(self, command, *, needs_sudo=False)`: if `self._runner.busy`: `self.notify("task running", severity="warning")`; return. Else `self.run_worker(self._task_flow(command, needs_sudo), exclusive=False)` (async worker).
- `async def _task_flow(self, command, needs_sudo)`: (Task 5 inserts the sudo gate here; leave `# TODO(phase4-task5): sudo gate`) → panel = provision panel; `panel.append_log("$ " + " ".join(command))`; `try: result = await self._runner.run(command, panel.append_log)` catch `TaskBusyError` → notify; else notify `f"done (rc={result.returncode})"` or `"cancelled"`; then `self.action_refresh()`.
- `cancel_task(self)`: `self._runner.cancel()`.

- [ ] **Step 4: Run to verify pass** — `3 passed` new; full suite → `99 passed`.

- [ ] **Step 5: Commit**

```bash
git add tui/src/workstation_tui/app/ tui/tests/test_provision_panel.py
git commit -m "feat(tui): provision panel — tool table, filter, streamed task log"
git push
```

---

### Task 5: Sudo gate integration + keepalive + suspend fallback

**Files:**
- Modify: `tui/src/workstation_tui/app/app.py`
- Test: `tui/tests/test_sudo_gate.py`

**Interfaces:**
- Consumes: `sudo_status`, `sudo_validate`, `SudoModal`, Task 4's `_task_flow` TODO seam.
- Produces:
  - Constructor grows `sudo_status_fn=sudo_status`, `sudo_validate_fn=sudo_validate` (injectable).
  - `_task_flow` gains the gate before running: when `needs_sudo` and `context.os == "linux"`: `status = await asyncio.to_thread(self.sudo_status_fn)`; `"valid"` → proceed; `"no_sudo"` → notify error `sudo not available`, abort; `"needs_password"` → `ok = await self.push_screen_wait(SudoModal(validator=self.sudo_validate_fn))`; not ok → notify `cancelled`, abort; ok → re-check `sudo_status_fn()`; if STILL `needs_password` (timestamp_timeout=0 sudoers) → notify error `sudo timestamp caching disabled — run in a terminal: <command>` and abort (the full app-suspend flow is deferred to the phase that needs it; the message names the exact command).
  - While a `needs_sudo` task runs: keepalive async worker calls `sudo_status_fn` every `self.sudo_keepalive_secs` (default 60.0, test-overridable); stops when the task ends.

- [ ] **Step 1: Write the failing tests**

`tui/tests/test_sudo_gate.py`:

```python
import asyncio

from workstation_tui.app.app import WorkstationApp
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider


def make_app(statuses: list[str], validate_results: list[bool]):
    runner = FakeRunner()
    status_calls: list[int] = []
    validate_calls: list[str] = []

    def status_fn():
        status_calls.append(1)
        return statuses.pop(0) if statuses else "valid"

    def validate_fn(pw: str) -> bool:
        validate_calls.append(pw)
        return validate_results.pop(0)

    app = WorkstationApp(
        summary_provider=fake_provider, runner=runner,
        tools_provider=tools_provider,
        sudo_status_fn=status_fn, sudo_validate_fn=validate_fn,
    )
    return app, runner, status_calls, validate_calls


async def test_valid_timestamp_runs_without_modal() -> None:
    app, runner, status_calls, _ = make_app(["valid"], [])
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        await pilot.pause()
        assert runner.commands
        assert status_calls


async def test_password_flow_then_run() -> None:
    app, runner, _, validate_calls = make_app(
        ["needs_password", "valid"], [True]
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        await pilot.press(*"pw")
        await pilot.press("enter")
        for _ in range(4):
            await pilot.pause()
        assert validate_calls == ["pw"]
        assert runner.commands


async def test_modal_escape_aborts() -> None:
    app, runner, _, _ = make_app(["needs_password"], [])
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        await pilot.press("escape")
        for _ in range(3):
            await pilot.pause()
        assert runner.commands == []


async def test_user_kind_skips_gate() -> None:
    app, runner, status_calls, _ = make_app(["needs_password"], [])
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        await pilot.pause()
        app.query_one("#provision-filter").value = "glances"
        await pilot.pause()
        app.query_one("#provision-table").focus()
        await pilot.press("r")
        await pilot.pause()
        await pilot.pause()
        assert runner.commands          # ran
        assert status_calls == []       # gate never consulted for user-kind
```

- [ ] **Step 2: Run to verify failure** (constructor kwargs unknown).

- [ ] **Step 3: Implement** per the Interfaces block. Keepalive sketch inside `_task_flow` around the runner await:

```python
        keepalive: asyncio.Task | None = None
        if needs_sudo:
            async def _keepalive() -> None:
                while True:
                    await asyncio.sleep(self.sudo_keepalive_secs)
                    await asyncio.to_thread(self.sudo_status_fn)
            keepalive = asyncio.create_task(_keepalive())
        try:
            result = await self._runner.run(command, panel.append_log)
        finally:
            if keepalive is not None:
                keepalive.cancel()
```

(`self.sudo_keepalive_secs = 60.0` set in `__init__`.)

- [ ] **Step 4: Run to verify pass** — `4 passed` new; full suite → `103 passed`.

- [ ] **Step 5: Commit**

```bash
git add tui/src/workstation_tui/app/app.py tui/tests/test_sudo_gate.py
git commit -m "feat(tui): sudo gate — overlay flow, keepalive, timestamp_timeout fallback"
git push
```

---

### Task 6: Docs + gate + PR

**Files:**
- Modify: `CLAUDE_CHANGELOG.md`

- [ ] **Step 1: CLAUDE_CHANGELOG.md** — append AT THE END of the table (chronological):

```markdown
| workstation TUI Phase 4: async runner (stream/refuse/cancel), in-TUI sudo overlay + keepalive, live Provision panel (table/filter/log, run/clean/updates/full) | No | README §tui still lands with the final phase |
```

- [ ] **Step 2: Full gate**

```bash
make -C makefile lint MODE=prod
make -C makefile tui-test MODE=prod     # expect 103 passed
bash scripts/check-templates.sh
```

- [ ] **Step 3: Commit + PR**

```bash
git add CLAUDE_CHANGELOG.md
git commit -m "docs: phase-4 changelog row"
git push
gh pr create --base main --title "feat(tui): workstation TUI Phase 4 — runner, sudo overlay, provision panel" --body "$(cat <<'EOF'
Phase 4 of the workstation TUI (spec §Execution engine + §screens Provision):

- core/runner.py: asyncio engine — merged-stream line callbacks, ONE task at a
  time (busy = refusal, never queue), SIGINT-group cancel with SIGKILL grace,
  127/126 conventions, MAKEFLAGS scrub
- core/sudo.py: sudo -n -v status / sudo -S -v validate (password transient)
- SudoModal: password overlay, threaded validator, inline retry, escape=abort
- Provision panel: tool table (stamp glyphs) + filter + streamed RichLog;
  r/c/u/R/x actions; user-kind targets skip the sudo gate; prod never gates
- sudo gate in the task flow: cached-timestamp short-circuit → modal →
  re-check (timestamp_timeout=0 → named-command fallback message) + 60s
  keepalive while privileged tasks run
- Pilot + asyncio test suite; fakes only (no real make/sudo in tests)

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01UfFaGAdVaLjVVrnq4jNJ9p
EOF
)"
gh pr checks --watch
```

Hand the PR to the user for review/merge; remind them the interactive sudo-overlay smoke (run a stale-timestamp `make` target from the TUI in a real terminal) is human-only.
