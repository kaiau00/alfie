"""After a Slack reply is sent, the words go; what Alfie learned stays.

THE PROMISE
-----------

On 2026-09-11 the owner decided how Alfie treats Slack: "look at messages,
update memory, don't copy them into our DB". The ledger already keeps it where
Alfie writes memory — ``sync_turn`` skips Slack turns — and the edge empties a
stored Slack body once the first reply chunk is sent. The G1 review
(2026-09-15) measured where verbatim copies were still being made, and the
owner chose to prune them rather than soften the promise. This hook is that
pruning. **Slack only**: every other platform's rows are left exactly as they
were, and the guard for that is the store's own word, not this hook's caller.

WHERE THE COPIES WERE (measured 2026-09-15, ``~/.hermes/state.db`` schema
version 30, read-only)
--------------------------------------------------------------------------

* ``messages.content`` — the user's words and the assistant's reply, one row
  each, ``role IN ('user','assistant')``. ``sessions.source`` is
  ``source.platform.value`` (gateway/session.py:2152), so a relayed Slack
  turn's session is ``source='slack'``.
* ``messages_fts`` (fts5, ``content='messages'``) and ``messages_fts_trigram``
  (fts5 over the view ``messages_fts_trigram_src``): two full-text indexes of
  the same column. Hermes's own ``AFTER UPDATE OF content`` triggers keep them
  in step, so rewriting ``content`` empties them too — the test proves it with
  a MATCH, not by trusting the trigger.
* ``sessions.title`` — auto-titled from the first message (``title_source``
  ``llm``/``derived``; 48 rows on this Mac). A person's own title
  (``title_source='user'``, and NULL, which ``hermes_state._title_rank``
  treats as the person's) is theirs and stays.
* ``delivery_obligations.content`` — the outbound reply, kept after
  ``state='delivered'`` (9 delivered rows on this Mac still carried it).
  Keyed by ``session_key = sessions.session_key`` (10/10 matched) and
  ``platform`` = the source platform.
* The Claude child's transcript, ``$HERMES_HOME/claude-code/projects/<cwd as
  dashes>/<id>.jsonl``. The id is one of two: the deterministic
  ``uuid5(_CLAUDE_SESSION_NAMESPACE, "hermes:<session id>")``
  (agent/claude_code_runtime.py ``_claude_session_id_for``; 28/28 non-cron
  sessions resolved that way), or — when the turn took a pre-warmed spare or
  a ``--resume`` was refused and the id rotated — a uuid4 recorded against the
  Hermes session id in ``$HERMES_HOME/claude-code/hermes-sessions.json``,
  which the transport reads FIRST (agent/transports/claude_code_session.py
  :1006, ``mapped or session_id``). Both are looked for. Lines of ``type``
  ``user`` carry ``message.content`` as a list of ``{type:text}`` blocks (472)
  or a plain string (3); ``assistant`` lines carry ``text``, ``thinking`` and
  ``tool_use`` blocks; ``last-prompt`` lines carry the words again as
  ``lastPrompt``; ``ai-title`` lines carry a title made from them.
  ``attachment`` lines of type ``prompt_snapshot`` are the system prompt, and
  ``queue-operation``'s ``operation`` is ``enqueue``/``dequeue`` — neither is
  touched.
* A session that was compressed mid-turn: the gateway moves the turn's rows
  to a child session (``sessions.parent_session_id`` → the one named in the
  hook context, ``source`` inherited) while ``agent:end`` still names the
  parent. The child is Slack too, so it is scrubbed with its parent — the
  named session and every descendant.

WHAT SURVIVES, deliberately
---------------------------

* Every id: the session row, ``session_key``, ``chat_id``, ``thread_id``,
  ``platform_message_id``, each message's ``id`` and ``timestamp``, the
  transcript's ``uuid``/``parentUuid``/``sessionId`` chain. A reply still
  threads, a retry still de-duplicates, a resume still resumes.
* ``role='tool'`` rows and the assistant's ``tool_calls``: that is what Alfie
  *did* — the claim it wrote, the cron it set — which the memory rule allows.
  ``tool_use`` blocks in the transcript, likewise.
* An obligation not yet delivered: it still has to be sent.
* A title the person gave the session.

WHEN IT RUNS
------------

``agent:end`` fires (gateway/run.py ~21503) after the agent has run and before
the non-streaming send (~21844), which sends from the in-memory ``response``,
never from the store — so nothing here can alter what the person receives.
But the store is written asynchronously: the agent flushes per step, the
gateway queues ``_dirty_transcripts`` and flushes later, and one path
persists the user row after the hook. So a single pass would miss the very
turn it was fired for. Three passes: now, and again after each of
``_DELAYS`` seconds; and ``gateway:startup`` sweeps every Slack session, which
is what catches a turn that was the last one before the gateway stopped.

HOW IT IS KEPT SMALL AND SAFE
-----------------------------

* **One transaction per session**, never one for the store: a row that
  cannot be written (a title the unique index refuses, say) costs that
  session that pass and nothing else. The startup sweep is a background task
  so startup is not held, and it commits as it goes.
* **The work is bounded, not the await.** ``asyncio.wait_for`` around a
  thread abandons the awaiter and leaves the thread holding the store's write
  lock; a session's transaction is short instead, and the store's own
  ``busy_timeout`` is the only wait.
* **One pass per session at a time** (a per-session lock), and the
  transcript is rewritten through ``mkstemp`` in its own directory and
  swapped by rename — two passes for one session cannot truncate each other's
  temp file or replace a newer transcript with an older read.
* **A transcript line that cannot be re-encoded** (a lone surrogate escape,
  which JavaScript's ``JSON.stringify`` emits for a split emoji) is written
  back as ASCII-escaped JSON; any other failure on one file is logged and the
  next file is still done.
* Nothing here raises. ``HookRegistry.emit`` only prints what escapes a
  handler and has no timeout of its own.

The child that is still alive holds the turn in its own memory until it
respawns — process memory, not a copy on disk.

WHAT IS LOGGED
--------------

One JSON line per pass that changed anything, to
``$MOE_HOME/logs/no-verbatim.jsonl``: the session id and counts. Never the
words — that would be the copy this file exists to remove.
"""

import asyncio
import glob
import json
import logging
import os
import sqlite3
import tempfile
import threading
import time
import uuid

log = logging.getLogger("gateway.moe-no-verbatim")

PLATFORM = "slack"

#: What a scrubbed message says instead of its words. Names the platform and
#: the rule, and nothing that was said.
MARKER = "[slack: no verbatim copy kept — Alfie keeps what it learned, not what was said]"
#: The title a Slack session carries once its auto-title is gone, followed by
#: the WHOLE session id: the store has ``UNIQUE INDEX idx_sessions_title_unique
#: ON sessions(title)`` and gateway ids are date-prefixed
#: (``20260913_211535_cb050bb9``), so a prefix of one collides within a day.
TITLE_PREFIX = "Slack — no copy kept "

#: agent/claude_code_runtime.py ``_CLAUDE_SESSION_NAMESPACE``. The test
#: compares this against the fork when the fork is importable.
CLAUDE_SESSION_NAMESPACE = uuid.UUID("6f1c0d2e-7b3a-4c8e-9a5d-2f4b8c1e7d90")
#: agent/transports/claude_code_session.py ``SESSION_MAP_FILENAME``.
SESSION_MAP_FILENAME = "hermes-sessions.json"

#: Seconds after ``agent:end`` at which the deferred passes run. The gateway
#: flushes its transcript queue within seconds; the last pass is for a store
#: that was locked twice.
_DEFAULT_DELAYS = "2,15,90"

_pending = set()
_locks_guard = threading.Lock()
_locks = {}


def _lock_for(session_id):
    with _locks_guard:
        lock = _locks.get(session_id)
        if lock is None:
            lock = _locks[session_id] = threading.Lock()
        return lock


# ---------------------------------------------------------------- where things are

def hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def state_db_path():
    return os.path.join(hermes_home(), "state.db")


def claude_config_dir():
    return os.path.join(hermes_home(), "claude-code")


def claude_session_id(hermes_session_id):
    return str(uuid.uuid5(CLAUDE_SESSION_NAMESPACE, "hermes:%s" % hermes_session_id))


def _session_map():
    """``{hermes session id: claude session id}`` as the transport reads it."""
    try:
        with open(os.path.join(claude_config_dir(), SESSION_MAP_FILENAME), encoding="utf-8") as fh:
            data = json.load(fh)
        return {str(k): str(v) for k, v in data.items()} if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def claude_session_ids(hermes_session_id, session_map=None):
    """Both ids the child may have written under — the mapped one first,
    the deterministic one always."""
    ids = []
    mapped = (session_map if session_map is not None else _session_map()).get(hermes_session_id)
    if mapped:
        ids.append(mapped)
    det = claude_session_id(hermes_session_id)
    if det not in ids:
        ids.append(det)
    return ids


def transcript_paths(hermes_session_id, session_map=None):
    """Every project directory: the child's cwd is configurable
    (``claude_code.cwd``), and the id is what identifies the file."""
    out = []
    for cid in claude_session_ids(hermes_session_id, session_map):
        pattern = os.path.join(claude_config_dir(), "projects", "*", cid + ".jsonl")
        out.extend(sorted(glob.glob(pattern)))
    return out


def _delays():
    # Unset means the defaults. Set and EMPTY means "no deferred passes" — a
    # test's way of asking for one pass — and `or` would have read that as
    # unset (the reverse of the trap moe-activity's _PATH documents).
    raw = os.environ.get("MOE_NO_VERBATIM_DELAYS")
    if raw is None:
        raw = _DEFAULT_DELAYS
    out = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            out.append(max(0.0, float(part)))
        except ValueError:
            continue
    return out


# ---------------------------------------------------------------- the store

def _connect(path):
    con = sqlite3.connect(path, timeout=5.0, isolation_level=None)
    con.execute("PRAGMA busy_timeout = 5000")
    return con


def _table_exists(con, name):
    return con.execute("SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name=?",
                       (name,)).fetchone() is not None


def _has_column(con, table, column):
    return any(r[1] == column for r in con.execute("PRAGMA table_info(%s)" % table))


def _confirmed_slack_sessions(con, session_ids):
    """The Slack sessions among those named — by the store's own word — plus
    every descendant (a compression child carries the turn's rows under a new
    id while the hook context still names the parent). Returns
    ``[(id, session_key)]``."""
    if not session_ids:
        return []
    marks = ",".join("?" for _ in session_ids)
    if _has_column(con, "sessions", "parent_session_id"):
        sql = ("WITH RECURSIVE fam(id) AS ("
               "  SELECT id FROM sessions WHERE id IN (%s)"
               "  UNION SELECT s.id FROM sessions s JOIN fam ON s.parent_session_id = fam.id)"
               " SELECT s.id, s.session_key FROM sessions s JOIN fam ON s.id = fam.id"
               " WHERE s.source=?" % marks)
    else:
        sql = "SELECT id, session_key FROM sessions WHERE id IN (%s) AND source=?" % marks
    return con.execute(sql, (*session_ids, PLATFORM)).fetchall()


def _scrub_one_in_store(con, sid, session_key):
    """One Slack session, one transaction. Raises on a refused write so the
    caller can log it for THIS session and go on to the next."""
    counts = {"messages": 0, "titles": 0, "obligations": 0}
    con.execute("BEGIN IMMEDIATE")
    try:
        cur = con.execute(
            "UPDATE messages SET content=?, reasoning=NULL, reasoning_content=NULL,"
            " reasoning_details=NULL, api_content=NULL"
            " WHERE session_id=? AND role IN ('user','assistant')"
            " AND content IS NOT NULL AND content <> ?",
            (MARKER, sid, MARKER))
        counts["messages"] = cur.rowcount
        # Only a title a machine made from the words. 'user' is the person's;
        # NULL is treated as the person's by hermes_state._title_rank, and so
        # here. Set as 'llm' — a machine-made title — so a 'derived' re-title
        # from the words cannot replace it; a later LLM title would be made
        # from the markers.
        title = TITLE_PREFIX + sid
        cur = con.execute(
            "UPDATE sessions SET title=?, title_source='llm', last_activity_description=NULL"
            " WHERE id=? AND title_source IN ('llm','derived')"
            " AND (title IS NULL OR title <> ?)",
            (title, sid, title))
        counts["titles"] = cur.rowcount
        if _table_exists(con, "delivery_obligations"):
            if session_key:
                cur = con.execute(
                    "UPDATE delivery_obligations SET content=''"
                    " WHERE state='delivered' AND content <> ''"
                    " AND (platform=? OR session_key=?)",
                    (PLATFORM, session_key))
            else:
                cur = con.execute(
                    "UPDATE delivery_obligations SET content=''"
                    " WHERE state='delivered' AND content <> '' AND platform=?",
                    (PLATFORM,))
            counts["obligations"] = cur.rowcount
        con.execute("COMMIT")
    except Exception:
        con.execute("ROLLBACK")
        raise
    return counts


# ---------------------------------------------------------------- the transcript

def _scrub_blocks(blocks):
    """Text blocks become the marker; thinking blocks go. A thinking block
    carries a signature over its text, and a resumed child hands earlier
    blocks back to the API — a rewritten one would be refused. Dropped, and
    if nothing is left a marker text block stands in so the message is still
    a message."""
    changed = False
    out = []
    for b in blocks:
        if not isinstance(b, dict):
            out.append(b)
            continue
        t = b.get("type")
        if t == "text":
            if b.get("text") != MARKER:
                b = dict(b)
                b["text"] = MARKER
                changed = True
            out.append(b)
        elif t in ("thinking", "redacted_thinking"):
            changed = True
        else:
            out.append(b)
    if not out and changed:
        out.append({"type": "text", "text": MARKER})
    return out, changed


def _scrub_line(d):
    """Returns True when ``d`` was changed in place."""
    t = d.get("type")
    if t in ("user", "assistant"):
        m = d.get("message")
        if not isinstance(m, dict):
            return False
        c = m.get("content")
        if isinstance(c, str):
            if c == MARKER:
                return False
            m["content"] = MARKER
            return True
        if isinstance(c, list):
            new, changed = _scrub_blocks(c)
            if changed:
                m["content"] = new
            return changed
        return False
    if t == "last-prompt":
        if d.get("lastPrompt") == MARKER:
            return False
        d["lastPrompt"] = MARKER
        return True
    if t == "ai-title":
        if d.get("aiTitle") == TITLE_PREFIX.strip():
            return False
        d["aiTitle"] = TITLE_PREFIX.strip()
        return True
    return False


def _encode(d):
    try:
        return json.dumps(d, ensure_ascii=False).encode("utf-8")
    except UnicodeEncodeError:
        # A lone surrogate escape survives json.loads and refuses utf-8.
        # ASCII-escaped is the same JSON to every reader.
        return json.dumps(d, ensure_ascii=True).encode("ascii")


def scrub_transcript(path):
    """Rewrite one jsonl beside itself and swap. Returns lines changed; 0
    means the file was not rewritten at all."""
    with open(path, "rb") as f:
        raw = f.read()
    out = []
    changed = 0
    for line in raw.split(b"\n"):
        if not line.strip():
            out.append(line)
            continue
        try:
            d = json.loads(line)
        except ValueError:
            out.append(line)
            continue
        if isinstance(d, dict) and _scrub_line(d):
            changed += 1
            out.append(_encode(d))
        else:
            out.append(line)
    if not changed:
        return 0
    st = os.stat(path)
    fd, tmp = tempfile.mkstemp(prefix=".no-verbatim-", suffix=".jsonl", dir=os.path.dirname(path))
    try:
        os.fchmod(fd, st.st_mode & 0o777)
        with os.fdopen(fd, "wb") as f:
            f.write(b"\n".join(out))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return changed


def _scrub_transcripts(session_ids):
    n = 0
    session_map = _session_map()
    for sid in session_ids:
        for p in transcript_paths(sid, session_map):
            try:
                n += scrub_transcript(p)
            except Exception as e:  # noqa: BLE001 - one file must not stop the rest
                log.warning("no-verbatim: transcript for session %s not rewritten (%s)",
                            sid, type(e).__name__)
    return n


# ---------------------------------------------------------------- passes

def _scrub_family(con, named_ids):
    """Every confirmed Slack session among ``named_ids`` and their
    descendants, each in its own transaction and under its own lock, each
    failure its own. Returns counts and the ids whose transcripts to do."""
    counts = {"sessions": 0, "messages": 0, "titles": 0, "obligations": 0, "failed": 0}
    done = []
    for sid, key in _confirmed_slack_sessions(con, named_ids):
        counts["sessions"] += 1
        with _lock_for(sid):
            try:
                c = _scrub_one_in_store(con, sid, key)
            except Exception as e:  # noqa: BLE001 - this session, this pass
                counts["failed"] += 1
                log.warning("no-verbatim: store rows for session %s not rewritten this pass (%s)",
                            sid, type(e).__name__)
                continue
            for k, v in c.items():
                counts[k] += v
            done.append(sid)
    for sid in done:
        with _lock_for(sid):
            counts["transcript_lines"] = counts.get("transcript_lines", 0) + _scrub_transcripts([sid])
    counts.setdefault("transcript_lines", 0)
    return counts


def scrub_session(session_id):
    """One Slack session (and its compression children), store and
    transcript. Synchronous; run in a thread."""
    db = state_db_path()
    # No store, no authority on what is Slack — and so nothing to rewrite.
    if not os.path.exists(db):
        return {"sessions": 0, "messages": 0, "titles": 0, "obligations": 0, "failed": 0,
                "transcript_lines": 0}
    con = _connect(db)
    try:
        return _scrub_family(con, [session_id])
    finally:
        con.close()


def sweep_all():
    """Every Slack session the store knows. Synchronous; run in a thread."""
    db = state_db_path()
    if not os.path.exists(db):
        return {"sessions": 0, "messages": 0, "titles": 0, "obligations": 0, "failed": 0,
                "transcript_lines": 0}
    con = _connect(db)
    try:
        ids = [r[0] for r in con.execute("SELECT id FROM sessions WHERE source=?", (PLATFORM,))]
        return _scrub_family(con, ids)
    finally:
        con.close()


def _receipt(event, session_id, counts):
    if not any(v for k, v in counts.items() if k not in ("sessions",)):
        return
    row = {"at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "event": event,
           "session_id": session_id or "", **counts}
    log.info("no-verbatim: %s", json.dumps(row, ensure_ascii=False))
    path = os.path.join(moe_home(), "logs", "no-verbatim.jsonl")
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    except OSError:
        pass


async def _pass(fn, event, session_id):
    try:
        counts = await asyncio.to_thread(fn)
    except Exception as e:  # noqa: BLE001 - a hook must not take the turn down
        log.warning("no-verbatim: %s pass for %s did not run (%s)",
                    event, session_id or "all", type(e).__name__)
        return
    _receipt(event, session_id, counts)


async def _deferred(session_id, delays):
    for d in delays:
        await asyncio.sleep(d)
        await _pass(lambda: scrub_session(session_id), "agent:end+%g" % d, session_id)


def _spawn(coro):
    try:
        task = asyncio.get_running_loop().create_task(coro)
    except RuntimeError:
        coro.close()
        return
    _pending.add(task)
    task.add_done_callback(_pending.discard)


async def handle(event_type, context):
    ctx = context or {}
    if event_type == "gateway:startup":
        # In the background: the gateway awaits its startup hooks, and a
        # sweep over a large store must not be what stands between a machine
        # and its first turn. Each session commits as it goes.
        _spawn(_pass(sweep_all, "gateway:startup", None))
        return
    if event_type != "agent:end":
        return
    # Cheap early return; not the guard. The store's `source` decides.
    if str(ctx.get("platform") or "") != PLATFORM:
        return
    session_id = str(ctx.get("session_id") or "")
    if not session_id:
        return
    await _pass(lambda: scrub_session(session_id), "agent:end", session_id)
    delays = _delays()
    if delays:
        _spawn(_deferred(session_id, delays))
