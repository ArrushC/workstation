"""`ws agent` / `ws-agent`: queue, inspect, cancel, retry and close headless agent jobs, and the
one-line orchestration context the SessionStart hook prints."""

from __future__ import annotations

import io
import json
import os
import shutil
import subprocess
import unittest
from contextlib import chdir, redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from agent_helpers import HAVE_SVN, AgentScratch, git, svn
from helpers import REPO, WS

from wslib import agent, core, jobs
from wslib import agent_exec as ax
from wslib import agent_registry as reg

QUEUED = {"status": {"Queued": {"enqueued_at": "2026-11-06T23:48:51.387887077Z"}}}
RUNNING = {"status": {"Running": {"enqueued_at": "2026-11-06T23:48:39Z", "start": "2026-11-06T23:48:41Z"}}}
KILLED = {"status": {"Done": {"enqueued_at": "2026-11-06T23:48:39Z", "start": "2026-11-06T23:48:40Z",
                              "end": "2026-11-06T23:48:41Z", "result": "Killed"}}}


class Cli(AgentScratch):
    def cli(self, *args: str, cwd: Path | None = None) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err), chdir(cwd or self.root):
            rc = agent.main(list(args))
        return rc, out.getvalue(), err.getvalue()

    def queued_run(self, repo: Path, prompt: str = "do it", *extra: str) -> str:
        rc, out, err = self.cli("run", "--title", "t", "--prompt", prompt, "--repo", str(repo), *extra)
        self.assertEqual(rc, 0, err)
        return out.split()[0]


class Run(Cli):
    def test_run_refuses_unregistered(self) -> None:
        repo = self.git_repo()
        self.pueue_status({})
        rc, _, err = self.cli("run", "--title", "t", "--prompt", "x", "--repo", str(repo))
        self.assertEqual(rc, 3)
        self.assertIn("ws-agent allow", err)
        self.assertFalse(any(c[0] == "add" for c in self.pueue_calls()))

    def test_run_refuses_inside_job(self) -> None:
        repo = self.git_repo()
        reg.allow(repo, "git", [])
        self.pueue_status({})
        os.environ["WS_AGENT_JOB"] = "abc123"
        rc, _, err = self.cli("run", "--title", "t", "--prompt", "x", "--repo", str(repo))
        self.assertEqual(rc, 3)
        self.assertIn("queued job", err)

    def test_run_refuses_no_repository(self) -> None:
        d = self.root / "plain"
        d.mkdir()
        rc, _, err = self.cli("run", "--title", "t", "--prompt", "x", "--repo", str(d))
        self.assertEqual(rc, 3)
        self.assertIn("git or SVN", err)

    def test_run_records_base_and_queues(self) -> None:
        repo = self.git_repo()
        reg.allow(repo, "git", [])
        self.pueue_status({}, agents=False)
        jid = self.queued_run(repo, "add a cache")
        job = jobs.load(jid)
        self.assertEqual(job.base["commit"], git("rev-parse", "HEAD", cwd=repo))
        self.assertEqual(job.repo, "~/src/proj")
        self.assertEqual(job.pueue_id, 7)
        self.assertEqual((jobs.job_dir(jid) / "prompt.md").read_text(), "add a cache")
        calls = self.pueue_calls()
        self.assertIn(["group", "add", "agents", "--parallel", "1"], calls)
        add = [c for c in calls if c[0] == "add"][-1]
        self.assertEqual(add[add.index("--group") + 1], "agents")

    def test_run_prompt_file(self) -> None:
        repo = self.git_repo()
        reg.allow(repo, "git", [])
        self.pueue_status({})
        pf = self.write(self.root / "p.md", "from a file\n")
        rc, out, err = self.cli("run", "--title", "t", "--prompt-file", str(pf), "--repo", str(repo))
        self.assertEqual(rc, 0, err)
        self.assertEqual((jobs.job_dir(out.split()[0]) / "prompt.md").read_text(), "from a file\n")

    def test_run_duplicate(self) -> None:
        repo = self.git_repo()
        reg.allow(repo, "git", [])
        self.pueue_status({})
        first = self.queued_run(repo, "same task")
        self.pueue_status({7: QUEUED})
        rc, out, err = self.cli("run", "--title", "t", "--prompt", "same task", "--repo", str(repo))
        self.assertEqual(rc, 3)
        self.assertIn(first, out + err)
        self.assertEqual(len(jobs.all_jobs()), 1)
        rc, _, err = self.cli("run", "--title", "t", "--prompt", "same task", "--repo", str(repo), "--force")
        self.assertEqual(rc, 0, err)
        self.assertEqual(len(jobs.all_jobs()), 2)

    def test_run_overlap_warns(self) -> None:
        repo = self.git_repo()
        reg.allow(repo, "git", [])
        self.pueue_status({})
        first = self.queued_run(repo, "one", "--paths", "src/a.c")
        self.pueue_status({7: RUNNING})
        rc, _, err = self.cli("run", "--title", "t", "--prompt", "two", "--repo", str(repo), "--paths", "src/*.c")
        self.assertEqual(rc, 0, err)
        self.assertIn(first, err)

    def test_run_pueued_down(self) -> None:
        repo = self.git_repo()
        reg.allow(repo, "git", [])
        rc, _, err = self.cli("run", "--title", "t", "--prompt", "x", "--repo", str(repo))
        self.assertEqual(rc, 1)
        self.assertIn("pueued", err)
        self.assertEqual(jobs.all_jobs(), [])

    def test_run_paused_queue_warns(self) -> None:
        repo = self.git_repo()
        reg.allow(repo, "git", [])
        self.pueue_status({}, group="Paused")
        rc, _, err = self.cli("run", "--title", "t", "--prompt", "x", "--repo", str(repo))
        self.assertEqual(rc, 0, err)
        self.assertIn("ws-agent resume", err)
        self.assertFalse(any(c[0] == "start" for c in self.pueue_calls()))

    def test_run_enqueue_failure_leaves_no_job(self) -> None:
        repo = self.git_repo()
        reg.allow(repo, "git", [])
        self.pueue_status({})
        self.write(self.pq / "fail-add", "")
        rc, _, err = self.cli("run", "--title", "t", "--prompt", "x", "--repo", str(repo))
        self.assertEqual(rc, 1)
        self.assertIn("pueue add failed", err)
        self.assertEqual(jobs.all_jobs(), [])


@unittest.skipUnless(HAVE_SVN, "svn/svnadmin not installed")
class RunSvn(Cli):
    def test_run_svn_mixed_needs_rev(self) -> None:
        url, wc = self.svn_repo()
        reg.allow(wc, "svn", [])
        self.pueue_status({})
        self.write(wc / "a.txt", "r2\n")
        svn("commit", "-m", "r2", cwd=wc)
        rc, _, err = self.cli("run", "--title", "t", "--prompt", "x", "--repo", str(wc))
        self.assertEqual(rc, 3)
        self.assertIn("--rev", err)
        jid = self.queued_run(wc, "x", "--rev", "1")
        job = jobs.load(jid)
        self.assertEqual(job.base, {"url": f"{url}/trunk", "repos_root": url, "rev": "1"})

    def test_run_svn_local_mods_warn(self) -> None:
        _, wc = self.svn_repo()
        reg.allow(wc, "svn", [])
        self.pueue_status({})
        self.write(wc / "a.txt", "local edit\n")
        rc, out, err = self.cli("run", "--title", "t", "--prompt", "x", "--repo", str(wc))
        self.assertEqual(rc, 0, err)
        self.assertIn("not included", err)
        self.assertTrue(any("not included" in w for w in jobs.load(out.split()[0]).warnings))


class Manage(Cli):
    def setUp(self) -> None:
        super().setUp()
        self.repo = self.git_repo()
        reg.allow(self.repo, "git", [])
        self.pueue_status({})

    def test_ls_json(self) -> None:
        a = self.queued_run(self.repo, "one")
        self.pueue_status({7: RUNNING})
        b = self.queued_run(self.repo, "two")
        self.pueue_status({7: RUNNING, 8: QUEUED})
        rc, out, _ = self.cli("ls", "--json", cwd=self.repo)
        self.assertEqual(rc, 0)
        rows = {r["id"]: r for r in json.loads(out)}
        self.assertEqual(rows[a]["state"], "running")
        self.assertEqual(rows[b]["state"], "queued")
        self.assertEqual(rows[a]["repo"], "~/src/proj")

    def test_ls_other_repo_hidden_unless_all(self) -> None:
        self.queued_run(self.repo, "one")
        other = self.git_repo("other")
        rc, out, _ = self.cli("ls", "--json", cwd=other)
        self.assertEqual(json.loads(out), [])
        rc, out, _ = self.cli("ls", "--json", "--all", cwd=other)
        self.assertEqual(len(json.loads(out)), 1)

    def test_cancel_then_state(self) -> None:
        jid = self.queued_run(self.repo)
        self.pueue_status({7: RUNNING})
        rc, _, err = self.cli("cancel", jid)
        self.assertEqual(rc, 0, err)
        self.assertEqual([c for c in self.pueue_calls() if c[0] in ("kill", "remove")], [["kill", "7"], ["remove", "7"]])
        self.assertEqual(jobs.state(jobs.load(jid), {}), "cancelled")
        rc, _, err = self.cli("cancel", jid)
        self.assertEqual(rc, 3)

    def test_retry_only_failed_or_interrupted(self) -> None:
        jid = self.queued_run(self.repo)
        self.pueue_status({7: RUNNING})
        rc, _, err = self.cli("retry", jid)
        self.assertEqual(rc, 3)
        self.assertIn("running", err)
        self.pueue_status({7: KILLED})
        self.write(jobs.job_dir(jid) / "exec.log", "--- attempt 1 start\nsomething went on\n")
        rc, out, err = self.cli("retry", jid)
        self.assertEqual(rc, 0, err)
        self.assertIn("Working copy:", out)   # inspected before recovering
        self.assertIn("something went on", out)
        add = [c for c in self.pueue_calls() if c[0] == "add"][-1]
        self.assertEqual(add[-1], "--resume")

    def test_retry_failed_archives_exit(self) -> None:
        jid = self.queued_run(self.repo)
        self.write(jobs.job_dir(jid) / "result" / "exit.json", '{"exit_code": 1}')
        job = jobs.load(jid)
        job.attempts = 1
        jobs.save(job)
        rc, _, err = self.cli("retry", jid)
        self.assertEqual(rc, 0, err)
        self.assertFalse((jobs.job_dir(jid) / "result" / "exit.json").exists())
        self.assertTrue((jobs.job_dir(jid) / "result" / "exit-1.json").exists())
        self.pueue_status({8: QUEUED})
        self.assertEqual(jobs.state(jobs.load(jid), {8: "Queued"}), "queued")

    def test_close_removes_wc_keeps_result(self) -> None:
        jid = self.queued_run(self.repo)
        job = jobs.load(jid)
        ax.prepare(job, jobs.job_dir(jid))
        self.write(jobs.job_dir(jid) / "result" / "changes.diff", "diff\n")
        rc, _, err = self.cli("close", jid)
        self.assertEqual(rc, 3)   # interrupted: retry or cancel first
        self.write(jobs.job_dir(jid) / "result" / "exit.json", '{"exit_code": 0}')
        rc, _, err = self.cli("close", jid)
        self.assertEqual(rc, 0, err)
        self.assertFalse((jobs.job_dir(jid) / "wc").exists())
        self.assertTrue((jobs.job_dir(jid) / "result" / "changes.diff").exists())
        self.assertNotIn(f"ws-agent/{jid}", git("branch", "--list", cwd=self.repo))
        self.assertEqual(len(git("worktree", "list", cwd=self.repo).splitlines()), 1)
        self.assertEqual(jobs.state(jobs.load(jid), {}), "closed")

    def test_result_shows_patch_and_warnings(self) -> None:
        jid = self.queued_run(self.repo)
        res = jobs.job_dir(jid) / "result"
        self.write(res / "exit.json", '{"exit_code": 0}')
        self.write(res / "claude.json", json.dumps({"type": "result", "is_error": False, "result": "Added the cache.",
                                                    "session_id": "S"}))
        self.write(res / "changes.diff", "diff --git a/app.py b/app.py\n--- a/app.py\n+++ b/app.py\n+x\n+y\n-z\n")
        self.write(res / "warnings.txt", "unversioned, not in the patch: extra.txt\n")
        self.write(res / "apply.txt", "Apply in your checkout:\n  git apply --index X\n")
        rc, out, _ = self.cli("result", jid)
        self.assertEqual(rc, 0)
        self.assertIn("succeeded", out)
        self.assertIn("Added the cache.", out)
        self.assertIn("app.py: +2 -1", out)
        self.assertIn("extra.txt", out)
        self.assertIn(str(res / "changes.diff"), out)
        self.assertIn("git apply --index", out)

    def test_pause_resume(self) -> None:
        self.assertEqual(self.cli("pause")[0], 0)
        self.assertEqual(self.cli("resume")[0], 0)
        self.assertEqual([c[0] for c in self.pueue_calls()[-2:]], ["pause", "start"])

    def test_show_unknown_job(self) -> None:
        rc, _, err = self.cli("show", "zzzzzz")
        self.assertEqual(rc, 1)
        self.assertIn("no job", err)


class Registry(Cli):
    def test_allow_refused_under_claudecode(self) -> None:
        repo = self.git_repo()
        os.environ["CLAUDECODE"] = "1"
        rc, _, err = self.cli("allow", str(repo))
        self.assertEqual(rc, 3)
        self.assertIn("your own terminal", err)
        self.assertIsNone(reg.find(repo))

    def test_allow_not_a_repository(self) -> None:
        d = self.root / "plain"
        d.mkdir()
        self.assertEqual(self.cli("allow", str(d))[0], 3)

    def test_allow_repos_disallow(self) -> None:
        repo = self.git_repo()
        rc, out, err = self.cli("allow", str(repo / "."), "--command", "make *")
        self.assertEqual(rc, 0, err)
        found = reg.find(repo)
        assert found is not None
        self.assertEqual(found.commands, ("make *",))
        rc, out, _ = self.cli("repos")
        self.assertIn("~/src/proj", out)
        self.assertIn("make *", out)
        self.assertEqual(self.cli("disallow", str(repo))[0], 0)
        self.assertIsNone(reg.find(repo))


class Context(Cli):
    def test_context_line_formats(self) -> None:
        repo = self.git_repo()
        self.pueue_status({})
        line = agent.context_line(repo)
        self.assertRegex(line, r"^\[orchestration\] git ~/src/proj main@[0-9a-f]{12} \| jobs: not allowed \(ws-agent allow\)"
                               r" \| here: none \| superagent: none$")
        reg.allow(repo, "git", [])
        jid = self.queued_run(repo)
        self.pueue_status({7: QUEUED})
        line = agent.context_line(repo)
        self.assertRegex(line, r"^\[orchestration\] git ~/src/proj main@[0-9a-f]{12} \| jobs: allowed; queue 0/1 running,"
                               rf" 1 queued \| here: {jid} queued \| superagent: none$")
        d = self.root / "plain"
        d.mkdir()
        self.assertEqual(agent.context_line(d), "[orchestration] no repository here | superagent: none")
        os.environ["WS_AGENT_JOB"] = jid
        self.assertIn(f"queued job {jid}", agent.context_line(repo))
        self.assertLessEqual(len(line), 400)

    def test_context_github_and_review(self) -> None:
        repo = self.git_repo()
        git("remote", "add", "origin", "https://github.com/ArrushC/proj.git", cwd=repo)
        reg.allow(repo, "git", [])
        self.pueue_status({})
        jid = self.queued_run(repo)
        self.write(jobs.job_dir(jid) / "result" / "exit.json", '{"exit_code": 0}')
        line = agent.context_line(repo)
        self.assertIn("git ~/src/proj github ArrushC/proj", line)
        self.assertIn(f"{jid} succeeded (review)", line)

    def test_context_never_raises(self) -> None:
        repo = self.git_repo()
        reg.allow(repo, "git", [])
        (self.bin / "pueue").unlink()
        os.environ["PATH"] = f"{self.bin}{os.pathsep}/usr/bin{os.pathsep}/bin"
        rc, out, _ = self.cli("context", cwd=repo)
        self.assertEqual(rc, 0)
        self.assertIn("queue: pueued not running", out)
        with mock.patch.object(agent.vcs, "probe", side_effect=RuntimeError("boom")):
            self.assertEqual(agent.context_line(repo), "")

    def test_context_paused(self) -> None:
        repo = self.git_repo()
        reg.allow(repo, "git", [])
        self.pueue_status({}, group="Paused")
        self.assertIn("queue paused (ws-agent resume)", agent.context_line(repo))

    @unittest.skipUnless(HAVE_SVN, "svn/svnadmin not installed")
    def test_context_svn(self) -> None:
        _, wc = self.svn_repo()
        reg.allow(wc, "svn", [])
        self.pueue_status({})
        self.assertRegex(agent.context_line(wc / "sub"),
                         r"^\[orchestration\] svn ~/src/svnwc \^/trunk@1 \| jobs: allowed; queue 0/1 running, 0 queued"
                         r" \| here: none \| superagent: none$")

    def test_route_json(self) -> None:
        repo = self.git_repo()
        reg.allow(repo, "git", ["make *"])
        self.pueue_status({})
        rc, out, _ = self.cli("route", "--json", cwd=repo)
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertEqual(set(data), {"vcs", "root", "base", "github", "allowed", "commands", "queue", "jobs", "superagent"})
        self.assertEqual(data["vcs"], "git")
        self.assertTrue(data["allowed"])
        self.assertEqual(data["superagent"], "none")
        self.assertEqual(data["commands"], ["make *"])


class Doctor(Cli):
    def test_doctor_no_secrets(self) -> None:
        self.fake("claude", 'case "$1 $2" in "auth status") echo \'{"loggedIn": true, "authMethod": "claude.ai", '
                            '"apiProvider": "firstParty", "email": "someone@example.invalid", "orgId": "org-123-secret", '
                            '"orgName": "Org", "subscriptionType": "pro"}\' ;; esac')
        self.pueue_status({})
        real_which = core.which
        with mock.patch.object(agent.core, "which", side_effect=lambda n: None if n == "svn" else real_which(n)):
            rc, out, _ = self.cli("doctor")
        self.assertEqual(rc, 1)   # svn missing is a finding
        self.assertIn("claude.ai", out)
        self.assertIn("pro", out)
        self.assertNotIn("someone@example.invalid", out)
        self.assertNotIn("org-123-secret", out)
        self.assertRegex(out, r"svn.*not installed")


class Launcher(AgentScratch):
    def test_launcher_runs(self) -> None:
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "scripts" / "ws").symlink_to(WS)
        r = subprocess.run(["bash", str(REPO / "dotfiles" / "local" / "bin" / "ws-agent"), "repos"], capture_output=True,
                           text=True, env=os.environ.copy())
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("no repositories", r.stdout)

    def test_ws_dispatches_agent(self) -> None:
        r = subprocess.run([shutil.which("python3") or "python3", str(WS / "ws.py"), "agent", "repos"], capture_output=True,
                           text=True, env=os.environ.copy())
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("no repositories", r.stdout)


if __name__ == "__main__":
    unittest.main()
