"""Composio triggers for the toolkits that cannot be read on a clock
(docs/PROACTIVE-MEMORY.md slice 7; owner decisions 2026-09-28).

A toolkit whose read plan found no "what is new for me" lister (LinkedIn,
Slack's live messages) can still tell Moe something happened — if Composio
pushes it. This module, on the Mac, turns such pushes on:

  1. only for a PAID tenant (tier away/away_plus: anything on a clock is
     paid), a toolkit the person granted with `speak`, connected, and whose
     read plan has no tool — a toolkit that can be read is read, never both;
  2. the toolkit's trigger types are read from Composio's catalogue, and the
     cheapest model picks the ones that mean "something new for the person"
     (a direct message, a mention, a message received) among those needing
     NO configuration — anything needing a repository, a channel or an id is
     a choice only the person could make;
  3. each is created in the person's own Composio project, under their own
     user id, and the edge is asked to make sure the project's webhook
     subscription points at it (edge `POST /v1/composio/triggers/enable`).

The choice is written into the toolkit's read plan (`triggers`), which
already travels to the away machine as the `situations/plan/<slug>`
document: the machine's reader (lib/composio_events.py) takes only the
events of triggers named there. A toolkit the person revokes, disconnects,
or a tier that drops to free has its triggers deleted (`retire`).

Pushes land on the edge, sealed at once to the tenant's cloud machine, and
only the machine collects them: nothing here reads an event.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import time
from typing import Any, Callable, Dict, List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import composio_items  # noqa: E402

PAID_TIERS = ("away", "away_plus")
MAX_TRIGGERS = 3
#: How often a toolkit with no triggers chosen is looked at again.
RECHECK_S = 7 * 86400
TRIGGERS_VERSION = 1


def moe_home() -> str:
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def tier() -> str:
    """The tenant's tier from `~/.moe/cloud/tier.json`, beside a credential
    naming a tenant; anything unreadable is free (composio-budget.sh's rule,
    failing toward free)."""
    cloud = os.path.join(moe_home(), "cloud")
    try:
        with open(os.path.join(cloud, "credential.json"), encoding="utf-8") as f:
            if not (json.load(f) or {}).get("tenant"):
                return "free"
        with open(os.path.join(cloud, "tier.json"), encoding="utf-8") as f:
            t = (json.load(f) or {}).get("tier")
        return t if t in PAID_TIERS else "free"
    except (OSError, ValueError, AttributeError):
        return "free"


def _composio():
    """connectors/composio.py, loaded by path (it is a script)."""
    mod = sys.modules.get("moe_composio_connector")
    if mod is not None:
        return mod
    path = os.path.join(moe_home(), "connectors", "composio.py")
    spec = importlib.util.spec_from_file_location("moe_composio_connector", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    sys.modules["moe_composio_connector"] = mod
    return mod


def trigger_types(slug: str, call=None) -> Optional[List[Dict[str, Any]]]:
    """Composio's catalogue of trigger types for a toolkit, as {slug, name,
    description, type, required}; None when it could not be read."""
    call = call or _composio().call
    status, body = call("GET", "/api/v3/triggers_types?toolkit_slugs=%s&limit=100" % slug)
    if status != 200 or not isinstance(body, dict):
        return None
    out = []
    for t in body.get("items") or []:
        cfg = t.get("config") if isinstance(t.get("config"), dict) else {}
        out.append({"slug": t.get("slug"), "name": t.get("name") or "",
                    "description": (t.get("description") or "")[:200], "type": t.get("type") or "",
                    "required": list(cfg.get("required") or [])})
    return [t for t in out if t["slug"]]


PLAN_SYSTEM = (
    "You choose which events a personal assistant should be told about for one "
    "connected service. You are shown the service's event types that need no "
    "setup. Pick at most %d that mean something NEW arrived for the person and "
    "may need them: a direct message, a mention, a message received, an "
    "invitation, something assigned to them. Not their own actions, not "
    "reactions, not structural changes (a channel created, a follower).\n\n"
    "Say for each whether every such event is addressed to the person by its "
    "nature (a direct message, a mention: true) or only sometimes (a message "
    "in a channel: false).\n\n"
    "Answer JSON only: {\"triggers\": [{\"slug\": \"...\", \"addressed\": true|false}]} "
    "— an empty list when none fit." % MAX_TRIGGERS
)


def choose(slug: str, types: List[Dict[str, Any]], call: Callable) -> List[Dict[str, Any]]:
    """The cheap model's pick among the types needing no configuration,
    checked against the catalogue."""
    free = [t for t in types if not t["required"]]
    if not free:
        return []
    lines = ["- %s (%s): %s" % (t["slug"], t["type"], t["description"] or t["name"]) for t in free[:60]]
    messages = [{"role": "system", "content": PLAN_SYSTEM},
                {"role": "user", "content": "Service: %s\n\nEvent types:\n%s" % (slug, "\n".join(lines))}]
    text = composio_items._answer_text(call(messages))
    m = re.search(r"\{.*\}", text or "", re.S)
    try:
        data = json.loads(m.group(0)) if m else {}
    except ValueError:
        return []
    known = {t["slug"] for t in free}
    picked, seen = [], set()
    for t in data.get("triggers") or []:
        if not isinstance(t, dict) or t.get("slug") not in known or t["slug"] in seen:
            continue
        seen.add(t["slug"])
        picked.append({"slug": t["slug"], "addressed": t.get("addressed") is True})
        if len(picked) == MAX_TRIGGERS:
            break
    return picked


def _edge(method: str, path: str, body: Optional[Dict[str, Any]] = None) -> Tuple[int, Any]:
    """The edge, as this Mac: channels.py's `call` (the credential's bearer)."""
    path_py = os.path.join(moe_home(), "connectors", "channels.py")
    spec = importlib.util.spec_from_file_location("moe_channels_for_triggers", path_py)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    try:
        return mod.call(method, path, body)
    except SystemExit:           # channels.py `die`s when the edge cannot be reached
        return 0, {}


def _upsert(trigger_slug: str, user_id: str, call=None) -> Optional[str]:
    call = call or _composio().call
    status, body = call("POST", "/api/v3/trigger_instances/%s/upsert" % trigger_slug,
                        {"user_id": user_id, "trigger_config": {}})
    if status not in (200, 201) or not isinstance(body, dict):
        return None
    return body.get("trigger_id") or body.get("id")


def _delete(trigger_id: str, call=None) -> bool:
    call = call or _composio().call
    if not trigger_id:
        return False
    status, _ = call("DELETE", "/api/v3/trigger_instances/manage/%s" % trigger_id)
    return status in (200, 204, 404)


def ensure(slug: str, *, model_call: Optional[Callable] = None, composio_call=None, edge_call=None,
           user_id: Optional[str] = None, now: Optional[float] = None) -> Dict[str, Any]:
    """Turn a toolkit's pushes on, if it qualifies; returns what was done.
    Idempotent: a plan that already carries this version's triggers is left
    as it is; a toolkit with nothing to push is looked at again weekly."""
    now = time.time() if now is None else now
    plan = composio_items.load_plan(slug) or {}
    if plan.get("tool"):
        return {"slug": slug, "skip": "read on a clock"}
    held = plan.get("triggers")
    if isinstance(held, dict) and held.get("v") == TRIGGERS_VERSION and (
            held.get("on") or now - float(held.get("at") or 0) < RECHECK_S):
        return {"slug": slug, "skip": "already decided"}
    if tier() == "free":
        return {"slug": slug, "skip": "free tier"}

    def decided(on, why=None):
        plan["triggers"] = dict({"v": TRIGGERS_VERSION, "on": on, "at": now}, **({"why": why} if why else {}))
        composio_items._save_plan(slug, plan)
        return dict({"slug": slug, "on": [t["slug"] for t in on]}, **({"skip": why} if why else {}))

    # Who the triggers are for, before anything is spent: no identity, no
    # triggers — and not asked again for a week.
    try:
        uid = user_id or _composio().user_id(False)
    except Exception:  # noqa: BLE001 — composio.py raises NoIdentity and friends
        uid = None
    if not uid:
        return decided([], "no Composio identity on this Mac")
    types = trigger_types(slug, call=composio_call)
    if types is None:
        return {"slug": slug, "skip": "catalogue unreadable"}
    picked = choose(slug, types, model_call or composio_items.default_call)
    on = []
    for t in picked:
        tid = _upsert(t["slug"], uid, call=composio_call)
        if tid:
            on.append(dict(t, id=tid))
    if on:
        status, _ = (edge_call or _edge)("POST", "/v1/composio/triggers/enable", {})
        if status != 200:
            # No subscription, nowhere for events to go: undo, try next week.
            for t in on:
                _delete(t["id"], call=composio_call)
            on = []
    return decided(on)


def retire(slug: str, *, composio_call=None) -> List[str]:
    """Delete a toolkit's triggers (revoked, disconnected, or no longer
    paid). The edge's subscription stays for any other toolkit's; the edge
    drops events of a tenant that is no longer paid."""
    plan = composio_items.load_plan(slug) or {}
    held = plan.get("triggers") if isinstance(plan.get("triggers"), dict) else {}
    gone, left = [], []
    for t in held.get("on") or []:
        if t.get("id") and _delete(t["id"], call=composio_call):
            gone.append(t.get("slug"))
        else:
            left.append(t)          # still live at Composio: kept, retried next tick
    if held:
        plan["triggers"] = {"v": TRIGGERS_VERSION, "on": left, "at": time.time(), "retired": not left}
        composio_items._save_plan(slug, plan)
    return gone


EDGE_CHECK_FILE = "composio-triggers-edge.json"
EDGE_CHECK_S = 86400


def check_subscription(*, edge_call=None, now: Optional[float] = None) -> Optional[Dict[str, Any]]:
    """Once a day while any trigger is live: ask the edge to make sure the
    project's subscription is there (idempotent), and to repair it when it
    reports deliveries failing (a secret rotated elsewhere, a deleted
    subscription). None when not due."""
    now = time.time() if now is None else now
    path = os.path.join(moe_home(), "gather", EDGE_CHECK_FILE)
    try:
        with open(path, encoding="utf-8") as f:
            last = float((json.load(f) or {}).get("at") or 0)
    except (OSError, ValueError, AttributeError):
        last = 0.0
    if now - last < EDGE_CHECK_S:
        return None
    call = edge_call or _edge
    status, body = call("POST", "/v1/composio/triggers/enable", {})
    repaired = False
    if status == 200 and isinstance(body, dict) and body.get("failing"):
        status, body = call("POST", "/v1/composio/triggers/enable", {"repair": True})
        repaired = status == 200
    # A failed check is tried again in an hour, not every tick.
    composio_items._save(path, {"at": now if status == 200 else now - EDGE_CHECK_S + 3600})
    return {"status": status, "repaired": repaired}
