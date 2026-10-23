"""Shared fixtures: a scratch home, checkout and state dir per test, and fake commands."""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

WS = Path(__file__).resolve().parent.parent
REPO = WS.parent.parent
sys.path.insert(0, str(WS))


class Scratch(unittest.TestCase):
    """HOME, the checkout (WS_REPO), the state and config dirs, all under one temp dir. The
    real home and its state are never read or written."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="ws-test-")
        self.root = Path(self._tmp.name)
        self.home = self.root / "home dir"   # a space, on purpose
        self.repo = self.home / ".config" / "mise"
        self.state = self.root / "state"
        self.bin = self.root / "bin"
        for d in (self.repo / "dotfiles", self.state, self.bin):
            d.mkdir(parents=True)
        env = {"HOME": str(self.home), "WS_REPO": str(self.repo), "WS_STATE_DIR": str(self.state),
               "WS_CONFIG_DIR": str(self.root / "cfg"), "NO_COLOR": "1", "WS_NONINTERACTIVE": "1",
               "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}", "WS_SHELL": "zsh"}
        self._env = mock.patch.dict(os.environ, env)
        self._env.start()
        for k in ("WS_OUT", "ZELLIJ", "ZELLIJ_SESSION_NAME", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "EDITOR", "VISUAL"):
            os.environ.pop(k, None)
        self.config = self.repo / "config.toml"
        self.config.write_text("[dotfiles]\n", encoding="utf-8")

    def tearDown(self) -> None:
        self._env.stop()
        self._tmp.cleanup()

    # --- files -------------------------------------------------------------------

    def write(self, path: Path, text: str | bytes, mode: int | None = None) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(text, str):
            path.write_text(text, encoding="utf-8")
        else:
            path.write_bytes(text)
        if mode is not None:
            os.chmod(path, mode)
        return path

    def fake(self, name: str, body: str) -> Path:
        """A command on PATH: a bash script."""
        p = self.bin / name
        p.write_text("#!/usr/bin/env bash\n" + body + "\n", encoding="utf-8")
        p.chmod(p.stat().st_mode | stat.S_IXUSR)
        return p

    # --- a status document like `mise dot status --json` ---------------------------

    def entries(self, *specs: dict[str, object]) -> dict[str, object]:
        """specs: target ("~/x"), source (repo-relative), mode, state, exclude."""
        lines = ["[dotfiles]"]
        files = []
        for s in specs:
            src = self.repo / str(s["source"])
            ex = s.get("exclude")
            spec = f'source = "{s["source"]}", mode = "{s.get("mode", "copy")}"'
            if ex:
                spec += ", exclude = [" + ", ".join(f'"{e}"' for e in ex) + "]"  # type: ignore[union-attr]
            lines.append(f'"{s["target"]}" = {{ {spec} }}')
            files.append({"target": s["target"], "source": str(src), "mode": s.get("mode", "copy"),
                          "state": s.get("state", "differs"),
                          "origin": {"config": str(self.config), "config_root": str(self.home), "source": str(src)}})
        self.config.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return {"files": files, "edits": [], "history": {}}

    def fake_mise(self, status: dict[str, object] | None = None, diff: str = "", log: Path | None = None) -> Path:
        """mise: `dot status --json` prints `status`, `dot diff` prints `diff`, the rest logs."""
        st = self.root / "status.json"
        st.write_text(json.dumps(status or {"files": [], "edits": []}), encoding="utf-8")
        df = self.root / "diff.txt"
        df.write_text(diff, encoding="utf-8")
        lg = log or self.root / "mise.log"
        return self.fake("mise", f"""printf '%s\\n' "$*" >>"{lg}"
case " $* " in
  *" bootstrap "*) echo "WS_BACKED_UP=${{WS_BACKED_UP:-}}" >>"{lg}.env" ;;
  *" dot status --json"*) cat "{st}" ;;
  *" dot diff "*) cat "{df}" ;;
  *" tasks ls "*) echo '[]' ;;
esac""")
