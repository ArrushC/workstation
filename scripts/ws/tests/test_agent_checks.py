"""wslib.agent_checks: the repository's checks, run by ws-agent itself on a job's result, inside
the job sandbox (no network unless the repository allows it), with a bounded output tail and a
time limit; and the verdict they give."""

from __future__ import annotations

import json
import os
import shutil
import unittest
from unittest import mock

from agent_helpers import AgentScratch

from wslib import agent_checks, agent_sandbox, jobs
from wslib import agent_registry as reg

HAVE_BWRAP = bool(shutil.which("bwrap"))


class Checks(AgentScratch):
    def setUp(self) -> None:
        super().setUp()
        self.job = jobs.Job(id="abc123", title="t", repo="~/src/p", vcs="svn", base={}, prompt_sha="s", paths=[],
                            created="x", session_id="", timeout="2h")
        jobs.save(self.job)
        self.jd = jobs.job_dir(self.job.id)
        self.wc = self.jd / "wc"
        self.wc.mkdir(parents=True)
        p = mock.patch.object(agent_sandbox, "probe", return_value=None)
        p.start()
        self.addCleanup(p.stop)

    def entry(self, *checks: str, network: bool = False) -> reg.Repo:
        return reg.Repo(path=self.wc, vcs="svn", checks=checks, network=network)

    def run_checks(self, *checks: str, **kw: object) -> list[agent_checks.CheckRun] | None:
        return agent_checks.run_checks(self.job, self.jd, self.entry(*checks, **kw), dict(os.environ))  # type: ignore[arg-type]


@unittest.skipUnless(HAVE_BWRAP, "bwrap not installed")
class Run(Checks):
    def test_checks_pass_and_fail(self) -> None:
        runs = self.run_checks("true", "sh -c 'echo boom; exit 3'")
        assert runs is not None
        self.assertEqual(agent_checks.verdict(runs), "fail")
        data = json.loads((self.jd / "result" / "checks.json").read_text())
        self.assertEqual([r["exit"] for r in data], [0, 3])
        self.assertEqual([r["cmd"] for r in data], ["true", "sh -c 'echo boom; exit 3'"])
        self.assertIn("boom", (self.jd / "result" / "checks.txt").read_text())
        self.assertEqual(agent_checks.verdict(self.run_checks("true")), "pass")

    def test_check_timeout_and_output_cap(self) -> None:
        with mock.patch.object(agent_checks, "CHECK_TIMEOUT", 1):
            runs = self.run_checks("sleep 5")
        assert runs is not None
        self.assertTrue(runs[0].timed_out)
        self.assertIsNone(runs[0].exit)
        self.assertEqual(agent_checks.verdict(runs), "fail")
        self.assertIn("timed out", (self.jd / "result" / "checks.txt").read_text())
        runs = self.run_checks("yes | head -c 5000000")
        assert runs is not None
        self.assertEqual(runs[0].exit, 0)
        self.assertLessEqual(len(runs[0].tail.encode()), agent_checks.OUTPUT_TAIL)
        self.assertLess((self.jd / "result" / "checks.txt").stat().st_size, 2 * agent_checks.OUTPUT_TAIL)

    def test_checks_run_sandboxed_without_network(self) -> None:
        runs = self.run_checks(f"touch {self.home / 'x'} && test -e {self.home / 'x'}")
        assert runs is not None
        self.assertFalse((self.home / "x").exists())   # the home directory is a throwaway layer
        runs = self.run_checks("touch ./made-here")
        assert runs is not None
        self.assertEqual(runs[0].exit, 0)
        self.assertTrue((self.wc / "made-here").exists())
        runs = self.run_checks("python3 -c \"import socket; socket.create_connection(('1.1.1.1', 53), 2)\"")
        assert runs is not None
        self.assertNotEqual(runs[0].exit, 0)
        secret = self.write(self.home / "secret.txt", "s")
        runs = self.run_checks(f"cat {secret}")
        assert runs is not None
        self.assertNotEqual(runs[0].exit, 0)
        self.assertNotIn("s\n", runs[0].tail.replace("No such", ""))

    def test_no_checks_is_none(self) -> None:
        self.assertEqual(self.run_checks(), [])
        self.assertEqual(agent_checks.verdict([]), "none")


class NoSandbox(Checks):
    def test_no_sandbox_means_not_run(self) -> None:
        marker = self.wc / "ran"
        with mock.patch.object(agent_sandbox, "probe", return_value="no bwrap"):
            runs = self.run_checks(f"touch {marker}")
        self.assertIsNone(runs)
        self.assertEqual(agent_checks.verdict(None), "not run")
        self.assertFalse(marker.exists())
        self.assertIn("not run", (self.jd / "result" / "checks.txt").read_text())


if __name__ == "__main__":
    unittest.main()
