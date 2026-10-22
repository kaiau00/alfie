#!/usr/bin/env python3
"""Guess a learning profile for an MCP connection nobody has researched.

The defaults table (learn/profiles.json) covers the services we know. A
person can add any MCP server to Hermes — an email bridge, a one-shot
tool, a docs search — and Alfie still has to decide, before anyone has
looked, whether it holds anything personal, whether that changes hourly
or monthly, and whether a read can be scoped by date. The only thing on
disk that says what an unknown server is is Hermes's schema cache:
~/.hermes/cache/mcp_schema_cache.json, {"<server>": {"tools": [{"name",
"description", "inputSchema"}, …]}}. This reads the tool names and
descriptions and sorts the server into one of four classes by keyword:

    live    mail, inbox, message, chat, calendar, task …  → sync, seed, daily, dated
    docs    page, doc, note, file, wiki, crm, contact …   → seed, weekly, dated if a
                                                            tool takes since/after/updated
    infra   schema, table, database, deploy, dns, log …  → seed, monthly, undated
    none    search, docs, reference, weather, gif …       → nothing personal; never learn

Scoring: each tool counts ONCE per class — 3 when a keyword is in the
tool's name, 1 when it is only in the description — so a chatty
description ("messages, messages, messages") cannot outvote what the
tool is called, and one tool cannot outvote the rest of the server. The
none-class VERBS (search, compute, generate, render) say how a tool
reads, not what: `search_messages` is a read of messages, and a tool that
names something personal beside such a verb does not count for none. A
server whose tools are all search_/get_/list_ over personal nouns is
therefore its nouns' class, never "nothing personal".

Ties go to the class that reads LESS: a server that looks half like a
mailbox and half like a docs index is treated as the docs index, and one
that looks half like a reference is not learned from until a person says
otherwise. The result carries `why`, naming the words that decided it, so
the sentence in Settings is honest about being a guess.

    infer(tools) -> dict           pure; tools is the cache's list
    profile_infer.py <server>      the guess for one cached server, as JSON
    profile_infer.py --all         every server in the cache

Python 3.9, stdlib only. Import-safe: nothing runs at import.
"""

import json
import os
import re
import sys

# The four classes, most conservative first — that order is the tie-break.
# Each keyword is matched as a whole token (split on anything that is not a
# letter or digit, lower-cased), with a plural "s" tolerated: "messages"
# counts for "message", but "docs" is its own word (documentation, class
# none) and never collapses into "doc" (a document, class docs).
#
# "project" is on no list: it is a task manager's project (personal, daily)
# as often as a deploy platform's (infra), and on a task manager it tied
# "task" and dragged the server to infra. A deploy platform has words of
# its own (deploy, site, zone) to be recognised by.
CLASSES = (
    ("none",  ("search", "docs", "reference", "compute", "generate", "render",
               "price", "flight", "hotel", "weather", "gif")),
    ("infra", ("schema", "table", "database", "sql", "deploy", "deployment", "site",
               "zone", "dns", "infra", "metric", "dashboard", "log", "analytics",
               "insight", "flag", "monitor")),
    ("docs",  ("page", "doc", "document", "note", "file", "folder", "wiki", "knowledge",
               "record", "crm", "contact", "deal", "lead", "spreadsheet", "sheet",
               "drive", "vault")),
    ("live",  ("mail", "email", "inbox", "message", "chat", "thread", "channel",
               "conversation", "calendar", "event", "meeting", "task", "todo",
               "reminder", "issue", "ticket", "draft")),
)

# "event" is two different words. On a calendar it is an appointment — the
# most live thing a person has. On an analytics product it is a row in a
# firehose ("query_events", "list_events"), and treating that as live had
# Moe polling a product-analytics server every ten minutes and offering to
# learn about the person from it. So it counts only in the company of a
# calendar word, and never on its own.
CONDITIONAL = {"event": ("calendar", "meeting", "invite", "attendee", "schedule")}

# The none words that are verbs: a way of reading, not a thing read. On a
# tool that names something personal they do not count at all; on one that
# names nothing they are weak evidence (a description's worth, even in the
# name): `search_repositories` is not a docs index, and five such tools
# must not outvote `list_issues`. A server that is only search verbs still
# lands in none — by having nothing personal, which is the honest reason.
NONE_VERBS = ("search", "compute", "generate", "render")

NAME_WEIGHT, DESC_WEIGHT = 3, 1

# Argument names that mean "only what changed since": their presence is what
# makes a docs-class read dated, so an update can ask for the last week
# rather than re-read the recipe.
DATED_ARGS = ("since", "after", "updated", "modified")

# A guess never switches the ten-minute pull on. Moe knowing what a server
# is for is not the person asking Moe to read it every ten minutes, and a
# service Moe has only guessed about is exactly where that mistake would be
# invisible. Every kind starts with sync off; the switch in Settings is how
# it goes on, and the `why` says so.
PROFILES = {
    "live":  {"sync": False, "seed": True,  "update": "daily",   "dated": True},
    "docs":  {"sync": False, "seed": True,  "update": "weekly",  "dated": False},
    "infra": {"sync": False, "seed": True,  "update": "monthly", "dated": False},
    "none":  {"sync": False, "seed": False, "update": "never",   "dated": False},
}

_TOKEN_RE = re.compile(r"[a-z0-9]+")
_KEYWORDS = {w: cls for cls, words in CLASSES for w in words}


def hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def cache_path():
    return os.path.join(hermes_home(), "cache", "mcp_schema_cache.json")


def load_cache(path=None):
    """The whole schema cache, or {} when it is missing or unreadable."""
    try:
        with open(path or cache_path(), encoding="utf-8") as f:
            v = json.load(f)
        return v if isinstance(v, dict) else {}
    except (OSError, ValueError):
        return {}


def cached_tools(server, path=None):
    """The tools list for one server, or None when the cache has no entry —
    None, not [], so a caller can tell "unknown server" from "no tools"."""
    entry = load_cache(path).get(server)
    if not isinstance(entry, dict):
        return None
    tools = entry.get("tools")
    return tools if isinstance(tools, list) else []


def _tokens(text):
    for tok in _TOKEN_RE.findall(str(text or "").lower()):
        if tok in _KEYWORDS:
            yield tok
        elif tok.endswith("s") and tok[:-1] in _KEYWORDS:
            yield tok[:-1]


def _arg_names(tool):
    schema = tool.get("inputSchema") or tool.get("parameters") or {}
    props = schema.get("properties") if isinstance(schema, dict) else None
    return [str(k) for k in (props or {})] if isinstance(props, dict) else []


def infer(tools):
    """Classify one server from its tools. Returns the profile fields the
    guess decides (sync, seed, update, dated), origin "inferred", the class,
    the hit counts, and a `why` sentence. Never raises on odd input: a
    malformed tool is skipped, an empty list is class none."""
    counts = {cls: 0 for cls, _ in CLASSES}
    words = {cls: {} for cls, _ in CLASSES}
    dated = False
    n = 0
    # A conditional word (see CONDITIONAL) only counts once the server has
    # shown one of its companions somewhere, so the whole tool list is read
    # for companions — raw words, not only keywords — before any of it is
    # scored.
    seen = set()
    for tool in tools or []:
        if not isinstance(tool, dict):
            continue
        for text in (tool.get("name"), tool.get("description")):
            for tok in _TOKEN_RE.findall(str(text or "").lower()):
                seen.add(tok[:-1] if tok.endswith("s") else tok)
    allowed = {w: any(c in seen for c in comp) for w, comp in CONDITIONAL.items()}
    for tool in tools or []:
        if not isinstance(tool, dict):
            continue
        n += 1
        fields = ((list(_tokens(tool.get("name"))), NAME_WEIGHT),
                  (list(_tokens(tool.get("description"))), DESC_WEIGHT))
        # Does this tool name anything personal at all? Then its "search"
        # is a search OF that, and not a mark against it.
        personal = any(_KEYWORDS[tok] != "none" and allowed.get(tok, True)
                       for toks, _ in fields for tok in toks)
        hits = {}
        for toks, weight in fields:
            for tok in toks:
                if not allowed.get(tok, True):
                    continue
                cls = _KEYWORDS[tok]
                if cls == "none" and tok in NONE_VERBS:
                    if personal:
                        continue
                    weight = DESC_WEIGHT
                hits[cls] = max(hits.get(cls, 0), weight)
                words[cls][tok] = words[cls].get(tok, 0) + 1
        for cls, weight in hits.items():
            counts[cls] += weight
        for arg in _arg_names(tool):
            if any(d in arg.lower() for d in DATED_ARGS):
                dated = True

    best = max(counts.values()) if counts else 0
    if best == 0:
        cls = "none"
        why = ("nothing in its %d tool%s looked personal, so Alfie will not learn from it "
               "unless you say so" % (n, "" if n == 1 else "s"))
    else:
        # First class in CLASSES order with the top count: the tie-break
        # towards less reading is the order itself.
        cls = next(c for c, _ in CLASSES if counts[c] == best)
        top = sorted(words[cls].items(), key=lambda kv: (-kv[1], kv[0]))[:3]
        named = ", ".join('"%s"' % w for w, _ in top)
        why = {
            "live":  "its tools talk about %s, which arrives all day: caught up daily, and you can have it kept ready every ten minutes" % named,
            "docs":  "its tools talk about %s, which changes over weeks: caught up weekly" % named,
            "infra": "its tools talk about %s, which changes over months: re-read monthly" % named,
            "none":  "its tools talk about %s — nothing personal to learn here" % named,
        }[cls]
        ties = [c for c, _ in CLASSES if counts[c] == best and c != cls]
        if ties:
            why += " (it could also be %s; the quieter reading wins)" % ", ".join(ties)

    out = dict(PROFILES[cls])
    if cls == "docs":
        out["dated"] = dated
        if dated:
            why += "; a tool takes a since/updated argument, so updates read only what changed"
    out.update({"origin": "inferred", "class": cls, "counts": counts, "why": why})
    return out


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: profile_infer.py <server> | --all", file=sys.stderr)
        return 2
    if argv[0] == "--all":
        for name, entry in sorted(load_cache().items()):
            tools = entry.get("tools") if isinstance(entry, dict) else None
            print(json.dumps(dict(server=name, **infer(tools or [])), sort_keys=True))
        return 0
    tools = cached_tools(argv[0])
    if tools is None:
        print("no cached schema for %r in %s" % (argv[0], cache_path()), file=sys.stderr)
        return 1
    print(json.dumps(infer(tools), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
