import shutil
import subprocess
from pathlib import Path
from unittest.mock import MagicMock

import pytest

from workstation_tui.core.makeiface import parse_inventory, read_inventory

SAMPLE = """\
scope|fzf|0.74.2
user|glances|latest
bespoke|python-env|3.14.6-2381415
bespoke|docker-engine|-
garbage line without pipes
too|many|pipes|here
"""


def test_parse_inventory_rows_and_errors() -> None:
    rows, errors = parse_inventory(SAMPLE)
    assert [(r.kind, r.name, r.version) for r in rows] == [
        ("scope", "fzf", "0.74.2"),
        ("user", "glances", "latest"),
        ("bespoke", "python-env", "3.14.6-2381415"),
        ("bespoke", "docker-engine", "-"),
    ]
    assert len(errors) == 2
    assert "garbage line without pipes" in errors[0]


@pytest.mark.skipif(shutil.which("make") is None, reason="make not on PATH")
def test_read_inventory_against_real_repo(repo_root: Path) -> None:
    rows, errors = read_inventory(repo_root, mode="prod")
    assert errors == []
    names = {r.name for r in rows}
    assert {"fzf", "chezmoi", "python-env"} <= names
    assert len(rows) > 90


def test_read_inventory_timeout_returns_error_tuple(repo_root: Path, monkeypatch) -> None:
    """Verify timeout exception is caught and returned as error tuple."""
    def mock_run(*args, **kwargs):
        raise subprocess.TimeoutExpired("make", timeout=30)

    monkeypatch.setattr(subprocess, "run", mock_run)
    rows, errors = read_inventory(repo_root, mode="prod")
    assert rows == []
    assert len(errors) == 1
    assert "timeout after 30s" in errors[0]


def test_read_inventory_missing_make_returns_error_tuple(repo_root: Path, monkeypatch) -> None:
    """Verify OSError (e.g., missing make binary) is caught and returned as error tuple."""
    def mock_run(*args, **kwargs):
        raise FileNotFoundError("make: command not found")

    monkeypatch.setattr(subprocess, "run", mock_run)
    rows, errors = read_inventory(repo_root, mode="prod")
    assert rows == []
    assert len(errors) == 1
    assert "make inventory failed:" in errors[0]


@pytest.mark.skipif(shutil.which("make") is None, reason="make not on PATH")
def test_read_inventory_scrubs_inherited_makeflags(repo_root: Path, monkeypatch) -> None:
    """Verify that inherited MAKEFLAGS/MFLAGS/MAKELEVEL are scrubbed from subprocess env.

    When a TUI/CLI process is launched from inside another make recipe with
    jobserver-auth flags, GNU make's --no-print-directory is ignored and
    directory-announcement lines corrupt parsed inventory rows. Verify that
    read_inventory succeeds even with a polluted environment.
    """
    # Simulate a polluted environment as if launched from a make recipe
    monkeypatch.setenv("MAKEFLAGS", "w -j8 --jobserver-auth=3,4")
    monkeypatch.setenv("MFLAGS", "-j8")
    monkeypatch.setenv("MAKELEVEL", "2")

    rows, errors = read_inventory(repo_root, mode="prod")
    assert errors == []
    names = {r.name for r in rows}
    assert {"fzf", "chezmoi", "python-env"} <= names
    assert len(rows) > 90
