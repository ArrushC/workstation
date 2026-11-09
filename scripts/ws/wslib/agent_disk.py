"""The disk guard: serve starts no job from a source, and `run` warns, while the filesystem that
holds the state directory (the jobs' working copies) is low on space."""

from __future__ import annotations

import shutil
from pathlib import Path

from . import core

MIN_FREE = 10 << 30
MIN_FREE_RATIO = 0.15


def threshold() -> str:
    return f"{MIN_FREE >> 30} GiB or {int(MIN_FREE_RATIO * 100)}%"


def usage() -> tuple[Path, int, int] | None:
    """(the folder measured, free bytes, total bytes), or None when it can't be measured."""
    p = core.state_dir()
    while not p.exists() and p != p.parent:
        p = p.parent
    try:
        u = shutil.disk_usage(p)
    except OSError:
        return None
    return p, u.free, u.total


def low() -> str | None:
    """Why space is low (under MIN_FREE, or under MIN_FREE_RATIO of the filesystem), or None."""
    got = usage()
    if got is None:
        return None
    p, free, total = got
    if free < MIN_FREE or (total and free < MIN_FREE_RATIO * total):
        pct = int(100 * free / total) if total else 0
        return f"{free >> 30} GiB free on {core.tilde(p)} ({pct}%), under {threshold()}"
    return None
