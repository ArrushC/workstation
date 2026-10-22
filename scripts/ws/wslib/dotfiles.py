"""The managed files as reconcile sees them: one Item per live file, with its live content,
the repo's intended content and the baseline, and which side changed.

Entries come from `mise dot status --json` (targets, sources, modes, states, declaring
file); `exclude` lists from that declaring config file. A directory entry becomes one
Item per file its source holds (minus excludes) plus any file the baseline remembers
for it, so a file the repo dropped still shows. Files only the live directory has were
never deployed and are not ours: they are never listed or imported.

A template's intended content is the live file with `mise dot diff` applied to it, so
the render is mise's, in the real home with the real variables; when that patch doesn't
apply cleanly the Item says so instead of guessing.
"""

from __future__ import annotations

import fnmatch
import json
import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from . import core, diffs
from .baseline import LOCAL_EDIT, NO_BASELINE, Backup, Store

SYNC = "in sync"
MODE = "mode differs"
LOCAL = "local edit"
REPO = "repo change"
BOTH = "both changed"
NOBASE = "no baseline"
MISSING = "not deployed"
DELETED = "deleted locally"
REMOVED = "removed from repo"
UNKNOWN = "can't render"
SOURCE_MISSING = "source missing"

TAGS = {  # short tags for the picker, and the colour of each
    LOCAL: ("local", "yellow"), REPO: ("repo", "blue"), BOTH: ("both", "red"),
    NOBASE: ("?", "mauve"), MISSING: ("new", "blue"), DELETED: ("deleted", "yellow"),
    REMOVED: ("removed", "blue"), MODE: ("mode", "cyan"), UNKNOWN: ("render?", "red"),
    SOURCE_MISSING: ("no source", "red"), SYNC: ("ok", "green"),
}


@dataclass
class Entry:
    target: str          # as mise prints it: "~/.config/zellij"
    path: Path           # the live path
    source: Path
    mode: str            # copy | template
    state: str           # applied | missing | differs | source_missing | tracked
    config: Path | None  # the file that declares it
    exclude: list[str] = field(default_factory=list)

    @property
    def template(self) -> bool:
        return self.mode == "template"

    @property
    def is_dir(self) -> bool:
        return self.source.is_dir() or (not self.source.exists() and self.path.is_dir())

    def excluded(self, rel: str) -> bool:
        return any(fnmatch.fnmatch(part, pat) for part in rel.split("/") for pat in self.exclude)


@dataclass
class Item:
    entry: Entry
    live: Path
    source: Path | None      # copy: the source file; template: the template
    key: str
    live_data: bytes | None  # None: the live file doesn't exist
    intended: bytes | None   # None: not in the repo (only when intended_known)
    intended_known: bool
    base: bytes | None
    has_base: bool
    exec_diff: bool = False
    note: str = ""
    # Each file this item was read from, as it was then (core.fingerprint): a plan made from
    # the item writes nothing if any of them has changed since (reconcile.execute).
    seen: dict[Path, tuple[str, int] | None] = field(default_factory=dict)

    @property
    def template(self) -> bool:
        return self.entry.template

    @property
    def in_dir(self) -> bool:
        """A file inside a directory entry: acted on alone, never through the whole entry."""
        return self.live != self.entry.path

    @property
    def rel(self) -> str:
        return self.live.relative_to(self.entry.path).as_posix() if self.in_dir else ""

    @property
    def cls(self) -> str:
        if self.entry.state == "source_missing" and not self.in_dir:
            return SOURCE_MISSING
        if not self.intended_known:
            return UNKNOWN
        live, want, base = self.live_data, self.intended, self.base
        if live is not None and want is not None and live == want:
            return MODE if self.exec_diff else SYNC
        if live is None and want is None:
            return SYNC
        if not self.has_base:
            return MISSING if live is None else NOBASE
        local, repo = live != base, want != base
        if local and repo:
            return BOTH
        if local:
            return DELETED if live is None else LOCAL
        if repo:
            return REMOVED if want is None else REPO
        return SYNC

    @property
    def why(self) -> str:
        """One line saying what happened, for the picker and the preview."""
        c = self.cls
        if c == BOTH:
            here = "deleted here" if self.live_data is None else "edited here"
            there = "removed from the repo" if self.intended is None else "changed in the repo"
            return f"{here} and {there} since the last deploy"
        return {
            LOCAL: "edited here since the last deploy; the repo hasn't changed",
            REPO: "the repo changed since the last deploy; the live file hasn't",
            NOBASE: "live and repo differ, and there is no baseline to tell which side changed",
            MISSING: "in the repo, never deployed here",
            DELETED: "deleted here since the last deploy; the repo still has it",
            REMOVED: "the repo dropped it since the last deploy; the live copy is unchanged",
            MODE: "same content, different executable bit",
            UNKNOWN: self.note or "couldn't rebuild mise's render to compare",
            SOURCE_MISSING: f"the entry's source is missing: {core.tilde(self.entry.source)}",
            SYNC: "live matches the repo",
        }[c]


@dataclass
class Model:
    entries: list[Entry] = field(default_factory=list)
    items: list[Item] = field(default_factory=list)
    edits: list[dict[str, object]] = field(default_factory=list)  # line/block edits not applied
    errors: list[str] = field(default_factory=list)
    status_ok: bool = False

    def pending(self) -> list[Item]:
        return [i for i in self.items if i.cls != SYNC]


def _key(path: Path) -> str:
    try:
        return core.home_key(path)
    except ValueError:
        return "abs:" + path.as_posix()


def _excludes(config: Path | None, target: str, cache: dict[Path, dict[str, object]]) -> list[str]:
    if config is None:
        return []
    if config not in cache:
        try:
            with open(config, "rb") as fh:
                cache[config] = tomllib.load(fh)
        except (OSError, tomllib.TOMLDecodeError):
            cache[config] = {}
    spec = cache[config].get("dotfiles", {})
    spec = spec.get(target) if isinstance(spec, dict) else None
    ex = spec.get("exclude", []) if isinstance(spec, dict) else []
    return [str(x) for x in ex] if isinstance(ex, list) else []


def status() -> tuple[dict[str, object] | None, str]:
    proc = core.mise("dot", "status", "--json")
    if proc.returncode != 0:
        return None, (proc.stderr or proc.stdout).strip() or f"mise dot status exited {proc.returncode}"
    try:
        return json.loads(proc.stdout), ""
    except ValueError as e:
        return None, f"mise dot status --json: unreadable output ({e})"


def render(entry: Entry, live: bytes | None) -> tuple[bytes | None, str]:
    """A template's intended content: the live file with mise's own diff applied. Returns
    (content, "") or (None, why)."""
    proc = core.mise("dot", "diff", "--", entry.target)
    if proc.returncode != 0:
        return None, (proc.stderr.strip().splitlines() or ["mise dot diff failed"])[-1]
    out = proc.stdout
    if "@@" not in out:
        # No content hunk: the difference is the mode alone (or nothing).
        return (live if live is not None else None), ("" if live is not None else "mise showed no content for a missing file")
    new = diffs.apply_unified(live or b"", out)
    if new is None:
        return None, "mise's diff didn't apply to the live file, so its render is unknown"
    return new, ""


def load(store: Store, *, render_templates: bool = True, status_doc: dict[str, object] | None = None) -> Model:
    model = Model()
    doc = status_doc
    if doc is None:
        doc, err = status()
        if doc is None:
            model.errors.append(err)
            return model
    model.status_ok = True
    cache: dict[Path, dict[str, object]] = {}
    files = doc.get("files", [])
    for f in files if isinstance(files, list) else []:
        if not isinstance(f, dict):
            continue
        target = str(f.get("target", ""))
        origin = f.get("origin") or {}
        cfg = origin.get("config") if isinstance(origin, dict) else None
        src = (origin.get("source") if isinstance(origin, dict) else None) or f.get("source") or ""
        entry = Entry(
            target=target, path=core.expand(target), source=core.expand(str(src)),
            mode=str(f.get("mode", "")), state=str(f.get("state", "")),
            config=Path(cfg) if cfg else None,
        )
        entry.exclude = _excludes(entry.config, target, cache)
        if entry.mode not in ("copy", "template"):
            continue  # symlink/track entries: mise's own history covers `track`
        model.entries.append(entry)
        if entry.is_dir:
            model.items.extend(_dir_items(entry, store))
        else:
            model.items.append(_file_item(entry, store, render_templates))
    edits = doc.get("edits", [])
    model.edits = [e for e in edits if isinstance(e, dict) and e.get("state") != "applied"] if isinstance(edits, list) else []
    return model


def _file_item(entry: Entry, store: Store, render_templates: bool) -> Item:
    live = core.read_bytes(entry.path)
    src = core.read_bytes(entry.source)
    key = _key(entry.path)
    base = store.content(key)
    item = Item(entry=entry, live=entry.path, source=entry.source, key=key, live_data=live,
                intended=None, intended_known=False, base=base, has_base=base is not None,
                seen={entry.path: core.fingerprint(entry.path, live), entry.source: core.fingerprint(entry.source, src)})
    if entry.state == "source_missing":
        return item
    if not entry.template:
        item.intended, item.intended_known = src, True
    elif entry.state == "applied":
        item.intended, item.intended_known = live, True
    elif render_templates:
        item.intended, item.note = render(entry, live)
        item.intended_known = item.intended is not None
    else:
        item.note = "not rendered (hook mode)"
    if live is not None and item.intended_known and item.intended is not None:
        item.exec_diff = core.is_executable(entry.path) != core.is_executable(entry.source)
    return item


def _dir_items(entry: Entry, store: Store) -> list[Item]:
    rels: set[str] = set()
    if entry.source.is_dir():
        for root, dirs, names in os.walk(entry.source):
            rel_root = Path(root).relative_to(entry.source).as_posix()
            dirs[:] = [d for d in dirs if not entry.excluded(d)]
            for n in names:
                rel = n if rel_root == "." else f"{rel_root}/{n}"
                if not entry.excluded(rel):
                    rels.add(rel)
    base_key = _key(entry.path)
    for k in store.keys_for(entry.target):
        if k.startswith(base_key + "/"):
            rel = k[len(base_key) + 1:]
            if not entry.excluded(rel):
                rels.add(rel)
    items = []
    for rel in sorted(rels):
        live_p, src_p = entry.path / rel, entry.source / rel
        live = core.read_bytes(live_p)
        want = core.read_bytes(src_p)
        key = _key(live_p)
        base = store.content(key)
        item = Item(entry=entry, live=live_p, source=src_p, key=key, live_data=live,
                    intended=want, intended_known=True, base=base, has_base=base is not None,
                    seen={live_p: core.fingerprint(live_p, live), src_p: core.fingerprint(src_p, want)})
        if live is not None and want is not None:
            item.exec_diff = core.is_executable(live_p) != core.is_executable(src_p)
        items.append(item)
    return items


# --- the hooks ------------------------------------------------------------------

def record_agreed(model: Model, store: Store, how: str) -> int:
    """Baseline every file whose live copy matches the repo; forget files gone from both
    sides, and entries no longer declared. Returns how many records changed."""
    n = 0
    for item in model.items:
        if item.cls == SYNC and item.live_data is not None:
            n += store.record(item.key, item.live_data, item.entry.target, how)
        elif item.cls == SYNC and item.live_data is None and store.get(item.key) is not None:
            store.forget(item.key)
            n += 1
    if model.status_ok and model.entries:
        declared = {e.target for e in model.entries}
        for k, v in list(store.files.items()):
            if v.get("entry") not in declared:
                store.forget(k)
                n += 1
    store.save()
    return n


def at_risk(item: Item) -> str:
    """Why an apply would lose this live file's content: LOCAL_EDIT, or NO_BASELINE when it
    differs with nothing to say which side moved. "" when it wouldn't: the live file matches
    the repo, the baseline holds it, or the apply leaves it alone."""
    live = item.live_data
    if live is None:
        return ""
    if item.cls == SOURCE_MISSING:
        return ""  # mise refuses the whole apply and writes nothing
    if item.intended_known and item.intended is not None and live == item.intended:
        return ""
    if item.entry.template and item.entry.state == "applied":
        return ""
    if item.has_base and live == item.base:
        return ""
    if item.intended_known and item.intended is None:
        return ""  # removed from the repo: an apply doesn't touch it
    return LOCAL_EDIT if item.has_base else NO_BASELINE


def snapshot(model: Model, store: Store) -> tuple[Backup, list[tuple[Path, str]]]:
    """Before an apply: back up every live file the apply would overwrite and the baseline
    doesn't already hold (at_risk). Returns the set and each file that couldn't be backed up,
    with why; one failure doesn't stop the others."""
    backup = Backup("pre-apply", store.root)
    failed: list[tuple[Path, str]] = []
    for item in model.items:
        why = at_risk(item)
        if why:
            try:
                backup.save(item.live, item.live_data, why)
            except OSError as e:
                failed.append((item.live, e.strerror or str(e)))
    return backup, failed
