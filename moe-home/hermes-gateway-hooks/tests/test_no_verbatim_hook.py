"""The no-verbatim hook: a Slack turn's words are gone after the reply, a
Telegram turn's are untouched, and everything that lets a reply thread stays.

The fixtures are built in the shape that was READ, not imagined: the
``messages``/``sessions``/``delivery_obligations`` DDL and the two FTS
triggers below are ``.schema`` from ``~/.hermes/state.db`` (schema_version
30, 2026-09-15, read-only), trimmed only of columns and triggers this hook
never touches; the jsonl lines are the key sets measured over 121 transcripts
the same day. No sentence in this file is anything anyone ever said in Slack.
"""

import asyncio
import importlib.util
import json
import os
import shutil
import sqlite3
import tempfile
import unittest
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
HANDLER = os.path.join(os.path.dirname(HERE), "moe-no-verbatim", "handler.py")

# ---- state.db, as read ------------------------------------------------------
SCHEMA = """
CREATE TABLE state_meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    user_id TEXT,
    session_key TEXT,
    chat_id TEXT,
    chat_type TEXT,
    thread_id TEXT,
    display_name TEXT,
    origin_json TEXT,
    model_config TEXT,
    parent_session_id TEXT,
    started_at REAL NOT NULL,
    title TEXT,
    title_source TEXT,
    last_activity_description TEXT
);
CREATE UNIQUE INDEX idx_sessions_title_unique ON sessions(title) WHERE title IS NOT NULL;
CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions(id),
    role TEXT NOT NULL,
    content TEXT,
    tool_call_id TEXT,
    tool_calls TEXT,
    tool_name TEXT,
    timestamp REAL NOT NULL,
    reasoning TEXT,
    reasoning_content TEXT,
    reasoning_details TEXT,
    platform_message_id TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    compacted INTEGER NOT NULL DEFAULT 0,
    api_content TEXT
);
CREATE VIRTUAL TABLE messages_fts USING fts5(
    content, tool_name, tool_calls, content='messages', content_rowid='id');
CREATE TRIGGER messages_fts_insert AFTER INSERT ON messages
WHEN (new.id > COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                         WHERE key = 'fts_rebuild_high_water'), -1)
   OR new.id <= COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                          WHERE key = 'fts_rebuild_progress'), -1))
BEGIN
    INSERT INTO messages_fts(rowid, content, tool_name, tool_calls)
    VALUES (new.id, new.content, new.tool_name, new.tool_calls);
END;
CREATE TRIGGER messages_fts_update
AFTER UPDATE OF content, tool_name, tool_calls, role ON messages
WHEN (old.content IS NOT new.content
    OR old.tool_name IS NOT new.tool_name
    OR old.tool_calls IS NOT new.tool_calls
    OR old.role IS NOT new.role)
   AND (old.id > COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                           WHERE key = 'fts_rebuild_high_water'), -1)
     OR old.id <= COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                            WHERE key = 'fts_rebuild_progress'), -1))
BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content, tool_name, tool_calls)
    VALUES ('delete', old.id, old.content, old.tool_name, old.tool_calls);
    INSERT INTO messages_fts(rowid, content, tool_name, tool_calls)
    VALUES (new.id, new.content, new.tool_name, new.tool_calls);
END;
CREATE VIEW messages_fts_trigram_src AS
    SELECT m.id, m.role, m.content, m.tool_name
    FROM messages AS m
    JOIN sessions AS s ON s.id = m.session_id
    WHERE m.role <> 'tool' AND s.source NOT IN ('cron', 'subagent')
      AND json_extract(COALESCE(s.model_config, '{}'), '$._delegate_from') IS NULL;
CREATE VIRTUAL TABLE messages_fts_trigram USING fts5(
    content, tool_name, content='messages_fts_trigram_src', content_rowid='id',
    tokenize='trigram');
CREATE TRIGGER messages_fts_trigram_insert AFTER INSERT ON messages
WHEN new.role <> 'tool'
BEGIN
    INSERT INTO messages_fts_trigram(rowid, content, tool_name)
    VALUES (new.id, new.content, new.tool_name);
END;
CREATE TRIGGER messages_fts_trigram_update
AFTER UPDATE OF content, tool_name, role ON messages
WHEN (old.content IS NOT new.content OR old.tool_name IS NOT new.tool_name OR old.role IS NOT new.role)
BEGIN
    INSERT INTO messages_fts_trigram(messages_fts_trigram, rowid, content, tool_name)
    SELECT 'delete', old.id, old.content, old.tool_name WHERE old.role <> 'tool';
    INSERT INTO messages_fts_trigram(rowid, content, tool_name)
    SELECT new.id, new.content, new.tool_name WHERE new.role <> 'tool';
END;
CREATE TABLE delivery_obligations (
    obligation_id TEXT PRIMARY KEY,
    session_key TEXT NOT NULL,
    platform TEXT NOT NULL,
    chat_id TEXT NOT NULL,
    thread_id TEXT,
    content TEXT NOT NULL,
    state TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    adapter_profile TEXT
);
"""

SLACK_SID = "6b1f2a3c-0000-4000-8000-00000000s1ac"
TG_SID = "9d8e7f60-0000-4000-8000-0000000te1eg"
SLACK_KEY = "agent:main:slack:group:C0ABCDEF:1700000000.000100"
TG_KEY = "agent:main:telegram:dm:5550001107"

# Invented. Distinctive so a search for them is a real search.
SLACK_ASK = "move the Berlin quarterly review to Thursday and tell Priya"
SLACK_REPLY = "Done: the Berlin review is Thursday at 10, and Priya has the invite."
SLACK_THINK = "The Berlin review is on the shared calendar; I need to move it."
TG_ASK = "what is on my calendar tomorrow in Lisbon"
TG_REPLY = "Two things tomorrow in Lisbon: the dentist and the harbour walk."
TOOL_ARGS = json.dumps([{"id": "call_1", "function": {"name": "memory",
                        "arguments": json.dumps({"claim": "Berlin review moved to Thursday"})}}])
TOOL_RESULT = '{"ok": true, "claim_id": "clm_42"}'
NS = uuid.UUID("6f1c0d2e-7b3a-4c8e-9a5d-2f4b8c1e7d90")


def load():
    spec = importlib.util.spec_from_file_location("moe_no_verbatim_test", HANDLER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def seed_store(path):
    con = sqlite3.connect(path)
    con.executescript(SCHEMA)
    for sid, src, key, chat, thread, title, tsrc in (
        (SLACK_SID, "slack", SLACK_KEY, "C0ABCDEF", "1700000000.000100", "Berlin review to Thursday", "llm"),
        (TG_SID, "telegram", TG_KEY, "5550001107", None, "Lisbon calendar", "llm"),
    ):
        con.execute("INSERT INTO sessions(id, source, user_id, session_key, chat_id, chat_type, thread_id,"
                    " started_at, title, title_source) VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (sid, src, "U1", key, chat, "group" if thread else "dm", thread, 1.0, title, tsrc))
    rows = [
        (SLACK_SID, "session_meta", json.dumps({"platform": "slack", "model": "m"}), None, None, 1.0, None),
        (SLACK_SID, "user", SLACK_ASK, None, None, 2.0, "1700000000.000200"),
        (SLACK_SID, "assistant", None, TOOL_ARGS, None, 3.0, None),
        (SLACK_SID, "tool", TOOL_RESULT, None, "memory", 4.0, None),
        (SLACK_SID, "assistant", SLACK_REPLY, None, None, 5.0, None),
        (TG_SID, "user", TG_ASK, None, None, 2.0, "4411"),
        (TG_SID, "assistant", TG_REPLY, None, None, 3.0, None),
    ]
    for sid, role, content, calls, tool_name, ts, pmid in rows:
        con.execute("INSERT INTO messages(session_id, role, content, tool_calls, tool_name, timestamp,"
                    " platform_message_id, reasoning) VALUES (?,?,?,?,?,?,?,?)",
                    (sid, role, content, calls, tool_name, ts, pmid,
                     SLACK_THINK if (sid == SLACK_SID and role == "assistant" and content) else None))
    for oid, key, plat, chat, content, state in (
        ("ob-slack-1", SLACK_KEY, "slack", "C0ABCDEF", SLACK_REPLY, "delivered"),
        ("ob-slack-2", SLACK_KEY, "slack", "C0ABCDEF", "a reply still waiting to be sent", "pending"),
        ("ob-tg-1", TG_KEY, "telegram", "5550001107", TG_REPLY, "delivered"),
    ):
        con.execute("INSERT INTO delivery_obligations(obligation_id, session_key, platform, chat_id,"
                    " content, state, created_at, updated_at, adapter_profile) VALUES (?,?,?,?,?,?,1,1,'default')",
                    (oid, key, plat, chat, content, state))
    con.commit()
    con.close()


def _line(kind, sid, cid, **extra):
    base = {"type": kind, "sessionId": cid, "uuid": "u-%s-%s" % (kind, extra.pop("n", 0)),
            "parentUuid": None, "timestamp": "2026-09-15T10:00:00.000Z", "cwd": "/scratch",
            "isSidechain": False, "userType": "external", "version": "2.0.0", "gitBranch": "",
            "entrypoint": "cli"}
    base.update(extra)
    return base


def transcript_lines(sid, ask, reply, think):
    cid = str(uuid.uuid5(NS, "hermes:%s" % sid))
    return [
        _line("attachment", sid, cid, n=0, attachment={"type": "prompt_snapshot",
                                                       "systemPrompt": ["You are Alfie."]}),
        _line("queue-operation", sid, cid, n=1, operation="enqueue"),
        _line("user", sid, cid, n=2, promptId="p1", permissionMode="default", promptSource="cli",
              message={"role": "user", "content": [{"type": "text", "text": ask}]}),
        _line("assistant", sid, cid, n=3, requestId="req_1",
              message={"role": "assistant", "id": "msg_1", "type": "message", "model": "m",
                       "content": [{"type": "thinking", "thinking": think, "signature": "sig=="}],
                       "stop_reason": None, "usage": {}}),
        _line("assistant", sid, cid, n=4, requestId="req_1",
              message={"role": "assistant", "id": "msg_1", "type": "message", "model": "m",
                       "content": [{"type": "tool_use", "id": "tu_1", "name": "mcp__hermes__memory",
                                    "input": {"claim": "Berlin review moved to Thursday"}}],
                       "stop_reason": "tool_use", "usage": {}}),
        _line("user", sid, cid, n=5, promptId="p1", sourceToolAssistantUUID="u-assistant-4",
              toolUseResult={"ok": True},
              message={"role": "user", "content": [{"type": "tool_result", "tool_use_id": "tu_1",
                                                    "content": TOOL_RESULT}]}),
        _line("assistant", sid, cid, n=6, requestId="req_2",
              message={"role": "assistant", "id": "msg_2", "type": "message", "model": "m",
                       "content": [{"type": "text", "text": reply}],
                       "stop_reason": "end_turn", "usage": {}}),
        _line("user", sid, cid, n=7, promptId="p2", permissionMode="default", promptSource="cli",
              message={"role": "user", "content": ask + " (again, as a plain string)"}),
        {"type": "last-prompt", "sessionId": cid, "leafUuid": "u-assistant-6", "lastPrompt": ask},
        {"type": "ai-title", "sessionId": cid, "aiTitle": "Berlin review to Thursday"},
    ]


def write_transcript(home, sid, lines):
    cid = str(uuid.uuid5(NS, "hermes:%s" % sid))
    d = os.path.join(home, "claude-code", "projects", "-scratch-claude-code-workspace")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, cid + ".jsonl")
    with open(p, "w", encoding="utf-8") as f:
        for l in lines:
            f.write(json.dumps(l) + "\n")
    return p


SLACK_CTX = {"platform": "slack", "chat_type": "group", "chat_id": "C0ABCDEF",
             "thread_id": "1700000000.000100", "session_id": SLACK_SID,
             "message": SLACK_ASK, "response": SLACK_REPLY, "model": "m", "provider": "claude-code"}
TG_CTX = dict(SLACK_CTX, platform="telegram", chat_type="dm", chat_id="5550001107", thread_id="",
              session_id=TG_SID, message=TG_ASK, response=TG_REPLY)


class _Scratch(unittest.TestCase):
    """A scratch HERMES_HOME and MOE_HOME per test, seeded in the measured
    shapes; the helpers every test reads through."""

    def setUp(self):
        self._env = {k: os.environ.get(k) for k in ("HERMES_HOME", "MOE_HOME", "MOE_NO_VERBATIM_DELAYS")}
        self.hermes = tempfile.mkdtemp(prefix="moe-no-verbatim-hermes-")
        self.moe = tempfile.mkdtemp(prefix="moe-no-verbatim-moe-")
        os.environ["HERMES_HOME"] = self.hermes
        os.environ["MOE_HOME"] = self.moe
        os.environ["MOE_NO_VERBATIM_DELAYS"] = ""      # deferred passes are opted into per test
        self.db = os.path.join(self.hermes, "state.db")
        seed_store(self.db)
        self.slack_jsonl = write_transcript(self.hermes, SLACK_SID,
                                            transcript_lines(SLACK_SID, SLACK_ASK, SLACK_REPLY, SLACK_THINK))
        self.tg_jsonl = write_transcript(self.hermes, TG_SID,
                                         transcript_lines(TG_SID, TG_ASK, TG_REPLY, "thinking about Lisbon"))
        self.mod = load()
        self.loop = asyncio.new_event_loop()

    def tearDown(self):
        for t in list(self.mod._pending):
            t.cancel()
        if self.mod._pending:
            self.loop.run_until_complete(asyncio.gather(*self.mod._pending, return_exceptions=True))
        self.loop.close()
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.hermes, ignore_errors=True)
        shutil.rmtree(self.moe, ignore_errors=True)

    # -- helpers --------------------------------------------------------------
    def go(self, coro):
        return self.loop.run_until_complete(coro)

    def settle(self):
        """The startup sweep and the deferred passes are background tasks;
        run the loop until every one of them has finished."""
        while self.mod._pending:
            self.go(asyncio.gather(*list(self.mod._pending), return_exceptions=True))

    def q(self, sql, *args):
        con = sqlite3.connect(self.db)
        try:
            return con.execute(sql, args).fetchall()
        finally:
            con.close()

    def rows(self, sid):
        return self.q("SELECT id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp,"
                      " reasoning, reasoning_content, reasoning_details, platform_message_id, active,"
                      " compacted, api_content FROM messages WHERE session_id=? ORDER BY id", sid)

    def blob(self):
        return "\n".join(str(r) for r in self.q("SELECT content, reasoning, tool_calls FROM messages")) + \
            "\n".join(str(r) for r in self.q("SELECT title, last_activity_description FROM sessions")) + \
            "\n".join(str(r) for r in self.q("SELECT content FROM delivery_obligations WHERE state='delivered'"))

    def read(self, path):
        with open(path, encoding="utf-8") as f:
            return f.read()



class NoVerbatimHookTest(_Scratch):
    # -- the promise ----------------------------------------------------------
    def test_a_slack_turns_words_are_gone_after_the_reply(self):
        before = [json.loads(l) for l in self.read(self.slack_jsonl).splitlines()]
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        blob = self.blob()
        for words in (SLACK_ASK, SLACK_REPLY, SLACK_THINK, "Berlin review to Thursday"):
            self.assertNotIn(words, blob, "the store still holds the words: %r" % words)
        text = self.read(self.slack_jsonl)
        for words in (SLACK_ASK, SLACK_REPLY, SLACK_THINK, "again, as a plain string", "Berlin review to Thursday"):
            self.assertNotIn(words, text, "the transcript still holds the words: %r" % words)
        # The marker stands where the words were, in both places.
        marked = self.q("SELECT count(*) FROM messages WHERE session_id=? AND role IN ('user','assistant')"
                        " AND content=?", SLACK_SID, self.mod.MARKER)[0][0]
        self.assertEqual(marked, 2)
        self.assertIn(self.mod.MARKER, text)
        after = [json.loads(l) for l in text.splitlines()]
        self.assertEqual(len(after), len(before), "a transcript line was lost")
        for a, b in zip(after, before):
            self.assertEqual(a.get("uuid"), b.get("uuid"))
            self.assertEqual(a.get("parentUuid"), b.get("parentUuid"))
            self.assertEqual(a.get("sessionId"), b.get("sessionId"))
            self.assertEqual(a.get("type"), b.get("type"))

    def test_the_two_full_text_indexes_forget_the_words_too(self):
        """Two more copies the review did not list. A MATCH is the falsifier —
        not the trigger's existence. 'Priya' is in the words and nowhere else;
        'Berlin' is also in the claim Alfie wrote (tool_calls is indexed too),
        and that is meant to stay findable."""
        self.assertEqual(self.q("SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'Priya'")[0][0], 2)
        self.assertGreater(self.q("SELECT count(*) FROM messages_fts_trigram WHERE messages_fts_trigram MATCH 'Priya'")[0][0], 0)
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        self.assertEqual(self.q("SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'Priya'")[0][0], 0)
        self.assertEqual(self.q("SELECT count(*) FROM messages_fts_trigram WHERE messages_fts_trigram MATCH 'Priya'")[0][0], 0)
        # What Moe did is still findable; Telegram's words still are too.
        self.assertEqual(self.q("SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'tool_calls:Berlin'")[0][0], 1)
        self.assertEqual(self.q("SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'Lisbon'")[0][0], 2)

    def test_a_telegram_turn_is_untouched(self):
        tg_before = self.rows(TG_SID)
        tg_session_before = self.q("SELECT * FROM sessions WHERE id=?", TG_SID)
        tg_ob_before = self.q("SELECT * FROM delivery_obligations WHERE obligation_id='ob-tg-1'")
        tg_jsonl_before = self.read(self.tg_jsonl)
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        self.go(self.mod.handle("agent:end", TG_CTX))
        self.go(self.mod.handle("gateway:startup", {}))
        self.settle()
        self.assertEqual(self.rows(TG_SID), tg_before)
        self.assertEqual(self.q("SELECT * FROM sessions WHERE id=?", TG_SID), tg_session_before)
        self.assertEqual(self.q("SELECT * FROM delivery_obligations WHERE obligation_id='ob-tg-1'"), tg_ob_before)
        self.assertEqual(self.read(self.tg_jsonl), tg_jsonl_before)

    def test_the_stores_own_word_is_the_guard_not_the_callers(self):
        """A context that says "slack" about a Telegram session changes
        nothing. The platform in the hook context is the gateway's claim; the
        session row's `source` is what the store recorded when it made it."""
        tg_before = self.rows(TG_SID)
        tg_jsonl_before = self.read(self.tg_jsonl)
        lying = dict(SLACK_CTX, session_id=TG_SID)
        self.go(self.mod.handle("agent:end", lying))
        self.assertEqual(self.rows(TG_SID), tg_before)
        self.assertEqual(self.read(self.tg_jsonl), tg_jsonl_before)
        self.assertFalse(os.path.exists(os.path.join(self.moe, "logs", "no-verbatim.jsonl")))

    # -- what survives --------------------------------------------------------
    def test_ids_and_threading_survive(self):
        before = self.rows(SLACK_SID)
        sess_before = self.q("SELECT id, source, user_id, session_key, chat_id, chat_type, thread_id"
                             " FROM sessions WHERE id=?", SLACK_SID)
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        after = self.rows(SLACK_SID)
        self.assertEqual(len(after), len(before))
        for a, b in zip(after, before):
            # id, session_id, role, tool_call_id, tool_calls, tool_name, timestamp,
            # platform_message_id, active, compacted — every column but the words.
            for i in (0, 1, 2, 4, 5, 6, 7, 11, 12, 13):
                self.assertEqual(a[i], b[i], "column %d of message %s changed" % (i, b[0]))
        self.assertEqual(self.q("SELECT id, source, user_id, session_key, chat_id, chat_type, thread_id"
                                " FROM sessions WHERE id=?", SLACK_SID), sess_before)
        self.assertEqual(self.q("SELECT count(*) FROM sessions")[0][0], 2)

    def test_what_moe_did_stays(self):
        """The tool row and the assistant's tool_calls are the claim Alfie wrote —
        what it learned, which the memory rule allows. An obligation not yet
        delivered keeps its content: it still has to be sent."""
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        self.assertEqual(self.q("SELECT content FROM messages WHERE session_id=? AND role='tool'", SLACK_SID),
                         [(TOOL_RESULT,)])
        self.assertEqual(self.q("SELECT tool_calls FROM messages WHERE session_id=? AND tool_calls IS NOT NULL",
                                SLACK_SID), [(TOOL_ARGS,)])
        self.assertEqual(self.q("SELECT content, state, session_key FROM delivery_obligations"
                                " WHERE obligation_id='ob-slack-1'")[0], ("", "delivered", SLACK_KEY))
        self.assertEqual(self.q("SELECT content FROM delivery_obligations WHERE obligation_id='ob-slack-2'")[0][0],
                         "a reply still waiting to be sent")
        text = self.read(self.slack_jsonl)
        self.assertIn('"tool_use"', text)
        self.assertIn(TOOL_RESULT.replace('"', '\\"'), text)

    def test_a_title_made_from_the_words_goes_and_a_persons_own_stays(self):
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        title = self.q("SELECT title FROM sessions WHERE id=?", SLACK_SID)[0][0]
        self.assertTrue(title.startswith(self.mod.TITLE_PREFIX), title)
        self.assertNotIn("Berlin", title)
        # Reset with a title the person typed.
        con = sqlite3.connect(self.db)
        con.execute("UPDATE sessions SET title='my ops channel', title_source='user' WHERE id=?", (SLACK_SID,))
        con.commit(); con.close()
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        self.assertEqual(self.q("SELECT title FROM sessions WHERE id=?", SLACK_SID)[0][0], "my ops channel")

    def test_thinking_blocks_are_dropped_not_rewritten(self):
        """A thinking block is signed over its text; a resumed child hands
        earlier blocks back to the API, and a rewritten one would be refused.
        So it goes, and a message left with nothing gets a marker text block."""
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        lines = [json.loads(l) for l in self.read(self.slack_jsonl).splitlines()]
        thinking_line = [l for l in lines if l.get("uuid") == "u-assistant-3"][0]
        blocks = thinking_line["message"]["content"]
        self.assertEqual([b["type"] for b in blocks], ["text"])
        self.assertEqual(blocks[0]["text"], self.mod.MARKER)
        self.assertNotIn("sig==", json.dumps(lines))

    # -- timing ---------------------------------------------------------------
    def test_rows_written_after_the_hook_are_caught_by_the_deferred_pass(self):
        """The gateway queues transcript writes and flushes them after
        `agent:end` (gateway/session.py `_dirty_transcripts`; run.py persists a
        user row after the hook on one path). One pass would miss the very
        turn it fired for."""
        os.environ["MOE_NO_VERBATIM_DELAYS"] = "0.05"
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        late_ask = "and move the Oslo one too while you are at it"
        con = sqlite3.connect(self.db)
        con.execute("INSERT INTO messages(session_id, role, content, timestamp) VALUES (?,?,?,?)",
                    (SLACK_SID, "user", late_ask, 6.0))
        con.commit(); con.close()
        self.assertIn(late_ask, self.blob(), "the late row must exist before the deferred pass")
        self.go(asyncio.sleep(0.4))
        self.assertNotIn(late_ask, self.blob())

    def test_delays_unset_means_the_defaults_and_empty_means_none(self):
        """Found by the suite's own stray-task warnings: `or` read a set-and-
        empty variable as unset and scheduled the default passes anyway."""
        os.environ["MOE_NO_VERBATIM_DELAYS"] = ""
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        self.assertEqual(len(self.mod._pending), 0)
        os.environ.pop("MOE_NO_VERBATIM_DELAYS")
        self.assertEqual(self.mod._delays(), [2.0, 15.0, 90.0])
        os.environ["MOE_NO_VERBATIM_DELAYS"] = "1, x, -3, 0.5"
        self.assertEqual(self.mod._delays(), [1.0, 0.0, 0.5])

    def test_startup_sweeps_a_session_that_had_no_next_turn(self):
        """The last Slack turn before the gateway stopped has no `agent:end`
        after its rows were flushed. Startup is the pass that gets it — in
        the background, so the gateway's startup is not held by it."""
        self.go(self.mod.handle("gateway:startup", {}))
        self.assertEqual(len(self.mod._pending), 1, "the sweep must be a background task")
        self.settle()
        blob = self.blob()
        self.assertNotIn(SLACK_ASK, blob)
        self.assertNotIn(SLACK_REPLY, blob)
        self.assertNotIn(SLACK_ASK, self.read(self.slack_jsonl))
        self.assertIn(TG_ASK, blob)
        self.assertIn(TG_ASK, self.read(self.tg_jsonl))

    def test_a_second_pass_changes_nothing(self):
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        st = os.stat(self.slack_jsonl)
        rows = self.rows(SLACK_SID)
        os.utime(self.slack_jsonl, (st.st_atime, st.st_mtime - 100))
        counts = self.mod.scrub_session(SLACK_SID)
        self.assertEqual(counts, {"sessions": 1, "messages": 0, "titles": 0, "obligations": 0,
                                  "failed": 0, "transcript_lines": 0})
        self.assertEqual(os.stat(self.slack_jsonl).st_mtime, st.st_mtime - 100, "the file was rewritten for nothing")
        self.assertEqual(self.rows(SLACK_SID), rows)

    # -- the marker, the receipt, the paths -------------------------------------
    def test_the_marker_names_the_platform_and_the_rule_and_nothing_said(self):
        self.assertIn("slack", self.mod.MARKER)
        self.assertIn("no verbatim copy", self.mod.MARKER)
        self.assertLess(len(self.mod.MARKER), 120)

    def test_the_receipt_carries_counts_and_no_words(self):
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        path = os.path.join(self.moe, "logs", "no-verbatim.jsonl")
        text = self.read(path)
        rows = [json.loads(l) for l in text.splitlines()]
        self.assertEqual(rows[0]["session_id"], SLACK_SID)
        self.assertEqual(rows[0]["messages"], 2)
        self.assertEqual(rows[0]["obligations"], 1)
        self.assertGreaterEqual(rows[0]["transcript_lines"], 5)
        for words in (SLACK_ASK, SLACK_REPLY, SLACK_THINK):
            self.assertNotIn(words, text)
        self.assertEqual(oct(os.stat(path).st_mode & 0o777), "0o600")

    def test_both_runtimes_paths_follow_hermes_home(self):
        """The Mac's HERMES_HOME is ~/.hermes; the machine's is /opt/data. One
        variable, both paths, nothing hard-wired to a home directory."""
        os.environ["HERMES_HOME"] = "/opt/data"
        self.assertEqual(self.mod.state_db_path(), "/opt/data/state.db")
        self.assertTrue(self.mod.transcript_paths(SLACK_SID) == [])   # nothing there, and no error
        cid = self.mod.claude_session_id(SLACK_SID)
        os.environ["HERMES_HOME"] = self.hermes
        self.assertEqual(self.mod.transcript_paths(SLACK_SID), [self.slack_jsonl])
        self.assertTrue(self.slack_jsonl.endswith(cid + ".jsonl"))
        os.environ.pop("HERMES_HOME")
        self.assertEqual(self.mod.state_db_path(), os.path.expanduser("~/.hermes/state.db"))

    def test_the_claude_session_id_is_the_forks(self):
        """The transcript is found by an id derived the way the fork derives
        it. If the fork moves its namespace this must go red, so it reads the
        fork when the fork is on the path (test-plugins.sh puts it there)."""
        try:
            from agent import claude_code_runtime as rt
        except Exception as e:  # noqa: BLE001
            self.skipTest("hermes-agent not importable here (%s): the namespace is pinned, not compared"
                          % type(e).__name__)
        self.assertEqual(rt._CLAUDE_SESSION_NAMESPACE, self.mod.CLAUDE_SESSION_NAMESPACE)

        class _A:  # what _claude_session_id_for reads
            session_id = SLACK_SID
        self.assertEqual(rt._claude_session_id_for(_A()), self.mod.claude_session_id(SLACK_SID))

    def test_nothing_raises_when_there_is_no_store(self):
        os.environ["HERMES_HOME"] = tempfile.mkdtemp(prefix="moe-no-verbatim-empty-")
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        self.go(self.mod.handle("gateway:startup", {}))
        self.settle()

    def test_other_events_and_other_platforms_do_nothing(self):
        before = self.blob()
        self.go(self.mod.handle("agent:start", SLACK_CTX))
        self.go(self.mod.handle("agent:end", dict(SLACK_CTX, platform="discord")))
        self.go(self.mod.handle("agent:end", dict(SLACK_CTX, platform="")))
        self.go(self.mod.handle("agent:end", dict(SLACK_CTX, session_id="")))
        self.assertEqual(self.blob(), before)


class ReviewFindingsTest(_Scratch):
    """One falsifier per finding of the 2026-09-15 review of this hook. Each
    was a way the words stayed while a receipt — or silence — said otherwise."""

    def add_slack_session(self, sid, ask, reply, title=None, title_source="llm",
                          parent=None, key=None, with_transcript=True):
        if title is None:
            title = "Thursday plans (%s)" % sid      # sessions.title is UNIQUE
        con = sqlite3.connect(self.db)
        con.execute("INSERT INTO sessions(id, source, user_id, session_key, chat_id, chat_type,"
                    " parent_session_id, started_at, title, title_source) VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (sid, "slack", "U1", key or ("agent:main:slack:group:C0ABCDEF:%s" % sid), "C0ABCDEF",
                     "group", parent, 1.0, title, title_source))
        con.execute("INSERT INTO messages(session_id, role, content, timestamp) VALUES (?,?,?,?)",
                    (sid, "user", ask, 2.0))
        con.execute("INSERT INTO messages(session_id, role, content, timestamp) VALUES (?,?,?,?)",
                    (sid, "assistant", reply, 3.0))
        con.commit(); con.close()
        if with_transcript:
            return write_transcript(self.hermes, sid, transcript_lines(sid, ask, reply, "hm"))

    def test_two_slack_sessions_from_one_day_are_both_scrubbed(self):
        """Gateway ids are date-prefixed (`20260913_211535_cb050bb9`, the live
        Telegram row), and `sessions.title` is UNIQUE. A title built from a
        prefix of the id collided within a day, the unique index refused it,
        and the whole scrub rolled back — every pass, for ever — for the
        second session of the day."""
        a, b = "20260915_090000_aaaaaaaa", "20260915_091500_bbbbbbbb"
        self.add_slack_session(a, "the Oslo numbers are wrong, fix them", "Fixed the Oslo numbers.")
        self.add_slack_session(b, "and book the Oslo flight for Marta", "Booked; Marta has it.",
                               title="Oslo flight")
        self.go(self.mod.handle("agent:end", dict(SLACK_CTX, session_id=a)))
        self.go(self.mod.handle("agent:end", dict(SLACK_CTX, session_id=b)))
        blob = self.blob()
        for words in ("Oslo numbers", "Oslo flight", "Marta"):
            self.assertNotIn(words, blob)
        titles = self.q("SELECT title FROM sessions WHERE id IN (?,?)", a, b)
        self.assertEqual(len({t for (t,) in titles}), 2, titles)
        receipts = [json.loads(l) for l in self.read(os.path.join(self.moe, "logs", "no-verbatim.jsonl")).splitlines()]
        self.assertEqual([r["failed"] for r in receipts], [0, 0])

    def test_a_transcript_written_under_a_mapped_id_is_scrubbed_too(self):
        """The transport reads hermes-sessions.json FIRST (`mapped or
        session_id`): a pre-warmed spare or a refused --resume leaves the
        turn's transcript under a uuid4 the deterministic path never names."""
        mapped = str(uuid.uuid4())
        d = os.path.join(self.hermes, "claude-code")
        with open(os.path.join(d, "hermes-sessions.json"), "w") as f:
            json.dump({SLACK_SID: mapped, TG_SID: str(uuid.uuid4())}, f)
        p = os.path.join(d, "projects", "-scratch-claude-code-workspace", mapped + ".jsonl")
        with open(p, "w") as f:
            for l in transcript_lines(SLACK_SID, SLACK_ASK, SLACK_REPLY, SLACK_THINK):
                l["sessionId"] = mapped
                f.write(json.dumps(l) + "\n")
        self.assertEqual(self.mod.transcript_paths(SLACK_SID), [p, self.slack_jsonl])
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        for path in (p, self.slack_jsonl):
            text = self.read(path)
            self.assertNotIn(SLACK_ASK, text, path)
            self.assertIn(self.mod.MARKER, text)
        # The map itself is untouched: it is how the next turn finds its child.
        with open(os.path.join(d, "hermes-sessions.json")) as f:
            self.assertEqual(json.load(f)[SLACK_SID], mapped)

    def test_a_compression_child_is_scrubbed_with_the_parent_it_was_split_from(self):
        """Compression mid-turn moves the turn's rows to a child session while
        agent:end still names the parent; the child inherits `source`."""
        child = "20260915_100000_cc000000"
        self.add_slack_session(child, "the Berlin follow-up, from the compressed half",
                               "Noted the Berlin follow-up.", parent=SLACK_SID, key=SLACK_KEY)
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        blob = self.blob()
        self.assertNotIn("compressed half", blob)
        self.assertNotIn("Berlin follow-up", blob)
        self.assertNotIn("compressed half", self.read(self.mod.transcript_paths(child)[0]))
        # A Telegram child of a Slack parent is not a thing, but the guard is
        # the child's own `source`: a child that is not Slack stays.
        con = sqlite3.connect(self.db)
        con.execute("UPDATE sessions SET source='telegram' WHERE id=?", (child,))
        con.execute("UPDATE messages SET content='kept because the child is telegram' WHERE session_id=? AND role='user'", (child,))
        con.commit(); con.close()
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        self.assertIn("kept because the child is telegram", self.blob())

    def test_a_null_title_source_is_the_persons_and_a_derived_one_becomes_llm(self):
        """hermes_state._title_rank treats NULL as the person's ('refuse to
        overwrite it'); this hook must agree. And a scrubbed title carries an
        explicit provenance so a 'derived' re-title from the words cannot put
        them back."""
        nul, der = "20260915_110000_dd000000", "20260915_111500_ee000000"
        self.add_slack_session(nul, "hand-titled thread words", "ok", title="ops (typed by me)", title_source=None)
        self.add_slack_session(der, "derived-titled thread words", "ok", title="derived-titled thread", title_source="derived")
        self.go(self.mod.handle("gateway:startup", {}))
        self.settle()
        self.assertEqual(self.q("SELECT title, title_source FROM sessions WHERE id=?", nul)[0], ("ops (typed by me)", None))
        self.assertEqual(self.q("SELECT title, title_source FROM sessions WHERE id=?", der)[0],
                         (self.mod.TITLE_PREFIX + der, "llm"))
        self.assertNotIn("hand-titled thread words", self.blob())

    def test_a_lone_surrogate_line_does_not_stop_the_transcript_being_rewritten(self):
        """JavaScript's JSON.stringify writes a split emoji as "\\ud83d";
        json.loads accepts it and utf-8 refuses it. That line used to raise
        out of the pass after the store had committed — the store said
        'done', the transcript kept every word."""
        # The surrogate sits in a field the rewrite KEEPS (gitBranch) on a line
        # it CHANGES (the text) — so re-encoding the changed line meets it. In
        # the text itself it would be replaced by the marker and prove nothing.
        with open(self.slack_jsonl, "a", encoding="utf-8") as f:
            f.write(json.dumps({"type": "user", "uuid": "u-user-99", "parentUuid": "u-assistant-6",
                                "sessionId": "x", "gitBranch": "SURROGATE",
                                "message": {"role": "user", "content": [
                                    {"type": "text", "text": "emoji cut in half"}]}})
                    .replace('"SURROGATE"', '"\\ud83d"') + "\n")
        self.go(self.mod.handle("agent:end", SLACK_CTX))
        text = self.read(self.slack_jsonl)
        self.assertNotIn("emoji cut in half", text)
        self.assertNotIn(SLACK_ASK, text)
        self.assertIn("\\ud83d", text, "the surrogate survives as the escape JavaScript wrote")
        for l in text.splitlines():
            json.loads(l)     # every line is still JSON

    def test_one_refused_session_does_not_take_the_others_with_it(self):
        """One transaction per session. Here the second session's scrubbed
        title is already taken by a title the person typed on another row, so
        the unique index refuses it — and the first and third are still done,
        and the receipt says one failed rather than saying nothing."""
        a, b, c = "20260915_120000_a1000000", "20260915_120500_b1000000", "20260915_121000_c1000000"
        for sid in (a, b, c):
            self.add_slack_session(sid, "words of %s" % sid, "reply to %s" % sid)
        self.add_slack_session("20260915_130000_ff000000", "a fourth", "ok",
                               title=self.mod.TITLE_PREFIX + b, title_source="user", with_transcript=False)
        self.go(self.mod.handle("gateway:startup", {}))
        self.settle()
        blob = self.blob()
        self.assertNotIn("words of %s" % a, blob)
        self.assertNotIn("words of %s" % c, blob)
        self.assertIn("words of %s" % b, blob, "b's pass was refused; its words are still there THIS pass")
        receipts = [json.loads(l) for l in self.read(os.path.join(self.moe, "logs", "no-verbatim.jsonl")).splitlines()]
        self.assertEqual(receipts[-1]["failed"], 1)
        self.assertGreaterEqual(receipts[-1]["sessions"], 4)

    def test_a_pass_for_a_session_waits_for_the_one_already_running(self):
        """Passes for one session overlap by design (+2 s of message 1 meets
        the immediate pass of message 2). Serialised per session, so the slower
        one cannot replace a newer transcript with its older read. This is the
        falsifier for the lock itself: the racing test below stays green with
        the lock removed (the window is a few microseconds on a small file),
        which the repo's own rule calls a check that cannot fail."""
        import threading
        lock = self.mod._lock_for(SLACK_SID)
        finished = threading.Event()

        def second():
            self.mod.scrub_session(SLACK_SID)
            finished.set()
        with lock:
            t = threading.Thread(target=second)
            t.start()
            self.assertFalse(finished.wait(0.3), "a second pass ran while the first held the session")
            self.assertIn(SLACK_ASK, self.blob(), "…and it must not have rewritten anything meanwhile")
        self.assertTrue(finished.wait(5.0), "the second pass never ran after the first let go")
        t.join()
        self.assertNotIn(SLACK_ASK, self.blob())
        # A different session is not held up by this one.
        other = self.mod._lock_for(TG_SID)
        self.assertIsNot(other, lock)

    def test_two_passes_for_one_session_at_once_lose_no_line(self):
        """Racing passes on one transcript: no line lost, no temp file left.
        Not the lock's falsifier (see above) — the temp-file half of it is:
        with a shared O_TRUNC path both writers truncate one inode."""
        import threading
        before = len(self.read(self.slack_jsonl).splitlines())
        errors = []

        def work():
            try:
                for _ in range(15):
                    self.mod.scrub_session(SLACK_SID)
                    with open(self.slack_jsonl, "a", encoding="utf-8") as f:
                        f.write(json.dumps({"type": "queue-operation", "operation": "enqueue",
                                            "sessionId": "x"}) + "\n")
            except Exception as e:  # noqa: BLE001
                errors.append(e)
        threads = [threading.Thread(target=work) for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(errors, [])
        lines = self.read(self.slack_jsonl).splitlines()
        self.assertEqual(len(lines), before + 4 * 15, "a line was lost to a racing rewrite")
        uuids = [json.loads(l).get("uuid") for l in lines[:before]]
        self.assertEqual(uuids, ["u-%s-%d" % (k, n) for k, n in
                                 (("attachment", 0), ("queue-operation", 1), ("user", 2), ("assistant", 3),
                                  ("assistant", 4), ("user", 5), ("assistant", 6), ("user", 7))] + [None, None])
        self.assertEqual(glob_tmp(os.path.dirname(self.slack_jsonl)), [], "a temp file was left behind")


def glob_tmp(d):
    return [n for n in os.listdir(d) if n.startswith(".no-verbatim-")]


if __name__ == "__main__":
    unittest.main()
