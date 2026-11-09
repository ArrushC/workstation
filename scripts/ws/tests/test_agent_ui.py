"""wslib.agent_ui and `ws-agent ui`: jobs and inbox items in one fzf list, with `show` (or the
item) as the preview and alt-keys for tell, retry, cancel, close, accept and dismiss."""

from __future__ import annotations

import io
import os
import unittest
from contextlib import chdir, redirect_stderr, redirect_stdout
from pathlib import Path

from agent_helpers import AgentScratch

from wslib import agent, agent_inbox, agent_ui, core, jobs


def _job(title: str, *, closed: bool = False) -> jobs.Job:
    j = jobs.Job(id=jobs.new_id(), title=title, repo="~/src/proj", vcs="git", base={}, prompt_sha=title, paths=[],
                 created=core.now_iso(), session_id="", timeout="2h", closed=closed)
    jobs.save(j)
    return j


def _item(cid: str, title: str) -> agent_inbox.Item:
    return agent_inbox.add(agent_inbox.Candidate(cid=cid, source="svn", repo="~/src/svnwc", explicit=False, author="a",
                                                 title=title, text="t", base={}, prompt="p"),
                           {"decision": "ask", "reason": "unsure"})


class Ui(AgentScratch):
    def cli(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err), chdir(self.root):
            rc = agent.main(list(args))
        return rc, out.getvalue(), err.getvalue()

    def test_rows_jobs_then_inbox(self) -> None:
        a = _job("first job")
        _job("closed one", closed=True)
        b = _job("tab\there\x1b[2J")
        it = _item("svn:u:5", "r5 by a: fix")
        gone = _item("svn:u:6", "r6")
        agent_inbox.resolve(gone, "dismissed")
        self.pueue_status({})
        rows = agent_ui.rows()
        self.assertEqual([r.split("\t")[0] for r in rows], ["job", "job", "inbox"])   # jobs first
        self.assertEqual({r.split("\t")[1] for r in rows[:2]}, {a.id, b.id})
        self.assertEqual(rows[2].split("\t")[1], it.id)
        self.assertTrue(all(len(r.split("\t")) == 5 for r in rows))   # a title's own tab can't add a column
        self.assertNotIn("\x1b", "".join(rows))
        self.assertEqual(rows[2].split("\t")[2:], ["ask", "r5 by a: fix", "~/src/svnwc"])
        self.assertEqual({r.split("\t")[2] for r in rows[:2]}, {"interrupted"})

    def test_fzf_argv_binds(self) -> None:
        argv = agent_ui.fzf_argv("ws-agent")
        self.assertEqual(argv[0], "fzf")
        self.assertEqual(argv[argv.index("--delimiter") + 1], "\\t")
        self.assertEqual(argv[argv.index("--with-nth") + 1], "2..")
        self.assertEqual(argv[argv.index("--with-shell") + 1], "bash -c")   # read -p is bash's, whatever $SHELL is
        preview = argv[argv.index("--preview") + 1]
        self.assertIn("ws-agent show {2}", preview)
        self.assertIn("ws-agent inbox --show {2}", preview)
        self.assertIn("{1}", preview)
        binds = [argv[i + 1] for i, a in enumerate(argv) if a == "--bind"]
        keys = {b.split(":", 1)[0]: b for b in binds}
        self.assertEqual(set(keys), {"enter", "alt-t", "alt-r", "alt-c", "alt-x", "alt-a", "alt-d"})
        for key, word in (("enter", "result {2} --diff"), ("alt-t", "tell {2}"), ("alt-r", "retry {2}"),
                          ("alt-c", "cancel {2}"), ("alt-x", "close {2}"), ("alt-a", "accept {2}"),
                          ("alt-d", "dismiss {2}")):
            self.assertIn(f"ws-agent {word}", keys[key])
            self.assertTrue(keys[key].endswith("+reload(ws-agent ui --rows)"), keys[key])
        for b in binds:   # fzf ends execute(...) at the first ')', so the command holds none
            self.assertRegex(b, r"^[a-z-]+:execute\([^)]*\)\+reload\([^)]*\)$")
        self.assertIn("read -r -p", keys["alt-t"])
        self.assertIn("${PAGER:-less}", keys["enter"])

    def test_ui_without_fzf(self) -> None:
        os.environ["PATH"] = f"{self.bin}{os.pathsep}/nonexistent"
        rc, _, err = self.cli("ui")
        self.assertEqual(rc, 1)
        self.assertIn("fzf isn't installed", err)

    def test_ui_runs_fzf_with_rows(self) -> None:
        a = _job("first job")
        self.pueue_status({})
        rec = self.root / "fzf-rec"
        rec.mkdir()
        self.fake("fzf", f'printf "%s\\n" "$@" >"{rec}/argv"\ncat >"{rec}/stdin"\nexit 130')
        rc, _, err = self.cli("ui")
        self.assertEqual(rc, 0, err)   # esc in fzf is a normal exit
        self.assertIn(f"job\t{a.id}\t", (rec / "stdin").read_text())
        argv = (rec / "argv").read_text()
        self.assertIn("--bind", argv)
        self.assertIn(" agent ui --rows)", argv)   # binds call this ws back
        rc, out, _ = self.cli("ui", "--rows")
        self.assertEqual(out.splitlines(), agent_ui.rows())

    def test_palette_actions(self) -> None:
        import tomllib
        from helpers import WS
        actions = {a["id"]: a for a in tomllib.loads(Path(WS / "actions.toml").read_text())["action"]}
        self.assertEqual(actions["agent-ui"]["ws"], ["agent", "ui"])
        self.assertEqual(actions["agent-ui"]["requires"], ["fzf", "pueue"])
        self.assertEqual(actions["agent-inbox"]["ws"], ["agent", "inbox"])
        self.assertEqual(actions["agent-inbox"]["kind"], "read")


if __name__ == "__main__":
    unittest.main()
