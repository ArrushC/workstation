"""Project workspaces: session identity, worktrees, discovery, resolution, the layout
injection for opt-in startup commands, and what `ws open` runs in each session state
(zellij stubbed)."""

from __future__ import annotations

import io
from unittest import mock
import os
import re
import shutil
import subprocess
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from helpers import REPO, Scratch

from wslib import workspace
from wslib.workspace import Project


def git(*args: str, cwd: Path) -> None:
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "init.defaultBranch=main",
                    *args], cwd=cwd, check=True, capture_output=True)


class Identity(unittest.TestCase):
    def test_stable_distinct_and_clean(self) -> None:
        a = workspace.session_name(Path("/srv/a/app"))
        self.assertEqual(a, workspace.session_name(Path("/srv/a/app")))
        self.assertNotEqual(a, workspace.session_name(Path("/srv/b/app")))
        self.assertRegex(a, r"^app-[0-9a-f]{6}$")
        odd = workspace.session_name(Path("/x/my project (copy)"), "my project (copy)")
        self.assertRegex(odd, r"^my-project-copy-[0-9a-f]{6}$")
        long = workspace.session_name(Path("/x/" + "n" * 80))
        self.assertLessEqual(len(long), 31)


class Workspaces(Scratch):
    def setUp(self) -> None:
        super().setUp()
        self.projects = self.home / "projects"
        self.app = self.projects / "app repo"
        self.app.mkdir(parents=True)
        git("init", "-q", cwd=self.app)
        git("commit", "-q", "--allow-empty", "-m", "init", cwd=self.app)
        self.wt = self.projects / "app-feature"
        git("worktree", "add", "-q", "-b", "feature", str(self.wt), cwd=self.app)
        self.write(self.root / "cfg/projects.toml", f'roots = ["{self.projects}"]\n')
        self.log = self.root / "zellij.log"
        self.sessions = self.root / "sessions.txt"
        self.sessions.write_text("")
        # Each call also starts a pane's shell as zellij would, with the env it was given: the
        # rc templates' own EDITOR/VISUAL lines, then what they leave.
        self.panes = self.root / "panes.log"
        for sh in ("zsh", "bash"):
            env = re.findall(r"^export (?:EDITOR|VISUAL)=.*$", (REPO / f"dotfiles/{sh}rc.tera").read_text(), re.M)
            self.assertEqual(len(env), 2, sh)
            self.write(self.root / f"env.{sh}", "\n".join(env) + "\n")
        self.fake("zellij", f"""case "$1" in
  list-sessions) cat "{self.sessions}" ;;
  *) printf '%s|%s|%s\\n' "$PWD" "${{EDITOR:-}}" "$*" >>"{self.log}"
     ! command -v zsh >/dev/null || zsh -f -c '. "$1"; print -r -- "zsh|$EDITOR $VISUAL"' _ "{self.root}/env.zsh" >>"{self.panes}"
     bash --norc --noprofile -c '. "$1"; echo "bash|$EDITOR $VISUAL"' _ "{self.root}/env.bash" >>"{self.panes}" ;;
esac""")
        os.environ["WS_NO_EXEC"] = "1"
        os.environ["WS_MUX"] = "zellij"  # these are zellij's tests; a host's own hc must not take over
        os.environ["ZELLIJ_CONFIG_DIR"] = str(REPO / "dotfiles/config/zellij")  # the deployed layouts

    def test_worktrees_are_distinct_workspaces(self) -> None:
        main, wt = workspace.describe(self.app.resolve()), workspace.describe(self.wt.resolve())
        self.assertFalse(main.linked)
        self.assertTrue(wt.linked)
        self.assertEqual((wt.main, wt.branch, wt.label), (self.app.resolve(), "feature", "app repo-app-feature"))
        self.assertNotEqual(main.session, wt.session)
        found = {p.path for p in workspace.discover()}
        self.assertEqual(found, {self.app.resolve(), self.wt.resolve()})

    def test_zoxide_history_maps_to_projects(self) -> None:
        sub = self.app / "src"
        sub.mkdir()
        plain = self.home / "notes"
        plain.mkdir()
        self.fake("zoxide", f'printf "  9.0 {sub}\\n  4.0 {plain}\\n  1.0 {self.home}\\n"')
        self.write(self.root / "cfg/projects.toml", 'roots = []\n')
        found = {p.path: p for p in workspace.discover()}
        self.assertIn(self.app.resolve(), found)          # a subdir counts as its repo
        self.assertNotIn(plain.resolve(), found)          # not a project
        self.assertNotIn(self.home.resolve(), found)      # never the home
        self.assertIn(self.wt.resolve(), found)           # and the repo's worktrees come along

    def test_resolve(self) -> None:
        other = self.home / "src/app repo"
        other.mkdir(parents=True)
        git("init", "-q", cwd=other)
        self.write(self.root / "cfg/projects.toml", f'roots = ["{self.projects}", "{self.home / "src"}"]\n')
        projects = workspace.discover()
        proj, cands = workspace.resolve("app-feature", projects)
        self.assertEqual(proj.path if proj else None, self.wt.resolve())
        proj, cands = workspace.resolve("app repo", projects)  # two checkouts of that name
        self.assertIsNone(proj)
        self.assertEqual({c.path for c in cands}, {self.app.resolve(), other.resolve()})
        proj, _ = workspace.resolve(str(self.app / "."), projects)  # a path with a space
        self.assertEqual(proj.path if proj else None, self.app.resolve())
        self.assertEqual(workspace.resolve("nothing-like-it", projects), (None, []))

    def test_inject_into_the_dev_layout(self) -> None:
        dev = (REPO / "dotfiles/config/zellij/layouts/dev.kdl").read_text()
        out = workspace.inject(dev, Path('/p/a "q"'), {"editor": ["nvim", "."], "run": ["mise", "run", "dev"]}, True)
        self.assertIn('    cwd "/p/a \\"q\\""', out)
        self.assertRegex(out, r'pane size="60%" name="editor" command="nvim" start_suspended=true \{\n\s+args "\."')
        self.assertRegex(out, r'pane name="run"\s+size="30%" command="mise" start_suspended=true \{\n\s+args "run" "dev"\n\s+\}')
        swap = dev.index("swap_tiled_layout")
        self.assertTrue(out.endswith(dev[swap:]))  # the swap layouts are untouched
        with self.assertRaises(ValueError):
            workspace.inject(dev, Path("/p"), {"nope": ["x"]}, False)

    def zellij_calls(self) -> list[tuple[str, ...]]:
        return [tuple(line.split("|", 2)) for line in self.log.read_text().splitlines()]

    def pane_editors(self) -> dict[str, str]:
        """Each shell's "EDITOR VISUAL" after its startup in the last zellij call's panes."""
        return dict(line.split("|", 1) for line in self.panes.read_text().splitlines())

    def open(self, path: Path, **kw: object) -> str:
        proj = workspace.describe(path.resolve())
        with redirect_stdout(io.StringIO()) as buf:
            self.assertEqual(workspace.open_project(proj, **kw), 0)  # type: ignore[arg-type]
        return buf.getvalue()

    def test_create_attach_resurrect(self) -> None:
        name = Project(self.app.resolve()).session
        out = self.open(self.app)
        self.assertIn("creating", out)
        self.assertEqual(self.zellij_calls()[-1], (str(self.app.resolve()), "",
                         f"--session {name} --new-session-with-layout dev"))
        self.assertIn(name, workspace.load_registry())
        self.sessions.write_text(f"{name} [Created 2m ago] \n")
        out = self.open(self.app)
        self.assertIn("attaching", out)
        self.assertEqual(self.zellij_calls()[-1][2], f"attach {name}")
        self.sessions.write_text(f"{name} [Created 2h ago] (EXITED - attach to resurrect)\n")
        out = self.open(self.app, run_task="build")
        self.assertIn("resurrecting", out)
        self.assertIn("commands in panes wait for Enter", out)
        self.assertIn("startup commands run only when a session is created", out)
        self.assertEqual(self.zellij_calls()[-1][2], f"attach {name}")

    def test_inside_zellij_switches(self) -> None:
        os.environ["ZELLIJ"] = "0"
        os.environ["ZELLIJ_SESSION_NAME"] = "main"
        name = workspace.describe(self.wt.resolve()).session
        self.open(self.wt)
        calls = [c[2] for c in self.zellij_calls()]
        self.assertEqual(calls, [f"attach --create-background {name} options --default-layout dev",
                                 f"action switch-session {name}"])

    def test_prefs_editor_layout_and_opt_in_startup(self) -> None:
        self.write(self.root / "cfg/projects.toml", f"""roots = ["{self.projects}"]
editor = "hx"
[project."{self.app}"]
editor = "nvim"
startup = {{ editor = "nvim .", run = "mise run dev" }}
""")
        name = Project(self.app.resolve()).session
        out = self.open(self.app)
        self.assertIn("editor pane starts: nvim .", out)
        cwd, editor, args = self.zellij_calls()[-1]
        gen = self.state / "workspaces" / f"{name}.kdl"
        self.assertEqual((cwd, editor, args), (str(self.app.resolve()), "nvim",
                                               f"--session {name} --new-session-with-layout {gen}"))
        text = gen.read_text()
        self.assertIn('command="nvim"', text)
        self.assertIn(f'cwd "{self.app.resolve()}"', text)
        # Another project gets the defaults and no startup commands: nothing is inferred.
        self.open(self.wt)
        cwd, editor, args = self.zellij_calls()[-1]
        self.assertEqual((editor, args.endswith(" dev")), ("hx", True))

    def test_the_editor_survives_the_panes_shell_startup(self) -> None:
        self.write(self.root / "cfg/projects.toml", f'roots = ["{self.projects}"]\n[project."{self.app}"]\neditor = "nvim"\n')
        shells = ("zsh", "bash") if shutil.which("zsh") else ("bash",)
        self.open(self.app)
        self.assertEqual(self.pane_editors(), dict.fromkeys(shells, "nvim nvim"))
        self.open(self.wt, editor="micro")
        self.assertEqual(self.pane_editors(), dict.fromkeys(shells, "micro micro"))
        self.write(self.root / "cfg/projects.toml", f'roots = ["{self.projects}"]\n')
        self.sessions.write_text("")
        self.open(self.app)  # no editor anywhere: helix
        self.assertEqual(self.pane_editors(), dict.fromkeys(shells, "hx hx"))

    def test_project_config_is_never_run(self) -> None:
        # A project's own files can't add startup commands: only projects.toml and --run do.
        self.write(self.app / "mise.toml", '[tasks.dev]\nrun = "touch pwned"\n')
        self.write(self.app / "projects.toml", '[project."."]\nstartup = { run = "touch pwned" }\n')
        self.open(self.app)
        self.assertFalse((self.app / "pwned").exists())
        self.assertTrue(self.zellij_calls()[-1][2].endswith("--new-session-with-layout dev"))

    # --- herdr-core (hc) ------------------------------------------------------------

    def fake_hc(self, live: str = "") -> Path:
        """An hc that lists `live` (terminals as JSON objects) and logs every other call."""
        log = self.root / "hc.log"
        self.write(self.root / "hc-ls.json", '{"hidden_finished":0,"terminals":[' + live + ']}')
        self.fake("hc", f"""case "$1" in
  ls) cat "{self.root}/hc-ls.json" ;;
  *) printf '%s|%s\\n' "$PWD" "$*" >>"{log}" ;;
esac""")
        os.environ["WS_MUX"] = "hc"
        return log

    def test_mux_prefers_hc_and_obeys_the_preference(self) -> None:
        os.environ.pop("WS_MUX")
        self.fake_hc()
        os.environ.pop("WS_MUX")
        self.assertEqual(workspace.mux({}), "hc")              # both installed: herdr-core
        self.assertEqual(workspace.mux({"mux": "zellij"}), "zellij")
        os.environ["WS_MUX"] = "hc"
        self.assertEqual(workspace.mux({"mux": "zellij"}), "hc")  # the environment wins
        self.assertEqual(workspace.hc_name("App.Repo v2-1a2b3c"), "app-repo-v2-1a2b3c")
        self.assertLessEqual(len(workspace.hc_name("x" * 24 + "-1a2b3c")), 32)

    def test_hc_creates_then_attaches(self) -> None:
        log = self.fake_hc()
        proj = workspace.describe(self.app.resolve())
        name = workspace.hc_name(proj.session)
        self.assertRegex(name, r"^app-repo-[0-9a-f]{6}$")
        self.write(self.root / "cfg/projects.toml", f'roots = ["{self.projects}"]\neditor = "nvim"\n')
        out = self.open(self.app, run_task="build")
        self.assertIn("creating", out)
        calls = [line.split("|", 1)[1] for line in log.read_text().splitlines()]
        self.assertEqual(calls, [f"run --bg --keep --no-parent --name {name} --cwd {self.app.resolve()}",
                                 f"send {name} export EDITOR=nvim VISUAL=nvim",
                                 f"send {name} mise run build",
                                 f"attach --history 1000 {name}"])
        self.assertFalse(self.log.exists())  # zellij was never asked
        self.assertIn(proj.session, workspace.load_registry())
        # Running: attach only; nothing is typed into a shell that is already there.
        log.unlink()
        self.fake_hc('{"address":"t4","name":"' + name + '","state":"live"}')
        out = self.open(self.app, run_task="build")
        self.assertIn("attaching", out)
        self.assertIn("only when a workspace is created", out)
        self.assertEqual([line.split("|", 1)[1] for line in log.read_text().splitlines()], [f"attach --history 1000 {name}"])
        self.assertEqual(workspace.state_of(workspace.sessions(), proj.session), "running")

    def test_hc_from_inside_a_terminal(self) -> None:
        proj = workspace.describe(self.app.resolve())
        name = workspace.hc_name(proj.session)
        log = self.fake_hc('{"address":"t4","name":"' + name + '","state":"live"}')
        os.environ["HC_TERMINAL_ID"] = "t4"
        self.assertIn("already in", self.open(self.app))
        os.environ["HC_TERMINAL_ID"] = "t9"  # another terminal: no nested attach
        with redirect_stdout(io.StringIO()) as buf:
            self.assertEqual(workspace.open_project(proj), 1)
        self.assertIn("detach", buf.getvalue())
        self.assertFalse(log.exists())

    def test_no_mux_changes_directory(self) -> None:
        ws_out = self.root / "ws-out"
        os.environ["WS_OUT"] = str(ws_out)
        os.environ["WS_MUX"] = "hc"  # asked for, not installed
        self.fake("mise", "echo '[]'")
        with mock.patch.object(workspace.core, "which", lambda name: None):
            out = self.open(self.wt)
        self.assertEqual(ws_out.read_text(), f"cd\t{self.wt.resolve()}\n")
        self.assertIn("no hc or zellij here", out)

    def test_cd_fallback(self) -> None:
        ws_out = self.root / "ws-out"
        os.environ["WS_OUT"] = str(ws_out)
        self.fake("mise", "echo '[]'")
        out = self.open(self.wt, cd_only=True)
        self.assertEqual(ws_out.read_text(), f"cd\t{self.wt.resolve()}\n")
        self.assertIn("this shell is now in the project", out)
        self.assertFalse(self.log.exists())

    def test_list(self) -> None:
        import argparse

        name = Project(self.app.resolve()).session
        self.sessions.write_text(f"{name} [Created 2m ago] \n")
        args = argparse.Namespace(prefs=False, preview=False, project=None, list=True, names=False)
        with redirect_stdout(io.StringIO()) as buf:
            workspace.main(args)
        lines = buf.getvalue().splitlines()
        self.assertTrue(lines[0].startswith("running"), lines)
        self.assertTrue(any(re.search(r"none yet", ln) for ln in lines))


if __name__ == "__main__":
    unittest.main()
