"""`ws reconcile`: review each managed file that differs from the repo and decide what to do.

Every change is a Plan first: the files it writes or deletes, the diff of each, what is
backed up, and the baseline it leaves. The picker previews plans before anything runs,
and nothing is written until it is confirmed. Nothing is committed or pushed: a record
or merge leaves the checkout dirty for you to review with git.

Templates are never recorded: a rendered file copied over its .tera source would bake
this host's values into every host's template. Their record step is `edit`, which opens
the template beside the live changes to port by hand.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from . import core, diffs, ui
from .baseline import Backup, Store, backup_sets, restore_hint
from .dotfiles import (BOTH, DELETED, LOCAL, MISSING, MODE, NOBASE, REMOVED, REPO, SOURCE_MISSING,
                       SYNC, TAGS, UNKNOWN, Item, Model, load, record_agreed)

KEYS = {"alt-r": "record", "alt-a": "apply", "alt-m": "merge", "alt-e": "edit"}


@dataclass
class Write:
    path: Path
    data: bytes | None   # None deletes the file
    side: str            # "live" or "repo"
    mode: int | None = None


@dataclass
class Plan:
    action: str
    item: Item
    summary: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    diff: str = ""
    writes: list[Write] = field(default_factory=list)
    mise_apply: str = ""            # a single-file entry: let mise render/copy it
    baseline: bytes | None = None   # what the baseline becomes (None: forget it)
    keep_baseline: bool = False
    ok: bool = True                 # False: the plan can't run (the reason is in summary)

    def render(self, color: bool = False) -> str:
        out = []
        for s in self.summary:
            out.append(s)
        for w in self.warnings:
            out.append(core.paint("! " + w, "yellow", on=color))
        if self.diff:
            out.append("")
            out.append(self.diff.rstrip("\n"))
        return "\n".join(out) + "\n"


def _mode_of(path: Path | None, default: int = 0o644) -> int:
    try:
        return path.stat().st_mode & 0o777 if path is not None else default
    except OSError:
        return default


def _labels(item: Item) -> tuple[str, str]:
    repo = core.tilde(item.source) if item.source else "repo"
    return f"live {core.tilde(item.live)}", f"repo {repo}" + (" (rendered)" if item.template else "")


def actions_for(item: Item) -> list[tuple[str, str]]:
    """(action, label) pairs for an item, the recommended one first."""
    c = item.cls
    acts: list[tuple[str, str]] = []
    can_merge = (c == BOTH and item.live_data is not None and item.intended is not None
                 and item.base is not None and not diffs.is_binary(item.live_data)
                 and not diffs.is_binary(item.intended))
    record_label = "record: copy the live file into the repo"
    if c == REMOVED:
        record_label = "record: restore it into the repo"
    if c == DELETED:
        record_label = "record: delete it from the repo too"
    apply_label = {MISSING: "apply: deploy the repo's version", DELETED: "apply: restore it from the repo",
                   REMOVED: "apply: remove the live copy (backed up)",
                   MODE: "apply: set the repo's executable bit"}.get(c, "apply: overwrite live with the repo's version (backed up)")
    edit_label = ("edit: open the template beside your live changes" if item.template
                  else "edit: open the live file and its source")
    record_ok = not item.template and (item.live_data is not None or (c == DELETED and item.in_dir))
    order = {
        LOCAL: ["edit", "apply"] if item.template else ["record", "apply", "edit"],
        REPO: ["apply", "edit"],
        BOTH: (["merge"] if can_merge else []) + ["edit", "apply"] + ([] if item.template else ["record"]),
        NOBASE: ["edit", "apply"] + ([] if item.template else ["record"]),
        MISSING: ["apply"],
        DELETED: ["apply"] + (["record"] if item.in_dir and not item.template else []),
        REMOVED: ["apply", "record"],
        MODE: ["apply"],
        UNKNOWN: ["edit", "apply"],
        SOURCE_MISSING: ["edit"],
    }.get(c, [])
    labels = {"record": record_label, "apply": apply_label, "edit": edit_label,
              "merge": "merge: three-way merge of live, repo and the last deploy"}
    for a in order:
        if a == "record" and not record_ok:
            continue
        acts.append((a, labels[a]))
    acts.append(("skip", "skip: change nothing"))
    return acts


def plan(item: Item, action: str) -> Plan:
    p = Plan(action, item)
    live_l, repo_l = _labels(item)
    p.summary.append(f"{core.tilde(item.live)}: {item.cls} ({item.why})")
    if action == "record":
        if item.template:
            p.ok = False
            p.summary.append(f"refused: {core.tilde(item.live)} is rendered from {core.tilde(item.entry.source)}; "
                             "a rendered file is never copied over its template. Use edit to port the change.")
            return p
        if item.source is None:
            p.ok = False
            return p
        if item.live_data is None:
            if not item.in_dir:
                p.ok = False
                p.summary.append("refused: to stop managing a whole entry, remove it from "
                                 f"{core.tilde(item.entry.config or 'its config')} and delete its source")
                return p
            p.writes.append(Write(item.source, None, "repo"))
            p.summary.append(f"deletes {core.tilde(item.source)} from the repo (not committed)")
            p.diff = diffs.unified(item.intended, None, repo_l, "/dev/null")
        else:
            p.writes.append(Write(item.source, item.live_data, "repo", _mode_of(item.source if item.source.exists() else None)))
            p.summary.append(f"writes the live content to {core.tilde(item.source)} (not committed)")
            p.diff = diffs.unified(item.intended, item.live_data, repo_l, live_l)
            p.baseline = item.live_data
        if item.cls == BOTH:
            p.warnings.append("the repo changed too since the last deploy: recording drops that change "
                              "(merge keeps both)")
        return p
    if action == "apply":
        if not item.intended_known and not item.template:
            p.ok = False
            return p
        if item.live_data is not None:
            p.summary.append(f"backs up {core.tilde(item.live)} first")
        if item.intended_known and item.intended is None:
            p.writes.append(Write(item.live, None, "live"))
            p.summary.append(f"deletes {core.tilde(item.live)} (the repo no longer has it)")
            p.diff = diffs.unified(item.live_data, None, live_l, "/dev/null")
            return p
        if item.in_dir:
            p.writes.append(Write(item.live, item.intended, "live", _mode_of(item.source)))
            p.summary.append(f"copies {core.tilde(item.source or '?')} to {core.tilde(item.live)}")
        else:
            p.mise_apply = item.entry.target
            p.summary.append(f"runs: {core.shell_join(core.mise_argv('dot', 'apply', '--force', '--yes', '--', item.entry.target))}")
        if item.intended_known:
            p.diff = diffs.unified(item.live_data, item.intended, live_l, repo_l)
            p.baseline = item.intended
        else:
            p.diff = core.mise("dot", "diff", "--", item.entry.target).stdout
        if item.cls == MODE:
            p.summary.append(f"sets the executable bit to the repo's ({oct(_mode_of(item.source))})")
        if item.cls in (LOCAL, BOTH, NOBASE, UNKNOWN) and item.live_data is not None:
            p.warnings.append("this replaces the live edit; the backup keeps it")
        return p
    if action == "merge":
        res = None
        if item.live_data is not None and item.base is not None and item.intended is not None:
            res = diffs.merge3(item.live_data, item.base, item.intended, (live_l, "last deploy", repo_l))
        if res is None:
            p.ok = False
            p.summary.append("can't merge: it needs the live file, the repo's version, the baseline and git")
            return p
        merged, conflicts = res
        return _merge_plan(p, merged, conflicts)
    p.ok = action in ("edit", "skip")
    return p


def _merge_plan(p: Plan, merged: bytes, conflicts: int) -> Plan:
    item = p.item
    live_l, repo_l = _labels(item)
    if conflicts:
        p.warnings.append(f"{conflicts} conflict(s): you resolve them in the editor before anything is written")
    p.diff = ("live -> merged\n" + diffs.unified(item.live_data, merged, live_l, "merged")
              + ("\nrepo -> merged\n" + diffs.unified(item.intended, merged, repo_l, "merged") if not item.template else ""))
    p.writes.append(Write(item.live, merged, "live", _mode_of(item.live)))
    if item.template:
        # The repo's render is now deployed underneath the local edit: the baseline becomes
        # that render, so the next look reports the remaining difference as a local edit.
        p.baseline = item.intended
        p.summary.append(f"writes the merge to {core.tilde(item.live)}; the template is unchanged, so port the "
                         f"local part into {core.tilde(item.entry.source)} (edit) to keep it on every host")
    else:
        assert item.source is not None
        p.writes.insert(0, Write(item.source, merged, "repo", _mode_of(item.source)))
        p.baseline = merged
        p.summary.append(f"writes the merge to {core.tilde(item.source)} (not committed) and {core.tilde(item.live)}")
    return p


def execute(p: Plan, store: Store, *, quiet: bool = False) -> bool:
    """Back up, write, record the baseline. True on success."""
    item = p.item
    backup = Backup(f"reconcile-{p.action}", store.root)
    for w in p.writes:
        backup.save(w.path)
    if p.mise_apply:
        backup.save(item.live)
    for w in p.writes:
        if w.data is None:
            try:
                w.path.unlink()
            except FileNotFoundError:
                pass
        else:
            core.atomic_write(w.path, w.data, w.mode)
    if p.mise_apply:
        # ws backed the file up above; the pre-dotfiles hook needn't take a second copy.
        proc = core.run(core.mise_argv("dot", "apply", "--force", "--yes", "--", p.mise_apply), capture=quiet,
                        env={"WS_BACKED_UP": "1"})
        if proc.returncode != 0:
            print(core.paint(f"mise dot apply failed (exit {proc.returncode})", "red"), file=sys.stderr)
            if quiet and proc.stderr:
                print(proc.stderr, file=sys.stderr)
            _report_backup(backup)  # even when quiet: the user needs the way back
            return False
        live = core.read_bytes(item.live)
        if p.baseline is None and live is not None:
            p.baseline = live
    if p.baseline is not None:
        store.record(item.key, p.baseline, item.entry.target, p.action)
    elif not p.keep_baseline and p.action == "apply":
        store.forget(item.key)
    elif p.action == "record" and item.live_data is None:
        store.forget(item.key)
    store.save()
    if not quiet:
        print(core.paint(f"done: {p.action} {core.tilde(item.live)}", "green"))
        if any(w.side == "repo" for w in p.writes):
            print(f"  review and commit: git -C {core.tilde(core.repo())} diff")
        _report_backup(backup)
    return True


def _report_backup(backup: Backup) -> None:
    if backup.saved:
        print(f"  backup: {backup.dir}")
        for orig, dest in backup.saved:
            print(core.paint(f"    restore: {restore_hint(dest, orig, backup.modes.get(orig, ''))}", "dim"))


# --- resolving merge conflicts and editing --------------------------------------

def resolve_conflicts(p: Plan, editor: str | None) -> Plan | None:
    """Open the merge result in the editor until no conflict markers are left."""
    item = p.item
    merged = next(w.data for w in p.writes if w.side == "live")
    assert merged is not None
    with tempfile.TemporaryDirectory(prefix="ws-merge-") as d:
        path = Path(d) / f"{item.live.name}.merged"
        path.write_bytes(merged)
        while True:
            ui.edit([path], editor)
            data = path.read_bytes()
            if not diffs.has_conflict_markers(data):
                break
            if not ui.confirm("Conflict markers are still in the file. Edit again? (no aborts the merge)", True):
                return None
    fresh = Plan("merge", item, summary=[p.summary[0]])
    return _merge_plan(fresh, data, 0)


def edit_item(item: Item, editor: str | None) -> None:
    files: list[Path] = []
    if item.template:
        tmp = Path(tempfile.mkdtemp(prefix="ws-template-"))
        files.append(item.entry.source)
        if item.intended is not None and item.live_data is not None:
            local = diffs.unified(item.intended, item.live_data, "rendered", "live")
            note = (f"# Live changes to {core.tilde(item.live)} that its template doesn't have yet.\n"
                    f"# Port what you want to keep into {core.tilde(item.entry.source)} (the file beside\n"
                    "# this one), save, and quit: ws reconcile renders the template again and compares.\n"
                    "# Never paste the rendered file over the template: it would bake in this host's values.\n\n")
            (tmp / "local-changes.diff").write_text(note + local, encoding="utf-8", errors="surrogateescape")
            files.append(tmp / "local-changes.diff")
        print(f"template: {core.tilde(item.entry.source)}  (renders to {core.tilde(item.live)})")
        ui.edit(files, editor)
        shutil.rmtree(tmp, ignore_errors=True)
        return
    for f in (item.live, item.source):
        if f is not None and f.exists():
            files.append(f)
    if not files and item.entry.config:
        files.append(item.entry.config)
    ui.edit(files, editor)


# --- the picker -----------------------------------------------------------------

def _line(i: int, item: Item, color: bool = True) -> str:
    tag, col = TAGS.get(item.cls, ("?", "red"))
    where = "template" if item.template else ("in " + item.entry.target if item.in_dir else item.entry.mode)
    return f"{i}\t{core.paint(f'{tag:<9}', col, on=color)} {core.tilde(item.live)}  {core.paint(where, 'dim', on=color)}"


def _edit_line(i: int, e: dict[str, object], color: bool = True) -> str:
    tag = core.paint(f"{'edit':<9}", "cyan", on=color)
    return (f"e{i}\t{tag} {e.get('path')}  "
            f"{core.paint(str(e.get('edit')) + ' ' + str(e.get('state')), 'dim', on=color)}")


def preview_text(item: Item, color: bool = True) -> str:
    out = [core.paint(core.tilde(item.live), "bold", on=color),
           f"{item.cls}: {item.why}"]
    if item.template:
        out.append(f"template: {core.tilde(item.entry.source)} (record is off for templates: edit ports changes)")
    elif item.source:
        out.append(f"source:   {core.tilde(item.source)}")
    if item.in_dir:
        out.append(f"entry:    {item.entry.target} (directory; only this file is touched)")
    rec = item.has_base
    out.append(f"baseline: {'yes' if rec else 'none recorded on this host'}")
    out.append("")
    live_l, repo_l = _labels(item)
    if item.cls == BOTH and item.base is not None:
        out.append(core.paint("changed here (last deploy -> live):", "yellow", on=color))
        out.append(diffs.unified(item.base, item.live_data, "last deploy", live_l, color=color))
        out.append(core.paint("changed in the repo (last deploy -> repo):", "blue", on=color))
        out.append(diffs.unified(item.base, item.intended, "last deploy", repo_l, color=color))
    elif item.cls == LOCAL and item.base is not None:
        out.append(diffs.unified(item.base, item.live_data, "last deploy", live_l, color=color))
    elif item.cls in (REPO, REMOVED) and item.base is not None:
        out.append(diffs.unified(item.base, item.intended, "last deploy", repo_l, color=color))
    elif item.intended_known:
        out.append(core.paint("live -> repo (what apply would write):", "dim", on=color))
        out.append(diffs.unified(item.live_data, item.intended, live_l, repo_l, color=color))
    else:
        out.append(core.mise("dot", "diff", "--", item.entry.target).stdout)
    return "\n".join(out)


def _recent_snapshot_note(days: int = 7) -> str:
    """The newest pre-apply backup of the last week that hasn't been mentioned yet: said once
    (a `.seen` file marks the set), and never calling a file a local edit without a baseline."""
    import datetime as dt

    from .cli import snapshot_words

    for d, entries in backup_sets()[:5]:
        if "-pre-apply" not in d.name or not entries or (d / ".seen").exists():
            continue
        try:
            when = dt.datetime.strptime(d.name[:15], "%Y%m%d-%H%M%S")
        except ValueError:
            continue
        if dt.datetime.now() - when > dt.timedelta(days=days):
            continue
        counts: dict[str, int] = {}
        for _, _, why, _ in entries:
            counts[why] = counts.get(why, 0) + 1
        try:
            (d / ".seen").touch()
        except OSError:
            pass
        return (f"the apply at {when:%Y-%m-%d %H:%M} overwrote {snapshot_words(counts)}; "
                f"backed up in {d} (ws reconcile --backups)")
    return ""


def _edit_config(e: dict[str, object]) -> str:
    """The config file that declares a line/block edit entry ("" when mise doesn't say)."""
    origin = e.get("origin")
    return str(origin.get("config") or "") if isinstance(origin, dict) else ""


class Session:
    def __init__(self, store: Store, editor: str | None = None) -> None:
        self.store = store
        self.editor = editor
        self.tmp = Path(tempfile.mkdtemp(prefix="ws-reconcile-"))
        self.note = ""

    def close(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def refresh(self) -> Model:
        model = load(self.store)
        record_agreed(model, self.store, "observe")
        return model

    def _write_preview(self, key: str, text: str) -> None:
        (self.tmp / f"{key}.txt").write_text(text, encoding="utf-8", errors="surrogateescape")

    def run(self) -> int:
        try:
            return self._loop()
        finally:
            self.close()

    def _loop(self) -> int:
        self.note = _recent_snapshot_note()
        while True:
            model = self.refresh()
            if model.errors:
                return core.die("; ".join(model.errors))
            pending = model.pending()
            if not pending and not model.edits:
                n = len(model.items)
                print(core.paint(f"Nothing to reconcile: all {n} managed files match the repo.", "green"))
                if self.note:
                    print(core.paint(self.note, "dim"))
                return 0
            lines = []
            for i, item in enumerate(pending):
                self._write_preview(str(i), preview_text(item))
                lines.append(_line(i, item))
            for i, e in enumerate(model.edits):
                self._write_preview(f"e{i}", f"{e.get('path')}: {e.get('edit')} is {e.get('state')}\n"
                                    f"declared in {core.tilde(_edit_config(e) or '?')}\n\n"
                                    + core.mise("dot", "diff", "--", str(e.get("path"))).stdout)
                lines.append(_edit_line(i, e))
            counts = {}
            for item in pending:
                counts[item.cls] = counts.get(item.cls, 0) + 1
            head = " · ".join(f"{v} {k}" for k, v in counts.items())
            header = (f"{head}\nEnter: choose an action   alt-r record  alt-a apply  alt-m merge  alt-e edit   Esc: quit"
                      + (f"\n{self.note}" if self.note else ""))
            pick = ui.fzf(lines, prompt="reconcile>", header=header,
                          preview=core.self_argv("_preview", str(self.tmp)), expect=list(KEYS))
            if pick is None:
                return 0
            ident = pick.ids[0]
            if ident.startswith("e"):
                self._edit_entry(model.edits[int(ident[1:])])
                continue
            item = pending[int(ident)]
            self._act(item, KEYS.get(pick.key, ""))

    def _edit_entry(self, e: dict[str, object]) -> None:
        path = str(e.get("path"))
        choice = ui.choose(f"{path} ({e.get('edit')}): [a]pply it, [e]dit its declaration, [s]kip?",
                           [("a", "apply: " + core.shell_join(core.mise_argv("dot", "apply", "--", path))),
                            ("e", "edit: open the config file that declares it"), ("s", "skip")], "s")
        if choice == "a":
            core.run(core.mise_argv("dot", "apply", "--yes", "--", path), capture=False)
        elif choice == "e":
            cfg = _edit_config(e)
            if cfg:
                ui.edit([Path(str(cfg))], self.editor)

    def _act(self, item: Item, action: str) -> None:
        acts = actions_for(item)
        names = [a for a, _ in acts]
        if action and action not in names:
            print(core.paint(f"{action} isn't available for {core.tilde(item.live)} ({item.cls})", "yellow"))
            action = ""
        if not action:
            lines = []
            for n, (a, label) in enumerate(acts):
                text = plan(item, a).render(color=True) if a not in ("edit", "skip") else (
                    "Opens the editor; nothing is written by ws. After you quit, the file is compared again."
                    if a == "edit" else "Leaves the file as it is.")
                self._write_preview(f"a{n}", text)
                # No recommendation without a baseline: ws doesn't know which side changed.
                sure = item.cls not in (NOBASE, UNKNOWN)
                rec = core.paint(" (recommended)", "green") if n == 0 and a != "skip" and sure else ""
                lines.append(f"a{n}\t{label}{rec}")
            pick = ui.fzf(lines, prompt=f"{core.tilde(item.live)}>", header=f"{item.cls}: {item.why}",
                          preview=core.self_argv("_preview", str(self.tmp)), preview_window="down,70%,wrap")
            if pick is None:
                return
            action = acts[int(pick.ids[0][1:])][0]
        if action == "skip":
            return
        if action == "edit":
            edit_item(item, self.editor)
            return
        p = plan(item, action)
        if p.action == "merge" and p.ok and any("conflict" in w for w in p.warnings):
            resolved = resolve_conflicts(p, self.editor)
            if resolved is None:
                print("merge aborted: nothing written")
                return
            p = resolved
        print(p.render(color=core.color_on()))
        if not p.ok:
            ui.pause()
            return
        if ui.confirm(f"{action} {core.tilde(item.live)}?"):
            execute(p, self.store)
            ui.pause()
        else:
            print("nothing changed")


# --- command line ---------------------------------------------------------------

def _match(model: Model, spec: str) -> list[Item]:
    """The items a command-line path names: one live file, or every file of an entry. A
    path may be spelt ~/x, absolute, relative to the cwd, as a baseline key or as mise's
    target."""
    want = spec.rstrip("/\\") or spec
    path = core.expand(want) if want.startswith("~") else Path(want).absolute()
    return [i for i in model.items
            if i.live == path or i.entry.path == path or i.key == want or i.entry.target == want]


def listing(model: Model, as_json: bool) -> int:
    pending = model.pending()
    if as_json:
        doc = {"items": [{"target": core.tilde(i.live), "entry": i.entry.target, "mode": i.entry.mode,
                          "class": i.cls, "why": i.why, "baseline": i.has_base,
                          "actions": [a for a, _ in actions_for(i)]} for i in pending],
               "edits": [{"path": e.get("path"), "edit": e.get("edit"), "state": e.get("state")} for e in model.edits],
               "in_sync": len(model.items) - len(pending)}
        print(json.dumps(doc, indent=1))
        return 0
    if not pending and not model.edits:
        print(f"Nothing to reconcile: all {len(model.items)} managed files match the repo.")
    for i in pending:
        tag = TAGS.get(i.cls, ("?", ""))[0]
        print(f"{tag:<9} {core.tilde(i.live)}  ({i.why})")
    for e in model.edits:
        print(f"{'edit':<9} {e.get('path')}  ({e.get('edit')} {e.get('state')})")
    note = _recent_snapshot_note()
    if note:
        print(note)
    return 0


def main(args) -> int:
    store = Store()
    if store.foreign:
        print(f"ws: {store.index_path} belongs to another home; baselines are read-only here", file=sys.stderr)
    if args.backups:
        sets = backup_sets()
        if not sets:
            print("no backups yet")
        for d, entries in sets:
            print(d)
            for orig, dest, why, mode in entries:
                print(f"  {orig}" + (f"  ({why})" if why else "") + f"\n    {restore_hint(Path(dest), Path(orig), mode)}")
        return 0
    direct = [(a, getattr(args, a)) for a in ("record", "apply", "merge") if getattr(args, a)]
    if args.list or args.json or direct or not core.interactive() or not core.which("fzf"):
        model = load(store)
        if model.errors:
            return core.die("; ".join(model.errors))
        record_agreed(model, store, "observe")
        if not direct:
            if not (args.list or args.json) and not core.interactive():
                print("(not a terminal: listing only; run ws reconcile in a terminal to act)", file=sys.stderr)
            elif not (args.list or args.json):
                print("(fzf not found: listing only; act with ws reconcile --record/--apply/--merge <path>)",
                      file=sys.stderr)
            return listing(model, args.json)
        rc = 0
        for action, specs in direct:
            for spec in specs:
                items = [i for i in _match(model, spec) if i.cls != SYNC]
                if not items:
                    print(f"ws: nothing to {action} for {spec}", file=sys.stderr)
                    rc = 1
                for item in items:
                    p = plan(item, action)
                    if action == "merge" and p.ok and any("conflict" in w for w in p.warnings):
                        if not core.interactive():
                            print(p.render())
                            print(f"ws: {core.tilde(item.live)}: the merge has conflicts; run ws reconcile in a "
                                  "terminal to resolve them", file=sys.stderr)
                            rc = 1
                            continue
                        resolved = resolve_conflicts(p, os.environ.get("WS_EDITOR"))
                        if resolved is None:
                            rc = 1
                            continue
                        p = resolved
                    print(p.render(color=core.color_on()))
                    if not p.ok:
                        rc = 1
                        continue
                    if args.yes or ui.confirm(f"{action} {core.tilde(item.live)}?"):
                        rc |= 0 if execute(p, store) else 1
                    else:
                        print("nothing changed")
        return rc
    return Session(store, os.environ.get("WS_EDITOR")).run()
