import subprocess
import sys

from workstation_tui.core.proc import run_passthrough


def test_run_passthrough_returns_exit_code() -> None:
    rc = run_passthrough([sys.executable, "-c", "import sys; sys.exit(3)"])
    assert rc == 3


def test_run_passthrough_scrubs_make_env(monkeypatch) -> None:
    monkeypatch.setenv("MAKEFLAGS", "w -j8 --jobserver-auth=3,4")
    rc = run_passthrough(
        [sys.executable, "-c",
         "import os, sys; sys.exit(1 if 'MAKEFLAGS' in os.environ else 0)"]
    )
    assert rc == 0


def test_run_passthrough_missing_binary() -> None:
    rc = run_passthrough(["definitely-not-a-real-binary-xyz"])
    assert rc == 127


def test_run_passthrough_not_executable(tmp_path) -> None:
    script = tmp_path / "notexec"
    script.write_text("#!/bin/sh\nexit 0\n")
    script.chmod(0o644)
    rc = run_passthrough([str(script)])
    assert rc == 126
