"""What kind of working copy a directory is in (git or SVN) and the base a job starts from.

The fast probe (`thorough=False`) is what the SessionStart hook runs in every session, so it
starts no process at all outside a working copy and never crawls one: `svn info --xml` reads
the working copy's database, `git rev-parse` reads HEAD. `thorough=True` (`ws agent run`) adds
`svnversion` / `git status`, which walk the whole tree, to find mixed revisions, switched
subtrees and local modifications.
"""

from __future__ import annotations

import re
import subprocess
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

_GITHUB = re.compile(r"github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$")


@dataclass(frozen=True)
class Probe:
    kind: str                 # "svn" | "git" | "none"
    root: Path | None = None  # the working copy root / worktree top level
    url: str = ""             # svn: the root's URL; git: remote.origin.url
    repos_root: str = ""      # svn: the repository root URL
    rev: str = ""             # svn: the root's BASE revision; git: HEAD's sha ("" before the first commit)
    version: str = ""         # svn: svnversion's output (thorough only)
    mixed: bool = False       # svn: several revisions in the working copy
    switched: bool = False    # svn: a subtree switched to another URL
    modified: bool = False    # local changes to versioned files (thorough only)
    branch: str = ""          # git: the checked-out branch ("HEAD" when detached)
    github: str = ""          # "owner/name" when the git origin is on github.com


def _run(argv: list[str], cwd: Path | None = None) -> str | None:
    try:
        r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 else None


def _marker(path: Path) -> tuple[str, Path] | None:
    """The nearest directory at or above `path` holding .svn or .git (a file for linked worktrees)."""
    d = path.resolve()
    for cand in (d, *d.parents):
        if (cand / ".svn").is_dir():
            return "svn", cand
        if (cand / ".git").exists():
            return "git", cand
    return None


def github_slug(url: str) -> str:
    m = _GITHUB.search(url.strip())
    return f"{m.group(1)}/{m.group(2)}" if m else ""


def short_url(p: Probe) -> str:
    """SVN's ^/ form of the URL (^/trunk); other kinds return the URL unchanged."""
    if p.kind == "svn" and p.repos_root and p.url.startswith(p.repos_root):
        return "^/" + p.url[len(p.repos_root):].strip("/")
    return p.url


def probe(path: Path, *, thorough: bool = False) -> Probe:
    found = _marker(path)
    if not found:
        return Probe("none")
    kind, top = found
    return _svn(top, thorough) if kind == "svn" else _git(top, thorough)


def _svn(top: Path, thorough: bool) -> Probe:
    out = _run(["svn", "info", "--xml", "--non-interactive", str(top)])
    if out is None:
        return Probe("svn", top)
    try:
        entry = ET.fromstring(out).find("entry")
    except ET.ParseError:
        return Probe("svn", top)
    if entry is None:
        return Probe("svn", top)
    wcroot = entry.findtext("wc-info/wcroot-abspath") or str(top)
    root = Path(wcroot)
    if root != top:   # `top` was a nested directory of the copy; ask about the root itself
        return _svn(root, thorough)
    url = entry.findtext("url") or ""
    repos_root = entry.findtext("repository/root") or ""
    rev = entry.get("revision", "")
    if not thorough:
        return Probe("svn", root, url, repos_root, rev)
    version = (_run(["svnversion", str(root)]) or "").strip()
    return Probe("svn", root, url, repos_root, rev, version, mixed=":" in version, switched="S" in version,
                 modified="M" in version)


def _git(top: Path, thorough: bool) -> Probe:
    head = (_run(["git", "-C", str(top), "rev-parse", "--verify", "-q", "HEAD"]) or "").strip()
    branch = (_run(["git", "-C", str(top), "rev-parse", "--abbrev-ref", "HEAD"]) or "").strip()
    url = (_run(["git", "-C", str(top), "config", "--get", "remote.origin.url"]) or "").strip()
    modified = False
    if thorough:
        status = _run(["git", "-C", str(top), "status", "--porcelain", "--untracked-files=no"])
        modified = bool(status and status.strip())
    return Probe("git", top, url=url, rev=head, modified=modified, branch=branch, github=github_slug(url))
