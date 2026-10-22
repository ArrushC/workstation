"""`ws apply`, which every shell's wsa runs: apply the repo's dotfiles to this home, asking
first when that would overwrite a local edit.

mise asks nothing before it overwrites a differing copy. This looks first, with reconcile's
model (dotfiles.at_risk): a file edited here since the last deploy (the repo may have changed
too), or one that differs with no baseline to say which side moved, would be lost. Each such
file's diff is shown and ws asks, or refuses when it can't ask. A repo change the live copy
wasn't edited past, a mode difference, a missing file, or an entry whose source is missing
(mise then refuses the whole apply) loses no content, so it applies without asking.

After a yes, wsa checks again before it runs mise: if a file at risk changed while the prompt
waited, another file became at risk, or what would replace one changed (for a template, mise
renders it again, so a change to its .tera file or to any variable it uses shows), nothing is
applied and you review it afresh; a check that can't run then refuses too. It then backs the
files up itself and stops if that fails, and tells the pre-dotfiles hook (WS_BACKED_UP) that
it needn't take a second copy. A few milliseconds still pass between that check and mise's
write.

mise resolving a config root other than this home means the -C pin failed and the wrong
checkout would be applied: that always refuses. The check says which way it went: it ran
and found nothing to lose, or it couldn't run (mise dot status failed, a file couldn't be
read). A check that couldn't run doesn't block the apply, as before ws apply: it warns and
applies, and mise reports the real problem. A status that names no config root skips only
the wrong-checkout check, with a warning.
"""

from __future__ import annotations

import os
import sys

from . import baseline, core, diffs, dotfiles, ui
from .baseline import LOCAL_EDIT, Store

RAW = "mise -C ~ bootstrap --only dotfiles --yes"


def main(extra: list[str]) -> int:
    """`extra` goes to mise bootstrap as given."""
    doc, err = dotfiles.status()
    if doc is not None:
        root = config_root(doc)
        if root and not _same_path(root, str(core.home())):
            print(f"wsa: refusing: mise resolved the dotfiles config root as {root}, not this home "
                  f"({core.home()}), so it would apply the wrong checkout. Nothing applied; check the "
                  "-C pin before retrying.", file=sys.stderr)
            return 1
        if not root and doc.get("files"):
            _warn("wsa: mise dot status named no config root, so the wrong-checkout check couldn't run; continuing")
        try:
            risky, checked = local_edits(doc)
        except OSError as e:
            doc, err = None, str(e)
        else:
            if risky:
                if not _confirm(risky):
                    return 1
                # The answer covers what was shown. Check again, and back the files up here,
                # so a change while the prompt waited, or a backup that fails, stops the apply.
                problem = _still_as_shown(risky) or _back_up(risky)
                if problem:
                    print(f"wsa: nothing applied: {problem}", file=sys.stderr)
                    return 1
                return _bootstrap(extra, backed_up=True)
            print(f"wsa: checked {checked} managed file(s): no local edit would be overwritten")
    if doc is None:
        _warn(f"wsa: the local-edit check couldn't run ({err}). Applying without it, as wsa does when "
              "it can't check; mise reports the real problem.")
    return _bootstrap(extra, backed_up=False)


def _bootstrap(extra: list[str], *, backed_up: bool) -> int:
    # backed_up: wsa holds the backup of what this apply overwrites, so the pre-dotfiles
    # hook needn't take a second (cli.baseline).
    return core.run(core.mise_argv("bootstrap", "--only", "dotfiles", "--yes", *extra), capture=False,
                    env={"WS_BACKED_UP": "1"} if backed_up else None).returncode


def _decision(risky: list[tuple[dotfiles.Item, str]]) -> dict[str, tuple[str | None, str, str | None]]:
    """What the answer was given about: each file at risk, its content as read, and what would
    replace it (for a template, mise's render, so a change to any of its inputs shows)."""
    def digest(data: bytes | None) -> str | None:
        return None if data is None else baseline.sha(data)
    return {str(item.live): (digest(item.live_data), why, digest(item.intended) if item.intended_known else None)
            for item, why in risky}


def _still_as_shown(risky: list[tuple[dotfiles.Item, str]]) -> str:
    """"" when a fresh check finds exactly what was shown; otherwise why not. A check that
    can't run now refuses: the answer can't be shown to still hold."""
    doc, err = dotfiles.status()
    if doc is None:
        return f"couldn't check again after your answer ({err}). Run wsa again to review it."
    root = config_root(doc)
    if root and not _same_path(root, str(core.home())):
        return f"mise now resolves the config root as {root}, not this home."
    try:
        fresh, _ = local_edits(doc)
    except OSError as e:
        return f"couldn't check again after your answer ({e}). Run wsa again to review it."
    before, after = _decision(risky), _decision(fresh)
    if before == after:
        risky[:] = fresh  # back up the bytes just checked
        return ""
    moved = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))
    return (f"{', '.join(core.tilde(m) for m in moved)} changed while you were deciding, so your answer no "
            "longer covers what the apply would overwrite. Run wsa again to review it.")


def _back_up(risky: list[tuple[dotfiles.Item, str]]) -> str:
    b = baseline.Backup("pre-apply")
    failed = []
    for item, why in risky:
        try:
            b.save(item.live, item.live_data, why)
        except OSError as e:
            failed.append(f"{core.tilde(item.live)} ({e.strerror or e})")
    if failed:
        return ("couldn't back up " + "; ".join(failed) + ". Fix that and run wsa again"
                + (f" (what was saved is in {b.dir})" if b.saved else "") + ".")
    print(f"wsa: backed up {len(b.saved)} file(s) first: {b.dir}  (ws reconcile --backups)")
    return ""


def _warn(msg: str) -> None:
    print(core.paint(msg, "yellow", on=core.color_on(sys.stderr)), file=sys.stderr)


def config_root(doc: dict[str, object]) -> str:
    files = doc.get("files")
    if not isinstance(files, list) or not files or not isinstance(files[0], dict):
        return ""
    origin = files[0].get("origin")
    root = origin.get("config_root") if isinstance(origin, dict) else None
    return root if isinstance(root, str) else ""


def _same_path(a: str, b: str) -> bool:
    # Windows paths compare without case (mise may print c:\users\...).
    return os.path.normcase(os.path.normpath(a)) == os.path.normcase(os.path.normpath(b))


def local_edits(doc: dict[str, object]) -> tuple[list[tuple[dotfiles.Item, str]], int]:
    """The live files the apply would lose, with why, and how many files were checked. A
    template's render comes from mise's diff only for these, and one that renders to the live
    file isn't at risk after all (its difference was the mode)."""
    out: list[tuple[dotfiles.Item, str]] = []
    items = dotfiles.load(Store(), render_templates=False, status_doc=doc).items
    for item in items:
        why = dotfiles.at_risk(item)
        if why and not item.intended_known:
            item.intended, item.note = dotfiles.render(item.entry, item.live_data)
            item.intended_known = item.intended is not None
            if item.intended_known and item.intended == item.live_data:
                why = ""
        if why:
            out.append((item, why))
    return out, len(items)


def _confirm(risky: list[tuple[dotfiles.Item, str]]) -> bool:
    color = core.color_on()
    for item, _ in risky:
        live = core.tilde(item.live)
        if item.intended_known:
            sys.stdout.write(diffs.unified(item.live_data, item.intended, f"{live} (live)", f"{live} (repo)", color=color))
        else:
            print(f"{live}: no diff to show ({item.note})")
    print(core.paint("wsa: the apply would overwrite these, and the baseline doesn't hold them:", "yellow"))
    for item, why in risky:
        print(f"  {core.tilde(item.live)}  ({'edited here since the last deploy' if why == LOCAL_EDIT else 'differs, and no baseline says which side changed'})")
    if not core.interactive():
        print(f"wsa: refusing to overwrite them non-interactively. Nothing applied. Keep an edit with ws reconcile "
              f"(record or merge), or overwrite them anyway with {RAW} (its pre-dotfiles hook backs them up "
              "first, and stops the apply if it can't)", file=sys.stderr)
        return False
    if ui.confirm("Apply anyway and overwrite them? wsa backs each up first, and stops if it can't."):
        return True
    print("wsa: nothing applied. Keep an edit with ws reconcile (record or merge), then run wsa again.", file=sys.stderr)
    return False
