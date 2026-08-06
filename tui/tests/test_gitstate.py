import subprocess
from pathlib import Path

from workstation_tui.core.gitstate import read_git_state

PORCELAIN = """\
# branch.oid 2846240deadbeef
# branch.head main
# branch.upstream origin/main
# branch.ab +2 -1
1 .M N... 100644 100644 100644 abc def CLAUDE.md
"""


def _fake_run(stdout: str, rc: int = 0):
    def run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, rc, stdout=stdout, stderr="")
    return run


def test_parses_branch_ab_dirty(tmp_path: Path) -> None:
    state, errors = read_git_state(tmp_path, run=_fake_run(PORCELAIN))
    assert errors == []
    assert state.branch == "main"
    assert (state.ahead, state.behind) == (2, 1)
    assert state.dirty is True


def test_clean_no_upstream(tmp_path: Path) -> None:
    state, _ = read_git_state(
        tmp_path, run=_fake_run("# branch.oid x\n# branch.head main\n")
    )
    assert (state.ahead, state.behind) == (0, 0)
    assert state.dirty is False


def test_never_raises(tmp_path: Path) -> None:
    def run(cmd, **kwargs):
        raise FileNotFoundError("git")
    state, errors = read_git_state(tmp_path, run=run)
    assert state is None
    assert "git" in errors[0]


def test_real_repo(repo_root: Path) -> None:
    state, errors = read_git_state(repo_root)
    assert errors == []
    assert state.branch  # real checkout has a branch


def test_malformed_ab_line_never_raises(tmp_path: Path) -> None:
    for bad in ("# branch.ab \n", "# branch.ab +2\n", "# branch.ab +?? -??\n"):
        state, errors = read_git_state(
            tmp_path, run=_fake_run("# branch.head main\n" + bad)
        )
        assert errors == []
        assert (state.ahead, state.behind) == (0, 0)


def test_detached_head_passthrough(tmp_path: Path) -> None:
    state, _ = read_git_state(
        tmp_path, run=_fake_run("# branch.oid x\n# branch.head (detached)\n")
    )
    assert state.branch == "(detached)"
