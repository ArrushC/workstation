"""Candidates and the inbox: work a source found (an SVN revision, a GitHub `/agent` request)
that waits for the person, because the source is in observe mode or triage said ask.

One private file per item, <state>/agent-inbox/<id>.json, with id = sha256(cid)[:10]: a cid
(svn:<uuid>:<rev>, gh:<slug>:c<id>) isn't a safe file name. The candidate's text is someone
else's words (a log message, a comment): it is shown to the person and quoted as untrusted in
a prompt, never followed. serve is the only writer of new items; the person's accept and
dismiss only change an item's status.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path

from . import core, jobs

STATUSES = ("open", "accepted", "dismissed")
PRIVATE = 0o600
_CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")


def printable(text: str, *, lines: bool = False) -> str:
    """Someone else's text made safe to print: control characters (terminal escapes, \\r) as
    '?', and newlines and tabs as spaces unless `lines` keeps them."""
    s = _CONTROL.sub("?", text)
    return s if lines else s.replace("\n", " ").replace("\t", " ")


@dataclass
class Candidate:
    cid: str                  # deterministic per source item, so a re-poll never makes a second one
    source: str               # "svn" | "github"
    repo: str                 # the registry key (tilde form)
    explicit: bool            # someone asked (/agent): no triage
    author: str
    title: str
    text: str                 # untrusted: what triage reads and the person sees
    base: dict[str, str]      # the job's base if accepted
    prompt: str               # the job's prompt if accepted
    thread: str = ""          # gh:<slug>#<number>: follow-ups on it go to the same job
    url: str = ""


@dataclass
class Item:
    id: str
    cid: str
    created: str
    candidate: dict[str, object]
    decision: dict[str, object] | None   # triage's, or None for an explicit request
    status: str
    job: str = ""

    def as_candidate(self) -> Candidate:
        names = {f.name for f in dataclasses.fields(Candidate)}
        return Candidate(**{k: v for k, v in self.candidate.items() if k in names})  # type: ignore[arg-type]


def inbox_dir() -> Path:
    return core.state_dir() / "agent-inbox"


def item_id(cid: str) -> str:
    return hashlib.sha256(cid.encode("utf-8")).hexdigest()[:10]


def _path(ident: str) -> Path:
    return inbox_dir() / f"{ident}.json"


def _read(path: Path) -> Item:
    data = json.loads(path.read_text(encoding="utf-8"))
    return Item(**{k: v for k, v in data.items() if k in Item.__dataclass_fields__})


def _save(item: Item) -> None:
    core.private_dir(inbox_dir())
    core.atomic_write(_path(item.id), (json.dumps(asdict(item), indent=2) + "\n").encode("utf-8"), PRIVATE)


def add(c: Candidate, decision: dict[str, object] | None) -> Item:
    """The item for c: created open, or the one already there (unchanged) for that cid."""
    path = _path(item_id(c.cid))
    if path.is_file():
        try:
            return _read(path)
        except (OSError, ValueError, TypeError):
            pass   # damaged: replaced below
    item = Item(id=item_id(c.cid), cid=c.cid, created=core.now_iso(), candidate=asdict(c), decision=decision,
                status="open")
    _save(item)
    return item


def items(repo: str | None = None, *, all_: bool = False) -> list[Item]:
    """Open items (every status with all_), of one repository or all, oldest first. A file that
    can't be read is skipped."""
    if not inbox_dir().is_dir():
        return []
    found = []
    for p in inbox_dir().glob("*.json"):
        try:
            it = _read(p)
        except (OSError, ValueError, TypeError):
            continue
        if (all_ or it.status == "open") and (repo is None or it.candidate.get("repo") == repo):
            found.append(it)
    return sorted(found, key=lambda i: (i.created, i.id))


def get(prefix: str) -> Item:
    """The item whose id is `prefix` or starts with it, or whose cid is `prefix`; KeyError when
    none or several match."""
    if prefix:
        for exact in (_path(prefix), _path(item_id(prefix))):
            if exact.is_file():
                try:
                    return _read(exact)
                except (OSError, ValueError, TypeError) as e:
                    raise KeyError(f"ws-agent: inbox item {exact.stem} can't be read ({e})") from e
    hits = [i for i in items(all_=True) if i.id.startswith(prefix)] if prefix else []
    if len(hits) != 1:
        raise KeyError(f"ws-agent: {'no inbox item' if not hits else 'several inbox items'} match {prefix!r}")
    return hits[0]


def resolve(item: Item, status: str, job: str = "") -> None:
    if status not in STATUSES:
        raise ValueError(f"unknown inbox status {status!r}")
    item.status, item.job = status, job
    _save(item)


def seen(cid: str) -> bool:
    """A cid that already has an inbox item (any status) or a job made from it."""
    return _path(item_id(cid)).exists() or any(j.origin == cid for j in jobs.all_jobs())
