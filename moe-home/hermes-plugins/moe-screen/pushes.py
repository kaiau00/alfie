"""The other side pushed — the Mac's gateway tells the app. Slice E1.

The edge writes a ``ledger_moved`` frame down every other live relay socket of
a tenant after a push stores anything (the edge's relay). On a Mac
that socket is the **gateway's**, not the app's — Memoe.app holds no relay
socket — and the app is the Mac's ledger client (``CloudSync``). So the frame
has to cross from one process to the other, and the crossing is one file:
``$MOE_HOME/cloud/pull-requested``, which the app watches
(``PullNudge`` in the closed cloud half) and pulls within a second of.

**Why this lives in moe-screen and not moe-ledger.** ``moeledger/nudge.py``
already knows how to install the handler and leave the marker, and
``moe-ledger``'s ``register()`` calls it — but on a Mac that ``register()``
never runs. The fork's general plugin loader classifies a module that
mentions ``MemoryProvider`` as ``exclusive`` and leaves it to the memory
system (``hermes_cli/plugins.py`` ``_detect_kind_from_source``), and the
memory system loads only the *active* provider — on a Mac that is claimstore;
moe-ledger is installed there as a library, absent from ``plugins.enabled``
(``configure-hermes.py`` ``LEDGER_PLUGIN``). So the Mac half as first written
reached nothing. moe-screen is the plugin that IS loaded by every Mac
gateway, at start, before a frame can arrive, and it is already the seam
between the gateway and the app (the delivery spool). The rule itself stays
in ``moeledger.nudge`` — this module only chooses when to call it.

**Never on the machine.** There the ledger client is moe-ledger itself, and
its handler pulls; installing this one would replace it (the table has one
entry per type) with a marker no process reads.
"""

from __future__ import annotations

import logging
from typing import Any, Callable, Optional

from . import _sibling
from . import deliver as _deliver

logger = logging.getLogger(__name__)


def handler(moe_home: Callable[[], str], nudge: Any) -> Callable[[dict], None]:
    """What a ``ledger_moved`` frame does on a Mac: leave the marker. Nothing
    else — no pull, no network: the app is the client."""

    def _on_moved(frame: dict) -> None:
        path = nudge.leave_marker(moe_home(), nudge.high_water_of(frame))
        if path is not None:
            logger.info("moe-screen: the other side pushed; left %s for the app", path.name)

    return _on_moved


def _transport_class() -> Optional[Any]:
    try:
        from gateway.relay.ws_transport import WebSocketRelayTransport
    except Exception:  # noqa: BLE001 - no relay in this gateway: nothing to listen on
        return None
    return WebSocketRelayTransport


def listen(transport_class: Any = None) -> bool:
    """Install the Mac's handler on the relay transport. Returns whether it
    did. Every refusal is a log line and False; the five-minute pull is the
    backstop for all of them."""
    ledger = _sibling.moeledger()
    if ledger is None:
        return False
    try:
        from moeledger import capability, nudge
    except Exception:  # noqa: BLE001
        logger.info("moe-screen: moeledger has no nudge module; pushes from the other side "
                    "are noticed by the app's scheduled pull")
        return False
    if capability.runtime() == capability.RUNS_IN_CLOUD:
        return False
    if transport_class is None:
        transport_class = _transport_class()
    if transport_class is None:
        logger.debug("moe-screen: no relay transport; pushes from the other side are noticed "
                     "by the app's scheduled pull")
        return False
    if nudge.install(transport_class, handler(_deliver.moe_home, nudge)):
        logger.info("moe-screen: listening for the other side's pushes on the relay")
        return True
    return False


__all__ = ["handler", "listen"]
