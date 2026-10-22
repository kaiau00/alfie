"""The sweep: what the conversation left open, found once it is over.

The brain is asked to write a loop down in the turn it hears one
(`moe_followups open`, docs/LOOPS.md §2). It will miss some — a promise made
in passing, a booking it started and never noted — and the owner's answer
was "both": the turn, and a sweep at the end of the conversation that reads
back over what the person said and catches the rest.

One small-model call per finished conversation, with nothing in it but the
person's own turns: no tools, no memory, no system prompt beyond the
question. It answers with JSON — a short list of loops, or an empty one —
and each is opened through `deliver.open_loop` with `source: sweep`, so a
later reader can see which door it came in by. Never more than a few per
sweep, never a slug already open, and nothing at all while Background
thinking is off: this is model spend on work nobody asked for right now,
which is exactly what that switch governs.

`call` is injected. In production it is Hermes's `call_llm(task="classify")`,
which on a subscription brain is served by the Claude Code CLI lane (the
fork's aux-cli-lane branch); until that lane exists on a Mac the call raises
or returns nothing, and this does nothing, quietly. Every failure here is a
log line: a sweep that could not run costs a follow-up, and a raised
exception in a session-end hook costs the session.

Python 3.9, stdlib only, like the rest of this plugin.
"""

import json
import logging
import re

from . import deliver as _deliver

logger = logging.getLogger(__name__)

#: How much of the conversation the sweep reads: the person's last turns,
#: newest last, up to this many characters. A sweep is not a transcript
#: search; what was said an hour ago and forty turns back is the brain's
#: job to have noted at the time.
MAX_USER_TURNS = 30
MAX_CHARS = 6000
#: Fewer user turns than this is a question, not a conversation.
MIN_USER_TURNS = 2
#: One turn's share. A pasted document is one turn and can be 60 KB; whole,
#: it would fill MAX_CHARS alone and crowd every other turn out.
MAX_TURN_CHARS = 1500
#: Loops one sweep may open. Five is a busy afternoon.
MAX_OPENED = 5
SOURCE = "sweep"
_SLUG = re.compile(r"^[a-z0-9-]{1,40}\Z")

SYSTEM = (
    "You read the end of a conversation between a person and their assistant, "
    "Alfie, and list what was left open — things worth Alfie coming back to later "
    "without being asked. Five kinds: said (the person said they would do "
    "something), started (Alfie began something whose outcome is still to come: "
    "a booking, an order, an application), waiting (a person is waiting on them "
    "for an answer), deadline (a date to prepare for), watch (a price, slot or "
    "page they looked at that can change). Only what the person actually said "
    "or Alfie actually did; never a guess, never a newsletter or a receipt. Skip "
    "anything in the already-open list.\n\n"
    "Answer with JSON only: a list of objects with keys slug (lower-case "
    "letters, digits, hyphens, up to 40), what (one line with the detail needed "
    "to act later: who, which, the price as it was), kind (one of the five), "
    "when (3h, 2d, tomorrow-morning, or an ISO 8601 time — the moment it is "
    "worth a word). An empty list is a fine answer."
)


#: What Moe wraps around the person's words before the brain sees them
#: (measured in Hermes's state.db on 2026-09-24): a Now line first; the
#: brief, which ends in a line and `---`; parenthetical notes (typed mode,
#: an interruption, a meeting); and, after the words, the "# Before you
#: answer" reminder — about 3.3 KB on every island turn. None of it is the
#: person's, and the reminder alone is over half of MAX_CHARS, so reading
#: turns whole kept one turn out of any conversation and the sweep always
#: stopped at MIN_USER_TURNS.
_REMINDER = re.compile(r"\n#{1,6} Before you answer\b")
_NOW_LINE = re.compile(r"^Now: [^\n]*\n+")
_BRIEF_END = re.compile(r"</brief>.*?\n-{3,}[ \t]*\n", re.S)
_TAGGED = re.compile(r"<([A-Za-z][\w-]*)>.*?</\1>", re.S)
_NEW_MESSAGE = "[New message]"
#: The line Moe puts between what it carries in front of a turn (a nudge's
#: card, a restarted brain's transcript, the brief) and the turn itself
#: (Conductor.submit). It is Moe's only where it follows one of Moe's own
#: notes: a `---` the person typed in their own words is theirs, and what
#: they said above it stays.
_SEPARATOR_AT_START = re.compile(r"-{3,}[ \t]*(\n|\Z)")
#: A note that says of itself that it is not the person — "(Background note,
#: not from the user. …)". What follows it, unless Moe's separator comes
#: first, is what the note introduced (a helper's result, a restored
#: transcript), never the person's words. The app also declares these turns
#: `background` (X-Hermes-Turn-Origin) and per-turn learning reads that; this
#: is for the readers that only have the transcript, like the sweep.
_NOT_THE_PERSON = re.compile(r"\bnot from the (?:user|person)\b", re.I)
#: Hermes's own count of what rode with a multimodal turn, put in front of
#: its text when the turn is flattened ("[1 image] Now: …"). Not Hermes
#: talking the way a cron prompt's "[IMPORTANT: …" is.
_ATTACHED = re.compile(r"^\[\d+ (?:image|file|attachment)s?\]\s*")
#: Quotation marks inside a note: what the note quotes (the words the person
#: heard of an interrupted reply, a card's text) can hold any bracket at
#: all, so brackets inside them do not count toward the note's end.
_QUOTES = {"\u201c": "\u201d", '"': '"'}


def _strip_leading_note(text):
    """`text` without one leading "(…)" note, or None if there is none or it
    never closes. Parentheses are matched by depth, and not counted inside
    what the note quotes: "only up to: “1) the lease…”" is still one note."""
    if not text.startswith("("):
        return None
    depth = 0
    closing = None
    for i, ch in enumerate(text):
        if closing is not None:
            if ch == closing:
                closing = None
            continue
        if ch in _QUOTES:
            closing = _QUOTES[ch]
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return text[i + 1:]
    return None


def persons_text(text):
    """`persons_words` with the person's own line breaks kept — for a reader
    that has to see a paste's shape (a fence, a quoted line) to leave it out."""
    text = _ATTACHED.sub("", str(text or "").lstrip(), count=1)
    m = _REMINDER.search(text)
    if m:
        text = text[:m.start()]
    text = _NOW_LINE.sub("", text.lstrip(), count=1)
    m = _BRIEF_END.search(text)
    if m:
        text = text[m.end():]
    if _NEW_MESSAGE in text:   # a chat channel: "<context>\n\n[New message]\n<text>"
        text = text.split(_NEW_MESSAGE, 1)[1]
    # Whatever Moe carries in a tag pair (<live-transcript>, <helper-result>,
    # <earlier-conversation>, …) is somebody else's words or Moe's own. By
    # shape, not by name: a new block needs no line here to be left out,
    # and a pasted block of markup is not the person talking either.
    text = _TAGGED.sub("", text)
    # Moe's notes, one after another, each with the separator that may follow
    # it. A note that says it is not the person, with no separator straight
    # after, is the whole turn; so is one that never closes.
    while True:
        text = text.lstrip()
        if not text.startswith("("):
            break
        rest = _strip_leading_note(text)
        not_theirs = bool(_NOT_THE_PERSON.search(text[:240]))
        if rest is None:
            if not_theirs:
                return ""
            break
        rest = rest.lstrip()
        m = _SEPARATOR_AT_START.match(rest)
        if m:
            text = rest[m.end():]
        elif not_theirs:
            return ""
        else:
            text = rest
    # A turn that is still bracketed is Hermes talking, not the person:
    # "[IMPORTANT: You are running as a scheduled cron job…".
    if text.startswith("["):
        return ""
    return text.strip()


def persons_words(text):
    """The person's own words out of a user turn as Alfie sent it, or "" when
    the turn carries none (a background note, a scheduled job's prompt)."""
    return " ".join(persons_text(text).split())


def user_turns(messages, limit=MAX_USER_TURNS, chars=MAX_CHARS):
    """The person's own turns, newest last, bounded. Tool results, the
    assistant's replies and anything without text are left out: the sweep is
    about what THEY said and what Alfie did, and Alfie's own doing is in what
    they asked for."""
    out = []
    for m in messages or []:
        if not isinstance(m, dict) or m.get("role") != "user":
            continue
        content = m.get("content")
        if isinstance(content, list):
            content = "\n".join(str(p.get("text") or "") for p in content
                                if isinstance(p, dict) and p.get("type") in (None, "text"))
        text = persons_words(content)
        if len(text) > MAX_TURN_CHARS:
            text = text[:MAX_TURN_CHARS].rstrip() + "…"
        if text:
            out.append(text)
    out = out[-limit:]
    total = 0
    kept = []
    for text in reversed(out):
        if total + len(text) > chars:
            break
        kept.append(text)
        total += len(text)
    return list(reversed(kept))


def _answer_text(result):
    """The model's text out of whatever the aux client returned."""
    if result is None:
        return ""
    if isinstance(result, str):
        return result
    try:
        choices = getattr(result, "choices", None) or result.get("choices")
        message = choices[0].message if hasattr(choices[0], "message") else choices[0]["message"]
        content = getattr(message, "content", None) or message.get("content")
        return str(content or "")
    except Exception:  # noqa: BLE001
        return str(result)


def parse_loops(text):
    """The JSON list out of an answer, tolerant of a fenced block or a
    sentence around it. Anything unreadable is no loops."""
    text = str(text or "").strip()
    if not text:
        return []
    m = re.search(r"\[.*\]", text, re.S)
    if not m:
        return []
    try:
        data = json.loads(m.group(0))
    except ValueError:
        return []
    return [d for d in data if isinstance(d, dict)] if isinstance(data, list) else []


def default_call(messages):
    """The cheapest model the person's own provider serves (lib/cheap_model.py,
    model-tiers.json), never the conversation's model: on any brain but a
    Claude plan an unpinned `classify` call runs on the main model."""
    return _cheap_model().call(messages, max_tokens=600, timeout=60)


def _cheap_model():
    """`lib/cheap_model.py`, from `$MOE_HOME/lib` (installed) or two
    directories up (the repo). By path: this plugin is not beside it."""
    import importlib.util
    import os
    import sys
    mod = sys.modules.get("cheap_model")
    if mod is not None:
        return mod
    here = os.path.dirname(os.path.abspath(__file__))
    home = os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")
    for path in (os.path.join(home, "lib", "cheap_model.py"),
                 os.path.join(here, "..", "..", "lib", "cheap_model.py")):
        if os.path.isfile(path):
            spec = importlib.util.spec_from_file_location("cheap_model", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            sys.modules["cheap_model"] = mod
            return mod
    raise ImportError("lib/cheap_model.py is not installed")


def sweep(messages, now=None, call=None, cfg=None):
    """Read the conversation's end and open what it left open.

    Returns the slugs opened. Never raises."""
    try:
        cfg = cfg if cfg is not None else _deliver.read_config()
        if cfg.get("backgroundThinking", True) is False:
            return []
        turns = user_turns(messages)
        if len(turns) < MIN_USER_TURNS:
            # Logged like every other outcome: this early return is where
            # the sweep sat, invisibly, for every conversation until
            # 2026-09-24 (see _REMINDER).
            logger.info("sweep: %d turn(s) of the person's own words, fewer than %d; nothing to read",
                        len(turns), MIN_USER_TURNS)
            return []
        already = sorted(_deliver.read_open())
        user = ("Already open (skip these): %s\n\nThe person's turns, oldest first:\n%s"
                % (", ".join(already) or "none",
                   "\n".join("- %s" % t for t in turns)))
        result = (call or default_call)([{"role": "system", "content": SYSTEM},
                                        {"role": "user", "content": user}])
        opened = []
        proposed = parse_loops(_answer_text(result))
        for item in proposed[:MAX_OPENED]:
            slug = str(item.get("slug") or "").strip().lower()
            if not _SLUG.match(slug) or slug in already:
                continue
            ok, why = _deliver.open_loop(slug, item.get("what"), kind=item.get("kind"),
                                         when=str(item.get("when") or ""), now=now,
                                         source=SOURCE)
            if ok:
                opened.append(slug)
            else:
                logger.info("sweep: %s not opened: %s", slug, why)
        # Always one line, even for nothing: on the owner's Mac (2026-09-11)
        # a silent sweep and a sweep that never ran read the same in
        # agent.log, and the only way to tell them apart was to reason about
        # session boundaries. A check that cannot be seen to run is a check
        # that cannot fail.
        logger.info("sweep: %d turn(s) read, %d loop(s) proposed, %d opened%s",
                    len(turns), len(proposed), len(opened),
                    (": " + ", ".join(opened)) if opened else "")
        return opened
    except Exception as e:  # noqa: BLE001 — see the module note
        logger.info("sweep: skipped: %s: %s", type(e).__name__, e)
        return []
