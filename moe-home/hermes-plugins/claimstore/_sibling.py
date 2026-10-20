"""Find ``moeledger`` — the library inside the sibling ``moe-ledger`` plugin.

Both plugins ship side by side under ``$HERMES_HOME/plugins/`` (or
``/opt/data/plugins/`` on a machine), and each needs a piece of the other
(CLOUD-PLAN §11.1): this one needs ``moeledger``'s keyring, field sealing and
``document`` rules; ``moe-ledger`` needs this one's ``store`` and
``projection``. Neither is on ``sys.path`` by itself, so each puts the other
there. Guarded: a Mac without the sibling still has a working (plaintext,
local-only) memory store, and says so.
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path
from types import ModuleType
from typing import Optional

logger = logging.getLogger(__name__)

SIBLING_DIR = Path(__file__).resolve().parent.parent / "moe-ledger"

_cached: Optional[ModuleType] = None
_tried = False


def moeledger() -> Optional[ModuleType]:
    """The ``moeledger`` package, or None when it cannot be imported.

    An already-imported ``moeledger`` (the machine's provider loaded it, or a
    test did) is used as is, so both plugins share one set of classes.
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
            sys.path.append(str(SIBLING_DIR))  # append, as moe-ledger does; never ahead of the stdlib
        try:
            import moeledger  # noqa: F811

            _cached = sys.modules["moeledger"]
            return _cached
        except ImportError:
            logger.warning("claimstore: %s is there but moeledger does not import "
                           "(missing `cryptography`?); claims stay plaintext and local",
                           SIBLING_DIR, exc_info=True)
            return None
    logger.warning("claimstore: no moe-ledger plugin beside this one at %s; claims stay "
                   "plaintext and local until it is installed", SIBLING_DIR)
    return None


__all__ = ["SIBLING_DIR", "moeledger"]
