"""Find ``moeledger`` — the library inside the sibling ``moe-ledger`` plugin.

A delivery that reached nobody has to be written down where the Mac will find
it, and that somewhere is the ledger (LEDGER-WIRE §16). The ledger's vault and
its record format live in ``moe-ledger``, one directory along under
``$HERMES_HOME/plugins/`` (or ``/opt/data/plugins/`` on a machine) — the same
arrangement ``claimstore``, ``moe-ledger`` and ``moe-connectors`` already have
with each other, and the same trick: neither plugin is on ``sys.path`` by
itself, so the one that needs the other puts it there.

**This is the boundary that keeps ``deliver.py`` stdlib-only.** That module's
own header says it *"must not depend on anything Hermes might drop"*, and the
ledger needs ``cryptography``. So the hold is injected into ``deliver()`` as a
callable and assembled here, where importing is allowed to fail.

Guarded, and the guard is the point rather than politeness. Without the
library there is nowhere to hold a message, and a runtime that cannot hold one
must **say so** — ``deliver()`` returns a failure and logs the reason — rather
than return the success that loses it. That is ``moe-connectors/_sibling.py``'s
own rule, which this is the second caller to need: §4.4, a capability that is
absent says so; it never pretends.
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path
from types import ModuleType
from typing import Optional

logger = logging.getLogger("moe-screen")

SIBLING_DIR = Path(__file__).resolve().parent.parent / "moe-ledger"

_cached: Optional[ModuleType] = None
_tried = False


def moeledger() -> Optional[ModuleType]:
    """The ``moeledger`` package, or None when it cannot be imported.

    An already-imported ``moeledger`` (the machine's memory provider loaded
    it, or a test did) is used as is, so a record written here and a record
    written by ``moe-ledger`` come out of one set of classes — which matters
    more here than anywhere: a ``say`` this plugin writes is read by that one.
    """
    global _cached, _tried
    if _cached is not None:
        return _cached
    if _tried:
        return None
    _tried = True
    try:
        import moeledger  # noqa: F401 — already importable

        _cached = sys.modules["moeledger"]
        return _cached
    except ImportError:
        pass
    if (SIBLING_DIR / "moeledger" / "__init__.py").exists():
        if str(SIBLING_DIR) not in sys.path:
            sys.path.append(str(SIBLING_DIR))   # append, never ahead of the stdlib
        try:
            import moeledger  # noqa: F811

            _cached = sys.modules["moeledger"]
            return _cached
        except ImportError:
            logger.warning("moe-screen: %s is there but moeledger does not import "
                           "(missing `cryptography`?); a delivery that reaches "
                           "nobody cannot be held", SIBLING_DIR, exc_info=True)
            return None
    logger.warning("moe-screen: no moe-ledger plugin beside this one at %s; a "
                   "delivery that reaches nobody cannot be held", SIBLING_DIR)
    return None


def forget() -> None:
    """Tests only: try the import again next time."""
    global _cached, _tried
    _cached = None
    _tried = False


__all__ = ["SIBLING_DIR", "forget", "moeledger"]
