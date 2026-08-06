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
