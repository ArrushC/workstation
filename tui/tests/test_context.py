import json
import subprocess
from pathlib import Path

from workstation_tui.core.context import detect_context


def fake_run_factory(group: str | None, fail: bool = False):
    def fake_run(cmd, **kwargs):
        if fail:
            raise FileNotFoundError(cmd[0])
        data = {"group": group} if group else {}
        return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(data), stderr="")
    return fake_run


def which_all(name: str) -> str:
    return f"/usr/bin/{name}"


def which_none(name: str) -> None:
    return None


def test_dev_linux_wsl(tmp_path: Path) -> None:
    pv = tmp_path / "version"
    pv.write_text("Linux version 6.6.87.2-microsoft-standard-WSL2 ...")
    ctx = detect_context(
        which=which_all, run=fake_run_factory("dev_machine"),
        proc_version=pv, platform="linux",
    )
    assert ctx.os == "linux"
    assert ctx.is_wsl is True
    assert ctx.group == "dev_machine"
    assert ctx.mode == "dev"
    assert ctx.has_make is True


def test_prod_defaults_when_group_unknown(tmp_path: Path) -> None:
    pv = tmp_path / "version"
    pv.write_text("Linux version 5.14.0-elrepo ...")
    ctx = detect_context(
        which=which_none, run=fake_run_factory(None, fail=True),
        proc_version=pv, platform="linux",
    )
    assert ctx.group is None
    assert ctx.mode == "prod"  # unknown group defaults to the safe scope
    assert ctx.is_wsl is False
    assert ctx.has_sudo is False


def test_windows(tmp_path: Path) -> None:
    ctx = detect_context(
        which=which_all, run=fake_run_factory("dev_machine"),
        proc_version=tmp_path / "absent", platform="win32",
    )
    assert ctx.os == "windows"
    assert ctx.is_wsl is False
