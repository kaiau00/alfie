"""The situations engine's adapter for every Composio toolkit — one adapter,
no per-service code (docs/PROACTIVE-MEMORY.md §4.2).

    composio_items.py <slug> items --since <cursor>

prints the toolkit's new items as the engine's item lines
(lib/situations.py `normalise_item`), then {"cursor": …}, like any
connector's `items` verb.

How it stays generic:

1. **Plan once, per toolkit, with no tools.** A small-model turn reads the
   toolkit's read-only tools (Composio's own annotations: `readOnlyHint`, not
   destructive, not update, not hidden from the router) with their argument
   schemas, and picks the ONE call that lists new things for the person —
   messages, mail, notifications, events, issues — with its window expressed
   in placeholders. The plan is validated back against those tools (the model
   cannot widen past a read) and cached, inspectable, at
   `~/.moe/gather/composio-<slug>.items.json`. A toolkit with no such call is
   recorded as not watchable, and asked again a week later.
2. **Run it deterministically.** Through Hermes's own MCP client and
   Composio's multiplexer (`mcp_autoread.dispatch`), no model holding the
   connection, like every other background read (lib/mcp_read.py).
3. **Read the answer by shape, not by name.** The items are the list of
   records that most carry an id, a time and text — not merely the longest
   list (a mail's twenty headers, or the multiplexer's one-element `results`
   wrapper, used to win); within a record, the id, time, sender, text and
   conversation are found by the field names services actually use
   (`FIELDS`), wherever in the record they sit.

The cursor is `{"t": <epoch>, "ids": [...]}`: the newest time seen (never
later than now), and the records at the edge of the window as `id@time`, so
an overlap is not read twice but a record that CHANGED — a notification with
new activity, an event moved — is read again. A first look
prints only a cursor of now, like every adapter: the engine starts from the
moment it was switched on, never from the history.

Runs under Hermes's interpreter (mcp_read and call_llm import Hermes).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, Iterable, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

PLACEHOLDERS = ("{since_epoch}", "{since_iso}", "{since_date}", "{since_slash_date}")
REPLAN_AFTER_DAYS = 7
TRANSIENT_RETRY_S = 3600
OVERLAP_SECONDS = 120
MAX_ITEMS = 100
EDGE_IDS = 200


def moe_home() -> str:
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


#: Bumped when what a plan must ask for changes; a plan made under an older
#: version is made again. 2 (2026-09-25): whole message text, not snippets —
#: the owner's Gmail plan read subject + preview only (median 261 chars).
#: 3 (2026-09-25): tools tagged mcpIgnore may be planned (GitHub had been
#: planned as "nothing to watch" with its notifications lister hidden).
PLAN_VERSION = 3


def plan_path(slug: str) -> str:
    return os.path.join(moe_home(), "gather", "composio-%s.items.json" % slug)


def _now() -> float:
    return time.time()


# ── 1. the plan ────────────────────────────────────────────────────────────

READ_TAG = "readOnlyHint"
#: Not `mcpIgnore`: that tag only keeps a tool out of Composio's default MCP
#: tool list — the multiplexer runs it by slug all the same (measured
#: 2026-09-25: GITHUB_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER, tagged
#: mcpIgnore, answered through COMPOSIO_MULTI_EXECUTE_TOOL). Denying it hid
#: 670 of GitHub's 823 tools, the notifications lister among them, and the
#: plan said GitHub had nothing to watch.
DENY_TAGS = {"destructiveHint", "updateHint"}
#: Words in a tool's name that say "lists what is new for me". Used only to
#: put such tools first when a big toolkit has more than the planner is shown.
_NEWS_WORDS = ("notification", "inbox", "unread", "received", "mention", "assigned", "message",
               "mail", "email", "event", "activity", "feed", "recent", "new", "review", "dm",
               "conversation", "comment", "list", "fetch", "search")
PLAN_TOOLS = 60


def rank_for_plan(tools: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Tools most likely to list what is new for the person first — by the
    words of their names, generically; the order is otherwise kept."""
    def score(t):
        words = set(re.split(r"[^a-z0-9]+", str(t.get("slug") or "").lower()))
        return -sum(1 for w in _NEWS_WORDS if w in words or (w + "s") in words)
    return sorted(tools, key=score)


def read_tools(rows: Iterable[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """The tools a plan may use: Composio says they only read, and nothing
    says otherwise. An id-taking read (fetch ONE message) is not a lister,
    so a tool whose required arguments are not all optional-in-practice
    (a query or a window) is left out."""
    out = []
    for t in rows or []:
        tags = set(t.get("tags") or [])
        if READ_TAG not in tags or tags & DENY_TAGS:
            continue
        required = [r.lower() for r in (t.get("required") or [])]
        if any(("id" in r.split("_") or r.endswith("id")) for r in required):
            continue
        out.append(t)
    return out


PLAN_SYSTEM = (
    "You configure a background reader for one connected service. You are "
    "shown the service's read-only tools with their arguments. Pick the ONE "
    "call that lists what is NEW for the person since a moment in time: their "
    "incoming messages, mail, notifications, mentions, events or issues — the "
    "things another person or system sends them. Not settings, not catalogs, "
    "not their own documents.\n\n"
    "It must be about THIS person's own account: their inbox, their "
    "notifications, their calendar, what mentions or is assigned to them. "
    "Never a search across everyone on the service (a public search of all "
    "pull requests, all posts, all repositories): if the only listers are "
    "global searches that cannot be limited to the person, answer with no "
    "tool.\n\n"
    "Express the moment with exactly one of these placeholders inside an "
    "argument value: {since_epoch} (unix seconds), {since_iso} (ISO 8601), "
    "{since_date} (YYYY-MM-DD), {since_slash_date} (YYYY/MM/DD). Keep results "
    "small (a max of about 25). Each result must carry the WHOLE text of the "
    "message, mail body or comment — a snippet or preview is not enough, "
    "because what someone asks is often past the first lines: turn on "
    "whatever argument includes the body or full content (payload, verbose, "
    "format=full or similar). Never attachments or files.\n\n"
    "Say whether EVERY result of that call is addressed to the person by "
    "its nature — their own inbox, notifications, direct messages, mentions "
    "or assignments (\"addressed\": true) — or only some are, like a channel "
    "or a calendar they share (\"addressed\": false).\n\n"
    "Answer JSON only: {\"tool\": \"<slug>\", \"args\": {...}, \"addressed\": "
    "true|false, \"why\": \"<one line>\"} — or {\"tool\": null, \"why\": \"...\"} when no tool lists new "
    "things by time."
)


def plan_messages(slug: str, tools: List[Dict[str, Any]]) -> List[Dict[str, str]]:
    lines = []
    for t in rank_for_plan(tools)[:PLAN_TOOLS]:
        params = t.get("parameters") or {}
        args = "; ".join("%s (%s): %s" % (k, v.get("type", ""), v.get("description", "")[:100])
                         for k, v in list(params.items())[:14])
        lines.append("- %s — %s\n  args: %s" % (t.get("slug"), (t.get("description") or "")[:200],
                                                 args or "none"))
    return [{"role": "system", "content": PLAN_SYSTEM},
            {"role": "user", "content": "Service: %s\n\nTools:\n%s" % (slug, "\n".join(lines))}]


def _has_placeholder(value: Any) -> bool:
    if isinstance(value, str):
        return any(p in value for p in PLACEHOLDERS)
    if isinstance(value, dict):
        return any(_has_placeholder(v) for v in value.values())
    if isinstance(value, list):
        return any(_has_placeholder(v) for v in value)
    return False


def validate_plan(answer: Any, tools: List[Dict[str, Any]]) -> Tuple[Optional[Dict[str, Any]], str]:
    text = answer if isinstance(answer, str) else _answer_text(answer)
    m = re.search(r"\{.*\}", str(text or ""), re.S)
    if not m:
        return None, "unreadable plan"
    try:
        data = json.loads(m.group(0))
    except ValueError:
        return None, "unreadable plan"
    tool = data.get("tool")
    if not tool:
        return None, "no tool lists new things by time: %s" % str(data.get("why") or "")[:160]
    by_slug = {t.get("slug"): t for t in tools}
    if tool not in by_slug:
        return None, "the plan named a tool that is not a read: %s" % tool
    args = data.get("args") if isinstance(data.get("args"), dict) else {}
    allowed = set((by_slug[tool].get("parameters") or {}).keys())
    if allowed and not set(args) <= allowed:
        return None, "the plan used arguments the tool does not take: %s" % sorted(set(args) - allowed)
    if not _has_placeholder(args):
        return None, "the plan has no time window"
    return {"tool": tool, "args": args, "addressed": data.get("addressed") is True,
            "why": str(data.get("why") or "")[:200]}, "planned"


def _answer_text(result: Any) -> str:
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


def fetch_tools(slug: str) -> Optional[List[Dict[str, Any]]]:
    script = os.path.join(moe_home(), "connectors", "composio.py")
    try:
        p = subprocess.run([sys.executable, script, "tools", slug, "--json", "--schemas"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           universal_newlines=True, timeout=240)
        return json.loads(p.stdout or "{}").get("tools") if p.returncode == 0 else None
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def default_call(messages):
    """The cheapest model the person's own provider serves (cheap_model.py
    beside this file), never the conversation's model."""
    return _cheap_model().call(messages, max_tokens=500, timeout=90)


def _cheap_model():
    import importlib.util
    mod = sys.modules.get("cheap_model")
    if mod is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cheap_model.py")
        spec = importlib.util.spec_from_file_location("cheap_model", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sys.modules["cheap_model"] = mod
    return mod


def load_plan(slug: str) -> Optional[Dict[str, Any]]:
    try:
        with open(plan_path(slug), encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def _save_plan(slug: str, plan: Dict[str, Any]) -> None:
    """A rebuilt read plan keeps the toolkit's `triggers` record: it names
    triggers live at Composio, and without it nothing could ever delete them
    (a replan every week dropped it — review 2026-09-28 §1)."""
    held = (load_plan(slug) or {}).get("triggers")
    if held and "triggers" not in plan:
        plan = dict(plan, triggers=held)
    _save(plan_path(slug), plan)


def _save(path: str, data: Any) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def plans_here() -> bool:
    """Only a Mac plans: it holds Composio's catalogue key and the person's
    account identities (connectors/composio.py). The away machine reads with
    the plan the Mac made, which travels to it as the
    `situations/plan/<slug>` document (moeledger/documents.py)."""
    return (os.environ.get("MOE_RUNS_IN") or ("mac" if sys.platform == "darwin" else "cloud")) == "mac"


def ensure_plan(slug: str, *, tools_fn=fetch_tools, call=None, now: Optional[float] = None,
                owners_fn=None) -> Dict[str, Any]:
    """The cached plan, or a new one. Always a dict: {"tool": …} when the
    toolkit can be watched, {"tool": null, "why": …} when it cannot. A plan
    carries `owner_ids` — who "me" is on the service — so the machine, which
    cannot ask, knows the person's own messages too."""
    now = _now() if now is None else now
    cached = load_plan(slug)
    if not plans_here():
        return cached or {"tool": None, "why": "no plan from the Mac yet", "at": now, "transient": True}
    age = now - float((cached or {}).get("at") or 0)
    # A plan from before the current version is made again — but the old
    # one keeps working until a new one validates (below), so a failed
    # replan never switches off a source that was being read.
    outdated = cached if (cached and cached.get("v") != PLAN_VERSION
                          and not os.environ.get("MOE_NO_THINK")) else None
    if outdated and outdated.get("tried") and now - float(outdated["tried"]) < TRANSIENT_RETRY_S:
        return outdated          # a replan failed recently: the old plan, until the retry
    if outdated:
        cached = None

    def keep_outdated():
        """The replan failed: keep reading with the old plan, and ask again
        after TRANSIENT_RETRY_S rather than on every tick."""
        kept = dict(outdated, tried=now)
        _save_plan(slug, kept)
        return kept
    if cached and (cached.get("tool") or age < (TRANSIENT_RETRY_S if cached.get("transient")
                                                 else REPLAN_AFTER_DAYS * 86400)):
        return cached
    if os.environ.get("MOE_NO_THINK"):
        # Background thinking is off: planning is a model call, so none is
        # made; the cached plan (if any) is used, and nothing is planned.
        return cached or {"tool": None, "why": "background thinking is off", "at": now, "transient": True}
    rows = tools_fn(slug)
    if rows is None and outdated and outdated.get("tool"):
        return keep_outdated()
    if rows is None:
        # Cached for an hour: a catalogue miss used to be re-fetched (a
        # 240-second subprocess) on every five-minute tick.
        plan = {"tool": None, "why": "could not read the service's tool list", "at": now,
                "transient": True, "v": PLAN_VERSION}
        _save_plan(slug, plan)
        return plan
    tools = read_tools(rows)
    if not tools:
        plan = {"tool": None, "why": "no read-only tools", "at": now}
    else:
        try:
            found, why = validate_plan((call or default_call)(plan_messages(slug, tools)), tools)
        except Exception:  # noqa: BLE001
            if outdated and outdated.get("tool"):
                return keep_outdated()
            raise
        if not found and outdated and outdated.get("tool"):
            return keep_outdated()   # the old plan stands; asked again after the retry time
        plan = dict(found, at=now) if found else {"tool": None, "why": why, "at": now}
        if found:
            plan["owner_ids"] = (owners_fn or owner_ids)(slug)
    plan["v"] = PLAN_VERSION
    _save_plan(slug, plan)
    return plan


# ── 2. the window ──────────────────────────────────────────────────────────


def fill(value: Any, since: float) -> Any:
    dt = datetime.fromtimestamp(since, timezone.utc)
    subs = {"{since_epoch}": str(int(since)),
            "{since_iso}": dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "{since_date}": dt.strftime("%Y-%m-%d"),
            "{since_slash_date}": dt.strftime("%Y/%m/%d")}
    if isinstance(value, str):
        if value in subs and value == "{since_epoch}":
            return int(since)
        for k, v in subs.items():
            value = value.replace(k, v)
        return value
    if isinstance(value, dict):
        return {k: fill(v, since) for k, v in value.items()}
    if isinstance(value, list):
        return [fill(v, since) for v in value]
    return value


# ── 3. reading the answer by shape ─────────────────────────────────────────

FIELDS = {
    "id": ("messageId", "message_id", "id", "uid", "ts", "number", "node_id", "event_id", "eventId"),
    "thread": ("threadId", "thread_id", "conversationId", "conversation_id", "channel", "channel_id",
               "chat_id", "issue_url", "subject_id", "repository_url", "html_url"),
    "text": ("messageText", "snippet", "preview", "text", "body", "content", "message", "summary",
             "description", "subject", "title"),
    "title": ("subject", "title", "name", "summary"),
    "from": ("sender", "from", "author", "user", "creator", "organizer", "actor", "owner"),
    # When it became new — sent, received, created or changed — before when
    # it happens (`start`, for an event), which only stands in when nothing
    # else says.
    "at": ("messageTimestamp", "internalDate", "date", "timestamp", "created_at", "createdAt",
           "updated_at", "updatedAt", "updated", "created", "ts", "time", "sent_at", "received_at",
           # Notion, Microsoft Graph, Google Drive and friends.
           "last_edited_time", "created_time", "receivedDateTime", "sentDateTime",
           "lastModifiedDateTime", "createdDateTime", "modifiedTime", "createdTime",
           "start"),
    # Who it was sent to. When a record says, "addressed to the owner" is
    # whether an owner id is among them — not, as it was, every record.
    "to": ("to", "To", "recipient", "recipients", "toRecipients", "to_recipients", "assignee",
           "assignees", "mentions", "attendees", "requested_reviewers"),
}


def _lists(obj: Any, depth: int = 0) -> List[List[Dict[str, Any]]]:
    """Every list of dicts anywhere in the payload."""
    out: List[List[Dict[str, Any]]] = []
    if depth > 8:
        return out
    if isinstance(obj, list):
        dicts = [x for x in obj if isinstance(x, dict)]
        if dicts:
            out.append(dicts)
        for x in obj:
            out.extend(_lists(x, depth + 1))
    elif isinstance(obj, dict):
        for v in obj.values():
            out.extend(_lists(v, depth + 1))
    return out


def _looks_like_item(rec: Dict[str, Any]) -> bool:
    return (_find(rec, FIELDS["id"]) not in (None, "") and _as_epoch(_find(rec, FIELDS["at"])) is not None
            and bool(_as_text(_find(rec, FIELDS["text"])).strip()))


def _records(obj: Any) -> List[Dict[str, Any]]:
    """The payload's items: of every list of records in it, the one with the
    most records that carry an id, a time and text. A list whose records
    carry none of the three is never it, however long."""
    best, best_score = [], 0
    for dicts in _lists(obj):
        score = sum(1 for d in dicts if _looks_like_item(d))
        if score > best_score or (score == best_score and score and len(dicts) < len(best)):
            best, best_score = dicts, score
    return best


#: Objects an item sits inside rather than parts of it: their owner is not
#: the item's sender, their url is not its conversation (a GitHub
#: notification's `repository.owner` made every notification the owner's own).
_CONTAINERS = ("repository", "repo", "organization", "org", "workspace", "project", "team",
               "space", "board", "base", "site")


def _find(rec: Dict[str, Any], keys: Tuple[str, ...], depth: int = 0, skip_containers: bool = False) -> Any:
    for k in keys:
        if k in rec and rec[k] not in (None, "", [], {}):
            return rec[k]
    if depth < 2:
        for name, v in rec.items():
            if skip_containers and name in _CONTAINERS:
                continue
            if isinstance(v, dict):
                got = _find(v, keys, depth + 1, skip_containers)
                if got not in (None, "", [], {}):
                    return got
    return None


_TEXT_KEYS = ("text", "body", "content", "plain", "plain_text", "markdown", "html", "title",
              "subject", "summary", "message", "snippet", "data", "value", "name", "login", "email",
              "emailAddress", "address")
_NOT_WORDS = re.compile(r"^(https?://|[0-9a-f-]{16,}$|\d+$)", re.I)


def _as_text(v: Any, depth: int = 0) -> str:
    """Words in a value: a string; the first wordy field of a dict (known
    text keys first, then any string that is not a link or an id, one level
    of nesting at a time — a Notion title is properties.Name.title[0].
    plain_text, an Outlook sender is from.emailAddress.address); a list's
    first few. Never the dict's own repr."""
    if isinstance(v, str):
        return v
    if isinstance(v, dict):
        if depth > 4:
            return ""
        for k in _TEXT_KEYS:
            if k in v:
                got = _as_text(v[k], depth + 1).strip()
                if got:
                    return got
        for k, x in v.items():
            if isinstance(x, str) and x.strip() and not _NOT_WORDS.match(x.strip()) and "id" not in k.lower():
                return x
        for x in v.values():
            if isinstance(x, (dict, list)):
                got = _as_text(x, depth + 1).strip()
                if got:
                    return got
        return ""
    if isinstance(v, list):
        if depth > 4:
            return ""
        return " ".join(t for t in (_as_text(x, depth + 1) for x in v[:3]) if t)
    return "" if v is None else str(v)


def _who(v: Any) -> str:
    """A sender as "Name <address>" when the record gives both — the
    address is what tells the owner's own messages apart. Looks in the
    value and one level of objects inside it (Outlook: from.emailAddress)."""
    if not isinstance(v, dict):
        return _as_text(v)
    layers = [v] + [x for x in v.values() if isinstance(x, dict)]
    name = next((l[k] for l in layers for k in ("name", "displayName", "display_name", "login")
                 if isinstance(l.get(k), str) and l[k].strip()), "")
    addr = next((l[k] for l in layers for k in ("address", "email", "emailAddress", "mail")
                 if isinstance(l.get(k), str) and "@" in l[k]), "")
    if name and addr and addr not in name:
        return "%s <%s>" % (name, addr)
    return name or addr or _as_text(v)


_TAG = re.compile(r"<[^>]{0,300}>")


def _plain(text: str) -> str:
    """HTML read as words: tags out, entities decoded, whitespace kept."""
    if "<" not in text or not _TAG.search(text):
        return text
    import html as _html
    text = re.sub(r"(?is)<(script|style).*?</\1>", " ", text)
    text = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</li>", "\n", text)
    return _html.unescape(_TAG.sub(" ", text))


def _as_epoch(v: Any) -> Optional[float]:
    if v is None:
        return None
    if isinstance(v, dict):
        v = v.get("dateTime") or v.get("date") or v.get("value")
    if isinstance(v, (int, float)) or (isinstance(v, str) and re.fullmatch(r"\d{9,13}(\.\d+)?", v.strip())):
        f = float(v)
        return f / 1000.0 if f > 1e12 else f
    if isinstance(v, str):
        s = v.strip().replace("Z", "+00:00")
        for fmt in (None, "%a, %d %b %Y %H:%M:%S %z", "%d %b %Y %H:%M:%S %z"):
            try:
                dt = datetime.fromisoformat(s) if fmt is None else datetime.strptime(v.strip(), fmt)
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                return dt.timestamp()
            except ValueError:
                continue
    return None


def _addressed(rec: Dict[str, Any], owners: set) -> bool:
    """To the owner: an owner id among the record's recipients, or in a
    mail's To/Cc headers. A record that names no recipient is not taken to
    be addressed to them — the gate then wants the owner to have taken part
    in the thread before it spends a call on it (review §15)."""
    if not owners:
        return False
    found = _find(rec, FIELDS["to"])
    blob = json.dumps(found, ensure_ascii=False).lower() if found not in (None, "", [], {}) else ""
    headers = _find(rec, ("headers",))
    if isinstance(headers, list):
        blob += " ".join(str(h.get("value") or "") for h in headers
                         if isinstance(h, dict) and str(h.get("name") or "").lower() in ("to", "cc")).lower()
    return any(o in blob for o in owners)


def _thread(rec: Dict[str, Any], iid: str) -> str:
    """The record's own conversation: a thread key on the record itself;
    then one nested in it, but never the container it lives in (a GitHub
    notification's `repository.html_url` made a whole repository one
    conversation); then the record's own id — many listers (notifications,
    issues) list one item per conversation."""
    for k in FIELDS["thread"]:
        v = rec.get(k)
        if v not in (None, "", [], {}):
            # A top-level channel given as an object ({"id": …, "name": …})
            # is still the conversation.
            got = _as_text(v.get("id") if isinstance(v, dict) and v.get("id") else v)
            if got:
                return got
    nested = _find(rec, tuple(k for k in FIELDS["thread"] if k not in _CONTAINER_KEYS), skip_containers=True)
    return _as_text(nested) or iid


#: Keys that name the place an item lives rather than its conversation.
_CONTAINER_KEYS = ("repository_url", "html_url", "channel", "channel_id")


def extract(payload: Any, owner_ids: Iterable[str] = (), now: Optional[float] = None,
            addressed: bool = False) -> List[Dict[str, Any]]:
    """The payload's records as items. A record with no id, no time or no
    text is not an item. A time in the future (an event's start standing in
    for when it was sent) is read as now: it would otherwise hold the cursor,
    and the gate's "still talking", in the future (review §7); the record's
    own time is kept as `seen_at` for the cursor's edge."""
    owners = {o.lower() for o in owner_ids if o}
    now = _now() if now is None else now
    out = []
    for rec in _records(payload)[:MAX_ITEMS]:
        iid = _as_text(_find(rec, FIELDS["id"]))
        at = _as_epoch(_find(rec, FIELDS["at"]))
        text = _plain(_as_text(_find(rec, FIELDS["text"]))).strip()
        title = _as_text(_find(rec, FIELDS["title"])).strip()
        if title and title not in text:
            text = (title + " — " + text).strip(" —")
        if not iid or at is None or not text:
            continue
        who = _who(_find(rec, FIELDS["from"], skip_containers=True)).strip()
        thread = _thread(rec, iid)
        me = bool(who) and any(o in who.lower() for o in owners)
        out.append({"id": iid, "thread": thread, "thread_name": (title or who)[:120], "at": min(at, now),
                    "seen_at": at,
                    "from": {"id": who[:120], "name": re.sub(r"\s*<[^>]*>", "", who)[:120], "me": me},
                    # A lister of the person's own inbox or notifications
                    # (the plan says so) is addressed to them by its nature.
                    "to_me": (addressed and not me) or _addressed(rec, owners),
                    "group": False, "kind": "msg",
                    "text": text[:2000]})
    return out


# ── the verb ───────────────────────────────────────────────────────────────


def parse_cursor(raw: str) -> Optional[Dict[str, Any]]:
    try:
        c = json.loads(raw) if raw else None
        return c if isinstance(c, dict) and "t" in c else None
    except ValueError:
        return None


def owner_ids(slug: str) -> List[str]:
    """Who "me" is on this service: the connected account's own identity,
    as Alfie's Composio helper already names it (`account_identity`)."""
    script = os.path.join(moe_home(), "connectors", "composio.py")
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("moe_composio_for_items", script)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        ident = mod.account_identity(slug)
        vals = ident.values() if isinstance(ident, dict) else [ident]
        return [str(v) for v in vals if isinstance(v, str) and v]
    except Exception:  # noqa: BLE001
        return []


def items(slug: str, raw_cursor: str, *, reader=None, plan_fn=ensure_plan,
          owners: Optional[List[str]] = None, now: Optional[float] = None) -> Tuple[List[Dict[str, Any]], str]:
    """(items, new cursor). Raises when the read fails, so the engine moves
    no cursor."""
    now = _now() if now is None else now
    cursor = parse_cursor(raw_cursor)
    if cursor is None:
        return [], json.dumps({"t": now, "ids": []})
    plan = plan_fn(slug)
    if not plan.get("tool"):
        # Not watchable (or its tool list could not be read): nothing to
        # read, and the cursor keeps up so a later plan starts from then.
        return [], json.dumps({"t": now, "ids": []})
    refused = runnable(slug, plan)
    if refused:
        # Checked every time it runs, on both sides: the plan file is a file,
        # and a plan is only ever a read (review §14).
        raise PermissionError("the plan for %s is not a read: %s" % (slug, refused))
    since = float(cursor["t"]) - OVERLAP_SECONDS
    read = {"tool": plan["tool"], "args": fill(plan.get("args") or {}, since)}
    if reader is None:
        import mcp_autoread
        import mcp_read
        payload = mcp_read.read_json("composio", mcp_autoread.dispatch("composio/" + slug, read))
    else:
        payload = reader(read)
    seen = set(cursor.get("ids") or [])
    if owners is None:
        owners = plan.get("owner_ids") if isinstance(plan.get("owner_ids"), list) else (
            owner_ids(slug) if plans_here() else [])
    found = [it for it in extract(payload, owners, now, addressed=plan.get("addressed") is True)
             if it["seen_at"] > since and _key(it) not in seen]
    found.sort(key=lambda it: it["at"])
    newest = min(now, max([float(cursor["t"])] + [it["at"] for it in found]))
    # The edge: what the next window's overlap will show again, by id AND
    # its own time, so the same record changed later is new.
    edge = [_key(it) for it in found if it["seen_at"] >= newest - OVERLAP_SECONDS]
    ids = (list(seen) + edge)[-EDGE_IDS:]
    for it in found:
        it.pop("seen_at", None)
    return found, json.dumps({"t": newest, "ids": ids})


def _key(it: Dict[str, Any]) -> str:
    return "%s@%d" % (it["id"], int(it.get("seen_at", it["at"])))


#: Verbs no read plan's tool may carry, checked when the plan RUNS (the
#: planner already kept to Composio's own read-only annotations; this is the
#: second key, for a plan file that did not come from the planner).
_MUTATING = frozenset("""
send create delete remove update post patch put reply forward move archive trash add set
write upload modify edit merge approve reject cancel charge refund pay transfer invite
accept star unstar follow unfollow subscribe unsubscribe mark execute run trigger publish
share assign unassign close reopen lock unlock pin unpin mute unmute block unblock label
unlabel insert import restore revoke grant enable disable install uninstall schedule
""".split())


def runnable(slug: str, plan: Dict[str, Any]) -> str:
    """Why this plan may NOT run, or "" when it may: its tool is one of this
    toolkit's own, has no mutating verb in its name, and — where the
    toolkit's catalogue is cached here — is annotated read-only there."""
    tool = str(plan.get("tool") or "")
    prefix = slug.upper() + "_"
    if not tool.startswith(prefix) or not re.fullmatch(r"[A-Z0-9_]+", tool):
        return "%s is not one of %s's tools" % (tool or "no tool", slug)
    verbs = set(tool[len(prefix):].lower().split("_"))
    if verbs & _MUTATING:
        return "%s names a change (%s)" % (tool, ", ".join(sorted(verbs & _MUTATING)))
    catalogue = os.path.join(moe_home(), "gather", "composio-%s.tools.json" % slug)
    try:
        with open(catalogue, encoding="utf-8") as f:
            rows = (json.load(f) or {}).get("tools")
    except (OSError, ValueError, AttributeError):
        rows = None
    if isinstance(rows, list) and rows:
        if tool not in {t.get("slug") for t in read_tools(r for r in rows if isinstance(r, dict))}:
            return "%s is not a read-only lister in %s's catalogue" % (tool, slug)
    return ""


def main(argv: List[str]) -> int:
    if len(argv) < 3 or argv[2] != "items":
        print("usage: composio_items.py <slug> items --since <cursor>", file=sys.stderr)
        return 2
    slug = argv[1].split("/")[-1].lower()
    raw = argv[argv.index("--since") + 1] if "--since" in argv and argv.index("--since") + 1 < len(argv) else ""
    agent = os.environ.get("HERMES_AGENT_DIR") or os.path.join(
        os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes"), "hermes-agent")
    if os.path.isdir(agent) and agent not in sys.path:
        sys.path.insert(0, agent)
    try:
        found, cursor = items(slug, raw)
    except Exception as e:  # noqa: BLE001 — a failed read moves no cursor
        print("composio items %s: %s: %s" % (slug, type(e).__name__, e), file=sys.stderr)
        return 1
    for it in found:
        print(json.dumps(it, ensure_ascii=False))
    print(json.dumps({"cursor": cursor}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
