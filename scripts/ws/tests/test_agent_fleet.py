"""wslib.agent_fleet: one view of jobs and inbox items on this host and on named hosts, pulled
over the person's own SSH only when asked. A fake `ssh` records its argv and answers per host."""

from __future__ import annotations

import io
import json
import os
import shlex
import unittest
from contextlib import chdir, redirect_stderr, redirect_stdout

from agent_helpers import AgentScratch

from wslib import agent, agent_fleet, agent_inbox, agent_ui, core, jobs
from wslib import agent_registry as reg

FAKE_SSH = r"""d="$WS_FAKE_SSH"
( IFS=$'\x1f'; printf '%s\n' "$*" ) >>"$d/argv.log"
host=""
for a in "$@"; do case "$a" in -*) ;; *) [ -z "$host" ] && [ "$prev" != -o ] && host="$a" ;; esac; prev="$a"; done
[ -f "$d/$host.out" ] || { echo "ssh: connect to host $host: Connection timed out" >&2; exit 255; }
cat "$d/$host.out"
"""


def remote(jobs_: list[dict[str, object]], inbox: list[dict[str, object]]) -> str:
    return json.dumps(jobs_) + "\n" + agent_fleet.MARK + "\n" + json.dumps(inbox) + "\n"


class Fleet(AgentScratch):
    def setUp(self) -> None:
        super().setUp()
        self.sx = self.root / "fake-ssh"
        self.sx.mkdir()
        os.environ["WS_FAKE_SSH"] = str(self.sx)
        self.fake("ssh", FAKE_SSH)
        self.pueue_status({})

    def cli(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err), chdir(self.root):
            rc = agent.main(list(args))
        return rc, out.getvalue(), err.getvalue()

    def ssh_calls(self) -> list[list[str]]:
        log = self.sx / "argv.log"
        return [ln.split("\x1f") for ln in log.read_text().splitlines()] if log.exists() else []

    def test_hosts_are_the_persons_to_set(self) -> None:
        self.assertEqual(self.cli("fleet", "add", "dev10")[0], 0)
        self.assertEqual(self.cli("fleet", "add", "me@dev11.example")[0], 0)
        self.assertEqual(reg.settings().fleet, ("dev10", "me@dev11.example"))
        for bad in ("-oProxyCommand=x", "a b", "x;y", ""):
            self.assertEqual(self.cli("fleet", "add", bad)[0], 2, bad)
        self.assertEqual(self.cli("fleet", "remove", "dev10")[0], 0)
        self.assertEqual(reg.settings().fleet, ("me@dev11.example",))
        os.environ["CLAUDECODE"] = "1"
        self.assertEqual(self.cli("fleet", "add", "dev12")[0], 3)   # like allow: not from a session
        self.assertEqual(reg.settings().fleet, ("me@dev11.example",))

    def test_rows_from_this_host_and_the_fleet(self) -> None:
        mine = jobs.Job(id="aaa111", title="local job", repo="~/src/proj", vcs="git", base={}, prompt_sha="s", paths=[],
                        created=core.now_iso(), session_id="", timeout="2h")
        jobs.save(mine)
        reg.set_fleet(("dev10", "dev11"))
        self.write(self.sx / "dev10.out", remote(
            [{"id": "bbb222", "state": "succeeded", "title": "remote\x1b[2J job\tx", "repo": "/data/svn/projA"},
             {"id": "ccc333", "state": "closed", "title": "old", "repo": "/data/svn/projA"}],
            [{"id": "1234567890", "status": "open", "decision": {"decision": "ask"},
              "candidate": {"title": "r9 by bob: fix", "repo": "/data/svn/projA", "explicit": False}}]))
        rows = [r.split("\t") for r in agent_fleet.rows()]
        self.assertTrue(all(len(r) == 6 for r in rows), rows)
        self.assertEqual([r[:3] for r in rows], [["local", "job", "aaa111"], ["dev10", "job", "bbb222"],
                                                 ["dev10", "inbox", "1234567890"], ["dev11", "down", "-"]])
        self.assertNotIn("\x1b", "\n".join("\t".join(r) for r in rows))   # a remote title is someone else's text
        self.assertIn("Connection timed out", rows[3][4])
        call = self.ssh_calls()[0]
        self.assertIn("BatchMode=yes", call)
        self.assertIn("ConnectTimeout=5", call)
        rc, out, _ = self.cli("fleet")
        self.assertEqual(rc, 0)
        self.assertRegex(out, r"dev10\s+bbb222\s+succeeded")
        self.assertRegex(out, r"dev11\s+-\s+unreachable")
        rc, out, _ = self.cli("fleet", "--json")
        self.assertEqual({r["host"] for r in json.loads(out)}, {"local", "dev10", "dev11"})

    def test_on_runs_the_command_there_shell_quoted(self) -> None:
        reg.set_fleet(("dev10",))
        self.write(self.sx / "dev10.out", "done\n")
        rc, out, err = self.cli("_on", "dev10", "tell", "bbb222", 'fix "it"; rm -rf ~ $(id)')
        self.assertEqual(rc, 0, err)   # ssh's own output goes straight to the terminal, not through ws-agent
        call = self.ssh_calls()[-1]
        self.assertEqual(call[call.index("dev10") - 1], "--")   # the host can't be read as an option
        sent = call[call.index("dev10") + 1:]
        self.assertEqual(len(sent), 1)   # one word for the remote shell
        inner = shlex.split(sent[0])
        self.assertEqual(inner[:2], ["bash", "-lc"])
        self.assertEqual(shlex.split(inner[2]), ["ws-agent", "tell", "bbb222", 'fix "it"; rm -rf ~ $(id)'])
        self.assertEqual(self.cli("_on", "elsewhere", "ls")[0], 3)   # only hosts the person listed
        self.assertEqual(self.cli("_on", "local", "ls", "--all")[0], 0)
        self.assertEqual(len(self.ssh_calls()), 1)   # local runs here
        os.environ["WS_AGENT_JOB"] = "abc123"
        self.assertEqual(self.cli("_on", "dev10", "ls")[0], 3)

    def test_the_fleet_view_binds(self) -> None:
        argv = agent_ui.fzf_argv("ws-agent", fleet=True)
        self.assertEqual(argv[argv.index("--with-nth") + 1], "1,3..")
        preview = argv[argv.index("--preview") + 1]
        self.assertIn("ws-agent _on {1} show {3}", preview)
        self.assertIn("ws-agent _on {1} inbox --show {3}", preview)
        binds = {b.split(":", 1)[0]: b for b in (argv[i + 1] for i, a in enumerate(argv) if a == "--bind")}
        for key, word in (("enter", "result {3} --diff"), ("alt-t", "tell {3}"), ("alt-r", "retry {3}"),
                          ("alt-c", "cancel {3}"), ("alt-x", "close {3}"), ("alt-a", "accept {3}"),
                          ("alt-d", "dismiss {3}")):
            self.assertIn(f"ws-agent _on {{1}} {word}", binds[key])
            self.assertRegex(binds[key], r"^[a-z-]+:execute\([^)]*\)\+reload\(ws-agent ui --fleet --rows\)$")
        rc, out, _ = self.cli("ui", "--fleet", "--rows")
        self.assertEqual(out.splitlines(), agent_fleet.rows())
        self.assertEqual(agent_inbox.items(), [])


if __name__ == "__main__":
    unittest.main()
