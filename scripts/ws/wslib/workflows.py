"""Thin entry points for tools that already own service and debugger lifecycles."""

from __future__ import annotations

import argparse
import hashlib
import os
import tempfile
from pathlib import Path

from . import core, workspace


def main(argv: list[str], *, command: str) -> int:
    if command == "services":
        if argv[:1] in (["--help"], ["-h"]):
            print("usage: ws services [process-compose arguments...]\n"
                  "Defaults to up in the current project. Uses process-compose.yaml and mise's environment.\n"
                  "Examples: ws services up -D; ws services attach; ws services process restart api\n"
                  "Each project has its own local control socket/port. Tool help: ws services up --help")
            return 0
        cwd = workspace.toplevel(Path.cwd()) or Path.cwd()
        # Linux sockets avoid port collisions across worktrees; Windows uses a stable
        # project port. Override with PC_PORT_NUM when two paths hash to the same port.
        key = hashlib.sha256(str(cwd.resolve()).encode()).hexdigest()[:12]
        directory = core.private_dir(core.state_dir() / "services")
        if core.IS_WINDOWS:
            connection = ["--port", os.environ.get("PC_PORT_NUM", str(20000 + int(key, 16) % 30000))]
        else:
            connection = ["--use-uds", "--unix-socket", str(directory / (key + ".sock"))]
        connection += ["--log-file", str(directory / (key + ".log"))]
        return core.run(["mise", "exec", "process-compose", "--", "process-compose", *connection,
                         *(argv or ["up"])], cwd=cwd, capture=False).returncode
    p = argparse.ArgumentParser(prog="ws debug", description="Linux rr record/replay debugging. rr owns its trace store.")
    p.add_argument("action", choices=["check", "record", "replay"])
    p.add_argument("args", nargs=argparse.REMAINDER)
    a = p.parse_args(argv)
    if core.IS_WINDOWS:
        return core.die("rr requires Linux; run ws debug on a Linux host", 2)
    if not core.which("rr"):
        return core.die("rr is not installed. It is provisioned by mise's Linux system packages; run ws update on a host with sudo.", 127)
    if a.action == "check":
        print("Recording and replaying true (VMs must expose hardware performance counters):", flush=True)
        with tempfile.TemporaryDirectory(prefix="ws-rr-check-") as directory:
            trace = str(Path(directory) / "trace")
            env = {"_RR_TRACE_DIR": directory}
            code = core.run(["rr", "record", "-o", trace, "/usr/bin/true"], env=env, capture=False).returncode
            if code:
                return code
            return core.run(["rr", "replay", "-a", trace], env=env, capture=False).returncode
    args = a.args[1:] if a.args[:1] == ["--"] else a.args
    if a.action == "record" and not args:
        return core.die("usage: ws debug record -- <program> [arguments...]", 2)
    return core.run(["rr", a.action, *args], capture=False).returncode
