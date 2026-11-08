"""The repositories queued agent jobs (`ws agent run`) may work in: one per-host file,
~/.config/workstation/agents.toml, written only by `ws agent allow`/`disallow`.

Those two refuse inside a Claude Code session (CLAUDECODE=1): which repositories an
unattended agent may touch is the person's decision, made in their own terminal.
"""

from __future__ import annotations

import json
import os
import tomllib
from dataclasses import dataclass
from pathlib import Path

from . import core

HEADER = "# ws-agent: repositories queued jobs may work in (per host). Edit with ws-agent allow/disallow.\n"
REFUSAL = ("ws-agent: a Claude Code session can't change which repositories jobs may use; "
           "run this in your own terminal")


class Refused(Exception):
    pass


@dataclass(frozen=True)
class Repo:
    path: Path
    vcs: str
    commands: tuple[str, ...] = ()
    allowed_at: str = ""


def registry_path() -> Path:
    return core.config_dir() / "agents.toml"


def _key(root: Path) -> str:
    return core.tilde(root.resolve())


def _read() -> dict[str, object]:
    try:
        return tomllib.loads(registry_path().read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError):
        return {}


def load() -> tuple[dict[str, Repo], int]:
    data = _read()
    repos: dict[str, Repo] = {}
    table = data.get("repo")
    for key, entry in (table.items() if isinstance(table, dict) else []):
        if not isinstance(entry, dict):
            continue
        cmds = entry.get("commands", [])
        repos[key] = Repo(core.expand(key), str(entry.get("vcs", "")),
                          tuple(str(c) for c in cmds) if isinstance(cmds, list) else (),
                          str(entry.get("allowed_at", "")))
    queue = data.get("queue")
    parallel = queue.get("parallel", 1) if isinstance(queue, dict) else 1
    return repos, parallel if isinstance(parallel, int) and parallel >= 1 else 1


def find(root: Path) -> Repo | None:
    return load()[0].get(_key(root))


def _guard() -> None:
    if os.environ.get("CLAUDECODE") == "1":
        raise Refused(REFUSAL)


def _write(repos: dict[str, Repo]) -> None:
    data = _read()
    queue = data.get("queue")
    out = [HEADER]
    if isinstance(queue, dict) and queue:
        out.append("\n[queue]\n")
        out += [f"{k} = {json.dumps(v)}\n" for k, v in queue.items() if isinstance(v, (int, str, bool))]
    for key, r in sorted(repos.items()):
        out.append(f"\n[repo.{json.dumps(key)}]\n")
        out.append(f"vcs = {json.dumps(r.vcs)}\n")
        out.append("commands = [" + ", ".join(json.dumps(c) for c in r.commands) + "]\n")
        out.append(f"allowed_at = {json.dumps(r.allowed_at)}\n")
    core.atomic_write(registry_path(), "".join(out).encode("utf-8"))


def allow(root: Path, vcs: str, commands: list[str]) -> Repo:
    _guard()
    repos = load()[0]
    repo = Repo(root.resolve(), vcs, tuple(commands), core.now_iso())
    repos[_key(root)] = repo
    _write(repos)
    return repo


def disallow(root: Path) -> bool:
    _guard()
    repos = load()[0]
    if repos.pop(_key(root), None) is None:
        return False
    _write(repos)
    return True
