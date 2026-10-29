"""Recent workspace context, using the existing workspace discovery and opener."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from . import core, history, ui, workspace


def note_path(project: workspace.Project) -> Path:
    return core.state_dir() / "notes" / (project.session + ".txt")


def rows() -> list[dict]:
    registry = workspace.load_registry()
    live = workspace.sessions()
    runs = history.records("runs")
    projects = {str(p.path): p for p in workspace.discover()}
    for r in runs:
        path = Path(r["cwd"])
        if path.is_dir():
            top = workspace.toplevel(path) or path
            projects.setdefault(str(top), workspace.describe(top))
    result = []
    for p in projects.values():
        related = [r for r in runs if Path(r["cwd"]).is_relative_to(p.path)]
        recent = registry.get(p.session, {}).get("opened", "")
        if related:
            recent = max(recent, related[0]["started"])
        try:
            note = note_path(p).read_text(encoding="utf-8")
        except FileNotFoundError:
            note = ""
        status = core.run(["git", "-C", str(p.path), "status", "--porcelain"], timeout=3)
        failed = next((r for r in related if r.get("exit_code") not in (None, 0)), None)
        result.append({"path": str(p.path), "label": p.label, "session": live.get(p.session, ""),
                       "branch": p.branch, "dirty": bool(status.stdout.strip()), "opened": recent,
                       "note": note, "failed_run": failed["id"] if failed else "",
                       "running": [r["id"] for r in related if history.running(r)]})
    return sorted(result, key=lambda r: r["opened"], reverse=True)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="ws resume", description="Recent projects, unfinished work, notes and failed runs.")
    p.add_argument("project", nargs="?")
    p.add_argument("--list", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("--note", metavar="TEXT", help="leave a note for this directory or the named project (empty clears it)")
    p.add_argument("--cd", action="store_true")
    p.add_argument("--tab", action="store_true")
    a = p.parse_args(argv)
    if a.note is not None:
        project, _ = workspace.resolve(a.project or str(workspace.toplevel(Path.cwd()) or Path.cwd()), workspace.discover())
        if project is None:
            return core.die("project not found or ambiguous; give its path", 2)
        path = note_path(project)
        core.private_dir(path.parent)
        core.atomic_write(path, a.note.encode(), 0o600)
        workspace.remember(project)
        print(f"Note saved for {project.label}")
        return 0
    if a.project:
        from .cli import _open_parser

        return workspace.main(_open_parser().parse_args(
            [a.project, *(["--cd"] if a.cd else []), *(["--tab"] if a.tab else [])]))
    items = rows()
    if a.json:
        print(json.dumps(items, indent=2))
        return 0
    lines = [f"{r['path']}\t{r['label']}  {r['branch']}{'*' if r['dirty'] else ''}  "
             f"{r['session']}  {r['opened']}  jobs={len(r['running'])}  "
             f"failed={r['failed_run'] or '-'}  {r['note'].replace(chr(10), ' ')}" for r in items]
    if not a.list and core.interactive() and core.which("fzf"):
        pick = ui.fzf(lines, prompt="resume>", header="Enter: reopen workspace; notes: ws resume <project> --note TEXT")
        if pick:
            return workspace.open_project(workspace.describe(Path(pick.ids[0])), cd_only=a.cd, tab=a.tab)
    else:
        print("\n".join(lines) or "No recent projects. Open one with ws open <path>.")
        if core.which("pueue"):
            print("\nQueued jobs (pueue):", flush=True)
            core.run(["pueue", "status"], capture=False, timeout=5)
    return 0
