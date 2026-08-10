import subprocess
from pathlib import Path

from workstation_tui.core.chezmoi import (
    apply_command,
    diff_command,
    parse_status_text,
    read_status,
    update_command,
)

SAMPLE = """\
MM .claude/settings.json
 A .config/newfile
DA .config/oldname
this line has no status code
"""


def test_parse_status_text() -> None:
    changes, errors = parse_status_text(SAMPLE)
    assert [(c.code, c.path) for c in changes] == [
        ("MM", ".claude/settings.json"),
        (" A", ".config/newfile"),
        ("DA", ".config/oldname"),
    ]
    assert len(errors) == 1


def test_read_status_success() -> None:
    def fake_run(cmd, **kwargs):
        assert cmd == ["chezmoi", "status"]
        return subprocess.CompletedProcess(cmd, 0, stdout=SAMPLE, stderr="")
    changes, errors = read_status(run=fake_run)
    assert len(changes) == 3


def test_read_status_never_raises() -> None:
    def fake_run(cmd, **kwargs):
        raise FileNotFoundError("chezmoi")
    changes, errors = read_status(run=fake_run)
    assert changes == []
    assert "chezmoi status failed" in errors[0]


def test_command_builders() -> None:
    assert diff_command() == ["chezmoi", "diff"]
    assert apply_command() == ["chezmoi", "apply", "--force"]
    assert update_command() == ["chezmoi", "update", "--force"]


def test_target_diff_success_and_failure() -> None:
    from workstation_tui.core.chezmoi import re_add_command, target_diff

    def ok_run(cmd, **kwargs):
        assert cmd == ["chezmoi", "diff", str(Path.home() / ".zshrc")]
        return subprocess.CompletedProcess(cmd, 0, stdout="-old\n+new\n", stderr="")

    text, err = target_diff(".zshrc", run=ok_run)
    assert err is None and "+new" in text

    def bad_run(cmd, **kwargs):
        raise FileNotFoundError("chezmoi")

    text, err = target_diff(".zshrc", run=bad_run)
    assert text == "" and "chezmoi diff failed" in err
    assert re_add_command(".zshrc") == ["chezmoi", "re-add", str(Path.home() / ".zshrc")]


def test_target_paths_absolutized_against_home() -> None:
    from workstation_tui.core.chezmoi import re_add_command, target_diff

    captured = {}

    def run(cmd, **kwargs):
        captured["cmd"] = cmd
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    target_diff(".claude/settings.json", run=run)
    assert captured["cmd"][2] == str(Path.home() / ".claude/settings.json")
    assert re_add_command(".claude/settings.json")[2] == str(
        Path.home() / ".claude/settings.json"
    )


def test_apply_target_command_absolutized_and_forced() -> None:
    from workstation_tui.core.chezmoi import apply_target_command

    assert apply_target_command(".zshrc") == [
        "chezmoi", "apply", "--force", str(Path.home() / ".zshrc"),
    ]
    assert apply_target_command(".claude/settings.json") == [
        "chezmoi", "apply", "--force", str(Path.home() / ".claude/settings.json"),
    ]
