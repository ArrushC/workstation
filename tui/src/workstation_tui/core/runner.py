"""Async subprocess engine: streaming, one task at a time, cancellable.

Spec §Execution engine: a busy runner REFUSES (never queues) a second
mutation; cancel sends SIGINT to the whole process group and escalates to
SIGKILL after a grace period; stdout/stderr are merged and streamed
line-by-line to the caller's on_line callback. Env is scrubbed of make's
jobserver variables (established precedent in proc.py/read_inventory).
"""

import asyncio
import os
import signal
import time
from typing import Callable

from workstation_tui.core.models import TaskResult

_SCRUB = ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")


class TaskBusyError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("task running")


class Runner:
    def __init__(self) -> None:
        self._proc: asyncio.subprocess.Process | None = None
        # Set synchronously at the top of run(), before the first await, so
        # `busy` is True for the whole spawn window — not just once _proc
        # lands. Without this a second run() (or a cancel()) can slip in
        # while create_subprocess_exec() is still suspended.
        self._inflight = False
        self._cancelled = False
        self._kill_handle: asyncio.TimerHandle | None = None
        self.kill_grace = 5.0

    @property
    def busy(self) -> bool:
        return self._inflight or self._proc is not None

    async def run(self, command: list[str], on_line: Callable[[str], None]) -> TaskResult:
        if self.busy:
            raise TaskBusyError()
        self._inflight = True
        self._cancelled = False
        try:
            env = {k: v for k, v in os.environ.items() if k not in _SCRUB}
            start = time.monotonic()
            try:
                proc = await asyncio.create_subprocess_exec(
                    *command,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.STDOUT,
                    start_new_session=True,
                    env=env,
                    # StreamReader's default buffer limit is 64KB; a single
                    # over-long line (e.g. a tool dumping a huge progress
                    # bar with no newline) would raise LimitOverrunError and
                    # blow up the read loop below. 1MB is a generous single-
                    # line guard without unbounding it entirely.
                    limit=1024 * 1024,
                )
            except FileNotFoundError:
                on_line(f"workstation: command not found: {command[0]}")
                return TaskResult(command=command, returncode=127,
                                  duration_secs=time.monotonic() - start)
            except OSError as exc:
                on_line(f"workstation: cannot execute {command[0]}: {exc}")
                return TaskResult(command=command, returncode=126,
                                  duration_secs=time.monotonic() - start)

            self._proc = proc
            # cancel() may have already fired during the spawn window above
            # (busy was True via _inflight while _proc was still None), so
            # the SIGINT was deferred — deliver it now that the process
            # actually exists.
            if self._cancelled:
                self._signal_and_arm_kill(proc, signal.SIGINT)

            try:
                assert proc.stdout is not None
                while True:
                    raw = await proc.stdout.readline()
                    if not raw:
                        break
                    on_line(raw.decode(errors="replace").rstrip("\n"))
                returncode = await proc.wait()
            except (Exception, asyncio.CancelledError):
                # Contract: a raising on_line (or a stream read error, e.g.
                # LimitOverrunError) must never leave the child running
                # untracked with `busy` already back to False. We surface
                # the failure to the caller — never swallow it — but the
                # process group must be killed and reaped, and the busy
                # invariant restored, before it propagates.
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                await proc.wait()
                raise
            finally:
                if self._kill_handle is not None:
                    self._kill_handle.cancel()
                    self._kill_handle = None

            return TaskResult(
                command=command,
                returncode=returncode,
                duration_secs=time.monotonic() - start,
                cancelled=self._cancelled,
            )
        finally:
            self._inflight = False
            self._proc = None

    def cancel(self) -> None:
        if not self.busy:
            return
        self._cancelled = True
        proc = self._proc
        if proc is None:
            # Still spawning (inflight, no process yet) — run() checks
            # self._cancelled right after the process lands and delivers
            # the signal itself.
            return
        if proc.returncode is not None:
            return
        if self._kill_handle is not None:
            # Escalation already scheduled by an earlier cancel(); don't
            # stack a second SIGINT/timer on top of it.
            return
        self._signal_and_arm_kill(proc, signal.SIGINT)

    def _signal_and_arm_kill(self, proc: asyncio.subprocess.Process, sig: int) -> None:
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            return
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            # No running loop to schedule the escalation on (e.g. cancel()
            # called from outside the event loop). The SIGINT is already
            # sent; degrade to no-escalation rather than crashing.
            return
        self._kill_handle = loop.call_later(self.kill_grace, self._force_kill, proc)

    def _force_kill(self, proc: asyncio.subprocess.Process) -> None:
        self._kill_handle = None
        if proc.returncode is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
