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


def test_group_none_when_chezmoi_fails(tmp_path: Path) -> None:
    def run_rc1(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="boom")
    ctx = detect_context(which=which_all, run=run_rc1,
                         proc_version=tmp_path / "absent", platform="linux")
    assert ctx.group is None
    assert ctx.mode == "prod"


def test_group_none_on_malformed_json(tmp_path: Path) -> None:
    def run_garbage(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, stdout="not json{", stderr="")
    ctx = detect_context(which=which_all, run=run_garbage,
                         proc_version=tmp_path / "absent", platform="linux")
    assert ctx.group is None


def test_group_none_on_non_string_group(tmp_path: Path) -> None:
    def run_int_group(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, stdout='{"group": 7}', stderr="")
    ctx = detect_context(which=which_all, run=run_int_group,
                         proc_version=tmp_path / "absent", platform="linux")
    assert ctx.group is None
