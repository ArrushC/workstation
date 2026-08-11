"""Task 3: push integration — mutual exclusion, last-push column,
notification (spec §1 rest).

Reuses test_fleet_panel.py's `make_app` fixture and test_push_screen.py's
`_RecordingPushScreen` double (no real MultiRunner/subprocess is ever
constructed here) plus core/multirun.py's `HostRun` dataclass directly for
the notification-rule scenarios.
"""

import asyncio

from workstation_tui.app.app import WorkstationApp
from workstation_tui.app.panels.fleet import rel_age
from workstation_tui.app.widgets.push_screen import PushScreen
from workstation_tui.core.multirun import HostRun
from tests.test_app_shell import fake_provider
from tests.test_fleet_panel import make_app
from tests.test_provision_panel import FakeRunner, tools_provider
from tests.test_push_screen import _RecordingPushScreen

import workstation_tui.app.panels.fleet as fleet_mod

# -- 1. launch_task refused while a push is in flight -----------------------


async def test_launch_task_refused_while_push_inflight(monkeypatch) -> None:
    runner = FakeRunner()
    app = WorkstationApp(
        summary_provider=fake_provider, runner=runner,
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
    )
    calls: list[tuple[tuple, dict]] = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app._push_inflight = True
        monkeypatch.setattr(app, "notify", lambda *a, **k: calls.append((a, k)))
        app.launch_task(["make", "fzf"], log_to=lambda _: None)
        for _ in range(4):
            await pilot.pause()
    assert runner.commands == [], "runner must never be touched while push is inflight"
    assert calls, "must notify the user"
    assert calls[0][0][0] == "push running"
    assert calls[0][1].get("severity") == "warning"


# -- 2. push entry refused while a local task is in flight -------------------


async def test_push_entry_refused_while_task_inflight(monkeypatch) -> None:
    monkeypatch.setattr(fleet_mod, "PushScreen", _RecordingPushScreen)
    _RecordingPushScreen.captured = None
    runner = FakeRunner()
    app = make_app(runner)
    calls: list[tuple[tuple, dict]] = []
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        app._task_inflight = True
        monkeypatch.setattr(app, "notify", lambda *a, **k: calls.append((a, k)))
        await pilot.press("p")
        await pilot.pause()
    assert _RecordingPushScreen.captured is None, "PushScreen must never open"
    assert calls, "must notify the user"
    assert calls[0][0][0] == "task running"
    assert calls[0][1].get("severity") == "warning"


# -- 3. watch tick skips while a push is in flight ---------------------------


async def test_watch_tick_skips_while_push_inflight() -> None:
    calls = 0

    def counting_provider():
        nonlocal calls
        calls += 1
        return fake_provider()

    app = WorkstationApp(
        summary_provider=counting_provider, runner=FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        watch_interval_secs=0.05,
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        baseline = calls
        app._push_inflight = True
        await pilot.press("w")
        await asyncio.sleep(0.2)
        await pilot.pause()
        assert calls == baseline
        app._push_inflight = False
        await pilot.press("w")  # pause the timer before context teardown
        await pilot.pause()


# -- 4. _apply_push_outcomes populates last_push + push column renders ------


async def test_apply_push_outcomes_populates_last_push_and_renders_column() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        panel = app.query_one("#fleet")
        table = app.query_one("#fleet-table")

        # never-pushed hosts render a dim dash in the push column (index 2:
        # net, repo, push, name, ...).
        assert table.get_row("alpha")[2].plain == "–"

        # Isolate the push-column assertions from the async re-probe cycle
        # `_apply_push_outcomes` also triggers (refresh_panel() -> a
        # thread worker that re-renders on its own schedule) — this test
        # cares only about the synchronous stamping + rendering contract.
        panel.refresh_panel = lambda: None
        panel._now_fn = lambda: 1000.0
        panel._apply_push_outcomes({"alpha": "done", "beta": "failed"})
        assert panel.last_push["alpha"] == ("done", 1000.0)
        assert panel.last_push["beta"] == ("failed", 1000.0)

        panel._now_fn = lambda: 1047.0  # 47s later
        panel._render_rows()
        alpha_cell = table.get_row("alpha")[2]
        assert alpha_cell.plain == "✓ 47s"
        beta_cell = table.get_row("beta")[2]
        assert beta_cell.plain == "✗ 47s"


# -- 5. rel_age boundaries ----------------------------------------------------


def test_rel_age_boundaries() -> None:
    assert rel_age(59) == "59s"
    assert rel_age(60) == "1m"
    assert rel_age(3599) == "59m"
    assert rel_age(3600) == "1h"
    assert rel_age(86400) == "1d"


# -- 6. notification rules ----------------------------------------------------


class _FixedRunner:
    """MultiRunner double whose `.runs` are pre-set to the desired terminal
    states/timestamps and whose `run()` returns immediately (like
    test_push_screen.py's DoneRunner) — models a push that already
    settled by the time PushScreen's own worker awaits it."""

    def __init__(self, runs: dict[str, HostRun]) -> None:
        self.commands = {name: ["cmd"] for name in runs}
        self.runs = runs

    async def run(self, on_update) -> None:
        return

    def cancel(self) -> None:
        pass


async def _drive_notification(
    runs: dict[str, HostRun], threshold: float
) -> list[tuple[str, str]]:
    calls: list[tuple[str, str]] = []
    app = WorkstationApp(
        summary_provider=fake_provider, runner=FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        notifier=lambda title, msg: calls.append((title, msg)),
    )
    app.notify_threshold_secs = threshold

    def factory(cmds, **kwargs):
        return _FixedRunner(runs)

    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(PushScreen({n: ["cmd"] for n in runs}, runner_factory=factory))
        for _ in range(5):
            await pilot.pause()
    return calls


async def test_notification_rules() -> None:
    # failed present -> ALWAYS notifies, regardless of duration being under
    # the threshold.
    failed_runs = {
        "alpha": HostRun(name="alpha", state="done", rc=0, started=0.0, finished=1.0),
        "beta": HostRun(name="beta", state="failed", rc=1, started=0.0, finished=1.0),
    }
    calls = await _drive_notification(failed_runs, threshold=10.0)
    assert calls == [("workstation", "push — 1 ok, 1 failed (1s)")]

    # all ok, duration >= threshold -> notifies.
    ok_long_runs = {
        "alpha": HostRun(name="alpha", state="done", rc=0, started=0.0, finished=20.0),
    }
    calls = await _drive_notification(ok_long_runs, threshold=10.0)
    assert calls == [("workstation", "push — 1 ok, 0 failed (20s)")]

    # all ok, duration < threshold -> no toast.
    ok_short_runs = {
        "alpha": HostRun(name="alpha", state="done", rc=0, started=0.0, finished=5.0),
    }
    calls = await _drive_notification(ok_short_runs, threshold=10.0)
    assert calls == []

    # every host cancelled -> NEVER a toast, even with threshold=0 (which
    # would otherwise trip the "ok" branch for any non-negative duration).
    cancelled_runs = {
        "alpha": HostRun(
            name="alpha", state="cancelled", rc=None, started=0.0, finished=5.0
        ),
        "beta": HostRun(name="beta", state="cancelled", rc=None),
    }
    calls = await _drive_notification(cancelled_runs, threshold=0.0)
    assert calls == []
