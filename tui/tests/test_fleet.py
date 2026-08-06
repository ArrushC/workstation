import asyncio
from pathlib import Path

from workstation_tui.core.fleet import (
    manage_hosts_add_command,
    manage_hosts_remove_command,
    probe_all,
    probe_host,
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
    async def fake_probe(address, *, port=22, timeout=3.0):
        return "up" if address == "127.0.0.1" else "down"

    entries = [E, HostEntry(name="b", address="10.0.0.9", user="u", group="prod_machine")]
    result = await probe_all(entries, probe=fake_probe)
    assert result == {"a": "up", "b": "down"}


def test_push_command(tmp_path: Path) -> None:
    assert push_command(tmp_path, "build-01")[-2:] == ["--name", "build-01"]
    assert push_command(tmp_path, None)[-1].endswith("update-hosts.sh")


def test_manage_hosts_commands(tmp_path: Path) -> None:
    add = manage_hosts_add_command(tmp_path, E)
    assert add[0] == "bash" and "--add" in add and "--skip-confirm" in add
    assert add[add.index("--name") + 1] == "a"
    rm = manage_hosts_remove_command(tmp_path, "a", os_name="windows")
    assert rm[0] == "powershell.exe" and "-Remove" in rm and "-SkipConfirm" in rm
