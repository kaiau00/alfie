"""The cloud picks up an ask the Mac left open — docs/AWAY-HANDOFF.md slice 3.

The edge, once the Mac has been gone longer than the grace, sends the ask to
this machine as an inbound message on the person's chat: a marker,
``[moe-task <id>]``, and a sentence for a model that meets it with no plugin.
The edge never holds the words; they are here, in the ``task/inflight``
document the Mac sealed at turn start and this machine applied to
``$MOE_HOME/turns/inflight.json`` (``moeledger.documents.NAME_ASK``).

One hook, stdlib, refusing to break a turn:

* ``pre_gateway_dispatch`` — the one seam Hermes offers that can REPLACE an
  inbound message's text (``gateway/run_inbound.py``, ``{"action":
  "rewrite"}``). A marker whose task matches the file becomes the person's
  own words behind a note saying why the model is seeing them here; a
  marker whose task the file does not know becomes a note saying the ask
  did not arrive, so the model never guesses at somebody else's request.
  The marker itself is kept at the head, which is how the second hook
  recognises the turn.
* The done report is NOT here. ``post_llm_call`` never fires under the
  claude-code runtime (``agent/claude_code_runtime.py`` finishes a turn
  without it), which is the brain the machine runs; the one turn-end seam
  that does fire there is the memory provider's ``sync_turn``, so
  ``moe-ledger`` reports ``/v1/task/done`` from there, finding the same
  marker at the head of a line of the user's turn.
"""
from __future__ import annotations

import json
import logging
import os
import re
from typing import Any, Dict, Optional

logger = logging.getLogger("moe-screen.tasks")

#: At the head of a LINE, not of the text: the gateway may put a nudge note
#: and "[New message]" in front of what arrived (`gateway/run_inbound.py`).
MARKER = re.compile(r"(?m)^\s*\[moe-task ([A-Za-z0-9._:-]{1,80})\]")
#: The edge sends the marker under a message id of this shape
#: (`app.py task_dispatch`, `channel_message_id="task:<id>"`); a Telegram
#: id is a number. So the marker is honoured only on a message the EDGE
#: minted, and anybody who can type into a bound chat cannot make Moe say
#: "your Mac closed mid-request" in the person's voice.
MESSAGE_ID_PREFIX = "task:"
ASK_FILE = os.path.join("turns", "inflight.json")

NOTE = (
    "[moe-task {task}] The person asked their Mac for this and the Mac closed "
    "while it was being worked on; you are picking it up here. First tell them, "
    "in one line, that their Mac closed and you are carrying on from here. Then "
    "do what they asked and answer as you normally would. Their words:\n\n{words}"
)
MISSING = (
    "[moe-task {task}] The person asked their Mac for something and the Mac closed "
    "while it was being worked on, but the request itself did not reach this "
    "machine. Tell them, in one line, that their Mac closed mid-request and you "
    "could not pick it up here, and ask them to say it again."
)


def moe_home() -> str:
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def hermes_home() -> str:
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def read_ask(home: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """The applied `task/inflight` document, or None."""
    path = os.path.join(home or moe_home(), ASK_FILE)
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) else None


def marker_task(text: Any) -> Optional[str]:
    """The task id when a line of `text` opens with the marker, else None."""
    if not isinstance(text, str):
        return None
    m = MARKER.search(text)
    return m.group(1) if m else None


def edge_minted(event: Any) -> bool:
    """Whether this message's id says the edge's task sweep sent it."""
    mid = getattr(event, "message_id", None)
    return isinstance(mid, str) and mid.startswith(MESSAGE_ID_PREFIX)


def rewrite(text: Any, ask: Optional[Dict[str, Any]]) -> Optional[str]:
    """What the model should see instead of `text`, or None to leave it."""
    task = marker_task(text)
    if task is None:
        return None
    if ask and str(ask.get("task") or "") == task:
        words = ask.get("words") or ask.get("text") or ""
        if isinstance(words, str) and words.strip():
            return NOTE.format(task=task, words=words.strip())
    return MISSING.format(task=task)


def on_inbound(event=None, gateway=None, session_store=None, **kwargs):
    """`pre_gateway_dispatch`. Returns the rewrite, or None."""
    try:
        if event is None or not edge_minted(event):
            return None
        new = rewrite(getattr(event, "text", None), read_ask())
        if new is None:
            return None
        logger.info("tasks: an ask the Mac left open arrived; the model gets the person's words")
        return {"action": "rewrite", "text": new}
    except Exception:  # noqa: BLE001 — nothing here may break dispatch
        logger.warning("tasks: could not look at an inbound message", exc_info=True)
        return None
