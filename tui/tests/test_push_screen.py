import asyncio

from textual.app import App
from textual.screen import ModalScreen

import workstation_tui.app.panels.fleet as fleet_mod
from workstation_tui.app.widgets.confirm_modal import ConfirmModal
from workstation_tui.app.widgets.push_screen import PushScreen
from workstation_tui.app.widgets.text_view import TextViewScreen
from workstation_tui.core.multirun import HostRun, MultiRunner
from tests.test_fleet_panel import HOSTS, make_app

# -- test doubles -----------------------------------------------------------


class ScriptedRunner:
    """MultiRunner double for driving PushScreen's own rendering directly
    (no real MultiRunner/subprocess): records `commands`, exposes `.runs`
    (same shape as the real `HostRun` dict), captures the `on_update`
    callback `run()` is handed so the test can fire it on demand, and
    blocks in `run()` until the test releases it (`finish()`) or the test
    drives `cancel()` itself — mirrors how the real MultiRunner keeps
    `run()` alive for the whole push, with state changes arriving via
    `on_update` in between.
    """

    def __init__(self, commands: dict[str, list[str]], *, limit: int = 4, exec_fn=None) -> None:
        self.commands = dict(commands)
        self.runs: dict[str, HostRun] = {
            name: HostRun(name=name, state="queued") for name in commands
        }
        self.cancel_called = False
        self.on_update = None
        self._release = asyncio.Event()

    async def run(self, on_update) -> None:
        self.on_update = on_update
        await self._release.wait()

    def fire(self, name: str) -> None:
        """Test hook: invoke the captured on_update for `name`, same as
        MultiRunner would after mutating that host's HostRun."""
        assert self.on_update is not None, "run() never started"
        self.on_update(name)

    def finish(self) -> None:
        self._release.set()

    def cancel(self) -> None:
        self.cancel_called = True
        for run in self.runs.values():
            if run.state in ("queued", "running"):
                run.state = "cancelled"
        self.finish()


class DoneRunner:
    """Every host already finished by the time `run()` is awaited — models
    a completed MultiRunner cycle so `esc` dismisses immediately without
    the confirm-then-cancel detour ScriptedRunner's still-queued rows hit."""

    def __init__(self, commands: dict[str, list[str]], *, limit: int = 4, exec_fn=None) -> None:
        self.commands = dict(commands)
        self.runs: dict[str, HostRun] = {
            name: HostRun(name=name, state="done", rc=0) for name in commands
        }
        self.cancel_called = False

    async def run(self, on_update) -> None:
        return

    def cancel(self) -> None:
        self.cancel_called = True


class Host(App):
    """Minimal push_screen_wait harness (test_widgets.py's pattern) — pushes
    whatever screen_factory() returns and records its eventual dismiss
    result."""

    def __init__(self, screen_factory):
        super().__init__()
        self.screen_factory = screen_factory
        self.result = "UNSET"
        # Task 3 added PushScreen's dependency on app.notifier/
        # notify_threshold_secs/_push_inflight (the push-completion toast +
        # mutual-exclusion flag, spec §1) — this bare-App harness never
        # exercises real WorkstationApp wiring, so `_run_push` needs
        # matching attributes to run without an AttributeError. The
        # notification RULES themselves are covered by
        # test_push_integration.py against a real WorkstationApp; this
        # harness only needs to not crash.
        self.notifier = lambda title, msg: None
        self.notify_threshold_secs = 10.0
        self._push_inflight = False

    def on_mount(self) -> None:
        self.run_worker(self._ask())

    async def _ask(self) -> None:
        self.result = await self.push_screen_wait(self.screen_factory())


class _RecordingPushScreen(ModalScreen[dict[str, str] | None]):
    """Fleet-panel wiring double: records the `commands` dict PushScreen
    was constructed with, then dismisses immediately — no real MultiRunner
    ever gets built, so pressing p/P in these tests can never spawn a real
    subprocess."""

    captured: dict[str, list[str]] | None = None

    def __init__(self, commands, *, runner_factory=None) -> None:
        super().__init__()
        _RecordingPushScreen.captured = commands

    def on_mount(self) -> None:
        self.dismiss(None)


# -- p/P wiring: FleetPanel opens PushScreen with the right commands --------


async def test_push_selected_opens_screen_with_one_command(monkeypatch) -> None:
    monkeypatch.setattr(fleet_mod, "PushScreen", _RecordingPushScreen)
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("p")
        await pilot.pause()
        await pilot.press("y")
        for _ in range(4):
            await pilot.pause()
    assert _RecordingPushScreen.captured is not None
    assert list(_RecordingPushScreen.captured.keys()) == ["alpha"]
    assert _RecordingPushScreen.captured["alpha"][-2:] == ["--name", "alpha"]


async def test_push_all_opens_screen_with_every_host(monkeypatch) -> None:
    monkeypatch.setattr(fleet_mod, "PushScreen", _RecordingPushScreen)
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("P")
        await pilot.pause()
        await pilot.press("y")
        for _ in range(4):
            await pilot.pause()
    assert _RecordingPushScreen.captured is not None
    assert set(_RecordingPushScreen.captured.keys()) == {e.name for e in HOSTS}


# -- PushScreen rendering + lifecycle (scripted runner_factory) -------------


async def test_rows_render_queued_glyphs_before_run() -> None:
    commands = {"alpha": ["cmd"], "beta": ["cmd"]}
    runners: list[ScriptedRunner] = []

    def factory(cmds, **kwargs):
        runner = ScriptedRunner(cmds)
        runners.append(runner)
        return runner

    app = Host(lambda: PushScreen(commands, runner_factory=factory))
    async with app.run_test() as pilot:
        await pilot.pause()
        table = app.screen.query_one("#push-table")
        assert table.row_count == 2
        alpha_row = table.get_row("alpha")
        assert alpha_row[0].plain == "·"  # PUSH_ICONS["queued"]
        assert alpha_row[1].plain == "alpha"
        summary = str(app.screen.query_one("#push-summary").content)
        assert summary == "0 running · 0 done · 0 failed · 2 queued"
        runners[0].finish()  # let the still-blocked worker unwind on teardown
        await pilot.pause()


async def test_state_updates_render_glyphs_and_summary() -> None:
    commands = {"alpha": ["cmd"], "beta": ["cmd"]}
    runners: list[ScriptedRunner] = []

    def factory(cmds, **kwargs):
        runner = ScriptedRunner(cmds)
        runners.append(runner)
        return runner

    app = Host(lambda: PushScreen(commands, runner_factory=factory))
    async with app.run_test() as pilot:
        await pilot.pause()
        runner = runners[0]
        runner.runs["alpha"].state = "done"
        runner.runs["alpha"].rc = 0
        runner.runs["alpha"].lines = ["ok"]
        runner.fire("alpha")
        runner.runs["beta"].state = "failed"
        runner.runs["beta"].rc = 1
        runner.runs["beta"].lines = ["boom"]
        runner.fire("beta")
        await pilot.pause()
        table = app.screen.query_one("#push-table")
        assert table.get_row("alpha")[0].plain == "✓"
        assert table.get_row("alpha")[3].plain == "ok"
        assert table.get_row("beta")[0].plain == "✗"
        assert table.get_row("beta")[3].plain == "boom"
        summary = str(app.screen.query_one("#push-summary").content)
        assert summary == "0 running · 1 done · 1 failed · 0 queued"
        runner.finish()
        await pilot.pause()


# -- enter drills into the cursor host's log --------------------------------


async def test_enter_opens_text_view_with_host_lines() -> None:
    commands = {"alpha": ["cmd"]}

    def factory(cmds, **kwargs):
        return ScriptedRunner(cmds)

    app = Host(lambda: PushScreen(commands, runner_factory=factory))
    async with app.run_test() as pilot:
        await pilot.pause()
        push_screen = app.screen
        push_screen._runner.runs["alpha"].lines = ["line one", "line two"]
        table = push_screen.query_one("#push-table")
        table.focus()
        await pilot.press("enter")
        await pilot.pause()
        assert isinstance(app.screen, TextViewScreen)
        assert app.screen._text == "line one\nline two"
        assert app.screen._title == "alpha"
        await pilot.press("escape")
        await pilot.pause()
        push_screen._runner.finish()
        await pilot.pause()


# -- escape: confirm while unfinished, dismiss outright once finished -------


async def test_esc_asks_while_running_then_dismisses_once_finished() -> None:
    """One test, two scenarios (brief's bullet 6): `esc` while any host is
    still queued/running asks first, and declining leaves the dashboard
    open; `esc` once every host has finished dismisses straight away with
    the outcomes dict, no confirm detour."""

    # -- still running: esc asks; declining stays open, no dismiss yet ----
    def scripted_factory(cmds, **kwargs):
        return ScriptedRunner(cmds)  # rows stay "queued" — run() never released

    still_running = Host(
        lambda: PushScreen({"alpha": ["cmd"]}, runner_factory=scripted_factory)
    )
    async with still_running.run_test() as pilot:
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
        # ConfirmModal now on top of PushScreen — declining must leave it
        # there, not dismiss the underlying push dashboard.
        assert isinstance(still_running.screen, ConfirmModal)
        await pilot.press("n")
        await pilot.pause()
        assert isinstance(still_running.screen, PushScreen)
    assert still_running.result == "UNSET"

    # -- already finished: esc dismisses immediately with the outcomes ----
    def done_factory(cmds, **kwargs):
        return DoneRunner(cmds)

    finished = Host(
        lambda: PushScreen(
            {"alpha": ["cmd"], "beta": ["cmd"]}, runner_factory=done_factory
        )
    )
    async with finished.run_test() as pilot:
        await pilot.pause()
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
    assert finished.result == {"alpha": "done", "beta": "done"}


# -- fix round 1 regression: cancel-and-close waits for settled outcomes ---


class _HangingProc:
    """Mirrors test_multirun.py's cancellation-test fakes: `readline()`
    blocks until the per-host task is cancelled (kill()+wait() then reap
    cleanly), reproducing the REAL MultiRunner cancellation race —
    `HostRun.state = "cancelled"` only lands once the task's own
    `except asyncio.CancelledError` handler runs, not synchronously inside
    `MultiRunner.cancel()`. `ScriptedRunner`'s synchronous `cancel()` can't
    reproduce this timing, which is why fix round 1 needed a REAL
    `MultiRunner` (with a fake `exec_fn`) here instead."""

    def __init__(self, started: asyncio.Event) -> None:
        self._started = started
        self.stdout = self
        self.returncode = None

    async def readline(self) -> bytes:
        self._started.set()
        await asyncio.sleep(10)
        return b""  # pragma: no cover - killed well before this resolves

    def kill(self) -> None:
        self.returncode = -9

    async def wait(self) -> int:
        return -9


class _QuickProc:
    """Finishes immediately with rc=0 and no output — models a host whose
    push already completed before the cancel-and-close happens."""

    def __init__(self) -> None:
        self.stdout = self
        self.returncode = 0

    async def readline(self) -> bytes:
        return b""

    async def wait(self) -> int:
        return self.returncode


async def test_esc_cancel_waits_for_settled_outcomes_before_dismissing() -> None:
    """Regression pin: `_close_flow` must AWAIT the push worker's real
    settling after `runner.cancel()` before computing `_outcomes()`. Before
    the fix, `dismiss()` fired with whatever state each host happened to be
    in the instant `cancel()` RETURNED (still "running" for the in-flight
    host) rather than the settled "cancelled" — reproduced end-to-end here
    with a REAL `MultiRunner` (fake `exec_fn`, no real subprocess)."""
    started = asyncio.Event()
    commands = {"alpha": ["run-alpha"], "beta": ["run-beta"]}

    async def fake_exec(*args, **kwargs):
        if args[0] == "run-alpha":
            return _HangingProc(started)
        return _QuickProc()

    def factory(cmds, **kwargs):
        return MultiRunner(cmds, exec_fn=fake_exec)

    app = Host(lambda: PushScreen(commands, runner_factory=factory))
    async with app.run_test() as pilot:
        await pilot.pause()
        await asyncio.wait_for(started.wait(), timeout=5)
        # beta (no output, rc=0) settles almost immediately; a few more
        # ticks lets it land "done" before the snapshot below.
        for _ in range(5):
            await pilot.pause()
        push_screen = app.screen
        assert push_screen._runner.runs["alpha"].state == "running"
        assert push_screen._runner.runs["beta"].state == "done"

        await pilot.press("escape")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmModal)
        await pilot.press("y")
        # The confirm-then-cancel worker is now awaiting the push worker's
        # real settling (asyncio task cancellation needs a scheduling
        # turn) — pump the loop until dismiss actually lands.
        for _ in range(10):
            await pilot.pause()

    assert app.result == {"alpha": "cancelled", "beta": "done"}
