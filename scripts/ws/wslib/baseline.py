"""The last content each managed file had when the live copy and the repo agreed, and the
backups ws takes before it overwrites anything.

mise keeps no record of what it deployed for copy and template entries (its history
covers `mode = "track"` entries only), so a file that differs can't say which side moved.
This store is that record: the dotfiles-baseline hook (post-dotfiles) writes it after every
apply, and `ws reconcile` refreshes it whenever it finds a file in sync. Host state, in
core.state_dir()/dotfiles, never in the checkout:

  baseline.json        {"version": 1, "home": ..., "files": {key: {sha256, entry, at, how}}}
  blobs/<sha256>       the content itself (three-way merges need the base, not a hash)
  baseline.lock        held only while save() reads, merges and writes the index
  backups/<stamp>-<why>/home/<key>, .../repo/<path>, MANIFEST.tsv (original, backup, why, mode)

Blobs and backups are copies of files such as ~/.ssh/config, so the store is private on
Linux: its directories 0700, its files 0600, a store an older ws left readable tightened
when it is next opened. A backup records the original's mode, which the restore puts back.

Several ws processes can share the store (a hook during wsu, a reconcile in another tab).
A Store keeps its changes in memory; save() takes the lock, reads the index as it is now,
applies just those changes, writes the blobs they need and the index, removes unreferenced
blobs, and lets go. No lock is held between load and save, so none waits on a prompt.

An index ws can't use is never overwritten unseen. A damaged one (not JSON, the wrong shape)
reads as no baselines and is reported; the next save keeps it as baseline.json.damaged-<time>
and starts a new index, and blobs are kept while such a file exists. One written in another
format version, or for another home, is read-only here. A blob that is missing, or whose
content no longer matches its name, is no baseline.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import time
from pathlib import Path
from typing import Iterator

from . import core

VERSION = 1
KEEP_BACKUPS = 50
PRIVATE = 0o600
LOCK_TIMEOUT = 30.0
SHA = re.compile(r"^[0-9a-f]{64}$")
# Why the pre-apply snapshot kept a file: it changed since the last deploy, or it differed
# from the repo with no baseline to say which side moved (often an older deployed copy).
LOCAL_EDIT = "local edit"
NO_BASELINE = "no baseline"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def secure(root: Path) -> None:
    """Tighten a store written before it was private (0755 directories, 0644 files). The
    root goes last, so an interrupted pass runs again; symlinks are never followed."""
    if core.IS_WINDOWS or not root.is_dir() or not root.stat().st_mode & 0o077:
        return
    todo = [(os.path.join(d, n), m) for d, dirs, files in os.walk(root)
            for n, m in [(n, 0o700) for n in dirs] + [(n, PRIVATE) for n in files]]
    for p, mode in [*todo, (str(root), 0o700)]:
        if not os.path.islink(p):
            try:
                os.chmod(p, mode)
            except OSError:
                pass  # never fail a hook over this; the next open tries again


def _warn(msg: str) -> None:
    print(core.paint(f"ws: {msg}", "yellow", on=core.color_on(sys.stderr)), file=sys.stderr)


class Store:
    def __init__(self, root: Path | None = None) -> None:
        self.root = root or core.state_dir() / "dotfiles"
        secure(self.root)
        self.index_path = self.root / "baseline.json"
        self.home = str(core.home())
        self.files: dict[str, dict[str, str]] = {}
        self.dirty = False
        self._changes: dict[str, dict[str, str] | None] = {}  # key -> new record, None: forgotten
        self._pending: dict[str, bytes] = {}                 # sha256 -> content not yet written
        self.foreign = False   # written for another home (a scratch HOME sharing XDG_STATE_HOME)
        self.problem = ""      # why the index can't be used as it is, when it can't
        self.read_only = False
        state, files, why = self._load()
        if state == "ok":
            self.files = files
        elif state != "missing":
            self.problem = why
            self.read_only = state != "damaged"
            self.foreign = state == "foreign"
            if state == "damaged":
                _warn(f"{self.index_path} can't be used ({why}). Until it is replaced every file reads as having "
                      "no baseline (?). The next baseline update keeps it as baseline.json.damaged-<time> and "
                      "starts a new index; blobs are kept while that file exists.")
            elif state == "version":
                _warn(f"{self.index_path} {why}, so baselines are read-only here: nothing is recorded or "
                      "removed until this checkout is updated (wsu).")
            elif state == "unreadable":
                _warn(f"can't read {self.index_path} ({why}); baselines are read-only until it can be read.")

    def _load(self) -> tuple[str, dict[str, dict[str, str]], str]:
        """_read under the lock, so it never meets a save halfway; on Windows an open index
        would also make that save's rename fail. Unlocked when the lock can't be had."""
        if not self.index_path.exists():
            return self._read()
        try:
            with self._locked():
                return self._read()
        except (OSError, TimeoutError):
            return self._read()

    def _read(self) -> tuple[str, dict[str, dict[str, str]], str]:
        """The index as it is on disk: (state, files, why). state is ok, missing, damaged,
        version (another format), foreign (another home) or unreadable."""
        try:
            raw = self.index_path.read_bytes()
        except FileNotFoundError:
            return "missing", {}, ""
        except OSError as e:
            return "unreadable", {}, e.strerror or str(e)
        try:
            data = json.loads(raw.decode("utf-8"))
        except ValueError as e:  # UnicodeDecodeError is one
            return "damaged", {}, f"not JSON: {e}"
        if not isinstance(data, dict):
            return "damaged", {}, "not a JSON object"
        if data.get("home") not in (None, self.home):
            return "foreign", {}, f"written for another home ({data.get('home')})"
        version = data.get("version")
        if not isinstance(version, int) or isinstance(version, bool):
            return "damaged", {}, "no format version"
        if version != VERSION:
            return "version", {}, f"is format version {version}, and this ws reads version {VERSION}"
        files = data.get("files")
        if not isinstance(files, dict):
            return "damaged", {}, "no files table"
        for key, rec in files.items():
            if not (isinstance(rec, dict) and isinstance(rec.get("sha256"), str) and SHA.match(rec["sha256"])
                    and isinstance(rec.get("entry"), str)):
                return "damaged", {}, f"a bad record for {key!r}"
        return "ok", files, ""

    def get(self, key: str) -> dict[str, str] | None:
        return self.files.get(key)

    def content(self, key: str) -> bytes | None:
        """The baseline's content, or None: no record, or its blob is missing or no longer
        matches its sha256 (then there is no baseline to trust)."""
        rec = self.files.get(key)
        if not rec:
            return None
        digest = rec["sha256"]
        if digest in self._pending:
            return self._pending[digest]
        data = core.read_bytes(self.root / "blobs" / digest)
        return data if data is not None and sha(data) == digest else None

    def record(self, key: str, data: bytes, entry: str, how: str) -> bool:
        """Remember `data` as what `key` last agreed on (written by save). False when
        nothing changed."""
        if self.read_only:
            return False
        digest = sha(data)
        old = self.files.get(key)
        if old and old.get("sha256") == digest and old.get("entry") == entry and self.content(key) is not None:
            return False
        rec = {"sha256": digest, "entry": entry, "at": core.now_iso(), "how": how}
        self.files[key] = self._changes[key] = rec
        self._pending[digest] = data
        self.dirty = True
        return True

    def forget(self, key: str) -> None:
        if not self.read_only and self.files.pop(key, None) is not None:
            self._changes[key] = None
            self.dirty = True

    def keys_for(self, entry: str) -> list[str]:
        return [k for k, v in self.files.items() if v.get("entry") == entry]

    def save(self) -> bool:
        """Write this Store's changes over the index as it is now, under the lock. False when
        they couldn't be written (they stay pending, for a later save)."""
        if not self.dirty or self.read_only:
            return not self.dirty
        try:
            with self._locked():
                state, files, why = self._read()
                if state in ("version", "foreign", "unreadable"):
                    _warn(f"baselines not saved: {self.index_path} {why if state != 'unreadable' else 'is unreadable: ' + why}")
                    return False
                if state == "damaged":
                    kept, n = self.root / f"baseline.json.damaged-{core.stamp()}", 1
                    while kept.exists():
                        n += 1
                        kept = self.root / f"baseline.json.damaged-{core.stamp()}-{n}"
                    os.replace(self.index_path, kept)
                    _warn(f"kept the damaged baseline index as {kept} and started a new one")
                for key, rec in self._changes.items():
                    if rec is None:
                        files.pop(key, None)
                    else:
                        files[key] = rec
                blobs = core.private_dir(self.root / "blobs")
                used = {rec["sha256"] for rec in files.values()}
                for digest, data in self._pending.items():
                    on_disk = core.read_bytes(blobs / digest)
                    if digest in used and (on_disk is None or sha(on_disk) != digest):
                        core.atomic_write(blobs / digest, data, PRIVATE)  # missing, or altered
                doc = {"version": VERSION, "home": self.home, "files": dict(sorted(files.items()))}
                core.atomic_write(self.index_path, (json.dumps(doc, indent=1) + "\n").encode(), PRIVATE)
                self._gc(files)
        except TimeoutError as e:
            _warn(f"baselines not saved: {e}")
            return False
        self.files = files
        self._changes.clear()
        self._pending.clear()
        self.dirty = False
        return True

    def _gc(self, files: dict[str, dict[str, str]]) -> None:
        """Remove blobs no record uses, unless a damaged index is kept beside the store (its
        records can't be read, so any blob may be one of them)."""
        if any(self.root.glob("baseline.json.damaged-*")):
            return
        live = {v["sha256"] for v in files.values()}
        blobs = self.root / "blobs"
        if blobs.is_dir():
            for p in blobs.iterdir():
                if p.name not in live and not p.name.startswith("."):
                    try:
                        p.unlink()
                    except OSError:
                        pass

    @contextlib.contextmanager
    def _locked(self) -> Iterator[None]:
        """baseline.lock, exclusively: flock on Linux, a one-byte msvcrt lock on Windows. Both
        go when the process does, so a crash never leaves the store locked."""
        fd = os.open(core.private_dir(self.root) / "baseline.lock", os.O_RDWR | os.O_CREAT, PRIVATE)
        try:
            deadline = time.monotonic() + LOCK_TIMEOUT
            while not _try_lock(fd):
                if time.monotonic() > deadline:
                    raise TimeoutError(f"another ws held {self.root / 'baseline.lock'} for {LOCK_TIMEOUT:.0f}s")
                time.sleep(0.05)
            try:
                yield
            finally:
                _unlock(fd)
        finally:
            os.close(fd)


if core.IS_WINDOWS:
    import msvcrt

    def _try_lock(fd: int) -> bool:
        os.lseek(fd, 0, os.SEEK_SET)
        try:
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            return True
        except OSError:
            return False

    def _unlock(fd: int) -> None:
        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
else:
    import fcntl

    def _try_lock(fd: int) -> bool:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            return False

    def _unlock(fd: int) -> None:
        fcntl.flock(fd, fcntl.LOCK_UN)


class Backup:
    """One backup set: created on first use, one MANIFEST line per saved file."""

    def __init__(self, reason: str, root: Path | None = None) -> None:
        self.base = (root or core.state_dir() / "dotfiles") / "backups"
        self.reason = reason
        self.dir: Path | None = None
        self.saved: list[tuple[Path, Path]] = []
        self.reasons: dict[Path, str] = {}
        self.modes: dict[Path, str] = {}

    def save(self, path: Path, data: bytes | None = None, why: str = "") -> Path | None:
        """Copy a file (or `data` as that file's content) into the set; None if there was
        nothing to save. `why` goes in the MANIFEST: LOCAL_EDIT or NO_BASELINE for the
        pre-apply snapshot, so a backup never claims more than ws knew."""
        if data is None:
            data = core.read_bytes(path)
            if data is None:
                return None
        if self.dir is None:
            core.private_dir(core.private_dir(self.base.parent) / self.base.name)
            self.dir = self.base / f"{core.stamp()}-{self.reason}"
            n = 1
            while self.dir.exists():
                n += 1
                self.dir = self.base / f"{core.stamp()}-{self.reason}-{n}"
            self.dir.mkdir(mode=0o700)
            _prune(self.base, KEEP_BACKUPS)
        rel = _backup_rel(path)
        dest = self.dir
        for part in rel.parent.parts:  # mkdir(parents=True) would give the parents 0755
            dest = dest / part
            dest.mkdir(mode=0o700, exist_ok=True)
        dest = self.dir / rel
        core.atomic_write(dest, data, PRIVATE)
        mode = _mode(path)
        self.saved.append((path, dest))
        self.reasons[path] = why
        self.modes[path] = mode
        with open(self.dir / "MANIFEST.tsv", "a", encoding="utf-8",
                  opener=lambda p, flags: os.open(p, flags, PRIVATE)) as fh:
            fh.write(f"{path}\t{dest}\t{why}\t{mode}\n")
        return dest

    def counts(self) -> dict[str, int]:
        out: dict[str, int] = {}
        for why in self.reasons.values():
            out[why] = out.get(why, 0) + 1
        return out


def _mode(path: Path) -> str:
    """The file's permission bits in octal ("0644"); "" on Windows or when it's gone."""
    if core.IS_WINDOWS:
        return ""
    try:
        return f"{stat.S_IMODE(path.stat().st_mode):04o}"
    except OSError:
        return ""


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


def backup_sets(root: Path | None = None) -> list[tuple[Path, list[tuple[str, str, str, str]]]]:
    """Every backup set, newest first, with its (original, backup, why, mode) entries; why is
    "" for reconcile's own backups, and why and mode for sets written before they were recorded."""
    base = (root or core.state_dir() / "dotfiles") / "backups"
    out = []
    if not base.is_dir():
        return out
    for d in sorted((p for p in base.iterdir() if p.is_dir()), key=lambda p: p.name, reverse=True):
        pairs = []
        try:
            for line in (d / "MANIFEST.tsv").read_text(encoding="utf-8").splitlines():
                parts = line.split("\t") + ["", ""]
                if parts[1]:
                    pairs.append((parts[0], parts[1], parts[2], parts[3]))
        except FileNotFoundError:
            pass
        out.append((d, pairs))
    return out


def restore_hint(dest: Path, original: Path, mode: str = "") -> str:
    """The command that puts a backup back, with the original's mode when it was recorded
    (the backup itself is 0600)."""
    if os.name == "nt":
        return f'Copy-Item -LiteralPath "{dest}" -Destination "{original}"'
    cmd = core.shell_join(["cp", "--", str(dest), str(original)])
    return cmd + (" && " + core.shell_join(["chmod", mode, "--", str(original)]) if mode else "")
