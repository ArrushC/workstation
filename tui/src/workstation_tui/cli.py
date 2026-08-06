"""Click entry point. Bare invocation launches the Textual app (TTY-gated); subcommands run headless."""

import json as _json
import sys
from pathlib import Path

import click

from workstation_tui import __version__
from workstation_tui.core.chezmoi import (
    apply_command,
    diff_command,
    read_status,
    update_command,
)
from workstation_tui.core.context import detect_context
from workstation_tui.core.hostsfile import read_hosts
from workstation_tui.core.makeiface import (
    check_updates_command,
    doctor_command,
    provision_command,
)
from workstation_tui.core.proc import run_passthrough
from workstation_tui.core.summary import gather_summary
from workstation_tui.repo import find_repo_root


def _is_interactive() -> bool:
    # Seam: CliRunner swaps sys.stdin/sys.stdout during invoke, so the TTY
    # check must read them at call time AND be patchable as
    # cli._is_interactive in tests. Both streams must be TTYs — LinuxDriver
    # reads sys.__stdin__ for input, so a redirected stdin (e.g.
    # `workstation < /dev/null` on a real terminal) would launch a
    # keyboard-deaf UI if only stdout were checked.
    return sys.stdin.isatty() and sys.stdout.isatty()


def _launch_tui() -> None:
    # Lazy import: headless subcommands never pay the textual import.
    from workstation_tui.app.app import WorkstationApp

    WorkstationApp().run()


@click.group(invoke_without_command=True)
@click.version_option(__version__, prog_name="workstation")
@click.pass_context
def main(ctx: click.Context) -> None:
    """Workstation control panel — TUI + headless subcommands."""
    if ctx.invoked_subcommand is None:
        if not _is_interactive():
            click.echo(
                "workstation: the TUI needs a terminal — "
                "see --help for headless commands.",
                err=True,
            )
            sys.exit(1)
        _launch_tui()


def _require_repo() -> Path:
    root = find_repo_root()
    if root is None:
        click.echo(
            "workstation: cannot locate the workstation repo "
            "(set WORKSTATION_REPO or clone to ~/.local/share/chezmoi)",
            err=True,
        )
        sys.exit(2)
    return root


@main.command()
@click.option("--json", "as_json", is_flag=True, help="Machine-readable output.")
def status(as_json: bool) -> None:
    """Dashboard summary: tools, dotfiles, hosts."""
    s = gather_summary(_require_repo())
    if as_json:
        click.echo(s.model_dump_json())
        return
    c = s.context
    click.echo(f"host     {c.os} · group={c.group or '?'} · mode={c.mode}"
               f"{' · WSL' if c.is_wsl else ''}")
    click.echo(f"tools    {s.tools_fresh}/{s.tools_total} fresh · "
               f"{s.tools_stale} stale · {s.tools_missing} missing")
    click.echo(f"dotfiles {s.dotfiles_pending} pending")
    click.echo(f"hosts    {s.hosts_total} ({s.hosts_dev} dev · {s.hosts_prod} prod)")
    for err in (*s.inventory_errors, *s.dotfiles_errors, *s.hosts_errors):
        click.echo(f"warning  {err}", err=True)


@main.group()
def hosts() -> None:
    """Fleet host inventory (hosts.conf)."""


@hosts.command(name="list")
@click.option("--json", "as_json", is_flag=True, help="Machine-readable output.")
def hosts_list(as_json: bool) -> None:
    """List hosts.conf entries."""
    entries, errors = read_hosts(_require_repo())
    if as_json:
        click.echo(_json.dumps([e.model_dump() for e in entries]))
    else:
        for e in entries:
            click.echo(f"{e.name:<18} {e.address:<16} {e.user:<20} {e.group}")
    for err in errors:
        click.echo(f"warning  {err}", err=True)


@main.command()
def doctor() -> None:
    """Run the repo doctor (make doctor) and exit with its status."""
    ctx = detect_context()
    sys.exit(run_passthrough(doctor_command(_require_repo(), ctx.mode)))


@main.command()
def updates() -> None:
    """Check every version pin against upstream (make check-updates)."""
    ctx = detect_context()
    sys.exit(run_passthrough(check_updates_command(_require_repo(), ctx.mode)))


@main.command()
@click.argument("tools", nargs=-1, required=True)
@click.option("--mode", type=click.Choice(["dev", "prod"]), default=None,
              help="Override the detected MODE.")
def provision(tools: tuple[str, ...], mode: str | None) -> None:
    """Install/refresh one or more tools via make (sudo may prompt on dev)."""
    for tool in tools:
        if "=" in tool:
            raise click.UsageError(
                f"{tool!r} is not a tool name (use --mode for MODE; "
                "make variables cannot be set here)"
            )
    resolved = mode or detect_context().mode
    sys.exit(run_passthrough(provision_command(_require_repo(), list(tools), resolved)))


@main.group()
def dotfiles() -> None:
    """chezmoi workflow: status, diff, apply, update."""


@dotfiles.command(name="status")
def dotfiles_status() -> None:
    """Pending chezmoi changes."""
    pending, errors = read_status()
    if not pending and not errors:
        click.echo("dotfiles in sync")
    for p in pending:
        click.echo(f"{p.code} {p.path}")
    for err in errors:
        click.echo(f"warning  {err}", err=True)


@dotfiles.command(name="diff")
def dotfiles_diff() -> None:
    """Full chezmoi diff."""
    sys.exit(run_passthrough(diff_command()))


@dotfiles.command(name="apply")
def dotfiles_apply() -> None:
    """Show the diff, confirm, then apply with --force (prompts never fire)."""
    rc = run_passthrough(diff_command())
    if rc != 0:
        sys.exit(rc)
    if not click.confirm("Apply these changes?"):
        raise SystemExit(1)
    sys.exit(run_passthrough(apply_command()))


@dotfiles.command(name="update")
def dotfiles_update() -> None:
    """Pull the source repo and apply (chezmoi update --force)."""
    if not click.confirm("Pull the dotfiles repo and apply to this host?"):
        raise SystemExit(1)
    sys.exit(run_passthrough(update_command()))
