"""`ws agent` / `ws-agent`: queue, inspect, cancel, retry and close headless agent jobs, and the
one-line orchestration context the SessionStart hook prints."""

from __future__ import annotations

import io
import json
import os
import shutil
import subprocess
import time
import unittest
from contextlib import chdir, redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from agent_helpers import CLAUDE_AUTH_OK, HAVE_SVN, AgentScratch, git, no_sandbox_ws, svn
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
        self.assertIn(["group", "add", "agents", "--parallel", "2"], calls)   # two at a time, one per engine
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

    def finished(self, jid: str, info: dict[str, object], report: dict[str, object] | None = None) -> None:
        res = jobs.job_dir(jid) / "result"
        self.write(res / "exit.json", json.dumps(info))
        if report is not None:
            self.write(res / "report.json", json.dumps(report))
        job = jobs.load(jid)
        job.engine = str(info.get("engine", ""))
        jobs.save(job)

    def test_ls_columns(self) -> None:
        a = self.queued_run(self.repo, "one")
        self.finished(a, {"exit_code": 0, "status": "done", "kind": "ok", "engine": "codex", "checks": "fail"})
        rc, out, _ = self.cli("ls", cwd=self.repo)
        self.assertEqual(rc, 0)
        self.assertRegex(out, rf"^{a}\s+succeeded\s+checks fail\s+codex\s+\d{{4}}-\d\d-\d\dT")
        rc, out, _ = self.cli("ls", "--json", cwd=self.repo)
        row = json.loads(out)[0]
        self.assertEqual((row["engine"], row["checks"]), ("codex", "fail"))

    def test_context_shows_engines_and_needs_you(self) -> None:
        reg.allow(self.repo, "git", [], engines=("claude", "codex"))
        q = self.queued_run(self.repo, "ask me")
        self.finished(q, {"exit_code": 1, "status": "question", "kind": "ok", "engine": "claude"},
                      {"status": "question", "summary": "s", "question": "A or B?", "tests": None, "notes": None})
        w = self.queued_run(self.repo, "wait for it")
        self.finished(w, {"exit_code": 1, "kind": "usage_limit", "engine": "claude",
                          "reset_at": "2100-01-01T15:30:00+00:00"})
        line = agent.context_line(self.repo)
        self.assertIn("jobs: allowed (claude, codex)", line)
        self.assertIn(f"{q} needs you", line)
        self.assertRegex(line, rf"{w} waiting \(claude until \d\d:\d\d\)")

    def test_result_shows_report(self) -> None:
        jid = self.queued_run(self.repo)
        self.finished(jid, {"exit_code": 1, "status": "question", "kind": "ok", "engine": "claude"},
                      {"status": "question", "summary": "Two ways to do it.", "question": "Keep the old API?",
                       "tests": None, "notes": None})
        rc, out, _ = self.cli("result", jid)
        self.assertEqual(rc, 0)
        self.assertIn("needs-you", out)
        self.assertIn("Two ways to do it.", out)
        self.assertIn("Keep the old API?", out)
        self.assertIn(f"ws-agent answer {jid}", out)
        w = self.queued_run(self.repo, "another")
        self.finished(w, {"exit_code": 1, "kind": "usage_limit", "engine": "claude", "reason": "claude: cooling down",
                          "reset_at": "2100-01-01T00:00:00+00:00"})
        rc, out, _ = self.cli("result", w)
        self.assertIn("waiting", out)
        self.assertIn("2100-01-01", out)

    def test_result_shows_checks_and_review(self) -> None:
        jid = self.queued_run(self.repo)
        self.finished(jid, {"exit_code": 0, "status": "done", "kind": "ok", "engine": "claude", "checks": "fail",
                            "fix_rounds": 1, "review": "concerns"},
                      {"status": "done", "summary": "did it", "question": None, "tests": None, "notes": None})
        res = jobs.job_dir(jid) / "result"
        self.write(res / "checks.json", json.dumps([{"cmd": "make test", "exit": 2, "duration_s": 1.0, "timed_out": False}]))
        self.write(res / "checks.txt", "$ make test    (exit 2, 1.0s)\n" + "".join(f"line {i}\n" for i in range(40)) + "\n")
        self.write(res / "review.json", json.dumps({"verdict": "concerns", "summary": "one problem", "findings": [
            {"file": "app.py", "line": 7, "issue": "the cache never expires"}]}))
        rc, out, _ = self.cli("result", jid)
        self.assertEqual(rc, 0)
        self.assertIn("checks: fail (after 1 fix round)", out)
        self.assertIn("make test: exit 2", out)
        self.assertIn("line 39", out)
        self.assertNotIn("line 10\n", out)   # the last 20 lines only
        self.assertIn("review: concerns", out)
        self.assertIn("app.py:7: the cache never expires", out)

    def test_tell_finished_job_requeues_with_the_message(self) -> None:
        jid = self.queued_run(self.repo)
        self.finished(jid, {"exit_code": 0, "status": "done", "kind": "ok", "engine": "claude"})
        rc, out, err = self.cli("tell", jid, "please", "also", "update", "the", "docs")
        self.assertEqual(rc, 0, err)
        self.assertIn(f"requeued {jid}", out)
        adds = [c for c in self.pueue_calls() if c[0] == "add"]
        self.assertEqual(adds[-1][-1], "--resume")
        self.assertEqual([m["text"] for m in jobs.undelivered(jobs.load(jid))], ["please also update the docs"])
        res = jobs.job_dir(jid) / "result"
        self.assertFalse((res / "exit.json").exists())
        self.assertEqual(jobs.state(jobs.load(jid), {jobs.load(jid).pueue_id: "Queued"}), "queued")

    def test_answer_is_tell(self) -> None:
        jid = self.queued_run(self.repo)
        self.finished(jid, {"exit_code": 1, "status": "question", "kind": "ok", "engine": "claude"})
        rc, out, err = self.cli("answer", jid, "use option B")
        self.assertEqual(rc, 0, err)
        self.assertEqual([m["text"] for m in jobs.undelivered(jobs.load(jid))], ["use option B"])

    def test_tell_while_running_only_posts(self) -> None:
        jid = self.queued_run(self.repo)
        self.pueue_status({7: RUNNING})
        before = len([c for c in self.pueue_calls() if c[0] == "add"])
        rc, out, err = self.cli("tell", jid, "carry on")
        self.assertEqual(rc, 0, err)
        self.assertIn("after its current turn", out)
        self.assertEqual(len([c for c in self.pueue_calls() if c[0] == "add"]), before)

    def test_tell_refusals(self) -> None:
        jid = self.queued_run(self.repo)
        self.write(jobs.job_dir(jid) / "result" / "exit.json", '{"exit_code": 0}')
        self.assertEqual(self.cli("close", jid)[0], 0)
        rc, _, err = self.cli("tell", jid, "too late")
        self.assertEqual(rc, 3)
        self.assertIn("closed", err)
        other = self.queued_run(self.repo, "other")
        job = jobs.load(other)
        job.cancelled = True
        jobs.save(job)
        self.assertEqual(self.cli("tell", other, "x")[0], 3)
        live = self.queued_run(self.repo, "live")
        os.environ["WS_AGENT_JOB"] = "abc123"
        rc, _, err = self.cli("tell", live, "x")
        self.assertEqual(rc, 3)
        self.assertIn("queued job", err)
        del os.environ["WS_AGENT_JOB"]
        self.assertEqual(self.cli("tell", live, "   ")[0], 2)

    def test_show_prints_the_thread(self) -> None:
        jid = self.queued_run(self.repo)
        jobs.post(jobs.load(jid), "job", "question: A or B?", attempt=1)
        jobs.post(jobs.load(jid), "you", "B")
        rc, out, _ = self.cli("show", jid)
        self.assertEqual(rc, 0)
        self.assertRegex(out, r"job.*question: A or B\?")
        self.assertRegex(out, r"you.*B")

    def test_retry_a_waiting_job_and_close_a_needs_you_one(self) -> None:
        w = self.queued_run(self.repo, "waits")
        self.finished(w, {"exit_code": 1, "kind": "usage_limit", "engine": "claude", "reset_at": "2100-01-01T00:00:00+00:00"})
        rc, out, err = self.cli("retry", w)
        self.assertEqual(rc, 0, err)
        self.assertIn(f"requeued {w}", out)
        q = self.queued_run(self.repo, "asks")
        self.finished(q, {"exit_code": 1, "status": "question", "kind": "ok", "engine": "claude"})
        rc, _, err = self.cli("close", q)
        self.assertEqual(rc, 0, err)
        self.assertEqual(jobs.state(jobs.load(q), {}), "closed")

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
        self.write(res / "exit.json", '{"exit_code": 0, "status": "done", "kind": "ok", "engine": "claude"}')
        self.write(res / "report.json", json.dumps({"status": "done", "summary": "Added the cache.", "question": None,
                                                    "tests": "make test: ok", "notes": None}))
        self.write(res / "changes.diff", "diff --git a/app.py b/app.py\n--- a/app.py\n+++ b/app.py\n+x\n+y\n-z\n")
        self.write(res / "warnings.txt", "unversioned, not in the patch: extra.txt\n")
        self.write(res / "apply.txt", "Apply in your checkout:\n  git apply --index X\n")
        rc, out, _ = self.cli("result", jid)
        self.assertEqual(rc, 0)
        self.assertIn("succeeded", out)
        self.assertIn("Added the cache.", out)
        self.assertIn("make test: ok", out)
        self.assertIn("app.py: +2 -1", out)
        self.assertIn("extra.txt", out)
        self.assertIn(str(res / "changes.diff"), out)
        self.assertIn("git apply --index", out)

    def test_run_duplicate_of_failed_suggests_retry(self) -> None:
        jid = self.queued_run(self.repo, "flaky task")
        self.write(jobs.job_dir(jid) / "result" / "exit.json", '{"exit_code": 1}')
        rc, out, err = self.cli("run", "--title", "t", "--prompt", "flaky task", "--repo", str(self.repo))
        self.assertEqual(rc, 3)
        self.assertIn(f"ws-agent retry {jid}", err)

    def test_run_waits_for_the_queue_lock(self) -> None:
        os.environ["WS_AGENT_LOCK_TIMEOUT"] = "0.2"
        with jobs.queue_lock():
            rc, _, err = self.cli("run", "--title", "t", "--prompt", "locked out", "--repo", str(self.repo))
        self.assertEqual(rc, 1)
        self.assertIn("another ws-agent run", err)
        self.assertEqual(jobs.all_jobs(), [])

    def test_result_failed_shows_reason_and_log(self) -> None:
        jid = self.queued_run(self.repo)
        jd = jobs.job_dir(jid)
        self.write(jd / "result" / "exit.json", json.dumps({"exit_code": 124, "timed_out": True, "is_error": True}))
        self.write(jd / "exec.log", "--- attempt 1 start\nws-agent: running claude (session S)\n--- attempt 1 finished: exit 124\n")
        rc, out, _ = self.cli("result", jid)
        self.assertEqual(rc, 0)
        self.assertIn("timed out after 2h", out)
        self.assertIn("finished: exit 124", out)

    def test_cancel_stops_the_running_claude(self) -> None:
        jid = self.queued_run(self.repo)
        proc = subprocess.Popen(["sleep", "300"], start_new_session=True)
        self.addCleanup(lambda: (proc.kill(), proc.wait()))
        jobs.record_run(jobs.load(jid), proc.pid)
        self.pueue_status({7: KILLED})   # pueue lost track of it; claude still runs
        self.assertEqual(jobs.state(jobs.load(jid), {7: "Killed"}), "running")
        rc, out, err = self.cli("cancel", jid)
        self.assertEqual(rc, 0, err)
        proc.wait(timeout=15)
        self.assertIsNone(jobs.live_run(jobs.load(jid)))
        self.assertEqual(jobs.state(jobs.load(jid), {}), "cancelled")

    def test_close_refuses_while_claude_runs(self) -> None:
        jid = self.queued_run(self.repo)
        self.write(jobs.job_dir(jid) / "result" / "exit.json", '{"exit_code": 1}')
        proc = subprocess.Popen(["sleep", "300"], start_new_session=True)
        self.addCleanup(lambda: (proc.kill(), proc.wait()))
        jobs.record_run(jobs.load(jid), proc.pid)
        os.remove(jobs.job_dir(jid) / "result" / "exit.json")
        rc, _, err = self.cli("close", jid)
        self.assertEqual(rc, 3)
        self.assertIn("running", err)

    def test_result_diff_prints_the_patch(self) -> None:
        jid = self.queued_run(self.repo)
        res = jobs.job_dir(jid) / "result"
        self.write(res / "exit.json", '{"exit_code": 0}')
        self.write(res / "changes.diff", "diff --git a/app.py b/app.py\n+cached\n")
        self.write(res / "manifest.txt", "app.py\tmodified\n")
        rc, out, _ = self.cli("result", jid, "--diff")
        self.assertEqual(rc, 0)
        self.assertIn("+cached", out)            # the patch itself, so review needs no read outside the project
        self.assertIn("app.py\tmodified", out)
        rc, out, _ = self.cli("result", jid)
        self.assertNotIn("+cached", out)
        self.assertIn(f"ws-agent result {jid} --diff", out)

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

    @unittest.skipUnless(HAVE_SVN, "svn/svnadmin not installed")
    def test_allow_engines_and_checks(self) -> None:
        _, wc = self.svn_repo()
        rc, out, err = self.cli("allow", str(wc), "--engine", "claude", "--engine", "codex", "--check", "make test",
                                "--fix-rounds", "0", "--review", "claude", "--network")
        self.assertEqual(rc, 0, err)
        self.assertIn("OpenAI", out + err)
        self.assertIn("authoriz", out + err)
        found = reg.find(wc)
        assert found is not None
        self.assertEqual((found.engines, found.checks, found.fix_rounds, found.review, found.network),
                         (("claude", "codex"), ("make test",), 0, "claude", True))
        rc, out, _ = self.cli("repos")
        self.assertIn("engines: claude, codex", out)
        self.assertIn("checks: make test", out)
        self.assertIn("network: on", out)

    def test_allow_bad_review_is_a_usage_error(self) -> None:
        repo = self.git_repo()
        rc, _, err = self.cli("allow", str(repo), "--review", "codex")
        self.assertEqual(rc, 2)
        self.assertIn("isn't one of this repository's engines", err)
        self.assertIsNone(reg.find(repo))

    def test_allow_unparseable_registry(self) -> None:
        repo = self.git_repo()
        self.write(reg.registry_path(), "[[bad\n")
        rc, _, err = self.cli("allow", str(repo))
        self.assertEqual(rc, 1)
        self.assertIn("agents.toml", err)
        self.assertEqual(reg.registry_path().read_text(), "[[bad\n")


class Context(Cli):
    def test_context_line_formats(self) -> None:
        repo = self.git_repo()
        self.pueue_status({})
        line = agent.context_line(repo)
        self.assertRegex(line, r"^\[orchestration\] git ~/src/proj main@[0-9a-f]{12} \| jobs: not allowed \(ws-agent allow\)"
                               r" \| here: none$")
        reg.allow(repo, "git", [])
        jid = self.queued_run(repo)
        self.pueue_status({7: QUEUED})
        line = agent.context_line(repo)
        self.assertRegex(line, r"^\[orchestration\] git ~/src/proj main@[0-9a-f]{12} \| jobs: allowed \(claude\); queue 0/1 running,"
                               rf" 1 queued \| here: {jid} queued$")
        d = self.root / "plain"
        d.mkdir()
        self.assertEqual(agent.context_line(d), "[orchestration] no repository here")
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
                         r"^\[orchestration\] svn ~/src/svnwc \^/trunk@1 \| jobs: allowed \(claude\); queue 0/1 running, 0 queued"
                         r" \| here: none$")

    def test_route_json(self) -> None:
        repo = self.git_repo()
        reg.allow(repo, "git", ["make *"])
        self.pueue_status({})
        rc, out, _ = self.cli("route", "--json", cwd=repo)
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertEqual(set(data), {"vcs", "root", "base", "github", "allowed", "commands", "queue", "jobs"})
        self.assertEqual(data["vcs"], "git")
        self.assertTrue(data["allowed"])
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

    def test_doctor_rows(self) -> None:
        self.fake("claude", 'echo \'{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "pro"}\'')
        self.fake("codex", 'echo "Not logged in" >&2; exit 1')
        repo = self.git_repo()
        reg.allow(repo, "git", [], engines=("claude", "codex"))
        self.pueue_status({})
        with mock.patch.object(agent.agent_sandbox, "probe", return_value=None):
            rc, out, _ = self.cli("doctor")
        self.assertRegex(out, r"ok\s+engine claude: ")
        self.assertRegex(out, r"!!\s+engine codex: not logged in")
        self.assertRegex(out, r"ok\s+sandbox: ")
        with mock.patch.object(agent.agent_sandbox, "probe", return_value="no bwrap"):
            rc, out, _ = self.cli("doctor")
        self.assertEqual(rc, 1)
        self.assertRegex(out, r"!!\s+sandbox: no bwrap")
        outside = self.root / "data" / "svn" / "projB"
        outside.mkdir(parents=True)
        reg.allow(outside, "svn", [])
        with mock.patch.object(agent.agent_sandbox, "probe", return_value=None):
            rc, out, _ = self.cli("doctor")
        self.assertRegex(out, rf"sandbox hides .*{self.root / 'data' / 'svn'}")
        self.assertIn("[sandbox] hide", out)
        engines_mod = agent.engines
        engines_mod.cool("claude", "2100-01-01T00:00:00+00:00")
        with mock.patch.object(agent.agent_sandbox, "probe", return_value=None):
            rc, out, _ = self.cli("doctor")
        self.assertRegex(out, r"engine claude: .*cooling down until 2100-01-01")


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


HOOK = REPO / "dotfiles" / "claude" / "skills" / "workstation-orchestration" / "hooks" / "context.sh"
EVENTS_HOOK = HOOK.with_name("events.sh")


class HookScript(AgentScratch):
    """The SessionStart hook: one line from ws-agent context, nothing on any failure, exit 0."""

    def hook(self, stdin: str = "{}", **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(HOOK)], input=stdin, capture_output=True, text=True, timeout=20,
                              env={**os.environ, **env})

    def test_context_hook_prints_line(self) -> None:
        self.fake("ws-agent", 'echo "[orchestration] x $PWD"; echo "second line"')
        d = self.root / "proj dir"
        d.mkdir()
        r = self.hook(json.dumps({"session_id": "s", "cwd": str(d), "hook_event_name": "SessionStart"}))
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, f"[orchestration] x {d}\n")   # first line only, run in the session's directory

    def test_context_hook_fail_open(self) -> None:
        self.fake("ws-agent", "echo partial; exit 1")
        r = self.hook()
        self.assertEqual((r.returncode, r.stdout), (0, ""))
        self.fake("ws-agent", "sleep 10; echo late")
        r = self.hook(WS_AGENT_HOOK_TIMEOUT="1")
        self.assertEqual((r.returncode, r.stdout), (0, ""))
        (self.bin / "ws-agent").unlink()
        r = self.hook(PATH=f"{self.bin}{os.pathsep}/usr/bin{os.pathsep}/bin")
        self.assertEqual((r.returncode, r.stdout), (0, ""))

    def test_context_hook_missing_cwd(self) -> None:
        self.fake("ws-agent", 'echo "[orchestration] here"')
        r = self.hook(json.dumps({"cwd": str(self.root / "gone")}))
        self.assertEqual((r.returncode, r.stdout), (0, "[orchestration] here\n"))

    def events_hook(self, stdin: str = "{}", **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(EVENTS_HOOK)], input=stdin, capture_output=True, text=True, timeout=20,
                              env={**os.environ, **env})

    def test_events_hook_passes_the_prompt_json_and_prints_lines(self) -> None:
        self.fake("ws-agent", f'cat >"{self.root}/events.stdin"; echo "$1 $PWD"; echo "[orchestration] b1 failed"')
        d = self.root / "proj dir"
        d.mkdir()
        payload = json.dumps({"session_id": "S", "cwd": str(d), "hook_event_name": "UserPromptSubmit", "prompt": "hi"})
        r = self.events_hook(payload)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, f"events {d}\n[orchestration] b1 failed\n")
        self.assertEqual(json.loads((self.root / "events.stdin").read_text())["session_id"], "S")

    def test_events_hook_fails_open(self) -> None:
        self.fake("ws-agent", "echo partial; exit 1")
        self.assertEqual((self.events_hook().returncode, self.events_hook().stdout), (0, ""))
        self.fake("ws-agent", "sleep 10; echo late")
        r = self.events_hook(WS_AGENT_HOOK_TIMEOUT="1")
        self.assertEqual((r.returncode, r.stdout), (0, ""))
        (self.bin / "ws-agent").unlink()
        r = self.events_hook(PATH=f"{self.bin}{os.pathsep}/usr/bin{os.pathsep}/bin")
        self.assertEqual((r.returncode, r.stdout), (0, ""))


class EventsCommand(Cli):
    def test_events_never_calls_pueue(self) -> None:
        from wslib import agent_events
        repo = self.git_repo()
        reg.allow(repo, "git", [])
        self.pueue_status({})
        jid = self.queued_run(repo)
        before = len(self.pueue_calls())
        payload = json.dumps({"session_id": "sess-1", "cwd": str(repo)})
        with mock.patch("sys.stdin", io.StringIO(payload)):
            self.assertEqual(self.cli("events", cwd=repo), (0, "", ""))   # first prompt: marker only
        agent_events.append("succeeded", jobs.load(jid), f"{jid} succeeded (t)")
        (self.bin / "pueue").unlink()
        with mock.patch("sys.stdin", io.StringIO(payload)):
            rc, out, _ = self.cli("events", cwd=repo)
        self.assertEqual(rc, 0)
        self.assertEqual(out, f"[orchestration] {jid} succeeded (t): ws-agent result {jid}\n")
        self.assertEqual(len(self.pueue_calls()), before)
        with mock.patch("sys.stdin", io.StringIO("not json")):
            self.assertEqual(self.cli("events", cwd=repo)[:2], (0, ""))


@unittest.skipUnless(shutil.which("pueued") and shutil.which("pueue"), "pueue not installed")
class RealQueueCancel(Cli):
    """ws-agent run → a real (scratch) pueued → _exec → a fake claude; cancel must stop claude itself."""

    def setUp(self) -> None:
        super().setUp()
        (self.bin / "pueue").unlink()
        cfg = self.root / "pueue.yml"
        (self.root / "pr").mkdir()
        self.write(cfg, f"shared:\n  pueue_directory: {self.root / 'pd'}\n  runtime_directory: {self.root / 'pr'}\n"
                        f"  unix_socket_path: {self.root / 'p.sock'}\n")
        os.environ["WS_AGENT_PUEUE_CONFIG"] = str(cfg)
        self.daemon = subprocess.Popen(["pueued", "-c", str(cfg)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(50):
            if (self.root / "p.sock").exists():
                break
            time.sleep(0.1)
        self.fake("claude", CLAUDE_AUTH_OK + 'echo $$ >"$HOME/claude.pid"; sleep 300')
        # pueue runs _exec in its own process, where the job sandbox would hide this scratch home
        # (and the fake) under /tmp: it runs through a ws.py stand-in with the sandbox switched off.
        p = mock.patch.object(core, "WS_PY", no_sandbox_ws(self.root))
        p.start()
        self.addCleanup(p.stop)

    def tearDown(self) -> None:
        subprocess.run(["pueue", "-c", os.environ["WS_AGENT_PUEUE_CONFIG"], "shutdown"], capture_output=True)
        try:
            self.daemon.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.daemon.kill()
        super().tearDown()

    def test_cancel_stops_claude_and_frees_the_slot(self) -> None:
        repo = self.git_repo()
        reg.allow(repo, "git", [])
        jid = self.queued_run(repo, "sleepy")
        job = jobs.load(jid)
        for _ in range(150):   # run.pid lands as timeout starts; the fake writes claude.pid a moment later
            if jobs.live_run(job) is not None and (self.home / "claude.pid").exists():
                break
            time.sleep(0.1)
        self.assertIsNotNone(jobs.live_run(job), (jobs.job_dir(jid) / "exec.log").read_text() if (jobs.job_dir(jid) / "exec.log").exists() else "")
        claude_pid = int((self.home / "claude.pid").read_text())
        rc, _, err = self.cli("cancel", jid)
        self.assertEqual(rc, 0, err)
        for _ in range(100):
            if not Path(f"/proc/{claude_pid}").exists():
                break
            time.sleep(0.1)
        self.assertFalse(Path(f"/proc/{claude_pid}").exists())   # claude itself is gone, not only _exec
        q = jobs.pueue_status()
        assert q is not None
        self.assertEqual(q.running, 0)


if __name__ == "__main__":
    unittest.main()
