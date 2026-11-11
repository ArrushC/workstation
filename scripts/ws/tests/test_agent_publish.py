"""wslib.agent_publish: the one place ws-agent writes to a server. Off by default; each kind of
write is named per repository by the person; only something new is ever created (a comment, a
new branch, a draft PR, a new SVN branch); a job is published once; automatically only for
passing jobs a source made. `origin` here is a local bare repository (pushes are real), SVN is a
real file:// repository, and `gh` is a stand-in that records what would be posted."""

from __future__ import annotations

import io
import json
import os
import time
import unittest
import unittest.mock
from contextlib import chdir, redirect_stderr, redirect_stdout
from pathlib import Path

from agent_helpers import HAVE_SVN, AgentScratch, git, svn

from wslib import agent, agent_events, agent_sources, core, jobs
from wslib import agent_publish as pub
from wslib import agent_registry as reg
from wslib import agent_serve as serve

SLUG = "ArrushC/proj"
FAKE_GH = r"""d="$WS_FAKE_GH"
( IFS=$'\x1f'; printf '%s\n' "$*" ) >>"$d/argv.log"
n=$(wc -l <"$d/argv.log" | tr -d ' ')
case "$1 $2" in
"api --method") cat >"$d/body.$n"; [ -f "$d/post-then-fail" ] && { echo "HTTP 502" >&2; exit 1; }; echo '{"html_url": "https://github.com/ArrushC/proj/issues/7#issuecomment-1"}' ;;
"pr create") cat >"$d/pr-body"; [ -f "$d/pr-fails" ] && { echo "pull request create failed" >&2; exit 1; }
  echo "https://github.com/ArrushC/proj/pull/8" ;;
api\ repos/*/pulls/*) [ -f "$d/pulls-fail" ] && { echo "HTTP 502 SERVER WORDS" >&2; exit 1; }; cat "$d/pulls-ref" 2>/dev/null || echo "" ;;
api\ repos/*) echo main ;;
*) exit 1 ;;
esac
"""
def outside_fences(body: str) -> str:
    """The text GitHub renders as markdown: everything not inside a ``` fence."""
    out, fence = [], ""
    for ln in body.splitlines():
        run = len(ln) - len(ln.lstrip("`"))
        if not fence and run >= 3:
            fence = "`" * run
        elif fence and ln.strip() == fence:
            fence = ""
        elif not fence:
            out.append(ln)
    return "\n".join(out)


SUMMARY = "Renamed f. Thanks @everyone, see #1.\n```\n<script>x</script>\x1b[2J"


class Publish(AgentScratch):
    def setUp(self) -> None:
        super().setUp()
        self.gx = self.root / "fake-gh"
        self.gx.mkdir()
        os.environ["WS_FAKE_GH"] = str(self.gx)
        self.fake("gh", FAKE_GH)
        self.repo = self.git_repo()
        self.origin = self.root / "origin.git"
        git("init", "-q", "--bare", str(self.origin), cwd=self.root)
        git("remote", "add", "origin", f"https://github.com/{SLUG}.git", cwd=self.repo)
        git("config", f"url.{self.origin.as_uri()}.insteadOf", f"https://github.com/{SLUG}.git", cwd=self.repo)
        git("config", "user.name", "The Person", cwd=self.repo)
        git("config", "user.email", "person@example.invalid", cwd=self.repo)
        git("push", "-q", "origin", "main", cwd=self.repo)
        self.head = git("rev-parse", "HEAD", cwd=self.repo)
        reg.allow(self.repo, "git", [])
        self.pueue_status({})

    def settings(self, **kw: object) -> None:
        reg.set_publish(self.repo, reg.Publish(**kw))  # type: ignore[arg-type]

    def job(self, *, origin: str = f"gh:{SLUG}:c9", checks: str = "pass", number: int = 7, change: bool = True,
            title: str = "ArrushC/proj#7: SOMEONE ELSE'S WORDS") -> jobs.Job:
        j = jobs.Job(id=jobs.new_id(), title=title, repo="~/src/proj", vcs="git",
                     base={"commit": self.head, "branch": "main"}, prompt_sha=f"s{time.time_ns()}", paths=[],
                     created=core.now_iso(), session_id="", timeout="2h", origin=origin, engine="claude")
        jobs.save(j)
        res = jobs.job_dir(j.id) / "result"
        self.write(res / "exit.json", json.dumps({"exit_code": 0, "status": "done", "kind": "ok", "engine": "claude",
                                                  "checks": checks, "finished": "2100-01-01T00:00:00+00:00"}))
        self.write(res / "report.json", json.dumps({"status": "done", "summary": SUMMARY}))
        diff = ("diff --git a/app.py b/app.py\n--- a/app.py\n+++ b/app.py\n@@ -1,2 +1,2 @@\n def f():\n"
                "-    return 1\n+    return 2\n") if change else ""
        self.write(res / "changes.diff", diff)
        self.write(res / "manifest.txt", "M\tapp.py\n" if change else "")
        if origin.startswith("gh:") and number:
            agent_sources.remember_thread(f"gh:{SLUG}#{number}", j.id)
        return j

    def gh_calls(self) -> list[list[str]]:
        log = self.gx / "argv.log"
        return [ln.split("\x1f") for ln in log.read_text().splitlines()] if log.exists() else []

    def remote_refs(self) -> dict[str, str]:
        out = git("for-each-ref", "--format=%(refname) %(objectname)", cwd=self.origin)
        return dict(ln.split() for ln in out.splitlines())

    def local_state(self) -> tuple[str, str, str, str]:
        return (git("rev-parse", "HEAD", cwd=self.repo), git("for-each-ref", cwd=self.repo),
                git("status", "--porcelain", cwd=self.repo), (self.repo / "app.py").read_text())

    def cli(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err), chdir(self.root):
            rc = agent.main(list(args))
        return rc, out.getvalue(), err.getvalue()

    # --- off by default, and only what the settings name -------------------------------------

    def test_nothing_is_written_until_the_person_turns_it_on(self) -> None:
        j = self.job()
        before = self.remote_refs()
        lines = pub.publish(j, auto=False)
        self.assertIn("name no kind", lines[0])
        self.settings(mode="off", comment=True, draft_pr=True)
        self.assertTrue(all("not published" in ln and "off" in ln for ln in pub.publish(j, auto=False)))
        self.settings(mode="manual", comment=True, draft_pr=True)   # manual: serve never publishes
        self.assertTrue(all("not published" in ln for ln in pub.publish(j, auto=True)))
        self.assertEqual(serve.tick(time.time()), [])
        self.assertEqual((self.gh_calls(), self.remote_refs()), ([], before))
        reg.set_publish(self.repo, reg.Publish(mode="auto", comment=True))
        self.assertEqual(pub.kinds_for(j, reg.find(self.repo)), ["comment"])   # the PR wasn't named

    def test_a_typo_in_the_mode_never_publishes(self) -> None:
        self.settings(mode="auto", comment=True)
        p = reg.registry_path()
        p.write_text(p.read_text().replace('mode = "auto"', 'mode = "always"'))
        found = reg.find(self.repo)
        assert found is not None
        self.assertEqual(found.publish.mode, "off")

    # --- the comment ---------------------------------------------------------------------------

    def test_the_comment_is_fixed_text_and_an_inert_quote(self) -> None:
        self.settings(mode="manual", comment=True)
        j = self.job()
        lines = pub.publish(j, auto=False)
        self.assertRegex(lines[0], rf"{j.id}: published comment: https://github.com/")
        call = self.gh_calls()[-1]
        self.assertEqual(call[:4], ["api", "--method", "POST", f"repos/{SLUG}/issues/7/comments"])
        body = json.loads(next(self.gx.glob("body.*")).read_text())["body"]
        self.assertTrue(body.startswith("Posted by an agent (ws-agent job"))
        self.assertIn("not written by a person", body.splitlines()[0])
        self.assertIn("Checks: pass.", body)
        outside = outside_fences(body)
        for bit in ("everyone", "Renamed f", "script", "app.py"):
            self.assertNotIn(bit, outside)     # model text and file names only ever inside a code fence
        self.assertIn("Renamed f. Thanks @everyone, see #1.", body)
        self.assertNotIn("\x1b", body)
        self.assertNotIn("SOMEONE ELSE'S WORDS", body)   # the request's own text is never echoed
        again = pub.publish(j, auto=False)
        self.assertIn("already published", again[0])
        self.assertEqual(len([c for c in self.gh_calls() if c[:2] == ["api", "--method"]]), 1)   # once

    def test_a_job_with_no_issue_to_answer_posts_no_comment(self) -> None:
        self.settings(mode="manual", comment=True)
        mine = self.job(origin="", title="my own job")
        self.assertIn("name no kind", pub.publish(mine, auto=False)[0])
        self.assertEqual(self.gh_calls(), [])

    # --- the draft pull request ----------------------------------------------------------------

    def test_a_draft_pr_is_a_new_branch_and_touches_nothing_of_the_persons(self) -> None:
        self.settings(mode="manual", draft_pr=True, comment=True)
        j = self.job()
        local = self.local_state()
        lines = pub.publish(j, auto=False)
        self.assertRegex(lines[0], rf"{j.id}: published draft_pr: https://github.com/{SLUG}/pull/8")
        refs = self.remote_refs()
        self.assertEqual(set(refs), {"refs/heads/main", f"refs/heads/ws-agent/{j.id}"})
        self.assertEqual(refs["refs/heads/main"], self.head)   # the default branch is where it was
        tip = refs[f"refs/heads/ws-agent/{j.id}"]
        self.assertEqual(git("rev-parse", f"{tip}^", cwd=self.origin), self.head)   # one commit on the job's base
        self.assertIn("return 2", git("show", f"{tip}:app.py", cwd=self.origin))
        msg = git("log", "-1", "--format=%an|%B", tip, cwd=self.origin)
        self.assertTrue(msg.startswith(f"The Person|ws-agent {j.id}\n"), msg)
        self.assertNotIn("SOMEONE ELSE", msg)
        self.assertEqual(self.local_state(), local)   # HEAD, every ref, the index and the files
        create = next(c for c in self.gh_calls() if c[:2] == ["pr", "create"])
        self.assertIn("--draft", create)
        self.assertEqual((create[create.index("--head") + 1], create[create.index("--base") + 1]),
                         (f"ws-agent/{j.id}", "main"))
        self.assertTrue((self.gx / "pr-body").read_text().startswith("Draft, made by an agent"))
        self.assertIn("Draft pull request: https://github.com/ArrushC/proj/pull/8",
                      json.loads(next(self.gx.glob("body.*")).read_text())["body"])   # the comment links it
        self.assertFalse((jobs.job_dir(j.id) / "result" / "publish.index").exists())

    def test_an_existing_branch_is_never_written(self) -> None:
        self.settings(mode="manual", draft_pr=True)
        j = self.job()
        git("push", "-q", "origin", f"{self.head}:refs/heads/ws-agent/{j.id}", cwd=self.repo)
        before = self.remote_refs()
        lines = pub.publish(j, auto=False)
        self.assertIn("already exists on origin", lines[0])
        self.assertEqual(self.remote_refs(), before)
        self.assertFalse(any(c[:2] == ["pr", "create"] for c in self.gh_calls()))

    def test_an_origin_that_isnt_the_repository_or_an_empty_patch_publishes_nothing(self) -> None:
        self.settings(mode="manual", draft_pr=True)
        empty = self.job(change=False)
        self.assertIn("patch is empty", pub.publish(empty, auto=False)[0])
        j = self.job()
        git("remote", "set-url", "origin", "https://github.com/someone/else.git", cwd=self.repo)
        self.assertIn("someone/else", pub.publish(j, auto=False)[0])
        self.assertEqual(set(self.remote_refs()), {"refs/heads/main"})

    # --- automatic publishing ------------------------------------------------------------------

    def test_only_passing_source_jobs_are_published_automatically(self) -> None:
        self.settings(mode="auto", comment=True, draft_pr=True)
        for j, why in ((self.job(checks="fail"), "only passing"), (self.job(checks="none"), "only passing"),
                       (self.job(origin="", title="the person's own"), "a source made")):
            self.assertIn(why, pub.allowed(j, "draft_pr", auto=True) or "", j.title)
        self.assertEqual(serve.tick(time.time()), [])
        self.assertEqual(set(self.remote_refs()), {"refs/heads/main"})
        failing = self.job(checks="fail")
        self.assertIn("--even-failing", pub.allowed(failing, "draft_pr", auto=False) or "")
        self.assertIsNone(pub.allowed(failing, "draft_pr", auto=False, even_failing=True))

    def test_serve_publishes_once_with_a_notice(self) -> None:
        self.settings(mode="auto", comment=True, draft_pr=True)
        notices: list[str] = []
        j = self.job()
        with unittest.mock.patch.object(agent_events, "notify", side_effect=notices.append):
            lines = serve.tick(time.time())
            self.assertEqual(len([ln for ln in lines if ": published " in ln]), 2, lines)
            self.assertEqual(serve.tick(time.time()), [])   # once
        self.assertEqual(len(notices), 2)
        self.assertIn(f"refs/heads/ws-agent/{j.id}", self.remote_refs())
        rec = pub.record(j)
        self.assertTrue(rec["comment"]["auto"] and rec["draft_pr"]["url"])

    def test_the_automatic_cap_and_the_retry_limit(self) -> None:
        self.settings(mode="auto", comment=True)
        for _ in range(pub.AUTO_CAP):
            done = self.job()
            pub._save(done, "comment", {"url": "u", "at": core.now_iso(), "auto": True})
        self.assertIn("daily cap", pub.allowed(self.job(), "comment", auto=True) or "")

    def test_a_pr_that_fails_to_open_is_retried_without_pushing_again(self) -> None:
        self.settings(mode="auto", draft_pr=True)
        self.write(self.gx / "pr-fails", "")   # the push works, opening the PR doesn't
        j = self.job()
        for _ in range(pub.MAX_TRIES + 2):
            serve.tick(time.time())
        rec = pub.record(j)["draft_pr"]
        self.assertEqual(rec["tries"], pub.MAX_TRIES)   # then serve leaves it for the person
        tip = self.remote_refs()[f"refs/heads/ws-agent/{j.id}"]
        self.assertEqual(rec["commit"], tip)
        (self.gx / "pr-fails").unlink()
        self.assertIn("published draft_pr", pub.publish(j, auto=False)[0])   # the PR opens; nothing is pushed again
        self.assertEqual(self.remote_refs()[f"refs/heads/ws-agent/{j.id}"], tip)

    # --- the commands --------------------------------------------------------------------------

    def test_publish_to_is_the_persons_and_validates(self) -> None:
        rc, out, err = self.cli("publish-to", str(self.repo), "--mode", "auto", "--comment", "--draft-pr")
        self.assertEqual(rc, 0, err)
        self.assertIn("auto (GitHub comment, draft PR)", out)
        self.assertIn("without asking per job", err)
        self.assertIn("publish: auto", self.cli("repos")[1])
        self.assertEqual(self.cli("publish-to", str(self.repo), "--mode", "always")[0], 2)
        self.assertEqual(self.cli("publish-to", str(self.repo), "--svn-branch", "^/branches/x")[0], 2)   # a git repo
        reg.allow(self.repo, "git", [])   # allowing again keeps the settings
        found = reg.find(self.repo)
        assert found is not None
        self.assertEqual((found.publish.mode, found.publish.comment, found.publish.draft_pr), ("auto", True, True))
        self.assertTrue(found.publish.since)
        os.environ["CLAUDECODE"] = "1"
        self.assertEqual(self.cli("publish-to", str(self.repo), "--mode", "auto", "--comment")[0], 3)

    def test_publish_command_and_dry_run(self) -> None:
        self.settings(mode="manual", comment=True, draft_pr=True)
        j = self.job()
        rc, out, _ = self.cli("publish", j.id, "--dry-run")
        self.assertEqual(rc, 0)
        self.assertIn(f"would publish draft_pr: branch ws-agent/{j.id}", out)
        self.assertIn(f"would publish comment: a comment on {SLUG}#7", out)
        self.assertEqual((self.gh_calls(), set(self.remote_refs())), ([], {"refs/heads/main"}))
        rc, out, _ = self.cli("publish", j.id)
        self.assertEqual(rc, 0)
        self.assertEqual(self.cli("publish", j.id)[0], 3)   # nothing left to publish
        os.environ["WS_AGENT_JOB"] = "abc123"
        self.assertEqual(self.cli("publish", j.id)[0], 3)


@unittest.skipUnless(HAVE_SVN, "svn/svnadmin not installed")
class PublishSvn(AgentScratch):
    def setUp(self) -> None:
        super().setUp()
        self.url, self.wc = self.svn_repo()
        reg.allow(self.wc, "svn", [])
        self.pueue_status({})

    def job(self, origin: str = "") -> jobs.Job:
        j = jobs.Job(id=jobs.new_id(), title="rename a", repo="~/src/svnwc", vcs="svn",
                     base={"url": f"{self.url}/trunk", "repos_root": self.url, "rev": "1"}, prompt_sha=f"s{time.time_ns()}",
                     paths=[], created=core.now_iso(), session_id="", timeout="2h", origin=origin)
        jobs.save(j)
        res = jobs.job_dir(j.id) / "result"
        self.write(res / "exit.json", json.dumps({"exit_code": 0, "status": "done", "kind": "ok", "checks": "pass",
                                                  "finished": "2100-01-01T00:00:00+00:00"}))
        self.write(res / "changes.diff", "Index: trunk/a.txt\n===================================================================\n"
                                         "diff --git a/trunk/a.txt b/trunk/a.txt\n"
                                         "--- a/trunk/a.txt\t(revision 1)\n+++ b/trunk/a.txt\t(working copy)\n@@ -1 +1 @@\n-a\n+a2\n")
        return j

    def test_a_new_svn_branch_only_for_the_persons_own_job(self) -> None:
        reg.set_publish(self.wc, reg.Publish(mode="auto", svn_branch="^/branches/ws-agent"))
        j = self.job()
        self.assertIn("a source made", pub.allowed(j, "svn_branch", auto=True) or "")
        review = self.job(origin="svn:u-1:5")
        self.assertIn("never published automatically", pub.allowed(review, "svn_branch", auto=True) or "")
        self.assertIn("stays local", pub.allowed(review, "svn_branch", auto=False) or "")
        self.assertEqual(serve.tick(time.time()), [])
        self.assertEqual(svn("info", "--show-item", "revision", self.url), "1")   # nothing committed so far
        lines = pub.publish(j, auto=False)
        self.assertRegex(lines[0], rf"published svn_branch: {self.url}/branches/ws-agent/{j.id}@2")
        self.assertEqual(svn("cat", f"{self.url}/branches/ws-agent/{j.id}/a.txt"), "a2")
        self.assertEqual(svn("cat", f"{self.url}/trunk/a.txt"), "a")   # trunk is untouched
        self.assertEqual(svn("info", "--show-item", "last-changed-revision", f"{self.url}/trunk"), "1")
        self.assertEqual(svn("status", "-q", cwd=self.wc), "")          # so is the person's working copy
        self.assertFalse((jobs.job_dir(j.id) / "publish-wc").exists())
        self.assertIn("already published", pub.publish(j, auto=False)[0])

    def test_the_branch_parent_cant_be_the_jobs_own_tree(self) -> None:
        with self.assertRaises(ValueError):
            reg.set_publish(self.wc, reg.Publish(mode="manual", svn_branch="^/branches/../trunk"))
        reg.set_publish(self.wc, reg.Publish(mode="manual", svn_branch="^/branches/x"))
        j = self.job()
        j.base = dict(j.base, url=f"{self.url}/branches")   # the job's own tree would hold the new branch
        jobs.save(j)
        self.assertIn("inside", pub.publish(j, auto=False)[0])
        self.assertEqual(svn("info", "--show-item", "revision", self.url), "1")
        self.assertTrue(Path(self.wc / "a.txt").exists())


class ReviewFindings(Publish):
    """One test per finding of the whole-branch review of publish."""

    def test_a_draft_pr_never_pushes_commits_that_arent_on_the_target_branch(self) -> None:
        self.settings(mode="auto", draft_pr=True)
        fork = self.root / "fork"
        git("clone", "-q", str(self.origin), str(fork), cwd=self.root)
        self.write(fork / ".github" / "workflows" / "x.yml", "on: push\n")
        git("add", "-A", cwd=fork)
        git("commit", "-qm", "a fork contributor's commit", cwd=fork)
        git("push", "-q", "origin", "HEAD:refs/pull/1/head", cwd=fork)
        theirs = git("rev-parse", "HEAD", cwd=fork)
        git("fetch", "-q", "--no-write-fetch-head", "origin", "refs/pull/1/head", cwd=self.repo)
        j = self.job()
        j.base = {"commit": theirs, "branch": "pull/1/head"}
        jobs.save(j)
        before = self.remote_refs()
        self.assertEqual(serve.tick(time.time()), serve.tick(time.time()))
        lines = pub.publish(j, auto=False)
        self.assertIn("isn't on", lines[0])
        self.assertEqual(self.remote_refs(), before)   # their commit never became a branch of this repository
        # the person's own unpushed commits don't go out either
        self.write(self.repo / "secret.txt", "not pushed yet\n")
        git("add", "-A", cwd=self.repo)
        git("commit", "-qm", "local only", cwd=self.repo)
        mine = self.job(origin="", title="my own")
        mine.base = {"commit": git("rev-parse", "HEAD", cwd=self.repo), "branch": "main"}
        jobs.save(mine)
        self.assertIn("isn't on", pub.publish(mine, auto=False)[0])
        self.assertEqual(self.remote_refs(), before)

    def test_posted_text_is_inside_a_code_fence(self) -> None:
        self.settings(mode="manual", comment=True)
        j = self.job()
        res = jobs.job_dir(j.id) / "result"
        nasty = ("&commat;octocat &num;1 GH-2 https://github.com/o/r/issues/3 [link](https://evil.example) "
                 "![img](https://evil.example/x.png)\n````\nafter a long fence")
        self.write(res / "report.json", json.dumps({"status": "done", "summary": nasty}))
        self.write(res / "manifest.txt", "M\t[x](https://evil.example).py\n")
        self.write(res / "exit.json", json.dumps({"exit_code": 0, "status": "done", "kind": "ok", "checks": "pass",
                                                  "engine": "claude @everyone [x](y)"}))
        pub.publish(j, auto=False)
        body = json.loads(next(self.gx.glob("body.*")).read_text())["body"]
        outside = outside_fences(body)
        for bit in ("octocat", "GH-2", "evil.example", "issues/3", "after a long fence", "@", "]("):
            self.assertNotIn(bit, outside, bit)
        self.assertIn("&commat;octocat", body)   # shown as written, inside the fence

    def test_auto_never_publishes_what_finished_before_it_was_switched_on(self) -> None:
        old = self.job()
        res = jobs.job_dir(old.id) / "result"
        info = json.loads((res / "exit.json").read_text())
        self.write(res / "exit.json", json.dumps(dict(info, finished="2026-01-01T00:00:00+00:00")))
        self.settings(mode="manual", comment=True)
        rc, _, err = self.cli("publish-to", str(self.repo), "--mode", "auto", "--comment")
        self.assertEqual(rc, 0, err)
        self.assertIn("before publishing became automatic", pub.allowed(old, "comment", auto=True) or "")
        self.assertEqual(serve.tick(time.time()), [])
        new = self.job()
        info = json.loads((jobs.job_dir(new.id) / "result" / "exit.json").read_text())
        self.write(jobs.job_dir(new.id) / "result" / "exit.json", json.dumps(dict(info, finished="2100-01-01T00:00:00+00:00")))
        self.assertIsNone(pub.allowed(new, "comment", auto=True))

    def test_a_comment_that_may_have_been_posted_is_never_posted_again_automatically(self) -> None:
        self.cli("publish-to", str(self.repo), "--mode", "auto", "--comment")
        j = self.job()
        info = json.loads((jobs.job_dir(j.id) / "result" / "exit.json").read_text())
        self.write(jobs.job_dir(j.id) / "result" / "exit.json", json.dumps(dict(info, finished="2100-01-01T00:00:00+00:00")))
        self.write(self.gx / "post-then-fail", "")   # GitHub created it, then the connection dropped
        for _ in range(4):
            serve.tick(time.time())
        posts = [c for c in self.gh_calls() if c[:2] == ["api", "--method"]]
        self.assertEqual(len(posts), 1)
        self.assertIn("may have reached", pub.allowed(j, "comment", auto=True) or "")

    def test_the_push_writes_one_new_branch_and_nothing_else(self) -> None:
        self.settings(mode="manual", draft_pr=True)
        git("config", "push.followTags", "true", cwd=self.repo)
        git("tag", "-a", "v9-private", "-m", "local", cwd=self.repo)
        j = self.job()
        self.assertIn("published draft_pr", pub.publish(j, auto=False)[0])
        self.assertEqual(set(self.remote_refs()), {"refs/heads/main", f"refs/heads/ws-agent/{j.id}"})   # no tag

    def test_a_patch_that_touches_workflows_needs_the_person(self) -> None:
        self.cli("publish-to", str(self.repo), "--mode", "auto", "--draft-pr")
        j = self.job()
        res = jobs.job_dir(j.id) / "result"
        info = json.loads((res / "exit.json").read_text())
        self.write(res / "exit.json", json.dumps(dict(info, finished="2100-01-01T00:00:00+00:00")))
        self.write(res / "changes.diff", "diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml\nnew file mode 100644\n"
                                         "--- /dev/null\n+++ b/.github/workflows/ci.yml\n@@ -0,0 +1 @@\n+on: push\n")
        self.assertIn(".github", pub.allowed(j, "draft_pr", auto=True) or "")
        self.assertEqual(serve.tick(time.time()), [])
        self.assertIn("--allow-workflows", pub.allowed(j, "draft_pr", auto=False) or "")
        self.assertIsNone(pub.allowed(j, "draft_pr", auto=False, allow_workflows=True))
        self.assertEqual(set(self.remote_refs()), {"refs/heads/main"})

    def test_a_paused_queue_publishes_nothing(self) -> None:
        self.cli("publish-to", str(self.repo), "--mode", "auto", "--comment")
        j = self.job()
        info = json.loads((jobs.job_dir(j.id) / "result" / "exit.json").read_text())
        self.write(jobs.job_dir(j.id) / "result" / "exit.json", json.dumps(dict(info, finished="2100-01-01T00:00:00+00:00")))
        self.pueue_status({}, group="Paused")
        self.assertEqual(serve.tick(time.time()), [])
        self.assertEqual(self.gh_calls(), [])


@unittest.skipUnless(HAVE_SVN, "svn/svnadmin not installed")
class ReviewFindingsSvn(PublishSvn):
    def real_job(self, sub: str) -> jobs.Job:
        """A job based on <root>/<sub>, with the diff the executor itself collects."""
        from wslib import agent_exec as ax
        j = jobs.Job(id=jobs.new_id(), title="change b", repo="~/src/svnwc", vcs="svn",
                     base={"url": f"{self.url}/{sub}", "repos_root": self.url, "rev": "1"}, prompt_sha=f"s{time.time_ns()}",
                     paths=[], created=core.now_iso(), session_id="", timeout="2h")
        jobs.save(j)
        jd = jobs.job_dir(j.id)
        svn("checkout", "-q", f"{self.url}/{sub}@1", str(jd / "wc"))
        target = next(p for p in (jd / "wc").rglob("*.txt"))
        target.write_text("changed by the job\n")
        ax.collect(j, jd)
        self.write(jd / "result" / "exit.json", json.dumps({"exit_code": 0, "status": "done", "kind": "ok", "checks": "pass"}))
        self.rel = str(target.relative_to(jd / "wc"))
        return j

    def test_the_branch_holds_the_jobs_change_in_one_revision_at_any_depth(self) -> None:
        reg.set_publish(self.wc, reg.Publish(mode="manual", svn_branch="^/branches/ws-agent"))
        for sub in ("trunk", "trunk/sub"):
            j = self.real_job(sub)
            before = int(svn("info", "--show-item", "revision", self.url))
            lines = pub.publish(j, auto=False)
            self.assertRegex(lines[0], rf"published svn_branch: .*/branches/ws-agent/{j.id}@{before + 1}$", sub)
            self.assertEqual(svn("cat", f"{self.url}/branches/ws-agent/{j.id}/{self.rel}"), "changed by the job", sub)
            self.assertEqual(int(svn("info", "--show-item", "revision", self.url)), before + 1)   # one revision

    def test_a_patch_that_doesnt_apply_leaves_nothing_on_the_server(self) -> None:
        reg.set_publish(self.wc, reg.Publish(mode="manual", svn_branch="^/branches/ws-agent"))
        j = self.job()
        self.write(jobs.job_dir(j.id) / "result" / "changes.diff",
                   "Index: nope.txt\n--- a/trunk/nope.txt\t(revision 1)\n+++ b/trunk/nope.txt\t(working copy)\n@@ -1 +1 @@\n-x\n+y\n")
        lines = pub.publish(j, auto=False)
        self.assertIn("failed", lines[0])
        self.assertEqual(svn("info", "--show-item", "revision", self.url), "1")
        self.assertFalse(pub.published(j, "svn_branch"))

    def test_the_branch_parent_is_never_trunk_or_a_watched_tree(self) -> None:
        for bad in ("^/./trunk", "^/trunk/agents", "^//branches", "^/branches/./x", "^/trunk"):
            with self.assertRaises(ValueError, msg=bad):
                reg.set_publish(self.wc, reg.Publish(mode="manual", svn_branch=bad))
        reg.set_watch(self.wc, reg.Watch(urls=("^/branches/rel",)))
        for bad in ("^/branches/rel/agents", "^/branches"):
            with self.assertRaises(ValueError, msg=bad):
                reg.set_publish(self.wc, reg.Publish(mode="manual", svn_branch=bad))
        reg.set_publish(self.wc, reg.Publish(mode="manual", svn_branch="^/agents"))
        p = reg.registry_path()   # a hand edit doesn't get past publish either
        p.write_text(p.read_text().replace('svn_branch = "^/agents"', 'svn_branch = "^/./trunk"'))
        j = self.job()
        self.assertIn("not published", pub.publish(j, auto=False)[0])
        self.assertEqual(svn("info", "--show-item", "revision", self.url), "1")


# The review classes reuse the fixtures of the classes above, not their tests.
for _cls, _base in ((ReviewFindings, Publish), (ReviewFindingsSvn, PublishSvn)):
    for _name in [n for n in vars(_base) if n.startswith("test_")]:
        setattr(_cls, _name, None)


if __name__ == "__main__":
    unittest.main()


class DeferredMinors(Publish):
    """The minor findings of the whole-branch review of publish."""

    def set_exit(self, j: jobs.Job, **kw: object) -> None:
        f = jobs.job_dir(j.id) / "result" / "exit.json"
        f.write_text(json.dumps({**json.loads(f.read_text()), **kw}))

    def test_the_daily_cap_counts_jobs_and_never_blocks_a_jobs_own_second_kind(self) -> None:
        self.settings(mode="auto", comment=True, draft_pr=True)
        now = {"at": core.now_iso(), "auto": True}
        for _ in range(pub.AUTO_CAP - 1):   # four jobs, eight writes: still under a cap of five jobs
            done = self.job()
            pub._save(done, "comment", {"url": "u", **now})
            pub._save(done, "draft_pr", {"url": "u", **now})
        self.assertIsNone(pub.allowed(self.job(), "comment", auto=True))
        half = self.job()
        pub._save(half, "draft_pr", {"url": "u", **now})   # the fifth job today: its comment is still owed
        self.assertIsNone(pub.allowed(half, "comment", auto=True))
        self.assertIn("daily cap", pub.allowed(self.job(), "comment", auto=True) or "")

    def test_a_request_on_a_pull_request_targets_its_branch_or_nothing(self) -> None:
        self.settings(mode="manual", draft_pr=True)
        git("push", "-q", "origin", f"{self.head}:refs/heads/feature", cwd=self.repo)
        j = self.job()
        j.base = {"commit": self.head, "branch": "pull/5/head"}
        jobs.save(j)
        self.write(self.gx / "pulls-fail", "")   # GitHub can't say which branch: never the default one instead
        line = pub.publish(j, auto=False)[0]
        self.assertIn("draft_pr failed", line)
        self.assertEqual(set(self.remote_refs()), {"refs/heads/main", "refs/heads/feature"})
        (self.gx / "pulls-fail").unlink()
        self.write(self.gx / "pulls-ref", "feature\n")   # a pull request from the same repository
        self.assertIn("published draft_pr", pub.publish(j, auto=False)[0])
        create = next(c for c in self.gh_calls() if c[:2] == ["pr", "create"])
        self.assertEqual(create[create.index("--base") + 1], "feature")

    def test_the_person_is_told_once_when_serve_gives_up(self) -> None:
        self.settings(mode="auto", draft_pr=True, comment=True)
        self.write(self.gx / "pr-fails", "")
        self.write(self.gx / "post-then-fail", "")
        j = self.job()
        notices: list[str] = []
        with unittest.mock.patch.object(agent_events, "notify", side_effect=notices.append):
            for _ in range(pub.MAX_TRIES + 2):
                serve.tick(time.time())
        self.assertEqual(sorted(notices), [f"{j.id}: comment wasn't published automatically (ws-agent publish {j.id})",
                                           f"{j.id}: draft_pr wasn't published automatically (ws-agent publish {j.id})"])

    def test_a_failure_by_hand_doesnt_use_up_serves_tries(self) -> None:
        self.settings(mode="auto", draft_pr=True)
        self.write(self.gx / "pr-fails", "")
        j = self.job()
        for _ in range(pub.MAX_TRIES + 1):
            self.assertIn("draft_pr failed", pub.publish(j, auto=False)[0])
        self.assertIsNone(pub.allowed(j, "draft_pr", auto=True))

    def test_a_damaged_try_count_reads_as_none(self) -> None:
        self.settings(mode="auto", comment=True)
        j = self.job()
        pub._save(j, "comment", {"tries": "many"})
        self.assertIsNone(pub.allowed(j, "comment", auto=True))

    def test_the_persons_pre_push_hook_still_decides(self) -> None:
        self.settings(mode="manual", draft_pr=True)
        hook = self.repo / ".git" / "hooks" / "pre-push"
        self.write(hook, "#!/bin/sh\necho 'the hook says no' >&2\nexit 1\n")
        hook.chmod(0o755)
        j = self.job()
        self.assertIn("draft_pr failed", pub.publish(j, auto=False)[0])
        self.assertEqual(set(self.remote_refs()), {"refs/heads/main"})

    def test_a_reviewers_concerns_leave_it_to_the_person_and_show_in_the_comment(self) -> None:
        self.settings(mode="auto", comment=True)
        j = self.job()
        self.set_exit(j, review="concerns")
        self.assertIn("reviewer had concerns", pub.allowed(j, "comment", auto=True) or "")
        self.assertEqual(serve.tick(time.time()), [])
        self.assertIn("published comment", pub.publish(j, auto=False)[0])
        body = json.loads(next(self.gx.glob("body.*")).read_text())["body"]
        self.assertIn("Review: concerns.", outside_fences(body))
        fine = self.job()
        self.set_exit(fine, review="ok")
        self.assertIsNone(pub.allowed(fine, "comment", auto=True))

    def test_only_a_job_that_succeeded_and_is_still_open_is_published(self) -> None:
        self.settings(mode="manual", comment=True, draft_pr=True)
        failed, asks, closed, cancelled = self.job(), self.job(), self.job(), self.job()
        self.set_exit(failed, exit_code=1, status="failed")
        self.set_exit(asks, status="question")
        closed.closed = True
        jobs.save(closed)
        cancelled.cancelled = True
        jobs.save(cancelled)
        for j in (failed, asks, closed, cancelled):
            lines = pub.publish(j, auto=False)
            self.assertTrue(lines and all("hasn't succeeded" in ln for ln in lines), lines)
        self.assertEqual((self.gh_calls(), set(self.remote_refs())), ([], {"refs/heads/main"}))


class DeferredMinorsSvn(PublishSvn):
    def test_auto_with_only_an_svn_branch_says_it_stays_by_hand(self) -> None:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err), chdir(self.root):
            rc = agent.main(["publish-to", str(self.wc), "--mode", "auto", "--svn-branch", "^/branches/ws-agent"])
        self.assertEqual(rc, 0, err.getvalue())
        self.assertNotIn("without asking per job", err.getvalue())
        self.assertIn("never published automatically", err.getvalue())

    def test_a_commit_the_server_refuses_is_not_recorded(self) -> None:
        reg.set_publish(self.wc, reg.Publish(mode="manual", svn_branch="^/branches/ws-agent"))
        hook = self.root / "svnrepo" / "hooks" / "pre-commit"
        self.write(hook, "#!/bin/sh\necho 'the server says no' >&2\nexit 1\n")
        hook.chmod(0o755)
        j = self.job()
        self.assertIn("svn_branch failed", pub.publish(j, auto=False)[0])
        self.assertEqual((pub.published(j, "svn_branch"), svn("info", "--show-item", "revision", self.url)), ("", "1"))
        self.assertFalse((jobs.job_dir(j.id) / "publish-wc").exists())
        hook.unlink()
        self.assertIn("published svn_branch", pub.publish(j, auto=False)[0])   # and it can be tried again

