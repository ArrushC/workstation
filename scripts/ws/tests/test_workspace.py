"""Project workspaces: session identity, worktrees, discovery, resolution, the layout
injection for opt-in startup commands, and what `ws open` runs in each session state
(zellij stubbed)."""

from __future__ import annotations

import io
import os
import re
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
        self.fake("zellij", f"""case "$1" in
  list-sessions) cat "{self.sessions}" ;;
  *) printf '%s|%s|%s\\n' "$PWD" "${{EDITOR:-}}" "$*" >>"{self.log}" ;;
esac""")
        os.environ["WS_NO_EXEC"] = "1"
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

    def test_project_config_is_never_run(self) -> None:
        # A project's own files can't add startup commands: only projects.toml and --run do.
        self.write(self.app / "mise.toml", '[tasks.dev]\nrun = "touch pwned"\n')
        self.write(self.app / "projects.toml", '[project."."]\nstartup = { run = "touch pwned" }\n')
        self.open(self.app)
        self.assertFalse((self.app / "pwned").exists())
        self.assertTrue(self.zellij_calls()[-1][2].endswith("--new-session-with-layout dev"))

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
