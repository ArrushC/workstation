"""The action catalogue: actions.toml's curated entries, plus the mise tasks found at run
time, filtered to what this OS, this shell and the tools on PATH can run."""

from __future__ import annotations

import json
import os
import re
import textwrap
import tomllib
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

from . import core

CATALOGUE = core.WS_DIR / "actions.toml"
KINDS = ("read", "change", "open", "info")
RUNNERS = ("run", "task", "ws", "insert", "cd", "edit", "doc", "text")
SHELLS = ("zsh", "bash", "nu", "pwsh")


@dataclass
class Action:
    id: str
    title: str
    desc: str = ""
    group: str = "tasks"
    kind: str = "change"
    keywords: list[str] = field(default_factory=list)
    os: list[str] = field(default_factory=list)
    shells: list[str] = field(default_factory=list)
    requires: list[str] = field(default_factory=list)
    alias: str = ""
    wsh: bool = True
    fixes: list[str] = field(default_factory=list)
    run: list[str] = field(default_factory=list)
    pick: str = ""
    task: str = ""
    task_args: list[str] = field(default_factory=list)
    ws: list[str] = field(default_factory=list)
    insert: str = ""
    cd: str = ""
    edit: str = ""
    doc: str = ""
    text: list[str] = field(default_factory=list)
    cwd: str = ""          # project tasks run in their project
    source: str = "scripts/ws/actions.toml"

    @property
    def runner(self) -> str:
        for r in RUNNERS:
            if getattr(self, r):
                return r
        return ""

    def available(self, os_name: str, shell: str) -> bool:
        if self.os and os_name not in self.os:
            return False
        if self.shells and shell and shell not in self.shells:
            return False
        return all(core.which(r) for r in self.requires)

    def argv(self, arg: str = "") -> list[str]:
        """The exact argv this action runs (run/task), placeholders filled in."""
        if self.task:
            base = core.mise_argv("run", self.task, *self.task_args) if not self.cwd else ["mise", "run", self.task]
        elif self.run:
            base = list(self.run)
        else:
            return []
        return [fill(a, arg) for a in base]


def fill(s: str, arg: str = "") -> str:
    return (s.replace("{home}", str(core.home())).replace("{repo}", str(core.repo()))
            .replace("{state}", str(core.state_dir())).replace("{arg}", arg))


@dataclass
class Catalogue:
    actions: list[Action]
    groups: dict[str, str]
    order: list[str]
    synonyms: dict[str, list[str]]
    notes: list[dict[str, object]]
    problems: list[str] = field(default_factory=list)

    def by_id(self, ident: str) -> Action | None:
        return next((a for a in self.actions if a.id == ident), None)

    def search_words(self, a: Action) -> list[str]:
        """The action's own words plus their synonyms (both directions)."""
        words = {w.lower() for w in re.findall(r"[A-Za-z0-9+.-]+", f"{a.id} {a.title} {' '.join(a.keywords)}")}
        extra: list[str] = []
        for canon, syns in self.synonyms.items():
            if canon in words or words & set(syns):
                extra += [canon, *syns]
        seen: set[str] = set()
        out = []
        for w in [*a.keywords, *extra]:
            if w.lower() not in seen:
                seen.add(w.lower())
                out.append(w)
        return out


def load(path: Path = CATALOGUE) -> Catalogue:
    with open(path, "rb") as fh:
        doc = tomllib.load(fh)
    groups = dict(doc.get("groups", {}))
    order = list(groups.pop("order", []))
    actions: list[Action] = []
    problems: list[str] = []
    seen: set[str] = set()
    for raw in doc.get("action", []):
        raw = dict(raw)
        if "wsh" not in raw:
            raw["wsh"] = bool(raw.get("alias"))
        try:
            a = Action(**raw)
        except TypeError as e:
            problems.append(f"{raw.get('id', '?')}: {e}")
            continue
        if a.id in seen:
            problems.append(f"{a.id}: duplicate id")
        seen.add(a.id)
        if a.kind not in KINDS:
            problems.append(f"{a.id}: kind {a.kind!r} is not one of {KINDS}")
        runners = [r for r in RUNNERS if getattr(a, r)]
        if len(runners) != 1:
            problems.append(f"{a.id}: needs exactly one of {RUNNERS}, has {runners}")
        if a.group not in groups:
            problems.append(f"{a.id}: group {a.group!r} isn't in [groups]")
        if a.pick and not a.run:
            problems.append(f"{a.id}: pick needs run")
        for s in a.shells:
            if s not in SHELLS:
                problems.append(f"{a.id}: shell {s!r} is not one of {SHELLS}")
        actions.append(a)
    return Catalogue(actions, groups, order, dict(doc.get("synonyms", {})), list(doc.get("note", [])), problems)


def _mise_tasks(*args: str, cwd: str | None = None) -> tuple[list[dict[str, object]], str]:
    argv = ["mise", "tasks", "ls", "--json", *args] if cwd else core.mise_argv("tasks", "ls", "--json", *args)
    proc = core.run(argv, cwd=cwd, env={"NO_COLOR": "1"}, timeout=20)
    if proc.returncode != 0:
        lines = (proc.stderr or "").strip().splitlines()
        return [], next((ln for ln in lines if "trust" in ln.lower()), lines[0] if lines else "mise tasks failed")
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        return [], "mise tasks ls: unreadable output"
    return [t for t in data if isinstance(t, dict)], ""


def project_dir(cwd: Path) -> Path | None:
    """The project the cwd is in: its git worktree, else the nearest dir with a mise config.
    Never the home or this checkout."""
    from .workspace import toplevel  # noqa: PLC0415 (workspace imports catalog)

    top = toplevel(cwd)
    if top is None:
        for d in [cwd, *cwd.parents]:
            if d == core.home():
                break
            if any((d / n).exists() for n in ("mise.toml", ".mise.toml", "mise", ".mise")):
                top = d
                break
    if top is None or top == core.home() or top == core.repo():
        return None
    return top


def discover(cat: Catalogue, cwd: Path | None = None) -> list[Action]:
    """The checkout's mise tasks (unless curated) and the cwd project's own tasks."""
    curated = {a.task for a in cat.actions if a.task}
    cwd = cwd or Path.cwd()
    proj = project_dir(cwd)
    with ThreadPoolExecutor(max_workers=2) as pool:
        glob = pool.submit(_mise_tasks)
        local = pool.submit(_mise_tasks, "--local", cwd=str(cwd)) if proj else None
        global_tasks, _ = glob.result()
        local_tasks, local_err = local.result() if local else ([], "")
    out: list[Action] = []
    for t in global_tasks:
        name = str(t.get("name", ""))
        if not name or name in curated or t.get("hide"):
            continue
        if core.IS_WINDOWS and t.get("file"):
            continue  # tasks/ files are bash scripts: mise lists them on Windows too, but they can't run
        out.append(Action(
            id=f"task:{name}", title=f"mise run {name}", desc=str(t.get("description") or ""),
            group="health", kind="change", keywords=["task", "mise", *name.split("-")], task=name,
            wsh=False, source=f"mise task ({core.tilde(str(t.get('source') or ''))})",
        ))
    if proj is not None:
        for t in local_tasks:
            name = str(t.get("name", ""))
            if not name or t.get("global") or t.get("hide"):
                continue
            out.append(Action(
                id=f"project:{name}", title=f"{proj.name}: mise run {name}",
                desc=str(t.get("description") or "a task of this project"), group="projects", kind="change",
                keywords=["project", "task", "tasks", name, *name.split(":")], task=name, cwd=str(proj),
                wsh=False, source=f"project task ({core.tilde(str(t.get('source') or ''))})",
            ))
        if local_err:
            out.append(Action(
                id="project:untrusted", title=f"{proj.name}: tasks unavailable", desc=local_err,
                group="projects", kind="info", keywords=["project", "tasks", "trust"], wsh=False,
                text=[local_err, f"Review {core.tilde(proj)}'s mise config, then `mise trust` there to list its tasks."],
            ))
    return out


def current_shell() -> str:
    s = core.shell_name()
    if s:
        return s
    if core.IS_WINDOWS:
        return "nu"
    sh = Path(os.environ.get("SHELL", "")).name
    return sh if sh in SHELLS else ""


def _strs(v: object) -> list[str]:
    return [str(x) for x in v] if isinstance(v, list) else []


def help_text(cat: Catalogue, os_name: str = core.OS, shell: str | None = None, width: int = 78) -> str:
    shell = current_shell() if shell is None else shell
    out = ["workstation commands. Each acts on this host's own checkout (~/.config/mise),",
           "whatever the current directory. `ws` searches all of them, and runs the one you pick.", ""]
    for g in cat.order:
        rows = [a for a in cat.actions if a.group == g and a.wsh and a.available(os_name, shell)]
        if not rows:
            continue
        out.append(cat.groups.get(g, g) + ":")
        for a in rows:
            alias = a.alias or a.title
            desc = a.desc[len(alias) + 1:].lstrip() if a.desc.startswith(alias + ":") else a.desc
            body = textwrap.wrap(desc, width - 26) or [""]
            if len(alias) > 22:
                out.append(f"  {alias}")
                out.extend(f"  {'':22}  {b}" for b in body)
            else:
                out.append(f"  {alias:<22}  {body[0]}")
                out.extend(f"  {'':22}  {b}" for b in body[1:])
        out.append("")
    for n in cat.notes:
        n_os, n_sh = _strs(n.get("os")), _strs(n.get("shells"))
        if (n_os and os_name not in n_os) or (n_sh and shell and shell not in n_sh):
            continue
        out.append(f"{n.get('title')}:")
        out.extend(f"  {t}" for t in _strs(n.get("text")))
        out.append("")
    return "\n".join(out).rstrip("\n") + "\n"
