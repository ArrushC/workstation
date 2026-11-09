"""wslib.agent_exec: what pueue runs for a job — a private working copy, write-refusing shims, a
headless claude with a clean environment, and the review artifacts collected afterwards."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from agent_helpers import CLAUDE_AUTH_OK, FAKE_CODEX, HAVE_SVN, AgentScratch, git, no_sandbox_ws, svn
from helpers import WS

from wslib import agent_exec as ax
from wslib import agent_registry as reg
from wslib import agent_sandbox, engines, jobs

DONE = '{"status":"done","summary":"done: changed things","question":null,"tests":null,"notes":null}'
# claude 2.1.319's --output-format json: one line, an array of every message ending in the result,
# with the report in structured_output. $d/fail.<n> makes call n an error result with that text;
# $d/report (or report.<n>) replaces the report.
FAKE_CLAUDE = CLAUDE_AUTH_OK + r"""
d="$WS_FAKE_CLAUDE"
echo x >>"$d/calls"
n=$(wc -l <"$d/calls" | tr -d ' ')
printf '%s\n' "$@" >"$d/argv"; cp "$d/argv" "$d/argv.$n"
env >"$d/env"
cat >"$d/stdin"; cp "$d/stdin" "$d/stdin.$n"
pwd >"$d/cwd"
sid="" prev=""
for a in "$@"; do case "$prev" in --session-id | --resume) sid="$a" ;; esac; prev="$a"; done
mkdir -p "$HOME/.claude/projects/fake" && : >"$HOME/.claude/projects/fake/$sid.jsonl"
[ -f "$d/script.sh" ] && bash "$d/script.sh"
[ -f "$d/sleep" ] && sleep "$(cat "$d/sleep")"
err=$(cat "$d/is_error" 2>/dev/null || echo false) text="done: changed things"
[ -f "$d/fail.$n" ] && { err=true; text=$(cat "$d/fail.$n"); }
so=$(cat "$d/report.$n" 2>/dev/null || cat "$d/report" 2>/dev/null || echo '""" + DONE + r"""')
[ "$err" = true ] && so=null
text=$(printf '%s' "$text" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))')
printf '[{"type":"system","subtype":"init","session_id":"%s","cwd":"%s"},{"type":"assistant","message":{"content":[]}},{"type":"result","subtype":"success","is_error":%s,"duration_ms":10,"num_turns":3,"result":%s,"session_id":"%s","total_cost_usd":0,"structured_output":%s,"terminal_reason":"completed"}]\n' \
  "$sid" "$PWD" "$err" "$text" "$sid" "$so"
exit "$(cat "$d/exit" 2>/dev/null || echo 0)"
"""


class Exec(AgentScratch):
    """The executor with fakes for both engines; ws-agent's job sandbox is switched off here (it
    would hide the fakes under /tmp) and tested on its own, with real bwrap, in test_agent_sandbox."""

    def setUp(self) -> None:
        super().setUp()
        self.fc = self.root / "fake-claude"
        self.fc.mkdir()
        os.environ["WS_FAKE_CLAUDE"] = str(self.fc)
        self.fake("claude", FAKE_CLAUDE)
        self.fx = self.root / "fake-codex"
        self.fx.mkdir()
        os.environ["WS_FAKE_CODEX"] = str(self.fx)
        self.fake("codex", FAKE_CODEX)
        self._patches = [mock.patch.object(agent_sandbox, "wrap", side_effect=lambda argv, **kw: list(argv)),
                         mock.patch.object(agent_sandbox, "probe", return_value=None),
                         mock.patch.object(ax, "BACKOFF", (0, 0, 0))]
        for p in self._patches:
            p.start()
            self.addCleanup(p.stop)

    def make_job(self, repo: Path, vcs: str, base: dict[str, str], *, timeout: str = "2h",
                 commands: list[str] | None = None, prompt: str = "do the thing", **allow: object) -> jobs.Job:
        reg.allow(repo, vcs, commands or [], **allow)  # type: ignore[arg-type]
        job = jobs.Job(id=jobs.new_id(), title="the thing", repo=f"~/{repo.relative_to(self.home).as_posix()}", vcs=vcs,
                       base=base, prompt_sha="s", paths=[], created="2026-11-06T00:00:00+00:00", session_id="",
                       timeout=timeout)
        jobs.save(job)
        self.write(jobs.job_dir(job.id) / "prompt.md", prompt)
        return job

    def claude_script(self, body: str) -> None:
        self.write(self.fc / "script.sh", body)

    def result(self, job: jobs.Job, name: str) -> str:
        return (jobs.job_dir(job.id) / "result" / name).read_text(encoding="utf-8")

    def exit_json(self, job: jobs.Job) -> dict[str, object]:
        return json.loads(self.result(job, "exit.json"))

    def claude_calls(self) -> int:
        p = self.fc / "calls"
        return len(p.read_text().splitlines()) if p.exists() else 0


class Refusals(unittest.TestCase):
    def test_svn_refusals(self) -> None:
        refused = [["commit", "-m", "x"], ["-q", "ci", "-m", "x"], ["copy", "^/trunk", "^/branches/x", "-m", "b"],
                   ["delete", "https://svn.example/r/trunk/f.c", "-m", "x"], ["propset", "--revprop", "-r", "5", "svn:log", "x"],
                   ["update"], ["up", "-r", "3"], ["switch", "^/branches/b"], ["merge", "^/branches/b"], ["lock", "f.c"],
                   ["import", ".", "file:///r", "-m", "x"], ["mkdir", "file:///r/new", "-m", "x"], ["checkout", "file:///r"],
                   ["relocate", "file:///r2"], ["--username", "u", "commit"], ["-m", "msg", "commit"], ["auth"],
                   ["x-shelve", "s"], ["propedit", "svn:ignore", "."]]
        allowed = [["delete", "f.c"], ["propset", "svn:eol-style", "native", "f.c"], ["diff"], ["status", "-u"],
                   ["info", "--show-item", "url"], ["add", "new.c"], ["move", "a.c", "b.c"], ["copy", "a.c", "c.c"],
                   ["revert", "-R", "."], ["log", "-l", "3"], ["--version"], [], ["patch", "x.diff"],
                   ["--config-dir", "/x", "status"], ["mkdir", "newdir"]]
        for args in refused:
            self.assertIsNotNone(ax.svn_refusal(args), args)
        for args in allowed:
            self.assertIsNone(ax.svn_refusal(args), args)
        self.assertIn("commit", ax.svn_refusal(["-q", "ci"]) or "")

    def test_git_refusals(self) -> None:
        for args in (["push"], ["-c", "x=y", "push", "origin"], ["-C", "/r", "push"], ["svn", "dcommit"],
                     ["credential", "fill"], ["credential-store", "get"], ["send-email", "x.patch"]):
            self.assertIsNotNone(ax.git_refusal(args), args)
        for args in (["status"], ["-C", "/r", "diff"], ["log", "--oneline"], [], ["--version"]):
            self.assertIsNone(ax.git_refusal(args), args)
        for args in (["add", "x.py"], ["restore", "--staged", "x.py"], ["rm", "x"], ["mv", "a", "b"], ["apply", "p"],
                     ["commit", "-m", "x"], ["merge", "b"], ["rebase", "main"], ["cherry-pick", "c"], ["tag", "v1"],
                     ["update-ref", "refs/heads/x", "HEAD"], ["stash"], ["config", "user.name", "x"], ["remote", "add", "o", "u"],
                     ["worktree", "add", "x"], ["branch", "-D", "x"], ["checkout", "-b", "x"], ["switch", "-c", "x"],
                     ["fetch"], ["pull"], ["gc"], ["reset", "--hard"], ["reflog", "expire"]):
            self.assertIsNotNone(ax.git_refusal(args), args)

    def test_shims_confine_writes_to_the_job_copy(self) -> None:
        wc, out = Path("/jobs/j1/wc"), Path("/home/me/src/foo")
        self.assertIsNone(ax.svn_refusal(["revert", "-R", "."], wc=wc, cwd=wc))
        self.assertIsNone(ax.svn_refusal(["propset", "svn:eol-style", "native", "sub/f.c"], wc=wc, cwd=wc / "sub"))
        self.assertIsNotNone(ax.svn_refusal(["revert", "-R", str(out)], wc=wc, cwd=wc))
        self.assertIsNotNone(ax.svn_refusal(["delete", "/home/me/src/foo/x.c"], wc=wc, cwd=wc))
        self.assertIsNotNone(ax.svn_refusal(["revert", "-R", "."], wc=wc, cwd=out))
        self.assertIsNotNone(ax.svn_refusal(["add", "../escape"], wc=wc, cwd=wc))
        self.assertIsNone(ax.svn_refusal(["status", str(out)], wc=wc, cwd=wc))   # reading elsewhere is fine
        # git in a job is read-only: the agent edits files and ws-agent stages them when it finishes
        self.assertIsNotNone(ax.git_refusal(["-C", str(out), "add", "x"], wc=wc, cwd=wc))
        self.assertIsNotNone(ax.git_refusal(["add", "x"], wc=wc, cwd=wc))
        self.assertIsNotNone(ax.git_refusal(["restore", "."], wc=wc, cwd=wc))
        self.assertIsNone(ax.git_refusal(["-C", str(out), "status"], wc=wc, cwd=wc))
        self.assertIsNone(ax.git_refusal(["diff", "--stat"], wc=wc, cwd=wc))


class Env(unittest.TestCase):
    def test_clean_env(self) -> None:
        base = {"PATH": "/usr/bin", "HOME": "/h", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "x",
                "CLAUDE_CODE_MESSAGING_TOKEN": "y", "CLAUDE_CODE_MESSAGING_SOCKET": "z", "CLAUDE_CODE_ENTRYPOINT": "cli",
                "CLAUDE_CODE_BRIDGE_SESSION_ID": "b", "CLAUDE_CODE_EXECPATH": "/e", "CLAUDE_CODE_CHILD_SESSION": "1",
                "CLAUDE_CODE_SESSION_ATTENDED": "1", "CLAUDE_CODE_OAUTH_TOKEN": "keep", "CLAUDE_CODE_USE_VERTEX": "1",
                "ANTHROPIC_API_KEY": "keep2", "SSH_AUTH_SOCK": "/s", "GH_TOKEN": "g", "GITHUB_TOKEN": "g2",
                "GITLAB_TOKEN": "g3", "MISE_GITHUB_TOKEN": "g4", "GITHUB_API_TOKEN": "g5", "NPM_TOKEN": "n",
                "ANTHROPIC_AUTH_TOKEN": "keep3", "WS_AGENT_JOB": "old"}
        env = ax.clean_env(base, Path("/job/bin"), "abc123")
        for gone in ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_MESSAGING_SOCKET",
                     "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_EXECPATH",
                     "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED", "SSH_AUTH_SOCK", "GH_TOKEN",
                     "GITHUB_TOKEN", "GITLAB_TOKEN", "MISE_GITHUB_TOKEN", "GITHUB_API_TOKEN", "NPM_TOKEN"):
            self.assertNotIn(gone, env, gone)
        self.assertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "keep")
        self.assertEqual(env["CLAUDE_CODE_USE_VERTEX"], "1")
        self.assertEqual(env["ANTHROPIC_API_KEY"], "keep2")
        self.assertEqual(env["ANTHROPIC_AUTH_TOKEN"], "keep3")
        self.assertEqual(env["PATH"], "/job/bin" + os.pathsep + "/usr/bin")
        self.assertEqual(env["WS_AGENT_JOB"], "abc123")
        self.assertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        self.assertEqual(env["GIT_CONFIG_KEY_0"], "credential.helper")
        self.assertEqual(env["GIT_CONFIG_VALUE_0"], "")
        self.assertTrue(env["GIT_ASKPASS"].endswith("false"))
        self.assertEqual(env["SVN_EDITOR"], "false")
        self.assertIn("BatchMode=yes", env["SVN_SSH"])
        self.assertIn("IdentityFile=/dev/null", env["SVN_SSH"])
        self.assertEqual(env["GIT_OPTIONAL_LOCKS"], "0")   # git status never writes the read-only gitdir


class ExecGit(Exec):
    def test_execute_git(self) -> None:
        repo = self.git_repo()
        head = git("rev-parse", "HEAD", cwd=repo)
        job = self.make_job(repo, "git", {"commit": head, "branch": "main"}, commands=["make *"])
        self.claude_script('printf "def g():\\n    return 2\\n" >>app.py\nprintf "new\\n" >new.txt\n'
                           'printf "\\0\\1bin" >blob.bin\n')
        self.assertEqual(ax.execute(job.id, resume=False), 0)
        info = self.exit_json(job)
        self.assertEqual(info["exit_code"], 0)
        self.assertEqual(info["session_id"], jobs.load(job.id).session_id)
        self.assertEqual(info["num_turns"], 3)   # read from the result message, not a fallback
        diff = self.result(job, "changes.diff")
        self.assertIn("+    return 2", diff)
        self.assertIn("new.txt", diff)
        self.assertIn("GIT binary patch", diff)
        self.assertIn("A\tnew.txt", self.result(job, "manifest.txt"))
        argv = (self.fc / "argv").read_text().splitlines()
        self.assertIn("--permission-prompts", argv)
        self.assertEqual(argv[argv.index("--permission-prompts") + 1], "none")
        self.assertEqual(argv[argv.index("--permission-mode") + 1], "acceptEdits")
        self.assertIn("--session-id", argv)
        self.assertIn("Bash(make *)", argv)
        self.assertNotIn("bypassPermissions", argv)
        env = (self.fc / "env").read_text()
        self.assertNotIn("CLAUDECODE=", env)
        self.assertIn("WS_AGENT_JOB=" + job.id, env)
        self.assertEqual((self.fc / "stdin").read_text(), "do the thing")
        wc = jobs.job_dir(job.id) / "wc"
        self.assertEqual(Path((self.fc / "cwd").read_text().strip()), wc)
        self.assertEqual(git("rev-parse", "--abbrev-ref", "HEAD", cwd=wc), f"ws-agent/{job.id}")
        self.assertEqual(git("rev-parse", "HEAD", cwd=repo), head)   # the user's checkout is untouched
        self.assertEqual(jobs.load(job.id).attempts, 1)

    def test_resume_uses_same_session_and_inspects(self) -> None:
        repo = self.git_repo()
        job = self.make_job(repo, "git", {"commit": git("rev-parse", "HEAD", cwd=repo), "branch": "main"})
        self.claude_script('printf "partial\\n" >>app.py\n')
        ax.execute(job.id, resume=False)
        sid = jobs.load(job.id).session_id
        self.assertTrue(sid)
        ax.execute(job.id, resume=True)
        argv = (self.fc / "argv").read_text().splitlines()
        self.assertEqual(argv[argv.index("--resume") + 1], sid)
        self.assertNotIn("--session-id", argv)
        self.assertEqual(jobs.load(job.id).attempts, 2)
        inspect = self.result(job, "inspect-2.txt")
        self.assertIn("app.py", inspect)
        prompt = (self.fc / "stdin").read_text()
        self.assertIn("interrupted", prompt)
        self.assertIn("app.py", prompt)
        self.assertEqual(self.claude_calls(), 2)
        wc = jobs.job_dir(job.id) / "wc"   # not re-prepared: both attempts appended to the same copy
        self.assertEqual((wc / "app.py").read_text().count("partial"), 2)
        self.assertEqual(len(git("worktree", "list", cwd=repo).splitlines()), 2)

    def test_resume_without_transcript_starts_fresh(self) -> None:
        repo = self.git_repo()
        job = self.make_job(repo, "git", {"commit": git("rev-parse", "HEAD", cwd=repo), "branch": "main"})
        job.session_id = "0f0f0f0f-0000-4000-8000-000000000000"   # never persisted
        jobs.save(job)
        ax.execute(job.id, resume=True)
        argv = (self.fc / "argv").read_text().splitlines()
        self.assertIn("--session-id", argv)
        self.assertNotEqual(argv[argv.index("--session-id") + 1], "0f0f0f0f-0000-4000-8000-000000000000")
        self.assertIn("do the thing", (self.fc / "stdin").read_text())

    def test_not_allowed_anymore(self) -> None:
        repo = self.git_repo()
        job = self.make_job(repo, "git", {"commit": git("rev-parse", "HEAD", cwd=repo), "branch": "main"})
        reg.disallow(repo)
        self.assertEqual(ax.execute(job.id, resume=False), 1)
        self.assertEqual(self.exit_json(job)["exit_code"], 1)
        self.assertIn("isn't allowed", (jobs.job_dir(job.id) / "exec.log").read_text())
        self.assertEqual(self.claude_calls(), 0)

    def test_claude_error_is_failure(self) -> None:
        repo = self.git_repo()
        job = self.make_job(repo, "git", {"commit": git("rev-parse", "HEAD", cwd=repo), "branch": "main"})
        self.write(self.fc / "is_error", "true")
        self.assertEqual(ax.execute(job.id, resume=False), 1)
        self.assertEqual(jobs.state(jobs.load(job.id), {}), "failed")

    def test_timeout_recorded(self) -> None:
        repo = self.git_repo()
        job = self.make_job(repo, "git", {"commit": git("rev-parse", "HEAD", cwd=repo), "branch": "main"}, timeout="1s")
        self.write(self.fc / "sleep", "5")
        self.assertEqual(ax.execute(job.id, resume=False), 1)
        info = self.exit_json(job)
        self.assertTrue(info["timed_out"])
        self.assertEqual(info["exit_code"], 124)

    def test_stale_exit_json_removed(self) -> None:
        repo = self.git_repo()
        job = self.make_job(repo, "git", {"commit": git("rev-parse", "HEAD", cwd=repo), "branch": "main"})
        self.write(jobs.job_dir(job.id) / "result" / "exit.json", '{"exit_code": 1}')
        self.claude_script('test -e ../result/exit.json && echo STALE >"$WS_FAKE_CLAUDE/stale"\n')
        ax.execute(job.id, resume=False)
        self.assertFalse((self.fc / "stale").exists())
        self.assertEqual(self.exit_json(job)["exit_code"], 0)

    def test_cancelled_or_closed_job_never_runs(self) -> None:
        repo = self.git_repo()
        for flag in ("cancelled", "closed"):
            job = self.make_job(repo, "git", {"commit": git("rev-parse", "HEAD", cwd=repo), "branch": "main"},
                                prompt=f"p {flag}")
            setattr(job, flag, True)
            jobs.save(job)
            self.assertEqual(ax.execute(job.id, resume=False), 1)
            self.assertFalse((jobs.job_dir(job.id) / "result" / "exit.json").exists())
            self.assertFalse((jobs.job_dir(job.id) / "wc").exists())
        self.assertEqual(self.claude_calls(), 0)

    def test_live_attempt_blocks_another(self) -> None:
        repo = self.git_repo()
        job = self.make_job(repo, "git", {"commit": git("rev-parse", "HEAD", cwd=repo), "branch": "main"})
        proc = subprocess.Popen(["sleep", "300"], start_new_session=True)
        self.addCleanup(lambda: (proc.kill(), proc.wait()))
        jobs.record_run(job, proc.pid)
        self.assertEqual(ax.execute(job.id, resume=True), 1)
        self.assertEqual(self.claude_calls(), 0)
        self.assertFalse((jobs.job_dir(job.id) / "result" / "exit.json").exists())
        self.assertIn("still running", (jobs.job_dir(job.id) / "exec.log").read_text())

    def test_run_pid_recorded_during_the_run(self) -> None:
        repo = self.git_repo()
        job = self.make_job(repo, "git", {"commit": git("rev-parse", "HEAD", cwd=repo), "branch": "main"})
        self.claude_script('cp ../run.pid "$WS_FAKE_CLAUDE/run.pid.seen"; ps -o pgid= -p $$ | tr -d " " >"$WS_FAKE_CLAUDE/pgid"\n')
        ax.execute(job.id, resume=False)
        seen = json.loads((self.fc / "run.pid.seen").read_text())
        self.assertEqual(str(seen["pgid"]), (self.fc / "pgid").read_text().strip())   # claude runs in the recorded group
        self.assertFalse((jobs.job_dir(job.id) / "run.pid").exists())

    def test_claude_dies_with_its_executor(self) -> None:
        repo = self.git_repo()
        job = self.make_job(repo, "git", {"commit": git("rev-parse", "HEAD", cwd=repo), "branch": "main"})
        self.write(self.fc / "sleep", "300")
        ex = subprocess.Popen([sys.executable, str(no_sandbox_ws(self.root)), "agent", "_exec", job.id],
                              env=os.environ.copy())
        self.addCleanup(lambda: (ex.kill(), ex.wait()))
        for _ in range(100):
            if jobs.live_run(job) is not None:
                break
            time.sleep(0.1)
        self.assertIsNotNone(jobs.live_run(job))
        ex.kill()   # what `pueue kill` does to _exec
        ex.wait()
        for _ in range(100):
            if jobs.live_run(job) is None:
                break
            time.sleep(0.1)
        self.assertIsNone(jobs.live_run(job))   # timeout and claude went with it

    def test_partial_worktree_is_rebuilt(self) -> None:
        repo = self.git_repo()
        job = self.make_job(repo, "git", {"commit": git("rev-parse", "HEAD", cwd=repo), "branch": "main"})
        git("branch", f"ws-agent/{job.id}", cwd=repo)   # a branch left by an attempt cut short
        self.write(jobs.job_dir(job.id) / "wc" / "half.txt", "an interrupted checkout\n")
        self.assertEqual(ax.execute(job.id, resume=False), 0)
        wc = jobs.job_dir(job.id) / "wc"
        self.assertFalse((wc / "half.txt").exists())
        self.assertTrue((wc / "app.py").exists())
        self.assertNotIn("half.txt", self.result(job, "changes.diff"))

    def test_no_changes_warned(self) -> None:
        repo = self.git_repo()
        job = self.make_job(repo, "git", {"commit": git("rev-parse", "HEAD", cwd=repo), "branch": "main"})
        ax.execute(job.id, resume=False)
        self.assertIn("no changes", self.result(job, "warnings.txt"))


USAGE_2100 = "Claude AI usage limit reached|4102444800"   # resets 2100-01-01T00:00:00Z


class Attempts(Exec):
    def git_job(self, **allow: object) -> jobs.Job:
        repo = self.git_repo()
        return self.make_job(repo, "git", {"commit": git("rev-parse", "HEAD", cwd=repo), "branch": "main"}, **allow)

    def calls(self, d: Path) -> int:
        p = d / "calls"
        return len(p.read_text().splitlines()) if p.exists() else 0

    def test_structured_report_recorded(self) -> None:
        job = self.git_job()
        self.write(self.fc / "report", '{"status":"done","summary":"s","question":null,"tests":"make ok","notes":null}')
        self.assertEqual(ax.execute(job.id, resume=False), 0)
        report = json.loads(self.result(job, "report.json"))
        self.assertEqual((report["status"], report["summary"], report["tests"]), ("done", "s", "make ok"))
        info = self.exit_json(job)
        self.assertEqual((info["status"], info["kind"], info["engine"], info["exit_code"]), ("done", "ok", "claude", 0))
        self.assertEqual(jobs.state(jobs.load(job.id), {}), "succeeded")
        self.assertEqual(jobs.load(job.id).engine, "claude")
        self.assertEqual(jobs.load(job.id).history[-1]["kind"], "ok")

    def test_question_is_needs_you(self) -> None:
        job = self.git_job()
        self.write(self.fc / "report", '{"status":"question","summary":"s","question":"A or B?","tests":null,"notes":null}')
        self.assertEqual(ax.execute(job.id, resume=False), 1)
        info = self.exit_json(job)
        self.assertNotEqual(info["exit_code"], 0)
        self.assertEqual(info["status"], "question")
        self.assertEqual(jobs.state(jobs.load(job.id), {}), "needs-you")

    def test_transient_retry_resumes_same_session(self) -> None:
        job = self.git_job()
        self.write(self.fc / "fail.1", "API Error: 529 Overloaded")
        self.write(self.fc / "fail.2", "API Error: Connection error.")
        self.assertEqual(ax.execute(job.id, resume=False), 0)
        self.assertEqual(self.claude_calls(), 3)
        first = (self.fc / "argv.1").read_text().splitlines()
        sid = first[first.index("--session-id") + 1]
        for n in (2, 3):
            argv = (self.fc / f"argv.{n}").read_text().splitlines()
            self.assertEqual(argv[argv.index("--resume") + 1], sid, n)
        self.assertIn("temporary", (self.fc / "stdin.2").read_text())
        self.assertEqual(jobs.state(jobs.load(job.id), {}), "succeeded")
        self.assertEqual([h["kind"] for h in jobs.load(job.id).history], ["transient", "transient", "ok"])

    def test_transient_gives_up_after_three_retries(self) -> None:
        job = self.git_job()
        for n in range(1, 6):
            self.write(self.fc / f"fail.{n}", "API Error: 529 Overloaded")
        self.assertEqual(ax.execute(job.id, resume=False), 1)
        self.assertEqual(self.claude_calls(), 4)
        self.assertEqual(self.exit_json(job)["kind"], "transient")
        self.assertEqual(jobs.state(jobs.load(job.id), {}), "failed")

    def test_usage_limit_falls_back_to_the_next_engine(self) -> None:
        job = self.git_job(engines=("claude", "codex"))
        self.write(self.fc / "fail.1", USAGE_2100)
        self.assertEqual(ax.execute(job.id, resume=False), 0)
        info = self.exit_json(job)
        self.assertEqual(info["engine"], "codex")
        self.assertIn("started by another agent (claude)", (self.fx / "stdin").read_text())
        self.assertIn("do the thing", (self.fx / "stdin").read_text())   # the hand-off carries the task
        self.assertTrue(engines.cooling("claude").startswith("2100-01-01"))
        self.assertEqual(jobs.load(job.id).engine, "codex")
        self.assertEqual(jobs.load(job.id).session_id, "T-1")
        self.assertEqual(json.loads(self.result(job, "report.json"))["summary"], "codex did it")

    def test_claude_only_repo_never_falls_back(self) -> None:
        job = self.git_job()   # engines: claude only
        self.write(self.fc / "fail.1", USAGE_2100)
        self.assertEqual(ax.execute(job.id, resume=False), 1)
        self.assertEqual(self.calls(self.fx), 0)
        info = self.exit_json(job)
        self.assertEqual(info["kind"], "usage_limit")
        self.assertTrue(str(info["reset_at"]).startswith("2100-01-01"))
        self.assertEqual(jobs.state(jobs.load(job.id), {}), "waiting")

    def test_cooling_and_logged_out_is_waiting(self) -> None:
        # Claude hits its limit and Codex isn't logged in: the job waits for Claude's reset (serve
        # requeues it then) instead of failing.
        job = self.git_job(engines=("claude", "codex"))
        self.write(self.fc / "fail.1", USAGE_2100)
        self.write(self.fx / "login", "Not logged in")
        self.write(self.fx / "login.rc", "1")
        self.assertEqual(ax.execute(job.id, resume=False), 1)
        self.assertEqual(jobs.state(jobs.load(job.id), {}), "waiting")
        self.assertTrue(str(self.exit_json(job)["reset_at"]).startswith("2100-01-01"))

    def test_codex_resumes_its_own_thread(self) -> None:
        job = self.git_job(engines=("codex",))
        self.write(self.fx / "fail.1", json.dumps("stream disconnected before completion"))
        self.assertEqual(ax.execute(job.id, resume=False), 0)
        self.assertEqual(self.calls(self.fx), 2)
        second = (self.fx / "argv.2").read_text().splitlines()
        self.assertEqual(second[:3], ["exec", "resume", "T-1"])
        self.assertEqual(self.exit_json(job)["engine"], "codex")

    def test_sandbox_unavailable_runs_nothing(self) -> None:
        job = self.git_job()
        with mock.patch.object(agent_sandbox, "probe", return_value="no bwrap"):
            self.assertEqual(ax.execute(job.id, resume=False), 1)
        info = self.exit_json(job)
        self.assertEqual(info["kind"], "sandbox")
        self.assertIn("no bwrap", str(info["reason"]))
        self.assertEqual(self.claude_calls(), 0)
        self.assertEqual(jobs.state(jobs.load(job.id), {}), "failed")

    @unittest.skipUnless(shutil.which("bwrap"), "bwrap not installed")
    def test_engine_runs_inside_the_wrap(self) -> None:
        job = self.git_job()
        seen: list[list[str]] = []

        def capture(_job: jobs.Job, argv: list[str], *_a: object) -> int:
            seen.append(argv)
            return 1
        with mock.patch.object(agent_sandbox, "wrap", REAL_WRAP), mock.patch.object(ax, "_run_engine", side_effect=capture):
            ax.execute(job.id, resume=False)
        argv = seen[0]
        self.assertEqual(argv[:2], ["timeout", "--kill-after=60s"])
        self.assertTrue(argv[3].endswith("bwrap"), argv[:5])
        tmpfs = [argv[i + 1] for i, a in enumerate(argv) if a == "--tmpfs"]
        self.assertIn(str(self.home.resolve()), tmpfs)
        self.assertIn(str(Path(shutil.which("claude") or "").resolve()), argv)   # the engine itself, inside it

    def test_old_job_json_loads(self) -> None:
        job = self.git_job()
        p = jobs.job_dir(job.id) / "job.json"
        data = json.loads(p.read_text())
        for k in ("engine", "history", "auto_resumes"):
            data.pop(k, None)
        p.write_text(json.dumps(data))
        old = jobs.load(job.id)
        self.assertEqual((old.engine, old.history, old.auto_resumes), ("", [], 0))
        self.assertEqual(jobs.state(old, {}), "interrupted")
        self.assertEqual(ax.execute(job.id, resume=True), 0)

    def test_claude_bookkeeping_is_not_review_noise(self) -> None:
        job = self.git_job()
        # Claude Code 2.1.319's sandbox leaves .claude/.cc-writes/ (a directory) in the copy
        self.claude_script('mkdir -p .claude/.cc-writes && : >.claude/.cc-writes/w1\nprintf "x\\n" >>app.py\n')
        ax.execute(job.id, resume=False)
        self.assertNotIn(".cc-writes", self.result(job, "changes.diff"))
        self.assertIn("app.py", self.result(job, "changes.diff"))


class ChecksAndReview(Attempts):
    def test_fix_round_resumes_with_the_failure(self) -> None:
        # The check passes once fixed.txt exists; the second engine run creates it.
        self.claude_script('[ "$(wc -l <"$WS_FAKE_CLAUDE/calls")" -ge 2 ] && : >fixed.txt\n')
        job = self.git_job(checks=("test -e fixed.txt || { echo not-fixed-yet; exit 4; }",))
        self.assertEqual(ax.execute(job.id, resume=False), 0)
        self.assertEqual(self.claude_calls(), 2)
        second = (self.fc / "stdin.2").read_text()
        self.assertIn("checks failed", second)
        self.assertIn("not-fixed-yet", second)
        argv2 = (self.fc / "argv.2").read_text().splitlines()
        self.assertIn("--resume", argv2)   # the same session fixes its own change
        info = self.exit_json(job)
        self.assertEqual((info["checks"], info["fix_rounds"]), ("pass", 1))
        self.assertEqual(json.loads(self.result(job, "checks.json"))[0]["exit"], 0)

    def test_no_fix_rounds_records_the_failure(self) -> None:
        job = self.git_job(checks=("exit 4",), fix_rounds=0)
        self.assertEqual(ax.execute(job.id, resume=False), 0)   # the job finished; its checks didn't pass
        self.assertEqual(self.claude_calls(), 1)
        info = self.exit_json(job)
        self.assertEqual(info["checks"], "fail")
        self.assertEqual(jobs.state(jobs.load(job.id), {}), "succeeded")

    def test_checks_only_after_done(self) -> None:
        job = self.git_job(checks=("touch ran-checks",))
        self.write(self.fc / "report", '{"status":"question","summary":"s","question":"q?","tests":null,"notes":null}')
        ax.execute(job.id, resume=False)
        self.assertFalse((jobs.job_dir(job.id) / "wc" / "ran-checks").exists())
        self.assertEqual(self.exit_json(job)["checks"], "none")

    def test_review_recorded_and_read_only(self) -> None:
        job = self.git_job(engines=("claude", "codex"), review="codex")
        self.claude_script('printf "x\\n" >>app.py\n')
        self.write(self.fx / "report", json.dumps({"verdict": "concerns", "summary": "one issue",
                                                   "findings": [{"file": "app.py", "line": 3, "issue": "off by one"}]}))
        self.write(self.fx / "script.sh", 'printf "review wrote this\\n" >>app.py 2>/dev/null; true\n')
        wc = jobs.job_dir(job.id) / "wc"
        self.assertEqual(ax.execute(job.id, resume=False), 0)
        review = json.loads(self.result(job, "review.json"))
        self.assertEqual(review["verdict"], "concerns")
        self.assertEqual(review["findings"][0]["issue"], "off by one")
        argv = (self.fx / "argv").read_text().splitlines()
        self.assertEqual(argv[argv.index("-s") + 1], "read-only")
        stdin = (self.fx / "stdin").read_text()
        self.assertIn("do the thing", stdin)
        self.assertIn("app.py", stdin)   # the patch is in the prompt
        self.assertEqual(jobs.load(job.id).engine, "claude")   # the job's own session is untouched
        self.assertEqual(self.exit_json(job)["review"], "concerns")
        # A review that writes anyway (this fake ignores -s read-only) never reaches the patch, which
        # was taken before it, and is reported.
        self.assertIn("review wrote this", (wc / "app.py").read_text())
        self.assertNotIn("review wrote this", self.result(job, "changes.diff"))
        self.assertIn("the review changed the working copy", self.result(job, "warnings.txt"))

    def test_review_engine_must_be_allowed_and_available(self) -> None:
        job = self.git_job(engines=("claude", "codex"), review="codex")
        self.write(self.fx / "login", "Not logged in")
        self.write(self.fx / "login.rc", "1")
        self.assertEqual(ax.execute(job.id, resume=False), 0)
        self.assertFalse((jobs.job_dir(job.id) / "result" / "review.json").exists())
        self.assertIn("review", self.result(job, "warnings.txt"))


class Conversations(Attempts):
    def test_answer_after_a_question_resumes_the_same_session(self) -> None:
        job = self.git_job()
        self.write(self.fc / "report.1", '{"status":"question","summary":"s","question":"A or B?","tests":null,"notes":null}')
        ax.execute(job.id, resume=False)
        self.assertEqual(jobs.state(jobs.load(job.id), {}), "needs-you")
        sid = jobs.load(job.id).session_id
        jobs.post(jobs.load(job.id), "you", "use option B")
        self.assertEqual(ax.execute(job.id, resume=True), 0)
        stdin = (self.fc / "stdin.2").read_text()
        self.assertIn("use option B", stdin)
        self.assertNotIn("stopped before it finished", stdin)   # it asked; it wasn't interrupted
        argv = (self.fc / "argv.2").read_text().splitlines()
        self.assertEqual(argv[argv.index("--resume") + 1], sid)
        self.assertEqual(jobs.undelivered(jobs.load(job.id)), [])
        self.assertEqual(jobs.state(jobs.load(job.id), {}), "succeeded")
        froms = [m["from"] for m in jobs.thread(jobs.load(job.id))]
        self.assertEqual(froms, ["job", "you", "job"])   # the reports are part of the conversation

    def test_tell_while_running_waits_for_the_turn(self) -> None:
        job = self.git_job()
        self.claude_script('[ "$(wc -l <"$WS_FAKE_CLAUDE/calls")" -eq 1 ] && sleep 1\n')

        def tell_during_the_run() -> None:
            for _ in range(100):
                if jobs.live_run(jobs.load(job.id)) is not None:
                    break
                time.sleep(0.02)
            jobs.post(jobs.load(job.id), "you", "also handle the empty case")
        t = threading.Thread(target=tell_during_the_run)
        t.start()
        self.assertEqual(ax.execute(job.id, resume=False), 0)
        t.join(10)
        self.assertEqual(self.claude_calls(), 2)
        self.assertIn("also handle the empty case", (self.fc / "stdin.2").read_text())
        argv = (self.fc / "argv.2").read_text().splitlines()
        self.assertIn("--resume", argv)
        self.assertFalse(any(c[0] == "add" for c in self.pueue_calls()))   # delivered in place, no new task

    def test_message_during_collect_requeues(self) -> None:
        job = self.git_job()
        real_collect = ax.collect
        posted: list[bool] = []

        def collect_and_tell(j: jobs.Job, jd: Path) -> list[str]:
            if not posted:
                posted.append(True)
                jobs.post(jobs.load(j.id), "you", "one more thing")
            return real_collect(j, jd)
        self.pueue_status({})
        with mock.patch.object(ax, "collect", side_effect=collect_and_tell):
            self.assertEqual(ax.execute(job.id, resume=False), 0)
        adds = [c for c in self.pueue_calls() if c[0] == "add"]
        self.assertEqual(len(adds), 1)
        self.assertEqual(adds[0][-1], "--resume")
        self.assertFalse((jobs.job_dir(job.id) / "result" / "exit.json").exists())   # archived: it goes on
        self.assertEqual(ax.execute(job.id, resume=True), 0)
        self.assertIn("one more thing", (self.fc / "stdin.2").read_text())
        self.assertEqual(jobs.undelivered(jobs.load(job.id)), [])


class Events(Attempts):
    def test_a_finished_job_is_an_event_and_a_notice(self) -> None:
        from wslib import agent_events
        notices: list[str] = []
        job = self.git_job(checks=("true",))
        with mock.patch.object(agent_events, "notify", side_effect=notices.append):
            ax.execute(job.id, resume=False)
        events = [json.loads(line) for line in agent_events.events_path().read_text().splitlines()]
        self.assertEqual(events[-1]["kind"], "succeeded")
        self.assertEqual(events[-1]["job"], job.id)
        self.assertIn("checks pass", events[-1]["text"])
        self.assertEqual(len(notices), 1)
        self.assertIn(job.id, notices[0])

    def test_needs_you_and_waiting_are_events(self) -> None:
        from wslib import agent_events
        with mock.patch.object(agent_events, "notify"):
            q = self.git_job()
            self.write(self.fc / "report", '{"status":"question","summary":"s","question":"A or B?","tests":null,"notes":null}')
            ax.execute(q.id, resume=False)
            (self.fc / "report").unlink()
            self.write(self.fc / "fail.2", USAGE_2100)
            w = self.make_job(self.home / "src" / "proj", "git", jobs.load(q.id).base, prompt="another")
            ax.execute(w.id, resume=False)
        kinds = [json.loads(line)["kind"] for line in agent_events.events_path().read_text().splitlines()]
        self.assertEqual(kinds, ["needs-you", "waiting"])

    def test_a_requeued_job_is_no_event(self) -> None:
        from wslib import agent_events
        job = self.git_job()
        self.pueue_status({})
        real_collect = ax.collect

        def collect_and_tell(j: jobs.Job, jd: Path) -> list[str]:
            jobs.post(jobs.load(j.id), "you", "more")
            return real_collect(j, jd)
        with mock.patch.object(ax, "collect", side_effect=collect_and_tell), mock.patch.object(agent_events, "notify"):
            ax.execute(job.id, resume=False)
        self.assertFalse(agent_events.events_path().exists())


REAL_WRAP = agent_sandbox.wrap


@unittest.skipUnless(HAVE_SVN, "svn/svnadmin not installed")
class ExecSvn(Exec):
    def svn_job(self) -> tuple[str, Path, jobs.Job]:
        url, wc = self.svn_repo()
        job = self.make_job(wc, "svn", {"url": f"{url}/trunk", "repos_root": url, "rev": "1"})
        return url, wc, job

    def test_execute_svn_full_change_set(self) -> None:
        url, user_wc, job = self.svn_job()
        self.claude_script("\n".join([
            'printf "a2\\n" >a.txt',
            "svn propset -q svn:eol-style native a.txt",
            "svn propset -q svn:executable '*' run.sh",
            "python3 -c \"open('logo.bin','wb').write(bytes(range(255,-1,-1)))\"",
            "python3 -c \"open('new.bin','wb').write(b'\\x00\\x01bin')\" && svn add -q new.bin",
            'printf "new\\n" >new.txt && svn add -q new.txt',
            "svn rm -q sub/b.txt",
            "svn mv -q a.txt renamed.txt",
            'printf "stray\\n" >extra.txt',
            "svn commit -m sneaky >\"$WS_FAKE_CLAUDE/commit.out\" 2>&1; echo $? >\"$WS_FAKE_CLAUDE/commit.rc\"",
        ]) + "\n")
        self.assertEqual(ax.execute(job.id, resume=False), 0)
        self.assertEqual((self.fc / "commit.rc").read_text().strip(), "3")   # the shim refused it
        self.assertEqual(svn("info", "--show-item", "revision", f"{url}/trunk"), "1")   # nothing reached the server
        props = self.result(job, "props.txt")
        self.assertIn("svn:executable", props)
        self.assertIn("run.sh", props)
        manifest = self.result(job, "manifest.txt")
        self.assertRegex(manifest, r"renamed\.txt.*moved from a\.txt")
        self.assertRegex(manifest, r"new\.bin.*binary")
        self.assertIn("extra.txt", self.result(job, "warnings.txt"))
        self.assertEqual((jobs.job_dir(job.id) / "result" / "unversioned" / "extra.txt").read_text(), "stray\n")
        apply_txt = self.result(job, "apply.txt")
        self.assertIn("--strip 1", apply_txt)
        # The patch reproduces the change set in a fresh checkout of the same base.
        fresh = self.root / "fresh"
        svn("checkout", "-r", "1", f"{url}/trunk", str(fresh))
        svn("patch", "--strip", "1", str(jobs.job_dir(job.id) / "result" / "changes.diff"), cwd=fresh)
        wc = jobs.job_dir(job.id) / "wc"
        for f in ("renamed.txt", "logo.bin", "new.bin", "new.txt", "run.sh"):
            self.assertEqual((fresh / f).read_bytes(), (wc / f).read_bytes(), f)
        self.assertFalse((fresh / "sub" / "b.txt").exists())
        self.assertFalse((fresh / "a.txt").exists())
        self.assertEqual(svn("propget", "svn:executable", "run.sh", cwd=fresh), "*")
        self.assertEqual(svn("propget", "svn:eol-style", "renamed.txt", cwd=fresh), "native")
        self.assertEqual(svn("status", "-q", cwd=user_wc), "")   # the user's working copy is untouched

    def test_review_job_prepares_sparse_copy_and_input(self) -> None:
        url, user_wc = self.svn_repo()
        self.write(user_wc / "other" / "c.txt", "c\n")
        svn("add", "-q", "other", cwd=user_wc)
        svn("commit", "-q", "-m", "r2: other", cwd=user_wc)
        self.write(user_wc / "sub" / "b.txt", "b changed\n")
        svn("commit", "-q", "-m", "r3: change sub", cwd=user_wc)
        job = self.make_job(user_wc, "svn", {"url": f"{url}/trunk", "repos_root": url, "rev": "3", "review_rev": "3",
                                             "sparse": "sub"})
        self.assertEqual(ax.execute(job.id, resume=False), 0)
        wc = jobs.job_dir(job.id) / "wc"
        self.assertEqual((wc / "sub" / "b.txt").read_text(), "b changed\n")
        self.assertFalse((wc / "other").exists())   # only what the revision touched
        self.assertFalse((wc / "a.txt").exists())
        inp = jobs.job_dir(job.id) / "input"
        self.assertIn("+b changed", (inp / "r3.diff").read_text())
        self.assertIn("r3: change sub", (inp / "r3.log").read_text())
        argv = (self.fc / "argv").read_text().splitlines()
        self.assertEqual(argv[argv.index("--add-dir") + 1], str(inp))
        # root files and a directory: the root's files first, so its depth doesn't drop the directory
        job2 = self.make_job(user_wc, "svn", {"url": f"{url}/trunk", "repos_root": url, "rev": "3", "review_rev": "2",
                                              "sparse": "other\n."})
        self.assertEqual(ax.execute(job2.id, resume=False), 0)
        wc2 = jobs.job_dir(job2.id) / "wc"
        self.assertTrue((wc2 / "a.txt").exists())
        self.assertTrue((wc2 / "other" / "c.txt").exists())
        self.assertFalse((wc2 / "sub").exists())

    def test_checkout_at_recorded_revision(self) -> None:
        url, user_wc, job = self.svn_job()
        self.write(user_wc / "a.txt", "r2\n")
        svn("commit", "-m", "r2", cwd=user_wc)
        ax.execute(job.id, resume=False)
        wc = jobs.job_dir(job.id) / "wc"
        self.assertEqual(svn("info", "--show-item", "revision", str(wc)), "1")
        self.assertEqual((wc / "a.txt").read_text(), "a\n")

    def test_prepare_failure_recorded(self) -> None:
        _, wc = self.svn_repo()
        job = self.make_job(wc, "svn", {"url": (self.root / "nope").as_uri(), "repos_root": (self.root / "nope").as_uri(),
                                        "rev": "1"})
        self.assertEqual(ax.execute(job.id, resume=False), 1)
        self.assertEqual(self.exit_json(job)["exit_code"], 1)
        self.assertIn("E", (jobs.job_dir(job.id) / "exec.log").read_text())
        self.assertEqual(self.claude_calls(), 0)

    def test_shim_blocks_and_has_no_cached_credentials(self) -> None:
        _, _, job = self.svn_job()
        ax.execute(job.id, resume=False)
        shim = jobs.job_dir(job.id) / "bin" / "svn"
        wc = jobs.job_dir(job.id) / "wc"
        r = subprocess.run([str(shim), "commit", "-m", "x"], cwd=wc, capture_output=True, text=True)
        self.assertEqual(r.returncode, 3)
        self.assertIn("writes to the repository", r.stderr)
        r = subprocess.run([str(shim), "status"], cwd=wc, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        cfg = jobs.job_dir(job.id) / "svn-config"
        self.assertTrue((cfg / "servers").is_file())   # svn ran with the job's own config dir, not ~/.subversion
        self.assertEqual([p for p in cfg.rglob("*") if p.is_file() and "auth" in p.parts], [])   # no cached credentials

    def test_self_ignored_tool_dirs_are_not_review_noise(self) -> None:
        _, _, job = self.svn_job()
        self.claude_script('mkdir -p .toolstate/logs && printf "*\\n" >.toolstate/.gitignore && printf x >.toolstate/logs/a\n'
                           'printf "keep\\n" >notes.txt\n')
        ax.execute(job.id, resume=False)
        warnings = self.result(job, "warnings.txt")
        self.assertIn("notes.txt", warnings)
        self.assertNotIn(".toolstate", warnings)
        self.assertRegex(self.result(job, "manifest.txt"), r"\.toolstate\tunversioned tool directory \(ignores itself\)")
        self.assertFalse((jobs.job_dir(job.id) / "result" / "unversioned" / ".toolstate").exists())
        self.assertTrue((jobs.job_dir(job.id) / "result" / "unversioned" / "notes.txt").exists())

    def test_claude_bookkeeping_is_not_review_noise_svn(self) -> None:
        _, _, job = self.svn_job()
        self.claude_script('mkdir -p .claude/.cc-writes\nprintf "keep\\n" >notes.txt\n')   # as measured: an empty dir
        ax.execute(job.id, resume=False)
        warnings = self.result(job, "warnings.txt")
        self.assertNotIn(".claude", warnings)
        self.assertIn("notes.txt", warnings)
        self.assertFalse((jobs.job_dir(job.id) / "result" / "unversioned" / ".claude").exists())

    def test_partial_checkout_is_rebuilt(self) -> None:
        _, _, job = self.svn_job()
        self.write(jobs.job_dir(job.id) / "wc" / "junk.txt", "half a checkout\n")
        self.assertEqual(ax.execute(job.id, resume=False), 0)
        wc = jobs.job_dir(job.id) / "wc"
        self.assertFalse((wc / "junk.txt").exists())
        self.assertEqual(svn("info", "--show-item", "revision", str(wc)), "1")

    def test_plain_rm_and_mv_are_warned(self) -> None:
        _, _, job = self.svn_job()
        self.claude_script("rm sub/b.txt\nmv a.txt plain-moved.txt\n")
        ax.execute(job.id, resume=False)
        warnings = self.result(job, "warnings.txt")
        self.assertRegex(warnings, r"missing.*sub/b\.txt")
        self.assertRegex(warnings, r"missing.*a\.txt")
        self.assertIn("plain-moved.txt", warnings)

    def test_symlinks_are_not_followed(self) -> None:
        _, _, job = self.svn_job()
        outside = self.write(self.root / "outside" / "secret.txt", "not for the result\n")
        self.claude_script(f"ln -s {outside.parent} dirlink\nln -s {outside} filelink\n")
        ax.execute(job.id, resume=False)
        unv = jobs.job_dir(job.id) / "result" / "unversioned"
        self.assertFalse((unv / "dirlink").exists())
        self.assertFalse((unv / "filelink").exists())
        self.assertRegex(self.result(job, "warnings.txt"), r"symlink.*dirlink")

    def test_inspect_lists_changes(self) -> None:
        _, _, job = self.svn_job()
        self.claude_script('printf "zz\\n" >>a.txt\n')
        ax.execute(job.id, resume=False)
        text = ax.inspect(jobs.load(job.id))
        self.assertIn("a.txt", text)
        self.assertIn("M", text)


class ClaudeOutput(unittest.TestCase):
    def test_reads_result_from_array_and_object(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "claude.json"
            p.write_text(json.dumps([{"type": "system", "subtype": "init", "session_id": "S"},
                                     {"type": "result", "is_error": False, "num_turns": 2, "result": "ok", "session_id": "S"}]))
            self.assertEqual(engines.claude_result(p)["result"], "ok")
            p.write_text(json.dumps({"type": "result", "is_error": True, "result": "bad"}) + "\n")
            self.assertEqual(engines.claude_result(p)["result"], "bad")
            p.write_text("not json\n")
            self.assertEqual(engines.claude_result(p), {})


if __name__ == "__main__":
    unittest.main()
