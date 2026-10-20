#!/usr/bin/env python3
"""The away machine's reader of Composio trigger events (docs/PROACTIVE-MEMORY.md
slice 7): `composio_events.py <slug> items --since <cursor>`.

Composio pushes a trigger's event to the edge, which seals it at once to this
tenant's cloud machine and keeps it only until collected
(`GET /v1/composio/events`, then `POST /v1/composio/events/ack`). This opens
the events of the triggers the Mac chose for `<slug>` (its read plan's
`triggers`, which travels here as the `situations/plan/<slug>` document),
reads each event's `data` with the one generic shape reader
(composio_items.extract), and prints them as the engine's items.

**Nothing is lost between collecting and keeping.** An event is acked only
on the NEXT look, from the ids the engine saved in the cursor after it wrote
the items down — a crash in between re-reads them, and the feed keeps one
copy by id. Events of other toolkits are left for their own reader.

Cloud only: the edge refuses a Mac, and the Mac never holds these.
"""

from __future__ import annotations

import base64
import json
import os
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import composio_items  # noqa: E402


def hermes_home() -> str:
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def _vault():
    """moeledger's vault for this machine: its identity (to open) and its
    credential (to ask the edge)."""
    lib = os.path.join(hermes_home(), "plugins", "moe-ledger")
    if lib not in sys.path:
        sys.path.insert(0, lib)
    from moeledger.vault import Vault
    return Vault(os.path.join(hermes_home(), "moe"))


def _edge_call(method: str, path: str, body: Optional[Dict[str, Any]] = None) -> Tuple[int, Any]:
    import urllib.error
    import urllib.request
    v = _vault()
    cred = v.credential() or {}
    base = (os.environ.get("MOE_EDGE_URL") or v.edge_url() or "").rstrip("/")
    token = cred.get("token")
    if not base or not token:
        return 0, {}
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers=dict({"Authorization": "Bearer " + token},
                                              **({"Content-Type": "application/json"} if data else {})))
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, {}
    except (urllib.error.URLError, OSError, ValueError):
        return 0, {}


def _open(ev: Dict[str, Any], me) -> Optional[Dict[str, Any]]:
    lib = os.path.join(hermes_home(), "plugins", "moe-ledger")
    if lib not in sys.path:
        sys.path.insert(0, lib)
    from moeledger.inbound import open_inbound
    text = open_inbound(base64.b64decode(ev["ciphertext"]),
                        ephemeral_public=base64.b64decode(ev["ephemeralPublic"]),
                        # Pinned, never taken from the response: only a Composio
                        # event sealed to this machine is opened as one.
                        channel="composio", message_id=ev["messageId"], to_device=me.device_id,
                        me=me, scheme=ev.get("scheme") or "x25519-hkdf-sha256.aes-gcm-256.inbound.v1")
    obj = json.loads(text)
    return obj if isinstance(obj, dict) else None


MAX_PAGES = 10
#: The edge acknowledges at most this many ids a request.
ACK_BATCH = 500
#: At most this many events are taken a look; the rest wait for the next.
MAX_TAKEN = 500


def items(slug: str, raw_cursor: str, *, edge=None, opener=None, now: Optional[float] = None
          ) -> Tuple[List[Dict[str, Any]], str]:
    """(items, new cursor). The cursor is {"ack": [edge ids to delete]}."""
    now = time.time() if now is None else now
    edge = edge or _edge_call
    try:
        cursor = json.loads(raw_cursor) if raw_cursor.strip() else {}
    except ValueError:
        cursor = {}
    pending_ack = [i for i in (cursor.get("ack") or []) if isinstance(i, (int, str))]
    # In the edge's batches (MAX_ACK 500): one oversized ack was refused, and
    # the same cursor was then sent again on every tick, for good.
    for i in range(0, len(pending_ack), ACK_BATCH):
        status, _ = edge("POST", "/v1/composio/events/ack", {"ids": pending_ack[i:i + ACK_BATCH]})
        if status != 200:
            raise RuntimeError("could not acknowledge events (%s)" % status)
    plan = composio_items.load_plan(slug) or {}
    held = plan.get("triggers") if isinstance(plan.get("triggers"), dict) else {}
    mine = {t.get("slug"): t for t in held.get("on") or [] if isinstance(t, dict)}
    if not mine:
        return [], json.dumps({"ack": []})
    if opener is None:
        me = _vault().identity(create=False)
        if me is None:
            raise RuntimeError("this machine has no device identity")
        opener = lambda ev: _open(ev, me)  # noqa: E731
    owners = plan.get("owner_ids") if isinstance(plan.get("owner_ids"), list) else []
    out, ack, after = [], [], 0
    events: List[Dict[str, Any]] = []
    # Paged: events another toolkit's reader has not taken yet must never
    # hide this toolkit's behind them.
    for _ in range(MAX_PAGES):
        status, body = edge("GET", "/v1/composio/events" + ("?after=%d" % after if after else ""))
        if status != 200 or not isinstance(body, dict):
            raise RuntimeError("could not collect events (%s)" % status)
        page = body.get("events") or []
        events.extend(page)
        nxt = body.get("next")
        if not page or not isinstance(nxt, int) or nxt <= after:
            break
        after = nxt
    for ev in events:
        if len(ack) >= MAX_TAKEN:
            break
        try:
            event = opener(ev)
        except Exception as e:  # noqa: BLE001 — never openable here: cleared, not kept
            print("composio events: %s unreadable: %s" % (ev.get("id"), type(e).__name__), file=sys.stderr)
            ack.append(ev["id"])
            continue
        if not event:
            ack.append(ev["id"])
            continue
        trig = mine.get(event.get("trigger_slug"))
        if trig is None:
            # Another toolkit's, or one whose plan has not reached this
            # machine yet (the Mac just turned it on): left alone. Paging keeps
            # it from hiding anything, and the edge clears it after 24 h.
            continue
        ack.append(ev["id"])
        data = event.get("data")
        found = composio_items.extract(data if isinstance(data, (dict, list)) else {"data": data},
                                       owners, now, addressed=trig.get("addressed") is True)
        if not found and isinstance(data, dict):
            # One record: its own id and time where it has them, the event's
            # where it does not.
            rec = dict(data)
            rec.setdefault("id", event.get("id"))
            rec.setdefault("timestamp", event.get("timestamp"))
            found = composio_items.extract({"items": [rec]}, owners, now,
                                           addressed=trig.get("addressed") is True)
        for it in found:
            it.pop("seen_at", None)
            # One event, one item: its id is the event's, so a re-read is one copy.
            it["id"] = "%s/%s" % (event.get("trigger_slug"), it.get("id") or event.get("id"))
            out.append(it)
    out.sort(key=lambda it: it["at"])
    return out, json.dumps({"ack": ack})


def main(argv: List[str]) -> int:
    if len(argv) < 3 or argv[2] != "items":
        print("usage: composio_events.py <slug> items --since <cursor>", file=sys.stderr)
        return 2
    slug = argv[1]
    cursor = argv[argv.index("--since") + 1] if "--since" in argv and argv.index("--since") + 1 < len(argv) else ""
    try:
        got, new = items(slug, cursor)
    except Exception as e:  # noqa: BLE001 — the engine moves no cursor on a failed read
        print("composio events %s: %s: %s" % (slug, type(e).__name__, e), file=sys.stderr)
        return 1
    for it in got:
        print(json.dumps(it, ensure_ascii=False))
    print(json.dumps({"cursor": new}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
