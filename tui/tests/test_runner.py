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


async def test_busy_true_during_spawn_window() -> None:
    r = Runner()
    task = asyncio.create_task(
        r.run([sys.executable, "-c", "import time; time.sleep(2)"], lambda _: None)
    )
    await asyncio.sleep(0)  # run() has started but spawn may not have completed
    assert r.busy is True
    with pytest.raises(TaskBusyError):
        await r.run(["bash", "-c", "true"], lambda _: None)
    r.cancel()
    result = await task
    assert result.cancelled is True


async def test_raising_callback_kills_child_and_restores_invariant() -> None:
    r = Runner()

    def bad_callback(line: str) -> None:
        raise RuntimeError("ui exploded")

    with pytest.raises(RuntimeError, match="ui exploded"):
        await r.run(["bash", "-c", "echo x; sleep 30"], bad_callback)
    assert r.busy is False
    # invariant restored: a fresh run works immediately
    lines: list[str] = []
    result = await r.run(["bash", "-c", "echo recovered"], lines.append)
    assert result.returncode == 0
    assert "recovered" in lines
