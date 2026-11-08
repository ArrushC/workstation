"""wslib.vcs: what kind of working copy a directory is in, and its base (git or SVN)."""

from __future__ import annotations

import shutil
import subprocess
import unittest
from pathlib import Path

from helpers import Scratch

from wslib import vcs

HAVE_SVN = bool(shutil.which("svn") and shutil.which("svnadmin"))


def git(*args: str, cwd: Path) -> str:
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "init.defaultBranch=main",
                           *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def svn(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(["svn", "--non-interactive", *args], cwd=cwd, check=True, capture_output=True,
                          text=True).stdout.strip()


class SvnRepo(Scratch):
    """A file:// repository holding trunk/{a.txt, sub/b.txt} and branches/, and a checkout of trunk at r1."""

    def make_svn(self) -> tuple[str, Path]:
        repo = self.root / "repo"
        subprocess.run(["svnadmin", "create", str(repo)], check=True)
        url = repo.as_uri()
        seed = self.root / "seed"
        self.write(seed / "trunk" / "a.txt", "a\n")
        self.write(seed / "trunk" / "sub" / "b.txt", "b\n")
        (seed / "branches").mkdir()
        svn("import", str(seed), url, "-m", "seed")
        wc = self.root / "wc"
        svn("checkout", f"{url}/trunk", str(wc))
        return url, wc


class Probe(SvnRepo):
    def test_none(self) -> None:
        d = self.root / "plain"
        d.mkdir()
        p = vcs.probe(d)
        self.assertEqual(p.kind, "none")
        self.assertIsNone(p.root)

    def test_git_github(self) -> None:
        r = self.root / "g"
        r.mkdir()
        git("init", "-q", cwd=r)
        self.write(r / "f.txt", "x\n")
        git("add", "f.txt", cwd=r)
        git("commit", "-qm", "one", cwd=r)
        git("remote", "add", "origin", "git@github.com:ArrushC/demo.git", cwd=r)
        (r / "deep" / "er").mkdir(parents=True)
        p = vcs.probe(r / "deep" / "er")
        self.assertEqual(p.kind, "git")
        self.assertEqual(p.root, r)
        self.assertEqual(p.github, "ArrushC/demo")
        self.assertEqual(p.rev, git("rev-parse", "HEAD", cwd=r))
        self.assertEqual(len(p.rev), 40)
        self.assertEqual(p.branch, "main")

    def test_github_slug_forms(self) -> None:
        for url, want in (("https://github.com/ArrushC/demo.git", "ArrushC/demo"),
                          ("https://github.com/ArrushC/demo", "ArrushC/demo"),
                          ("ssh://git@github.com/ArrushC/demo.git", "ArrushC/demo"),
                          ("git@gitlab.com:ArrushC/demo.git", ""),
                          ("", "")):
            self.assertEqual(vcs.github_slug(url), want, url)

    def test_git_dirty_only_thorough(self) -> None:
        r = self.root / "g"
        r.mkdir()
        git("init", "-q", cwd=r)
        self.write(r / "f.txt", "x\n")
        git("add", "f.txt", cwd=r)
        git("commit", "-qm", "one", cwd=r)
        self.write(r / "f.txt", "y\n")
        self.assertFalse(vcs.probe(r).modified)
        self.assertTrue(vcs.probe(r, thorough=True).modified)

    def test_git_no_commits(self) -> None:
        r = self.root / "g"
        r.mkdir()
        git("init", "-q", cwd=r)
        p = vcs.probe(r)
        self.assertEqual(p.kind, "git")
        self.assertEqual(p.rev, "")


@unittest.skipUnless(HAVE_SVN, "svn/svnadmin not installed")
class ProbeSvn(SvnRepo):
    def test_svn_basic(self) -> None:
        url, wc = self.make_svn()
        p = vcs.probe(wc / "sub")
        self.assertEqual(p.kind, "svn")
        self.assertEqual(p.root, wc)
        self.assertEqual(p.url, f"{url}/trunk")
        self.assertEqual(p.repos_root, url)
        self.assertEqual(p.rev, "1")
        self.assertEqual(vcs.short_url(p), "^/trunk")
        self.assertEqual(p.version, "")   # not thorough: svnversion never ran

    def test_svn_clean_thorough(self) -> None:
        _, wc = self.make_svn()
        p = vcs.probe(wc, thorough=True)
        self.assertEqual(p.version, "1")
        self.assertFalse(p.mixed or p.switched or p.modified)

    def test_svn_modified(self) -> None:
        _, wc = self.make_svn()
        self.write(wc / "a.txt", "changed\n")
        p = vcs.probe(wc, thorough=True)
        self.assertTrue(p.modified)
        self.assertFalse(p.mixed)

    def test_svn_mixed(self) -> None:
        _, wc = self.make_svn()
        self.write(wc / "a.txt", "r2\n")
        svn("commit", "-m", "r2", cwd=wc)   # a.txt is now at r2, the rest at r1
        p = vcs.probe(wc, thorough=True)
        self.assertTrue(p.mixed)
        self.assertIn(":", p.version)

    def test_svn_switched(self) -> None:
        url, wc = self.make_svn()
        svn("copy", f"{url}/trunk", f"{url}/branches/b", "-m", "branch")
        svn("switch", f"{url}/branches/b/sub", str(wc / "sub"))
        p = vcs.probe(wc, thorough=True)
        self.assertTrue(p.switched)

    def test_nearest_wins(self) -> None:
        _, wc = self.make_svn()
        outer = self.root
        git("init", "-q", cwd=outer)   # a git repository around the SVN working copy
        self.assertEqual(vcs.probe(wc / "sub").kind, "svn")
        (outer / "elsewhere").mkdir()
        self.assertEqual(vcs.probe(outer / "elsewhere").kind, "git")


if __name__ == "__main__":
    unittest.main()
