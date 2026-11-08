"""wslib.agent_sources: what serve polls for work. An SVN watch turns each new revision on a
watched URL into a candidate (read with the person's own svn config; nothing is written to the
server), starting at HEAD when the watch is made, so there is no backlog."""

from __future__ import annotations

import time
import unittest

from agent_helpers import HAVE_SVN, AgentScratch, svn

from wslib import agent_sources as src
from wslib import agent_registry as reg


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


if __name__ == "__main__":
    unittest.main()
