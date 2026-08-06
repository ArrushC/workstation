from click.testing import CliRunner

from workstation_tui import __version__
from workstation_tui.cli import main


def test_version_flag() -> None:
    result = CliRunner().invoke(main, ["--version"])
    assert result.exit_code == 0
    assert __version__ in result.output


def test_bare_invocation_without_tty_errors() -> None:
    # CliRunner streams are not TTYs, so the bare command must refuse
    # cleanly instead of launching Textual.
    result = CliRunner().invoke(main, [])
    assert result.exit_code == 1
    assert "needs a terminal" in result.output


def test_bare_invocation_launches_app_on_tty(monkeypatch) -> None:
    # CliRunner swaps sys.stdin/sys.stdout during invoke, so patch the SEAM
    # (_is_interactive), never sys.stdin/sys.stdout themselves.
    import workstation_tui.cli as cli

    launched = []
    monkeypatch.setattr(cli, "_is_interactive", lambda: True)
    monkeypatch.setattr(cli, "_launch_tui", lambda: launched.append(True))
    result = CliRunner().invoke(main, [])
    assert result.exit_code == 0
    assert launched == [True]


def test_bare_invocation_stdin_redirect_refused(monkeypatch) -> None:
    # stdout a TTY but stdin not → still refuse (keyboard-deaf UI otherwise).
    #
    # NOTE: CliRunner.isolation() unconditionally rebinds sys.stdin AND
    # sys.stdout to its own _NamedTextIOWrapper objects for the duration of
    # invoke() (see click.testing.CliRunner.isolation) — patching
    # cli.sys.stdin.isatty / cli.sys.stdout.isatty on the PRE-invoke stream
    # objects has no effect once those objects are swapped out, so such a
    # patch cannot actually exercise "stdout is a TTY but stdin isn't"
    # through CliRunner. Patching the seam directly is the only way to
    # exercise this branch under CliRunner.
    import workstation_tui.cli as cli

    monkeypatch.setattr(cli, "_is_interactive", lambda: False)
    result = CliRunner().invoke(main, [])
    assert result.exit_code == 1
