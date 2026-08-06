from pathlib import Path

import pytest

# tui/tests/conftest.py -> parents[0]=tests, [1]=tui, [2]=repo root
_REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="session")
def repo_root() -> Path:
    return _REPO_ROOT
