"""wslib.agent_panel: the web panel. It answers on a Unix socket only, to a browser that has the
run's key and comes from the address `panel open` printed; it can do what `ws-agent ui` does and
has no route for anything else; and what other people or a model wrote leaves it as JSON text."""

from __future__ import annotations

import http.client
import json
import os
import socket
import stat
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from agent_helpers import AgentScratch

from wslib import agent, agent_inbox, agent_serve, core, jobs
from wslib import agent_panel as panel

TOKEN = "k" * 43
PORT = 45123
HOST = f"127.0.0.1:{PORT}"
EVIL = '<img src=x onerror="alert(1)"> </script><script>alert(2)</script>'


class PanelScratch(AgentScratch):
    def setUp(self) -> None:
        super().setUp()
        os.environ["XDG_RUNTIME_DIR"] = str(self.root / "run")
        (self.root / "run").mkdir(mode=0o700)
        self.pueue_status({})
        self.path = panel.socket_path()
        self.srv = panel.make_server(self.path, TOKEN, PORT)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)

    def ask(self, method: str, url: str, *, cookie: str | None = TOKEN, host: str = HOST, body: object = None,
            headers: dict[str, str] | None = None) -> tuple[int, dict[str, str], bytes]:
        h = {"Host": host, **({"X-WS-Key": cookie} if cookie else {}), **(headers or {})}
        data = b"" if body is None else json.dumps(body).encode()
        if body is not None:
            h["Content-Length"] = str(len(data))
        head = f"{method} {url} HTTP/1.1\r\n" + "".join(f"{k}: {v}\r\n" for k, v in h.items()) + "\r\n"
        # One write for the whole request. A refusal ends the connection without reading the body,
        # so http.client's two writes (headers, then body) could meet a closed socket: EPIPE.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(10)
            s.connect(str(self.path))
            s.sendall(head.encode() + data)
            with http.client.HTTPResponse(s, method=method) as r:
                r.begin()
                return r.status, {k.lower(): v for k, v in r.getheaders()}, r.read()

    def post(self, url: str, body: object = None, **kw: object) -> tuple[int, dict[str, str], bytes]:
        headers = {"Origin": f"http://{HOST}", "X-WS-Panel": "1", "Content-Type": "application/json"}
        headers.update(kw.pop("headers", {}))  # type: ignore[arg-type]
        return self.ask("POST", url, body=body if body is not None else {}, headers=headers, **kw)  # type: ignore[arg-type]

    def job(self, title: str = "the thing", *, status: str = "question", exit_code: int = 0) -> jobs.Job:
        j = jobs.Job(id=jobs.new_id(), title=title, repo="~/src/proj", vcs="git", base={}, prompt_sha=f"s{time.time_ns()}",
                     paths=[], created=core.now_iso(), session_id="", timeout="2h", engine="claude")
        jobs.save(j)
        res = jobs.job_dir(j.id) / "result"
        self.write(res / "exit.json", json.dumps({"exit_code": exit_code, "status": status, "kind": "ok", "checks": "pass"}))
        self.write(res / "report.json", json.dumps({"status": status, "summary": EVIL, "question": "Which one?"}))
        self.write(res / "changes.diff", "diff --git a/a b/a\n+<b>x</b>\n")
        self.write(jobs.job_dir(j.id) / "exec.log", "line 1\n</pre><script>alert(3)</script>\n")
        return j


class Access(PanelScratch):
    def test_it_listens_on_a_socket_only_its_owner_can_reach(self) -> None:
        self.assertTrue(stat.S_ISSOCK(self.path.stat().st_mode))
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode) & 0o077, 0)
        self.assertEqual(stat.S_IMODE(self.path.parent.stat().st_mode), 0o700)
        self.assertTrue(str(self.path).startswith(str(self.root / "run")))

    def test_nothing_of_the_persons_answers_without_this_runs_key(self) -> None:
        for url in ("/api/needs", "/api/jobs", "/api/history"):
            self.assertEqual(self.ask("GET", url, cookie=None)[0], 403, url)
            self.assertEqual(self.ask("GET", url, cookie="x" * 43)[0], 403, url)
            self.assertEqual(self.ask("GET", url, cookie=None, headers={"Cookie": f"ws_panel={TOKEN}"})[0], 403, url)
        self.assertEqual(self.post("/api/jobs/abc123/cancel", cookie=None)[0], 403)

    def test_the_key_is_never_a_cookie_and_never_reaches_the_server_in_an_address(self) -> None:
        # a cookie goes to every service on 127.0.0.1, whatever its port; the page keeps the key in
        # its own storage (per port) and sends it as a header
        for url in ("/", "/panel.js", "/panel.css"):
            status, headers, body = self.ask("GET", url, cookie=None)   # the page itself holds nothing of the person's
            self.assertEqual(status, 200, url)
            self.assertNotIn("set-cookie", headers)
            self.assertNotIn(TOKEN.encode(), body)
        script = (panel.STATIC / "panel.js").read_text()
        self.assertIn("sessionStorage", script)
        self.assertNotIn("document.cookie", script)
        self.assertEqual(self.ask("GET", f"/?t={TOKEN}", cookie=None)[1].get("set-cookie"), None)

    def test_a_refused_request_ends_its_connection(self) -> None:
        # Otherwise the body of a refused request is read as the next request on the same connection,
        # and a page on another local port could ride in on the person's own next poll.
        j = self.job()
        smuggled = (f"POST /api/jobs/{j.id}/cancel HTTP/1.1\r\nHost: {HOST}\r\nOrigin: http://{HOST}\r\n"
                    f"X-WS-Panel: 1\r\nX-WS-Key: {TOKEN}\r\nContent-Type: application/json\r\nContent-Length: 0\r\nX: ")
        with mock.patch.object(panel, "run_cli", return_value=(0, "cancelled")) as cli:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(str(self.path))
            s.sendall(f"POST /api/jobs/{j.id}/cancel HTTP/1.1\r\nHost: {HOST}\r\nContent-Type: text/plain\r\n"
                      f"Content-Length: {len(smuggled)}\r\n\r\n{smuggled}".encode())
            s.sendall(f"GET /api/needs HTTP/1.1\r\nHost: {HOST}\r\nX-WS-Key: {TOKEN}\r\n\r\n".encode())
            s.settimeout(5)
            data = b""
            try:
                while chunk := s.recv(65536):
                    data += chunk
            except OSError:
                pass
            s.close()
            cli.assert_not_called()
        self.assertTrue(data.startswith(b"HTTP/1.1 403"), data[:60])
        self.assertEqual(data.count(b"HTTP/1.1 "), 1)   # one answer, then the connection is over
        self.assertEqual(self.ask("POST", "/api/needs", headers={"Transfer-Encoding": "chunked"})[0], 400)

    def test_another_host_name_is_refused(self) -> None:
        # a page elsewhere whose name resolves to 127.0.0.1 reaches the port with its own Host
        for host in ("evil.example:45123", "127.0.0.1:1", "127.0.0.1"):
            self.assertEqual(self.ask("GET", "/api/needs", host=host)[0], 403, host)
            self.assertEqual(self.ask("GET", "/", cookie=None, host=host)[0], 403, host)

    def test_a_write_must_come_from_the_panels_own_page(self) -> None:
        j = self.job()
        with mock.patch.object(panel, "run_cli", return_value=(0, "cancelled")) as cli:
            for bad in ({"Origin": "http://evil.example"}, {"Origin": ""}, {"X-WS-Panel": ""},
                        {"Content-Type": "text/plain"}, {"Content-Type": "application/x-www-form-urlencoded"}):
                self.assertEqual(self.post(f"/api/jobs/{j.id}/cancel", headers=bad)[0], 403, bad)
            cli.assert_not_called()
            self.assertEqual(self.post(f"/api/jobs/{j.id}/cancel")[0], 200)
            cli.assert_called_once_with(["cancel", j.id])

    def test_every_answer_forbids_inline_script_and_foreign_content(self) -> None:
        for url in ("/", "/panel.js", "/api/needs"):
            _, headers, _ = self.ask("GET", url)
            self.assertIn("default-src 'none'", headers["content-security-policy"])
            self.assertIn("script-src 'self'", headers["content-security-policy"])
            self.assertEqual(headers["x-content-type-options"], "nosniff")
        page = (panel.STATIC / "index.html").read_text()
        self.assertNotRegex(page, r"(?i)<script(?![^>]*\bsrc=)|\son\w+=|javascript:|https?://")
        script = (panel.STATIC / "panel.js").read_text()
        self.assertNotRegex(script, r"innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\(|https?://(?!github)")


class Reads(PanelScratch):
    def test_what_waits_for_whom(self) -> None:
        asking, failed = self.job("asks"), self.job("broke", status="failed", exit_code=1)
        item = agent_inbox.add(agent_inbox.Candidate(cid="gh:a/b:i1", source="github", repo="~/src/proj", explicit=False,
                                                     author="ArrushC", title="An issue", text="words", base={}, prompt="p"),
                               {"decision": "ask", "reason": "not sure", "rule": None})
        status, headers, body = self.ask("GET", "/api/needs")
        self.assertEqual((status, headers["content-type"]), (200, "application/json; charset=utf-8"))
        data = json.loads(body)
        rows = {r["id"]: r for r in data["needs"]}
        self.assertEqual(rows[asking.id]["waits"], "your answer")
        self.assertIn("tell", rows[asking.id]["actions"])
        self.assertIn("retry", rows[failed.id]["actions"])
        self.assertEqual((rows[item.id]["kind"], rows[item.id]["actions"]), ("inbox", ["accept", "dismiss"]))
        self.assertEqual(data["needs"][0]["id"], item.id)   # the inbox first, then questions
        self.assertTrue(any("serve" in h["text"] for h in data["health"]))   # serve has never run here

    def test_a_healthy_system_says_nothing(self) -> None:
        self.write(agent_serve._dir() / "status.json", json.dumps({"pid": os.getpid(), "last_tick": time.time(), "last_error": ""}))
        self.assertEqual(json.loads(self.ask("GET", "/api/needs")[2])["health"], [])

    def test_other_peoples_words_leave_as_text_never_as_markup(self) -> None:
        j = self.job(EVIL)
        status, headers, body = self.ask("GET", f"/api/jobs/{j.id}")
        self.assertEqual((status, headers["content-type"]), (200, "application/json; charset=utf-8"))
        d = json.loads(body)
        self.assertEqual((d["title"], d["report"]["summary"], d["report"]["question"]), (EVIL, EVIL, "Which one?"))
        for part in ("diff", "log"):
            status, headers, body = self.ask("GET", f"/api/jobs/{j.id}/{part}")
            self.assertEqual((status, headers["content-type"]), (200, "text/plain; charset=utf-8"), part)
        self.assertIn(b"<script>alert(3)</script>", body)   # as plain text, with nosniff: never a page

    def test_a_result_file_swapped_for_a_link_is_never_served(self) -> None:
        j = self.job()
        secret = self.write(self.root / "id_ed25519", "TOPSECRET\n")
        note = self.write(self.root / "private.json", json.dumps({"summary": "TOPSECRET"}))
        res = jobs.job_dir(j.id) / "result"
        for name, target in (("changes.diff", secret), ("manifest.txt", secret), ("report.json", note)):
            (res / name).unlink(missing_ok=True)
            (res / name).symlink_to(target)
        log = jobs.job_dir(j.id) / "exec.log"
        log.unlink()
        log.symlink_to(secret)
        seen = b"".join(self.ask("GET", f"/api/jobs/{j.id}{part}")[2] for part in ("", "/diff", "/log"))
        self.assertNotIn(b"TOPSECRET", seen)

    def test_one_damaged_job_record_doesnt_blind_the_panel(self) -> None:
        good, bad = self.job("fine"), self.job("broken")
        rec = jobs.job_dir(bad.id) / "job.json"   # writable from inside that job's sandbox
        rec.write_text(json.dumps({**json.loads(rec.read_text()), "id": "../../etc"}))
        status, _, body = self.ask("GET", "/api/needs")
        self.assertEqual(status, 200, body[:200])
        self.assertEqual([r["id"] for r in json.loads(body)["needs"]], [good.id])
        self.assertEqual(self.ask("GET", f"/api/jobs/{bad.id}")[0], 404)

    def test_unknown_things_are_not_found(self) -> None:
        for url in ("/api/jobs/zzzzzz", "/api/jobs/abc123", "/api/inbox/abc123", "/api/jobs/abc123/diff",
                    "/api/nothing", "/etc/passwd", "/api/jobs/../../x", "/panel.py"):
            self.assertEqual(self.ask("GET", url)[0], 404, url)


class Actions(PanelScratch):
    def test_each_action_is_the_command_the_person_would_type(self) -> None:
        j = self.job()
        with mock.patch.object(panel, "run_cli", return_value=(0, "ok")) as cli:
            self.assertEqual(self.post(f"/api/jobs/{j.id}/tell", {"text": "the old one; rm -rf ~"})[0], 200)
            cli.assert_called_with(["tell", j.id, "--", "the old one; rm -rf ~"])   # one argument, never a shell's
            self.assertEqual(self.post(f"/api/jobs/{j.id}/tell", {"text": "  "})[0], 400)
            self.assertEqual(self.post(f"/api/jobs/{j.id}/tell", {"text": "a\x00b"})[0], 400)
            self.post(f"/api/jobs/{j.id}/tell", {"text": "--help"})
            cli.assert_called_with(["tell", j.id, "--", "--help"])                  # words, never an option
            for action in ("interrupt",):
                self.post(f"/api/jobs/{j.id}/{action}", {"text": "stop"})
                cli.assert_called_with([action, j.id, "--", "stop"])
            for action in ("cancel", "retry", "close"):
                self.post(f"/api/jobs/{j.id}/{action}")
                cli.assert_called_with([action, j.id])
            for action in ("accept", "dismiss"):
                self.post(f"/api/inbox/abcdef0123/{action}")
                cli.assert_called_with([action, "abcdef0123"])

    def test_a_refusal_is_shown_not_hidden(self) -> None:
        j = self.job()
        with mock.patch.object(panel, "run_cli", return_value=(3, "ws-agent: nothing to cancel")):
            status, _, body = self.post(f"/api/jobs/{j.id}/cancel")
        self.assertEqual((status, json.loads(body)), (409, {"ok": False, "code": 3, "message": "ws-agent: nothing to cancel"}))

    def test_there_is_no_way_to_start_work_widen_access_or_publish(self) -> None:
        j = self.job()
        with mock.patch.object(panel, "run_cli", return_value=(0, "ok")) as cli:
            for url in (f"/api/jobs/{j.id}/publish", f"/api/jobs/{j.id}/run", "/api/run", "/api/allow", "/api/repos/x/allow",
                        f"/api/jobs/{j.id}/publish-to", "/api/jobs/--help/cancel", f"/api/jobs/{j.id};id/cancel",
                        "/api/inbox/abcdef/tell", "/api/fleet/add", f"/api/jobs/{j.id}/answer"):
                self.assertEqual(self.post(url, {"text": "x"})[0], 404, url)
            for method in ("PUT", "DELETE", "PATCH"):
                self.assertEqual(self.ask(method, f"/api/jobs/{j.id}")[0], 405, method)
            cli.assert_not_called()

    def test_run_cli_is_a_plain_ws_agent_command_outside_any_session(self) -> None:
        os.environ["CLAUDECODE"] = "1"
        code, out = panel.run_cli(["ls", "--all"])
        self.assertEqual(code, 0, out)


class Opening(PanelScratch):
    def test_a_second_panel_on_the_host_is_refused_and_a_dead_ones_socket_replaced(self) -> None:
        with self.assertRaises(OSError):
            panel.make_server(self.path, TOKEN, PORT)
        self.srv.shutdown()
        self.srv.server_close()   # died without removing its socket
        again = panel.make_server(self.path, TOKEN, PORT)
        again.server_close()

    def test_the_relay_reaches_the_socket_from_this_machine_only(self) -> None:
        listener = panel.listen_local(0)
        self.addCleanup(listener.close)
        host, port = listener.getsockname()
        self.assertEqual(host, "127.0.0.1")
        threading.Thread(target=panel.relay, args=(listener, self.path), daemon=True).start()
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        c.request("GET", "/api/needs", headers={"Host": HOST, "X-WS-Key": TOKEN})
        self.assertEqual(c.getresponse().status, 200)
        c.close()

    def test_another_users_connection_to_the_local_port_is_refused(self) -> None:
        self.assertTrue(panel.peer_allowed(os.getuid(), wsl=False))
        self.assertFalse(panel.peer_allowed(os.getuid() + 1, wsl=False))
        self.assertFalse(panel.peer_allowed(os.getuid() + 1, wsl=True))
        self.assertFalse(panel.peer_allowed(None, wsl=False))    # a peer Linux can't name isn't one of ours
        self.assertTrue(panel.peer_allowed(None, wsl=True))      # the Windows browser, through WSL's own relay
        listener = panel.listen_local(0)
        self.addCleanup(listener.close)
        c = socket.create_connection(listener.getsockname(), timeout=5)
        conn, addr = listener.accept()
        self.assertEqual(panel.peer_uid(addr[1], listener.getsockname()[1]), os.getuid())
        c.close()
        conn.close()

    def test_the_socket_goes_only_where_no_one_else_can_put_a_link(self) -> None:
        shared = self.root / "shared"
        shared.mkdir(mode=0o777)
        os.chmod(shared, 0o777)
        os.environ["XDG_RUNTIME_DIR"] = str(shared)             # not ours alone: not used
        self.assertFalse(str(panel.socket_path()).startswith(str(shared)))
        os.environ["XDG_RUNTIME_DIR"] = str(self.root / "run")
        mine = self.root / "run" / "ws-agent"
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        self.srv.shutdown()
        self.srv.server_close()
        for f in mine.iterdir():
            f.unlink()
        mine.rmdir()
        mine.symlink_to(elsewhere, target_is_directory=True)    # planted before the panel first ran
        with self.assertRaises(OSError):
            panel.socket_path()

    def test_the_panel_is_the_persons_to_open(self) -> None:
        os.environ["CLAUDECODE"] = "1"
        self.assertEqual(agent.main(["panel", "open"]), 3)
        self.assertEqual(agent.main(["panel", "serve"]), 3)
        self.assertEqual(agent.main(["panel", "path"]), 0)

    def test_another_hosts_panel_only_for_a_fleet_host(self) -> None:
        self.assertEqual(panel.open_remote("not-in-my-fleet", 0), 3)
        self.assertEqual(panel.open_remote("-oProxyCommand=x", 0), 3)


if __name__ == "__main__":
    unittest.main()
