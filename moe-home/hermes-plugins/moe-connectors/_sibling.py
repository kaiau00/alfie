"""Find ``moeledger`` — the library inside the sibling ``moe-ledger`` plugin.

A detached connector's tool call has to be written down somewhere both
devices can read it, and that somewhere is the ledger (LEDGER-WIRE §14).
The ledger's vault and its record format live in ``moe-ledger``, one
directory along under ``$HERMES_HOME/plugins/`` (or ``/opt/data/plugins/`` on
a machine) — the same arrangement ``claimstore`` and ``moe-ledger`` already
have with each other, and the same trick: neither plugin is on ``sys.path``
by itself, so the one that needs the other puts it there.

Guarded, and the guard matters more here than in the memory plugins. Without
the library there is no queue, and a connector that cannot queue must say so
(``moe-connectors`` does, in one sentence) rather than answer "I'll do it when
your Mac wakes" about a record nobody wrote. §4.4: a capability that is absent
says so; it never pretends.
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path
from types import ModuleType
from typing import Optional

logger = logging.getLogger("moe-connectors")

SIBLING_DIR = Path(__file__).resolve().parent.parent / "moe-ledger"

_cached: Optional[ModuleType] = None
_tried = False


def moeledger() -> Optional[ModuleType]:
    """The ``moeledger`` package, or None when it cannot be imported.

    An already-imported ``moeledger`` (the machine's memory provider loaded
    it, or a test did) is used as is, so a record written here and a record
    written by ``moe-ledger`` come out of one set of classes.
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
            logger.warning("moe-connectors: %s is there but moeledger does not import "
                           "(missing `cryptography`?); a detached connector cannot queue",
                           SIBLING_DIR, exc_info=True)
            return None
    logger.warning("moe-connectors: no moe-ledger plugin beside this one at %s; a detached "
                   "connector cannot queue anything", SIBLING_DIR)
    return None


def forget() -> None:
    """Tests only: try the import again next time."""
    global _cached, _tried
    _cached = None
    _tried = False


__all__ = ["SIBLING_DIR", "forget", "moeledger"]
