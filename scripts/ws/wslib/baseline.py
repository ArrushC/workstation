"""The last content each managed file had when the live copy and the repo agreed, and the
backups ws takes before it overwrites anything.

mise keeps no record of what it deployed for copy and template entries (its history
covers `mode = "track"` entries only), so a file that differs can't say which side moved.
This store is that record: the dotfiles-baseline hook (post-dotfiles) writes it after every
apply, and `ws reconcile` refreshes it whenever it finds a file in sync. Host state, in
core.state_dir()/dotfiles, never in the checkout:

  baseline.json        {"version": 1, "home": ..., "files": {key: {sha256, entry, at, how}}}
  blobs/<sha256>       the content itself (three-way merges need the base, not a hash)
  backups/<stamp>-<why>/home/<key>, .../repo/<path>, MANIFEST.tsv (original, backup, why)
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
from pathlib import Path

from . import core

VERSION = 1
KEEP_BACKUPS = 50
# Why the pre-apply snapshot kept a file: it changed since the last deploy, or it differed
# from the repo with no baseline to say which side moved (often an older deployed copy).
LOCAL_EDIT = "local edit"
NO_BASELINE = "no baseline"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Store:
    def __init__(self, root: Path | None = None) -> None:
        self.root = root or core.state_dir() / "dotfiles"
        self.index_path = self.root / "baseline.json"
        self.home = str(core.home())
        self.files: dict[str, dict[str, str]] = {}
        self.dirty = False
        # A store written for another home (a scratch HOME sharing XDG_STATE_HOME) is
        # left alone: its keys are relative to a different tree.
        self.foreign = False
        try:
            data = json.loads(self.index_path.read_text(encoding="utf-8"))
        except (FileNotFoundError, ValueError):
            data = {}
        if data.get("home") not in (None, self.home):
            self.foreign = True
        elif data.get("version") == VERSION:
            self.files = data.get("files", {})

    def get(self, key: str) -> dict[str, str] | None:
        return self.files.get(key)

    def content(self, key: str) -> bytes | None:
        rec = self.files.get(key)
        if not rec:
            return None
        return core.read_bytes(self.root / "blobs" / rec["sha256"])

    def record(self, key: str, data: bytes, entry: str, how: str) -> bool:
        """Remember `data` as what `key` last agreed on. False when nothing changed."""
        if self.foreign:
            return False
        digest = sha(data)
        old = self.files.get(key)
        if old and old.get("sha256") == digest and old.get("entry") == entry:
            return False
        blob = self.root / "blobs" / digest
        if not blob.exists():
            core.atomic_write(blob, data)
        self.files[key] = {"sha256": digest, "entry": entry, "at": core.now_iso(), "how": how}
        self.dirty = True
        return True

    def forget(self, key: str) -> None:
        if not self.foreign and self.files.pop(key, None) is not None:
            self.dirty = True

    def keys_for(self, entry: str) -> list[str]:
        return [k for k, v in self.files.items() if v.get("entry") == entry]

    def save(self) -> None:
        if not self.dirty or self.foreign:
            return
        doc = {"version": VERSION, "home": self.home, "files": dict(sorted(self.files.items()))}
        core.atomic_write(self.index_path, (json.dumps(doc, indent=1) + "\n").encode())
        self.dirty = False
        self._gc()

    def _gc(self) -> None:
        live = {v["sha256"] for v in self.files.values()}
        blobs = self.root / "blobs"
        if blobs.is_dir():
            for p in blobs.iterdir():
                if p.name not in live and not p.name.startswith("."):
                    try:
                        p.unlink()
                    except OSError:
                        pass


class Backup:
    """One backup set: created on first use, one MANIFEST line per saved file."""

    def __init__(self, reason: str, root: Path | None = None) -> None:
        self.base = (root or core.state_dir() / "dotfiles") / "backups"
        self.reason = reason
        self.dir: Path | None = None
        self.saved: list[tuple[Path, Path]] = []
        self.reasons: dict[Path, str] = {}

    def save(self, path: Path, data: bytes | None = None, why: str = "") -> Path | None:
        """Copy a file (or `data` as that file's content) into the set; None if there was
        nothing to save. `why` goes in the MANIFEST: LOCAL_EDIT or NO_BASELINE for the
        pre-apply snapshot, so a backup never claims more than ws knew."""
        if data is None:
            data = core.read_bytes(path)
            if data is None:
                return None
        if self.dir is None:
            self.dir = self.base / f"{core.stamp()}-{self.reason}"
            n = 1
            while self.dir.exists():
                n += 1
                self.dir = self.base / f"{core.stamp()}-{self.reason}-{n}"
            self.dir.mkdir(parents=True)
            _prune(self.base, KEEP_BACKUPS)
        rel = _backup_rel(path)
        dest = self.dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        self.saved.append((path, dest))
        self.reasons[path] = why
        with open(self.dir / "MANIFEST.tsv", "a", encoding="utf-8") as fh:
            fh.write(f"{path}\t{dest}\t{why}\n")
        return dest

    def counts(self) -> dict[str, int]:
        out: dict[str, int] = {}
        for why in self.reasons.values():
            out[why] = out.get(why, 0) + 1
        return out


def _backup_rel(path: Path) -> Path:
    for prefix, root in (("repo", core.repo()), ("home", core.home())):
        try:
            return Path(prefix) / path.relative_to(root)
        except ValueError:
            continue
    drive = path.drive.replace(":", "") if path.drive else ""
    return Path("abs") / drive / Path(*path.parts[1:])


def _prune(base: Path, keep: int) -> None:
    sets = sorted((p for p in base.iterdir() if p.is_dir()), key=lambda p: p.name)
    for old in sets[:-keep] if len(sets) > keep else []:
        shutil.rmtree(old, ignore_errors=True)


def backup_sets(root: Path | None = None) -> list[tuple[Path, list[tuple[str, str, str]]]]:
    """Every backup set, newest first, with its (original, backup, why) entries; why is ""
    for reconcile's own backups and for sets written before it was recorded."""
    base = (root or core.state_dir() / "dotfiles") / "backups"
    out = []
    if not base.is_dir():
        return out
    for d in sorted((p for p in base.iterdir() if p.is_dir()), key=lambda p: p.name, reverse=True):
        pairs = []
        try:
            for line in (d / "MANIFEST.tsv").read_text(encoding="utf-8").splitlines():
                parts = line.split("\t")
                if len(parts) >= 2:
                    pairs.append((parts[0], parts[1], parts[2] if len(parts) > 2 else ""))
        except FileNotFoundError:
            pass
        out.append((d, pairs))
    return out


def restore_hint(dest: Path, original: Path) -> str:
    if os.name == "nt":
        return f'Copy-Item -LiteralPath "{dest}" -Destination "{original}"'
    return core.shell_join(["cp", "--", str(dest), str(original)])
