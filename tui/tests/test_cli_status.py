import json
from pathlib import Path

from click.testing import CliRunner

from workstation_tui.cli import main
from workstation_tui.repo import find_repo_root


def test_find_repo_root_env_override(tmp_path: Path, monkeypatch) -> None:
    (tmp_path / "makefile").mkdir()
    (tmp_path / "makefile" / "Makefile").touch()
    monkeypatch.setenv("WORKSTATION_REPO", str(tmp_path))
    assert find_repo_root() == tmp_path


def test_find_repo_root_rejects_bogus_env(tmp_path: Path, monkeypatch) -> None:
    # A set-but-invalid override must fail loudly (None), never silently
    # fall through to the default checkout.
    monkeypatch.setenv("WORKSTATION_REPO", str(tmp_path / "nope"))
    assert find_repo_root() is None


def test_require_repo_exit_2(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(tmp_path / "nope"))
    result = CliRunner().invoke(main, ["status"])
    assert result.exit_code == 2
    assert "cannot locate" in result.output


def test_status_json(repo_root: Path, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    result = CliRunner().invoke(main, ["status", "--json"])
    assert result.exit_code == 0, result.output
    data = json.loads(result.output)
    assert data["tools_total"] > 90
    assert "dotfiles_pending" in data


def test_status_human(repo_root: Path, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    result = CliRunner().invoke(main, ["status"])
    assert result.exit_code == 0, result.output
    assert "tools" in result.output
    assert "hosts" in result.output


def test_hosts_list_json(repo_root: Path, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    result = CliRunner().invoke(main, ["hosts", "list", "--json"])
    assert result.exit_code == 0, result.output
    data = json.loads(result.output)
    assert isinstance(data, list) and len(data) >= 2
    assert {"name", "address", "user", "group"} <= set(data[0])


def test_hosts_list_human(repo_root: Path, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    result = CliRunner().invoke(main, ["hosts", "list"])
    assert result.exit_code == 0
    assert "dev_machine" in result.output
