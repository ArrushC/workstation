from pathlib import Path

from workstation_tui.core.models import InventoryRow, StampState
from workstation_tui.core.stamps import scan, stamp_state


def make_stamps(tmp_path: Path, names: list[str]) -> Path:
    for n in names:
        (tmp_path / n).touch()
    return tmp_path


def test_fresh_exact_match(tmp_path: Path) -> None:
    d = make_stamps(tmp_path, ["fzf-0.74.2.done"])
    assert stamp_state(d, "fzf", "0.74.2") is StampState.FRESH


def test_stale_other_version_only(tmp_path: Path) -> None:
    d = make_stamps(tmp_path, ["ast-grep-0.44.1.done"])
    assert stamp_state(d, "ast-grep", "0.45.0") is StampState.STALE


def test_missing(tmp_path: Path) -> None:
    assert stamp_state(tmp_path, "fzf", "0.74.2") is StampState.MISSING


def test_latest_pin_is_exact(tmp_path: Path) -> None:
    d = make_stamps(tmp_path, ["nb-latest.done"])
    assert stamp_state(d, "nb", "latest") is StampState.FRESH


def test_dash_version_globs(tmp_path: Path) -> None:
    # "-" rows (docker-engine, lsp-servers-<hash>, wsl-config-<hash>) can't
    # know their stamp suffix: any stamp counts as FRESH, none as MISSING.
    d = make_stamps(tmp_path, ["docker-engine.done", "lsp-servers-8f3a.done"])
    assert stamp_state(d, "docker-engine", "-") is StampState.FRESH
    assert stamp_state(d, "lsp-servers", "-") is StampState.FRESH
    assert stamp_state(d, "wsl-config", "-") is StampState.MISSING


def test_hashed_version_is_exact(tmp_path: Path) -> None:
    d = make_stamps(tmp_path, ["python-env-3.14.6-2381415.done"])
    assert stamp_state(d, "python-env", "3.14.6-2381415") is StampState.FRESH
    assert stamp_state(d, "python-env", "3.14.6-9999999") is StampState.STALE


def test_scan_maps_rows(tmp_path: Path) -> None:
    d = make_stamps(tmp_path, ["fzf-0.74.2.done"])
    rows = [
        InventoryRow(kind="scope", name="fzf", version="0.74.2"),
        InventoryRow(kind="scope", name="zellij", version="0.44.3"),
    ]
    result = scan(d, rows)
    assert [(t.name, t.state) for t in result] == [
        ("fzf", StampState.FRESH),
        ("zellij", StampState.MISSING),
    ]


def test_bespoke_basename_overrides(tmp_path: Path) -> None:
    # claude-cli/node-runtime/go-runtime rows stamp under short basenames.
    d = make_stamps(tmp_path, ["claude-latest.done", "node-26.6.0.done"])
    assert stamp_state(d, "claude-cli", "latest") is StampState.FRESH
    assert stamp_state(d, "node-runtime", "26.5.1") is StampState.STALE
    assert stamp_state(d, "go-runtime", "1.24.4") is StampState.MISSING
