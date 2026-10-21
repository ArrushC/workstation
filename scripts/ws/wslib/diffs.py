"""Text diffs: show one, apply mise's to rebuild a rendered template, merge three sides."""

from __future__ import annotations

import difflib
import os
import re
import subprocess
import tempfile
from pathlib import Path

from . import core

HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
CONFLICT = re.compile(r"^(<{7}|={7}|>{7}|\|{7})( |$)", re.M)


def is_binary(data: bytes | None) -> bool:
    return data is not None and b"\0" in data[:8192]


def text(data: bytes | None) -> str:
    return "" if data is None else data.decode("utf-8", "surrogateescape")


def lines(s: str) -> list[str]:
    """Split on \\n only, keeping it (str.splitlines also splits on \\r, \\f and U+2028)."""
    return [p for p in re.split(r"(?<=\n)", s) if p]


def unified(a: bytes | None, b: bytes | None, a_label: str, b_label: str, *, color: bool = False,
            context: int = 3) -> str:
    """A unified diff from a to b ("" when equal). None means the file doesn't exist."""
    if a == b:
        return ""
    if is_binary(a) or is_binary(b):
        return f"Binary files {a_label} and {b_label} differ\n"
    al, bl = lines(text(a)), lines(text(b))
    out = []
    for line in difflib.unified_diff(al, bl, a_label if a is not None else "/dev/null",
                                     b_label if b is not None else "/dev/null", n=context):
        if not line.endswith("\n"):
            line += "\n\\ No newline at end of file\n"
        if color:
            if line.startswith(("+++", "---")):
                line = core.paint(line.rstrip("\n"), "bold", on=True) + "\n"
            elif line.startswith("+"):
                line = core.paint(line.rstrip("\n"), "green", on=True) + "\n"
            elif line.startswith("-"):
                line = core.paint(line.rstrip("\n"), "red", on=True) + "\n"
            elif line.startswith("@@"):
                line = core.paint(line.rstrip("\n"), "cyan", on=True) + "\n"
        out.append(line)
    return "".join(out)


def apply_unified(old: bytes, patch: str) -> bytes | None:
    """Apply the hunks of one file's unified diff to `old` and return the new content.

    Used on `mise dot diff` (current -> desired) to get a template's rendered output
    without rendering it anywhere else: the render stays mise's own, in the real home,
    with the real variables. Every context and removed line must match `old`; a
    mismatch returns None, so a misparse is never mistaken for the repo's intent.

    A hunk is as long as its header's line counts say, whatever its lines look like:
    removing a line "-- x" gives "--- x", which reads as a file header. A patch that ends
    inside a hunk, or a line in one that is no hunk line, returns None.
    """
    old_lines = lines(text(old))
    out: list[str] = []
    pos = 0
    hunks = 0
    patch_lines = patch.split("\n")
    if patch_lines[-1] == "":
        del patch_lines[-1]  # the split's trailing empty string, not an empty context line
    i = 0
    while i < len(patch_lines):
        m = HUNK.match(patch_lines[i])
        i += 1
        if not m:
            continue  # file headers and mise's own lines, between hunks
        hunks += 1
        a_start, a_left = int(m.group(1)), int(m.group(2) or "1")
        b_start, b_left = int(m.group(3)), int(m.group(4) or "1")
        start = a_start - 1 if a_left > 0 else a_start
        if start < pos or start > len(old_lines):
            return None
        out.extend(old_lines[pos:start])
        pos = start
        if b_start != len(out) + (1 if b_left > 0 else 0):
            return None
        last = ""
        while a_left or b_left or (i < len(patch_lines) and patch_lines[i].startswith("\\")):
            if i == len(patch_lines):
                return None  # the patch stops inside the hunk
            line = patch_lines[i]
            i += 1
            tag, body = (line[:1], line[1:]) if line else (" ", "")
            if tag == "\\":
                # "\ No newline at end of file" applies to the line just before it.
                if last == "+" and out and out[-1].endswith("\n"):
                    out[-1] = out[-1][:-1]
                continue
            if tag in (" ", "-"):
                if not a_left or (tag == " " and not b_left):
                    return None
                if pos >= len(old_lines) or old_lines[pos].rstrip("\n") != body:
                    return None
                if tag == " ":
                    out.append(old_lines[pos])
                    b_left -= 1
                a_left -= 1
                pos += 1
            elif tag == "+" and b_left:
                out.append(body + "\n")
                b_left -= 1
            else:
                return None
            last = tag
    if hunks == 0:
        return None
    out.extend(old_lines[pos:])
    return "".join(out).encode("utf-8", "surrogateescape")


def merge3(live: bytes, base: bytes, repo: bytes, labels: tuple[str, str, str]) -> tuple[bytes, int] | None:
    """`git merge-file --diff3` (git is a prerequisite on both OSes): the merged bytes and the
    conflict count (0 = clean). None when git can't run."""
    if not core.which("git"):
        return None
    with tempfile.TemporaryDirectory(prefix="ws-merge-") as d:
        paths = []
        for name, data in (("live", live), ("base", base), ("repo", repo)):
            p = Path(d) / name
            p.write_bytes(data)
            paths.append(str(p))
        # No user or system git config: the file being merged may be ~/.gitconfig itself,
        # mid-edit and unparseable (git then exits 128). HOME too: EL8's git 2.27 predates
        # GIT_CONFIG_GLOBAL.
        env = dict(os.environ, HOME=d, XDG_CONFIG_HOME=d, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        proc = subprocess.run(
            ["git", "merge-file", "-p", "--diff3",
             "-L", labels[0], "-L", labels[1], "-L", labels[2], *paths],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
        )
        if proc.returncode < 0 or proc.returncode > 127:
            return None
        return proc.stdout, proc.returncode


def has_conflict_markers(data: bytes) -> bool:
    return bool(CONFLICT.search(text(data)))
