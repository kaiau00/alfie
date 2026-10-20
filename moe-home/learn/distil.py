#!/usr/bin/env python3
"""Distil (map): one source's crawl text → one structured digest.

    distil.py <source> <crawl.txt> [--out digest.json] [--chunk-chars N]
    distil.py <source> <crawl.txt> --estimate

The crawl is chunked on line boundaries and each chunk goes to the local
Hermes api_server as one call (prompts/learn-distil.md). Each chunk is
independent, which is the whole point of map/reduce here: a 400 KB source
is ~35 small calls that fit a free tier, not one context-blowing prompt.

Crawled text is attacker-controlled. It is fenced as data in the user
message, the prompt says so in as many words, and nothing from it is ever
interpolated into a shell. The model's reply is parsed strictly: a claim
that is not about one of the five profile files, with a known confidence,
is dropped rather than guessed at.

What is kept (2026-09-22, the owner's rule: important, accurate, current):
the prompt carries the gate — "would this be useful to recall in 6
months?" — and a do-not-extract list; parse_reply then enforces in code
what a prompt can only ask for: a claim sensitive.py refuses (secrets,
health, phone, email, address, payment, money) is dropped and counted,
every claim is `kind` stable or event, and an event is never filed in
identity or people (it is moved to threads). After the last chunk the
digest is collapsed (consolidate.collapse): chunks are independent calls,
so the same fact told in twelve chunks came back twelve times; now it is
one claim whose `evidence` holds the twelve dates.

Digest shape (what merge.py consumes):

    {"source": "imessage", "generated": "2026-08-30", "window_days": 90,
     "chunks": 3, "claims": [{"file": "people", "key": "person:dani",
     "text": "**Dani** — ...", "date": "2026-08-12", "confidence": "high",
     "kind": "stable", "occurred_start": null, "occurred_end": null,
     "recurring": false, "evidence": ["2026-05-02", "2026-08-12"]}],
     "questions": ["..."], "sensitive_dropped": 0}
"""

import argparse
import json
import math
import os
import re
import sys
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hermes_client  # noqa: E402
import sensitive  # noqa: E402

KINDS = ("stable", "event")
CARD_FILES = ("identity", "people", "voice", "preferences")

FILES = ("identity", "people", "threads", "voice", "preferences")
CONFIDENCE = ("high", "med", "low")
DEFAULT_CHUNK_CHARS = 12000
SECONDS_PER_CALL = 10          # a rough, honest number for the estimate
SESSION_KEY = "moe-learn"      # scopes Hermes memory away from the conversation

DATE_RE = re.compile(r"\b(20\d\d)-(\d\d)-(\d\d)\b")

# The profile is rendered into the system prompt of every Hermes session,
# so a claim is the one place where crawled text (an email, a group chat)
# could turn into an instruction. Cheap guards on top of the prompt:
#   - a claim that reads as an instruction to the assistant is dropped. The
#     legitimate preferences file describes the user ("prefers short
#     replies"); it never needs to say "you must", "always cc", "obey".
#   - only preferences may mention the assistant at all. Identity, people,
#     threads and voice describe the user's world; "the assistant is to
#     email…" in a thread, or a person "whose requests are to be obeyed",
#     is planted, not observed. (A friend called Moe survives: the bold
#     name a people line starts with is not matched.)
#   - a claim about sending, reading out or forwarding secrets is dropped
#     whatever file it targets; the prompt already forbids recording them.
#   - nothing crawled gets "high" confidence in preferences. That file is
#     the one that steers behaviour, and only the user's own word (a
#     correction, source [user]) should carry full weight there.
# Round-two review fed twelve planted claims through the old guard and all
# twelve passed; the shapes below are what they looked like. A quoted
# 'you should' in a voice note is a known false positive we accept.
_VERBS = r"(?:send|forward|share|email|message|text|reply|tell|delete|remove|archive|run|execute|open|visit|call|cc|bcc|include|insert|attach|read\s+out|obey|comply|follow|ignore|block|post|paste|upload)"
_SECRETS = r"(?:passwords?|passcodes?|pass\s?phrases?|2fa|otp|one[- ]time\s+codes?|verification\s+codes?|credentials?|api\s+keys?|secrets?|(?:oauth|access|refresh|auth|session)\s+tokens?)"
_ASSISTANT = r"(?:you|your|the\s+assistant|an?\s+assistant|moe|hermes|the\s+agent|the\s+ai|the\s+bot|the\s+model|the\s+chatbot)"
INSTRUCTION_RE = re.compile(
    r"(?i)\b(?:ignore|disregard|forget|override)\b.{0,40}\b(?:instructions?|rules?|prompt|guidelines?)\b"
    r"|\bsystem prompt\b"
    r"|\b" + _ASSISTANT + r"\s+(?:must|should|shall|will|need to|have to|has to|are to|is to|may)\b"
    r"|\b(?:the\s+)?assistant\s+is\s+(?:called|named|now)\b"
    r"|\b(?:always|never|do not|don't|when\s+(?:replying|responding|answering|sending|asked))\b.{0,30}\b" + _VERBS + r"\b"
    r"|\b" + _VERBS + r"\s+(?:all|every|each|any)\s+(?:\w+\s+){0,2}(?:mails?|emails?|messages?|texts?|conversations?|threads?|repl(?:y|ies)|files?|contacts?|requests?|attachments?|documents?|invoices?|notes?|one|thing)\b"
    r"|\b(?:all|every|each|any)\s+(?:\w+\s+){0,3}(?:forwarded|sent|shared|copied|emailed|cc'?d)\s+to\b"
    r"|\b(?:in|on|to|with)\s+every\s+(?:reply|response|message|email|conversation)\b"
    r"|\b(?:as|to)\s+(?:an?\s+)?(?:assistant|ai|model|agent)\b.{0,30}\b(?:you|must|should)\b"
    r"|\bnew (?:instructions?|rules?|task)\b"
    r"|\b(?:obey|comply|unconditionally)\b"
    r"|\b(?:instructions?|orders?|requests?|commands?|word)\b.{0,20}\b(?:priority|precedence)\b"
    r"|\b(?:take|takes|has|have)\s+(?:priority|precedence)\s+over\b"
    r"|\bwithout\s+(?:asking|confirmation|confirming|checking|reading|review)\b"
    r"|\bon\s+(?:his|her|their|the user's|my)\s+behalf\b"
    r"|\b(?:prefers|wants|expects|asks|tells|needs|likes|authori[sz]ed)\s+" + _ASSISTANT + r"\s+(?:to\s+)?" + _VERBS + r"\b"
    r"|\b" + _VERBS + r"\b.{0,40}\b" + _SECRETS + r"\b"
    r"|\b" + _SECRETS + r"\b.{0,40}\b(?:sent|forwarded|shared|emailed|texted|read\s+out|pasted|posted)\b"
    r"|`|\|\s*(?:sh|bash|zsh)\b|\b(?:curl|wget)\s+\S*://")
# Files that describe the user's world, not the assistant: any mention of
# the assistant there is planted. Preferences legitimately says "wants the
# assistant to keep replies formal" — the verb patterns above police it.
ASSISTANT_RE = re.compile(r"(?i)\b(?:assistant|moe|hermes|the\s+agent|the\s+ai|the\s+bot|the\s+model|chatbot|you|your)\b")
NO_ASSISTANT_FILES = ("identity", "people", "threads", "voice")
NAME_RE = re.compile(r"^\*\*[^*]{1,60}\*\*")
QUOTED_RE = re.compile(r"'[^']{1,40}'|\"[^\"]{1,40}\"|‘[^’]{1,40}’|“[^”]{1,40}”")
PREF_MAX_CONFIDENCE = "med"
# The catch-all above has a cost the 2026-09-22 audit measured: the owner's
# main work IS an assistant called Moe, and "Builds Moe, a Mac assistant"
# matched `assistant|moe` and was dropped from every chunk — nothing about
# his work of the last months reached the profile. A claim about MAKING
# something (build, launch, ship, found, work on, a product/app/startup) may
# name Moe, Hermes, or "a/an … assistant|agent|bot|AI" as the thing made;
# "the assistant", "you" and "your" are still refused there, and INSTRUCTION_RE — every directive
# shape, "the assistant must/is to…", "authorised the assistant to send…" —
# still runs on the whole line first.
WORK_RE = re.compile(
    r"(?i)\b(?:build(?:s|ing)?|built|develop(?:s|ing|ed|er|ment)?|launch(?:es|ing|ed)?|ship(?:s|ping|ped)?|"
    r"found(?:er|ed|ing|s)?|co-?founder|work(?:s|ing|ed)?\s+on|product|startup|company|app|release[sd]?|"
    r"design(?:s|ing|ed)?|market(?:s|ing)?|sell(?:s|ing)?|pitch(?:es|ing)?|beta|users?|customers?)\b")
MADE_THING_RE = re.compile(
    r"(?i)\b(?:moe|hermes)\b|\ban?\s+(?:[\w-]+\s+){0,2}(?:assistant|agent|chatbot|bot|model|ai)\b")


def instruction_shaped(file, text):
    """True when a claim must not reach the system prompt."""
    if INSTRUCTION_RE.search(text):
        return True
    if file in NO_ASSISTANT_FILES:
        body = NAME_RE.sub("", text) if file == "people" else text
        # A voice line quotes sign-offs ('love you'); quoted spans are the
        # user's words, not an address to the assistant.
        body = QUOTED_RE.sub(" ", body)
        if WORK_RE.search(body):
            body = MADE_THING_RE.sub(" ", body)
        if ASSISTANT_RE.search(body):
            return True
    return False


def today():
    # Tests pin the clock; nothing else should.
    return os.environ.get("MOE_TODAY") or date.today().isoformat()


def prompt_text(name):
    # learn/ sits beside prompts/ both in the repo and in ~/.moe.
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "..", "prompts", name), encoding="utf-8") as f:
        return f.read()


def chunk_text(text, chunk_chars=DEFAULT_CHUNK_CHARS):
    """Split on line boundaries; a single overlong line is cut hard."""
    chunks, cur, size = [], [], 0
    for line in text.splitlines(keepends=True):
        while len(line) > chunk_chars:
            if cur:
                chunks.append("".join(cur))
                cur, size = [], 0
            chunks.append(line[:chunk_chars])
            line = line[chunk_chars:]
        if size + len(line) > chunk_chars and cur:
            chunks.append("".join(cur))
            cur, size = [], 0
        cur.append(line)
        size += len(line)
    if cur:
        chunks.append("".join(cur))
    return [c for c in chunks if c.strip()]


# ── relative dates, pinned to the message that said them (ticket #9) ─────
#
# A WhatsApp from 2026-09-21 22:45 said "invite has been sent for tomorrow at
# 10". The model resolved "tomorrow" against the day the crawl ran, and
# threads.md got "Project Atlas call scheduled for 2026-09-23 at 10am" — a
# day late, and on the 23rd Moe announced it as today's. The prompt already
# said to use the message's own date; asking was not enough. So the date is
# worked out here, in code, from the timestamp at the head of the line (or
# of the last line that had one — a mail body inherits its header's), and
# written into the text beside the words: "tomorrow at 10 [= 2026-09-22
# 10:00]". The model copies an absolute date; it never does the arithmetic.

from datetime import timedelta  # noqa: E402

STAMP_RE = re.compile(r"^\s*\[?(20\d\d)-(\d\d)-(\d\d)(?:[ T](\d{1,2}):(\d{2}))?")
_WEEKDAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
_AT = r"(?:[ \t]+at[ \t]+(?P<h>\d{1,2})(?::(?P<m>\d{2}))?(?:[ \t]*(?P<ap>a\.?m\.?|p\.?m\.?))?(?![\w:]))?"
RELATIVE_RE = re.compile(
    r"(?i)\b(?P<phrase>day after tomorrow|tomorrow(?:[ \t]+(?:morning|afternoon|evening|night))?"
    r"|tonight|this[ \t]+(?:morning|afternoon|evening)|today|yesterday|next[ \t]+week|this[ \t]+weekend"
    r"|(?P<dir>on|this|next)[ \t]+(?P<wd>" + "|".join(_WEEKDAYS) + r"))\b" + _AT)


#: A quoted line: ">" at the start of the text or of any "|"-separated field
#: (the message text follows the sender in the chat crawls).
QUOTE_RE = re.compile(r"(?:^|\|)[ \t]*>")
FORWARD_RE = re.compile(r"(?i)-*[ \t]*forwarded message|\bfwd?(?::|[ \t]+from\b)")


def _resolve(phrase, day):
    """(date, suffix) for one relative phrase said on `day`, or None."""
    p = " ".join(phrase.lower().split())
    if p.startswith("day after tomorrow"):
        return day + timedelta(days=2), ""
    if p.startswith("tomorrow"):
        part = p[len("tomorrow"):].strip()
        return day + timedelta(days=1), (" " + part if part else "")
    if p == "tonight":
        return day, " evening"
    if p.startswith("this ") and p.split()[1] in ("morning", "afternoon", "evening"):
        return day, " " + p.split()[1]
    if p == "today":
        return day, ""
    if p == "yesterday":
        return day - timedelta(days=1), ""
    if p == "next week":
        monday = day + timedelta(days=7 - day.weekday())
        return monday, None                       # "week of <monday>"
    if p == "this weekend":
        return day + timedelta(days=(5 - day.weekday()) % 7), " weekend"
    words = p.split()
    if len(words) == 2 and words[1] in _WEEKDAYS:
        ahead = (_WEEKDAYS.index(words[1]) - day.weekday()) % 7
        if words[0] in ("on", "next") and ahead == 0:
            ahead = 7                             # "on Monday", said on a Monday: next one
        return day + timedelta(days=ahead), ""
    return None


def anchor_relative_dates(text):
    """`text` with every relative date the crawl can pin written out beside
    it, against the timestamp of the message it is in. Lines with no
    timestamp above them are left exactly as they were."""
    out, anchor, quoted = [], None, False
    for line in text.splitlines(keepends=True):
        m = STAMP_RE.match(line)
        if m:
            try:
                anchor = date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
            except ValueError:
                anchor = None
            body_from = m.end()
            quoted = False                    # a new message ends a forwarded block
        else:
            body_from = 0
        if anchor is None or quoted:
            out.append(line)
            continue
        # Quoted or forwarded words were said on another day, which this
        # line's stamp does not know: "> see you tomorrow" in a reply, or
        # everything after "Fwd:" / "Forwarded message". Left as written.
        body = line[body_from:]
        if QUOTE_RE.search(body):
            out.append(line)
            continue
        fwd = FORWARD_RE.search(body)
        if fwd:
            quoted = True
            line = line[:body_from + fwd.start()]
            rest = body[fwd.start():]
        else:
            rest = ""

        def note(r, anchor=anchor):
            got = _resolve(r.group("phrase"), anchor)
            if got is None:
                return r.group(0)
            when, suffix = got
            if suffix is None:
                return "%s [= week of %s]" % (r.group(0), when.isoformat())
            clock = ""
            if r.group("h"):
                h, mnt = int(r.group("h")), int(r.group("m") or 0)
                ap = (r.group("ap") or "").lower().replace(".", "")
                if ap == "pm" and h < 12:
                    h += 12
                elif ap == "am" and h == 12:
                    h = 0
                if h > 23 or mnt > 59:
                    return r.group(0)
                clock = " %02d:%02d" % (h, mnt)
            return "%s [= %s%s%s]" % (r.group(0), when.isoformat(), clock, "" if clock else suffix)

        out.append(line[:body_from] + RELATIVE_RE.sub(note, line[body_from:]) + rest)
    return "".join(out)


def estimate(text, chunk_chars=DEFAULT_CHUNK_CHARS):
    n = len(chunk_text(text, chunk_chars))
    return {"bytes": len(text.encode("utf-8")), "chunks": n, "calls": n,
            "seconds": n * SECONDS_PER_CALL}


def valid_date(s):
    m = DATE_RE.search(str(s or ""))
    if not m:
        return None
    try:
        return date(int(m.group(1)), int(m.group(2)), int(m.group(3))).isoformat()
    except ValueError:
        return None


def latest_date_in(text):
    """The most recent date the text mentions, never a future one. A crawl is
    evidence of what has already happened, but a connected service's metadata
    is full of forward-looking dates — a metric certification "valid until
    2026-09-24", a renewal, an expiry. Taking the max unbounded dated every
    Pulse claim five days ahead: it read as wrong in the profile, `merge.py
    expire` never aged it out, and it beat genuinely newer claims on the
    newer-wins rule."""
    now, best = today(), None
    for m in DATE_RE.finditer(text):
        d = valid_date(m.group(0))
        if d and d <= now and (best is None or d > best):
            best = d
    return best


def parse_reply(reply, fallback_date, stats=None, force_file=None):
    """Strict: a malformed reply yields no claims, never a guess.
    `stats` (a dict) is bumped so the caller can tell "the model found
    nothing" from "the model's reply could not be read"."""
    try:
        obj = hermes_client.extract_json(reply)
    except ValueError:
        if stats is not None:
            stats["unparsed"] = stats.get("unparsed", 0) + 1
        return [], []
    claims = []
    for c in obj.get("claims") or []:
        if not isinstance(c, dict):
            continue
        f = force_file or str(c.get("file", "")).strip().lower()
        text = " ".join(str(c.get("text", "")).split())
        conf = str(c.get("confidence", "")).strip().lower()
        if f not in FILES or not text or conf not in CONFIDENCE:
            continue
        # Provenance tags are ours to write; strip one the model added.
        text = re.sub(r"\s*\[[^\]]*\]\s*$", "", text)
        if not text:
            continue
        if instruction_shaped(f, text):
            if stats is not None:
                stats["dropped"] = stats.get("dropped", 0) + 1
            continue
        if f == "preferences" and conf == "high":
            conf = PREF_MAX_CONFIDENCE
        # The refusal the prompt only asks for (sensitive.py): a secret, a
        # health line, a phone number, an email, an address, a payment detail
        # or an amount of money never reaches the digest.
        if sensitive.sensitive(text):
            if stats is not None:
                stats["sensitive"] = stats.get("sensitive", 0) + 1
            continue
        key = " ".join(str(c.get("key") or "").split()).lower()[:80] or None
        # The model can echo a date out of the crawl too ("valid until …"), so
        # the same rule applies here: a claim is dated when it was observed, and
        # that is never later than today.
        date = valid_date(c.get("date")) or fallback_date
        if date > today():
            date = fallback_date if fallback_date <= today() else today()
        # When an event happens is not when it was mentioned: occurred_* may
        # be in the future (an upcoming trip), `date` never is.
        start, end = valid_date(c.get("occurred_start")), valid_date(c.get("occurred_end"))
        if start and end and end < start:
            start, end = end, start
        kind = str(c.get("kind") or "").strip().lower()
        if kind not in KINDS:
            kind = "event" if (f == "threads" or start or end) else "stable"
        recurring = c.get("recurring") is True
        # Events are never cards: one filed in identity/people moves to threads.
        if kind == "event" and f in CARD_FILES and not force_file:
            f = "threads"
            text = re.sub(r"^\*\*([^*]{1,60})\*\*", r"\1", text)
            if key and key.startswith("person:"):
                key = None
        claims.append({"file": f, "key": key, "text": text[:400],
                       "date": date, "confidence": conf, "kind": kind,
                       "occurred_start": start, "occurred_end": end, "recurring": recurring})
    questions = []
    for q in obj.get("questions") or []:
        q = " ".join(str(q).split())
        if q and not sensitive.sensitive(q):
            questions.append(q[:300])
    return claims, questions


PROFILE_PROMPTS = {"personal": "learn-distil.md", "gather": "learn-gather.md",
                   # Another assistant's memory, pasted by the person (learn/import_memory.py).
                   "import": "learn-import.md"}


def distil(source, text, chunk_chars=DEFAULT_CHUNK_CHARS, window_days=None, chat=None, log=None, profile="personal"):
    chat = chat or hermes_client.chat
    system = prompt_text(PROFILE_PROMPTS.get(profile) or PROFILE_PROMPTS["personal"])
    # A gather source (a connected service) has no people/threads/voice — its
    # facts are all about the user's world, filed under identity. The prompt
    # (learn-gather.md) is general; the file is forced here, not trusted from it.
    force_file = "identity" if profile == "gather" else None
    claims, questions = [], []
    stats = {"unparsed": 0, "dropped": 0, "sensitive": 0}
    chunks = chunk_text(text, chunk_chars)
    for i, chunk in enumerate(chunks, 1):
        if log:
            log("distil %s: chunk %d/%d" % (source, i, len(chunks)))
        user = "Today: %s\nSource: %s\n\n<crawl>\n%s\n</crawl>" % (
            today(), source, anchor_relative_dates(chunk))
        # The crawl text is the rawest untrusted input in the pipeline. Distil
        # only transforms it to JSON, so the turn runs with NO tools — a
        # prompt-injection in an email or chat has nothing to act with.
        reply = chat(system, user, SESSION_KEY, enabled_toolsets=[hermes_client.NO_TOOLS])
        before = stats["unparsed"]
        # An import is a list of separate notes: one note's date says nothing
        # about another's, so an undated one is dated the day it was
        # imported, never a neighbour's day (review 2026-09-29).
        fallback = today() if profile == "import" else (latest_date_in(chunk) or today())
        cs, qs = parse_reply(reply, fallback, stats, force_file=force_file)
        if stats["unparsed"] > before and log:
            # A half-delivered SSE stream or a refusal looks exactly like an
            # empty chunk otherwise; say so once, so a digest with nothing
            # in it can be told from a source with nothing in it.
            log("distil %s: chunk %d/%d: no JSON in the reply (%d chars), skipped" % (source, i, len(chunks), len(reply or "")))
        # Every copy is kept here: collapse_digest (below) makes them one
        # claim and keeps each copy's date as evidence, which is what
        # `support` counts. Dropping a repeat here lost that count.
        claims.extend(cs)
        for q in qs:
            if q not in questions:
                questions.append(q)
    claims, more = collapse_digest(source, claims)
    for q in more:
        if q not in questions:
            questions.append(q)
    return {"source": source, "generated": today(), "window_days": window_days,
            "chunks": len(chunks), "unparsed_chunks": stats["unparsed"], "dropped_claims": stats["dropped"],
            "sensitive_dropped": stats["sensitive"], "claims": claims, "questions": questions}


def collapse_digest(source, claims):
    """One claim per topic across the whole digest (consolidate.collapse),
    the dates of every copy kept as its evidence. Returns (claims, questions)."""
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("moe_consolidate_d", os.path.join(here, "consolidate.py"))
    cons = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cons)
    P = cons.P
    objs = []
    for c in claims:
        o = P.Claim(c["file"], c["text"], source, c["date"], c["confidence"], P.normalize_key(c.get("key")),
                    kind=c.get("kind"), occurred_start=c.get("occurred_start"),
                    occurred_end=c.get("occurred_end"), recurring=c.get("recurring"))
        objs.append(o)
    kept, _dropped, questions = cons.collapse(objs)
    order = {id(o): i for i, o in enumerate(objs)}
    out = []
    for o in sorted(kept, key=lambda o: order.get(id(o), 0)):
        out.append({"file": o.file, "key": o.key, "text": o.text, "date": o.date,
                    "confidence": o.confidence, "kind": o.kind, "occurred_start": o.occurred_start,
                    "occurred_end": o.occurred_end, "recurring": o.recurring, "evidence": list(o.evidence)})
    return out, questions


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("source")
    ap.add_argument("crawl")
    ap.add_argument("--out")
    ap.add_argument("--chunk-chars", type=int, default=int(os.environ.get("MOE_LEARN_CHUNK_CHARS", DEFAULT_CHUNK_CHARS)))
    ap.add_argument("--window-days", type=int)
    ap.add_argument("--estimate", action="store_true", help="print the cost estimate as JSON and exit")
    ap.add_argument("--profile", default="personal", choices=list(PROFILE_PROMPTS),
                    help="which distil prompt: personal (mail/chat/notes) or gather (a connected service)")
    args = ap.parse_args(argv)
    if not re.match(r"^[A-Za-z0-9_-]+$", args.source):
        ap.error("source must be a connector name")
    with open(args.crawl, encoding="utf-8", errors="replace") as f:
        text = f.read()
    if args.estimate:
        print(json.dumps(estimate(text, args.chunk_chars)))
        return 0
    try:
        digest = distil(args.source, text, args.chunk_chars, args.window_days,
                        log=lambda m: print(m, file=sys.stderr), profile=args.profile)
    except hermes_client.HermesError as e:
        print("distil: %s" % e, file=sys.stderr)
        return 3
    out = json.dumps(digest, indent=1, ensure_ascii=False)
    if args.out:
        tmp = args.out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(out + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, args.out)
    else:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
