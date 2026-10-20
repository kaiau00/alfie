"""The background engine's documents, carried when the engine runs — not
only at a session boundary (docs/PROACTIVE-MEMORY-STATUS.md #7; the owner,
2026-09-29: "within about five minutes, only when something changed").

What the situations tick writes — situations, promises, read positions —
and what reminder deliveries write (open, said, closed, calendar-said) are
documents that travel between the Mac and the cloud machine
(moeledger/documents.py `ENGINE_NAMES`). They used to be sealed only when a
chat session started or ended: on a Mac hours or days apart, on the machine
only when the owner next messaged it. So the tick itself now calls

    travel.receive()   at its start: apply what arrived from the other side
    travel.send()      at its end:   seal what changed, and push it now

On a Mac the claimstore plugin seals and the app pushes (the pull marker
CloudSync watches runs a pull and a push); on the machine the moe-ledger
provider seals and pushes itself, and the edge nudges the other side, which
pulls within a second. A document seals only when its bytes changed.

**Read positions** (`feed/cursors`) move on nearly every tick; they ride at
most every CURSOR_EVERY_S. The cost is at a hand-over: a Mac shut just
after a tick that skipped them leaves the machine up to fifteen minutes
behind, and it reads those messages again — its feed is its own, so they
reach its sensor again too. Bounded, and the price of not sealing a record
on every tick.

On the machine both are narrow: a receive pulls a few pages and applies the
engine's names only, never another applier.

Never raises. Stdlib only; the plugins are found beside Hermes.
"""

from __future__ import annotations

import json
import os
import sys
import time
from typing import Any, Dict, List, Optional

ENGINE_NAMES = ("proactive/situations", "proactive/promises", "feed/cursors", "proactive/open",
                "proactive/said", "proactive/closed", "proactive/calendar-said",
                "proactive/offer-state", "proactive/offer-feedback", "settings/background",
                "proactive/holds", "proactive/mentions")
CURSORS = "feed/cursors"
CURSOR_EVERY_S = 15 * 60


def moe_home() -> str:
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def hermes_home() -> str:
    for d in (os.environ.get("HERMES_HOME", ""), "/opt/data", os.path.expanduser("~/.hermes")):
        if d and os.path.isdir(os.path.join(d, "plugins")):
            return d
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def on_mac() -> bool:
    return (os.environ.get("MOE_RUNS_IN") or ("mac" if sys.platform == "darwin" else "cloud")) == "mac"


def _state_path() -> str:
    return os.path.join(moe_home(), "feed", "travel.json")


def _read_state() -> Dict[str, Any]:
    try:
        with open(_state_path(), encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_state(data: Dict[str, Any]) -> None:
    path = _state_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = "%s.%d.tmp" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except OSError:
        pass


def names_to_send(now: Optional[float] = None, state: Optional[Dict[str, Any]] = None) -> List[str]:
    """Every engine name, the read positions only every CURSOR_EVERY_S."""
    now = time.time() if now is None else now
    state = _read_state() if state is None else state
    last = float(state.get("cursors_at") or 0)
    return [n for n in ENGINE_NAMES if n != CURSORS or now - last >= CURSOR_EVERY_S]


_BACKEND: List[Any] = []


def _plugins_on_path() -> None:
    plugins = os.path.join(hermes_home(), "plugins")
    if plugins not in sys.path:
        sys.path.insert(0, plugins)


def backend():
    """(kind, callable(names, receive, send) -> dict), once per process."""
    if _BACKEND:
        return _BACKEND[0]
    _plugins_on_path()
    if on_mac():
        import claimstore  # noqa: WPS433 — the Mac's memory provider package

        def run(names, receive, send):
            return claimstore.travel(list(names), receive=receive, send=send)
        found = ("mac", run)
    else:
        provider = _load_moe_ledger().MoeLedgerProvider()

        def run(names, receive, send):
            return provider.travel(list(names), receive=receive, send=send)
        found = ("machine", run)
    _BACKEND.append(found)
    return found


def _load_moe_ledger():
    """The moe-ledger plugin package (its directory name has a hyphen, so it
    is loaded by path, the way the gateway hook loads it)."""
    import importlib.util
    root = os.path.join(hermes_home(), "plugins", "moe-ledger")
    # `moeledger` (the library) is a top-level import inside the plugin.
    if root not in sys.path:
        sys.path.append(root)
    name = "moe_ledger_for_travel"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, os.path.join(root, "__init__.py"),
                                                  submodule_search_locations=[root])
    mod = importlib.util.module_from_spec(spec)
    mod.__package__ = name
    mod.__path__ = [root]
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def receive(runner=None) -> Dict[str, Any]:
    """Apply what the other side sent. Never raises."""
    try:
        run = runner or backend()[1]
        return run(ENGINE_NAMES, True, False) or {}
    except Exception as e:  # noqa: BLE001
        return {"error": "%s: %s" % (type(e).__name__, e)}


def send(runner=None, now: Optional[float] = None) -> Dict[str, Any]:
    """Seal what changed and push it now. Never raises."""
    now = time.time() if now is None else now
    try:
        state = _read_state()
        names = names_to_send(now, state)
        run = runner or backend()[1]
        out = run(names, False, True) or {}
        if CURSORS in names and not out.get("error"):
            state["cursors_at"] = now
            _write_state(state)
        return out
    except Exception as e:  # noqa: BLE001
        return {"error": "%s: %s" % (type(e).__name__, e)}
