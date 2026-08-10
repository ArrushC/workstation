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
