from click.testing import CliRunner

import workstation_tui.cli as cli
from workstation_tui.cli import main


def _capture(monkeypatch, rc=0):
    calls: list[list[str]] = []
    def fake_passthrough(cmd):
        calls.append(cmd)
        return rc
    monkeypatch.setattr(cli, "run_passthrough", fake_passthrough)
    return calls


def test_doctor_streams_and_exits_with_rc(repo_root, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    calls = _capture(monkeypatch, rc=1)
    result = CliRunner().invoke(main, ["doctor"])
    assert result.exit_code == 1
    assert calls[0][-2:] == ["doctor", f"MODE={cli.detect_context().mode}"]


def test_updates(repo_root, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    calls = _capture(monkeypatch)
    result = CliRunner().invoke(main, ["updates"])
    assert result.exit_code == 0
    assert "check-updates" in calls[0]


def test_provision_tools_and_mode_override(repo_root, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    calls = _capture(monkeypatch)
    result = CliRunner().invoke(main, ["provision", "fzf", "zellij", "--mode", "prod"])
    assert result.exit_code == 0
    assert calls[0][-3:] == ["fzf", "zellij", "MODE=prod"]


def test_provision_requires_tool(repo_root, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    result = CliRunner().invoke(main, ["provision"])
    assert result.exit_code != 0


def test_provision_rejects_var_assignment(repo_root, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    calls = _capture(monkeypatch)
    result = CliRunner().invoke(main, ["provision", "MODE=dev"])
    assert result.exit_code != 0
    assert "not a tool name" in result.output
    assert calls == []
