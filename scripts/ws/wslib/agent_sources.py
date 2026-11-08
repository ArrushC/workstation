"""Sources: what serve polls for work. An SVN watch turns each new revision on a watched URL
into a candidate (an inferred one: it goes through triage); a GitHub source takes `/agent`
requests (explicit ones).

Polls read with the person's own credentials and never write to a server. Their state is
<state>/agent-serve/sources.json, one entry per source:
- "svn:<repo key>:<url as configured>": {cursor, last_poll, url, root, uuid[, last_error]}
- "gh:<slug>": {cursor, last_poll, interval, threads: {"#<n>": job id}}
Each writer changes only its own entry, under a lock, so serve and `ws-agent watch` never undo
each other. A watch with no cursor (never started, or forgotten) starts at HEAD: no backlog.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import re
import subprocess
import urllib.parse
import xml.etree.ElementTree as ET
from collections.abc import Iterator
from pathlib import Path

from . import agent_inbox, agent_registry, core

SVN_TIMEOUT = 120
MIN_INTERVAL = 60   # seconds: no source is polled more often, whatever its interval says
INPUT = "../input"  # the job's input/ folder, as the engine sees it from its working copy

REVIEW_REV = ("Review r{rev} by {author} against this rule: {rule}. Its diff is in {input}/r{rev}.diff and its "
              "log entry in {input}/r{rev}.log. Report findings in the summary (file, line, issue). Propose fixes "
              "only as changes in this working copy, and only if the rule asks for fixes. The working copy holds "
              "only the directories the revision touched, at that revision.")


class SourceError(Exception):
    """A poll couldn't read its source (unreachable, refused, unparsable)."""


# --- state ----------------------------------------------------------------------------------

def _dir() -> Path:
    return core.state_dir() / "agent-serve"


def source_state() -> dict[str, dict[str, object]]:
    try:
        data = json.loads((_dir() / "sources.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {k: v for k, v in data.items() if isinstance(v, dict)} if isinstance(data, dict) else {}


def save_source_state(data: dict[str, dict[str, object]]) -> None:
    core.private_dir(_dir())
    core.atomic_write(_dir() / "sources.json", (json.dumps(data, indent=1, sort_keys=True) + "\n").encode("utf-8"))


@contextlib.contextmanager
def _locked() -> Iterator[None]:
    core.private_dir(_dir())
    with open(_dir() / "sources.lock", "a+") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        yield


def update_source(key: str, value: dict[str, object] | None) -> None:
    """Set (None: drop) one source's entry, leaving every other entry as it is now."""
    with _locked():
        data = source_state()
        if value is None:
            data.pop(key, None)
        else:
            data[key] = value
        save_source_state(data)


def forget_sources(prefix: str) -> None:
    with _locked():
        data = source_state()
        for k in [k for k in data if k.startswith(prefix)]:
            del data[k]
        save_source_state(data)


def seconds(text: str, default: int = 300) -> int:
    m = re.fullmatch(r"\s*(\d+)\s*([smhd]?)\s*", text or "")
    return int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)] if m else default


# --- SVN ------------------------------------------------------------------------------------

def _svn(*args: str, cwd: Path | None = None) -> str:
    try:
        r = subprocess.run(["svn", "--non-interactive", *args], capture_output=True, text=True, cwd=cwd,
                           timeout=SVN_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise SourceError(f"svn {args[0]}: {e}") from e
    if r.returncode != 0:
        tail = (r.stderr.strip().splitlines() or [f"exit {r.returncode}"])[-1]
        raise SourceError(f"svn {args[0]} {args[-1]}: {tail}")
    return r.stdout


def _info(target: str, cwd: Path) -> dict[str, object]:
    """HEAD, the absolute URL, the repository root and uuid of a URL (^/... resolves against the
    working copy at cwd)."""
    try:
        e = ET.fromstring(_svn("info", "--xml", target, cwd=cwd)).find("entry")
        assert e is not None
        return {"rev": int(e.get("revision", "")), "url": e.findtext("url") or "",
                "root": e.findtext("repository/root") or "", "uuid": e.findtext("repository/uuid") or ""}
    except (ET.ParseError, AssertionError, ValueError) as err:
        raise SourceError(f"svn info {target}: unreadable output ({err})") from err


def _key(entry: agent_registry.Repo, url: str) -> str:
    return f"svn:{core.tilde(entry.path)}:{url}"


def start_watch(entry: agent_registry.Repo) -> None:
    """Each watched URL's cursor at the repository's HEAD now, unless it has one (a changed
    setting skips nothing). SourceError when svn can't say."""
    if entry.watch is None:
        return
    for u in entry.watch.urls:
        info = _info(u, entry.path)
        with _locked():
            data = source_state()
            if not isinstance(data.get(_key(entry, u), {}).get("cursor"), int):
                data[_key(entry, u)] = {"cursor": info["rev"], "last_poll": 0.0, "url": info["url"],
                                        "root": info["root"], "uuid": info["uuid"]}
                save_source_state(data)


def sparse_dirs(paths: list[tuple[str, str, str]], under: str) -> list[str]:
    """The directories, relative to the watched path `under`, that hold what a revision touched
    there ('.' for the watched directory's own files): (action, kind, repository path) each. A
    directory inside another listed one is left out; '.' is files only, so it covers none."""
    under = under.rstrip("/")
    found: set[str] = set()
    for action, kind, p in paths:
        if p != under and not p.startswith(under + "/"):
            continue
        rel = p[len(under):].strip("/")
        d = rel if kind == "dir" and action != "D" else (rel.rsplit("/", 1)[0] if "/" in rel else "")
        found.add(d or ".")
    dirs = sorted(d for d in found if d == "." or not any(
        o not in (".", d) and d.startswith(o + "/") for o in found))
    return dirs or ["."]


def review_prompt(rev: str, author: str, rule: str, task: str = "") -> str:
    p = REVIEW_REV.format(rev=rev, author=author or "?", rule=rule, input=INPUT)
    return p + (f"\n\nWhat to check: {task}" if task else "")


def _rules_words(rules: tuple[str, ...]) -> str:
    if not rules:
        return "none was given (look for bugs and risky changes)"
    if len(rules) == 1:
        return rules[0]
    return "one of these: " + "; ".join(f"{i}) {r}" for i, r in enumerate(rules, 1))


def _candidates(entry: agent_registry.Repo, info: dict[str, object], xml: str) -> list[agent_inbox.Candidate]:
    assert entry.watch is not None
    url, root = str(info["url"]), str(info["root"])
    under = urllib.parse.unquote(url[len(root):]) if url.startswith(root) else "/"
    try:
        log = ET.fromstring(xml)
    except ET.ParseError as e:
        raise SourceError(f"svn log {url}: unreadable output ({e})") from e
    found = []
    for le in log.findall("logentry"):
        rev = le.get("revision", "")
        author = le.findtext("author") or ""
        if entry.watch.authors and author not in entry.watch.authors:
            continue
        msg = le.findtext("msg") or ""
        changed = [(p.get("action", "?"), p.get("kind", ""), p.text or "") for p in le.findall("paths/path")]
        lines = [f"{a} {p}" + (f" (from {pe.get('copyfrom-path')}:{pe.get('copyfrom-rev')})"
                               if pe.get("copyfrom-path") else "")
                 for (a, _, p), pe in zip(changed, le.findall("paths/path"))]
        first = msg.strip().splitlines()[0] if msg.strip() else "(no message)"
        found.append(agent_inbox.Candidate(
            cid=f"svn:{info['uuid']}:{rev}", source="svn", repo=core.tilde(entry.path), explicit=False,
            author=author, title=f"r{rev} by {author or '?'}: {first}"[:160],
            text=f"r{rev} by {author or '?'} on {le.findtext('date') or '?'}\n\n{msg.rstrip()}\n\nChanged paths:\n"
                 + "\n".join(lines),
            base={"url": url, "repos_root": root, "rev": rev, "review_rev": rev,
                  "sparse": "\n".join(sparse_dirs(changed, under))},
            prompt=review_prompt(rev, author, _rules_words(entry.watch.rules)), url=f"{url}@{rev}"))
    return found


def poll_svn(entry: agent_registry.Repo, now: float) -> list[agent_inbox.Candidate]:
    """New revisions on each watched URL whose interval has passed, oldest first; each URL's
    cursor then moves to HEAD. SourceError (after the URL's poll time is recorded, so a broken
    server isn't asked again before its interval) when svn fails."""
    w = entry.watch
    if w is None or w.mode not in agent_registry.MODES or w.mode == "off":
        return []
    every = max(MIN_INTERVAL, seconds(w.interval))
    found: list[agent_inbox.Candidate] = []
    errors = []
    for u in w.urls:
        key = _key(entry, u)
        st = source_state().get(key, {})
        last = st.get("last_poll")
        if isinstance(last, (int, float)) and now - float(last) < every:
            continue
        try:
            info = _info(u, entry.path)
            cursor = st.get("cursor")
            new: list[agent_inbox.Candidate] = []
            if isinstance(cursor, int) and int(str(info["rev"])) > cursor:
                new = _candidates(entry, info, _svn("log", "--xml", "-v", "-r", f"{cursor + 1}:{info['rev']}",
                                                    str(info["url"])))
        except SourceError as e:
            update_source(key, {**st, "last_poll": now, "last_error": str(e)})
            errors.append(str(e))
            continue
        update_source(key, {"cursor": info["rev"], "last_poll": now, "url": info["url"], "root": info["root"],
                            "uuid": info["uuid"]})
        found += new
    if errors and not found:
        raise SourceError("; ".join(errors))
    return found
