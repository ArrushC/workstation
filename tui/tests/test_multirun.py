import asyncio

import pytest

from workstation_tui.core.multirun import HostRun, MultiRunner


class FakeProc:
    """Fake asyncio.subprocess.Process: PIPE-merged stdout streamed line by
    line, then EOF; `wait()` resolves once the lines are drained. Mirrors the
    `probe_setup` fake-subprocess pattern in test_fleet.py, plus an async
    `.stdout.readline()` since MultiRunner streams output (probe_setup
    doesn't)."""

    class _Stdout:
        def __init__(self, lines: list[bytes]) -> None:
            self._lines = list(lines)

        async def readline(self) -> bytes:
            if self._lines:
                return self._lines.pop(0)
            return b""

    def __init__(self, lines: list[bytes], returncode: int = 0) -> None:
        self.stdout = FakeProc._Stdout(lines)
        self.returncode = returncode
        self.killed = False
        self.wait_calls = 0

    async def wait(self) -> int:
        self.wait_calls += 1
        return self.returncode

    def kill(self) -> None:
        self.killed = True


def exec_returning(lines: list[bytes], returncode: int = 0):
    """Build a fake exec_fn whose spawned process yields `lines` then `rc`."""

    async def fake_exec(*args, **kwargs):
        return FakeProc(lines, returncode)

    return fake_exec


async def test_concurrency_cap_respected() -> None:
    """5 commands, limit=2: track the max number of fakes simultaneously
    "running" via an event-controlled fake — never more than 2 at once."""
    concurrent = 0
    max_concurrent = 0
    release = asyncio.Event()

    class GatedProc:
        def __init__(self) -> None:
            nonlocal concurrent, max_concurrent
            concurrent += 1
            max_concurrent = max(max_concurrent, concurrent)
            self.stdout = self
            self._done = False
            self.returncode = 0

        async def readline(self) -> bytes:
            if self._done:
                return b""
            await release.wait()
            self._done = True
            nonlocal concurrent
            concurrent -= 1
            return b""

        async def wait(self) -> int:
            return 0

    async def fake_exec(*args, **kwargs):
        return GatedProc()

    commands = {f"h{i}": ["cmd"] for i in range(5)}
    runner = MultiRunner(commands, limit=2, exec_fn=fake_exec)
    task = asyncio.create_task(runner.run(lambda name: None))
    # Let the first wave of coroutines spawn and hit the gate.
    for _ in range(10):
        await asyncio.sleep(0)
    assert concurrent == 2
    release.set()
    await task
    assert max_concurrent == 2


async def test_state_transitions_done_and_failed_by_rc() -> None:
    runner = MultiRunner(
        {"ok": ["true"]}, limit=4, exec_fn=exec_returning([], 0)
    )
    events: list[str] = []
    await runner.run(events.append)
    assert runner.runs["ok"].state == "done"
    assert runner.runs["ok"].rc == 0
    assert runner.runs["ok"].started is not None
    assert runner.runs["ok"].finished is not None
    assert runner.runs["ok"].elapsed(runner.runs["ok"].finished) == (
        runner.runs["ok"].finished - runner.runs["ok"].started
    )

    runner2 = MultiRunner(
        {"bad": ["false"]}, limit=4, exec_fn=exec_returning([], 7)
    )
    await runner2.run(lambda name: None)
    assert runner2.runs["bad"].state == "failed"
    assert runner2.runs["bad"].rc == 7


async def test_queued_before_run() -> None:
    runner = MultiRunner({"a": ["cmd"]}, limit=4, exec_fn=exec_returning([], 0))
    assert runner.runs["a"].state == "queued"
    assert runner.runs["a"].elapsed(123.0) is None


async def test_lines_streamed_and_on_update_fired() -> None:
    lines = [b"one\n", b"two\n"]
    runner = MultiRunner(
        {"h": ["cmd"]}, limit=4, exec_fn=exec_returning(lines, 0)
    )
    updates: list[str] = []
    await runner.run(updates.append)
    assert runner.runs["h"].lines == ["one", "two"]
    # on_update fired at least once per appended line plus state changes.
    assert updates.count("h") >= len(lines)


async def test_line_cap_at_5000_drops_oldest() -> None:
    total = 5005
    lines = [f"line{i}\n".encode() for i in range(total)]
    runner = MultiRunner(
        {"h": ["cmd"]}, limit=4, exec_fn=exec_returning(lines, 0)
    )
    await runner.run(lambda name: None)
    got = runner.runs["h"].lines
    assert len(got) == 5000
    assert got[0] == "line5"
    assert got[-1] == f"line{total - 1}"


async def test_spawn_failure_never_raises() -> None:
    async def raising_exec(*args, **kwargs):
        raise OSError("no such file")

    runner = MultiRunner({"h": ["cmd"]}, limit=4, exec_fn=raising_exec)
    await runner.run(lambda name: None)
    run = runner.runs["h"]
    assert run.state == "failed"
    assert run.rc is None
    assert len(run.lines) == 1
    assert "OSError" in run.lines[0]
    assert "no such file" in run.lines[0]


async def test_midstream_exception_marks_failed_kills_reaps_and_run_returns() -> None:
    """A generic exception mid-stream (readline/wait/on_update — modeled
    here as readline() raising) must never leak out of run(): the host
    ends "failed" with the exception text as its log line, the child is
    killed + reaped, run() returns normally, and other hosts are
    unaffected."""

    class RaisingProc:
        def __init__(self) -> None:
            self.stdout = self
            self.returncode = None
            self.killed = False
            self.wait_calls = 0

        async def readline(self) -> bytes:
            raise RuntimeError("boom mid-stream")

        def kill(self) -> None:
            self.killed = True
            self.returncode = -9

        async def wait(self) -> int:
            self.wait_calls += 1
            return -9

    bad_proc = RaisingProc()

    async def dispatching_exec(*args, **kwargs):
        name = args[0]
        if name == "bad":
            return bad_proc
        return FakeProc([b"ok\n"], 0)

    runner = MultiRunner(
        {"bad": ["bad"], "good": ["good"]}, limit=4, exec_fn=dispatching_exec
    )
    updates: list[str] = []
    await runner.run(updates.append)

    bad_run = runner.runs["bad"]
    assert bad_run.state == "failed"
    assert bad_run.rc is None
    assert len(bad_run.lines) == 1
    assert "RuntimeError" in bad_run.lines[0]
    assert "boom mid-stream" in bad_run.lines[0]
    assert bad_proc.killed is True
    assert bad_proc.wait_calls >= 1

    good_run = runner.runs["good"]
    assert good_run.state == "done"
    assert good_run.rc == 0
    assert good_run.lines == ["ok"]


async def test_cancel_kills_running_reaps_and_marks_cancelled() -> None:
    started = asyncio.Event()

    class HangingProc:
        def __init__(self) -> None:
            self.killed = False
            self.wait_calls = 0
            self.stdout = self
            self.returncode = None

        async def readline(self) -> bytes:
            started.set()
            await asyncio.sleep(10)
            return b""  # pragma: no cover - killed before this resolves

        def kill(self) -> None:
            self.killed = True
            self.returncode = -9

        async def wait(self) -> int:
            self.wait_calls += 1
            return -9

    proc = HangingProc()

    async def fake_exec(*args, **kwargs):
        return proc

    runner = MultiRunner({"h": ["cmd"]}, limit=4, exec_fn=fake_exec)
    task = asyncio.create_task(runner.run(lambda name: None))
    await asyncio.wait_for(started.wait(), timeout=5)
    runner.cancel()
    await asyncio.wait_for(task, timeout=5)
    assert proc.killed is True
    assert proc.wait_calls >= 1
    assert runner.runs["h"].state == "cancelled"


async def test_cancel_marks_queued_as_cancelled() -> None:
    """limit=1 with 2 commands: the second is still queued when cancel()
    fires before the semaphore ever admits it."""
    started = asyncio.Event()
    release = asyncio.Event()

    class BlockingProc:
        def __init__(self) -> None:
            self.stdout = self
            self.returncode = 0
            self.killed = False

        async def readline(self) -> bytes:
            started.set()
            await release.wait()
            return b""

        async def wait(self) -> int:
            return 0

        def kill(self) -> None:
            self.killed = True

    async def fake_exec(*args, **kwargs):
        return BlockingProc()

    runner = MultiRunner(
        {"first": ["cmd"], "second": ["cmd"]}, limit=1, exec_fn=fake_exec
    )
    task = asyncio.create_task(runner.run(lambda name: None))
    await asyncio.wait_for(started.wait(), timeout=5)
    assert runner.runs["second"].state == "queued"
    runner.cancel()
    release.set()
    await asyncio.wait_for(task, timeout=5)
    assert runner.runs["second"].state == "cancelled"
    assert runner.runs["second"].rc is None


async def test_insertion_order_matches_commands() -> None:
    commands = {"zeta": ["cmd"], "alpha": ["cmd"], "mid": ["cmd"]}
    runner = MultiRunner(commands, limit=4, exec_fn=exec_returning([], 0))
    assert list(runner.runs.keys()) == ["zeta", "alpha", "mid"]


async def test_run_cancelled_externally_kills_and_reaps() -> None:
    """If the task running MultiRunner.run() is itself cancelled (not via
    runner.cancel()), live children must still be killed + reaped before the
    CancelledError propagates — the probe_setup discipline."""
    started = asyncio.Event()

    class HangingProc:
        def __init__(self) -> None:
            self.killed = False
            self.wait_calls = 0
            self.stdout = self
            self.returncode = None

        async def readline(self) -> bytes:
            started.set()
            await asyncio.sleep(10)
            return b""  # pragma: no cover

        def kill(self) -> None:
            self.killed = True
            self.returncode = -9

        async def wait(self) -> int:
            self.wait_calls += 1
            return -9

    proc = HangingProc()

    async def fake_exec(*args, **kwargs):
        return proc

    runner = MultiRunner({"h": ["cmd"]}, limit=4, exec_fn=fake_exec)
    task = asyncio.create_task(runner.run(lambda name: None))
    await asyncio.wait_for(started.wait(), timeout=5)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert proc.killed is True
    assert proc.wait_calls >= 1


def test_host_run_elapsed() -> None:
    hr = HostRun(name="x", state="queued")
    assert hr.elapsed(10.0) is None
    hr.started = 5.0
    assert hr.elapsed(10.0) == 5.0
    hr.finished = 8.0
    assert hr.elapsed(1000.0) == 3.0
