#!/usr/bin/env python3
"""ws: the workstation command palette, dotfile reconciliation and project workspaces.

Run by the `ws` wrapper in each shell (zshrc.tera, bashrc.tera, config.nu.tera and the
PowerShell profile) and by the dotfiles-baseline/-snapshot hook tasks. The logic lives in
wslib/; the curated actions in actions.toml. `ws help` lists everything.

This file stays parseable by the oldest system python3 a host has (EL8's 3.6), so a hook
that reaches it before mise's Python is installed gets a message instead of a SyntaxError.
"""
import os
import sys

if sys.version_info < (3, 11):
    sys.stderr.write(
        "ws: needs Python 3.11 or newer (mise's python, tools.python in config.toml); "
        "this is %s. Run wsu (or mise install python) first.\n" % sys.version.split()[0]
    )
    # The bootstrap hooks must never stop a bootstrap: before the tools phase has
    # installed mise's Python, they skip with this message.
    sys.exit(0 if sys.argv[1:2] == ["baseline"] else 2)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from wslib.cli import main  # noqa: E402

sys.exit(main(sys.argv[1:]))
