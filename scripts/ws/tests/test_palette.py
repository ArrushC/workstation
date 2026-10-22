"""The catalogue and the palette: every entry well-formed and pointing at something real,
search by intent, OS and shell filters, the cheatsheet, and dispatch (structured argv,
confirmation, cancellation, ids only)."""

from __future__ import annotations

import io
import json
import os
import re
import subprocess
import sys
import tomllib
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from helpers import REPO, Scratch

from wslib import catalog, palette
from wslib.catalog import Action


class Catalogue(unittest.TestCase):
    def setUp(self) -> None:
        self.cat = catalog.load()

    def test_loads_clean(self) -> None:
        self.assertEqual(self.cat.problems, [])
        self.assertGreater(len(self.cat.actions), 30)

    def test_ascii_only(self) -> None:
        # PowerShell 5.1 consoles print `wsh`.
        text = catalog.CATALOGUE.read_text(encoding="utf-8")
        self.assertEqual([ln for ln in text.splitlines() if not ln.isascii()], [])

    def test_tasks_exist(self) -> None:
        defined = {p.name for p in (REPO / "tasks").iterdir()}
        for f in ("config.toml", "config.linux.toml", "config.windows.toml"):
            with open(REPO / f, "rb") as fh:
                defined |= set(tomllib.load(fh).get("tasks", {}))
        for a in self.cat.actions:
            if a.task:
                self.assertIn(a.task, defined, a.id)

    def test_docs_exist(self) -> None:
        for a in self.cat.actions:
            if a.doc:
                name, _, heading = a.doc.partition("#")
                text = (REPO / name).read_text(encoding="utf-8")
                self.assertTrue(palette.section(text, heading), f"{a.id}: no heading {heading!r} in {name}")

    def test_fixes_name_health_rows(self) -> None:
        rows = set(re.findall(r'row_(?:ok|warn|bad|skip) "([^"]+)"', (REPO / "tasks/health").read_text()))
        for a in self.cat.actions:
            for f in a.fixes:
                self.assertIn(f, rows, f"{a.id} fixes {f!r}, which tasks/health has no row for")

    def test_search_by_intent(self) -> None:
        # By OS and shell only: what's on this host's PATH (winterop, cheat) doesn't matter here.
        acts = [a for a in self.cat.actions if (not a.os or "linux" in a.os) and (not a.shells or "zsh" in a.shells)]
        for words, want in ((["python"], "python-env-rebuild"), (["rebuild"], "python-env-rebuild"),
                            (["ssh"], "fssh"), (["clipboard"], "clip-get"), (["paste"], "osc52"),
                            (["update"], "wsu-linux"), (["upgrade"], "wsu-linux"), (["dotfiles"], "reconcile"),
                            (["merge"], "reconcile"), (["workspace"], "open"), (["worktree"], "open"),
                            (["recover"], "backups"), (["fix"], "health-fix")):
            ids = [a.id for a in palette.search(self.cat, acts, words)]
            self.assertIn(want, ids, f"{words} -> {ids}")

    def test_os_and_shell_filters(self) -> None:
        wsu = {a.id: a for a in self.cat.actions}
        self.assertTrue(wsu["wsu-linux"].available("linux", "zsh"))
        self.assertFalse(wsu["wsu-linux"].available("windows", "nu"))
        self.assertTrue(wsu["wsu-windows"].available("windows", "pwsh"))
        self.assertFalse(wsu["fzf-shell"].available("linux", "nu"))
        self.assertFalse(Action(id="x", title="x", requires=["no-such-command-ws"], text=["x"]).available("linux", "zsh"))

    def test_help_per_shell(self) -> None:
        nu = catalog.help_text(self.cat, "windows", "nu")
        self.assertIn("nushell\\autoload", nu)
        self.assertIn("wsu", nu)
        self.assertNotIn("zs [name]", nu)  # zellij is Linux-only
        bash = catalog.help_text(self.cat, "linux", "bash")
        self.assertIn("~/.bashrc.local", bash)
        self.assertNotIn("~/.zshrc.local", bash)
        for alias in ("wse", "wsd", "wsa", "wsr", "wss", "wsu", "wsh", "ws reconcile", "ws open [project]"):
            self.assertRegex(bash, rf"(?m)^  {re.escape(alias)}\s", alias)


class Dispatch(Scratch):
    def action(self, **kw: object) -> Action:
        base: dict[str, object] = {"id": "t", "title": "t", "kind": "change"}
        base.update(kw)
        return Action(**base)  # type: ignore[arg-type]

    def test_change_needs_confirmation(self) -> None:
        out = self.root / "ran"
        a = self.action(run=[sys.executable, "-c", "open(r'%s', 'w').write('x')" % out])
        with redirect_stdout(io.StringIO()) as buf:
            self.assertEqual(palette.dispatch(a), 0)
        self.assertFalse(out.exists())
        self.assertIn("cancelled", buf.getvalue())

    def test_argv_is_passed_as_is(self) -> None:
        out = self.home / "out file"
        tricky = "a b; rm -rf x $(whoami) 'q' \"dq\""
        code = "import sys; open(sys.argv[1], 'w').write(sys.argv[2])"
        a = self.action(run=[sys.executable, "-c", code, "{home}/out file", tricky])
        with redirect_stdout(io.StringIO()):
            self.assertEqual(palette.dispatch(a, yes=True), 0)
        self.assertEqual(out.read_text(), tricky)

    def test_insert_and_cd_go_to_the_shell(self) -> None:
        ws_out = self.root / "ws-out"
        os.environ["WS_OUT"] = str(ws_out)
        palette.dispatch(self.action(kind="change", insert="wsa"))
        palette.dispatch(self.action(kind="open", cd="{repo}"))
        self.assertEqual(ws_out.read_text().splitlines(), ["insert\twsa", f"cd\t{self.repo}"])
        os.environ["WS_SHELL"] = "pwsh"  # PowerShell can't take a prompt insert: it's printed
        with redirect_stdout(io.StringIO()) as buf:
            palette.dispatch(self.action(kind="change", insert="wsa"))
        self.assertIn("Run: wsa", buf.getvalue())
        self.assertEqual(len(ws_out.read_text().splitlines()), 2)

    def palette_with_fzf(self, fzf_body: str) -> tuple[int, str]:
        log = self.root / "mise.log"
        self.fake_mise(log=log)
        self.fake("fzf", fzf_body)
        os.environ.pop("WS_NONINTERACTIVE")
        with mock.patch("wslib.core.interactive", return_value=True), redirect_stdout(io.StringIO()):
            rc = palette.main([])
        return rc, log.read_text() if log.exists() else ""

    def test_cancel_runs_nothing(self) -> None:
        rc, log = self.palette_with_fzf("cat >/dev/null; exit 130")
        self.assertEqual(rc, 0)
        self.assertNotIn("dot diff", log)

    def test_only_listed_ids_run(self) -> None:
        # Whatever the picker returns, only an id the palette listed maps to a command.
        rc, log = self.palette_with_fzf("cat >/dev/null; printf 'mise -C / dot apply --yes\\tx\\n'")
        self.assertEqual(rc, 1)
        self.assertNotIn("dot apply", log)

    def test_pick_runs_its_action(self) -> None:
        rc, log = self.palette_with_fzf("grep '^wsd\t' | head -1")
        self.assertEqual(rc, 0)
        self.assertIn(f"-C {self.home} dot diff", log)

    def test_discovered_tasks(self) -> None:
        tasks = [{"name": "health", "description": "curated already", "global": True},
                 {"name": "fmt", "description": "format", "global": True, "source": str(self.repo / "config.toml")},
                 {"name": "secret", "hide": True, "global": True}]
        local = [{"name": "build", "description": "Build it", "global": False, "source": "mise.toml"}]
        proj = self.home / "proj"
        (proj / ".git").mkdir(parents=True)
        self.fake("mise", f"""case " $* " in
  *" --local "*) echo '{json.dumps(local)}' ;;
  *" tasks ls "*) echo '{json.dumps(tasks)}' ;;
esac""")
        found = {a.id: a for a in catalog.discover(catalog.load(), proj)}
        self.assertEqual(set(found), {"task:fmt", "project:build"})
        b = found["project:build"]
        self.assertEqual((b.argv(), b.cwd, b.kind), (["mise", "run", "build"], str(proj), "change"))
        self.assertEqual(found["task:fmt"].argv(), ["mise", "-C", str(self.home), "run", "fmt"])

    def test_health_rows_map_to_repairs(self) -> None:
        self.fake("mise", 'printf "bad\\tpython-env\\twpy reports 3.9\\nok\\tdisk\\tfine\\nwarn\\tnot a row we fix\\tx\\n" >"$WS_HEALTH_ROWS"')
        with redirect_stdout(io.StringIO()) as buf:
            palette.health()
        out = buf.getvalue()
        self.assertIn("python-env: -> Update the Python env", out)
        self.assertIn("not a row we fix: (no repair action", out)
        self.assertNotIn("disk", out)


class Cli(Scratch):
    def run_ws(self, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(REPO / "scripts/ws/ws.py"), *args], capture_output=True,
                              text=True, env=dict(os.environ, **(env or {})))

    def test_hooks_never_fail(self) -> None:
        # No mise on PATH at all: the hook says so and exits 0, so a bootstrap carries on.
        p = self.run_ws("baseline", "record", env={"PATH": str(self.bin)})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("not recorded", p.stderr)
        self.fake("mise", "echo 'not json'")
        p = self.run_ws("baseline", "snapshot")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("PRE-APPLY BACKUP FAILED: the check couldn't run", p.stderr)  # not "nothing to back up"

    def test_help_matches_catalogue(self) -> None:
        p = self.run_ws("help", env={"WS_SHELL": "nu"})
        self.assertEqual(p.returncode, 0)
        self.assertIn("ws reconcile", p.stdout)


if __name__ == "__main__":
    unittest.main()
