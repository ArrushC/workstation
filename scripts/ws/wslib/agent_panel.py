"""`ws-agent panel`: this host's jobs and inbox in a browser, with a JSON API under it.

It answers three questions, in this order: does anything need the person, is the system healthy,
and what happened to one piece of work. It can do what `ws-agent ui` does to a job or an inbox
item (tell, interrupt, cancel, retry, close, accept, dismiss) and nothing else: there is no route
that starts work, changes what agents may touch, or publishes.

It listens on a Unix socket in the person's runtime directory, never on a TCP port: on a shared
host a localhost port is open to every user. `panel open` gives a browser a 127.0.0.1 address
that is relayed to that socket (for another host, through `ssh -L`), and the panel lives exactly
as long as that command. Every request needs the run's token (traded once for a cookie), the
right Host, and for a write the right Origin and a header no plain form can send.

Titles, reports, log lines and inbox text are other people's or a model's words: they leave here
as JSON strings and the page inserts them as text, never as HTML.
"""

from __future__ import annotations

import contextlib
import hmac
import http.server
import json
import os
import re
import secrets
import socket
import socketserver
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from . import agent_disk, agent_inbox, agent_registry, core, jobs

STATIC = Path(__file__).with_name("panel")
FILES = {"/": ("index.html", "text/html; charset=utf-8"),
         "/panel.js": ("panel.js", "text/javascript; charset=utf-8"),
         "/panel.css": ("panel.css", "text/css; charset=utf-8")}
CSP = ("default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; "
       "base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
COOKIE = "ws_panel"
JOB_ACTIONS = ("tell", "interrupt", "cancel", "retry", "close")
INBOX_ACTIONS = ("accept", "dismiss")
_ID = re.compile(r"[0-9a-f]{6,16}")
LOG_TAIL = 400
BODY_MAX = 16_384
ACTION_TIMEOUT = 120
SERVE_STALE = 180        # seconds without a serve tick before the panel says so

# Whom a job waits for, by its stage: the first thing each row says.
WAITS = {"needs-you": "your answer", "delivered": "review or CI", "succeeded": "you, to apply or close it",
         "failed": "you, to retry or close it", "interrupted": "a retry", "waiting": "an engine's cooldown",
         "queued": "the engine", "running": "the engine", "unknown": "the queue"}
NEEDS = ("needs-you", "succeeded", "failed", "interrupted", "delivered")
ALLOWED = {"needs-you": ("tell", "cancel", "close"), "delivered": ("tell", "close"),
           "succeeded": ("tell", "close"), "failed": ("retry", "tell", "close"), "interrupted": ("retry", "cancel", "close"),
           "waiting": ("retry", "cancel"), "queued": ("tell", "cancel"), "running": ("tell", "interrupt", "cancel"),
           "unknown": ("cancel",), "cancelled": ("close",)}


def socket_path() -> Path:
    """The panel's socket: in the user's runtime directory (theirs alone, gone at logout), else in
    the state directory. The directory is 0700 either way."""
    run = os.environ.get("XDG_RUNTIME_DIR")
    base = Path(run) if run and os.path.isdir(run) else core.state_dir()
    return core.private_dir(base / "ws-agent") / "panel.sock"


# --- what the page reads ---------------------------------------------------------------------

def _stage(job: jobs.Job, state: str) -> str:
    from . import agent_publish
    return "delivered" if state == "succeeded" and agent_publish.published(job, "draft_pr") else state


def _row(job: jobs.Job, state: str) -> dict[str, object]:
    info = jobs.exit_info(job) or {}
    stage = _stage(job, state)
    return {"kind": "job", "id": job.id, "state": state, "stage": stage, "waits": WAITS.get(stage, ""),
            "checks": str(info.get("checks") or ""), "engine": job.engine, "title": job.title, "repo": job.repo,
            "created": job.created, "from_source": bool(job.origin), "actions": list(ALLOWED.get(stage, ()))}


def job_rows() -> list[dict[str, object]]:
    q = jobs.pueue_status()
    tasks = q.tasks if q else None
    return [_row(j, st) for j in jobs.all_jobs() if (st := jobs.state(j, tasks)) != "closed"]


def _inbox_row(it: agent_inbox.Item) -> dict[str, object]:
    c = it.candidate
    word = str((it.decision or {}).get("decision") or ("request" if c.get("explicit") else "open"))
    return {"kind": "inbox", "id": it.id, "state": word, "stage": "inbox", "waits": "you, to accept or dismiss it",
            "title": str(c.get("title") or ""), "repo": str(c.get("repo") or ""), "created": it.created,
            "source": str(c.get("source") or ""), "author": str(c.get("author") or ""),
            "reason": str((it.decision or {}).get("reason") or ""), "actions": list(INBOX_ACTIONS)}


def health() -> list[dict[str, str]]:
    """Only what is wrong or worth knowing: a healthy system returns nothing."""
    from . import agent_serve, agent_sources, engines
    out: list[dict[str, str]] = []
    st = agent_serve.status()
    tick = st.get("last_tick")
    if not st:
        out.append({"level": "bad", "text": "ws-agent serve has never run here: sources aren't read and nothing is published"})
    elif not isinstance(tick, (int, float)) or time.time() - float(tick) > SERVE_STALE:
        out.append({"level": "bad", "text": "ws-agent serve isn't ticking: sources aren't read and nothing is published"})
    elif st.get("last_error"):
        out.append({"level": "warn", "text": f"serve: {st.get('last_error')}"})
    q = jobs.pueue_status()
    if q is None:
        out.append({"level": "bad", "text": "the job queue (pueued) isn't running: no job starts"})
    elif q.group == "Paused":
        out.append({"level": "warn", "text": "the job queue is paused: nothing starts and nothing is published"})
    low = agent_disk.low()
    if low:
        out.append({"level": "warn", "text": f"disk is low ({low}): requests from sources wait in the inbox"})
    for key, src in sorted(agent_sources.source_state().items()):
        if isinstance(src, dict) and src.get("last_error"):
            out.append({"level": "warn", "text": f"{key}: {src.get('last_error')}"})
    for name in agent_registry.KNOWN_ENGINES:
        until = engines.cooling(name)
        if until:
            out.append({"level": "warn", "text": f"{name} is cooling down until {until} (usage limit)"})
    return out


def needs() -> dict[str, object]:
    from . import agent_publish
    rows: list[dict[str, object]] = []
    for r in job_rows():
        if r["stage"] in NEEDS:
            rows.append(r)
            job = jobs.load(str(r["id"]))
            if agent_publish.held_back(job):
                r["note"] = "a comment to its thread may not have been posted: look there, then ws-agent publish --seen"
            elif agent_publish.update_gave_up(job):
                r["note"] = "its update couldn't be pushed: ws-agent publish tries again"
    order = {s: n for n, s in enumerate(NEEDS)}
    rows.sort(key=lambda r: (order.get(str(r["stage"]), 9), str(r["created"])))
    inbox = [_inbox_row(it) for it in agent_inbox.items()]
    working = [r for r in job_rows() if r["stage"] not in NEEDS]
    return {"needs": inbox + rows, "working": working, "health": health(),
            "host": socket.gethostname(), "at": core.now_iso()}


def _text(job_id: str, *names: str, limit: int = 400_000) -> str:
    """A file of the job's directory, never through a link the job left there (jobs.result_bytes)."""
    return jobs.result_bytes(job_id, *names, limit=limit).decode("utf-8", "replace")


def history(what: str) -> list[dict[str, object]]:
    from . import agent_serve
    rows = agent_serve.decisions()
    if what:
        rows = [r for r in rows if what in (r.get("job"), r.get("item")) or what == r.get("cid")
                or (what.startswith("#") and str(r.get("thread") or "").rpartition("#")[1:] == ("#", what[1:]))]
    return rows[-200:]


def job_detail(job_id: str) -> dict[str, object] | None:
    from . import agent_publish
    try:
        job = jobs.load(job_id)
    except (KeyError, OSError, ValueError):
        return None
    q = jobs.pueue_status()
    info = jobs.exit_info(job) or {}
    published = {k: {"url": str(v.get("url") or ""), "at": str(v.get("at") or v.get("updated_at") or ""),
                     "pending": bool(v.get("attempting") and not v.get("url"))}
                 for k, v in agent_publish.record(job).items()}
    return {**_row(job, jobs.state(job, q.tasks if q else None)), "base": job.base, "attempts": job.attempts,
            "origin": job.origin, "report": jobs.result_json(job.id, "report.json"),
            "review": jobs.result_json(job.id, "review.json"), "review_verdict": str(info.get("review") or ""),
            "files": _text(job.id, "result", "manifest.txt", limit=20_000).splitlines(),
            "published": published,
            "thread": [{"from": str(m.get("from") or ""), "ts": str(m.get("ts") or ""), "text": str(m.get("text") or "")}
                       for m in jobs.thread(job)],
            "history": history(job.id)}


def inbox_detail(item_id: str) -> dict[str, object] | None:
    try:
        it = agent_inbox.get(item_id)
    except KeyError:
        return None
    c = it.candidate
    return {**_inbox_row(it), "url": str(c.get("url") or ""), "text": str(c.get("text") or ""),
            "decision": it.decision or {}, "status": it.status, "history": history(it.id)}


# --- what the page may do ----------------------------------------------------------------------

def run_cli(words: list[str]) -> tuple[int, str]:
    """One ws-agent command, as the person: (exit code, what it printed). A subprocess, as `ui`
    does it, so every action takes the locks and the checks the command line takes."""
    env = {k: v for k, v in os.environ.items() if k not in ("CLAUDECODE", "WS_AGENT_JOB")}
    ws = Path(__file__).resolve().parents[1] / "ws.py"
    try:
        r = subprocess.run([sys.executable, str(ws), "agent", *words], capture_output=True, text=True,
                           timeout=ACTION_TIMEOUT, env=env, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, f"ws-agent {words[0]}: {e}"
    return r.returncode, (r.stdout + r.stderr).strip()


def act(kind: str, ident: str, action: str, body: dict[str, object]) -> tuple[int, dict[str, object]]:
    """(HTTP status, answer) for one action. The verbs are fixed; the only free text is the
    person's own message, passed as one argument and never through a shell."""
    if not _ID.fullmatch(ident):
        return 404, {"error": "no such id"}
    if kind == "jobs" and action in JOB_ACTIONS:
        words = [action, ident]
        if action in ("tell", "interrupt"):
            text = str(body.get("text") or "").strip()
            if not text:
                return 400, {"error": "say what to tell it"}
            words.append(text)
    elif kind == "inbox" and action in INBOX_ACTIONS:
        words = [action, ident]
    else:
        return 404, {"error": "no such action"}
    code, out = run_cli(words)
    return (200 if code == 0 else 409), {"ok": code == 0, "code": code, "message": out}


# --- the server --------------------------------------------------------------------------------

class Panel:
    """One run: its token, and the addresses a browser may use for it."""

    def __init__(self, token: str, port: int) -> None:
        self.token = token
        self.hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
        self.origins = {f"http://{h}" for h in self.hosts}


class Handler(http.server.BaseHTTPRequestHandler):
    panel: Panel = Panel("", 0)   # each server's own, set by make_server
    server_version = "ws-agent-panel"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:   # noqa: A002 - the base class's name
        return   # nothing on stderr: paths carry ids, and the terminal belongs to `panel open`

    def address_string(self) -> str:
        return "local"

    # -- answers

    def _send(self, status: int, body: bytes, ctype: str, extra: dict[str, str] | None = None) -> None:
        self.send_response(status)
        for k, v in {"Content-Type": ctype, "Content-Length": str(len(body)), "Content-Security-Policy": CSP,
                     "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
                     "Cache-Control": "no-store", **(extra or {})}.items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status: int, data: object) -> None:
        self._send(status, json.dumps(data).encode("utf-8"), "application/json; charset=utf-8")

    def _text(self, status: int, text: str) -> None:
        self._send(status, text.encode("utf-8"), "text/plain; charset=utf-8")

    def _refuse(self, status: int, why: str) -> None:
        self._text(status, why + "\n")

    # -- who is asking

    def _cookie(self) -> str:
        for part in (self.headers.get("Cookie") or "").split(";"):
            name, _, value = part.strip().partition("=")
            if name == COOKIE:
                return value
        return ""

    def _allowed(self) -> bool:
        """The right Host (a page elsewhere that resolves to 127.0.0.1 has another), and the token."""
        if (self.headers.get("Host") or "") not in self.panel.hosts:
            self._refuse(403, "this panel answers only at the address `ws-agent panel open` printed")
            return False
        if not hmac.compare_digest(self._cookie().encode(), self.panel.token.encode()):
            self._refuse(403, "open the panel with the address `ws-agent panel open` printed (it carries this run's key)")
            return False
        return True

    # -- GET

    def do_GET(self) -> None:   # noqa: N802 - http.server's name
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == "/" and "t" in query:   # the printed address: trade its key for a cookie, once
            if (self.headers.get("Host") or "") not in self.panel.hosts or \
                    not hmac.compare_digest(query["t"][0].encode(), self.panel.token.encode()):
                self._refuse(403, "that key isn't this run's: use the address `ws-agent panel open` printed")
                return
            self._send(303, b"", "text/plain", {"Location": "/",
                                                 "Set-Cookie": f"{COOKIE}={self.panel.token}; HttpOnly; SameSite=Strict; Path=/"})
            return
        if not self._allowed():
            return
        if url.path in FILES:
            name, ctype = FILES[url.path]
            self._send(200, (STATIC / name).read_bytes(), ctype)
            return
        parts = [p for p in url.path.split("/") if p]
        if parts[:1] != ["api"]:
            self._refuse(404, "no such page")
            return
        route: Callable[[], object] | None = None
        if parts == ["api", "needs"]:
            route = needs
        elif parts == ["api", "jobs"]:
            route = job_rows
        elif parts == ["api", "history"]:
            route = lambda: history((query.get("what") or [""])[0])   # noqa: E731
        elif len(parts) == 3 and parts[1] == "jobs" and _ID.fullmatch(parts[2]):
            route = lambda: job_detail(parts[2])   # noqa: E731
        elif len(parts) == 3 and parts[1] == "inbox" and _ID.fullmatch(parts[2]):
            route = lambda: inbox_detail(parts[2])   # noqa: E731
        elif len(parts) == 4 and parts[1] == "jobs" and _ID.fullmatch(parts[2]) and parts[3] in ("diff", "log"):
            jd = jobs.job_dir(parts[2])
            if not (jd / "job.json").is_file():
                self._refuse(404, "no such job")
                return
            if parts[3] == "diff":
                self._text(200, _text(parts[2], "result", "changes.diff"))
            else:
                self._text(200, "\n".join(_text(parts[2], "exec.log").splitlines()[-LOG_TAIL:]) + "\n")
            return
        if route is None:
            self._refuse(404, "no such page")
            return
        try:
            data = route()
        except Exception as e:  # noqa: BLE001 - a broken record is an answer, not a dead panel
            self._json(500, {"error": f"{type(e).__name__}: {e}"})
            return
        if data is None:
            self._refuse(404, "no such item")
        else:
            self._json(200, data)

    do_HEAD = do_GET   # noqa: N815

    # -- POST

    def do_POST(self) -> None:   # noqa: N802
        if not self._allowed():
            return
        # A page elsewhere can make a browser send a POST here with the cookie; it can't set this
        # header or this content type without a preflight, and its Origin isn't ours.
        if (self.headers.get("Origin") or "") not in self.panel.origins or self.headers.get("X-WS-Panel") != "1" \
                or (self.headers.get("Content-Type") or "").split(";")[0].strip() != "application/json":
            self._refuse(403, "actions come from the panel's own page")
            return
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            length = -1
        if not 0 <= length <= BODY_MAX:
            self._refuse(413, "too much")
            return
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            body = None
        if not isinstance(body, dict):
            self._refuse(400, "the body is one JSON object")
            return
        parts = [p for p in urlsplit(self.path).path.split("/") if p]
        if len(parts) != 4 or parts[0] != "api" or parts[1] not in ("jobs", "inbox"):
            self._refuse(404, "no such action")
            return
        status, answer = act(parts[1], parts[2], parts[3], body)
        self._json(status, answer)

    def _no(self) -> None:
        self._refuse(405, "not here")

    do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _no   # noqa: N815


class _SocketServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = False

    def get_request(self) -> tuple[socket.socket, str]:
        conn, _ = self.socket.accept()
        return conn, "local"   # a Unix peer has no address; the handler wants something to name

    def handle_error(self, request: object, client_address: object) -> None:
        return   # a browser that went away mid-answer isn't worth a traceback on the person's terminal


def make_server(path: Path, token: str, port: int) -> _SocketServer:
    """The panel on a Unix socket only its owner can connect to. A stale socket from a run that
    died is replaced; one a live panel holds is left alone."""
    core.private_dir(path.parent)
    if len(os.fsencode(path)) > 100:   # sun_path holds about 107 bytes
        raise OSError(f"the socket's path is too long for a Unix socket ({path}); set XDG_RUNTIME_DIR to a short directory")
    if path.exists() or path.is_symlink():
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(str(path))
        except OSError:
            path.unlink()
        else:
            raise OSError(f"a panel is already open on this host ({path})")
        finally:
            probe.close()
    handler = type("PanelHandler", (Handler,), {"panel": Panel(token, port)})
    old = os.umask(0o177)
    try:
        return _SocketServer(str(path), handler)
    finally:
        os.umask(old)


# --- reaching it from a browser ------------------------------------------------------------------

def _pipe(a: socket.socket, b: socket.socket) -> None:
    with contextlib.suppress(OSError):
        while data := a.recv(65536):
            b.sendall(data)
    for s in (a, b):
        with contextlib.suppress(OSError):
            s.shutdown(socket.SHUT_RDWR)


def relay(listener: socket.socket, path: Path) -> None:
    """127.0.0.1:<port> to the socket, byte for byte, until the listener closes."""
    while True:
        try:
            conn, _ = listener.accept()
        except OSError:
            return
        up = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            up.connect(str(path))
        except OSError:
            conn.close()
            up.close()
            continue
        for a, b in ((conn, up), (up, conn)):
            threading.Thread(target=_pipe, args=(a, b), daemon=True).start()


def listen_local(port: int = 0) -> socket.socket:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))   # this machine only, whatever the port
    s.listen(16)
    return s


def serve_stdin() -> int:
    """`ws-agent panel serve`: what `panel open <host>` runs over SSH. It reads the run's key and
    the browser's port from stdin (never from the command line, where other users could read
    them), serves on the socket, and ends when stdin closes: with the SSH session."""
    try:
        token, port = sys.stdin.readline().strip(), int(sys.stdin.readline().strip())
    except ValueError:
        print("ws-agent panel serve: expected the key and the port on stdin", file=sys.stderr)
        return 2
    if len(token) < 32:
        print("ws-agent panel serve: expected the key and the port on stdin", file=sys.stderr)
        return 2
    path = socket_path()
    try:
        srv = make_server(path, token, port)
    except OSError as e:
        print(f"ws-agent panel: {e}", file=sys.stderr)
        return 1
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f"ready {path}", flush=True)
    with contextlib.suppress(OSError, KeyboardInterrupt):
        while sys.stdin.readline():
            pass
    srv.shutdown()
    with contextlib.suppress(OSError):
        path.unlink()
    return 0


def open_local(port: int) -> int:
    token = secrets.token_urlsafe(32)
    try:
        listener = listen_local(port)
    except OSError as e:
        print(f"ws-agent panel: can't listen on 127.0.0.1:{port}: {e}", file=sys.stderr)
        return 1
    port = listener.getsockname()[1]
    path = socket_path()
    try:
        srv = make_server(path, token, port)
    except OSError as e:
        listener.close()
        print(f"ws-agent panel: {e}", file=sys.stderr)
        return 1
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    threading.Thread(target=relay, args=(listener, path), daemon=True).start()
    print(f"panel for {socket.gethostname()}: http://127.0.0.1:{port}/?t={token}")
    print("It is open while this command runs (ctrl-c closes it). The address carries this run's key.", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        print()
    finally:
        listener.close()
        srv.shutdown()
        with contextlib.suppress(OSError):
            path.unlink()
    return 0


def open_remote(host: str, port: int) -> int:
    """Another host's panel: its own `ws-agent panel serve` on its own socket, reached through
    `ssh -L` from a port on this machine. Nothing is installed or left running there."""
    import shlex
    if not agent_registry.HOST.match(host) or host not in agent_registry.settings().fleet:
        print(f"ws-agent panel: {host} isn't one of your fleet hosts (ws-agent fleet add {host}, in your own terminal)",
              file=sys.stderr)
        return 3
    token = secrets.token_urlsafe(32)
    with contextlib.closing(listen_local(port)) as probe:   # find a free port, then hand it to ssh
        port = probe.getsockname()[1]
    ask = subprocess.run(["ssh", "-o", "BatchMode=yes", "--", host, "bash -lc " + shlex.quote("ws-agent panel path")],
                         capture_output=True, text=True, timeout=60)
    remote = ask.stdout.strip().splitlines()[-1] if ask.returncode == 0 and ask.stdout.strip() else ""
    if not remote.startswith("/") or not re.fullmatch(r"[\w./@+-]+", remote):
        print(f"ws-agent panel: {host} didn't say where its panel listens: "
              f"{agent_inbox.printable(ask.stderr.strip() or ask.stdout.strip())[:300]}", file=sys.stderr)
        return 1
    proc = subprocess.Popen(["ssh", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                             "-L", f"127.0.0.1:{port}:{remote}", "--", host,
                             "bash -lc " + shlex.quote("ws-agent panel serve")],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    assert proc.stdin is not None and proc.stdout is not None
    proc.stdin.write(f"{token}\n{port}\n")
    proc.stdin.flush()
    first = proc.stdout.readline().strip()
    if not first.startswith("ready "):
        proc.terminate()
        print(f"ws-agent panel: {host}'s panel didn't start: {agent_inbox.printable(first)[:300]}", file=sys.stderr)
        return 1
    print(f"panel for {host}: http://127.0.0.1:{port}/?t={token}")
    print("It is open while this command runs (ctrl-c closes it, and the panel on that host with it).", flush=True)
    try:
        proc.wait()
    except KeyboardInterrupt:
        print()
    finally:
        with contextlib.suppress(OSError):
            proc.stdin.close()      # the remote panel ends when its stdin does
        with contextlib.suppress(subprocess.TimeoutExpired):
            proc.wait(timeout=5)
        if proc.poll() is None:
            proc.terminate()
    return 0
