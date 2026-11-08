"""wslib.agent_sandbox: ws-agent's own bwrap around every engine and check. It hides the home
directory, other jobs and registered working copies (whatever an engine reads goes to its
provider), keeps the job's directory writable, and can cut the network."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from agent_helpers import AgentScratch, git

from wslib import agent_registry as reg
from wslib import agent_sandbox as sbx
from wslib import jobs

HAVE_BWRAP = bool(shutil.which("bwrap"))
PY = sys.executable


def _job(job_id: str, repo: str = "~/src/proj", vcs: str = "svn") -> jobs.Job:
    job = jobs.Job(id=job_id, title="t", repo=repo, vcs=vcs, base={}, prompt_sha="s", paths=[], created="x",
                   session_id="", timeout="2h")
    jobs.save(job)
    (jobs.job_dir(job_id) / "wc").mkdir(parents=True, exist_ok=True)
    return job


class Sandbox(AgentScratch):
    def setUp(self) -> None:
        super().setUp()
        # Outside /tmp and $HOME, which the sandbox hides wholesale: only the hide list can hide these.
        self.outside = Path(tempfile.mkdtemp(prefix="ws-sbx-", dir="/var/tmp"))
        self.addCleanup(shutil.rmtree, self.outside, True)
        self.job = _job("aaa111")
        self.jd = jobs.job_dir("aaa111")
        self.wc = self.jd / "wc"

    def run_in(self, code: str, **kw: object) -> subprocess.CompletedProcess[str]:
        argv = sbx.wrap([PY, "-I", "-c", code], job_id="aaa111", wc=self.wc, **kw)  # type: ignore[arg-type]
        return subprocess.run(argv, capture_output=True, text=True, timeout=60)

    def readable(self, path: Path, **kw: object) -> bool:
        r = self.run_in(f"open({str(path)!r}).read()", **kw)
        return r.returncode == 0


@unittest.skipUnless(HAVE_BWRAP, "bwrap not installed")
class Layout(Sandbox):
    def test_home_is_hidden_but_the_copy_is_writable(self) -> None:
        secret = self.write(self.home / "secret.txt", "s")
        self.assertFalse(self.readable(secret))
        r = self.run_in(f"open({str(self.wc / 'x')!r}, 'w').write('in')")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.wc / "x").read_text(), "in")
        r = self.run_in(f"open({str(self.home / 'out')!r}, 'w').write('o')")
        self.assertFalse((self.home / "out").exists())   # the hidden home is a throwaway layer

    def test_other_jobs_and_registered_repos_are_hidden(self) -> None:
        os.environ["WS_STATE_DIR"] = str(self.outside / "state")   # jobs outside /tmp and $HOME
        self.job = _job("aaa111")
        self.jd, self.wc = jobs.job_dir("aaa111"), jobs.job_dir("aaa111") / "wc"
        sibling = _job("bbb222")
        other = self.write(jobs.job_dir(sibling.id) / "wc" / "f.txt", "other job")
        repo = self.outside / "company" / "wc"
        repo.mkdir(parents=True)
        reg.allow(repo, "svn", [])
        in_repo = self.write(repo / "src.c", "code")
        hidden = self.write(self.outside / "data" / "svn" / "x.txt", "hidden")
        self.write(reg.registry_path(), reg.registry_path().read_text() + f'\n[sandbox]\nhide = ["{self.outside / "data"}"]\n')
        own = self.write(self.jd / "result" / "r.txt", "mine")
        for p in (other, in_repo, hidden):
            self.assertTrue(p.exists())
            self.assertFalse(self.readable(p), p)
        self.assertTrue(self.readable(own))

    def test_symlink_out_of_the_copy_reads_nothing(self) -> None:
        secret = self.write(self.home / "secret.txt", "s")
        outside = self.write(self.outside / "o.txt", "o")
        reg.allow(self.outside, "svn", [])
        (self.wc / "link").symlink_to(secret)
        (self.wc / "link2").symlink_to(outside)
        self.assertFalse(self.readable(self.wc / "link"))
        self.assertFalse(self.readable(self.wc / "link2"))

    def test_network_off(self) -> None:
        r = self.run_in("import socket; socket.create_connection(('1.1.1.1', 53), 2)", network=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertRegex(r.stderr, r"(?i)unreachable|network|errno")

    def test_nested_sandbox_runs(self) -> None:
        argv = sbx.wrap(["bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--unshare-net", "--", "true"],
                        job_id="aaa111", wc=self.wc)
        r = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_extra_ro_and_rw_paths(self) -> None:
        ro = self.write(self.home / ".tool" / "bin.txt", "tool")
        rw = self.home / ".state"
        rw.mkdir()
        self.assertTrue(self.readable(ro, ro=[ro.parent]))
        r = self.run_in(f"open({str(ro)!r}, 'w').write('x')", ro=[ro.parent])
        self.assertNotEqual(r.returncode, 0)
        r = self.run_in(f"open({str(rw / 's')!r}, 'w').write('kept')", rw=[rw])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((rw / "s").read_text(), "kept")

    def test_git_config_secrets_are_hidden(self) -> None:
        repo = self.git_repo()
        cfg = repo / ".git" / "config"
        cfg.write_text(cfg.read_text() + '[remote "origin"]\n\turl = https://x-access-token:SECRET-TOKEN-1@github.com/o/r\n'
                       '\tfetch = +refs/heads/*:refs/remotes/origin/*\n[http]\n\textraheader = AUTHORIZATION: basic SECRET-2\n'
                       '[credential]\n\thelper = store\n[user]\n\tname = kept\n')
        job = _job("ddd444", repo="~/src/proj", vcs="git")
        wc = jobs.job_dir(job.id) / "wc"
        wc.rmdir()
        git("worktree", "add", "-q", "-b", "ws-agent/ddd444", str(wc), cwd=repo)
        r = subprocess.run(sbx.wrap(["cat", str(cfg)], job_id=job.id, wc=wc), capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("SECRET", r.stdout)
        self.assertNotIn("helper", r.stdout)
        self.assertIn("name = kept", r.stdout)            # the rest of the config stays
        self.assertIn("SECRET-TOKEN-1", cfg.read_text())  # the person's file is untouched
        env = {**os.environ, "GIT_OPTIONAL_LOCKS": "0"}
        for argv in (["git", "-C", str(wc), "status", "--short"], ["git", "-C", str(wc), "log", "--oneline", "-1"]):
            r = subprocess.run(sbx.wrap(argv, job_id=job.id, wc=wc), capture_output=True, text=True, timeout=60, env=env)
            self.assertEqual(r.returncode, 0, (argv, r.stderr))

    def test_the_folder_around_an_outside_registered_copy_is_hidden(self) -> None:
        company = self.outside / "data" / "svn"
        registered = company / "projB"
        registered.mkdir(parents=True)
        reg.allow(registered, "svn", [])
        neighbour = self.write(company / "projA" / "src.c", "SECRET-NEIGHBOUR")   # not registered, not in hide
        self.assertFalse(self.readable(neighbour))
        self.assertTrue(neighbour.exists())

    def test_the_folder_hiding_never_hides_what_the_job_needs(self) -> None:
        company = self.outside / "opt"
        registered = company / "repo"
        registered.mkdir(parents=True)
        reg.allow(registered, "svn", [])
        tool = self.write(company / "tools" / "tool.txt", "a tool")
        self.assertTrue(self.readable(tool, ro=[tool.parent]))   # a bound tool's folder is never hidden

    def test_git_dir_is_read_only(self) -> None:
        repo = self.git_repo()
        job = _job("ccc333", repo="~/src/proj", vcs="git")
        wc = jobs.job_dir(job.id) / "wc"
        wc.rmdir()
        git("worktree", "add", "-q", "-b", "ws-agent/ccc333", str(wc), cwd=repo)
        env = {**os.environ, "GIT_OPTIONAL_LOCKS": "0"}
        argv = sbx.wrap(["git", "-C", str(wc), "status", "--short"], job_id=job.id, wc=wc)
        r = subprocess.run(argv, capture_output=True, text=True, timeout=60, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        code = f"open({str(repo / '.git' / 'x')!r}, 'w').write('x')"
        r = subprocess.run(sbx.wrap([PY, "-I", "-c", code], job_id=job.id, wc=wc), capture_output=True, text=True,
                           timeout=60)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((repo / ".git" / "x").exists())
        self.assertFalse(subprocess.run(sbx.wrap([PY, "-I", "-c", f"open({str(repo / 'app.py')!r}).read()"],
                                                 job_id=job.id, wc=wc), capture_output=True).returncode == 0)


class Probe(Sandbox):
    @unittest.skipUnless(HAVE_BWRAP, "bwrap not installed")
    def test_probe_caches_and_reports(self) -> None:
        self.assertIsNone(sbx.probe(force=True))
        cache = json.loads((Path(os.environ["WS_STATE_DIR"]) / "agent-sandbox.json").read_text())
        self.assertIs(cache["ok"], True)
        os.environ["PATH"] = str(self.bin)   # no bwrap on PATH
        self.assertIsNone(sbx.probe())        # cached
        reason = sbx.probe(force=True)
        assert reason is not None
        self.assertIn("bwrap", reason)

    def test_wrap_without_bwrap_raises(self) -> None:
        os.environ["PATH"] = str(self.bin)
        with self.assertRaises(sbx.SandboxError):
            sbx.wrap(["true"], job_id="aaa111", wc=self.wc)

    def test_hidden_paths(self) -> None:
        _job("bbb222")
        reg.allow(self.outside, "svn", [])
        self.write(reg.registry_path(), reg.registry_path().read_text() + '\n[sandbox]\nhide = ["/data/svn"]\n')
        hidden = sbx.hidden_paths("aaa111")
        self.assertIn(jobs.job_dir("bbb222"), hidden)
        self.assertNotIn(jobs.job_dir("aaa111"), hidden)
        self.assertIn(self.outside.resolve(), hidden)
        self.assertIn(Path("/data/svn"), hidden)


if __name__ == "__main__":
    unittest.main()
