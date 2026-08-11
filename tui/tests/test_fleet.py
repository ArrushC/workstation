import asyncio
from pathlib import Path

import pytest

from workstation_tui.core.fleet import (
    manage_hosts_add_command,
    manage_hosts_remove_command,
    probe_all,
    probe_host,
    probe_setup,
    push_command,
)
from workstation_tui.core.models import HostEntry

E = HostEntry(name="a", address="127.0.0.1", user="u", group="dev_machine")


async def test_probe_host_up_and_down() -> None:
    server = await asyncio.start_server(lambda r, w: w.close(), "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    assert await probe_host("127.0.0.1", port=port, timeout=2.0) == "up"
    server.close()
    await server.wait_closed()
    assert await probe_host("127.0.0.1", port=1, timeout=0.5) == "down"


async def test_probe_all_uses_injected_probe() -> None:
    """down hosts short-circuit to (\"down\", None) without ever running
    setup_probe; up hosts run setup_probe and carry its result."""

    setup_calls: list[str] = []

    async def fake_probe(address, *, port=22, timeout=3.0):
        return "up" if address == "127.0.0.1" else "down"

    async def fake_setup(entry, *, timeout=6.0, exec_fn=None):
        setup_calls.append(entry.name)
        return "setup"

    entries = [E, HostEntry(name="b", address="10.0.0.9", user="u", group="prod_machine")]
    result = await probe_all(entries, probe=fake_probe, setup_probe=fake_setup)
    assert result == {"a": ("up", "setup"), "b": ("down", None)}
    # setup_probe must run only for the reachable host — an ssh attempt
    # into an address that isn't even TCP-reachable would just re-derive
    # "down" the slow way.
    assert setup_calls == ["a"]


# -- probe_setup: two-stage ssh state machine -----------------------------


class _FakeProc:
    """Fake asyncio.subprocess.Process: wait() resolves immediately."""

    def __init__(self, returncode: int) -> None:
        self.returncode = returncode
        self.killed = False

    async def wait(self) -> int:
        return self.returncode

    def kill(self) -> None:
        self.killed = True


class _HangingProc:
    """Fake process whose wait() never resolves within any sane timeout —
    until kill() is called, mirroring a real subprocess (SIGKILL makes a
    SUBSEQUENT wait() resolve immediately instead of hanging). Finding 2's
    reap-after-kill calls wait() a second time post-kill(); without this
    kill-awareness the fake would hang the test for the full 10s instead of
    exercising the reap."""

    def __init__(self) -> None:
        self.killed = False
        self.wait_calls = 0

    async def wait(self) -> int:
        self.wait_calls += 1
        if self.killed:
            return -9
        await asyncio.sleep(10)
        return 0  # pragma: no cover - never reached under timeout=0.1

    def kill(self) -> None:
        self.killed = True


async def test_probe_setup_argv_shape() -> None:
    captured: dict = {}

    async def fake_exec(*args, **kwargs):
        captured["args"] = args
        captured["kwargs"] = kwargs
        return _FakeProc(0)

    await probe_setup(E, exec_fn=fake_exec)
    # Finding 3: "--" precedes the destination (hosts.conf entries bypass
    # host-form validation, so a "-"-leading user/address would otherwise
    # be option-parsed by ssh) — the remote command follows the destination,
    # matching app.py's ssh_to established `["ssh", "--", dest]` pattern.
    assert captured["args"] == (
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "--",
        "u@127.0.0.1", "test", "-d", ".local/share/chezmoi",
    )
    assert captured["kwargs"]["stdout"] == asyncio.subprocess.DEVNULL
    assert captured["kwargs"]["stderr"] == asyncio.subprocess.DEVNULL


def _exec_returning(rc: int):
    """Build a fake exec_fn whose process resolves with the given rc."""

    async def fake_exec(*args, **kwargs):
        return _FakeProc(rc)

    return fake_exec


async def test_probe_setup_state_machine() -> None:
    assert await probe_setup(E, exec_fn=_exec_returning(0)) == "setup"
    assert await probe_setup(E, exec_fn=_exec_returning(1)) == "missing"
    assert await probe_setup(E, exec_fn=_exec_returning(255)) == "ssh-failed"


async def test_probe_setup_exception_never_raises() -> None:
    async def raising_exec(*args, **kwargs):
        raise OSError("no such host")

    assert await probe_setup(E, exec_fn=raising_exec) == "ssh-failed"


async def test_probe_setup_timeout_kills_child() -> None:
    proc = _HangingProc()

    async def fake_exec(*args, **kwargs):
        return proc

    result = await probe_setup(E, timeout=0.1, exec_fn=fake_exec)
    assert result == "ssh-failed"
    assert proc.killed is True
    # Finding 2: the timeout branch also reaps (a second wait() after
    # kill()), not just kills — no zombie left behind.
    assert proc.wait_calls == 2


async def test_probe_setup_cancelled_kills_and_reaps_child() -> None:
    """Finding 2: probe_setup leaked the ssh child on cancellation —
    asyncio.CancelledError is a BaseException, so neither the inner
    TimeoutError handler nor the outer `except Exception` caught it, and
    exclusive-group cancellation (every FleetPanel refresh restarts the
    probe worker) is routine, not exceptional. The fix must (a) kill + reap
    the child and (b) still let the CancelledError propagate — swallowing
    it would break the worker-cancellation contract callers rely on."""

    class _CancellingProc:
        def __init__(self) -> None:
            self.killed = False
            self.wait_calls = 0

        async def wait(self) -> int:
            self.wait_calls += 1
            if self.wait_calls == 1:
                raise asyncio.CancelledError()
            return 0  # the reap call, post-kill

        def kill(self) -> None:
            self.killed = True

    proc = _CancellingProc()

    async def fake_exec(*args, **kwargs):
        return proc

    with pytest.raises(asyncio.CancelledError):
        await probe_setup(E, exec_fn=fake_exec)
    assert proc.killed is True
    assert proc.wait_calls == 2  # first wait() raised Cancelled, second is the reap


async def test_probe_all_include_setup_false_skips_stage_two() -> None:
    """Finding 4 (ssh probe storm): include_setup=False must never invoke
    setup_probe at all, even for a reachable host — the caller (FleetPanel,
    gated on panel visibility) uses this to avoid escalating to ssh on
    every refresh from panels other than Fleet."""
    setup_calls: list[str] = []

    async def fake_probe(address, *, port=22, timeout=3.0):
        return "up"

    async def fake_setup(entry, *, timeout=6.0, exec_fn=None):
        setup_calls.append(entry.name)
        return "setup"

    result = await probe_all(
        [E], probe=fake_probe, setup_probe=fake_setup, include_setup=False
    )
    assert result == {"a": ("up", None)}
    assert setup_calls == []


def test_push_command(tmp_path: Path) -> None:
    cmd = push_command(tmp_path, "build-01")
    assert cmd[-2:] == ["--name", "build-01"]
    assert cmd[0] == str(tmp_path / "scripts" / "update-hosts.sh")


def test_manage_hosts_commands(tmp_path: Path) -> None:
    add = manage_hosts_add_command(tmp_path, E)
    assert add[0] == "bash" and "--add" in add and "--skip-confirm" in add
    assert add[add.index("--name") + 1] == "a"
    rm = manage_hosts_remove_command(tmp_path, "a", os_name="windows")
    assert rm[0] == "powershell.exe" and "-Remove" in rm and "-SkipConfirm" in rm
