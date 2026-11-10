"""`ws-agent fleet`: the jobs and inbox items of this host and of the hosts the person listed
(`[fleet] hosts` in agents.toml: SSH aliases from their own ~/.ssh/config), in one view.

Pull only: when the person opens the view, each host is asked over their own SSH (`ws-agent ls
--all --json`, `ws-agent inbox --json`, one connection, in parallel). Nothing runs on a remote
host otherwise: no service, no port, no cache. An unreachable host is one row saying so. What a
remote host answers is someone else's text here: printed through `printable`, never in an event
line. `on()` runs one ws-agent command on a listed host, its arguments quoted for the remote
shell (the fleet view's keys use it).
"""

from __future__ import annotations

import json
import shlex
import subprocess
from concurrent.futures import ThreadPoolExecutor

from . import agent_inbox, agent_registry, jobs

MARK = "@@ws-agent-inbox@@"
SSH_TIMEOUT = 20
LOCAL = "local"


def ssh_argv(host: str, words: list[str], *, tty: bool = False) -> list[str]:
    """ssh to `host` running ws-agent with `words`, through a login shell (a non-interactive SSH
    session has no ~/.local/bin on PATH). One word for the remote shell, each argument quoted."""
    inner = shlex.join(["ws-agent", *words])
    return ["ssh", *(["-t"] if tty else []), "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", host,
            shlex.join(["bash", "-lc", inner])]


def _cell(text: object) -> str:
    return agent_inbox.printable(str(text or ""))


def _local() -> list[tuple[str, ...]]:
    q = jobs.pueue_status()
    tasks = q.tasks if q else None
    out: list[tuple[str, ...]] = []
    for j in jobs.all_jobs():
        st = jobs.state(j, tasks)
        if st != "closed":
            out.append((LOCAL, "job", j.id, st, _cell(j.title), j.repo))
    for it in agent_inbox.items():
        out.append((LOCAL, "inbox", it.id, _word(it.decision, it.candidate), _cell(it.candidate.get("title")),
                    str(it.candidate.get("repo") or "")))
    return out


def _word(decision: object, candidate: object) -> str:
    d = decision if isinstance(decision, dict) else {}
    c = candidate if isinstance(candidate, dict) else {}
    return _cell(d.get("decision") or ("request" if c.get("explicit") else "open"))


def _remote(host: str) -> list[tuple[str, ...]]:
    inner = "ws-agent ls --all --json && echo " + MARK + " && ws-agent inbox --json"
    argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", host, shlex.join(["bash", "-lc", inner])]
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=SSH_TIMEOUT, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        return [(host, "down", "-", "unreachable", _cell(e), "")]
    if r.returncode != 0 or MARK not in r.stdout:
        why = (r.stderr.strip().splitlines() or [f"exit {r.returncode}"])[-1]
        return [(host, "down", "-", "unreachable", _cell(why), "")]
    head, _, tail = r.stdout.partition(MARK)
    try:
        listed, inbox = json.loads(head), json.loads(tail)
    except ValueError:
        return [(host, "down", "-", "unreachable", "its ws-agent answered something unreadable", "")]
    out: list[tuple[str, ...]] = []
    for j in listed if isinstance(listed, list) else []:
        if isinstance(j, dict) and j.get("state") != "closed":
            out.append((host, "job", _cell(j.get("id")), _cell(j.get("state")), _cell(j.get("title")), _cell(j.get("repo"))))
    for it in inbox if isinstance(inbox, list) else []:
        if isinstance(it, dict) and it.get("status", "open") == "open":
            c = it.get("candidate") if isinstance(it.get("candidate"), dict) else {}
            assert isinstance(c, dict)
            out.append((host, "inbox", _cell(it.get("id")), _word(it.get("decision"), c), _cell(c.get("title")),
                        _cell(c.get("repo"))))
    return out


def table() -> list[tuple[str, ...]]:
    """(host, kind, id, state, title, repo) rows: this host, then each fleet host in the order listed."""
    hosts = agent_registry.settings().fleet
    with ThreadPoolExecutor(max_workers=max(1, len(hosts))) as pool:
        remote = list(pool.map(_remote, hosts))
    return _local() + [row for rows in remote for row in rows]


def rows() -> list[str]:
    return ["\t".join(r) for r in table()]


def on(host: str, words: list[str], *, tty: bool) -> list[str] | None:
    """The argv that runs `ws-agent <words>` on a listed host; None for this host (run it here).
    KeyError for a host the person didn't list."""
    if host == LOCAL:
        return None
    if host not in agent_registry.settings().fleet:
        raise KeyError(f"ws-agent: {host} isn't in the fleet (ws-agent fleet add {host}, in your own terminal)")
    return ssh_argv(host, words, tty=tty)
