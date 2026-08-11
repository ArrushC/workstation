"""Capped-parallel subprocess engine: many hosts, one bounded worker pool.

Deliberately separate from `runner.Runner` (the single-flight, busy-refusing
engine used for interactive one-at-a-time actions, e.g. a make goal fired
from a panel). `MultiRunner` drives a whole fleet's worth of commands
concurrently — one per host — capped by an `asyncio.Semaphore`, with
per-host progress tracked in a `HostRun` rather than returned as one
`TaskResult`. It reuses `runner.scrubbed_env()` for the same jobserver-var
scrubbing but otherwise shares no state with `Runner`.

No textual imports: this module is pure asyncio + dataclasses, consumed by
a later push-dashboard widget that adapts `HostRun` updates onto the
screen.

Cancellation has two distinct entry points with two distinct contracts,
both modeled on the `probe_setup` kill+reap discipline (core/fleet.py):

- `MultiRunner.cancel()` cancels every per-host task directly. Each
  per-host coroutine catches its own `asyncio.CancelledError`, kills +
  reaps its child process (if any), marks its `HostRun` "cancelled", and
  — unlike `probe_setup` — *swallows* the CancelledError rather than
  re-raising it. This is deliberate: `run()` awaits the per-host tasks via
  `asyncio.gather(..., return_exceptions=True)`, and cancelling children
  directly (never touching the gather future itself) means that gather
  finishes normally once every child has, so `run()` returns to its caller
  with no exception — the documented contract.
- Cancelling `run()`'s own enclosing task from the *outside* is different:
  that cancellation lands on the `gather()` call itself, which cascades
  into every live child exactly as above, but `gather()` still re-raises
  CancelledError to `run()` once all children finish (this is standard
  `asyncio.gather` behavior when the aggregate future itself receives the
  cancel request, independent of `return_exceptions`). `run()`'s `except`
  clause does one more defensive kill+reap sweep over any process that
  might still be tracked, then re-raises — so an external cancellation of
  `run()` always kills+reaps live children before propagating.
"""

import asyncio
import contextlib
import time
from dataclasses import dataclass, field
from typing import Callable

from workstation_tui.core.runner import scrubbed_env

_LINE_CAP = 5000


@dataclass
class HostRun:
    """Per-host progress: state machine + captured output."""

    name: str
    state: str  # "queued" | "running" | "done" | "failed" | "cancelled"
    rc: int | None = None
    started: float | None = None
    finished: float | None = None
    lines: list[str] = field(default_factory=list)

    def elapsed(self, now: float) -> float | None:
        """None before the host has started; `finished - started` once it
        has finished (ignoring `now`); `now - started` while still running.
        """
        if self.started is None:
            return None
        end = self.finished if self.finished is not None else now
        return end - self.started


class MultiRunner:
    """Run one command per host, up to `limit` concurrently."""

    def __init__(
        self,
        commands: dict[str, list[str]],
        *,
        limit: int = 4,
        exec_fn=asyncio.create_subprocess_exec,
    ) -> None:
        self.commands = dict(commands)
        self.limit = limit
        self.exec_fn = exec_fn
        self.runs: dict[str, HostRun] = {
            name: HostRun(name=name, state="queued") for name in self.commands
        }
        self._sem = asyncio.Semaphore(limit)
        self._procs: dict[str, asyncio.subprocess.Process] = {}
        self._tasks: dict[str, asyncio.Task] = {}

    async def run(self, on_update: Callable[[str], None]) -> None:
        self._tasks = {
            name: asyncio.ensure_future(self._run_one(name, cmd, on_update))
            for name, cmd in self.commands.items()
        }
        try:
            await asyncio.gather(*self._tasks.values(), return_exceptions=True)
        except asyncio.CancelledError:
            # run()'s own task was cancelled externally (not via
            # self.cancel()). Every live per-host task already got its own
            # CancelledError via gather()'s cascade and killed+reaped its
            # child in _exec_and_stream — this is a defensive second sweep
            # so nothing can survive even if a child's cleanup hadn't run
            # yet when this fires.
            for task in self._tasks.values():
                task.cancel()
            await asyncio.gather(*self._tasks.values(), return_exceptions=True)
            for proc in list(self._procs.values()):
                with contextlib.suppress(Exception):
                    proc.kill()
                with contextlib.suppress(Exception):
                    await proc.wait()
            raise
        finally:
            self._tasks = {}

    def cancel(self) -> None:
        """Cancel every host that hasn't finished yet.

        Cancels the per-host tasks directly (never the `gather()` future
        `run()` is awaiting), so each task's own CancelledError-handling
        kills+reaps its child and marks it "cancelled" without that
        exception ever reaching `run()` — see the module docstring.
        """
        for task in self._tasks.values():
            task.cancel()

    async def _run_one(
        self, name: str, cmd: list[str], on_update: Callable[[str], None]
    ) -> None:
        run = self.runs[name]
        try:
            async with self._sem:
                run.state = "running"
                run.started = time.monotonic()
                on_update(name)
                await self._exec_and_stream(run, cmd, on_update)
        except asyncio.CancelledError:
            run.state = "cancelled"
            run.rc = None
            if run.started is not None:
                run.finished = time.monotonic()
            on_update(name)
            # Swallowed by design (see module docstring): this task is only
            # ever cancelled directly by MultiRunner.cancel(), never via the
            # gather() future in run(), so nothing upstream is waiting to
            # observe this exception.

    async def _exec_and_stream(
        self, run: HostRun, cmd: list[str], on_update: Callable[[str], None]
    ) -> None:
        try:
            proc = await self.exec_fn(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env=scrubbed_env(),
                # StreamReader's default buffer limit is 64KB; a single
                # over-long line (e.g. a tool dumping a huge progress bar
                # with no newline) would raise LimitOverrunError and blow
                # up the read loop below. Mirrors runner.py's Runner.run().
                limit=1024 * 1024,
            )
        except Exception as exc:  # spawn failure must never raise out of run()
            run.state = "failed"
            run.rc = None
            run.lines.append(f"{type(exc).__name__}: {exc}")
            run.finished = time.monotonic()
            on_update(run.name)
            return

        self._procs[run.name] = proc
        try:
            assert proc.stdout is not None
            while True:
                raw = await proc.stdout.readline()
                if not raw:
                    break
                line = raw.decode(errors="replace").rstrip("\n")
                run.lines.append(line)
                if len(run.lines) > _LINE_CAP:
                    del run.lines[0]
                on_update(run.name)
            rc = await proc.wait()
        except asyncio.CancelledError:
            # Mirrors probe_setup's on-cancel discipline: kill, reap under
            # suppress (the process may already be gone), then re-raise so
            # _run_one's handler marks the host "cancelled".
            proc.kill()
            with contextlib.suppress(Exception):
                await proc.wait()
            raise
        except Exception as exc:
            # A stream-read error (e.g. LimitOverrunError from an
            # unterminated over-long line) or any other failure mid-stream
            # (readline, wait, or a raising on_update) must not leak the
            # child or strand the host at "running" forever. Same
            # never-raise contract as the spawn-failure branch above: kill
            # + reap, mark failed, and swallow rather than let it propagate
            # into run()'s gather(..., return_exceptions=True), which would
            # otherwise absorb it silently and leave the host un-terminable
            # (cancel() is a no-op once run()'s task set is torn down).
            proc.kill()
            with contextlib.suppress(Exception):
                await proc.wait()
            run.state = "failed"
            run.rc = None
            run.lines.append(f"{type(exc).__name__}: {exc}")
            run.finished = time.monotonic()
            on_update(run.name)
            return
        finally:
            self._procs.pop(run.name, None)

        run.rc = rc
        run.state = "done" if rc == 0 else "failed"
        run.finished = time.monotonic()
        on_update(run.name)
