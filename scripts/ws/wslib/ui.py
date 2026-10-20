"""fzf pickers, yes/no prompts and the editor, kept to what every ws command shares."""

from __future__ import annotations

import os
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from . import core

# Catppuccin Mocha with the mauve accent, as the rest of the toolbelt (fzf-tab, television).
FZF_COLORS = ("--color=bg+:#313244,spinner:#f5e0dc,hl:#f38ba8,fg:#cdd6f4,header:#f38ba8,"
              "info:#cba6f7,pointer:#cba6f7,marker:#b4befe,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8,border:#6c7086")


@dataclass
class Pick:
    key: str        # the --expect key that ended the picker ("" for Enter)
    ids: list[str]  # the first tab-separated field of each chosen line


def fzf(lines: list[str], *, prompt: str, header: str = "", preview: list[str] | None = None,
        expect: list[str] | None = None, query: str = "", multi: bool = False,
        preview_window: str = "right,60%,wrap", extra: list[str] | None = None) -> Pick | None:
    """Run fzf over `id<TAB>display` lines. Only the id comes back, so nothing the picker
    shows is ever executed. None when cancelled (Esc, Ctrl-C) or fzf is missing."""
    if not core.which("fzf"):
        return None
    argv = ["fzf", "--ansi", "--delimiter", "\t", "--with-nth", "2..", "--prompt", f"{prompt} ",
            "--layout", "reverse", "--height", "90%", "--border", "rounded", "--info", "inline-right",
            "--tiebreak", "begin,index", FZF_COLORS]
    if header:
        argv += ["--header", header, "--header-first"]
    if preview:
        argv += ["--preview", core.shell_join(preview) + " {1}", "--preview-window", preview_window]
    if expect:
        argv += ["--expect", ",".join(expect)]
    if query:
        argv += ["--query", query]
    if multi:
        argv.append("--multi")
    argv += extra or []
    proc = subprocess.run(argv, input="\n".join(lines) + "\n", stdout=subprocess.PIPE,
                          text=True, encoding="utf-8", errors="replace")
    if proc.returncode != 0:  # 1: no match, 130: cancelled
        return None
    out = proc.stdout.split("\n")
    key = out.pop(0) if expect else ""
    ids = [line.split("\t", 1)[0] for line in out if line]
    return Pick(key, ids) if ids else None


def confirm(question: str, default: bool = False) -> bool:
    if not core.interactive():
        return False
    hint = "[Y/n]" if default else "[y/N]"
    try:
        reply = input(f"{question} {hint} ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return False
    return default if not reply else reply.startswith("y")


def pause(prompt: str = "Press Enter to go back ") -> None:
    try:
        input(prompt)
    except (EOFError, KeyboardInterrupt):
        print()


def choose(question: str, options: list[tuple[str, str]], default: str = "") -> str:
    """A one-letter menu for terminals without fzf: options are (key, label)."""
    if not core.interactive():
        return ""
    for k, label in options:
        print(f"  {k}  {label}")
    try:
        reply = input(f"{question} ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return ""
    return reply or default


def editor_argv(files: list[Path], editor: str | None = None) -> list[str]:
    """The user's editor on these files, side by side where the editor can split."""
    cmd = editor or os.environ.get("VISUAL") or os.environ.get("EDITOR") or ""
    if not cmd:
        for cand in ("hx", "nvim", "vim", "vi", "notepad"):
            if core.which(cand):
                cmd = cand
                break
    argv = shlex.split(cmd, posix=not core.IS_WINDOWS) or ["vi"]
    name = Path(argv[0]).stem.lower()
    paths = [str(f) for f in files]
    if len(paths) > 1:
        if name in ("hx", "helix"):
            argv.append("--vsplit")
        elif name in ("nvim", "vim", "vi"):
            argv.append("-O")
        elif name in ("code", "codium", "zed"):
            argv.append("--wait")
    elif name in ("code", "codium", "zed"):
        argv.append("--wait")
    return argv + paths


def edit(files: list[Path], editor: str | None = None) -> int:
    argv = editor_argv(files, editor)
    print(core.paint(f"$ {core.shell_join(argv)}", "dim"))
    return core.run(argv, capture=False).returncode


def pager(content: str) -> None:
    """Show long text: less -R where it exists, else print it."""
    if core.interactive() and core.which("less"):
        subprocess.run(["less", "-R", "-F", "-X"], input=content, text=True, encoding="utf-8")
    else:
        sys.stdout.write(content)
