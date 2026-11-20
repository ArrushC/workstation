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


class _Conn(http.client.HTTPConnection):
    def __init__(self, path: Path) -> None:
        super().__init__("localhost")
        self._path = path

    def connect(self) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(str(self._path))


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
        c = _Conn(self.path)
        h = {"Host": host, **({"Cookie": f"{panel.COOKIE}={cookie}"} if cookie else {}), **(headers or {})}
        data = None if body is None else json.dumps(body).encode()
        c.request(method, url, body=data, headers=h)
        r = c.getresponse()
        out = (r.status, {k.lower(): v for k, v in r.getheaders()}, r.read())
        c.close()
        return out

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

    def test_nothing_answers_without_this_runs_key(self) -> None:
        for url in ("/", "/panel.js", "/api/needs", "/api/jobs"):
            self.assertEqual(self.ask("GET", url, cookie=None)[0], 403, url)
            self.assertEqual(self.ask("GET", url, cookie="x" * 43)[0], 403, url)
        self.assertEqual(self.post("/api/jobs/abc123/cancel", cookie=None)[0], 403)

    def test_the_printed_address_trades_its_key_for_a_cookie_once(self) -> None:
        status, headers, _ = self.ask("GET", f"/?t={TOKEN}", cookie=None)
        self.assertEqual((status, headers["location"]), (303, "/"))
        cookie = headers["set-cookie"]
        self.assertIn(f"{panel.COOKIE}={TOKEN}", cookie)
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)
        self.assertEqual(self.ask("GET", "/?t=" + "w" * 43, cookie=None)[0], 403)
        self.assertEqual(self.ask("GET", "/")[0], 200)

    def test_another_host_name_is_refused(self) -> None:
        # a page elsewhere whose name resolves to 127.0.0.1 reaches the port with its own Host
        for host in ("evil.example:45123", "127.0.0.1:1", "127.0.0.1"):
            self.assertEqual(self.ask("GET", "/api/needs", host=host)[0], 403, host)
            self.assertEqual(self.ask("GET", f"/?t={TOKEN}", cookie=None, host=host)[0], 403, host)

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

    def test_unknown_things_are_not_found(self) -> None:
        for url in ("/api/jobs/zzzzzz", "/api/jobs/abc123", "/api/inbox/abc123", "/api/jobs/abc123/diff",
                    "/api/nothing", "/etc/passwd", "/api/jobs/../../x", "/panel.py"):
            self.assertEqual(self.ask("GET", url)[0], 404, url)


class Actions(PanelScratch):
    def test_each_action_is_the_command_the_person_would_type(self) -> None:
        j = self.job()
        with mock.patch.object(panel, "run_cli", return_value=(0, "ok")) as cli:
            self.assertEqual(self.post(f"/api/jobs/{j.id}/tell", {"text": "the old one; rm -rf ~"})[0], 200)
            cli.assert_called_with(["tell", j.id, "the old one; rm -rf ~"])   # one argument, never a shell's
            self.assertEqual(self.post(f"/api/jobs/{j.id}/tell", {"text": "  "})[0], 400)
            for action in ("interrupt",):
                self.post(f"/api/jobs/{j.id}/{action}", {"text": "stop"})
                cli.assert_called_with([action, j.id, "stop"])
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
        c.request("GET", "/api/needs", headers={"Host": HOST, "Cookie": f"{panel.COOKIE}={TOKEN}"})
        self.assertEqual(c.getresponse().status, 200)
        c.close()

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
