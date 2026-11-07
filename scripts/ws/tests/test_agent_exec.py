"""wslib.agent_exec: what pueue runs for a job — a private working copy, write-refusing shims, a
headless claude with a clean environment, and the review artifacts collected afterwards."""

from __future__ import annotations

import json
import os
import subprocess
import unittest
from pathlib import Path

from agent_helpers import HAVE_SVN, AgentScratch, git, svn

from wslib import agent_exec as ax
from wslib import agent_registry as reg
from wslib import jobs

FAKE_CLAUDE = r"""
d="$WS_FAKE_CLAUDE"
printf '%s\n' "$@" >"$d/argv"
env >"$d/env"
cat >"$d/stdin"
pwd >"$d/cwd"
sid="" prev=""
for a in "$@"; do case "$prev" in --session-id | --resume) sid="$a" ;; esac; prev="$a"; done
mkdir -p "$HOME/.claude/projects/fake" && : >"$HOME/.claude/projects/fake/$sid.jsonl"
echo x >>"$d/calls"
[ -f "$d/script.sh" ] && bash "$d/script.sh"
[ -f "$d/sleep" ] && sleep "$(cat "$d/sleep")"
# claude 2.1.319's --output-format json: one line, an array of every message ending in the result
printf '[{"type":"system","subtype":"init","session_id":"%s","cwd":"%s"},{"type":"assistant","message":{"content":[]}},{"type":"result","subtype":"success","is_error":%s,"duration_ms":10,"num_turns":3,"result":"done: changed things","session_id":"%s","total_cost_usd":0,"terminal_reason":"completed"}]\n' \
  "$sid" "$PWD" "$(cat "$d/is_error" 2>/dev/null || echo false)" "$sid"
exit "$(cat "$d/exit" 2>/dev/null || echo 0)"
"""


class Exec(AgentScratch):
    def setUp(self) -> None:
        super().setUp()
        self.fc = self.root / "fake-claude"
        self.fc.mkdir()
        os.environ["WS_FAKE_CLAUDE"] = str(self.fc)
        self.fake("claude", FAKE_CLAUDE)

    def make_job(self, repo: Path, vcs: str, base: dict[str, str], *, timeout: str = "2h",
                 commands: list[str] | None = None, prompt: str = "do the thing") -> jobs.Job:
        reg.allow(repo, vcs, commands or [])
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
        for args in (["status"], ["commit", "-m", "x"], ["-C", "/r", "diff"], ["log", "--oneline"], [], ["--version"]):
            self.assertIsNone(ax.git_refusal(args), args)


class Env(unittest.TestCase):
    def test_clean_env(self) -> None:
        base = {"PATH": "/usr/bin", "HOME": "/h", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "x",
                "CLAUDE_CODE_MESSAGING_TOKEN": "y", "CLAUDE_CODE_MESSAGING_SOCKET": "z", "CLAUDE_CODE_ENTRYPOINT": "cli",
                "CLAUDE_CODE_BRIDGE_SESSION_ID": "b", "CLAUDE_CODE_EXECPATH": "/e", "CLAUDE_CODE_CHILD_SESSION": "1",
                "CLAUDE_CODE_SESSION_ATTENDED": "1", "CLAUDE_CODE_OAUTH_TOKEN": "keep", "CLAUDE_CODE_USE_VERTEX": "1",
                "ANTHROPIC_API_KEY": "keep2", "SSH_AUTH_SOCK": "/s", "GH_TOKEN": "g", "GITHUB_TOKEN": "g2",
                "GITLAB_TOKEN": "g3", "WS_AGENT_JOB": "old"}
        env = ax.clean_env(base, Path("/job/bin"), "abc123")
        for gone in ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_MESSAGING_SOCKET",
                     "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_EXECPATH",
                     "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED", "SSH_AUTH_SOCK", "GH_TOKEN",
                     "GITHUB_TOKEN", "GITLAB_TOKEN"):
            self.assertNotIn(gone, env, gone)
        self.assertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "keep")
        self.assertEqual(env["CLAUDE_CODE_USE_VERTEX"], "1")
        self.assertEqual(env["ANTHROPIC_API_KEY"], "keep2")
        self.assertEqual(env["PATH"], "/job/bin" + os.pathsep + "/usr/bin")
        self.assertEqual(env["WS_AGENT_JOB"], "abc123")
        self.assertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        self.assertEqual(env["GIT_CONFIG_KEY_0"], "credential.helper")
        self.assertEqual(env["GIT_CONFIG_VALUE_0"], "")
        self.assertTrue(env["GIT_ASKPASS"].endswith("false"))
        self.assertEqual(env["SVN_EDITOR"], "false")


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

    def test_no_changes_warned(self) -> None:
        repo = self.git_repo()
        job = self.make_job(repo, "git", {"commit": git("rev-parse", "HEAD", cwd=repo), "branch": "main"})
        ax.execute(job.id, resume=False)
        self.assertIn("no changes", self.result(job, "warnings.txt"))


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
            self.assertEqual(ax._claude_result(p)["result"], "ok")
            p.write_text(json.dumps({"type": "result", "is_error": True, "result": "bad"}) + "\n")
            self.assertEqual(ax._claude_result(p)["result"], "bad")
            p.write_text("not json\n")
            self.assertEqual(ax._claude_result(p), {})


if __name__ == "__main__":
    unittest.main()
