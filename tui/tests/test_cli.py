from click.testing import CliRunner

from workstation_tui import __version__
from workstation_tui.cli import main


def test_version_flag() -> None:
    result = CliRunner().invoke(main, ["--version"])
    assert result.exit_code == 0
    assert __version__ in result.output


def test_bare_invocation_is_placeholder() -> None:
    result = CliRunner().invoke(main, [])
    assert result.exit_code == 0
    assert "later phase" in result.output
