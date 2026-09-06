from pathlib import Path

import pytest

# tui/tests/conftest.py -> parents[0]=tests, [1]=tui, [2]=repo root
_REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="session")
def repo_root() -> Path:
    return _REPO_ROOT


@pytest.fixture(autouse=True)
def _no_real_notifier(monkeypatch):
    # Tests that don't inject a notifier must never reach the real
    # ~/.claude/notify.sh (present on dev machines — real OS toasts).
    import workstation_tui.app.app as app_mod

    monkeypatch.setattr(app_mod, "_default_notifier", lambda title, msg: None)


@pytest.fixture(autouse=True)
def _updates_cache_in_tmp(tmp_path, monkeypatch):
    # Same shape as _no_real_notifier above: a test that doesn't pass
    # updates_cache_path explicitly must never read/write the real
    # ~/.cache/workstation-tui/updates.json (mirrors health_cache_path's
    # per-test isolation, which every WorkstationApp() call already gets
    # for free since tests that care always pass health_cache_path=tmp_path
    # explicitly — updates_cache_path has no such universal habit yet, so
    # this fixture patches the module-level default resolver instead).
    import workstation_tui.app.app as app_mod

    monkeypatch.setattr(app_mod, "_default_updates_cache_path", lambda: tmp_path / "updates.json")


@pytest.fixture(autouse=True)
def _history_root_in_tmp(tmp_path, monkeypatch):
    # Same shape as _updates_cache_in_tmp above: a test that doesn't pass
    # history_store explicitly must never read/write the real
    # ~/.cache/workstation-tui/history — patches the module-level default
    # resolver so WorkstationApp.__init__'s late-bound
    # `_default_history_root()` call picks up the tmp path.
    import workstation_tui.app.app as app_mod

    monkeypatch.setattr(app_mod, "_default_history_root", lambda: tmp_path / "history")
