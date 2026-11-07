"""The repository's checks (`ws agent allow --check CMD`), run by ws-agent itself on a job's
result: never by the engine, always inside the job sandbox (the copy is the only writable place,
the home directory and other copies are hidden, and the network is cut unless the repository
allows it), each with a time limit and a bounded output tail. No sandbox, no checks: they are
recorded as "not run", never run unsandboxed.
"""

from __future__ import annotations

import json
import os
import selectors
import signal
import subprocess
import time
from collections.abc import Mapping
from dataclasses import asdict, dataclass
from pathlib import Path

from . import agent_registry, agent_sandbox, core, jobs

CHECK_TIMEOUT = 1200        # seconds per check
OUTPUT_TAIL = 1 << 20       # bytes of each check's output kept
FIX_TAIL_LINES = 80         # lines of a failing check's output a fix round gets


@dataclass
class CheckRun:
    cmd: str
    exit: int | None        # None: timed out
    duration_s: float
    timed_out: bool
    tail: str


def _run_one(argv: list[str], cwd: Path, env: Mapping[str, str]) -> tuple[int | None, bool, str]:
    proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            cwd=cwd, env=dict(env), start_new_session=True)
    assert proc.stdout is not None
    kept = bytearray()
    deadline = time.monotonic() + CHECK_TIMEOUT
    timed_out = False
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ)
    try:
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                timed_out = True
                break
            if not sel.select(timeout=min(left, 1.0)):
                if proc.poll() is not None:
                    break
                continue
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                break
            kept += chunk
            if len(kept) > OUTPUT_TAIL:
                del kept[:len(kept) - OUTPUT_TAIL]
    finally:
        sel.close()
    if not timed_out:   # output closed: the command still gets only what is left of its time
        try:
            proc.wait(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            timed_out = True
    if timed_out:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    proc.stdout.close()
    rc = proc.wait()
    tail = kept.decode("utf-8", "replace")
    while len(tail.encode("utf-8")) > OUTPUT_TAIL:   # a replacement character can grow the text
        tail = tail[1024:]
    return (None if timed_out else rc), timed_out, tail


def run_checks(job: jobs.Job, jd: Path, entry: agent_registry.Repo, env: Mapping[str, str]) -> list[CheckRun] | None:
    """Every check of `entry` in the job's copy, in order; None when the sandbox can't run here.
    Writes result/checks.txt (each command, its outcome, its output tail) and result/checks.json."""
    res = jd / "result"
    res.mkdir(parents=True, exist_ok=True)
    if not entry.checks:
        return []
    why = agent_sandbox.probe()
    if why:
        (res / "checks.txt").write_text(f"checks not run: no job sandbox on this host ({why})\n", encoding="utf-8")
        return None
    wc = jd / "wc"
    runs: list[CheckRun] = []
    for cmd in entry.checks:
        try:
            argv = agent_sandbox.wrap(["sh", "-c", cmd], job_id=job.id, wc=wc, network=entry.network)
        except agent_sandbox.SandboxError as e:
            (res / "checks.txt").write_text(f"checks not run: {e}\n", encoding="utf-8")
            return None
        start = time.monotonic()
        rc, timed_out, tail = _run_one(argv, wc, env)
        runs.append(CheckRun(cmd, rc, round(time.monotonic() - start, 1), timed_out, tail))
    lines = []
    for r in runs:
        how = f"timed out after {CHECK_TIMEOUT}s" if r.timed_out else f"exit {r.exit}"
        lines += [f"$ {r.cmd}    ({how}, {r.duration_s}s)", r.tail.rstrip("\n"), ""]
    (res / "checks.txt").write_text("\n".join(lines), encoding="utf-8")
    summary = [{k: v for k, v in asdict(r).items() if k != "tail"} for r in runs]
    core.atomic_write(res / "checks.json", (json.dumps(summary, indent=2) + "\n").encode("utf-8"))
    return runs


def verdict(runs: list[CheckRun] | None) -> str:
    if runs is None:
        return "not run"
    if not runs:
        return "none"
    return "pass" if all(r.exit == 0 and not r.timed_out for r in runs) else "fail"


def failing(runs: list[CheckRun]) -> CheckRun | None:
    return next((r for r in runs if r.timed_out or r.exit != 0), None)


def fix_tail(run: CheckRun) -> str:
    return "\n".join(run.tail.rstrip("\n").splitlines()[-FIX_TAIL_LINES:])
