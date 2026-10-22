#!/usr/bin/env python3
"""The profile store — "What Alfie knows about you" as a data layer.

    profile.py list [--file NAME] [--json] [--active]
    profile.py show <file>
    profile.py summary                      summary.md's text; nothing (exit 0) if none
    profile.py search <words> [--json]      active AND archived claims
    profile.py check [--json]               the "check these" list (≤ 5 items)
    profile.py delete <claim-id> [--json]
    profile.py correct <claim-id> "<new text>" [--json]
    profile.py confirm <claim-id> [--json]  "Right": the line becomes the person's
    profile.py restore <claim-id> [--json]  an archived claim back into its file
    profile.py answer "<question>" "<text>" [--file F] [--json]
                                            the answer kept as the person's line; the question closes
    profile.py dismiss "<question>" [--json]
                                            close a question (questions.md, held, or the check's own)
    profile.py expire --days N
    profile.py retire-all --learned         the wipe before a re-learn (see below)

    profile.py get|set|due|stamp|sources …   the per-SOURCE learning profile
                                             (forwarded to source_profile.py)

Files live in $MOE_HOME/memory/profile/ — identity, people, threads,
voice, preferences (.md) — and every line that is a claim looks like:

    - **Dani** — sister; talks daily [imessage, 2026-08-12, high]

Plain markdown, editable by hand, one claim per line, provenance at the
end: source, date of the latest evidence, confidence. That tag is what lets
a claim be corrected, expired, or cited ("that's from a March thread").

A claim id is the first 10 hex chars of sha1(file + normalised text). It
depends on nothing else, so re-confirming a claim from another crawl keeps
its id, and a hand-edited date does not orphan a link in the app.

The UI contract (Sources/Moe/Memory/MemoryPane.swift, MemoryReader) —
`list --json` prints one JSON array; every object has

    id, file, text, source, date, confidence, key      (since the start)
    kind          "stable" | "event"                    (since 2026-09-22)
    active        true for a line in its file, false for an archived one
    occurred_start, occurred_end   ISO date or null — WHEN an event happens,
                  as opposed to `date`, the latest evidence (mention) of it
    support       int ≥ 1: independent dated sightings of this claim
    reason        only on an archived claim: past | superseded | duplicate |
                  cap | moved | retired  (and `archived`, the date it was)
    flag          only when set, only on an active crawled claim, and only
                  on a line the "check these" list is about (so never more
                  lines than `check` has items, ≤ 5): "contradicts" (it
                  disagrees with another line; the question is in
                  questions.md), "question" (an open question quotes it),
                  "unsure" (low confidence, identity/people/preferences) or
                  "new" (first seen in the latest learn run that added
                  lines to a profile that already had some — a first seed,
                  or the first pass after retire-all, flags nothing). A
                  line the person wrote, corrected or confirmed (source
                  "user") never has a flag.

`check --json` prints the list the page shows under "Check these" — the
same one check.md holds — as a JSON array, at most MAX_CHECK (5), in
priority order contradicts > question > unsure > new:

    [{"kind": "contradicts"|"question"|"unsure"|"new",
      "text": "<the question, or the line's text>",
      "ids":  ["<claim id>", ...]}]          ids: the lines it is about;
                                             [] for a free-text question

Inline editing on the Memory page — one command per action, each exits 0
on success, 1 for an unknown id (2 for an empty correction), and with
--json prints ONE object on stdout:

    edit text   profile.py correct <id> "<new text>" --json
    forget      profile.py delete  <id> --json
    "Right"     profile.py confirm <id> --json
    bring back  profile.py restore <id> --json

    {"ok": true, "action": "correct"|"delete"|"confirm"|"restore",
     "id": "<the id you passed>", "claim": {<the list --json object>}}
    {"ok": false, "action": ..., "id": ..., "error": "no claim with id …"}

`claim` is the line as it now is: for correct, the NEW line (new text, so
a NEW id — replace the row's id with claim.id); for confirm, the same text
and so the SAME id with source "user", confidence "high", no flag; for
delete, the line that was removed. After any of them the page should
re-read `list --json` and `check --json`: each also rewrites check.md,
closes any open question quoting the line (confirm also archives the
other side of a contradiction it settles, `superseded`, tombstoned), and
promotes a held question into the freed place.

What makes an edit stick: correct and confirm both leave a line with
source "user", and every nightly pass leaves those alone — consolidate.py
never removes one as sensitive, moves or trims it, merges it into another
line (two of the person's lines on one topic both stay), retires it as a
past event, caps it away, or flags it; merge.py lets no crawl add a
competing line on a topic the person has spoken on, and a corrected or
deleted line is tombstoned by id and topic key so no crawl brings it back.

The list holds active AND archived claims (`active` tells them apart);
`--active` leaves the archive out, which is what the moe_profile tool asks
for. An app build from before 2026-09-22 reads none of the new fields and
would draw an archived line as a current one — but the payload ships
inside the app and is installed with it, so an old app does not meet this
profile.py on a Mac; the cloud machine runs no app. `summary` prints
memory/profile/summary.md (the nightly "current picture", first line
`# Current picture`) and prints nothing, exit 0, when there is none.

Stable facts and events (docs/MEMORY.md §8). A stable claim is a card fact
that would still be true in six months (who someone is, where the person
works). An event happens at a time — occurred_start/occurred_end — and
lives only in threads.md. An event whose end is more than 30 days gone,
and which does not recur, is ARCHIVED by learn/consolidate.py: out of the
file, out of the prompt, kept in archive.md, findable by `search` and
`list --all`, and `restore` puts it back.

Sidecars, all optional and all regenerable:
  .keys.json        {file: {claim id: topic key}} — the digest's "person:dani",
                    which is how merge.py finds two claims about one thing
  .tombstones.json  {"ids": [...], "keys": ["file\tkey", ...]} — claims the
                    user deleted or corrected, by id and by topic key;
                    merge.py never lets a crawl bring either back
  .meta.json        {"files": {file: {id: meta}}, "archive": {id: meta}} —
                    kind, occurred_start/end, recurring, evidence (the dated
                    sightings support counts), first_seen; for the archive
                    also origin file, key, reason, archived date and `by`
                    (the claim that superseded it)
  archive.md        the archived lines, grouped by the file they came from
  summary.md        the nightly current picture (consolidate.py)
  check.md          "Check these": the same ≤ 5 items `check` prints

`retire-all --learned` is the reset before a re-learn: it copies the whole
profile to backups/retired-<date>/, moves every crawled line (never the
person's own `user` lines) into the archive with reason `retired`, removes
summary.md, check.md and questions.md, and deletes the digests and the
per-source seed/update stamps — so the next `learn.sh all --stage update`
seeds every consented source from scratch. The changed files travel to
the cloud machine as the ledger's `profile/…` documents like any edit.

Python 3.9, stdlib only.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys
from datetime import date, timedelta

FILES = ("identity", "people", "threads", "voice", "preferences")
HEADINGS = {"identity": "Identity", "people": "People", "threads": "Threads",
            "voice": "Voice", "preferences": "Preferences"}
CONFIDENCE = ("high", "med", "low")
CONF_RANK = {"high": 3, "med": 2, "low": 1}
USER_SOURCE = "user"
KINDS = ("stable", "event")
# Where each kind may live: an event is a thing that happens at a time, and
# identity/people are cards of what stays true (docs/MEMORY.md §8).
EVENT_FILES = ("threads",)
# How long after an event ends it stays in the profile, then is archived.
EVENT_GRACE_DAYS = 30
# How many dated sightings a claim remembers (support counts them); bounded
# so .meta.json stays far below the ledger's 256 KB document limit.
MAX_EVIDENCE = 12
# The archive keeps this many lines, newest-archived first.
MAX_ARCHIVE = 400
ARCHIVE_REASONS = ("past", "superseded", "duplicate", "cap", "moved", "retired")

CLAIM_RE = re.compile(
    r"^\s*[-*]\s+(?P<text>.*?)\s*\[(?P<source>[A-Za-z0-9_-]+),\s*(?P<date>\d{4}-\d{2}-\d{2}),\s*(?P<conf>high|med|low)\]\s*$")
NAME_RE = re.compile(r"^\*\*([^*]{1,60})\*\*")
ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def today():
    return os.environ.get("MOE_TODAY") or date.today().isoformat()


def profile_dir():
    return os.environ.get("MOE_PROFILE_DIR") or os.path.join(
        os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe"), "memory", "profile")


def normalise(text):
    return " ".join(text.split()).lower()


def claim_id(file, text):
    h = hashlib.sha1(("%s\n%s" % (file, normalise(text))).encode("utf-8")).hexdigest()
    return h[:10]


def iso_or_none(s):
    s = str(s or "").strip()[:10]
    if not ISO_RE.match(s):
        return None
    try:
        return date.fromisoformat(s).isoformat()
    except ValueError:
        return None


class Claim(object):
    __slots__ = ("file", "text", "source", "date", "confidence", "key",
                 "kind", "occurred_start", "occurred_end", "recurring", "evidence", "first_seen",
                 "reason", "archived", "by", "flag")

    def __init__(self, file, text, source, date, confidence, key=None, kind=None,
                 occurred_start=None, occurred_end=None, recurring=False, evidence=None, first_seen=None):
        self.file, self.text, self.source = file, " ".join(text.split()), source
        self.date, self.confidence, self.key = date, confidence, key
        self.kind = kind if kind in KINDS else default_kind(file)
        self.occurred_start, self.occurred_end = iso_or_none(occurred_start), iso_or_none(occurred_end)
        self.recurring = bool(recurring)
        ev = sorted(set(d for d in (evidence or []) if iso_or_none(d)))
        if not ev and iso_or_none(date):
            ev = [date]
        self.evidence = ev[-MAX_EVIDENCE:]
        self.first_seen = iso_or_none(first_seen)
        self.reason = self.archived = self.by = None
        # "contradicts" while a question about this line is open (merge.py,
        # consolidate.py); "new" is derived at listing time (Store.flag_of).
        self.flag = None

    @property
    def id(self):
        return claim_id(self.file, self.text)

    @property
    def support(self):
        return max(1, len(self.evidence))

    @property
    def active(self):
        return self.reason is None

    def line(self):
        return "- %s [%s, %s, %s]" % (self.text, self.source, self.date, self.confidence)

    def add_evidence(self, dates):
        ev = set(self.evidence)
        ev.update(d for d in dates if iso_or_none(d))
        self.evidence = sorted(ev)[-MAX_EVIDENCE:]

    def meta(self):
        m = {"kind": self.kind}
        if self.occurred_start:
            m["occurred_start"] = self.occurred_start
        if self.occurred_end:
            m["occurred_end"] = self.occurred_end
        if self.recurring:
            m["recurring"] = True
        if self.evidence:
            m["evidence"] = list(self.evidence)
        if self.first_seen:
            m["first_seen"] = self.first_seen
        if self.flag == "contradicts":
            m["flag"] = "contradicts"
        return m

    def apply_meta(self, m):
        if not isinstance(m, dict):
            return
        if m.get("kind") in KINDS:
            self.kind = m["kind"]
        self.occurred_start = iso_or_none(m.get("occurred_start")) or self.occurred_start
        self.occurred_end = iso_or_none(m.get("occurred_end")) or self.occurred_end
        self.recurring = bool(m.get("recurring")) or self.recurring
        if isinstance(m.get("evidence"), list):
            self.add_evidence(m["evidence"])
        self.first_seen = iso_or_none(m.get("first_seen")) or self.first_seen
        if m.get("flag") == "contradicts":
            self.flag = "contradicts"

    def event_end(self):
        """The day an event is over: its occurred_end, else its start, else
        — a line from before kinds existed — the date it was last seen."""
        return self.occurred_end or self.occurred_start or self.date

    def as_dict(self):
        d = {"id": self.id, "file": self.file, "text": self.text, "source": self.source,
             "date": self.date, "confidence": self.confidence, "key": self.key,
             "kind": self.kind, "active": self.active,
             "occurred_start": self.occurred_start, "occurred_end": self.occurred_end,
             "support": self.support}
        if self.flag and self.active:
            d["flag"] = self.flag
        if not self.active:
            d["reason"] = self.reason
            d["archived"] = self.archived
        return d


def default_kind(file):
    return "event" if file in EVENT_FILES else "stable"


# ── topic keys ─────────────────────────────────────────────────────────────
#
# The audit found one person under four keys (person:zorach, person:zorach
# grynhaus, person:zorach-grynhaus, person:zorach_grynhaus) and one person
# twice as a Hebrew and a Latin spelling. Keys are free text from a model,
# so they are normalised here, and people are matched as ENTITIES (the name's
# tokens), not strings: case and separators never matter, a first name alone
# joins the one full name it can mean (never two), and a Hebrew-script name
# joins a Latin one when their consonant skeletons agree.

_SEP_RE = re.compile(r"[\s_./\\-]+")
_TOKEN_RE = re.compile(r"[^\W\d_]+", re.UNICODE)
HONORIFICS = {"mr", "mrs", "ms", "dr", "rabbi", "reb", "rav", "r", "prof", "the"}


def normalize_key(key):
    """"Person: Zorach_Grynhaus " → "person:zorach-grynhaus"."""
    k = " ".join(str(key or "").split()).lower()
    if not k:
        return None
    prefix, sep, rest = k.partition(":")
    if not sep:
        prefix, rest = "", k
    rest = _SEP_RE.sub("-", rest.strip()).strip("-")
    prefix = _SEP_RE.sub("-", prefix.strip()).strip("-")
    out = (prefix + ":" + rest) if prefix else rest
    return out[:80] or None


def name_tokens(name):
    toks = [t for t in _TOKEN_RE.findall(str(name or "").lower()) if t not in HONORIFICS]
    return toks


def is_hebrew(tok):
    return any("֐" <= ch <= "׿" for ch in tok)


_HE = {"א": "", "ב": "v", "ג": "g", "ד": "d", "ה": "", "ו": "", "ז": "z", "ח": "k", "ט": "t",
       "י": "", "כ": "k", "ך": "k", "ל": "l", "מ": "m", "ם": "m", "נ": "n", "ן": "n", "ס": "s",
       "ע": "", "פ": "p", "ף": "f", "צ": "c", "ץ": "c", "ק": "k", "ר": "r", "ש": "s", "ת": "t"}
_LATIN_DIGRAPHS = (("sch", "s"), ("tch", "k"), ("tz", "c"), ("ts", "c"), ("ch", "k"), ("kh", "k"),
                   ("sh", "s"), ("ph", "f"), ("th", "t"), ("ck", "k"), ("x", "ks"))
_LATIN = {"b": "v", "w": "v", "q": "k", "j": "y", "c": "k"}


def skeleton(tok):
    """A consonant skeleton both scripts reduce to: "zorach" and "זורח" are
    both "zrk"; "yosef", "joseph" and "יוסף" are all "ysf". Vowels, matres
    lectionis and silent letters drop; the sounds each script spells two
    ways (b/v, ch/k/kh, tz/ts) fold to one. Deliberately coarse — it is
    only used to join a Hebrew spelling to a Latin one, never two Latin
    names, which compare exactly."""
    tok = tok.lower()
    if is_hebrew(tok):
        out = []
        for i, ch in enumerate(tok):
            if ch == "י" and i == 0:
                out.append("y")
            elif ch == "פ" and i == len(tok) - 1:
                out.append("f")
            else:
                out.append(_HE.get(ch, ""))
        s = "".join(out)
        # פ between vowels is usually f (Yosef is written יוסף, final form)
        return s.replace("p", "f")
    t = tok
    for a, b in _LATIN_DIGRAPHS:
        t = t.replace(a, b)
    out = []
    for i, ch in enumerate(t):
        if ch == "c":           # the tz/ts from the digraphs above
            out.append("c")
        elif ch == "y":
            out.append("y" if i == 0 else "")
        elif ch in "aeiou" or ch == "h":
            continue
        else:
            out.append(_LATIN.get(ch, ch))
    return "".join(out).replace("p", "f")


def tokens_match(a, b):
    if a == b:
        return True
    if is_hebrew(a) == is_hebrew(b):
        return False          # two spellings in one script are two names
    sa, sb = skeleton(a), skeleton(b)
    if len(sa) >= 2 and sa == sb:
        return True
    sa, sb = sa.replace("v", ""), sb.replace("v", "")
    return len(sa) >= 2 and sa == sb


def person_name(claim):
    """The name a people claim is about: its key's, else its bold name."""
    k = claim.key or ""
    if k.startswith("person:"):
        return k[len("person:"):]
    m = NAME_RE.match(claim.text or "")
    return m.group(1) if m else ""


def same_person(ta, tb):
    """Two names (token lists) are one person when their first names match
    and, where both give a second name, those match too."""
    if not ta or not tb or not tokens_match(ta[0], tb[0]):
        return False
    if len(ta) >= 2 and len(tb) >= 2:
        return tokens_match(ta[1], tb[1])
    return True


def canonical_person_key(names):
    """The key a group of spellings of one person is filed under: the
    longest Latin-script spelling, else the longest at all."""
    best = None
    for toks in names:
        if not toks:
            continue
        score = (0 if any(is_hebrew(t) for t in toks) else 1, len(toks), len("".join(toks)))
        if best is None or score > best[0]:
            best = (score, toks)
    return ("person:" + "-".join(best[1])) if best else None


def group_people(claims):
    """Partition people claims into one list per person. A full name joins
    the group whose full name it matches; a lone first name joins a group
    only when exactly one group can be meant — "David" beside "David Cohen"
    and "David Levi" stays on its own rather than guessing."""
    groups = []          # [ [claims], [token lists] ]
    singles = []
    for c in claims:
        toks = name_tokens(person_name(c))
        if not toks:
            groups.append([[c], []])
            continue
        if len(toks) == 1:
            singles.append((c, toks))
            continue
        for g in groups:
            if any(len(t) >= 2 and same_person(t, toks) for t in g[1]):
                g[0].append(c)
                g[1].append(toks)
                break
        else:
            groups.append([[c], [toks]])
    for c, toks in singles:
        hits = [g for g in groups if g[1] and any(same_person(t, toks) for t in g[1])]
        full = [g for g in hits if any(len(t) >= 2 for t in g[1])]
        target = full[0] if len(full) == 1 else (hits[0] if len(hits) == 1 else None)
        if len(full) > 1:
            target = None
        if target is None:
            groups.append([[c], [toks]])
        else:
            target[0].append(c)
            target[1].append(toks)
    return [(g[0], canonical_person_key(g[1])) for g in groups]


def entity_key(claim):
    """The normalised topic key a claim is matched on (people: by name)."""
    if claim.file == "people":
        toks = name_tokens(person_name(claim))
        if toks:
            return "person:" + "-".join(toks)
    return normalize_key(claim.key)


def derived_key(claim):
    """A key when the digest gave none: people are keyed by name; anything
    else only matches itself, which is the safe default."""
    if claim.file == "people":
        m = NAME_RE.match(claim.text)
        if m:
            return "person:" + "-".join(name_tokens(m.group(1))) if name_tokens(m.group(1)) else None
    return None


def rank(c):
    """Importance for caps and the prompt: the person's own word, then how
    sure, then how often seen, then how recent."""
    return (1 if c.source == USER_SOURCE else 0, CONF_RANK.get(c.confidence, 0), c.support, c.date)


def is_past(c, day=None):
    """An event whose end is more than EVENT_GRACE_DAYS gone, and that does
    not recur. A recurring pattern survives only with two independent
    sightings (docs/MEMORY.md §8); with one it is just an event."""
    if c.kind != "event" or c.source == USER_SOURCE:
        return False
    if c.recurring and c.support >= 2:
        return False
    end = c.event_end()
    if not end:
        return False
    cutoff = (date.fromisoformat(day or today()) - timedelta(days=EVENT_GRACE_DAYS)).isoformat()
    return end < cutoff


# ── passing events told as card facts ──────────────────────────────────────
#
# After the 2026-09-22 re-learn the card files still carried events in
# passing: "**Zorach** — friend …; recently returned from seminary as of
# September 2026", "Was testing a Telegram bot named Otto". A card line
# states what stays true; the event half of it is dropped (people) or the
# whole line re-filed as an event (identity). The summary uses the same test
# to refuse a past-tense line.

_MONTH = r"(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*"
EVENTISH_RE = re.compile(
    r"^\s*(?:was|were|had been|used to|recently|just)\b"
    r"|\b(?:recently|just)\s+(?:\w+ed|got|came|went|had|began|wrapped|finished|returned|moved|started)\b"
    r"|\b(?:wrapped up|returned from|came back from|got back from|back from)\b"
    r"|\bwas\s+\w+ing\b"
    r"|\bas of\s+(?:" + _MONTH + r"\s+)?\d{4}\b",
    re.IGNORECASE)
AS_OF_RE = re.compile(r"[,;]?\s*\(?\bas of\s+(?:" + _MONTH + r"\s+)?\d{4}\)?", re.IGNORECASE)


def eventish(text):
    """True for a line (or clause) that tells something that happened —
    past tense, "recently …", "as of <month> <year>" — rather than a fact
    that stays true."""
    return bool(EVENTISH_RE.search(str(text or "").replace("**", "")))


def card_text(file, text):
    """A people line with its passing-event clauses dropped: the clauses
    after the name are split on ';' and each eventish one goes. Returns the
    new text, the same text when nothing changed, or None when nothing
    durable is left (the caller re-files the line as an event)."""
    m = re.match(r"^(\*\*[^*]{1,60}\*\*\s*[—–-]\s*)(.*)$", text)
    if file != "people" or not m:
        return None if eventish(text) else text
    head, rest = m.group(1), m.group(2)
    clauses = [c.strip() for c in re.split(r";\s*", rest) if c.strip()]
    keep = []
    for c in clauses:
        if eventish(c):
            stripped = AS_OF_RE.sub("", c).strip(" ,;.")
            # "friend, as of 2026" → "friend"; "returned from X" → gone
            if stripped and stripped != c.strip(" ,;.") and not eventish(stripped):
                keep.append(stripped)
            continue
        keep.append(c)
    if not keep:
        return None
    out = head + "; ".join(keep)
    return text if normalise(out.rstrip(".")) == normalise(text.rstrip(".")) else out


# ── the "check these" list ─────────────────────────────────────────────────
#
# ONE list, shared by check.md (consolidate.py), `profile.py check --json`
# and the `flag` field of `list --json`, so the page, the file and the flags
# can never disagree. At most MAX_CHECK items, in priority order:
#   contradicts   an open question quoting two lines (or a flagged line)
#   question      any other open question, then what the summary model flagged
#   unsure        a crawled identity/people/preferences line at low confidence
#   new           a crawled line first seen in the latest run that added
#                 lines to a profile that ALREADY had some — a first seed
#                 (an empty profile, or right after retire-all) flags nothing
# The person's own lines (source `user`) are never on it.

MAX_CHECK = 5
MAX_OPEN_QUESTIONS = 5
QUOTED = re.compile(r'"([^"]{3,400})"')


def read_questions(root):
    try:
        with open(os.path.join(root, "questions.md"), encoding="utf-8") as f:
            return [ln[2:].strip() for ln in f if ln.startswith("- ") and ln[2:].strip()]
    except OSError:
        return []


# Questions are shown to the person and read out to them, so they say "you".
# The prompts ask for that (prompts/learn-*.md); this is the deterministic
# half, for questions written before they did and for a model that forgets.
# Conservative on purpose: "the user" is unambiguous and always rewritten;
# "they/them/their" only when "themselves/themself" in the same question
# ties them to the user ("the user introduced themselves as X — is that a
# name they go by?"). "Is the user's brother running it, or are they
# co-running it?" keeps its "they" — that one means two people. Text inside
# double quotes is a quoted profile line (QUOTED finds lines by it) and is
# never touched.
_YOU = [
    (r"\bthe user(?:'|\u2019)s\b", "your"),
    (r"\bdoes the user\b", "do you"), (r"\bis the user\b", "are you"),
    (r"\bwas the user\b", "were you"), (r"\bhas the user\b", "have you"),
    (r"\bthe user is\b", "you are"), (r"\bthe user was\b", "you were"),
    (r"\bthe user has\b", "you have"), (r"\bthe user does\b", "you do"),
    (r"\bthe user\b", "you"),
]
_THEY = [
    (r"\bthemselves\b", "yourself"), (r"\bthemself\b", "yourself"),
    (r"\bthey are\b", "you are"), (r"\bthey were\b", "you were"), (r"\bthey have\b", "you have"),
    (r"\bthey\b", "you"), (r"\btheir\b", "your"), (r"\bthem\b", "you"),
]


def second_person(q):
    """A question as said to the person: "Is Rebecca the user's sister?" →
    "Is Rebecca your sister?". Idempotent; never changes quoted text."""
    if not isinstance(q, str) or not q:
        return q
    parts = re.split(r'("[^"]*")', q)
    lowered = q.lower()
    reflexive = "the user" in lowered and re.search(r"\bthemsel(?:f|ves)\b", lowered)
    rules = _YOU + (_THEY if reflexive else [])
    out = []
    for i, part in enumerate(parts):
        if i % 2 == 1:
            out.append(part)
            continue
        for pat, rep in rules:
            def sub(m, rep=rep):
                w = m.group(0)
                return rep[0].upper() + rep[1:] if w[:1].isupper() else rep
            part = re.sub(pat, sub, part, flags=re.IGNORECASE)
        out.append(part)
    text = "".join(out)
    return text[:1].upper() + text[1:] if text else text


def same_question(a, b):
    return normalise(second_person(a)) == normalise(second_person(b))


def new_ids(active, meta):
    """Ids of crawled active lines that are "new": first seen on or after
    .meta.json `latest_run`. Nothing is new when every crawled line is that
    recent — that run was a seed, not an addition to a known profile."""
    latest = meta.get("latest_run")
    if not latest:
        return set()
    crawled = [c for c in active if c.source != USER_SOURCE]
    if not any((c.first_seen or "") < latest for c in crawled):
        return set()
    return {c.id for c in crawled if c.first_seen and c.first_seen >= latest}


class Store(object):
    def __init__(self, root=None):
        self.root = root or profile_dir()

    # -- sidecars ---------------------------------------------------------

    def _load_json(self, name, default):
        try:
            with open(os.path.join(self.root, name), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return default

    def _save_json(self, name, obj):
        os.makedirs(self.root, exist_ok=True)
        path = os.path.join(self.root, name)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=1, sort_keys=True, ensure_ascii=False)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)

    def keys(self):
        return self._load_json(".keys.json", {})

    def save_keys(self, keys):
        self._save_json(".keys.json", keys)

    def meta(self):
        m = self._load_json(".meta.json", {})
        if not isinstance(m, dict):
            m = {}
        m.setdefault("files", {})
        m.setdefault("archive", {})
        return m

    def save_meta(self, m):
        self._save_json(".meta.json", m)

    def check_items(self, files=None):
        """The "check these" list (see MAX_CHECK above): a list of
        {"kind", "text", "ids"} — kind contradicts | question | unsure | new,
        ids the active crawled claims the item is about (empty for a
        free-text question)."""
        files = files if files is not None else self.read_all()
        active = [c for f in FILES for c in files.get(f, [])]
        crawled = [c for c in active if c.source != USER_SOURCE]
        by_text = {}
        for c in crawled:
            by_text.setdefault(c.text, []).append(c)
        meta = self.meta()
        contra, other = [], []
        for q in read_questions(self.root):
            about = [c for t in QUOTED.findall(q) for c in by_text.get(t, [])]
            if len(about) >= 2 or any(c.flag == "contradicts" for c in about):
                contra.append({"kind": "contradicts", "text": second_person(q), "ids": [c.id for c in about]})
            else:
                other.append({"kind": "question", "text": second_person(q), "ids": [c.id for c in about]})
        extra = [{"kind": "question", "text": second_person(x), "ids": []}
                 for x in meta.get("check_extra") or [] if isinstance(x, str) and x.strip()]
        unsure = [{"kind": "unsure", "text": c.text, "ids": [c.id]} for c in render_ranked(
            [c for c in crawled if c.file in ("identity", "people", "preferences") and c.confidence == "low"])]
        fresh = new_ids(active, meta)
        new = [{"kind": "new", "text": c.text, "ids": [c.id]}
               for c in render_ranked([c for c in crawled if c.id in fresh])]
        out, seen_text, seen_ids = [], set(), set()
        for it in contra + other + extra + unsure + new:
            if len(out) >= MAX_CHECK:
                break
            if it["text"] in seen_text:
                continue
            if it["kind"] in ("unsure", "new") and set(it["ids"]) <= seen_ids:
                continue
            seen_text.add(it["text"])
            seen_ids.update(it["ids"])
            out.append(it)
        return out

    def mark_new(self, claims):
        """Set each claim's listing `flag` from check_items(): an active
        crawled line gets the kind of the first item about it
        (contradicts | question | unsure | new); every other line none.
        So `list --json` flags exactly the lines check.md lists."""
        flags = {}
        for it in self.check_items():
            for cid in it["ids"]:
                flags.setdefault(cid, it["kind"])
        for c in claims:
            c.flag = flags.get(c.id) if c.active and c.source != USER_SOURCE else None
        return claims

    def write_check(self, files=None):
        """check.md from check_items(); removed when the list is empty."""
        items = self.check_items(files)
        path = os.path.join(self.root, "check.md")
        if not items:
            if os.path.exists(path):
                os.remove(path)
            return items
        label = {"contradicts": "Contradiction", "question": "Question", "unsure": "Not sure", "new": "New"}
        lines = ["# Check these", "",
                 "New, unsure or contradicting things Alfie learned. Fix or forget any of them on the Memory page.", ""]
        lines += ["- %s — %s" % (label[it["kind"]], it["text"]) for it in items]
        os.makedirs(self.root, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        return items

    def _tombstone_sidecar(self):
        t = self._load_json(".tombstones.json", {})
        if isinstance(t, list):            # the first format: ids only
            t = {"ids": t, "keys": []}
        return {"ids": set(t.get("ids") or []), "keys": set(t.get("keys") or [])}

    def tombstones(self):
        """Claim ids the user deleted or corrected."""
        return self._tombstone_sidecar()["ids"]

    def tombstoned_keys(self):
        """(file, key) pairs the user deleted or corrected. The trade-off:
        an id tombstone only stops the identical sentence, so a crawl could
        bring a deleted claim back reworded. A key tombstone stops every
        crawled claim on that topic — delete "**Dani** — sister" and no
        source will add a Dani line again, however true. Only crawls are
        blocked: merge.py refuses digests from source `user` anyway, and a
        correction or a hand-written line is the user's word, never
        tombstoned. A claim with no key (most non-people claims the model
        did not key) is protected by id alone. Keys are compared
        normalised, so "person:Dani" and "person:dani" are one topic."""
        out = set()
        for k in self._tombstone_sidecar()["keys"]:
            if "\t" in k:
                f, key = k.split("\t", 1)
                out.add((f, normalize_key(key) or key))
        return out

    def add_tombstone(self, cid, file=None, key=None):
        t = self._tombstone_sidecar()
        t["ids"].add(cid)
        if file and key:
            t["keys"].add("%s\t%s" % (file, key))
        self._save_json(".tombstones.json", {"ids": sorted(t["ids"]), "keys": sorted(t["keys"])})

    # -- files ------------------------------------------------------------

    def path(self, file):
        return os.path.join(self.root, file + ".md")

    def read(self, file):
        """Claims in one file, in file order. Non-claim lines are ignored,
        and write() regenerates the heading — so edit the claims, not the
        prose around them; a line without a provenance tag will not last."""
        if file not in FILES:
            raise ValueError("unknown profile file: %s" % file)
        keys = self.keys().get(file, {})
        meta = self.meta()["files"].get(file, {})
        out = []
        try:
            with open(self.path(file), encoding="utf-8") as f:
                for line in f:
                    m = CLAIM_RE.match(line)
                    if not m:
                        continue
                    c = Claim(file, m.group("text"), m.group("source"), m.group("date"), m.group("conf"))
                    c.key = keys.get(c.id) or derived_key(c)
                    c.apply_meta(meta.get(c.id))
                    out.append(c)
        except OSError:
            pass
        return out

    def read_all(self):
        return {f: self.read(f) for f in FILES}

    def write(self, file, claims):
        """Rewrite one file: heading, then one line per claim. People are
        sorted by name so the file reads like a directory; the rest keep the
        order they were learned in. Writing is atomic — this file is read
        by a Hermes plugin on every new session."""
        os.makedirs(self.root, exist_ok=True)
        # One line per id: the same sentence twice is one claim.
        seen, uniq = set(), []
        for c in claims:
            if c.id not in seen:
                seen.add(c.id)
                uniq.append(c)
        claims = uniq
        if file == "people":
            claims = sorted(claims, key=lambda c: (normalise(c.text), c.source))
        lines = ["# %s" % HEADINGS[file], ""]
        lines += [c.line() for c in claims]
        path = self.path(file)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        # Keys and meta ride along with the claims: this file's slice of
        # each sidecar is replaced wholesale, so neither outlives its line.
        keys = self.keys()
        keys[file] = {c.id: c.key for c in claims if c.key}
        self.save_keys(keys)
        meta = self.meta()
        meta["files"][file] = {c.id: c.meta() for c in claims}
        self.save_meta(meta)

    # -- the archive --------------------------------------------------------

    def archive_path(self):
        return os.path.join(self.root, "archive.md")

    def read_archive(self):
        """Archived claims, each with the file it came from (its id is the
        id it had there, so a link or a tombstone still finds it)."""
        meta = self.meta()["archive"]
        out, current = [], None
        by_heading = {v: k for k, v in HEADINGS.items()}
        try:
            with open(self.archive_path(), encoding="utf-8") as f:
                for line in f:
                    if line.startswith("## "):
                        current = by_heading.get(line[3:].strip())
                        continue
                    m = CLAIM_RE.match(line)
                    if not m or current is None:
                        continue
                    c = Claim(current, m.group("text"), m.group("source"), m.group("date"), m.group("conf"))
                    mm = meta.get(c.id) or {}
                    c.apply_meta(mm)
                    c.key = mm.get("key") or derived_key(c)
                    c.reason = mm.get("reason") if mm.get("reason") in ARCHIVE_REASONS else "past"
                    c.archived = iso_or_none(mm.get("archived")) or c.date
                    c.by = mm.get("by")
                    out.append(c)
        except OSError:
            pass
        return out

    def write_archive(self, claims):
        seen, uniq = set(), []
        # Newest-archived first, so the cap drops the longest-retired.
        for c in sorted(claims, key=lambda c: (c.archived or "", c.date), reverse=True):
            if c.id in seen:
                continue
            seen.add(c.id)
            uniq.append(c)
        uniq = uniq[:MAX_ARCHIVE]
        lines = ["# Archive", "",
                 "Lines Alfie no longer uses: events that are over, older wordings, duplicates, and",
                 "anything past a file's limit. Kept so nothing learned is lost; search finds them,",
                 "and `profile.py restore <id>` puts one back.", ""]
        for f in FILES:
            group = [c for c in uniq if c.file == f]
            if not group:
                continue
            lines.append("## %s" % HEADINGS[f])
            lines += [c.line() for c in group]
            lines.append("")
        os.makedirs(self.root, exist_ok=True)
        path = self.archive_path()
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("\n".join(lines).rstrip() + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        meta = self.meta()
        arch = {}
        for c in uniq:
            m = c.meta()
            m.update({"file": c.file, "reason": c.reason or "past", "archived": c.archived or today()})
            if c.key:
                m["key"] = c.key
            if c.by:
                m["by"] = c.by
            arch[c.id] = m
        meta["archive"] = arch
        self.save_meta(meta)

    def archive(self, claims, reason, by=None):
        """Move `claims` (already gone from their files, or about to be) into
        the archive. Returns how many were added."""
        if not claims:
            return 0
        current = self.read_archive()
        for c in claims:
            c.reason, c.archived = reason, today()
            if by:
                c.by = by
        ids = {c.id for c in claims}
        self.write_archive([c for c in current if c.id not in ids] + list(claims))
        return len(claims)

    def unarchive(self, ids):
        """Drop these ids from the archive (a crawl asserted them again, or
        they were restored)."""
        ids = set(ids)
        current = self.read_archive()
        keep = [c for c in current if c.id not in ids]
        if len(keep) != len(current):
            self.write_archive(keep)
        return len(current) - len(keep)

    def find(self, cid):
        for f in FILES:
            for c in self.read(f):
                if c.id == cid:
                    return c
        for c in self.read_archive():
            if c.id == cid:
                return c
        return None

    # -- operations shared by the CLI and the Hermes tool -------------------

    def delete(self, cid):
        c = self.find(cid)
        if c is None:
            return None
        if c.active:
            self.write(c.file, [x for x in self.read(c.file) if x.id != cid])
        else:
            self.unarchive([cid])
        self.add_tombstone(cid, c.file, c.key)
        self.drop_questions([c.text])
        return c

    def drop_questions(self, texts):
        """Remove every open or held question quoting one of `texts` — the
        person has settled that line. Returns the texts those questions
        quoted besides `texts` (the other side of a contradiction)."""
        texts = set(texts)
        others = []
        meta = self.meta()
        held = [q for q in meta.get("questions_held") or [] if isinstance(q, str)]
        open_q = read_questions(self.root)

        def keep(q):
            quoted = QUOTED.findall(q)
            if any(t in texts for t in quoted):
                others.extend(t for t in quoted if t not in texts)
                return False
            return True
        new_open, new_held = [q for q in open_q if keep(q)], [q for q in held if keep(q)]
        if len(new_open) != len(open_q) or len(new_held) != len(held):
            # promote held questions into the freed places (at most five open)
            room = max(0, MAX_OPEN_QUESTIONS - len(new_open))
            new_open, new_held = new_open + new_held[:room], new_held[room:]
            path = os.path.join(self.root, "questions.md")
            if new_open:
                tmp = path + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    f.write("# Questions for you\n\n" + "".join("- %s\n" % second_person(q) for q in new_open))
                os.chmod(tmp, 0o600)
                os.replace(tmp, path)
            elif os.path.exists(path):
                os.remove(path)
            meta = self.meta()
            meta["questions_held"] = new_held
            self.save_meta(meta)
        return others

    def close_question(self, question):
        """Remove one question — open, held, or the nightly check's own —
        matched as the person saw it (second_person). Held questions move
        up into a freed place. True when one was found."""
        found = False
        meta = self.meta()
        open_q = read_questions(self.root)
        held = [q for q in meta.get("questions_held") or [] if isinstance(q, str)]
        extra = [q for q in meta.get("check_extra") or [] if isinstance(q, str)]
        keep_open = [q for q in open_q if not same_question(q, question)]
        keep_held = [q for q in held if not same_question(q, question)]
        keep_extra = [q for q in extra if not same_question(q, question)]
        found = (len(keep_open), len(keep_held), len(keep_extra)) != (len(open_q), len(held), len(extra))
        if not found:
            return False
        room = max(0, MAX_OPEN_QUESTIONS - len(keep_open))
        keep_open, keep_held = keep_open + keep_held[:room], keep_held[room:]
        path = os.path.join(self.root, "questions.md")
        if keep_open:
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write("# Questions for you\n\n" + "".join("- %s\n" % second_person(q) for q in keep_open))
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)
        elif os.path.exists(path):
            os.remove(path)
        meta = self.meta()
        meta["questions_held"] = keep_held
        meta["check_extra"] = keep_extra
        self.save_meta(meta)
        return True

    def answer(self, question, text, file="identity"):
        """The person answers a question on the Memory page: the answer is
        kept as their own line (source `user`, so every pass leaves it
        alone) and the question closes. Returns the new claim, or None when
        no such question is open. Raises ValueError for an empty answer."""
        text = re.sub(r"\s*\[[^\]]*\]\s*$", "", " ".join((text or "").split()))
        if not text:
            raise ValueError("empty answer")
        if file not in FILES:
            raise ValueError("unknown profile file: %s" % file)
        if not self.close_question(question):
            return None
        c = Claim(file, text, USER_SOURCE, today(), "high", first_seen=today())
        self.write(file, [x for x in self.read(file) if x.id != c.id] + [c])
        return c

    def add(self, file, text):
        """The person writes a line of their own on the Memory page ("+ Add
        something Alfie should know"). It is kept exactly like a correction:
        source `user`, confidence high, dated today — which every pass
        already leaves alone (merge.py adds nothing competing on its topic,
        consolidate.py never caps, supersedes, archives or dedupes it, and
        `expire` skips it). Its kind is the file's: an event in threads, a
        standing fact elsewhere. The same sentence already archived comes
        back rather than sitting twice. Returns the new claim; raises
        ValueError for an empty line or an unknown file."""
        text = re.sub(r"\s*\[[^\]]*\]\s*$", "", " ".join((text or "").split()))
        if not text:
            raise ValueError("empty line")
        if file not in FILES:
            raise ValueError("unknown profile file: %s" % file)
        c = Claim(file, text, USER_SOURCE, today(), "high", first_seen=today())
        c.key = derived_key(c)
        if any(x.id == c.id for x in self.read_archive()):
            self.unarchive([c.id])
        self.write(file, [x for x in self.read(file) if x.id != c.id] + [c])
        return c

    def confirm(self, cid):
        """The person says a line is right ("Right" on the Memory page). The
        line becomes theirs — same text, so the SAME id; source `user`,
        confidence high, dated today; kind, event dates and evidence kept —
        which is what every pass already leaves alone: never merged away,
        superseded, capped, retired as past, removed as sensitive, flagged
        or re-asked, and merge.py lets no crawl add a competing line on its
        topic. Any open question quoting it is closed, and a crawled line on
        the other side of that question is archived `superseded` (by this
        id) and tombstoned by id, so the same sentence is not learned back.
        An archived line is restored first. Returns the confirmed claim, or
        None for an unknown id."""
        c = self.find(cid)
        if c is None:
            return None
        if not c.active:
            c = self.restore(cid)
        others = set(self.drop_questions([c.text])) - {c.text}
        mine = Claim(c.file, c.text, USER_SOURCE, today(), "high", c.key, kind=c.kind,
                     occurred_start=c.occurred_start, occurred_end=c.occurred_end,
                     recurring=c.recurring, evidence=c.evidence, first_seen=c.first_seen or today())
        losers = []
        for f in FILES:
            claims = self.read(f)
            out, changed = [], False
            for x in claims:
                if x.id == cid:
                    out.append(mine)
                    changed = True
                elif x.text in others and x.source != USER_SOURCE:
                    losers.append(x)
                    changed = True
                else:
                    out.append(x)
            if changed:
                self.write(f, out)
        if losers:
            self.archive(losers, "superseded", by=cid)
            for x in losers:
                self.add_tombstone(x.id)
        return mine

    def correct(self, cid, text):
        """The user's word beats every source: the old claim is tombstoned
        so no crawl brings it back, the new one is theirs, dated today."""
        c = self.find(cid)
        if c is None:
            return None
        text = " ".join(text.split())
        text = re.sub(r"\s*\[[^\]]*\]\s*$", "", text)   # a pasted tag would double up
        if not text:
            raise ValueError("empty correction")
        new = Claim(c.file, text, USER_SOURCE, today(), "high", c.key, kind=c.kind,
                    occurred_start=c.occurred_start, occurred_end=c.occurred_end,
                    first_seen=today())
        if c.active:
            claims = [new if x.id == cid else x for x in self.read(c.file)]
        else:
            self.unarchive([cid])
            claims = self.read(c.file) + [new]
        self.write(c.file, claims)
        self.add_tombstone(cid, c.file, c.key)
        self.drop_questions([c.text])
        return new

    def restore(self, cid):
        """An archived claim back into its file. The person asked for it, so
        a past event restored stays until they delete it: it is kept as a
        stable line (the nightly pass would otherwise archive it again)."""
        for c in self.read_archive():
            if c.id == cid:
                self.unarchive([cid])
                c.reason = c.archived = c.by = None
                if is_past(c):
                    c.kind = "stable"
                self.write(c.file, self.read(c.file) + [c])
                return c
        return None

    def search(self, words):
        """Active and archived claims whose text or key holds every word."""
        terms = [w for w in normalise(words).split() if w]
        out = []
        for c in [x for f in FILES for x in self.read(f)] + self.read_archive():
            hay = normalise(c.text + " " + (c.key or ""))
            if terms and all(t in hay for t in terms):
                out.append(c)
        return out

    def expire(self, days):
        """Drop claims whose latest evidence is older than N days. The
        user's own corrections never expire — they were not inferred."""
        cutoff = (date.fromisoformat(today()) - timedelta(days=days)).isoformat()
        dropped = []
        for f in FILES:
            claims = self.read(f)
            keep = [c for c in claims if c.source == USER_SOURCE or c.date >= cutoff]
            if len(keep) != len(claims):
                dropped += [c for c in claims if c not in keep]
                self.write(f, keep)
        return dropped

    def summary(self):
        try:
            with open(os.path.join(self.root, "summary.md"), encoding="utf-8") as f:
                return f.read()
        except OSError:
            return ""

    def retire_all(self, stamp=None):
        """The reset before a re-learn (see the module docstring). Returns a
        dict of counts. Recoverable twice over: the backup directory holds
        the files exactly as they were, and every retired line is in the
        archive with reason `retired`."""
        day = stamp or today()
        backups = os.path.join(self.root, "backups")
        n, dest = 0, None
        while True:
            dest = os.path.join(backups, "retired-%s%s" % (day, "" if n == 0 else "-%d" % n))
            if not os.path.exists(dest):
                break
            n += 1
        os.makedirs(dest)
        os.chmod(backups, 0o700)
        os.chmod(dest, 0o700)
        import shutil
        for name in sorted(os.listdir(self.root)):
            src = os.path.join(self.root, name)
            if os.path.isfile(src) and (name.endswith(".md") or name.endswith(".json")):
                shutil.copy2(src, os.path.join(dest, name))
        retired, kept = [], 0
        for f in FILES:
            claims = self.read(f)
            mine = [c for c in claims if c.source == USER_SOURCE]
            gone = [c for c in claims if c.source != USER_SOURCE]
            kept += len(mine)
            if gone or os.path.exists(self.path(f)):
                self.write(f, mine)
            retired += gone
        self.archive(retired, "retired")
        # The next pass is a first seed: nothing it learns is "new" (there
        # is no earlier profile to be new against), and no old question or
        # model check item outlives the lines it was about.
        meta = self.meta()
        meta["had_profile"] = False
        for k in ("latest_run", "check_extra", "questions_held"):
            meta.pop(k, None)
        self.save_meta(meta)
        removed = []
        for name in ("summary.md", "check.md", "questions.md"):
            p = os.path.join(self.root, name)
            if os.path.exists(p):
                os.remove(p)
                removed.append(name)
        cleared = 0
        for sub in ("digests", "stamps"):
            d = os.path.join(self.root, sub)
            if os.path.isdir(d):
                for name in os.listdir(d):
                    if name.endswith(".json"):
                        os.remove(os.path.join(d, name))
                        cleared += 1
        return {"retired": len(retired), "kept_user_lines": kept, "removed": removed,
                "cleared_digests_and_stamps": cleared, "backup": dest}


# ── the prompt block ───────────────────────────────────────────────────────
#
# What reaches the model, in this order: summary.md (the current picture),
# then each file's ACTIVE lines newest/strongest first, each file held to
# its share of what is left so one long file cannot starve the rest, and
# any share a file does not use handed on. Until 2026-09-22 this spent the
# whole budget on identity in file order — the OLDEST 22 identity lines —
# and threads, people and voice never reached the prompt at all.
# (hermes-plugins/moe-profile duplicates this on purpose; keep them equal.)
RENDER_ORDER = ("identity", "threads", "people", "preferences", "voice")
RENDER_SHARES = {"identity": 0.30, "threads": 0.25, "people": 0.25, "preferences": 0.12, "voice": 0.08}
SUMMARY_MAX_CHARS = 1800


def render_ranked(claims):
    return sorted(claims, key=lambda c: (1 if c.source == USER_SOURCE else 0, c.date,
                                         CONF_RANK.get(c.confidence, 0), c.support), reverse=True)


def render_blocks(summary, by_file, max_chars, head_len=0):
    """Shared by render() here and the plugin: (summary block, {file: lines})."""
    parts = []
    spent = head_len
    s = (summary or "").strip()
    if s:
        lines = s.splitlines()
        if lines and lines[0].startswith("# "):
            lines[0] = "## " + lines[0][2:]
        block = ""
        for ln in lines:
            if len(block) + len(ln) + 1 > min(SUMMARY_MAX_CHARS, max_chars - spent - 2):
                break
            block += ln + "\n"
        if block.strip():
            parts.append(block + "\n")
            spent += len(block) + 1
    budget = max(0, max_chars - spent)
    chosen = {f: [] for f in RENDER_ORDER}
    used = {f: 0 for f in RENDER_ORDER}
    rest = {f: list(by_file.get(f) or []) for f in RENDER_ORDER}
    total = 0

    def cost(f, line):
        return len(line) + 1 + (len("## %s\n" % HEADINGS[f]) + 1 if not chosen[f] else 0)

    for f in RENDER_ORDER:                      # pass 1: each file's share
        allowance = int(budget * RENDER_SHARES[f])
        while rest[f]:
            c = cost(f, rest[f][0])
            if used[f] + c > allowance or total + c > budget:
                break
            chosen[f].append(rest[f].pop(0))
            used[f] += c
            total += c
    moved = True                                # pass 2: what is left over,
    while moved:                                # a line per file per round
        moved = False
        for f in RENDER_ORDER:
            if rest[f]:
                c = cost(f, rest[f][0])
                if total + c <= budget:
                    chosen[f].append(rest[f].pop(0))
                    total += c
                    moved = True
    for f in RENDER_ORDER:
        if chosen[f]:
            parts.append("## %s\n%s\n\n" % (HEADINGS[f], "\n".join(chosen[f])))
    return "".join(parts)


def render(store, max_chars=4000):
    """Compact text for a system prompt: the current picture, then each
    file's active lines newest/strongest first within its share."""
    by_file = {}
    for f in RENDER_ORDER:
        by_file[f] = ["- %s (%s %s)" % (c.text, c.source, c.date[:7]) for c in render_ranked(store.read(f))]
    return render_blocks(store.summary(), by_file, max_chars).rstrip()[:max_chars]


# The other "profile" — how each SOURCE is read, how often, and whether Moe
# may speak up about it (sync, speak, seed, update, watch), with its stamps
# — lives in learn/source_profile.py. The
# spec that learn.sh, sync.sh and Settings build to names this file for
# those verbs, and the memory screen already runs this file for the claims,
# so the verbs are forwarded here rather than making the callers know two
# scripts. `list` stays the claims list (Settings › Memory reads it); the
# per-source list is `sources`.
SOURCE_VERBS = {"get": "get", "set": "set", "due": "due", "stamp": "stamp", "sources": "list"}


def _source_profile():
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("moe_source_profile", os.path.join(here, "source_profile.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] in SOURCE_VERBS:
        return _source_profile().main([SOURCE_VERBS[argv[0]]] + argv[1:])
    ap = argparse.ArgumentParser(
        description="What Alfie knows about you",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="the per-source learning profile (forwarded to source_profile.py):\n"
               "  get <source>                        the resolved profile, as JSON\n"
               "  set <source> <key> <value>          sync|speak|seed|update|watch|seed_days\n"
               "  due <source> [--today YYYY-MM-DD]   seed | update <days> | no\n"
               "  stamp <source> seed|update [--today YYYY-MM-DD]\n"
               "                                      record a run; --today is the day the crawl started\n"
               "  sources                             one JSON profile per line, every known source")
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("list")
    p.add_argument("--file", choices=FILES)
    p.add_argument("--json", action="store_true")
    p.add_argument("--all", action="store_true", help=argparse.SUPPRESS)   # the default since 2026-09-22
    p.add_argument("--active", action="store_true", help="only claims in use (leave out the archive)")
    p = sub.add_parser("show")
    p.add_argument("file", choices=FILES)
    for verb in ("delete", "confirm", "restore"):
        p = sub.add_parser(verb)
        p.add_argument("id")
        p.add_argument("--json", action="store_true")
    p = sub.add_parser("correct")
    p.add_argument("id")
    p.add_argument("text")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("check")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("add", help="a line of the person's own (source user)")
    p.add_argument("file", choices=FILES)
    p.add_argument("text")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("answer")
    p.add_argument("question")
    p.add_argument("text")
    p.add_argument("--file", choices=FILES, default="identity")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("dismiss")
    p.add_argument("question")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("search")
    p.add_argument("words", nargs="+")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("expire")
    p.add_argument("--days", type=int, required=True)
    sub.add_parser("render")
    sub.add_parser("summary")
    p = sub.add_parser("retire-all")
    p.add_argument("--learned", action="store_true", required=True,
                   help="every crawled line (never your own) — the reset before a re-learn")
    args = ap.parse_args(argv)
    store = Store()

    if args.cmd == "list":
        files = [args.file] if args.file else FILES
        rows = [c for f in files for c in store.read(f)]
        if not args.active:
            rows += [c for c in store.read_archive() if c.file in files]
        store.mark_new(rows)
        if args.json:
            print(json.dumps([c.as_dict() for c in rows], ensure_ascii=False))
        else:
            for c in rows:
                print("%s  %-11s %s %-4s %-10s %s%s" % (c.id, c.file, c.date, c.confidence, c.source,
                                                   "" if c.active else "(archived: %s) " % c.reason, c.text))
        return 0
    if args.cmd == "show":
        try:
            with open(store.path(args.file), encoding="utf-8") as f:
                sys.stdout.write(f.read())
        except OSError:
            print("# %s\n\n(nothing yet)" % HEADINGS[args.file])
        return 0
    def done(verb, c, human):
        store.write_check()      # the check list never lists a settled line
        if getattr(args, "json", False):
            print(json.dumps({"ok": True, "action": verb, "id": args.id, "claim": c.as_dict()},
                             ensure_ascii=False))
        else:
            print(human)
        return 0

    def missing(what):
        if getattr(args, "json", False):
            print(json.dumps({"ok": False, "action": args.cmd, "id": args.id, "error": what}))
        print(what, file=sys.stderr)
        return 1

    if args.cmd == "delete":
        c = store.delete(args.id)
        if c is None:
            return missing("no claim with id %s" % args.id)
        return done("delete", c, "deleted %s: %s" % (c.id, c.text))
    if args.cmd == "confirm":
        c = store.confirm(args.id)
        if c is None:
            return missing("no claim with id %s" % args.id)
        return done("confirm", c, "confirmed %s: %s" % (c.id, c.line()))
    if args.cmd == "correct":
        try:
            c = store.correct(args.id, args.text)
        except ValueError as e:
            print(str(e), file=sys.stderr)
            return 2
        if c is None:
            return missing("no claim with id %s" % args.id)
        return done("correct", c, "corrected → %s: %s" % (c.id, c.line()))
    if args.cmd == "add":
        try:
            c = store.add(args.file, args.text)
        except ValueError as e:
            if args.json:
                print(json.dumps({"ok": False, "action": "add", "error": str(e)}))
            print(str(e), file=sys.stderr)
            return 2
        store.write_check()
        if args.json:
            print(json.dumps({"ok": True, "action": "add", "id": c.id, "claim": c.as_dict()},
                             ensure_ascii=False))
        else:
            print("added %s: %s" % (c.id, c.line()))
        return 0
    if args.cmd in ("answer", "dismiss"):
        def said(obj, code, human, err=False):
            if args.json:
                print(json.dumps(obj, ensure_ascii=False))
            else:
                print(human, file=sys.stderr if err else sys.stdout)
            return code
        try:
            if args.cmd == "answer":
                c = store.answer(args.question, args.text, args.file)
            else:
                c = True if store.close_question(args.question) else None
        except ValueError as e:
            return said({"ok": False, "action": args.cmd, "question": args.question, "error": str(e)},
                        2, str(e), err=True)
        if c is None:
            what = "no open question: %s" % args.question
            return said({"ok": False, "action": args.cmd, "question": args.question, "error": what},
                        1, what, err=True)
        store.write_check()
        obj = {"ok": True, "action": args.cmd, "question": args.question}
        if args.cmd == "answer":
            obj["claim"] = c.as_dict()
        return said(obj, 0, "answered: %s" % c.line() if args.cmd == "answer" else "dismissed")
    if args.cmd == "check":
        items = store.check_items()
        if args.json:
            print(json.dumps(items, ensure_ascii=False))
        else:
            for it in items:
                print("%-11s %s" % (it["kind"], it["text"]))
        return 0
    if args.cmd == "expire":
        dropped = store.expire(args.days)
        for c in dropped:
            print("expired %s: %s" % (c.id, c.line()))
        print("%d claim(s) expired" % len(dropped))
        return 0
    if args.cmd == "render":
        print(render(store))
        return 0
    if args.cmd == "summary":
        sys.stdout.write(store.summary())
        return 0
    if args.cmd == "restore":
        c = store.restore(args.id)
        if c is None:
            return missing("no archived claim with id %s" % args.id)
        return done("restore", c, "restored %s: %s" % (c.id, c.line()))
    if args.cmd == "search":
        rows = store.search(" ".join(args.words))
        if args.json:
            print(json.dumps([c.as_dict() for c in rows], ensure_ascii=False))
        else:
            for c in rows:
                print("%s  %-11s %s %-8s %s" % (c.id, c.file, c.date, "" if c.active else "archived", c.text))
        return 0
    if args.cmd == "retire-all":
        print(json.dumps(store.retire_all(), ensure_ascii=False))
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
