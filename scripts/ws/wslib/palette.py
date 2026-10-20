"""`ws`: the searchable palette over the catalogue, and running what was picked.

The picker hands back an action id, nothing else; the action's argv comes from the
catalogue (or from mise's task list), so no text shown in the picker is ever run. A
`change` action prints the exact command and asks first; Esc anywhere changes nothing.
"""

from __future__ import annotations

import json
import re
import sys
import tempfile
from pathlib import Path

from . import core, ui
from .catalog import Action, Catalogue, current_shell, discover, fill, load

KIND_TAGS = {"read": ("read", "green"), "change": ("change", "yellow"), "open": ("open", "mauve"),
             "info": ("info", "blue")}
INSERT_SHELLS = ("zsh", "bash", "nu")


def actions(cat: Catalogue, *, with_discovered: bool = True, cwd: Path | None = None) -> list[Action]:
    shell = current_shell()
    found = cat.actions + (discover(cat, cwd) if with_discovered else [])
    return [a for a in found if a.available(core.OS, shell)]


def command_text(a: Action, arg: str = "") -> str:
    """What the action executes, spelt out for the preview and the confirmation."""
    r = a.runner
    if r in ("run", "task"):
        cmd = core.shell_join(a.argv(arg or ("<" + a.pick + ">" if a.pick else "")))
        return f"cd {core.shell_join([a.cwd])} && {cmd}" if a.cwd else cmd
    if r == "ws":
        return core.shell_join(["ws", *a.ws])
    if r == "insert":
        return a.insert
    if r == "cd":
        return core.shell_join(["cd", fill(a.cd)])
    if r == "edit":
        return core.shell_join([*ui.editor_argv([Path(fill(a.edit))])])
    if r == "doc":
        return f"show {a.doc}"
    return ""


def preview(a: Action, cat: Catalogue | None = None, color: bool = True) -> str:
    tag = {"read": "read: changes nothing", "change": "change: writes files or host state; asks before running",
           "open": "open: an interactive program (editor, picker, session)", "info": "info: text only"}[a.kind]
    lines = [core.paint(a.title, "bold", on=color), a.desc, "", f"kind:    {tag}"]
    r = a.runner
    if r == "insert":
        how = ("put on your prompt; press Enter to run it" if current_shell() in INSERT_SHELLS
               else "printed for you to run")
        lines.append(f"runs:    {a.insert}  ({how}; it's a shell function or script)")
    elif r == "text":
        lines.append("shows:")
        lines += [f"  {t}" for t in a.text]
    elif r:
        lines.append(f"runs:    {command_text(a)}")
    if a.pick:
        lines.append(f"asks:    {a.pick} first (a picker; Esc cancels)")
    if a.alias:
        lines.append(f"alias:   {a.alias}")
    if a.fixes:
        lines.append(f"repairs: health rows {', '.join(a.fixes)}")
    lines.append(f"from:    {a.source}" + (f" ({a.id})" if a.source.startswith("scripts/") else ""))
    if cat is not None:
        words = cat.search_words(a)
        if words:
            lines.append(core.paint("search:  " + " ".join(words), "dim", on=color))
    return "\n".join(lines) + "\n"


def _line(a: Action, cat: Catalogue) -> str:
    tag, col = KIND_TAGS[a.kind]
    words = " ".join(cat.search_words(a))
    return f"{a.id}\t{core.paint(f'{tag:<6}', col)} {a.title}  {core.paint(a.desc, 'dim')}  {core.paint(words, 'dim')}"


def search(cat: Catalogue, acts: list[Action], words: list[str]) -> list[Action]:
    """The actions whose title, description or search words contain every word (what the
    palette's fzf matches on, as a plain filter for `ws actions <words>`)."""
    low = [w.lower() for w in words]
    out = []
    for a in acts:
        hay = " ".join([a.id, a.title, a.desc, *cat.search_words(a)]).lower()
        if all(w in hay for w in low):
            out.append(a)
    return out


def pick_target() -> str | None:
    proc = core.mise("dot", "status", "--json")
    try:
        files = json.loads(proc.stdout).get("files", [])
    except ValueError:
        return None
    lines = [f"{f['target']}\t{f['target']}  {core.paint(f.get('mode', '') + ' ' + f.get('state', ''), 'dim')}"
             for f in files if isinstance(f, dict) and f.get("target")]
    pick = ui.fzf(lines, prompt="dotfile>")
    return pick.ids[0] if pick else None


def show_doc(spec: str) -> int:
    name, _, heading = spec.partition("#")
    path = core.repo() / name
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        return core.die(f"can't read {path}: {e}")
    if heading:
        text = section(text, heading) or text
    with tempfile.TemporaryDirectory(prefix="ws-doc-") as d:
        tmp = Path(d) / (Path(name).stem + ".md")
        tmp.write_text(text, encoding="utf-8")
        for argv in (["glow", "-p", str(tmp)], ["bat", "--paging=always", "--style=plain", "-l", "md", str(tmp)]):
            if core.which(argv[0]) and core.interactive():
                return core.run(argv, capture=False).returncode
        ui.pager(text)
    return 0


def section(text: str, heading: str) -> str:
    """One markdown section: from the heading to the next heading of its level or above."""
    lines = text.split("\n")
    for i, line in enumerate(lines):
        m = re.match(r"^(#+)\s+(.*)$", line)
        if m and m.group(2).strip().lower() == heading.strip().lower():
            level = len(m.group(1))
            end = len(lines)
            for j in range(i + 1, len(lines)):
                m2 = re.match(r"^(#+)\s", lines[j])
                if m2 and len(m2.group(1)) <= level and not _in_fence(lines, j):
                    end = j
                    break
            return "\n".join(lines[i:end]) + "\n"
    return ""


def _in_fence(lines: list[str], j: int) -> bool:
    return sum(1 for ln in lines[:j] if ln.startswith("```")) % 2 == 1


def dispatch(a: Action, *, yes: bool = False) -> int:
    """Run one action. The only place a palette pick turns into a process."""
    r = a.runner
    arg = ""
    if a.pick:
        picked = pick_target() if a.pick == "dotfile-targets" else None
        if not picked:
            print("cancelled: nothing ran")
            return 0
        arg = picked
    if r == "text":
        for t in a.text:
            print(t)
        return 0
    if r == "ws":
        from .cli import main  # noqa: PLC0415 (cli imports palette)

        return main(list(a.ws))
    if r == "insert":
        if current_shell() in INSERT_SHELLS and core.emit("insert", a.insert):
            return 0
        print(f"Run: {a.insert}")
        return 0
    if r == "cd":
        target = fill(a.cd)
        if not core.emit("cd", target):
            print(f"cd {core.shell_join([target])}")
        return 0
    if r == "edit":
        path = Path(fill(a.edit))
        return ui.edit([path])
    if r == "doc":
        return show_doc(a.doc)
    argv = a.argv(arg)
    if not argv:
        return core.die(f"{a.id}: nothing to run")
    shown = command_text(a, arg)
    if a.kind == "change" and not yes:
        print(core.paint(f"$ {shown}", "bold"))
        if not ui.confirm("Run it?"):
            print("cancelled: nothing ran")
            return 0
    elif a.kind != "change":
        print(core.paint(f"$ {shown}", "dim"))
    return core.run(argv, cwd=a.cwd or None, capture=False).returncode


def main(query: list[str], *, list_only: bool = False, as_json: bool = False) -> int:
    cat = load()
    for p in cat.problems:
        print(f"ws: actions.toml: {p}", file=sys.stderr)
    acts = actions(cat)
    if list_only or as_json or not core.interactive() or not core.which("fzf"):
        if as_json:
            print(json.dumps([{"id": a.id, "title": a.title, "kind": a.kind, "runs": command_text(a),
                               "source": a.source} for a in acts], indent=1))
            return 0
        for a in search(cat, acts, query):
            print(f"{a.kind:<6}  {a.title:<40}  {command_text(a)}")
        return 0
    by_id = {a.id: a for a in acts}
    with tempfile.TemporaryDirectory(prefix="ws-palette-") as d:
        for a in acts:
            (Path(d) / f"{_safe(a.id)}.txt").write_text(preview(a, cat), encoding="utf-8")
        lines = [_line(a, cat) for a in acts]
        header = "Search by what you want to do (python, rebuild, ssh, clipboard, update, dotfiles...).  Enter: run  Esc: cancel"
        pick = ui.fzf(lines, prompt="ws>", header=header, query=" ".join(query),
                      preview=core.self_argv("_preview", d, "--safe"), preview_window="down,40%,wrap")
    if pick is None:
        return 0
    chosen = by_id.get(pick.ids[0])
    if chosen is None:  # only an id the palette listed can run
        return core.die(f"no action {pick.ids[0]!r}")
    return dispatch(chosen)


def _safe(ident: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", ident)


def health(yes: bool = False) -> int:
    """Run the health report, then offer the repair action of each failing or warning row."""
    if core.IS_WINDOWS:
        print("The health report is Linux-only. On Windows: mise doctor, wss, mise bootstrap status --missing.")
        return 0
    with tempfile.TemporaryDirectory(prefix="ws-health-") as d:
        rows_file = Path(d) / "rows.tsv"
        rc = core.run(core.mise_argv("run", "health"), env={"WS_HEALTH_ROWS": str(rows_file)}, capture=False).returncode
        rows = []
        try:
            for line in rows_file.read_text(encoding="utf-8").splitlines():
                parts = line.split("\t")
                if len(parts) >= 3 and parts[0] in ("bad", "warn"):
                    rows.append((parts[0], parts[1], parts[2]))
        except FileNotFoundError:
            pass
    if not rows:
        print("health: nothing to fix" if rc == 0 else "health: the report failed before listing its rows")
        return rc
    cat = load()
    acts = actions(cat, with_discovered=False)
    lines, choices = [], []
    for n, (status, name, detail) in enumerate(rows):
        fixes = [a for a in acts if name in a.fixes]
        if "dotfiles-only" in detail or "ws reconcile" in detail:
            # Drift that is only dotfiles (the bootstrap-state row says so) is reconcile's.
            fixes = [a for a in acts if "dotfiles" in a.fixes] or fixes
        fix = fixes[0] if fixes else None
        choices.append((name, detail, fix))
        mark = core.paint("x" if status == "bad" else "!", "red" if status == "bad" else "yellow")
        what = f"-> {fix.title}" if fix else core.paint("(no repair action: see the row's hint)", "dim")
        lines.append(f"{n}\t{mark} {name}: {what}  {core.paint(detail, 'dim')}")
    print()
    if not core.interactive() or not core.which("fzf"):
        for line in lines:
            print(line.split("\t", 1)[1])
        return rc
    with tempfile.TemporaryDirectory(prefix="ws-health-") as d:
        for n, (name, detail, fix) in enumerate(choices):
            text = f"{name}: {detail}\n\n" + (preview(fix, cat) if fix else "No catalogue action repairs this row.\n")
            (Path(d) / f"{n}.txt").write_text(text, encoding="utf-8")
        pick = ui.fzf(lines, prompt="fix>", header="Pick a finding to run its repair (it asks before changing anything). Esc: done",
                      preview=core.self_argv("_preview", d), preview_window="down,50%,wrap")
    if pick is None:
        return rc
    name, detail, fix = choices[int(pick.ids[0])]
    if fix is None:
        print(f"{name}: {detail}")
        return rc
    return dispatch(fix, yes=yes)


def preview_file(directory: str, ident: str, safe: bool = False) -> int:
    name = _safe(ident) if safe else ident
    path = Path(directory) / f"{name}.txt"
    try:
        sys.stdout.write(path.read_text(encoding="utf-8", errors="surrogateescape"))
    except OSError:
        print(f"(no preview for {ident})")
    return 0

