"""Private, independent records: concurrent runs never rewrite a shared index."""

from __future__ import annotations

import csv
import datetime
import json
import os
import platform
import re
import uuid
from pathlib import Path

from . import core


def root(kind: str) -> Path:
    return core.state_dir() / kind


def create(kind: str) -> Path:
    parent = core.private_dir(root(kind))
    # Subsecond precision keeps `latest` chronological even for very short commands;
    # a random suffix alone would reorder runs started in the same second.
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    path = parent / (stamp + "-" + uuid.uuid4().hex[:12])
    path.mkdir(mode=0o700)
    return path


def save(path: Path, data: dict) -> None:
    core.atomic_write(path / "record.json", (json.dumps(data, indent=2) + "\n").encode(), 0o600)


def records(kind: str) -> list[dict]:
    result = []
    for path in sorted(root(kind).glob("*/record.json"), reverse=True):
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(doc, dict) and doc.get("id") == path.parent.name:
                result.append(doc)
        except (OSError, ValueError):
            continue
    return result


def find(kind: str, ident: str) -> tuple[Path, dict]:
    if not re.fullmatch(r"[A-Za-z0-9_-]+", ident):
        raise ValueError("invalid record id")
    items = records(kind)
    matches = items[:1] if ident == "latest" else [r for r in items if r["id"].startswith(ident)]
    if len(matches) != 1:
        raise ValueError(f"{ident!r}: expected one {kind} record, found {len(matches)}")
    return root(kind) / matches[0]["id"], matches[0]


def context(cwd: Path) -> dict:
    def git(*args: str) -> str:
        proc = core.run(["git", "-C", str(cwd), *args], timeout=5)
        return proc.stdout.strip() if proc.returncode == 0 else ""

    return {"cwd": str(cwd.resolve()), "host": platform.node(), "platform": platform.platform(),
            "revision": git("rev-parse", "HEAD"), "branch": git("branch", "--show-current"),
            "dirty": bool(git("status", "--porcelain")), "started": core.now_iso()}


def running(record: dict) -> bool:
    if record.get("status") != "running" or record.get("host") != platform.node():
        return False
    try:
        # On Windows os.kill(pid, 0) can terminate processes; query tasklist instead.
        if core.IS_WINDOWS:
            pid = str(int(record["pid"]))
            result = core.run(["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"], timeout=5)
            return any(len(row) > 1 and row[1] == pid for row in csv.reader(result.stdout.splitlines()))
        os.kill(int(record["pid"]), 0)
        return True
    except (ProcessLookupError, KeyError, ValueError):
        return False
    except PermissionError:
        return True


def status(record: dict) -> str:
    if record.get("status") == "running":
        return "running" if running(record) else "interrupted"
    return str(record.get("exit_code", record.get("status", "unknown")))
