"""wslib.engines: Claude Code and Codex behind one interface. Command lines that confine each
engine, a structured report from both, failures classified (transient, usage limit, auth),
and the choice of engine per attempt: allowed, available, not cooling down."""

from __future__ import annotations

import json
import os
import shutil
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from agent_helpers import AgentScratch
from helpers import WS

from wslib import agent_registry as reg
from wslib import agent_sandbox, engines, jobs

FIX = WS / "tests" / "fixtures"


def _job() -> jobs.Job:
    return jobs.Job(id="abc123", title="the thing", repo="~/src/p", vcs="svn", base={}, prompt_sha="s", paths=[],
                    created="x", session_id="S-1", timeout="2h")


class Engines(AgentScratch):
    def setUp(self) -> None:
        super().setUp()
        self.adir = self.root / "attempt"
        self.adir.mkdir()
        self.wc = self.root / "wc"
        self.wc.mkdir()
        self.c = engines.Confinement(wc=self.wc, network=False, commands=("make *",), instructions="RULES",
                                     read_dirs=(self.root / "input",))
        self.fake("claude", 'echo \'{"loggedIn": true, "authMethod": "claude.ai"}\'')
        self.fake("codex", 'echo "Logged in using ChatGPT"')
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(agent_sandbox, "probe", return_value=None).start()

    def out(self, text: str) -> None:
        (self.adir / "stdout").write_text(text, encoding="utf-8")


class Argv(Engines):
    def test_claude_argv_has_schema_sandbox_and_confinement(self) -> None:
        argv = engines.ENGINES["claude"].argv(_job(), self.adir, resume=None, c=self.c, model="")
        settings = json.loads(argv[argv.index("--settings") + 1])
        self.assertIs(settings["permissions"]["blockWritesOutsideWorkingDirectories"], True)
        sb = settings["sandbox"]
        self.assertIs(sb["enabled"], True)
        self.assertIs(sb["failIfUnavailable"], True)
        self.assertIs(sb["allowUnsandboxedCommands"], False)
        self.assertEqual(sb["filesystem"]["allowWrite"], [str(self.wc)])
        self.assertIn(str(self.home / ".claude" / ".credentials.json"), sb["filesystem"]["denyRead"])
        self.assertEqual(sb["network"]["allowedDomains"], [])
        self.assertEqual(json.loads(argv[argv.index("--json-schema") + 1]), engines.REPORT_SCHEMA)
        self.assertEqual(argv[argv.index("--session-id") + 1], "S-1")
        self.assertEqual(argv[argv.index("--append-system-prompt") + 1], "RULES")
        self.assertEqual(argv[argv.index("--add-dir") + 1], str(self.root / "input"))
        rules = argv[argv.index("--allowedTools") + 1:]
        self.assertIn("Bash(make *)", rules)
        self.assertNotIn("Edit", rules)
        self.assertNotIn("Write", rules)
        self.assertNotIn("--model", argv)
        resumed = engines.ENGINES["claude"].argv(_job(), self.adir, resume="S-1", c=self.c, model="opus")
        self.assertEqual(resumed[resumed.index("--resume") + 1], "S-1")
        self.assertNotIn("--session-id", resumed)
        self.assertEqual(resumed[resumed.index("--model") + 1], "opus")

    def test_claude_network_on_leaves_the_sandbox_network_open(self) -> None:
        c = engines.Confinement(wc=self.wc, network=True, commands=(), instructions="R")
        argv = engines.ENGINES["claude"].argv(_job(), self.adir, resume=None, c=c, model="")
        self.assertNotIn("network", json.loads(argv[argv.index("--settings") + 1])["sandbox"])

    def test_codex_argv_and_resume_argv(self) -> None:
        codex = engines.ENGINES["codex"]
        argv = codex.argv(_job(), self.adir, resume=None, c=self.c, model="")
        for flag in ("--json", "--skip-git-repo-check", "--ignore-rules", "--ignore-user-config"):
            self.assertIn(flag, argv)
        self.assertEqual(argv[1], "exec")
        self.assertEqual(argv[argv.index("-s") + 1], "workspace-write")
        self.assertEqual(argv[argv.index("-C") + 1], str(self.wc))
        self.assertEqual(argv[argv.index("-o") + 1], str(self.adir / "last.json"))
        self.assertEqual(json.loads((self.adir / "schema.json").read_text()), engines.REPORT_SCHEMA)
        configs = [argv[i + 1] for i, a in enumerate(argv) if a == "-c"]
        self.assertIn('approval_policy="never"', configs)
        self.assertIn("sandbox_workspace_write.network_access=false", configs)
        self.assertIn('developer_instructions="RULES"', configs)
        self.assertEqual(argv[-1], "-")   # the prompt comes on stdin
        self.assertNotIn("--add-dir", argv)   # --add-dir grants writes; reads need nothing
        resumed = codex.argv(_job(), self.adir, resume="T-1", c=self.c, model="o4")
        self.assertEqual(resumed[1:4], ["exec", "resume", "T-1"])
        self.assertNotIn("-s", resumed)
        self.assertNotIn("-C", resumed)
        rc = [resumed[i + 1] for i, a in enumerate(resumed) if a == "-c"]
        self.assertIn('sandbox_mode="workspace-write"', rc)
        self.assertIn("sandbox_workspace_write.network_access=false", rc)
        self.assertEqual(resumed[resumed.index("-m") + 1], "o4")
        self.assertEqual(resumed[-1], "-")

    def test_each_engine_drops_the_other_providers_credentials(self) -> None:
        base = {"PATH": "/usr/bin", "CLAUDE_CODE_OAUTH_TOKEN": "c", "ANTHROPIC_API_KEY": "a", "OPENAI_API_KEY": "o",
                "CODEX_API_KEY": "x"}
        claude_env = engines.ENGINES["claude"].env(base)
        self.assertEqual((claude_env.get("CLAUDE_CODE_OAUTH_TOKEN"), claude_env.get("ANTHROPIC_API_KEY")), ("c", "a"))
        self.assertNotIn("OPENAI_API_KEY", claude_env)
        self.assertNotIn("CODEX_API_KEY", claude_env)
        codex_env = engines.ENGINES["codex"].env(base)
        self.assertEqual(codex_env.get("OPENAI_API_KEY"), "o")
        self.assertNotIn("CLAUDE_CODE_OAUTH_TOKEN", codex_env)
        self.assertNotIn("ANTHROPIC_API_KEY", codex_env)

    def test_read_only_runs(self) -> None:
        c = engines.Confinement(wc=self.wc, network=False, commands=("make *",), instructions="R", read_only=True,
                                schema=engines.REVIEW_SCHEMA)
        argv = engines.ENGINES["claude"].argv(_job(), self.adir, resume=None, c=c, model="")
        self.assertEqual(argv[argv.index("--permission-mode") + 1], "default")   # edits need approval: none comes
        self.assertEqual(argv[argv.index("--allowedTools") + 1:], ["Read", "Glob", "Grep"])
        self.assertEqual(json.loads(argv[argv.index("--json-schema") + 1]), engines.REVIEW_SCHEMA)
        self.assertEqual(json.loads(argv[argv.index("--settings") + 1])["sandbox"]["filesystem"]["allowWrite"], [])
        cx = engines.ENGINES["codex"].argv(_job(), self.adir, resume=None, c=c, model="")
        self.assertEqual(cx[cx.index("-s") + 1], "read-only")
        self.assertEqual(json.loads((self.adir / "schema.json").read_text()), engines.REVIEW_SCHEMA)

    def test_conform(self) -> None:
        self.assertEqual(engines.conform({"status": "done", "summary": "s"}, engines.REPORT_SCHEMA),
                         {"status": "done", "summary": "s", "question": None, "tests": None, "notes": None})
        self.assertIsNone(engines.conform({"status": "maybe", "summary": "s"}, engines.REPORT_SCHEMA))
        self.assertIsNone(engines.conform({"summary": "s"}, engines.REPORT_SCHEMA))
        self.assertIsNone(engines.conform("not json", engines.REPORT_SCHEMA))
        review = {"verdict": "ok", "summary": "fine", "findings": []}
        self.assertEqual(engines.conform(json.dumps(review), engines.REVIEW_SCHEMA), review)
        self.assertIsNone(engines.conform({"verdict": "ok", "summary": "x"}, engines.REVIEW_SCHEMA))

    def test_parse_with_the_review_schema(self) -> None:
        review = {"verdict": "concerns", "summary": "s", "findings": [{"file": "a", "line": None, "issue": "i"}]}
        self.out(json.dumps([{"type": "result", "is_error": False, "session_id": "S", "result": "r",
                              "structured_output": review}]))
        o = engines.ENGINES["claude"].parse(self.adir, 0, schema=engines.REVIEW_SCHEMA)
        self.assertEqual((o.kind, o.report), ("ok", review))
        self.assertEqual(engines.ENGINES["claude"].parse(self.adir, 0).kind, "error")   # not a report

    def test_paths(self) -> None:
        self.assertEqual(engines.ENGINES["claude"].rw_paths(), [self.home / ".claude", self.home / ".claude.json"])
        self.assertEqual(engines.ENGINES["codex"].rw_paths(), [self.home / ".codex"])
        self.assertEqual(engines.ENGINES["claude"].ro_paths(), [self.bin.resolve()])


class Parse(Engines):
    def test_parse_claude_fixture(self) -> None:
        self.out((FIX / "claude-structured.json").read_text())
        o = engines.ENGINES["claude"].parse(self.adir, 0)
        self.assertEqual(o.kind, "ok")
        assert o.report is not None
        self.assertEqual(o.report["status"], "done")
        self.assertEqual(o.report["summary"], "fixture")
        self.assertEqual(o.session_id, "dffd075f-b90d-4b1a-ab42-2d033397891c")
        self.assertEqual(o.turns, 2)
        self.assertEqual(engines.ENGINES["claude"].session_from(self.adir), o.session_id)

    def test_parse_codex_fixture(self) -> None:
        self.out((FIX / "codex-exec.jsonl").read_text())
        shutil.copy(FIX / "codex-last.json", self.adir / "last.json")
        o = engines.ENGINES["codex"].parse(self.adir, 0)
        self.assertEqual(o.kind, "ok")
        assert o.report is not None
        self.assertEqual(o.report["status"], "done")
        self.assertEqual(o.session_id, "01a1b794-e8d6-78f3-89a8-ad8ab3d6fc35")
        self.assertEqual(engines.ENGINES["codex"].session_from(self.adir), o.session_id)

    def test_codex_report_from_the_last_message_when_no_file(self) -> None:
        self.out((FIX / "codex-exec.jsonl").read_text())
        o = engines.ENGINES["codex"].parse(self.adir, 0)
        self.assertEqual(o.kind, "ok")
        assert o.report is not None
        self.assertEqual(o.report["summary"], "fixture")

    def test_parse_truncated_output_is_error(self) -> None:
        claude = (FIX / "claude-structured.json").read_text()
        for text in ("", claude[: len(claude) // 2]):
            self.out(text)
            self.assertEqual(engines.ENGINES["claude"].parse(self.adir, 1).kind, "error", text[:40])
        self.out('{"type":"thread.started","thread_id":"T"}\n')
        o = engines.ENGINES["codex"].parse(self.adir, 1)
        self.assertEqual(o.kind, "error")
        self.assertEqual(o.session_id, "T")   # still known, so a retry resumes it

    def test_claude_without_report_is_error(self) -> None:
        self.out(json.dumps([{"type": "result", "is_error": False, "result": "done", "session_id": "S"}]))
        o = engines.ENGINES["claude"].parse(self.adir, 0)
        self.assertEqual(o.kind, "error")
        self.assertIn("report", o.message)

    def test_codex_400_fixture_is_error(self) -> None:
        self.out((FIX / "codex-error-400.jsonl").read_text())
        o = engines.ENGINES["codex"].parse(self.adir, 1)
        self.assertEqual(o.kind, "error")
        self.assertIn("Invalid schema", o.message)

    def test_classify_failures(self) -> None:
        cases = [
            ({"result": "Claude AI usage limit reached|1767225600"}, "usage_limit"),
            ({"result": "5-hour limit reached ∙ resets 3pm"}, "usage_limit"),
            ({"result": "API Error: 529 Overloaded"}, "transient"),
            ({"result": "API Error: 500 Internal server error"}, "transient"),
            ({"result": "x", "api_error_status": 503}, "transient"),
            ({"result": "Request timed out."}, "transient"),
            ({"result": "API Error: Connection error."}, "transient"),
            ({"result": "Invalid API key · Please run /login"}, "auth"),
            ({"result": "OAuth token has expired"}, "auth"),
            ({"result": "something else broke"}, "error"),
        ]
        for extra, kind in cases:
            self.out(json.dumps([{"type": "result", "is_error": True, "session_id": "S", **extra}]))
            o = engines.ENGINES["claude"].parse(self.adir, 1)
            self.assertEqual(o.kind, kind, extra)
        self.out(json.dumps([{"type": "result", "is_error": True, "session_id": "S",
                              "result": "Claude AI usage limit reached|1767225600"}]))
        self.assertTrue(engines.ENGINES["claude"].parse(self.adir, 1).reset_at.startswith("2026-01-01"))

        def codex_fail(msg: str) -> str:
            return "\n".join(json.dumps(e) for e in (
                {"type": "thread.started", "thread_id": "T"}, {"type": "turn.started"},
                {"type": "error", "message": msg}, {"type": "turn.failed", "error": {"message": msg}}))
        for msg, kind in (
                (json.dumps({"error": {"message": "You've hit your usage limit.", "code": "usage_limit_reached"},
                             "status": 429}), "usage_limit"),
                (json.dumps({"error": {"message": "Rate limit reached", "type": "rate_limit"}, "status": 429}),
                 "transient"),
                ("stream disconnected before completion: error sending request", "transient"),
                (json.dumps({"error": {"message": "server overloaded"}, "status": 503}), "transient"),
                (json.dumps({"error": {"message": "Unauthorized"}, "status": 401}), "auth")):
            self.out(codex_fail(msg))
            self.assertEqual(engines.ENGINES["codex"].parse(self.adir, 1).kind, kind, msg)


class Select(Engines):
    def entry(self, *names: str) -> reg.Repo:
        return reg.Repo(path=self.wc, vcs="svn", engines=names)

    def test_select_respects_allowed_order_cooldown_and_availability(self) -> None:
        engine, _ = engines.select(self.entry("claude", "codex"))
        assert engine is not None
        self.assertEqual(engine.name, "claude")
        engines.cool("claude", "2999-01-01T00:00:00+00:00")
        engine, reasons = engines.select(self.entry("claude", "codex"))
        assert engine is not None
        self.assertEqual(engine.name, "codex")
        self.assertTrue(any("claude: cooling down until 2999-01-01" in r for r in reasons), reasons)
        self.fake("codex", 'echo "Not logged in" >&2; exit 1')
        engine, reasons = engines.select(self.entry("claude", "codex"))
        self.assertIsNone(engine)
        self.assertTrue(any(r.startswith("codex: ") and "log" in r for r in reasons), reasons)
        engine, reasons = engines.select(self.entry("claude"))
        self.assertIsNone(engine)
        self.assertEqual(len(reasons), 1)
        self.assertIn("cooling down", reasons[0])
        engine, _ = engines.select(self.entry("claude", "codex"), exclude={"claude"})
        self.assertIsNone(engine)

    def test_cooldown_expires(self) -> None:
        engines.cool("claude", "2000-01-01T00:00:00+00:00")
        self.assertEqual(engines.cooling("claude"), "")
        engine, _ = engines.select(self.entry("claude"))
        assert engine is not None

    def test_never_an_engine_the_repository_doesnt_list(self) -> None:
        self.fake("claude", "exit 1")
        engine, reasons = engines.select(self.entry("claude"))
        self.assertIsNone(engine)
        self.assertTrue(all(r.startswith("claude: ") for r in reasons), reasons)

    def test_available_needs_the_sandbox(self) -> None:
        with mock.patch.object(agent_sandbox, "probe", return_value="no bwrap"):
            engine, reasons = engines.select(self.entry("claude", "codex"))
        self.assertIsNone(engine)
        self.assertEqual(reasons, ["sandbox: no bwrap"])

    def test_slot_caps_concurrency(self) -> None:
        events: list[str] = []
        entered = threading.Event()

        def first() -> None:
            with engines.slot("claude", 1, poll=0.02):
                events.append("first in")
                entered.set()
                time.sleep(0.3)
                events.append("first out")

        def second() -> None:
            entered.wait(5)
            with engines.slot("claude", 1, poll=0.02):
                events.append("second in")

        threads = [threading.Thread(target=first), threading.Thread(target=second)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(10)
        self.assertEqual(events, ["first in", "first out", "second in"])
        with engines.slot("claude", 2, poll=0.02), engines.slot("claude", 2, poll=0.02):
            pass   # two slots: both enter at once

    def test_transcripts(self) -> None:
        p = self.home / ".claude" / "projects" / "x" / "S-9.jsonl"
        self.write(p, "")
        self.assertTrue(engines.ENGINES["claude"].transcript_exists("S-9"))
        self.assertFalse(engines.ENGINES["claude"].transcript_exists(""))
        self.write(self.home / ".codex" / "sessions" / "2026" / "11" / "07" / "rollout-2026-11-07T19-55-51-T-9.jsonl", "")
        self.assertTrue(engines.ENGINES["codex"].transcript_exists("T-9"))
        self.assertFalse(engines.ENGINES["codex"].transcript_exists("T-0"))


if __name__ == "__main__":
    os.environ.pop("CLAUDECODE", None)
    unittest.main()
