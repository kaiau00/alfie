"""The learner: what the person did with Moe's offers, turned into how sure
Moe is that they want help next time (docs/PROACTIVE-MEMORY.md §4.9).

Zero labour: the signals are what the person does anyway, written by the
island (`SituationOffer.record`) to `~/.moe/proactive/offer-feedback.jsonl`
as `{at, id, action}` — `used` (the draft was sent, the send confirmed),
`chose-to-send` (asked Moe to send it, through the brain and the send gate,
where whether it went is not observable here), `opened` (looked at it),
`not-now`, `not-this-kind`, and `handled` (Done: they dealt with it another
way — neither a yes nor a no, so it weighs nothing).

Each situation's `p_wanted` (the sensor's own guess) is the prior; the
person's answers to earlier offers move it, per KIND of situation (the
sensor's free-text `kind`, folded) and per conversation (the thread). A Beta
posterior, with the sensor's guess worth `PRIOR_WEIGHT` answers:

    a = PRIOR_WEIGHT·p + Σ yes-weights        b = PRIOR_WEIGHT·(1−p) + Σ no-weights
    p′ = a / (a + b)

"Not this kind of thing" is the strongest no there is, and also silences the
kind outright for `SILENCE_DAYS` — a person who said it should not have to
say it twice. Nothing here names a kind or a person: it is all their own
history.

Stdlib only; pure functions over the two files.
"""

from __future__ import annotations

import json
import os
import re
import time
from typing import Any, Dict, Iterable, List, Optional

PRIOR_WEIGHT = 2.0
SILENCE_DAYS = 30
WEIGHTS = {            # (yes, no)
    "used": (1.0, 0.0),            # the draft went (the send was confirmed)
    "chose-to-send": (0.8, 0.0),   # asked Moe to send it; whether it went is the gate's
    "opened": (0.4, 0.0),
    "not-now": (0.0, 0.5),
    "not-this-kind": (0.0, 3.0),
    "handled": (0.0, 0.0),         # Done: dealt with another way, not "not wanted"
}


def moe_home() -> str:
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def feedback_path() -> str:
    return os.path.join(moe_home(), "proactive", "offer-feedback.jsonl")


def kind_key(kind: Any) -> str:
    """The sensor's free-text kind, folded, so "Payment dispute" and
    "payment disputes" are one kind."""
    words = re.findall(r"[a-z]+", str(kind or "").lower())
    words = [w[:-1] if len(w) > 4 and w.endswith("s") else w for w in words][:4]
    return " ".join(words)


def read_feedback(path: Optional[str] = None, limit: int = 2000) -> List[Dict[str, Any]]:
    out = []
    try:
        with open(path or feedback_path(), encoding="utf-8") as f:
            lines = f.read().splitlines()[-limit:]
    except OSError:
        return []
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("id") and row.get("action") in WEIGHTS:
            out.append(row)
    return out


def adjusted(sit: Dict[str, Any], situations: Dict[str, Any],
             feedback: Iterable[Dict[str, Any]], now: Optional[float] = None) -> float:
    """How sure Moe is, after the person's own history, that they want help
    with this situation. 0 when they said "not this kind of thing" lately."""
    now = time.time() if now is None else now
    try:
        p = min(1.0, max(0.0, float(sit.get("p_wanted") or 0)))
    except (TypeError, ValueError):
        p = 0.0
    kind = kind_key(sit.get("kind"))
    thread = (sit.get("source"), sit.get("thread"))
    a = PRIOR_WEIGHT * p
    b = PRIOR_WEIGHT * (1.0 - p)
    for row in feedback:
        other = situations.get(row.get("id")) or {}
        same_kind = bool(kind) and kind_key(other.get("kind")) == kind
        same_thread = (other.get("source"), other.get("thread")) == thread and thread[1]
        if not (same_kind or same_thread):
            continue
        action = row["action"]
        if action == "not-this-kind" and same_kind:
            try:
                if now - float(row.get("at") or 0) < SILENCE_DAYS * 86400:
                    return 0.0
            except (TypeError, ValueError):
                pass
        yes, no = WEIGHTS[action]
        a += yes
        b += no
    return round(a / (a + b), 3) if a + b > 0 else p
