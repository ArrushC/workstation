"""ws's command line: `ws [words]` is the palette, the rest are subcommands."""

from __future__ import annotations

import argparse
import os
import sys
import traceback

SUBCOMMANDS = ("reconcile", "open", "apply", "help", "health", "actions", "baseline", "complete")
COMPLETED = SUBCOMMANDS[:6]  # the ones a user types


def _reconcile_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="ws reconcile", description=(
        "Review each managed dotfile that differs from the repo, and record, apply, merge, edit "
        "or skip it. Without options: an fzf picker with a diff preview."))
    p.add_argument("--list", action="store_true", help="print what differs and why, then exit")
    p.add_argument("--json", action="store_true", help="the same as JSON")
    p.add_argument("--record", nargs="+", metavar="PATH", help="copy these live files into the repo (copy entries only)")
    p.add_argument("--apply", nargs="+", metavar="PATH", help="replace these live files with the repo's version")
    p.add_argument("--merge", nargs="+", metavar="PATH", help="three-way merge these (needs a baseline)")
    p.add_argument("--yes", action="store_true", help="don't ask before each change (diffs still print)")
    p.add_argument("--backups", action="store_true", help="list the backups and how to restore each file")
    return p


def _open_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="ws open", description=(
        "Open a project workspace: attach to its zellij session if it is running, resurrect it if "
        "it exited, or create it in the project with the dev layout. Windows: change to the project."))
    p.add_argument("project", nargs="?", help="a name (as listed), a session name or a path; picks when ambiguous")
    p.add_argument("--layout", help="layout for a new session (default: projects.toml, else dev)")
    p.add_argument("--editor", help="EDITOR/VISUAL inside a new session (default: projects.toml)")
    p.add_argument("--run", metavar="TASK", help="start this mise task in the layout's run pane (new sessions only)")
    p.add_argument("--cd", action="store_true", help="just change this shell to the project")
    p.add_argument("--tab", action="store_true", help="open it in a new WezTerm or Windows Terminal tab")
    p.add_argument("--list", action="store_true", help="list known workspaces and their session state")
    p.add_argument("--names", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--prefs", action="store_true", help="edit projects.toml (roots, editor, layout, startup)")
    p.add_argument("--preview", action="store_true", help=argparse.SUPPRESS)
    return p


def _apply_parser() -> argparse.ArgumentParser:
    return argparse.ArgumentParser(prog="ws apply", description=(
        "Apply the repo's dotfiles to this home (wsa). A file the apply would overwrite that was "
        "edited here, or that differs with no baseline to tell, is shown with its diff first, and "
        "ws asks (it refuses when it can't ask). Other options go to mise bootstrap."))


USAGE = """\
usage: ws [words...]          the palette (search starts with the words)
       ws reconcile [...]     review dotfiles that differ from the repo (ws reconcile -h)
       ws open [project]      open a project workspace (ws open -h)
       ws apply [...]         apply the repo's dotfiles, asking before a local edit is lost (wsa)
       ws health              run the health report and fix a finding
       ws help                the cheatsheet (wsh)
       ws actions [--json]    list every action and what it runs
"""


def main(argv: list[str]) -> int:
    try:
        return _main(argv)
    except KeyboardInterrupt:
        print()
        return 130
    except BrokenPipeError:
        return 0


def _main(argv: list[str]) -> int:
    if argv[:1] == ["_preview"]:  # fzf's preview: _preview <dir> [--safe] <id>
        from .palette import preview_file

        rest = [a for a in argv[2:] if a != "--safe"]
        return preview_file(argv[1] if len(argv) > 1 else "", rest[0] if rest else "", "--safe" in argv[2:])
    if argv[:1] in (["-h"], ["--help"]):
        sys.stdout.write(USAGE)
        return 0
    cmd = argv[0] if argv and argv[0] in SUBCOMMANDS else ""
    rest = argv[1:] if cmd else argv
    if cmd == "baseline":
        return baseline(rest)
    if cmd == "reconcile":
        from .reconcile import main as reconcile

        return reconcile(_reconcile_parser().parse_args(rest))
    if cmd == "open":
        from .workspace import main as open_main

        return open_main(_open_parser().parse_args(rest))
    if cmd == "apply":
        from .apply import main as apply_main

        return apply_main(_apply_parser().parse_known_args(rest)[1])
    if cmd == "help":
        from .catalog import help_text, load

        sys.stdout.write(help_text(load()))
        return 0
    if cmd == "health":
        from .palette import health

        return health()
    if cmd == "actions":
        from .palette import main as palette

        return palette([a for a in rest if not a.startswith("--")], list_only=True, as_json="--json" in rest)
    if cmd == "complete":
        return complete(rest)
    from .palette import main as palette

    return palette(rest)


def baseline(args: list[str]) -> int:
    """The bootstrap hooks: `record` after every dotfiles apply (post-dotfiles), `snapshot`
    before it (pre-dotfiles). They never fail a bootstrap: any error is a warning."""
    from . import core
    from .baseline import Store
    from .dotfiles import load, record_agreed, snapshot

    what = args[0] if args else "status"
    try:
        store = Store()
        if what == "status":
            print(f"{store.index_path}: {len(store.files)} file(s) recorded"
                  + (f" ({store.problem}: read-only here)" if store.read_only else "")
                  + (f" (damaged: {store.problem})" if store.problem and not store.read_only else ""))
            return 0
        if what == "snapshot" and os.environ.get("WS_BACKED_UP") == "1":
            return 0  # wsa or ws reconcile backed up what this apply overwrites, and stops if it can't
        model = load(store, render_templates=False)
        if model.errors:
            if what == "snapshot":
                _backup_failed(f"the check couldn't run: {model.errors[0]}")
            else:
                print(f"ws baseline: not recorded ({model.errors[0]})", file=sys.stderr)
            return 0
        if what == "record":
            n = record_agreed(model, store, "apply")
            if n:
                print(f"ws: dotfile baselines updated ({n})")
        elif what == "snapshot":
            b, failed = snapshot(model, store)
            if b.saved:
                print(f"ws: backed up {snapshot_words(b.counts())} the apply may overwrite: {b.dir}")
                print("    (ws reconcile --backups lists them with restore commands)")
            if failed:
                _backup_failed("couldn't copy " + "; ".join(f"{core.tilde(f)} ({why})" for f, why in failed))
            elif not b.saved:
                print(f"ws: pre-apply backup: nothing to back up ({len(model.items)} managed file(s) checked, "
                      "no local edit the apply could overwrite)")
        else:
            print(f"ws baseline: unknown action {what!r} (record, snapshot, status)", file=sys.stderr)
            return 2
    except Exception as e:  # noqa: BLE001 (a hook must never stop the bootstrap)
        if what == "snapshot":
            _backup_failed(f"{type(e).__name__}: {e}")
        else:
            print("ws baseline: failed (the bootstrap carries on):", file=sys.stderr)
        traceback.print_exc(limit=3)
    return 0


def _backup_failed(why: str) -> None:
    """The pre-apply backup didn't happen (or not for every file). The hook still exits 0, so
    the apply goes ahead: say plainly that what it overwrites may be unrecoverable."""
    from . import core

    print(core.paint(f"ws: PRE-APPLY BACKUP FAILED: {why}. The apply goes ahead anyway (this hook never "
                     "stops a bootstrap), so a local edit it overwrites may not be recoverable from a "
                     "backup. wsa takes its own backup and stops instead.", "red", on=core.color_on(sys.stderr)),
          file=sys.stderr)


def snapshot_words(counts: dict[str, int]) -> str:
    """What a pre-apply snapshot kept, without calling a file a local edit when there was no
    baseline to say so: "2 local edit(s)", "4 file(s) with no baseline", or both."""
    from .baseline import LOCAL_EDIT, NO_BASELINE

    local, unknown = counts.get(LOCAL_EDIT, 0), counts.get(NO_BASELINE, 0) + counts.get("", 0)
    parts = []
    if local:
        parts.append(f"{local} local edit(s)")
    if unknown:
        parts.append(f"{unknown} file(s) that differed from the repo with no baseline to tell whether they were edits")
    return " and ".join(parts) or "0 files"


def complete(words: list[str]) -> int:
    """Candidates for the word being completed, for the zsh, bash and Nushell completers."""
    if len(words) <= 1:
        cur = words[0] if words else ""
        print("\n".join(s for s in COMPLETED if s.startswith(cur)))
        return 0
    sub, cur = words[0], words[-1]
    if sub == "open" and not cur.startswith("-"):
        from .workspace import discover

        names = sorted({p.label for p in discover()})
        print("\n".join(n for n in names if n.startswith(cur)))
    elif sub == "open":
        print("\n".join(f for f in ["--layout", "--editor", "--run", "--cd", "--tab", "--list", "--prefs"] if f.startswith(cur)))
    elif sub == "reconcile":
        print("\n".join(f for f in ["--list", "--json", "--record", "--apply", "--merge", "--yes", "--backups"]
                        if f.startswith(cur)))
    return 0

