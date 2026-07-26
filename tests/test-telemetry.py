#!/usr/bin/env python3
"""tests/test-telemetry.py -- scripts/lib/telemetry.py against fixtures whose
event shapes were copied from REAL harness stores, plus (when they exist on
this machine) the real stores themselves.

Why fixtures AND live probes: a fixture proves the parser handles the shape
it was written for, which is circular if the shape was invented. Every
fixture below is a trimmed copy of an actual line observed in
`~/.copilot/session-state/<id>/events.jsonl` or
`~/.claude/projects/<slug>/<id>.jsonl` on 2026-07-26 -- same keys, same
nesting, same value types, with content shortened and paths made generic.
The LiveStoreProbe class then reads whatever real stores are present and
reports what it found. It never fails when they are absent (CI has neither
harness installed) but it does fail if a real store parses to nothing, which
is the regression that would matter.
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts" / "lib"))

import telemetry  # noqa: E402


# --------------------------------------------------------------------------
# Fixture builders -- event shapes copied from real stores
# --------------------------------------------------------------------------

def _ts(seconds):
    return "2026-07-25T22:40:{:02d}.000Z".format(seconds)


def copilot_session(tmp, session_id, events):
    d = Path(tmp) / "session-state" / session_id
    d.mkdir(parents=True, exist_ok=True)
    with (d / "events.jsonl").open("w", encoding="utf-8") as handle:
        for event in events:
            handle.write(json.dumps(event) + "\n")
    return d


def ev(etype, data, ts):
    """One event line. Real lines also carry `id`/`parentId`; telemetry.py
    reads neither, and including them here would imply it does."""
    return {"type": etype, "data": data, "timestamp": ts}


def simple_turn(turn_id, model="claude-opus-4.6", user=None, tools=(),
                out_tokens=100, start=0, end=5):
    """The exact event sequence a real Copilot turn emits, in order."""
    events = []
    if user is not None:
        events.append(ev("user.message", {"content": user, "delivery": "idle"}, _ts(start)))
    events.append(ev("assistant.turn_start",
                     {"turnId": turn_id, "interactionId": "i-" + turn_id}, _ts(start)))
    events.append(ev("assistant.message", {
        "messageId": "m-" + turn_id, "model": model, "content": "...",
        "outputTokens": out_tokens, "toolRequests": [], "turnId": turn_id,
    }, _ts(start)))
    for index, (tool_name, args) in enumerate(tools):
        events.append(ev("tool.execution_start", {
            "toolCallId": "tc-{}-{}".format(turn_id, index),
            "toolName": tool_name, "arguments": args,
            "turnId": turn_id, "model": model,
        }, _ts(start)))
    events.append(ev("assistant.turn_end", {"turnId": turn_id, "model": model}, _ts(end)))
    return events


class CopilotEventsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.env = {"SL_COPILOT_HOME": self.tmp}

    def turns(self):
        return telemetry.build_turn_requests(self.env)

    def test_turn_carries_model_prompt_tokens_and_elapsed(self):
        copilot_session(self.tmp, "s1", simple_turn(
            "0", user="fix the parser", out_tokens=7000, start=0, end=42))
        (turn,) = self.turns()
        self.assertEqual(turn["modelId"], "claude-opus-4.6")
        self.assertEqual(turn["messageText"], "fix the parser")
        self.assertEqual(turn["messageLength"], len("fix the parser"))
        self.assertEqual(turn["completionTokens"], 7000)
        self.assertEqual(turn["totalElapsed"], 42000)
        self.assertEqual(turn["source"], "copilot")

    def test_elapsed_is_none_not_zero_when_turn_never_ended(self):
        """A truncated tail must not read as an instantaneous response --
        that is the difference between "unknown" and "very fast", and
        slow-responses would silently under-count on the latter."""
        events = simple_turn("0", user="hi")
        events = [e for e in events if e["type"] != "assistant.turn_end"]
        copilot_session(self.tmp, "s1", events)
        (turn,) = self.turns()
        self.assertIsNone(turn["totalElapsed"])
        self.assertEqual(telemetry.requests_with([turn], "totalElapsed"), [])

    def test_unparseable_timestamps_give_none_elapsed_not_zero(self):
        """Second half of the same invariant as the test above, for the
        other way a timestamp can be unusable. Found by mutation testing:
        turning THIS branch's `return None` into `return 0` survived until
        this case existed, which would have scored every event whose
        timestamp format ever changes as a 0ms response."""
        events = simple_turn("0", user="x")
        for event in events:
            event["timestamp"] = "not-a-timestamp"
        copilot_session(self.tmp, "s1", events)
        (turn,) = self.turns()
        self.assertIsNone(turn["totalElapsed"])

    def test_tools_files_and_meta_tool_exclusion(self):
        copilot_session(self.tmp, "s1", simple_turn("0", user="x", tools=[
            ("view", {"path": "/repo/a.py"}),
            ("view", {"path": "/repo/a.py"}),          # duplicate -> one file
            ("edit", {"path": "/repo/b.py", "new_str": "x"}),
            ("report_intent", {"intent": "planning"}),  # META_TOOLS, excluded
            ("bash", {"command": "ls"}),
        ]))
        (turn,) = self.turns()
        self.assertNotIn("report_intent", turn["toolsUsed"])
        self.assertEqual(turn["referencedFiles"], ["/repo/a.py"])
        self.assertEqual(turn["editedFiles"], ["/repo/b.py"])
        self.assertIn("bash", turn["toolsUsed"])

    def test_mcp_tools_get_the_upstream_mcp_prefix(self):
        copilot_session(self.tmp, "s1", simple_turn("0", user="x", tools=[
            ("search", {}),
        ]))
        # Rebuild the same event with the MCP fields the real store sets.
        path = Path(self.tmp) / "session-state" / "s1" / "events.jsonl"
        lines = path.read_text().splitlines()
        patched = []
        for line in lines:
            obj = json.loads(line)
            if obj["type"] == "tool.execution_start":
                obj["data"]["mcpServerName"] = "context7"
                obj["data"]["mcpToolName"] = "query-docs"
            patched.append(json.dumps(obj))
        path.write_text("\n".join(patched) + "\n")
        (turn,) = self.turns()
        self.assertIn("mcp_context7_query-docs", turn["toolsUsed"])

    def test_abort_marks_the_open_turn_canceled(self):
        events = simple_turn("0", user="x")
        events.insert(-1, ev("abort", {"reason": "user_initiated"}, _ts(3)))
        copilot_session(self.tmp, "s1", events)
        (turn,) = self.turns()
        self.assertTrue(turn["isCanceled"])

    def test_permission_pair_becomes_a_confirmation_without_an_autoapprove_claim(self):
        events = simple_turn("0", user="x")
        events.insert(-1, ev("permission.requested", {
            "requestId": "r1",
            "permissionRequest": {"kind": "shell", "fullCommandText": "rm -rf /tmp/x"},
        }, _ts(2)))
        events.insert(-1, ev("permission.completed", {
            "requestId": "r1", "result": {"kind": "approved"},
        }, _ts(4)))
        copilot_session(self.tmp, "s1", events)
        (turn,) = self.turns()
        self.assertEqual(len(turn["toolConfirmations"]), 1)
        confirmation = turn["toolConfirmations"][0]
        self.assertEqual(confirmation["kind"], "shell")
        self.assertEqual(confirmation["result"], "approved")
        # Deliberate: this stream cannot distinguish a standing allow-rule
        # from a human clicking approve, so no autoApproved field is
        # invented. See telemetry.py for the latency measurements.
        self.assertNotIn("autoApproved", confirmation)

    def test_skill_tool_and_skill_event_both_land_deduplicated(self):
        events = simple_turn("0", user="x", tools=[("skill", {"skill": "brainstorming"})])
        events.insert(-1, ev("skill.invoked", {"name": "brainstorming"}, _ts(3)))
        copilot_session(self.tmp, "s1", events)
        (turn,) = self.turns()
        self.assertEqual(turn["skillsUsed"], ["brainstorming"])

    def test_fragment_turn_with_no_model_and_no_tools_is_dropped(self):
        copilot_session(self.tmp, "s1", [
            ev("assistant.turn_start", {"turnId": "9"}, _ts(0)),
            ev("assistant.turn_end", {"turnId": "9"}, _ts(1)),
        ])
        self.assertEqual(self.turns(), [])

    def test_unparseable_and_truncated_lines_do_not_raise(self):
        d = Path(self.tmp) / "session-state" / "s1"
        d.mkdir(parents=True)
        good = simple_turn("0", user="x")
        with (d / "events.jsonl").open("w") as handle:
            handle.write("not json at all\n")
            for event in good:
                handle.write(json.dumps(event) + "\n")
            handle.write('{"type": "assistant.mess')  # truncated tail
        self.assertEqual(len(self.turns()), 1)

    def test_missing_store_yields_empty_not_an_exception(self):
        self.assertEqual(telemetry.build_turn_requests({"SL_COPILOT_HOME": "/nope"}), [])
        self.assertEqual(telemetry.build_api_calls({"SL_COPILOT_HOME": "/nope"}), [])


class CopilotStoreDbTest(unittest.TestCase):
    """assistant_usage_events -- the DDL below is copied verbatim from the
    real ~/.copilot/session-store.db schema (sqlite3 .schema, 2026-07-26)."""

    DDL = """
    CREATE TABLE sessions (id TEXT PRIMARY KEY);
    CREATE TABLE assistant_usage_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL REFERENCES sessions(id),
        turn_index INTEGER, agent_id TEXT, parent_tool_call_id TEXT,
        model TEXT NOT NULL, input_tokens INTEGER, output_tokens INTEGER,
        cache_read_tokens INTEGER, cache_write_tokens INTEGER,
        reasoning_tokens INTEGER, total_nano_aiu INTEGER,
        request_multiplier REAL, duration_ms INTEGER,
        time_to_first_token_ms INTEGER, initiator TEXT, api_endpoint TEXT,
        reasoning_effort TEXT, finish_reason TEXT,
        content_filter_triggered INTEGER, token_details_json TEXT,
        created_at TEXT DEFAULT (datetime('now')));
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.env = {"SL_COPILOT_HOME": self.tmp}
        conn = sqlite3.connect(str(Path(self.tmp) / "session-store.db"))
        conn.executescript(self.DDL)
        conn.execute("INSERT INTO sessions (id) VALUES ('s1')")
        conn.executemany(
            "INSERT INTO assistant_usage_events (session_id, model, input_tokens,"
            " output_tokens, cache_read_tokens, duration_ms, reasoning_effort,"
            " initiator, finish_reason, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
            [
                ("s1", "claude-opus-4.6", 28943, 65, 28794, 3500, "high", "agent", "stop", "2026-07-25"),
                ("s1", "gpt-5.4", 9000, 400, 0, 12000, None, "user", "tool_calls", "2026-07-25"),
            ],
        )
        conn.commit()
        conn.close()

    def test_rows_become_api_calls_with_token_and_effort_fields(self):
        calls = telemetry.build_api_calls(self.env)
        self.assertEqual(len(calls), 2)
        by_model = {c["modelId"]: c for c in calls}
        self.assertEqual(by_model["claude-opus-4.6"]["promptTokens"], 28943)
        self.assertEqual(by_model["claude-opus-4.6"]["cacheReadTokens"], 28794)
        self.assertEqual(by_model["claude-opus-4.6"]["reasoningEffort"], "high")
        self.assertEqual(by_model["claude-opus-4.6"]["totalElapsed"], 3500)

    def test_zero_cache_read_is_kept_but_null_effort_becomes_none(self):
        """0 cached tokens is the very thing cache-hit-starvation looks for,
        so it must survive; an unset reasoning_effort must NOT become "" and
        get counted in that rule's denominator."""
        calls = telemetry.build_api_calls(self.env)
        gpt = [c for c in calls if c["modelId"] == "gpt-5.4"][0]
        self.assertEqual(gpt["cacheReadTokens"], 0)
        self.assertIsNone(gpt["reasoningEffort"])
        self.assertEqual(len(telemetry.requests_with(calls, "reasoningEffort")), 1)
        self.assertEqual(len(telemetry.requests_with(calls, "cacheReadTokens")), 2)

    def test_database_is_opened_read_only(self):
        """Immutable URI: no -wal/-shm may appear, and the file must not be
        modified. A live Copilot process holds this database open."""
        db = Path(self.tmp) / "session-store.db"
        before = db.stat().st_mtime_ns
        telemetry.build_api_calls(self.env)
        self.assertEqual(db.stat().st_mtime_ns, before)
        self.assertFalse((Path(self.tmp) / "session-store.db-wal").exists())


class ClaudeTranscriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.dir = Path(self.tmp) / "projects" / "-repo"
        self.dir.mkdir(parents=True)
        self.env = {"CLAUDE_CONFIG_DIR": self.tmp, "SL_COPILOT_HOME": "/nope"}

    def write(self, lines):
        with (self.dir / "sess.jsonl").open("w") as handle:
            for line in lines:
                handle.write(json.dumps(line) + "\n")

    @staticmethod
    def assistant(request_id, blocks, output_tokens=500, model="claude-opus-5"):
        return {
            "type": "assistant", "requestId": request_id,
            "timestamp": "2026-07-25T10:00:00.000Z",
            "message": {
                "role": "assistant", "model": model, "stop_reason": "tool_use",
                "content": blocks,
                "usage": {"input_tokens": 15971, "output_tokens": output_tokens,
                          "cache_read_input_tokens": 900,
                          "cache_creation_input_tokens": 42497},
            },
        }

    def test_repeated_usage_across_blocks_is_counted_once_per_request(self):
        """Claude Code writes one line per content BLOCK and repeats the
        identical usage object on each. Verified on a real transcript: three
        consecutive lines, one requestId, identical token counts. Summing
        per line would triple-count."""
        self.write([
            {"type": "user", "uuid": "u1", "timestamp": "2026-07-25T10:00:00.000Z",
             "message": {"role": "user", "content": "do the thing"}},
            self.assistant("req-1", [{"type": "thinking", "thinking": "..."}]),
            self.assistant("req-1", [{"type": "text", "text": "ok"}]),
            self.assistant("req-1", [{"type": "tool_use", "name": "Read",
                                       "input": {"file_path": "/repo/a.py"}}]),
        ])
        calls = telemetry.build_api_calls(self.env)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["completionTokens"], 500)
        self.assertEqual(calls[0]["promptTokens"], 15971)
        self.assertEqual(calls[0]["cacheReadTokens"], 900)
        (turn,) = telemetry.build_turn_requests(self.env)
        self.assertEqual(turn["completionTokens"], 500)

    def test_tool_result_user_lines_do_not_start_new_requests(self):
        """Every tool call produces a `user` line carrying a tool_result. If
        those counted as requests, the request total would be the tool-call
        total and every per-request rate would be wrong."""
        self.write([
            {"type": "user", "uuid": "u1", "timestamp": "2026-07-25T10:00:00.000Z",
             "message": {"role": "user", "content": "go"}},
            self.assistant("req-1", [{"type": "tool_use", "name": "Read",
                                       "input": {"file_path": "/repo/a.py"}}]),
            {"type": "user", "uuid": "u2", "message": {"role": "user", "content": [
                {"type": "tool_result", "content": "file body"}]}},
            self.assistant("req-2", [{"type": "text", "text": "done"}]),
        ])
        turns = telemetry.build_turn_requests(self.env)
        self.assertEqual(len(turns), 1)
        self.assertEqual(turns[0]["referencedFiles"], ["/repo/a.py"])

    def test_file_tools_split_into_referenced_and_edited(self):
        self.write([
            {"type": "user", "uuid": "u1", "message": {"role": "user", "content": "go"}},
            self.assistant("r1", [
                {"type": "tool_use", "name": "Read", "input": {"file_path": "/a"}},
                {"type": "tool_use", "name": "Write", "input": {"file_path": "/b"}},
                {"type": "tool_use", "name": "Glob", "input": {"path": "/c"}},
                {"type": "tool_use", "name": "Skill", "input": {"skill": "brainstorming"}},
                {"type": "tool_use", "name": "Agent", "input": {"subagent_type": "explore"}},
            ]),
        ])
        (turn,) = telemetry.build_turn_requests(self.env)
        self.assertEqual(sorted(turn["referencedFiles"]), ["/a", "/c"])
        self.assertEqual(turn["editedFiles"], ["/b"])
        self.assertEqual(turn["skillsUsed"], ["brainstorming"])
        self.assertEqual(turn["agentName"], "explore")

    def test_interrupted_message_marks_the_turn_canceled(self):
        self.write([
            {"type": "user", "uuid": "u1", "message": {"role": "user", "content": "go"}},
            self.assistant("r1", [{"type": "text", "text": "working"}]),
            {"type": "user", "uuid": "u2", "interruptedMessageId": "m1",
             "message": {"role": "user", "content": [{"type": "tool_result", "content": "x"}]}},
        ])
        (turn,) = telemetry.build_turn_requests(self.env)
        self.assertTrue(turn["isCanceled"])

    def test_sidechain_and_meta_lines_are_excluded(self):
        self.write([
            {"type": "user", "uuid": "u1", "isSidechain": True,
             "message": {"role": "user", "content": "subagent internal"}},
            {"type": "user", "uuid": "u2", "isMeta": True,
             "message": {"role": "user", "content": "Continue from where you left off."}},
            {"type": "user", "uuid": "u3", "message": {"role": "user", "content": "real"}},
            self.assistant("r1", [{"type": "text", "text": "ok"}]),
        ])
        (turn,) = telemetry.build_turn_requests(self.env)
        self.assertEqual(turn["messageText"], "real")


class ExtractCodeBlocksTest(unittest.TestCase):
    """The pure extractor, against upstream's CODE_BLOCK_RE semantics."""

    def test_language_and_line_count(self):
        blocks = telemetry.extract_code_blocks("prose\n```python\na\nb\nc\n```\nmore")
        self.assertEqual(blocks, [{"language": "python", "loc": 3}])

    def test_language_aliases_are_applied(self):
        """`py` and `python` must not count as two languages, and `md` and
        `markdown` must land in the same bucket -- real data on this machine
        contains both spellings, and low-markdown-ratio's numerator depends
        on it."""
        blocks = telemetry.extract_code_blocks("```py\nx\n```\n```md\ny\n```\n```ts\nz\n```")
        self.assertEqual([b["language"] for b in blocks], ["python", "markdown", "typescript"])

    def test_missing_info_string_is_unknown(self):
        self.assertEqual(telemetry.extract_code_blocks("```\na\n```"),
                         [{"language": "unknown", "loc": 1}])

    def test_empty_body_is_zero_loc_but_still_a_block(self):
        """Upstream emits the block with loc 0; aiCode.length is itself
        tested by analyzer-patterns, so dropping it would diverge."""
        self.assertEqual(telemetry.extract_code_blocks("```py\n\n```"),
                         [{"language": "python", "loc": 0}])

    def test_multiple_blocks_are_all_returned(self):
        blocks = telemetry.extract_code_blocks("```py\na\n```\ntext\n```sh\nb\nc\n```")
        self.assertEqual([b["loc"] for b in blocks], [1, 2])

    def test_unterminated_fence_yields_nothing(self):
        self.assertEqual(telemetry.extract_code_blocks("```py\na\nb"), [])


class CodeScanBudgetTest(unittest.TestCase):
    def test_budget_matches_upstreams_max_code_scan_chars(self):
        self.assertEqual(telemetry.MAX_CODE_SCAN_CHARS, 128000)

    def test_content_past_the_budget_is_not_scanned(self):
        """Upstream slices responseText to 128k before extracting. Without
        the same cap, one enormous generated file would dominate every
        LoC-based rule and our answers would diverge from upstream's for
        identical input."""
        scan = telemetry._CodeScan()
        scan.feed("```py\na\n```")
        scan.feed("x" * telemetry.MAX_CODE_SCAN_CHARS)
        scan.feed("```py\nb\nc\n```")
        self.assertEqual(scan.blocks, [{"language": "python", "loc": 1}])

    def test_separator_length_counts_against_the_budget(self):
        """Sized so the fence fits EXACTLY when the separator is free and is
        truncated when it is charged -- otherwise the assertion passes for
        the wrong reason (mutation-found: dropping the separator charge left
        this green)."""
        fence = "```py\nz\n```"
        scan = telemetry._CodeScan()
        scan.feed("a" * (telemetry.MAX_CODE_SCAN_CHARS - len(fence)))
        scan.feed(fence, separator_len=2)
        self.assertEqual(scan.blocks, [])

        loose = telemetry._CodeScan()
        loose.feed("a" * (telemetry.MAX_CODE_SCAN_CHARS - len(fence)))
        loose.feed(fence, separator_len=0)
        self.assertEqual(loose.blocks, [{"language": "python", "loc": 1}])


class CodeFenceTest(unittest.TestCase):
    def test_extension_becomes_the_language(self):
        self.assertEqual(telemetry._code_fence("/a/b/main.py", "x\ny"),
                         "```py\nx\ny\n```")

    def test_path_without_a_dot_is_unknown(self):
        self.assertEqual(telemetry._code_fence("Makefile", "x"), "```unknown\nx\n```")

    def test_missing_path_or_code_produces_nothing(self):
        """Upstream only pushes when BOTH are present; synthesising a fence
        from a pathless write would attribute lines to language 'unknown'
        that upstream never counts at all."""
        self.assertIsNone(telemetry._code_fence(None, "x"))
        self.assertIsNone(telemetry._code_fence("a.py", None))
        self.assertIsNone(telemetry._code_fence("a.py", ""))

    def test_arg_key_precedence_matches_upstream(self):
        args = {"new_str": "n", "file_text": "f", "content": "c"}
        self.assertEqual(telemetry._first_str(args, telemetry.COPILOT_CODE_ARG_KEYS), "f")
        self.assertEqual(telemetry._first_str({"new_str": "n", "content": "c"},
                                              telemetry.CLAUDE_CODE_ARG_KEYS), "c")
        self.assertIsNone(telemetry._first_str({"path": "a.py"},
                                               telemetry.COPILOT_CODE_ARG_KEYS))


class CopilotAiCodeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.env = {"SL_COPILOT_HOME": self.tmp}

    def test_edit_tool_new_str_becomes_ai_code(self):
        events = simple_turn("0", user="write it", tools=[
            ("edit", {"path": "/repo/app.py", "old_str": "old", "new_str": "a\nb\nc"}),
        ])
        copilot_session(self.tmp, "s1", events)
        (turn,) = telemetry.build_turn_requests(self.env)
        self.assertEqual(turn["aiCode"], [{"language": "python", "loc": 3}])
        self.assertEqual(telemetry.ai_loc(turn), 3)

    def test_create_tool_file_text_becomes_ai_code(self):
        events = simple_turn("0", user="new file", tools=[
            ("create", {"path": "/repo/README.md", "file_text": "# hi\ntext"}),
        ])
        copilot_session(self.tmp, "s1", events)
        (turn,) = telemetry.build_turn_requests(self.env)
        self.assertEqual(turn["aiCode"], [{"language": "markdown", "loc": 2}])

    def test_old_str_is_never_counted(self):
        """aiCode means lines PRODUCED, not diff size. Counting old_str would
        make every edit look twice as large and would double-count a pure
        deletion as authorship."""
        events = simple_turn("0", user="x", tools=[
            ("edit", {"path": "/repo/app.py",
                      "old_str": "1\n2\n3\n4\n5\n6\n7\n8\n9\n10",
                      "new_str": "a"}),
        ])
        copilot_session(self.tmp, "s1", events)
        (turn,) = telemetry.build_turn_requests(self.env)
        self.assertEqual(telemetry.ai_loc(turn), 1)

    def test_read_only_tools_contribute_no_ai_code(self):
        events = simple_turn("0", user="x", tools=[
            ("view", {"path": "/repo/app.py"}),
            ("bash", {"command": "ls"}),
        ])
        copilot_session(self.tmp, "s1", events)
        (turn,) = telemetry.build_turn_requests(self.env)
        self.assertEqual(turn["aiCode"], [])

    def test_prose_fences_in_assistant_content_count(self):
        events = simple_turn("0", user="explain")
        for event in events:
            if event["type"] == "assistant.message":
                event["data"]["content"] = "Here:\n```bash\necho hi\n```\n"
        copilot_session(self.tmp, "s1", events)
        (turn,) = telemetry.build_turn_requests(self.env)
        self.assertEqual(turn["aiCode"], [{"language": "bash", "loc": 1}])

    def test_workspace_comes_from_session_start_git_root(self):
        events = [ev("session.start",
                     {"sessionId": "s1",
                      "context": {"cwd": "/repo/sub", "gitRoot": "/repo"}},
                     "2026-07-25T22:40:00.000Z")]
        events += simple_turn("0", user="x")
        copilot_session(self.tmp, "s1", events)
        (turn,) = telemetry.build_turn_requests(self.env)
        self.assertEqual(turn["workspaceName"], "/repo")


class ClaudeAiCodeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.dir = Path(self.tmp) / "projects" / "-repo"
        self.dir.mkdir(parents=True)
        self.env = {"CLAUDE_CONFIG_DIR": self.tmp, "SL_COPILOT_HOME": "/nope"}

    def write(self, lines):
        with (self.dir / "sess.jsonl").open("w") as handle:
            for line in lines:
                handle.write(json.dumps(line) + "\n")

    def _assistant(self, blocks):
        return {
            "type": "assistant", "requestId": "r1",
            "timestamp": "2026-07-25T10:00:00.000Z", "cwd": "/repo",
            "message": {"role": "assistant", "model": "claude-opus-5",
                        "content": blocks,
                        "usage": {"input_tokens": 1, "output_tokens": 2}},
        }

    def test_write_tool_content_and_prose_fences_both_count(self):
        self.write([
            {"type": "user", "uuid": "u1", "cwd": "/repo",
             "timestamp": "2026-07-25T10:00:00.000Z",
             "message": {"role": "user", "content": "build it"}},
            self._assistant([
                {"type": "text", "text": "Plan:\n```sh\nmake\n```"},
                {"type": "tool_use", "name": "Write",
                 "input": {"file_path": "/repo/a.kt", "content": "x\ny"}},
            ]),
        ])
        (turn,) = telemetry.build_turn_requests(self.env)
        self.assertEqual(turn["aiCode"],
                         [{"language": "bash", "loc": 1}, {"language": "kt", "loc": 2}])
        self.assertEqual(turn["workspaceName"], "/repo")

    def test_read_tools_contribute_nothing(self):
        self.write([
            {"type": "user", "uuid": "u1", "cwd": "/repo",
             "timestamp": "2026-07-25T10:00:00.000Z",
             "message": {"role": "user", "content": "look"}},
            self._assistant([{"type": "tool_use", "name": "Read",
                              "input": {"file_path": "/repo/a.py"}}]),
        ])
        (turn,) = telemetry.build_turn_requests(self.env)
        self.assertEqual(turn["aiCode"], [])


class BuildSessionsTest(unittest.TestCase):
    @staticmethod
    def _rec(source, session, loc=0, workspace=None):
        return {"source": source, "session_id": session,
                "workspaceName": workspace,
                "aiCode": [{"language": "python", "loc": loc}] if loc else []}

    def test_groups_by_source_and_session_preserving_order(self):
        records = [self._rec("copilot", "a", 1), self._rec("claude", "a", 2),
                   self._rec("copilot", "a", 3)]
        sessions = telemetry.build_sessions(records)
        self.assertEqual(len(sessions), 2)
        self.assertEqual(sessions[0]["requestCount"], 2)
        self.assertEqual(telemetry.session_ai_loc(sessions[0]), 4)
        self.assertEqual(telemetry.session_ai_loc(sessions[1]), 2)

    def test_same_id_from_two_harnesses_is_never_merged(self):
        sessions = telemetry.build_sessions(
            [self._rec("copilot", "dup"), self._rec("claude", "dup")])
        self.assertEqual(len(sessions), 2)

    def test_missing_workspace_falls_back_to_the_session_id(self):
        """Bucketing every unknown-workspace session under one name would
        make low-markdown-ratio answer about a workspace that does not
        exist."""
        (session,) = telemetry.build_sessions([self._rec("copilot", "s9")])
        self.assertEqual(session["workspaceName"], "s9")


class CustomInstructionBytesTest(unittest.TestCase):
    """The instruction-file plumbing three Coach rules depend on.

    Upstream computes this for CLI sessions -- resolveCustomInstructionsBytes
    branches on an `isCLI` flag to read <session dir>/workspace.yaml and stat
    <folder>/.github/copilot-instructions.md [upstream
    src/core/parser-vscode.ts:106-133]. The claim that it comes "from the VS
    Code workspace, not from any CLI session log" was false.
    """

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.ws = self.tmp / "ws"
        self.ws.mkdir()

    # -- Copilot: workspace.yaml -> .github/copilot-instructions.md --------
    def _copilot(self, cwd_line):
        store = self.tmp / "store"
        (store / "session-state").mkdir(parents=True, exist_ok=True)
        session_dir = copilot_session(str(store), "s0", simple_turn("0", user="x"))
        if cwd_line is not None:
            (session_dir / "workspace.yaml").write_text(cwd_line)
        return telemetry.build_turn_requests(
            {"SL_COPILOT_HOME": str(store), "CLAUDE_CONFIG_DIR": "/nope"})

    def test_copilot_reads_the_instruction_file_named_by_workspace_yaml(self):
        (self.ws / ".github").mkdir()
        (self.ws / ".github" / "copilot-instructions.md").write_text("x" * 1234)
        turns = self._copilot("cwd: {}\n".format(self.ws))
        self.assertEqual([t["customInstructionsBytes"] for t in turns], [1234])
        self.assertEqual(turns[0]["workspaceName"], str(self.ws))

    def test_an_absent_instruction_file_is_zero_not_unknown(self):
        """0 and None mean different things downstream: 0 is "this workspace
        has no instructions" (a finding), None is "we could not tell" (a
        skip). Collapsing them would turn absent data into a finding."""
        turns = self._copilot("cwd: {}\n".format(self.ws))
        self.assertEqual([t["customInstructionsBytes"] for t in turns], [0])

    def test_no_workspace_yaml_leaves_the_size_unknown(self):
        turns = self._copilot(None)
        self.assertEqual([t["customInstructionsBytes"] for t in turns], [None])

    def test_a_relative_cwd_is_refused(self):
        """Transcribes parseCLIWorkspaceFolderPath's absolute-path guard
        [upstream src/core/parser-vscode-files.ts:586]. Without it a
        relative value would be resolved against the evaluator's own
        working directory."""
        turns = self._copilot("cwd: ../../etc\n")
        self.assertEqual([t["customInstructionsBytes"] for t in turns], [None])

    def test_a_trailing_slash_is_stripped_like_upstream(self):
        (self.ws / ".github").mkdir()
        (self.ws / ".github" / "copilot-instructions.md").write_text("y" * 7)
        turns = self._copilot("cwd: {}//\n".format(self.ws))
        self.assertEqual([t["customInstructionsBytes"] for t in turns], [7])

    # -- Claude Code: cwd -> CLAUDE.md -------------------------------------
    def _claude(self, cwd):
        home = self.tmp / "claude"
        project = home / "projects" / "-repo"
        project.mkdir(parents=True, exist_ok=True)
        with (project / "sess.jsonl").open("w") as handle:
            for line in [
                {"type": "user", "cwd": cwd, "uuid": "u1",
                 "timestamp": "2026-07-25T10:00:00.000Z",
                 "message": {"role": "user", "content": "hi"}},
                {"type": "assistant", "requestId": "r1", "cwd": cwd,
                 "timestamp": "2026-07-25T10:00:01.000Z",
                 "message": {"role": "assistant", "model": "claude-opus-5",
                             "stop_reason": "end_turn",
                             "content": [{"type": "text", "text": "ok"}],
                             "usage": {"input_tokens": 1, "output_tokens": 1}}},
            ]:
                handle.write(json.dumps(line) + "\n")
        return telemetry.build_turn_requests(
            {"CLAUDE_CONFIG_DIR": str(home), "SL_COPILOT_HOME": "/nope"})

    def test_claude_reads_claude_md_from_the_sessions_cwd(self):
        """ADAPTATION: Claude Code has no .github/copilot-instructions.md.
        <cwd>/CLAUDE.md is the same artefact -- always-on instructions
        prepended to every request in the workspace -- under a different
        name, and it is what this harness's half of the rule reads."""
        (self.ws / "CLAUDE.md").write_text("z" * 4321)
        turns = self._claude(str(self.ws))
        self.assertEqual([t["customInstructionsBytes"] for t in turns], [4321])

    def test_claude_workspace_without_claude_md_is_zero(self):
        turns = self._claude(str(self.ws))
        self.assertEqual([t["customInstructionsBytes"] for t in turns], [0])


class RequestsWithTest(unittest.TestCase):
    def test_none_excludes_but_zero_and_empty_list_do_not(self):
        records = [
            {"a": 0, "b": []},        # present, falsy -- must be KEPT
            {"a": None, "b": []},     # absent -- must be DROPPED
            {"b": []},                # missing key == absent
        ]
        self.assertEqual(len(telemetry.requests_with(records, "a")), 1)
        self.assertEqual(len(telemetry.requests_with(records, "b")), 3)
        self.assertEqual(len(telemetry.requests_with(records, "a", "b")), 1)


class LiveStoreProbe(unittest.TestCase):
    """Reads whatever real harness state exists on THIS machine.

    Reports and skips when a store is absent (CI installs neither harness).
    Fails when a store is present but yields nothing -- that is a real
    parser regression against real data, and it is the only thing a fixture
    suite structurally cannot catch.
    """

    def _probe(self, name, available, build, expect):
        if not available:
            print("[capability probe] {}: UNAVAILABLE -- live extraction NOT "
                  "exercised here (fixtures above still ran)".format(name),
                  file=sys.stderr)
            self.skipTest("{} store not present on this machine".format(name))
        records = build()
        print("[capability probe] {}: AVAILABLE -- {} record(s)".format(
            name, len(records)), file=sys.stderr)
        self.assertTrue(records, "{} store exists but parsed to zero records".format(name))
        expect(records)

    def test_live_copilot_events(self):
        env = dict(os.environ)
        env["CLAUDE_CONFIG_DIR"] = "/nonexistent-for-this-probe"
        available = bool(telemetry._copilot_event_files(env))
        self._probe(
            "copilot events.jsonl", available,
            lambda: telemetry.build_turn_requests(env),
            lambda recs: self.assertTrue(
                any(r["toolsUsed"] for r in recs),
                "real Copilot sessions parsed but no turn recorded a tool call"),
        )

    def test_live_copilot_usage_db(self):
        env = dict(os.environ)
        env["CLAUDE_CONFIG_DIR"] = "/nonexistent-for-this-probe"
        available = telemetry._copilot_store_db(env) is not None
        self._probe(
            "copilot session-store.db", available,
            lambda: telemetry.build_api_calls(env),
            lambda recs: self.assertTrue(
                any(r["promptTokens"] for r in recs),
                "session-store.db parsed but no row carried input tokens"),
        )

    def test_live_claude_transcripts(self):
        env = dict(os.environ)
        env["SL_COPILOT_HOME"] = "/nonexistent-for-this-probe"
        available = bool(telemetry._claude_transcripts(env))
        self._probe(
            "claude projects/*.jsonl", available,
            lambda: telemetry.build_api_calls(env),
            lambda recs: self.assertTrue(
                any(r["modelId"] for r in recs),
                "real Claude transcripts parsed but no API call carried a model"),
        )

    def test_live_ai_code_is_actually_extracted(self):
        """The one thing fixtures cannot prove: that aiCode is non-empty
        against REAL logs.

        A fixture suite passes whether or not the extractor matches the
        shapes a harness really emits, and five rules would then evaluate
        against a structurally-empty input and report a clean bill of health
        -- the failure this branch treats as worse than a skip. Measured
        here on 2026-07-26 before this landed: Copilot 29,819 LoC and Claude
        11,391 LoC over the six largest sessions of each.
        """
        env = dict(os.environ)
        available = bool(telemetry._copilot_event_files(env)) or \
            bool(telemetry._claude_transcripts(env))
        if not available:
            print("[capability probe] aiCode (live): UNAVAILABLE -- no harness "
                  "store on this machine", file=sys.stderr)
            self.skipTest("no harness store present")
        records = telemetry.build_turn_requests(env)
        total = sum(telemetry.ai_loc(r) for r in records)
        languages = {b["language"] for r in records for b in (r.get("aiCode") or [])}
        print("[capability probe] aiCode (live): AVAILABLE -- {} LoC across {} "
              "request(s), {} language(s)".format(total, len(records), len(languages)),
              file=sys.stderr)
        self.assertTrue(records, "harness store exists but parsed to zero requests")
        self.assertGreater(
            total, 0,
            "real harness sessions parsed but aiCode extracted ZERO lines -- the "
            "five aiCode rules would evaluate against an always-empty input")


if __name__ == "__main__":
    unittest.main()
