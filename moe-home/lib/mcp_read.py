"""Read one Hermes MCP connection deterministically — no model in the loop.

The one read helper both background passes use: the WATCH monitor script
(hermes-jobs/moe-watch-reader.py, run by Hermes's cron) and the GATHER
crawl (learn.sh's connector sources). Each declares which calls to make;
this makes exactly those calls through Hermes's own MCP client, with
Hermes's cached OAuth token, and returns text that is stable across runs.

Why no model may hold the connection: Hermes has no per-job read-only
allowlist for MCP tools, and its one server-level gate (`trust:
untrusted`) keys on a readOnlyHint annotation that Pulse, for one, does not
set on any tool — so the only way an LLM turn is kept away from a
connection's write tools is for no LLM turn to hold the connection at all.
The reads are DECLARED (a recipe on disk), never chosen by a model, and any
agent turn that later sees the text runs ["memory", "no_mcp"].

Must be run by Hermes's own interpreter (~/.hermes/hermes-agent/.venv), which
is what cron uses for `.py` scripts and what learn.sh's callers use; the
Hermes checkout is put on sys.path here. Import-safe: nothing runs at import.

Python 3.9+, stdlib only besides Hermes itself.
"""

import json
import os
import importlib
import re
import sys

MAX_CHARS_DEFAULT = 6000


def hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def _redact():
    """lib/redact.py, beside this file — the read-time PII backstop."""
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    import redact  # noqa: WPS433
    return redact


def agent_dir():
    """Hermes's checkout: ``HERMES_AGENT_DIR``, ``$HERMES_HOME/hermes-agent``
    (a Mac), ``/opt/hermes`` (the away image, where HERMES_HOME is the
    volume and the checkout is not under it — S6) — the first that holds
    ``tools/mcp_tool.py``, else the Mac's default so the import error
    names it."""
    candidates = [os.environ.get("HERMES_AGENT_DIR") or "",
                  os.path.join(hermes_home(), "hermes-agent"), "/opt/hermes"]
    for cand in candidates:
        if cand and os.path.isfile(os.path.join(cand, "tools", "mcp_tool.py")):
            return cand
    return candidates[1]


def hermes():
    """Hermes's MCP client module and tool dispatcher, from the checkout.

    Returned as a pair so callers and tests can hand in a stub."""
    agent = agent_dir()
    if agent not in sys.path:
        sys.path.insert(0, agent)
    from tools import mcp_tool  # noqa: WPS433
    from model_tools import handle_function_call  # noqa: WPS433
    return mcp_tool, handle_function_call


def _mcp_config(mcp_tool):
    """The configured MCP servers, from wherever this Hermes keeps them.

    `_load_mcp_config` used to live on `tools.mcp_tool` and now lives on
    `tools.mcp_tool_config`; `mcp_tool.__getattr__` raises for anything that
    is not a lazy SDK symbol, so the old spelling is an AttributeError rather
    than a fallback. Measured on the owner's Mac 2026-09-20 at pin
    `ce81ae8305`: every read of every gather source was skipped with
    "module 'tools.mcp_tool' has no attribute '_load_mcp_config'", so the
    learning crawl had been returning nothing at all — silently, because a
    skipped read is reported per tool and an empty gather is not an error.

    Both spellings are tried, newest first. A Hermes with neither is a real
    failure and says so, rather than reading as a source with nothing in it.
    """
    for module, attr in ((None, "_load_mcp_config"),
                         ("tools.mcp_tool_config", "_load_mcp_config")):
        holder = mcp_tool
        if module:
            try:
                holder = importlib.import_module(module)
            except ImportError:
                continue
        loader = getattr(holder, attr, None)
        if callable(loader):
            return loader()
    raise RuntimeError(
        "this Hermes exposes no MCP server configuration "
        "(tools.mcp_tool / tools.mcp_tool_config._load_mcp_config)")


def _hermes_fn(mcp_tool, name, new_module):
    """A Hermes MCP helper from where Hermes keeps it now. Hermes moved
    `register_mcp_servers` to `tools.mcp_tool_discovery` and
    `mcp_prefixed_tool_name` to `tools.mcp_tool_schema`, keeping the old
    `tools.mcp_tool.<name>` only as a shim it said it would remove on
    2026-09-14 (every read printed that warning). The real module is asked
    for the new home first; a stand-in (the tests' stub pair) is used as
    given."""
    if getattr(mcp_tool, "__name__", "") == "tools.mcp_tool":
        try:
            mod = importlib.import_module(new_module)
            fn = getattr(mod, name, None)
            if fn is not None:
                return fn
        except ImportError:
            pass
    return getattr(mcp_tool, name)


def connect(connector, mcp_tool):
    """Bring up ONE server — the one asked for — not every configured one.

    `discover_mcp_tools()` connects everything in config.yaml; here that
    would also wake Vercel and Supabase, which park without an interactive
    OAuth and cost seconds each tick for a connection nobody asked about."""
    servers = _mcp_config(mcp_tool)
    cfg = servers.get(connector)
    if not isinstance(cfg, dict):
        raise RuntimeError("%s is not a configured Hermes MCP server" % connector)
    _hermes_fn(mcp_tool, "register_mcp_servers", "tools.mcp_tool_discovery")({connector: cfg})


_VOLATILE = re.compile(
    r"^\s*(?:as of|generated|fetched|retrieved|refreshed|updated)\b[^\n]*$", re.I | re.M)

#: The same idea for a JSON answer: a line that is only an execution id.
#: Composio's tool executor returns a `log_id` on every call, so without
#: this two identical reads a day apart differ by one line, the merge sees
#: a change, and a source that has not moved is "learned" again every
#: night. `session_id` goes too, and not only for the noise: an identifier
#: that acts as a capability must never be written into a digest
#: (docs/COMPOSIO.md, fact 5).
_VOLATILE_ID = re.compile(
    r'^\s*"(?:log_id|request_id|execution_id|correlation_id|trace_id|session_id)"\s*:[^\n]*$',
    re.I | re.M)


def stable(text):
    """The result as bytes worth hashing: no 'as of 09:41' lines, no
    execution ids, no trailing whitespace, no runs of blank lines. Content
    dates are kept — a message from Tuesday is content, not noise."""
    text = _VOLATILE_ID.sub("", _VOLATILE.sub("", text or ""))
    text = "\n".join(line.rstrip() for line in text.splitlines())
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def result_text(raw):
    """(text, error). Hermes hands back a JSON string; a tool's own payload
    is usually under `result`, sometimes `content`, an error under `error`."""
    if not isinstance(raw, str):
        raw = str(raw)
    try:
        obj = json.loads(raw)
    except ValueError:
        return raw, ""
    if isinstance(obj, dict):
        if obj.get("error"):
            return "", str(obj["error"])
        for key in ("result", "content", "text"):
            if key in obj:
                val = obj[key]
                return (val if isinstance(val, str) else json.dumps(val, indent=1, sort_keys=True)), ""
        return json.dumps(obj, indent=1, sort_keys=True), ""
    return json.dumps(obj, indent=1, sort_keys=True), ""


def read_connector(connector, reads, max_chars=MAX_CHARS_DEFAULT, hermes_pair=None, task="moe-read"):
    """Make exactly these reads on one connection; return the snapshot text.

    `reads` is a list of {"tool": name, "args": {...}}. Each result is
    normalised (stable) and cut at `max_chars`, under a "## tool args"
    heading, in order. Raises on a failed call — a tool error, an
    unconfigured server — so the caller's failure path runs (for Hermes's
    monitor mode a non-zero exit is a source ERROR, never a change).

    A read may carry `"label"`, and then that is the heading instead of the
    call. It exists for a Composio toolkit, whose reads are dispatched
    through one multiplexer tool: without it every section of a gather
    would be headed COMPOSIO_MULTI_EXECUTE_TOOL and the text handed to the
    understand step would not say what was read."""
    if not re.match(r"^[a-z][a-z0-9_-]{0,31}$", str(connector or "")):
        raise ValueError("bad connector name %r" % (connector,))
    mcp_tool, call = hermes_pair or hermes()
    connect(connector, mcp_tool)
    limit = int(max_chars or MAX_CHARS_DEFAULT)
    parts = []
    for read in reads:
        if not isinstance(read, dict) or not str(read.get("tool") or "").strip():
            raise ValueError("a read must name a tool")
        tool = str(read["tool"]).strip()
        args = dict(read.get("args") or {})
        name = _hermes_fn(mcp_tool, "mcp_prefixed_tool_name", "tools.mcp_tool_schema")(connector, tool)
        raw = call(name, args, task_id="%s-%s" % (task, connector))
        text, err = result_text(raw)
        if err:
            raise RuntimeError("%s.%s: %s" % (connector, tool, err))
        # The source's own PII marker, honoured before anything downstream
        # sees the text: neither memory nor a delivery ever gets a field
        # the connection itself says to keep off scheduled surfaces.
        text = stable(_redact().drop_flagged(text))
        if len(text) > limit:
            text = text[:limit].rstrip() + "\n[… cut at %d characters]" % limit
        label = str(read.get("label") or "").strip()
        if not label:
            label = tool if not args else "%s %s" % (tool, json.dumps(args, sort_keys=True))
        parts.append("## %s\n\n%s" % (label, text or "(nothing)"))
    return "\n\n".join(parts) + "\n"


def read_json(connector, read, hermes_pair=None, task="moe-items"):
    """One read, its payload parsed rather than flattened to text — for the
    situations engine's item adapters (lib/composio_items.py), which need a
    message's id, time and sender as fields, not prose.

    The same connection, dispatcher and PII rule as `read_connector`: the
    source's own "keep this off scheduled surfaces" marker is honoured on the
    text before it is parsed. Raises on a tool error. Returns whatever JSON
    the tool gave (dict, list, or a string if it gave no JSON)."""
    if not re.match(r"^[a-z][a-z0-9_-]{0,31}$", str(connector or "")):
        raise ValueError("bad connector name %r" % (connector,))
    mcp_tool, call = hermes_pair or hermes()
    connect(connector, mcp_tool)
    if not isinstance(read, dict) or not str(read.get("tool") or "").strip():
        raise ValueError("a read must name a tool")
    name = _hermes_fn(mcp_tool, "mcp_prefixed_tool_name", "tools.mcp_tool_schema")(
        connector, str(read["tool"]).strip())
    raw = call(name, dict(read.get("args") or {}), task_id="%s-%s" % (task, connector))
    text, err = result_text(raw)
    if err:
        raise RuntimeError("%s.%s: %s" % (connector, read["tool"], err))
    text = _redact().drop_flagged(text)
    try:
        return json.loads(text)
    except ValueError:
        return text
