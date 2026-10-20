"""The hold: a delivery that reached nobody, written down where the Mac
will find it (LEDGER-WIRE §16, CLOUD-PLAN §6 item 7).

`deliver()` is stdlib-only by contract and the ledger is not, so this is the
piece between them. It is a *factory*: `holder()` returns the callable
`deliver(..., hold=…)` takes, or None when there is nowhere to hold anything —
and None is a real answer that `deliver()` reports as a failed delivery rather
than swallowing.

**Nothing in here is about cron, or reminders, or the island.** It answers one
question — *can this sentence be written down, and where* — and every reason
it might not be is a separate, logged sentence, because "held" and "lost" must
never look the same from outside. That symmetry is the whole point: `deliver()`
used to answer both with `(True, "")`.
"""

from __future__ import annotations

import logging
import os
from typing import Any, Callable, Optional

from . import _sibling

logger = logging.getLogger("moe-screen")


def hermes_home() -> str:
    return os.path.expanduser(os.environ.get("HERMES_HOME") or "~/.hermes")


def vault_root() -> str:
    """``<HERMES_HOME>/moe`` — where ``moe-ledger`` keeps this device's
    identity, keyring, sessions and ledger files. The same spelling
    ``moe-connectors.vault_root`` uses, and for the same reason: two answers
    to "where is the vault" is two vaults."""
    return os.path.join(hermes_home(), "moe")


def holder(root: Optional[str] = None) -> Optional[Callable[..., bool]]:
    """A `hold` for `deliver()`, or None when this runtime cannot hold.

    None — never an exception, and never a callable that quietly does
    nothing — for each of: no ledger library beside this plugin, a vault that
    will not open, a device that was never enrolled, and a machine that has no
    conversation to speak into. Each is logged where it is found, with the
    path or the reason, because the person will never see any of them and the
    log is the only place the message's existence is recorded.
    """
    lib = _sibling.moeledger()
    if lib is None:
        return None                      # _sibling has already said why
    try:
        from moeledger.says import (RUNTIME_MAC, append_say, choose_thread)
        from moeledger.sync import LocalLedger
        from moeledger.vault import Vault
    except Exception:
        logger.warning("moe-screen: the ledger library is there but will not import; "
                       "a delivery that reaches nobody cannot be held", exc_info=True)
        return None

    where = root or vault_root()
    try:
        vault = Vault(where)
        identity = vault.identity(create=False)
    except Exception:
        logger.warning("moe-screen: could not open the vault at %s; a delivery that "
                       "reaches nobody cannot be held", where, exc_info=True)
        return None
    if identity is None:
        # Never enrolled: no chain to append to and no peer to read it. On a
        # free Mac this is the ordinary state and is not an error — but a free
        # Mac has a screen, so it never reaches this code at all.
        logger.info("moe-screen: no device identity at %s; a delivery that reaches "
                    "nobody cannot be held", where)
        return None

    def hold(text: str, source: str = "", job: str = "",
             reason: str = "no-channels") -> bool:
        """Write one `say`. True only when the record is on the chain.

        Every failure returns False rather than raising: `deliver()` turns
        False into a failed delivery with a reason, and an exception crossing
        this boundary would instead take out the whole send.
        """
        try:
            records = list(vault.read_ledger())
        except Exception:
            logger.warning("moe-screen: could not read the ledger to choose a "
                           "conversation; not held", exc_info=True)
            return False
        # `Vault.key` raises `VaultError` on an unreadable `thread-keys.json`,
        # so neither of these is the total function it looks like. Unguarded,
        # the exception escaped into `deliver._hold`'s catch-all — contained,
        # but the specific log line below (the one naming what went wrong)
        # never fired, and the caller saw the exception's words instead. This
        # module's own docstring promises "every failure returns False rather
        # than raising"; it now does.
        try:
            thread = choose_thread(records, lambda t: vault.key(t) is not None)
        except Exception:
            logger.warning("moe-screen: could not read this device's thread keys to "
                           "choose a conversation; not held", exc_info=True)
            return False
        if not thread:
            logger.warning("moe-screen: this device holds no conversation to hold a "
                           "message in; not held")
            return False
        try:
            key = vault.key(thread)
        except Exception:
            logger.warning("moe-screen: could not read the chosen conversation's key; "
                           "not held", exc_info=True)
            return False
        if key is None:
            # choose_thread only offers threads whose key resolved, so this is
            # a race with a `thread.delete` between the two reads rather than a
            # logic hole. Reported rather than retried: the message is one
            # sentence and the next tick is minutes away.
            logger.warning("moe-screen: the chosen conversation's key went away; not held")
            return False
        try:
            # `runtime=mac`: a say is addressed to the runtime with a screen,
            # and this is the machine writing FOR the Mac. It is not a note to
            # self — a machine draining its own says would speak them into a
            # void, which is the failure this whole path exists to close.
            record = append_say(
                LocalLedger(vault, identity.device_id),
                thread=thread, runtime=RUNTIME_MAC, reason=reason, key=key,
                text=text, source=source, job=job)
        except Exception:
            logger.warning("moe-screen: could not append the say; not held", exc_info=True)
            return False
        # The id and the reason, never the sentence. This log is on Fly, in
        # the clear, and the text is sealed precisely so it is not.
        logger.info("moe-screen: reached nobody (%s) — held as say %s in %s",
                    reason, record.id, thread)
        return True

    return hold


__all__ = ["hermes_home", "holder", "vault_root"]
