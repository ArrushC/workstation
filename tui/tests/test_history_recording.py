"""Task 4: history recording hooks — launch_task/run_task_sequence,
PushScreen completion, and Fleet key distribution each land one (or more)
`HistoryEntry` in `app.history_store` (spec §3 recording).

Recording is fire-and-forget (`WorkstationApp.record_history` schedules a
background `asyncio.to_thread` task rather than awaiting it), so every test
here polls the tmp on-disk store for a short while instead of asserting
immediately after the triggering call.
"""

import asyncio

from workstation_tui.app.app import WorkstationApp
from workstation_tui.app.panels.fleet import FleetPanel
from workstation_tui.app.widgets.push_screen import PushScreen
from workstation_tui.core.models import TaskResult
from workstation_tui.core.multirun import HostRun
from tests.test_app_shell import fake_provider
from tests.test_fleet_panel import make_app as make_fleet_app
from tests.test_provision_panel import FakeRunner, tools_provider


def make_app(runner=None, **kwargs):
    return WorkstationApp(
        summary_provider=fake_provider, runner=runner or FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        **kwargs,
    )


async def _wait_for_history(app, count, timeout=2.0, step=0.02):
    """Poll `app.history_store` until it holds >= `count` entries (or the
    timeout elapses) — record_history's create_task/to_thread hop means the
    write may not have landed yet the instant the triggering call returns.
    """
    elapsed = 0.0
    while elapsed < timeout:
        entries = app.history_store.load()
        if len(entries) >= count:
            return entries
        await asyncio.sleep(step)
        elapsed += step
    return app.history_store.load()


# -- 1. launch_task rc 0 -> one "task" entry ---------------------------------


async def test_launch_task_success_records_task_entry() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        app.launch_task(["fake", "cmd"], log_to=lambda _: None)
        for _ in range(4):
            await pilot.pause()
        entries = await _wait_for_history(app, 1)
    assert len(entries) == 1
    entry = entries[0]
    assert entry.kind == "task"
    assert entry.command == ["fake", "cmd"]
    assert entry.summary == "fake cmd"
    assert entry.returncode == 0
    assert entry.duration_secs == 0.1
    assert entry.cancelled is False
    assert entry.outcome == "ok"
    log = app.history_store.read_log(entry.id)
    assert "$ fake cmd" in log
    assert "fake output" in log


# -- 2. cancelled task -> outcome cancelled ----------------------------------


async def test_cancelled_task_records_cancelled_outcome() -> None:
    class CancellingRunner(FakeRunner):
        async def run(self, command, on_line):
            self.commands.append(command)
            on_line("==> fake output")
            return TaskResult(command=command, returncode=0, duration_secs=5.0,
                              cancelled=True)

    app = make_app(CancellingRunner())
    async with app.run_test() as pilot:
        await pilot.pause()
        app.launch_task(["fake", "cmd"], log_to=lambda _: None)
        for _ in range(4):
            await pilot.pause()
        entries = await _wait_for_history(app, 1)
    assert len(entries) == 1
    entry = entries[0]
    assert entry.kind == "task"
    assert entry.cancelled is True
    assert entry.outcome == "cancelled"


# -- 3. sequence of two -> two "sequence" entries in order -------------------


async def test_sequence_of_two_records_two_entries_in_order() -> None:
    class SlowSequentialRunner:
        """FakeRunner-shaped double whose `run()` takes a real (small)
        wall-clock delay before returning. This isn't padding for its own
        sake: each command's history write is a fire-and-forget background
        task (record_history -> create_task(to_thread(...))), so with a
        zero-delay runner both commands' writes could be submitted to the
        thread-pool executor close enough together to race for which one
        actually lands in index.jsonl first. Giving the SECOND command's
        run() a real sleep guarantees the first command's write has long
        since completed on its own thread before the second is even
        scheduled, so the two entries land in the on-disk index in the
        same order the sequence ran them.
        """

        def __init__(self) -> None:
            self.commands: list[list[str]] = []
            self.busy = False

        async def run(self, command, on_line):
            self.commands.append(command)
            on_line("out")
            await asyncio.sleep(0.05)
            return TaskResult(command=command, returncode=0, duration_secs=0.01)

        def cancel(self) -> None:
            pass

    app = make_app(SlowSequentialRunner())
    async with app.run_test() as pilot:
        await pilot.pause()
        app.run_task_sequence([["one"], ["two"]], log_to=lambda _: None)
        for _ in range(4):
            await pilot.pause()
        entries = await _wait_for_history(app, 2, timeout=3.0)
    assert len(entries) == 2
    ordered = list(reversed(entries))  # load() returns newest first
    assert [e.command for e in ordered] == [["one"], ["two"]]
    assert [e.kind for e in ordered] == ["sequence", "sequence"]
    assert all(e.needs_sudo is False for e in ordered)
    assert all(e.outcome == "ok" for e in ordered)


# -- 4. sudo-refused / busy -> nothing recorded ------------------------------


async def test_sudo_refused_and_busy_record_nothing() -> None:
    # sudo-gate refusal: needs_sudo=True + sudo_status_fn -> "no_sudo" means
    # _sudo_gate returns False and _task_flow returns before a TaskResult
    # ever exists.
    refused_app = WorkstationApp(
        summary_provider=fake_provider, runner=FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "no_sudo",
    )
    async with refused_app.run_test() as pilot:
        await pilot.pause()
        refused_app.launch_task(["fake", "cmd"], needs_sudo=True, log_to=lambda _: None)
        for _ in range(4):
            await pilot.pause()
        await asyncio.sleep(0.1)
    assert refused_app.history_store.load() == []

    # busy: the runner reports busy=True, so launch_task's own busy check
    # refuses BEFORE the worker (and thus _task_flow) ever runs — again, no
    # TaskResult ever exists.
    class BusyRunner(FakeRunner):
        def __init__(self) -> None:
            super().__init__()
            self.busy = True

    busy_app = make_app(BusyRunner())
    async with busy_app.run_test() as pilot:
        await pilot.pause()
        busy_app.launch_task(["fake", "cmd"], log_to=lambda _: None)
        for _ in range(4):
            await pilot.pause()
        await asyncio.sleep(0.1)
    assert busy_app.history_store.load() == []


# -- 5. push completion -> one "push" entry with per-host log sections ------


async def test_push_completion_records_push_entry() -> None:
    runs = {
        "alpha": HostRun(name="alpha", state="done", rc=0, started=0.0, finished=1.0,
                         lines=["alpha line one", "alpha line two"]),
        "beta": HostRun(name="beta", state="failed", rc=1, started=0.0, finished=2.0,
                        lines=["beta line one"]),
    }

    class FixedRunner:
        """MultiRunner double: `.runs` pre-set to already-settled HostRuns,
        `run()` returns immediately — models a push whose per-host work is
        already done by the time PushScreen's worker awaits it (same shape
        as test_push_integration.py's `_FixedRunner`)."""

        def __init__(self, commands) -> None:
            self.commands = dict(commands)
            self.runs = runs

        async def run(self, on_update) -> None:
            return

        def cancel(self) -> None:
            pass

    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(PushScreen({n: ["cmd"] for n in runs}, runner_factory=FixedRunner))
        for _ in range(6):
            await pilot.pause()
        entries = await _wait_for_history(app, 1)
    assert len(entries) == 1
    entry = entries[0]
    assert entry.kind == "push"
    assert entry.command is None
    assert entry.returncode is None
    assert entry.summary == "push — 1 ok, 1 failed"
    assert entry.outcome == "failed"
    log = app.history_store.read_log(entry.id)
    assert "=== alpha (done, rc=0) ===" in log
    assert "alpha line one" in log
    assert "alpha line two" in log
    assert "=== beta (failed, rc=1) ===" in log
    assert "beta line one" in log


# -- 6. keydist results -> one "keydist" entry -------------------------------


async def test_keydist_results_record_keydist_entry() -> None:
    app = make_fleet_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        panel = app.query_one("#fleet", FleetPanel)
        panel._apply_copy_id_results([("alpha", 0), ("beta", 1)])
        entries = await _wait_for_history(app, 1)
    assert len(entries) == 1
    entry = entries[0]
    assert entry.kind == "keydist"
    assert entry.command is None
    assert entry.returncode is None
    assert entry.duration_secs == 0.0
    assert entry.summary == "key distribution — 1 ok, 1 failed"
    assert entry.outcome == "failed"
    log = app.history_store.read_log(entry.id)
    assert "copy-id alpha: ok" in log
    assert "copy-id beta: failed (rc=1)" in log


# -- 7. F3: an unwritable/broken store warns ONCE per session, never raises --


class FailingStore:
    """A `HistoryStore`-shaped double whose `record()` always reports
    failure (the same `False` a real store returns for an unwritable
    root) without touching any real filesystem."""

    def record(self, entry, log_lines, keep: int = 200) -> bool:
        return False


async def test_unwritable_store_warns_once_per_session() -> None:
    app = make_app(history_store=FailingStore())
    calls: list[tuple[tuple, dict]] = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.notify = lambda *a, **k: calls.append((a, k))  # type: ignore[method-assign]

        app.launch_task(["fake", "cmd"], log_to=lambda _: None)
        for _ in range(4):
            await pilot.pause()
        await asyncio.sleep(0.1)

        # A second failed recording in the SAME session must not add a
        # second toast — one warning is enough to tell the user
        # something is wrong without spamming one per run.
        app.launch_task(["fake", "cmd2"], log_to=lambda _: None)
        for _ in range(4):
            await pilot.pause()
        await asyncio.sleep(0.1)

    warnings = [c for c in calls if "history write failed" in c[0][0]]
    assert len(warnings) == 1
    assert warnings[0][1].get("severity") == "warning"
    assert warnings[0][1].get("markup") is False
