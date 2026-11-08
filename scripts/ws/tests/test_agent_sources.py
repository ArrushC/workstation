"""wslib.agent_sources: what serve polls for work. An SVN watch turns each new revision on a
watched URL into a candidate (read with the person's own svn config; nothing is written to the
server), starting at HEAD when the watch is made, so there is no backlog. A GitHub source takes
`/agent` comments by listed logins as requests, sends later ones on the same issue to its open
job, and posts nothing back."""

from __future__ import annotations

import datetime as dt
import json
import os
import shutil
import time
import unittest

from agent_helpers import FAKE_GH, HAVE_SVN, AgentScratch, git, svn
from helpers import WS

from wslib import agent_sources as src
from wslib import agent_registry as reg
from wslib import core, jobs

FIXTURES = WS / "tests" / "fixtures"
SLUG = "ArrushC/proj"


@unittest.skipUnless(HAVE_SVN, "svn/svnadmin not installed")
class SvnWatch(AgentScratch):
    def setUp(self) -> None:
        super().setUp()
        self.url, self.wc = self.svn_repo()
        self.commit("sub/b.txt", "b1\n", "before the watch: one")
        self.commit("a.txt", "a1\n", "before the watch: two")
        self.uuid = svn("info", "--show-item", "repos-uuid", self.url)

    def commit(self, rel: str, text: str, msg: str, *, user: str = "") -> int:
        p = self.wc / rel
        new = not p.exists()
        self.write(p, text)
        if new:
            svn("add", "-q", "--parents", str(p), cwd=self.wc)
        svn("commit", "-q", "-m", msg, *(["--username", user] if user else []), cwd=self.wc)
        svn("update", "-q", cwd=self.wc)
        return int(svn("info", "--show-item", "revision", self.url))

    def entry(self, **kw: object) -> reg.Repo:
        return reg.Repo(path=self.wc, vcs="svn", watch=reg.Watch(urls=("^/trunk",), **kw))  # type: ignore[arg-type]

    def head(self) -> int:
        return int(svn("info", "--show-item", "revision", self.url))

    def cursor(self) -> object:
        return src.source_state()["svn:~/src/svnwc:^/trunk"]["cursor"]

    def test_watch_starts_at_head(self) -> None:
        e = self.entry()
        src.start_watch(e)
        self.assertEqual(self.cursor(), self.head())
        self.assertEqual(src.poll_svn(e, time.time()), [])
        src.start_watch(e)   # again (a changed setting): the cursor stays
        self.assertEqual(self.cursor(), self.head())

    def test_poll_finds_new_revisions(self) -> None:
        e = self.entry(rules=("API changes",))
        src.start_watch(e)
        r1 = self.commit("sub/b.txt", "b2\n", "fix the parser\n\nlonger text")
        r2 = self.commit("other/deep/c.txt", "c\n", "add c")
        self.write(self.root / "br" / "x.txt", "x")
        svn("import", "-q", str(self.root / "br"), f"{self.url}/branches/x", "-m", "a branch: not watched")
        found = src.poll_svn(e, time.time())
        self.assertEqual([c.cid for c in found], [f"svn:{self.uuid}:{r1}", f"svn:{self.uuid}:{r2}"])
        c = found[0]
        self.assertEqual((c.source, c.repo, c.explicit, c.thread), ("svn", "~/src/svnwc", False, ""))
        self.assertTrue(c.author)
        self.assertEqual(c.title, f"r{r1} by {c.author}: fix the parser")
        self.assertIn("longer text", c.text)
        self.assertIn("M /trunk/sub/b.txt", c.text)
        self.assertEqual(c.base, {"url": f"{self.url}/trunk", "repos_root": self.url, "rev": str(r1),
                                  "review_rev": str(r1), "sparse": "sub"})
        self.assertEqual(found[1].base["sparse"], "other")   # the new directory, whole
        self.assertIn(f"Review r{r1} by {c.author} against this rule: API changes", c.prompt)
        self.assertIn(f"r{r1}.diff", c.prompt)
        self.assertEqual(self.cursor(), self.head())
        self.assertEqual(src.poll_svn(e, time.time() + 3600), [])   # each revision once

    def test_sparse_dirs(self) -> None:
        paths = [("M", "file", "/trunk/sub/x/a.c"), ("M", "file", "/trunk/sub/b.c"), ("A", "dir", "/trunk/new"),
                 ("D", "dir", "/trunk/old/gone"), ("M", "file", "/trunk/top.txt"), ("M", "file", "/branches/y/z.c")]
        self.assertEqual(src.sparse_dirs(paths, "/trunk"), [".", "new", "old", "sub"])
        self.assertEqual(src.sparse_dirs([("M", "file", "/elsewhere/a")], "/trunk"), ["."])

    def test_authors_filter(self) -> None:
        e = self.entry(authors=("bob",))
        src.start_watch(e)
        mine = self.commit("a.txt", "a2\n", "not bob's")
        bobs = self.commit("a.txt", "a3\n", "bob's", user="bob")
        found = src.poll_svn(e, time.time())
        self.assertEqual([c.cid for c in found], [f"svn:{self.uuid}:{bobs}"])
        self.assertEqual(found[0].author, "bob")
        self.assertNotEqual(mine, bobs)

    def test_interval_respected(self) -> None:
        e = self.entry(interval="5m")
        src.start_watch(e)
        t = time.time()
        self.commit("a.txt", "a2\n", "one")
        self.assertEqual(len(src.poll_svn(e, t)), 1)
        self.commit("a.txt", "a3\n", "two")
        self.assertEqual(src.poll_svn(e, t + 10), [])     # not due yet
        self.assertEqual(len(src.poll_svn(e, t + 301)), 1)
        self.assertEqual(src.poll_svn(reg.Repo(path=self.wc, vcs="svn"), t + 9999), [])   # no watch
        self.assertEqual(src.poll_svn(self.entry(mode="off"), t + 9999), [])

    def test_no_new_revisions_is_quiet(self) -> None:
        e = self.entry()
        src.start_watch(e)
        head = self.head()
        t = time.time()
        self.assertEqual(src.poll_svn(e, t), [])
        self.assertEqual(src.poll_svn(e, t + 400), [])
        self.assertEqual(self.cursor(), head)

    def test_a_watch_never_started_starts_at_head(self) -> None:
        e = self.entry()
        self.commit("a.txt", "a2\n", "before anything")
        self.assertEqual(src.poll_svn(e, time.time()), [])   # no cursor yet: begin at HEAD, no backlog
        self.assertEqual(self.cursor(), self.head())

    def test_an_unreachable_url_raises_and_waits_for_the_interval(self) -> None:
        e = reg.Repo(path=self.wc, vcs="svn", watch=reg.Watch(urls=(f"{self.url}/nope",)))
        t = time.time()
        with self.assertRaises(src.SourceError):
            src.poll_svn(e, t)
        self.assertEqual(src.poll_svn(e, t + 10), [])   # no retry before the interval

    def test_forget(self) -> None:
        e = self.entry()
        src.start_watch(e)
        src.forget_sources("svn:~/src/svnwc:")
        self.assertNotIn("svn:~/src/svnwc:^/trunk", src.source_state())


def iso(t: float) -> str:
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class GitHub(AgentScratch):
    """FAKE_GH answers from the captured fixtures (edited per test); `origin` is a local bare
    repository, so the base really is fetched."""

    def setUp(self) -> None:
        super().setUp()
        self.gx = self.root / "fake-gh"
        self.gx.mkdir()
        os.environ["WS_FAKE_GH"] = str(self.gx)
        self.fake("gh", FAKE_GH)
        self.repo = self.git_repo()
        origin = self.root / "origin.git"
        git("init", "-q", "--bare", str(origin), cwd=self.root)
        git("remote", "add", "origin", str(origin), cwd=self.repo)
        git("push", "-q", "origin", "main", cwd=self.repo)
        git("fetch", "-q", "origin", cwd=self.repo)
        self.tracking = git("rev-parse", "refs/remotes/origin/main", cwd=self.repo)
        # origin moves on: a commit on main and a pull request head the local copy has never fetched
        other = self.root / "other"
        git("clone", "-q", str(origin), str(other), cwd=self.root)
        self.write(other / "app.py", "def f():\n    return 2\n")
        git("commit", "-qam", "two", cwd=other)
        git("push", "-q", "origin", "main", cwd=other)
        self.origin_main = git("rev-parse", "HEAD", cwd=other)
        self.write(other / "app.py", "def f():\n    return 3\n")
        git("commit", "-qam", "the PR", cwd=other)
        git("push", "-q", "origin", "HEAD:refs/pull/7/head", cwd=other)
        self.pr_head = git("rev-parse", "HEAD", cwd=other)
        self.entry = reg.Repo(path=self.repo, vcs="git",
                              github=reg.GitHubSource(slug=SLUG, mode="observe", logins=("ArrushC",)))
        self.t0 = time.time()
        src.start_github(self.entry)
        self.answer("", {"default_branch": "main"})
        self.answer("issues", [])
        issue = json.loads((FIXTURES / "gh-issue.json").read_text())
        issue.pop("pull_request", None)
        self.answer("issues/7", dict(issue, number=7, title="The parser drops comments", body="It loses # lines."))
        self.comment()

    def answer(self, endpoint: str, data: object) -> None:
        name = "repos_" + SLUG.replace("/", "_") + ("_" + endpoint.replace("/", "_") if endpoint else "")
        self.write(self.gx / f"{name}.json", json.dumps(data))

    def comment(self, body: str = "/agent fix the parser\nkeep the API", login: str = "ArrushC", cid: int = 901,
                number: int = 7, *, at: float | None = None) -> dict[str, object]:
        c = json.loads((FIXTURES / "gh-issue-comments.json").read_text())[0]
        c.update(id=cid, body=body, user={"login": login}, created_at=iso(at or self.t0 + 5),
                 updated_at=iso(at or self.t0 + 5),
                 issue_url=f"https://api.github.com/repos/{SLUG}/issues/{number}",
                 html_url=f"https://github.com/{SLUG}/issues/{number}#issuecomment-{cid}")
        self.answer("issues/comments", [c])
        self.answer(f"issues/{number}/comments", [c])
        return c

    def gh_calls(self) -> list[list[str]]:
        log = self.gx / "argv.log"
        return [ln.split("\x1f") for ln in log.read_text().splitlines()] if log.exists() else []

    def test_agent_comment_by_a_listed_login_is_a_request(self) -> None:
        cands, follow = src.poll_github(self.entry, self.t0 + 1)
        self.assertEqual(follow, [])
        self.assertEqual(len(cands), 1)
        c = cands[0]
        self.assertEqual((c.cid, c.thread, c.source, c.explicit, c.author, c.repo),
                         (f"gh:{SLUG}:c901", f"gh:{SLUG}#7", "github", True, "ArrushC", "~/src/proj"))
        self.assertEqual(c.base, {"commit": self.origin_main, "branch": "main"})
        self.assertIn("fix the parser", c.title)
        self.assertEqual(c.url, f"https://github.com/{SLUG}/issues/7#issuecomment-901")
        before, _, quoted = c.prompt.partition("<untrusted>")
        self.assertIn("fix the parser\nkeep the API", before)
        self.assertIn("The parser drops comments", quoted)
        self.assertIn("It loses # lines.", quoted)
        self.assertIn("nothing you write is posted back", c.prompt)
        self.assertEqual(src.source_state()[f"gh:{SLUG}"]["cursor"], iso(self.t0 + 5))
        self.assertEqual(src.poll_github(self.entry, self.t0 + 100), ([], []))   # once

    def test_new_issue_body_is_a_request(self) -> None:
        self.answer("issues/comments", [])
        issue = json.loads((FIXTURES / "gh-issue.json").read_text())
        issue.pop("pull_request", None)
        issue.update(number=9, title="Add a test", body="/agent add a test for f", user={"login": "arrushc"},
                     created_at=iso(self.t0 + 3), updated_at=iso(self.t0 + 3))
        old = dict(issue, number=3, body="/agent from before", created_at=iso(self.t0 - 999))   # updated, not new
        self.answer("issues", [old, issue])
        self.answer("issues/9/comments", [])
        cands, _ = src.poll_github(self.entry, self.t0 + 1)
        self.assertEqual([c.cid for c in cands], [f"gh:{SLUG}:i9"])
        self.assertEqual(cands[0].thread, f"gh:{SLUG}#9")

    def test_outsider_comment_ignored(self) -> None:
        self.comment(login="someone-else")
        self.assertEqual(src.poll_github(self.entry, self.t0 + 1), ([], []))
        for i, body in enumerate(("please /agent fix it", "/agentfix it", "fix it")):
            self.comment(body=body, cid=950 + i)
            self.assertEqual(src.poll_github(self.entry, self.t0 + 100 * (i + 1)), ([], []), body)

    def test_followup_goes_to_the_open_job(self) -> None:
        job = jobs.Job(id=jobs.new_id(), title="t", repo="~/src/proj", vcs="git", base={}, prompt_sha="x", paths=[],
                       created=core.now_iso(), session_id="", timeout="2h", origin=f"gh:{SLUG}:c800")
        jobs.save(job)
        src.remember_thread(f"gh:{SLUG}#7", job.id)
        self.assertEqual(src.poll_github(self.entry, self.t0 + 1), ([], [(job.id, "fix the parser\nkeep the API")]))
        job.closed = True
        jobs.save(job)
        self.comment(body="/agent and the docs", cid=902)
        cands, follow = src.poll_github(self.entry, self.t0 + 100)
        self.assertEqual((follow, [c.cid for c in cands]), ([], [f"gh:{SLUG}:c902"]))   # a closed job: a new request

    def test_pr_comment_fetches_the_pr_head(self) -> None:
        issue = json.loads((FIXTURES / "gh-issue.json").read_text())
        self.assertIn("pull_request", issue)   # the captured #55 is a pull request
        self.answer("issues/7", dict(issue, number=7))
        cands, _ = src.poll_github(self.entry, self.t0 + 1)
        self.assertEqual(cands[0].base, {"commit": self.pr_head, "branch": "pull/7/head"})
        self.assertIn("pull request", cands[0].prompt)

    def test_poll_interval_honoured(self) -> None:
        self.write(self.gx / "poll-interval", "300")
        src.poll_github(self.entry, self.t0 + 1)
        n = len(self.gh_calls())
        self.assertEqual(src.poll_github(self.entry, self.t0 + 200), ([], []))
        self.assertEqual(len(self.gh_calls()), n)   # not asked before 300 s
        src.poll_github(self.entry, self.t0 + 302)
        self.assertGreater(len(self.gh_calls()), n)

    def test_a_failed_request_is_retried(self) -> None:
        (self.gx / f"repos_{SLUG.replace('/', '_')}.json").unlink()   # the default branch can't be read
        with self.assertRaises(src.SourceError):
            src.poll_github(self.entry, self.t0 + 1)
        self.answer("", {"default_branch": "main"})
        cands, _ = src.poll_github(self.entry, self.t0 + 100)
        self.assertEqual([c.cid for c in cands], [f"gh:{SLUG}:c901"])

    def test_github_never_writes(self) -> None:
        real = shutil.which("git")
        assert real is not None
        self.fake("git", f'printf \'%s\\n\' "$*" >>"{self.gx}/git.log"\nexec {real} "$@"')
        cands, _ = src.poll_github(self.entry, self.t0 + 1)
        self.assertEqual(len(cands), 1)
        for argv in self.gh_calls():
            self.assertEqual(argv[0], "api")
            for bad in ("-X", "--method", "-f", "-F", "--field", "--raw-field", "--input", "POST", "PATCH", "PUT",
                        "DELETE"):
                self.assertNotIn(bad, argv)
        prefix = f"-C {self.repo} "   # git -C <repo> <sub> ... (the scratch path may hold spaces)
        lines = (self.gx / "git.log").read_text().splitlines()
        self.assertTrue(lines and all(ln.startswith(prefix) for ln in lines), lines)
        subs = [ln[len(prefix):].split()[0] for ln in lines]
        self.assertTrue(set(subs) <= {"fetch", "rev-parse", "remote"}, subs)
        self.assertEqual(git("rev-parse", "refs/remotes/origin/main", cwd=self.repo), self.tracking)   # untouched
        self.assertNotEqual(self.tracking, self.origin_main)

    def test_start_and_off(self) -> None:
        cursor = src.source_state()[f"gh:{SLUG}"]["cursor"]
        self.assertIn(cursor, {iso(self.t0 - 1), iso(self.t0), iso(self.t0 + 1)})   # now, to the second
        src.start_github(self.entry)   # again: the cursor stays
        self.assertEqual(src.source_state()[f"gh:{SLUG}"]["cursor"], cursor)
        off = reg.Repo(path=self.repo, vcs="git", github=reg.GitHubSource(slug=SLUG, mode="off", logins=("ArrushC",)))
        self.assertEqual(src.poll_github(off, self.t0 + 1), ([], []))
        self.assertEqual(self.gh_calls(), [])


if __name__ == "__main__":
    unittest.main()
