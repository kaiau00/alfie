"""``reach_owner(text, urgency?, channel?)``: the one way the brain reaches the
person it works for — and it can reach nobody else.

**The incident.** The owner said "message me on Telegram". The brain's brief
listed only the personal-account Telegram reader as "not connected"; the
Memoe bot the cloud holds for him was invisible to it, and it had no tool that
could message *him*. So it made a cron job told to WhatsApp him, and the job
messaged a contact. A contact-send tool takes an address, and an address is
exactly what can be wrong.

This tool takes **words and, at most, the name of a chat app** — never a chat,
a number or an address — and decides where he is at the moment it is called
(the owner's decision: "he should figure it out on the spot, know what
channels are connected"):

* **at the Mac** (the app's presence stamp: screen unlocked, awake, hands on
  it lately) → the island, and his phone stays quiet — unless HIS OWN WORDS
  this turn named a channel (the model's `channel` argument alone is not
  enough: `deliver.person_asked_for`);
* **away** → Memoe's cloud sends it to *his own* chat — the one the EDGE
  recorded (the bot's creator, or a code he sent from the app), never one
  this Mac names — on whichever chat app is live, picked (`POST /v1/owner/notify`; the recipient is fixed
  at the edge), then the chat apps he ticked on this Mac;
* **nowhere** → kept in his inbox, and the result says so.

The result names the channel that took it, so the brain can tell him the
truth. The routing is `deliver.reach_owner`; this file is the schema and the
handler. Registered in the ``connectors`` toolset on purpose: that is the
toolset Hermes never defers behind its own search (``tool_search.
_DIRECT_SURFACE_TOOLSETS``), so this is in front of the model on every turn,
on every runtime, the way the person's own connectors are.
"""
from __future__ import annotations

import json

try:
    from . import deliver as _deliver
except ImportError:  # loaded by path (the tests), not as the plugin package
    import importlib.util as _ilu
    import os as _os
    _spec = _ilu.spec_from_file_location(
        "moe_screen_deliver_for_reach",
        _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "deliver.py"))
    _deliver = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(_deliver)

TOOL_NAME = "reach_owner"
#: Hermes never defers this toolset (see the module docstring). The name is
#: shared with moe-connectors deliberately; nothing enumerates it by owner.
TOOLSET = "connectors"

TOOL_SCHEMA = {
    "name": TOOL_NAME,
    "description": (
        "Reach the person you work for — and only them. Use it whenever you "
        "need to tell them something outside this reply: a finished task, "
        "something urgent, or when they ask you to message or text them "
        "(\"message me on Telegram\", \"text me when it's done\"). It works out "
        "where they are right now: at the Mac it shows on the island; away, it "
        "goes to their own chat on whichever chat app is connected through "
        "Memoe, then to the ones they ticked on this Mac; if nothing is "
        "reachable it waits in their inbox. It never takes an address and can "
        "never reach anyone else. Never use a contact-sending tool (WhatsApp, "
        "Telegram, email, SMS…) to reach them. The result says which channel "
        "it used — tell them that, truthfully; if it was only kept in their "
        "inbox, or may have been delivered, say exactly that. Calling it again "
        "with the same words does not send them twice."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "text": {
                "type": "string",
                "description": "What to tell them, as you would say it. Short.",
            },
            "urgency": {
                "type": "string",
                "enum": list(_deliver.URGENCIES),
                "description": "\"urgent\" sends to every one of their chat apps instead "
                               "of the first that takes it — only for what truly cannot "
                               "wait; it is limited to a few an hour. Default \"normal\".",
            },
            "channel": {
                "type": "string",
                "description": "Only when they named a chat app in their own words "
                               "(\"on Telegram\"): its name, e.g. telegram. Never a chat, "
                               "a number or an address. Honoured only when their words "
                               "this turn named it; otherwise it goes where they are.",
            },
        },
        "required": ["text"],
    },
}


def handle_tool(params=None, **kwargs) -> str:
    """Hermes calls ``handler(args_dict, **kw)``. Always JSON, never raises."""
    try:
        args = params if isinstance(params, dict) else dict(kwargs)
        text = args.get("text")
        if not isinstance(text, str) or not text.strip():
            return json.dumps({"success": False, "error": "reach_owner needs the text to send"})
        urgency = args.get("urgency") or "normal"
        channel = args.get("channel") or ""
        if not isinstance(channel, str):
            channel = ""
        out = _deliver.reach_owner(text, urgency=str(urgency), channel=channel)
        result = {"success": bool(out.get("ok")), "reached": out.get("channel") or "",
                  "via": out.get("via") or "", "result": out.get("detail") or ""}
        if out.get("tried"):
            result["not_reached"] = out["tried"]
        if not out.get("ok"):
            result["error"] = out.get("detail") or "not reached"
        return json.dumps(result)
    except Exception as e:  # noqa: BLE001
        return json.dumps({"success": False, "error": "%s: %s" % (type(e).__name__, e)})


def available() -> bool:
    return True
