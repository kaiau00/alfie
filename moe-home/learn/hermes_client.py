#!/usr/bin/env python3
"""One-shot completions against the local Hermes api_server.

The endpoint is resolved the way Memoe.app resolves it (HermesEndpoint.swift):
port and key from ~/.moe/config.json (hermesPort / hermesKey), and when the
key is empty there, API_SERVER_KEY from ~/.hermes/.env. Nothing is ever
hardcoded here and nothing leaves 127.0.0.1 — the request goes out with an
empty proxy map so a system-wide HTTP proxy never sees the user's own text.

Python 3.9, stdlib only: this runs on the Mac's system interpreter.
"""

import json
import os
import re
import urllib.error
import urllib.request
import uuid

DEFAULT_PORT = 8642


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _env_key(path):
    # A .env line is KEY=value, optionally quoted; comments and blanks are
    # skipped. Last occurrence wins, like a shell would.
    key = ""
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*(?:export\s+)?API_SERVER_KEY\s*=\s*(.*?)\s*$", line)
                if m:
                    key = m.group(1).strip().strip("'\"")
    except OSError:
        pass
    return key


def resolve_endpoint():
    """→ (base_url, key). key may be empty; Hermes then forgets each turn."""
    cfg = _read_json(os.path.join(moe_home(), "config.json"))
    port = cfg.get("hermesPort", DEFAULT_PORT)
    if not isinstance(port, int) or not 1 <= port <= 65535:
        port = DEFAULT_PORT
    key = cfg.get("hermesKey") or ""
    if not isinstance(key, str) or not key:
        key = _env_key(os.path.join(hermes_home(), ".env"))
    return "http://127.0.0.1:%d" % port, key


class HermesError(Exception):
    pass


def _parse_reply(content_type, raw):
    """Assistant text from either a JSON completion or an SSE stream.

    We ask for stream=false, but the reply is parsed by shape rather than by
    trust: scripts/fake-hermes streams regardless, and a gateway that does
    the same must not turn every distil call into a parse error.
    """
    text = raw.decode("utf-8", "replace")
    if "text/event-stream" in (content_type or "") or text.lstrip().startswith("data:"):
        parts = []
        for line in text.splitlines():
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]" or not payload:
                continue
            try:
                delta = json.loads(payload)["choices"][0].get("delta", {})
            except (ValueError, KeyError, IndexError, TypeError):
                continue
            parts.append(delta.get("content") or "")
        return "".join(parts)
    try:
        return json.loads(text)["choices"][0]["message"]["content"] or ""
    except (ValueError, KeyError, IndexError, TypeError):
        raise HermesError("unexpected reply shape from Hermes")


# The learn pipeline runs several agent turns over attacker-controlled crawl
# text (distil, merge, the memory save). Each asks the gateway to narrow the
# turn's toolset so that text cannot drive an outbound action. NO_TOOLS is the
# strongest: the turn runs with no tools at all (distil/merge only transform
# text). "memory" leaves just the memory tool (the save turn needs it).
NO_TOOLS = "none"


def _verify_applied(applied_header, requested):
    """Fail closed: the gateway MUST echo X-Hermes-Applied-Toolsets confirming
    what it actually applied, and it must match. A request of [NO_TOOLS] means
    the turn must run with NO tools → applied must be empty. Any other request
    must resolve to a non-empty subset of itself (never wider). A gateway that
    predates the feature omits the header → refuse."""
    req = {t.strip() for t in requested if t and t.strip()}
    if not req:
        return
    if applied_header is None:
        raise HermesError(
            "gateway did not confirm the toolset restriction (no "
            "X-Hermes-Applied-Toolsets) — refusing to send untrusted data to a "
            "turn this gateway may not narrow; restart Alfie onto the current build")
    applied = {t.strip() for t in applied_header.split(",") if t.strip()}
    if req == {NO_TOOLS}:
        if applied:
            raise HermesError("gateway did not strip the toolset — it kept %s"
                              % ", ".join(sorted(applied)))
        return
    if not applied:
        raise HermesError("gateway applied an empty toolset — refusing the restricted turn")
    extra = applied - req
    if extra:
        raise HermesError(
            "gateway did not narrow the turn — it kept %s beyond the requested %s"
            % (", ".join(sorted(extra)), "/".join(sorted(req))))


def _post(system, user, session_key, timeout, session_id, enabled_toolsets):
    """One raw completion → (reply_text, applied_toolsets_header). No preflight
    and no verification; callers do those."""
    base, key = resolve_endpoint()
    body = json.dumps({
        "model": "hermes",
        "stream": False,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
    }).encode("utf-8")
    req = urllib.request.Request(base + "/v1/chat/completions", data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    if enabled_toolsets:
        req.add_header("X-Hermes-Enabled-Toolsets", ",".join(enabled_toolsets))
    if key:
        req.add_header("Authorization", "Bearer " + key)
        req.add_header("X-Hermes-Session-Id", session_id or uuid.uuid4().hex)
        req.add_header("X-Hermes-Session-Key", session_key)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as resp:
            applied = resp.headers.get("X-Hermes-Applied-Toolsets")
            return _parse_reply(resp.headers.get("Content-Type"), resp.read()), applied
    except urllib.error.HTTPError as e:
        raise HermesError("Hermes answered HTTP %d" % e.code)
    except (urllib.error.URLError, OSError) as e:
        raise HermesError("cannot reach Hermes at %s: %s" % (base, getattr(e, "reason", e)))


_CAPABILITY = {"checked": False, "ok": False}


def reset_capability():
    """Forget the cached capability probe (for tests)."""
    _CAPABILITY["checked"] = False
    _CAPABILITY["ok"] = False


def ensure_toolset_capable():
    """The PREVENTIVE gate. Before any turn ships untrusted data under a toolset
    restriction, confirm THIS gateway actually narrows and echoes — by sending
    one benign probe (no user data) that asks for memory-only and checking the
    echo. Cached per process. Raises HermesError if the gateway can't be trusted
    to narrow, so untrusted data is never sent to a full-tool turn. (A gateway
    that predates this feature has no echo and fails here, before any crawl text
    leaves this process.)"""
    if _CAPABILITY["checked"]:
        if not _CAPABILITY["ok"]:
            raise HermesError(
                "gateway cannot narrow a turn's toolset (checked this run) — "
                "refusing to send untrusted data; restart Alfie onto the current build")
        return
    _CAPABILITY["checked"] = True
    try:
        _, applied = _post("You are a capability probe. Reply with the word ok.",
                           "ok", "moe-capability", 30, None, ["memory"])
        _verify_applied(applied, ["memory"])
    except HermesError:
        _CAPABILITY["ok"] = False
        raise
    _CAPABILITY["ok"] = True


def chat(system, user, session_key, timeout=120, session_id=None, enabled_toolsets=None):
    """One completion. A fresh session id per call keeps Hermes from threading
    the chunks together into one ever-growing transcript.

    `enabled_toolsets` narrows the turn's toolset (X-Hermes-Enabled-Toolsets):
    the gateway keeps only the named toolsets it already exposes — shrinking a
    turn (to memory-only, or [NO_TOOLS] for no tools at all) but never widening
    it — so untrusted crawl data can't drive an outbound action. When a
    restriction is asked for, a one-time PREFLIGHT first proves the gateway
    honors it and raises BEFORE any data is sent otherwise; the applied-toolset
    echo is then re-checked after the turn as a backstop."""
    if enabled_toolsets is not None:
        # A present-but-blank restriction (``[]`` / ``[""]``) is ambiguous and,
        # left to a truthiness check, would silently skip the preflight and run
        # a full-tool turn. Reject it: ``["none"]`` means no tools, ``None``
        # means no restriction.
        enabled_toolsets = [t.strip() for t in enabled_toolsets if t and t.strip()]
        if not enabled_toolsets:
            raise HermesError(
                "empty toolset restriction — pass ['none'] for a no-tools turn "
                "or None for no restriction")
        ensure_toolset_capable()
    reply, applied = _post(system, user, session_key, timeout, session_id, enabled_toolsets)
    if enabled_toolsets:
        _verify_applied(applied, enabled_toolsets)
    return reply


def extract_json(text):
    """The first {...} object in a reply, tolerating fences and preamble."""
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\n?", "", text)
        text = re.sub(r"\n?```\s*$", "", text)
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("no JSON object in reply")
    return json.loads(text[start:end + 1])
