"""`ws open`: project workspaces. A project is a git worktree (or a directory you name);
its workspace is a zellij session named for it, started in it with the dev layout.

Discovery is cheap: zoxide's history, two levels under the configured roots, the
workspaces opened before, and each repo's linked worktrees read from .git/worktrees (no
git process, no scan of the home). Each worktree is its own workspace: the session name
is a readable label plus a hash of the worktree's resolved path, stable across runs and
distinct for two checkouts with the same name.

Nothing a project carries is executed: its mise tasks are listed (mise's trust check
applies), never run unless you pick one. Startup commands come only from your own
projects.toml or an explicit --run, never from the project.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from . import core, ui

MARKERS = ("mise.toml", ".mise.toml", "package.json", "Cargo.toml", "go.mod", "pyproject.toml",
           "CMakeLists.txt", "meson.build", "Makefile")
DEFAULT_LAYOUT = "dev"
PREFS_TEMPLATE = """\
# ws open preferences (per host; not tracked). `ws open --prefs` opens this file.
#
# roots: where `ws open` looks for projects besides zoxide's history (two levels deep).
# roots = ["~/projects", "~/src"]
#
# Defaults for every workspace:
# editor = "hx"      # EDITOR/VISUAL inside the workspace's session
# layout = "dev"     # a layout in ~/.config/zellij/layouts (dev, ops) or a .kdl path
#
# Per project, keyed by its path. `startup` is opt-in: each key is a pane name in the
# layout (dev has editor, terminal and run), each value the command that pane starts with
# when the session is CREATED. Nothing runs on attach, and nothing is read from the project.
# [project."~/projects/example"]
# editor = "nvim"
# layout = "dev"
# startup = { editor = "nvim .", run = "mise run dev" }
# suspended = true   # startup commands wait for Enter
"""


@dataclass
class Project:
    path: Path
    main: Path | None = None   # the main worktree when this is a linked one
    branch: str = ""
    sources: set[str] = field(default_factory=set)
    score: float = 0.0

    @property
    def linked(self) -> bool:
        return self.main is not None and self.main != self.path

    @property
    def label(self) -> str:
        if self.linked and self.main is not None and self.main.name != self.path.name:
            return f"{self.main.name}-{self.path.name}"
        return self.path.name or "root"

    @property
    def session(self) -> str:
        return session_name(self.path, self.label)


def session_name(path: Path, label: str | None = None) -> str:
    """<label>-<6 hex of sha256(resolved path)>: readable, stable, and two worktrees (or
    two clones) with the same directory name never share a session."""
    real = os.path.realpath(path)
    digest = hashlib.sha256(real.encode("utf-8", "surrogateescape")).hexdigest()[:6]
    clean = re.sub(r"[^A-Za-z0-9._-]+", "-", label or Path(real).name).strip("-.") or "project"
    return f"{clean[:24]}-{digest}"


def toplevel(path: Path) -> Path | None:
    """The worktree containing `path` (the directory holding .git, a dir or a file)."""
    try:
        p = path.resolve()
    except OSError:
        return None
    for d in [p, *p.parents]:
        if (d / ".git").exists():
            return d
    return None


def _gitdir(top: Path) -> Path | None:
    g = top / ".git"
    if g.is_dir():
        return g
    try:
        line = g.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    if line.startswith("gitdir:"):
        p = Path(line[7:].strip())
        return p if p.is_absolute() else (top / p).resolve()
    return None


def describe(top: Path) -> Project:
    """Branch and main worktree from the git files themselves (no git process)."""
    proj = Project(path=top)
    gd = _gitdir(top)
    if gd is None:
        return proj
    if gd.parent.name == "worktrees" and gd.parent.parent.name == ".git":
        proj.main = gd.parent.parent.parent
    try:
        head = (gd / "HEAD").read_text(encoding="utf-8").strip()
        proj.branch = head.removeprefix("ref: refs/heads/") if head.startswith("ref:") else head[:10]
    except OSError:
        pass
    return proj


def linked_worktrees(top: Path) -> list[Path]:
    wt = top / ".git" / "worktrees"
    out = []
    if wt.is_dir():
        for d in sorted(wt.iterdir()):
            try:
                p = Path((d / "gitdir").read_text(encoding="utf-8").strip()).parent
            except OSError:
                continue
            if p.is_dir():
                out.append(p)
    return out


# --- preferences and the registry -------------------------------------------------

def prefs_path() -> Path:
    return core.config_dir() / "projects.toml"


def load_prefs() -> dict[str, object]:
    try:
        with open(prefs_path(), "rb") as fh:
            return tomllib.load(fh)
    except FileNotFoundError:
        return {}
    except tomllib.TOMLDecodeError as e:
        print(f"ws: {core.tilde(prefs_path())}: {e} (ignored)", file=sys.stderr)
        return {}


def project_prefs(prefs: dict[str, object], path: Path) -> dict[str, object]:
    """Defaults merged with the [project."<path>"] table that names this path."""
    out = {k: prefs[k] for k in ("editor", "layout") if k in prefs}
    table = prefs.get("project", {})
    if isinstance(table, dict):
        real = os.path.realpath(path)
        for key, val in table.items():
            if isinstance(val, dict) and os.path.realpath(core.expand(str(key))) == real:
                out.update(val)
    return out


def roots(prefs: dict[str, object]) -> list[Path]:
    rs = prefs.get("roots")
    if isinstance(rs, list) and rs:
        return [core.expand(str(r)) for r in rs]
    return [Path(os.environ.get("PROJECT_ROOT") or core.home() / "projects")]


def registry_path() -> Path:
    return core.state_dir() / "workspaces.json"


def load_registry() -> dict[str, dict[str, str]]:
    try:
        data = json.loads(registry_path().read_text(encoding="utf-8"))
        return dict(data.get("workspaces", {}))
    except (FileNotFoundError, ValueError):
        return {}


def remember(proj: Project) -> None:
    reg = load_registry()
    reg[proj.session] = {"path": str(proj.path), "opened": core.now_iso()}
    doc = {"version": 1, "workspaces": reg}
    core.atomic_write(registry_path(), (json.dumps(doc, indent=1) + "\n").encode())


# --- discovery ----------------------------------------------------------------------

def zoxide_dirs() -> list[tuple[float, Path]]:
    if not core.which("zoxide"):
        return []
    proc = core.run(["zoxide", "query", "--list", "--score"], timeout=5)
    out = []
    for line in proc.stdout.splitlines():
        score, _, path = line.strip().partition(" ")
        try:
            out.append((float(score), Path(path.strip())))
        except ValueError:
            continue
    return out


def _project_root(d: Path) -> Path | None:
    top = toplevel(d)
    if top is not None:
        return top
    if any((d / m).exists() for m in MARKERS):
        return d
    return None


def discover(prefs: dict[str, object] | None = None) -> list[Project]:
    prefs = load_prefs() if prefs is None else prefs
    found: dict[str, Project] = {}
    home, repo = core.home().resolve(), core.repo().resolve()

    def add(path: Path, source: str, score: float = 0.0) -> None:
        try:
            real = path.resolve()
        except OSError:
            return
        if real in (home, Path(real.anchor)) or not real.is_dir():
            return
        key = str(real)
        if key not in found:
            found[key] = describe(real)
        found[key].sources.add(source)
        found[key].score = max(found[key].score, score)

    for score, d in zoxide_dirs():
        if d.is_dir():
            top = _project_root(d)
            if top is not None:
                add(top, "zoxide", score)
    for r in roots(prefs):
        if not r.is_dir():
            continue
        for child in _children(r):
            if (child / ".git").exists():
                add(child, "root")
            else:
                for grand in _children(child):
                    if (grand / ".git").exists():
                        add(grand, "root")
    for info in load_registry().values():
        p = Path(info.get("path", ""))
        if p.is_dir():
            add(p, "opened")
    for proj in list(found.values()):
        if (proj.path / ".git").is_dir():
            for wt in linked_worktrees(proj.path):
                add(wt, "worktree")
    for proj in found.values():
        if proj.path == repo:
            proj.sources.add("workstation")
    return list(found.values())


def _children(d: Path) -> list[Path]:
    try:
        return sorted(p for p in d.iterdir() if p.is_dir() and not p.name.startswith("."))
    except OSError:
        return []


def sessions() -> dict[str, str]:
    """zellij's sessions: name -> running | exited | current."""
    if not core.which("zellij"):
        return {}
    proc = core.run(["zellij", "list-sessions", "--no-formatting"], timeout=5)
    out = {}
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        name = line.split()[0]
        out[name] = "exited" if "EXITED" in line else ("current" if "(current)" in line else "running")
    return out


def ordered(projects: list[Project], live: dict[str, str]) -> list[Project]:
    reg = load_registry()

    def rank(p: Project) -> tuple[int, str, float, str]:
        st = live.get(p.session, "")
        return (0 if st in ("running", "current") else 1 if st == "exited" else 2,
                "~" if p.session not in reg else _neg(reg[p.session].get("opened", "")), -p.score, p.label)

    return sorted(projects, key=rank)


def _neg(iso: str) -> str:
    # Newest first within a string sort: invert each digit.
    return "".join(chr(ord("9") - ord(c) + ord("0")) if c.isdigit() else c for c in iso)


# --- resolving an argument ------------------------------------------------------------

def resolve(arg: str, projects: list[Project]) -> tuple[Project | None, list[Project]]:
    """One project for `arg`, or (None, the candidates to pick from)."""
    p = core.expand(arg) if arg.startswith("~") else Path(arg)
    if ("/" in arg or "\\" in arg or arg in (".", "..") or arg.startswith("~")) and p.is_dir():
        top = _project_root(p.resolve()) or p.resolve()
        return describe(top), []
    low = arg.lower()
    exact = [x for x in projects if low in (x.label.lower(), x.path.name.lower(), x.session.lower())]
    if len(exact) == 1:
        return exact[0], []
    if exact:
        return None, exact
    partial = [x for x in projects if low in x.label.lower() or low in str(x.path).lower()]
    if len(partial) == 1:
        return partial[0], []
    if partial:
        return None, partial
    if p.is_dir():
        top = _project_root(p.resolve()) or p.resolve()
        return describe(top), []
    if core.which("zoxide"):
        proc = core.run(["zoxide", "query", "--", arg], timeout=5)
        hit = proc.stdout.strip()
        if proc.returncode == 0 and hit and Path(hit).is_dir():
            top = _project_root(Path(hit)) or Path(hit)
            return describe(top), []
    return None, []


# --- layouts ----------------------------------------------------------------------

def kdl_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def layout_file(layout: str) -> Path | None:
    if layout.endswith(".kdl"):
        p = core.expand(layout) if layout.startswith("~") else Path(layout)
        return p if p.is_file() else None
    base = Path(os.environ.get("ZELLIJ_CONFIG_DIR") or core.home() / ".config" / "zellij")
    p = base / "layouts" / f"{layout}.kdl"
    return p if p.is_file() else None


def inject(layout_text: str, cwd: Path, commands: dict[str, list[str]], suspended: bool) -> str:
    """The layout with a root `cwd` and each named pane starting a command. Only the main
    tab is touched: the first pane of each name, before the swap layouts."""
    lines = layout_text.split("\n")
    root = next((i for i, ln in enumerate(lines) if re.match(r"^\s*layout\s*\{", ln)), None)
    if root is None:
        raise ValueError("no `layout {` block")
    stop = next((i for i, ln in enumerate(lines) if re.match(r"^\s*swap_(tiled|floating)_layout\b", ln)), len(lines))
    for name, argv in commands.items():
        pat = re.compile(rf'^(?P<ind>\s*)pane\b(?P<attrs>[^{{]*?)\bname="{re.escape(name)}"(?P<rest>[^{{/]*?)\s*(?P<brace>\{{)?\s*(?://.*)?$')
        for i in range(root + 1, stop):
            m = pat.match(lines[i])
            if not m:
                continue
            ind = m.group("ind")
            head = f'{ind}pane{m.group("attrs")}name="{name}"{m.group("rest").rstrip()} command={kdl_str(argv[0])}'
            if suspended:
                head += " start_suspended=true"
            args = f"{ind}    args {' '.join(kdl_str(a) for a in argv[1:])}" if argv[1:] else ""
            if m.group("brace"):
                lines[i] = head + " {" + (("\n" + args) if args else "")
            else:
                lines[i] = head + ((" {\n" + args + f"\n{ind}}}") if args else "")
            break
        else:
            raise ValueError(f"the layout has no pane named {name!r}")
    lines.insert(root + 1, f"    cwd {kdl_str(str(cwd))}")
    return "\n".join(lines)


def startup_commands(pp: dict[str, object], run_task: str = "") -> dict[str, list[str]]:
    import shlex

    cmds: dict[str, list[str]] = {}
    st = pp.get("startup")
    if isinstance(st, dict):
        for pane, cmd in st.items():
            if isinstance(cmd, str) and cmd.strip():
                cmds[str(pane)] = shlex.split(cmd, posix=not core.IS_WINDOWS)
            elif isinstance(cmd, list) and cmd:
                cmds[str(pane)] = [str(c) for c in cmd]
    if run_task:
        cmds["run"] = ["mise", "run", run_task]
    return cmds


# --- opening ----------------------------------------------------------------------

def project_tasks(path: Path) -> tuple[list[tuple[str, str]], str]:
    proc = core.run(["mise", "tasks", "ls", "--local", "--json"], cwd=path, env={"NO_COLOR": "1"}, timeout=20)
    if proc.returncode != 0:
        msg = next((ln for ln in proc.stderr.splitlines() if "trust" in ln.lower()), "")
        return [], msg or ""
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        return [], ""
    return [(str(t.get("name")), str(t.get("description") or "")) for t in data
            if isinstance(t, dict) and not t.get("global") and not t.get("hide")], ""


def preview(path: Path) -> str:
    proj = describe(toplevel(path) or path)
    pp = project_prefs(load_prefs(), proj.path)
    st = sessions().get(proj.session, "")
    lines = [core.paint(str(proj.path), "bold"),
             f"session: {proj.session} ({_state_words(st)})"]
    if proj.branch:
        lines.append(f"branch:  {proj.branch}" + (f"  (worktree of {core.tilde(proj.main)})" if proj.linked and proj.main else ""))
    lines.append(f"layout:  {pp.get('layout', DEFAULT_LAYOUT)}   editor: {pp.get('editor') or os.environ.get('EDITOR') or 'default'}")
    cmds = startup_commands(pp)
    if cmds:
        lines.append("startup (from your projects.toml, on create only):")
        lines += [f"  {pane}: {core.shell_join(argv)}" for pane, argv in cmds.items()]
    tasks, err = project_tasks(proj.path)
    if tasks:
        lines.append("")
        lines.append("mise tasks (run one with ws open --run <task>, or from the palette):")
        lines += [f"  {n:<16} {d}" for n, d in tasks[:20]]
    elif err:
        lines.append(f"mise tasks: {err}")
    return "\n".join(lines) + "\n"


def _state_words(st: str) -> str:
    return {"running": "running: attach", "current": "this session", "exited": "exited: resurrect its layout",
            "": "none yet: create"}[st]


def open_project(proj: Project, *, layout: str = "", editor: str = "", run_task: str = "",
                 cd_only: bool = False, tab: bool = False) -> int:
    prefs = load_prefs()
    pp = project_prefs(prefs, proj.path)
    if layout:
        pp["layout"] = layout
    if editor:
        pp["editor"] = editor
    remember(proj)
    name = proj.session
    use_zellij = not core.IS_WINDOWS and core.which("zellij") and not cd_only and not tab
    if not use_zellij:
        return _fallback(proj, pp, tab)
    st = sessions().get(name, "")
    lay = str(pp.get("layout") or DEFAULT_LAYOUT)
    cmds = startup_commands(pp, run_task)
    env = dict(os.environ)
    ed = str(pp.get("editor") or "")
    if ed:
        env["EDITOR"] = env["VISUAL"] = ed
    inside = os.environ.get("ZELLIJ_SESSION_NAME") or ("" if not os.environ.get("ZELLIJ") else "?")
    if st == "current" or inside == name:
        print(f"already in {name} ({proj.path})")
        return 0
    if st in ("running", "exited"):
        if st == "running":
            print(f"attaching to {name}: the running session, panes and processes as you left them")
        else:
            print(f"resurrecting {name}: zellij rebuilds its tabs and panes from its last save in "
                  f"{proj.path}; commands in panes wait for Enter, other processes don't come back")
        if run_task or pp.get("startup"):
            print("  (startup commands run only when a session is created)")
        argv = (["zellij", "action", "switch-session", name] if inside else ["zellij", "attach", name])
        rc = _exec(argv, proj.path, env, replace=not inside)
        if rc != 0 and inside:
            print(f"ws: couldn't switch to {name} from inside zellij; detach (Ctrl+S, then d) and run ws open again")
        return rc
    lay_arg = lay
    if cmds:
        src = layout_file(lay)
        if src is None:
            return core.die(f"startup commands need the layout as a file; no {lay}.kdl in ~/.config/zellij/layouts")
        try:
            text = inject(src.read_text(encoding="utf-8"), proj.path, cmds, bool(pp.get("suspended", False)))
        except ValueError as e:
            return core.die(f"{src}: {e}")
        gen = core.state_dir() / "workspaces" / f"{name}.kdl"
        core.atomic_write(gen, text.encode("utf-8"))
        lay_arg = str(gen)
    print(f"creating {name} in {proj.path} with the {lay} layout")
    for pane, argv in cmds.items():
        print(f"  {pane} pane starts: {core.shell_join(argv)}")
    if inside:
        rc = _exec(["zellij", "attach", "--create-background", name, "options", "--default-layout", lay_arg],
                   proj.path, env, replace=False)
        if rc != 0:
            return rc
        return _exec(["zellij", "action", "switch-session", name], proj.path, env, replace=False)
    return _exec(["zellij", "--session", name, "--new-session-with-layout", lay_arg], proj.path, env, replace=True)


def _exec(argv: list[str], cwd: Path, env: dict[str, str], replace: bool) -> int:
    if replace and not core.IS_WINDOWS and os.environ.get("WS_NO_EXEC") != "1":
        os.chdir(cwd)
        sys.stdout.flush()
        os.execvpe(argv[0], argv, env)
    return core.run(argv, cwd=cwd, env={k: v for k, v in env.items() if os.environ.get(k) != v}, capture=False).returncode


def _fallback(proj: Project, pp: dict[str, object], tab: bool) -> int:
    """No zellij (Windows, or --cd/--tab): change to the project, or open it in a new tab."""
    path = str(proj.path)
    if tab and os.environ.get("WEZTERM_PANE") and core.which("wezterm"):
        return core.run(["wezterm", "cli", "spawn", "--cwd", path], capture=False).returncode
    if tab and os.environ.get("WT_SESSION") and core.which("wt"):
        return core.run(["wt", "-w", "0", "new-tab", "-d", path], capture=False).returncode
    if tab:
        print("ws: no WezTerm or Windows Terminal session to open a tab in; changing directory instead")
    if not core.emit("cd", path):
        print(f"cd {core.shell_join([path])}")
    why = "zellij isn't available on Windows" if core.IS_WINDOWS else "--cd"
    print(f"{proj.label}: {path}  ({why}; this shell is now in the project)")
    ed = pp.get("editor")
    if ed:
        print(f"  editor for this project: {ed}")
    tasks, err = project_tasks(proj.path)
    if tasks:
        print("  tasks: " + ", ".join(n for n, _ in tasks[:12]) + "  (mise run <task>)")
    elif err:
        print(f"  tasks: {err}")
    return 0


# --- command line -------------------------------------------------------------------

def _pick(projects: list[Project], query: str = "") -> Project | None:
    live = sessions()
    projs = ordered(projects, live)
    if not projs:
        print("ws: no projects found. Add roots in projects.toml (ws open --prefs), or cd into one once so zoxide knows it.")
        return None
    if not core.interactive() or not core.which("fzf"):
        for p in projs:
            print(f"{p.label:<30} {p.path}")
        return None
    lines = []
    for p in projs:
        st = live.get(p.session, "")
        tag = {"running": ("running", "green"), "current": ("here", "green"), "exited": ("exited", "yellow")}.get(st, ("", "dim"))
        extra = (f"worktree {p.branch}" if p.linked else p.branch) or ""
        lines.append(f"{p.path}\t{core.paint(f'{tag[0]:<8}', tag[1])} {p.label:<28} "
                     f"{core.paint(core.tilde(p.path), 'dim')}  {core.paint(extra, 'dim')}")
    pick = ui.fzf(lines, prompt="project>", query=query,
                  header="Enter: open (attach, resurrect or create)   Esc: cancel",
                  preview=core.self_argv("open", "--preview"))
    if pick is None:
        return None
    path = Path(pick.ids[0])
    return next((p for p in projs if p.path == path), describe(path))


def main(args) -> int:
    if args.prefs:
        path = prefs_path()
        if not path.exists():
            core.atomic_write(path, PREFS_TEMPLATE.encode())
        return ui.edit([path])
    if args.preview:
        sys.stdout.write(preview(Path(args.project)))
        return 0
    prefs = load_prefs()
    projects = discover(prefs)
    if args.list or args.names:
        live = sessions()
        for p in ordered(projects, live):
            if args.names:
                print(p.label)
            else:
                print(f"{_state_words(live.get(p.session, '')):<30} {p.session:<32} {core.tilde(p.path)}")
        return 0
    if args.project:
        proj, cands = resolve(args.project, projects)
        if proj is None:
            if not cands:
                return core.die(f"no project matches {args.project!r} (a path works too)")
            proj = _pick(cands, args.project)
    else:
        proj = _pick(projects)
    if proj is None:
        return 0
    return open_project(proj, layout=args.layout or "", editor=args.editor or "", run_task=args.run or "",
                        cd_only=args.cd, tab=args.tab)
