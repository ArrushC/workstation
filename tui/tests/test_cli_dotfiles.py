from click.testing import CliRunner

import workstation_tui.cli as cli
from workstation_tui.cli import main
from workstation_tui.core.models import PendingChange


def _capture(monkeypatch, rc=0):
    calls: list[list[str]] = []
    def fake_passthrough(cmd):
        calls.append(cmd)
        return rc
    monkeypatch.setattr(cli, "run_passthrough", fake_passthrough)
    return calls


def test_dotfiles_status(monkeypatch) -> None:
    monkeypatch.setattr(
        cli, "read_status",
        lambda: ([PendingChange(code="MM", path=".zshrc")], []),
    )
    result = CliRunner().invoke(main, ["dotfiles", "status"])
    assert result.exit_code == 0
    assert "MM .zshrc" in result.output


def test_dotfiles_status_clean(monkeypatch) -> None:
    monkeypatch.setattr(cli, "read_status", lambda: ([], []))
    result = CliRunner().invoke(main, ["dotfiles", "status"])
    assert result.exit_code == 0
    assert "in sync" in result.output


def test_dotfiles_diff(monkeypatch) -> None:
    calls = _capture(monkeypatch)
    result = CliRunner().invoke(main, ["dotfiles", "diff"])
    assert result.exit_code == 0
    assert calls == [["chezmoi", "diff"]]


def test_dotfiles_apply_confirmed(monkeypatch) -> None:
    calls = _capture(monkeypatch)
    result = CliRunner().invoke(main, ["dotfiles", "apply"], input="y\n")
    assert result.exit_code == 0
    assert calls == [["chezmoi", "diff"], ["chezmoi", "apply", "--force"]]


def test_dotfiles_apply_declined(monkeypatch) -> None:
    calls = _capture(monkeypatch)
    result = CliRunner().invoke(main, ["dotfiles", "apply"], input="n\n")
    assert result.exit_code == 1
    assert calls == [["chezmoi", "diff"]]  # diff shown, apply never ran


def test_dotfiles_apply_aborts_on_failed_diff(monkeypatch) -> None:
    calls = _capture(monkeypatch, rc=127)
    result = CliRunner().invoke(main, ["dotfiles", "apply"], input="y\n")
    assert result.exit_code == 127
    assert calls == [["chezmoi", "diff"]]  # apply never ran, confirm never shown


def test_dotfiles_update_confirmed(monkeypatch) -> None:
    calls = _capture(monkeypatch)
    result = CliRunner().invoke(main, ["dotfiles", "update"], input="y\n")
    assert result.exit_code == 0
    assert calls == [["chezmoi", "update", "--force"]]
