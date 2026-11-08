"""The fixed admission rules a source's candidate passes before triage, the inbox or a job.

No model is asked here. The phase-1 duplicate and overlap checks follow in queue_job.
"""

from __future__ import annotations

import datetime as dt

from . import agent_inbox, agent_registry, jobs

DAILY_CAP = 10   # jobs a day from one source (one SVN repository, one GitHub repository)


def source_key(cid: str) -> str:
    """svn:<uuid>:<rev> -> svn:<uuid>; gh:<slug>:c<id> -> gh:<slug>."""
    return cid.rsplit(":", 1)[0]


def daily_count(key: str, today: dt.date | None = None) -> int:
    """Jobs made from this source's candidates (origin <key>:...) created today, UTC."""
    day = today or dt.datetime.now(dt.timezone.utc).date()
    n = 0
    for j in jobs.all_jobs():
        if not j.origin.startswith(f"{key}:"):
            continue
        try:
            created = dt.datetime.fromisoformat(j.created)
        except ValueError:
            continue
        if created.tzinfo is not None:
            created = created.astimezone(dt.timezone.utc)
        if created.date() == day:
            n += 1
    return n


def admit(c: agent_inbox.Candidate, entry: agent_registry.Repo | None, mode: str,
          allowed_authors: tuple[str, ...]) -> str | None:
    """None to admit c, else why not."""
    if entry is None:
        return f"{c.repo} is no longer allowed for queued jobs"
    if mode not in agent_registry.MODES or mode == "off":
        return f"the {c.source} source of {c.repo} is off"
    if c.source == "github":
        if not allowed_authors:
            return f"no GitHub login may ask in {c.repo} (ws-agent github --login)"
        if c.author.casefold() not in {a.casefold() for a in allowed_authors}:
            return f"{c.author or 'an unknown login'} isn't a login allowed to ask in {c.repo}"
    elif allowed_authors and c.author not in allowed_authors:
        return f"{c.author or 'an unknown author'} isn't an author watched in {c.repo}"
    if agent_inbox.seen(c.cid):
        return f"{c.cid} was already seen"
    key = source_key(c.cid)
    if daily_count(key) >= DAILY_CAP:
        return f"the daily cap of {DAILY_CAP} jobs from {key} is reached"
    return None
