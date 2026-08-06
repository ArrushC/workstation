"""Click entry point. Bare invocation will launch the Textual app (later phase)."""

import click

from workstation_tui import __version__


@click.group(invoke_without_command=True)
@click.version_option(__version__, prog_name="workstation")
@click.pass_context
def main(ctx: click.Context) -> None:
    """Workstation control panel — TUI + headless subcommands."""
    if ctx.invoked_subcommand is None:
        click.echo("workstation: the TUI arrives in a later phase — see --help.")
