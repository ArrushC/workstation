"""Opt-in command output journal. Commands are argv, never reconstructed shell text."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import core, history, ui


def start(argv: list[str], cwd: Path, label: str = "") -> int:
    if argv[:1] == ["--"]:
        argv = argv[1:]
    if not argv:
        return core.die("supply a command after --, for example: ws runs start -- mise run test", 2)
    if not cwd.is_dir():
        return core.die(f"working directory no longer exists: {cwd}")
    path = history.create("runs")
    data = {**history.context(cwd), "id": path.name, "argv": argv, "label": label,
            "pid": os.getpid(), "status": "running"}
    history.save(path, data)
    print(f"ws runs: {path.name}", flush=True)
    started = time.monotonic()
    code = 127
    proc = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0)  # no CRLF translation on Windows
        with os.fdopen(os.open(path / "output.log", flags, 0o600), "wb") as log:
            proc = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    start_new_session=not core.IS_WINDOWS)
            assert proc.stdout is not None
            while chunk := os.read(proc.stdout.fileno(), 65536):
                log.write(chunk)
                log.flush()
                try:
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                except BrokenPipeError:
                    pass  # still finish and keep the log when the viewer closes
            code = proc.wait()
    except KeyboardInterrupt:
        code = 130
        if proc is not None:
            if core.IS_WINDOWS:
                proc.terminate()
            else:
                os.killpg(proc.pid, signal.SIGINT)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                if core.IS_WINDOWS:
                    proc.kill()
                else:
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
    except OSError as error:
        core.die(str(error))
        data["error"] = str(error)
    finally:
        if proc is not None:
            if proc.stdout is not None:
                proc.stdout.close()
            if proc.poll() is None:
                if core.IS_WINDOWS:
                    proc.kill()
                else:
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
        data.update(status="finished", exit_code=code, duration=time.monotonic() - started, ended=core.now_iso())
        history.save(path, data)
    return code if code >= 0 else 128 - code


def show(ident: str) -> int:
    path, data = history.find("runs", ident)
    print(f"{data['id']}  exit={history.status(data)}  {data.get('cwd')}\n"
          f"$ {core.shell_join(data['argv'])}\n", flush=True)
    output = path / "output.log"
    if output.exists():
        # Stream instead of loading arbitrarily large build logs into memory.
        with output.open("rb") as fh:
            while chunk := fh.read(65536):
                sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
    if data.get("error"):
        print(data["error"])
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="ws runs", description="Opt-in command logs with exit status, duration and Git revision.")
    sub = parser.add_subparsers(dest="action")
    run = sub.add_parser("start", help="capture a command, e.g. ws runs start -- mise run test")
    run.add_argument("--label", default="")
    run.add_argument("command", nargs=argparse.REMAINDER)
    listing = sub.add_parser("list", help="list or search previous runs")
    listing.add_argument("query", nargs="?", default="")
    listing.add_argument("--json", action="store_true")
    listing.add_argument("--failed", action="store_true")
    search = sub.add_parser("search", help="search saved output for literal text")
    search.add_argument("text")
    search.add_argument("--id", help="limit search to a record id, unique prefix or latest")
    for action in ("show", "rerun"):
        p = sub.add_parser(action)
        p.add_argument("id", help="record id, unique prefix, or latest")
    args = parser.parse_args(argv)
    try:
        if args.action == "start":
            return start(args.command, Path.cwd(), args.label)
        if args.action == "show":
            return show(args.id)
        if args.action == "rerun":
            _, data = history.find("runs", args.id)
            return start(data["argv"], Path(data["cwd"]), data.get("label", ""))
        if args.action == "search":
            records = [history.find("runs", args.id)[1]] if args.id else history.records("runs")
            for record in records:
                output = history.root("runs") / record["id"] / "output.log"
                if not output.exists():
                    continue
                with output.open(encoding="utf-8", errors="replace") as lines:
                    for number, line in enumerate(lines, 1):
                        if args.text.casefold() in line.casefold():
                            print(f"{record['id']}:{number}: {line.rstrip()}")
            return 0
        items = history.records("runs")
        if args.action == "list":
            items = [r for r in items if args.query.lower() in json.dumps(r).lower()
                     and (not args.failed or r.get("exit_code") not in (None, 0))]
            if args.json:
                print(json.dumps(items, indent=2))
                return 0
        lines = [f"{r['id']}\t{history.status(r):>11} {r.get('duration', 0):7.1f}s  "
                 f"{r.get('label', '')} {core.shell_join(r['argv'])}  {r['cwd']}" for r in items]
        if not args.action and core.interactive() and core.which("fzf"):
            pick = ui.fzf(lines, prompt="runs>", header="Enter: output; Ctrl-R: rerun the selected command",
                          expect=["ctrl-r"], preview=core.self_argv("runs", "show"))
            if pick:
                return main(["rerun" if pick.key == "ctrl-r" else "show", pick.ids[0]])
        else:
            print("\n".join(lines) or "No recorded runs. Start one with: ws runs start -- mise run <task>")
        return 0
    except (OSError, ValueError) as error:
        return core.die(str(error))
