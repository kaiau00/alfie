"""A Mac that ran Alfie free before joining can still read what it wrote then.

CLOUD-PLAN §15.1, the read half. Swift's courier adopts the tenant's
`moe:memory` key and retires the one this Mac minted while it was free; these
pin the consequence on the side that actually reads memory — claimstore is the
Mac's memory provider, and the Swift claim code has no callers at all.

The split under test: **reads try every opening key, writes use only the
current one.** A retired key that could still seal would put new claims beyond
the reach of every other device in the tenant, which is this defect pointing
the other way.
"""

import base64
import json

import pytest

from claimstore.store import ClaimStore, open_text, parse_claim


CURRENT = bytes(range(32))
RETIRED = bytes(range(100, 132))
STRANGER = bytes(range(200, 232))


def _keyring(tmp_path, current, retired):
    """A thread-keys.json in the shape Swift's ThreadKeyring writes."""
    from moeledger.vault import Keyring

    path = tmp_path / "thread-keys.json"
    body = {
        "README": "x",
        "version": 1,
        "keys": {"moe:memory": base64.b64encode(current).decode()},
        "retired": {"moe:memory": [base64.b64encode(k).decode() for k in retired]},
    }
    path.write_text(json.dumps(body), encoding="utf-8")
    return Keyring(path)


def _seal(text, key):
    from claimstore.store import seal_text

    return seal_text(text, key)


def test_open_text_tries_every_key_and_current_first(tmp_path):
    sealed_old = _seal("the car is due in March", RETIRED)
    sealed_new = _seal("the dentist is on Tuesday", CURRENT)

    assert open_text(sealed_old, [CURRENT, RETIRED]) == "the car is due in March"
    assert open_text(sealed_new, [CURRENT, RETIRED]) == "the dentist is on Tuesday"
    # A single key still works exactly as it did — every existing caller.
    assert open_text(sealed_new, CURRENT) == "the dentist is on Tuesday"
    assert open_text(sealed_old, CURRENT) is None


def test_a_wrong_key_never_produces_plausible_text(tmp_path):
    """Trying several keys is only safe because GCM authenticates: a wrong key
    yields nothing rather than nonsense, so this cannot return the wrong text.
    """
    sealed = _seal("the dentist is on Tuesday", CURRENT)
    assert open_text(sealed, [STRANGER]) is None
    assert open_text(sealed, [STRANGER, CURRENT]) == "the dentist is on Tuesday"


def test_the_store_reads_a_claim_sealed_under_a_retired_key(tmp_path):
    """The §15.1 case end to end on the reading side."""
    keyring = _keyring(tmp_path, CURRENT, [RETIRED])
    store = ClaimStore(directory=tmp_path / "ledger", device="mac-EXAMPLE0001",
                       keyring=keyring)
    assert store.opening_keys[0] == CURRENT, "the current key must be tried first"
    assert RETIRED in store.opening_keys
    assert store.key == CURRENT, "sealing must never reach for a retired key"

    record = {
        "kind": "claim",
        "id": "r1",
        "body": {"op": "assert", "claim": "c1", "target": "memory",
                 "text_enc": _seal("the car is due in March", RETIRED)},
    }
    claim = parse_claim(record, store.opening_keys)
    assert claim is not None
    assert claim["text"] == "the car is due in March"
    assert claim["readable"] is True

    # And with only the current key — what this did before §15.1 — it is
    # present but unreadable, which is the defect being fixed.
    stale = parse_claim(record, CURRENT)
    assert stale is not None and stale["text"] is None and stale["readable"] is False


def test_a_store_with_no_retired_history_is_unchanged(tmp_path):
    keyring = _keyring(tmp_path, CURRENT, [])
    store = ClaimStore(directory=tmp_path / "ledger", device="mac-EXAMPLE0001",
                       keyring=keyring)
    assert store.opening_keys == [CURRENT]


def test_a_store_with_no_keyring_still_reads_with_its_single_key(tmp_path):
    """A standalone reader or a test has no keyring, and must not now need one."""
    store = ClaimStore(directory=tmp_path / "ledger", device="mac-EXAMPLE0001",
                       key=CURRENT)
    assert store.opening_keys == [CURRENT]
    assert store.key == CURRENT


def test_the_stores_own_readers_use_the_retired_keys(tmp_path):
    """Through `resolve` and `claim_records`, not through `parse_claim`.

    The first version of this file tested `parse_claim(record, store.opening_keys)`
    — which is the layer BELOW the defect. Reverting the store's own two call
    sites from `opening_keys` back to `key` left all 130 tests green, so
    nothing pinned the thing that actually had to change. Same shape as
    CLOUD-PLAN §18.12b, where the bug that shipped had no test because every
    test called the layer under it.
    """
    ledger = tmp_path / "ledger"

    # While this Mac was free: its own key, no keyring, a fact remembered.
    free = ClaimStore(directory=ledger, device="mac-EXAMPLE0001", key=RETIRED)
    free.assert_claim("memory", "the car is due in March", source="user")
    assert free.live("memory") == ["the car is due in March"]

    # Then it joins a tenant: the courier adopts the tenant's key and retires
    # this one. Same ledger, same records, a keyring where both live.
    joined = ClaimStore(directory=ledger, device="mac-EXAMPLE0001",
                        keyring=_keyring(tmp_path, CURRENT, [RETIRED]))
    assert joined.key == CURRENT

    # THE POINT: the fact written while free is still remembered.
    assert joined.live("memory") == ["the car is due in March"]

    # `claim_records` is asserted too, but note what it can and cannot show:
    # it filters on `target`, which is in the clear, so its key argument
    # changes nothing observable and no mutation of that one call site fails a
    # test. Checked rather than assumed — reverting it alone leaves the suite
    # green. It is passed the opening keys for consistency and in case the
    # filter ever reads text; it is not load-bearing today, and saying so is
    # better than leaving a line that looks like it is.
    assert len(joined.claim_records("memory")) == 1

    # And a fact written now seals under the tenant's key, so every other
    # device can read it — the half a retired key must never be used for.
    joined.assert_claim("memory", "the dentist is on Tuesday", source="user")
    assert sorted(joined.live("memory")) == [
        "the car is due in March", "the dentist is on Tuesday"]

    # A device holding only the tenant's key sees the new fact and not the old
    # one — until something re-asserts it. This used to be recorded here as
    # "§15.1's accepted trade: the content converges through the document
    # path", and that sentence was wrong twice: `MEMORY.md` is not one of
    # `DOCUMENT_NAMES`, so no document ever carried it, and the retired key
    # itself never leaves this Mac. What closes it is `reassert_retired`, in
    # `test_retired_key_converges.py`; this file's job stops at the read.
    other = ClaimStore(directory=ledger, device="mac-EXAMPLE0001", key=CURRENT)
    assert other.live("memory") == ["the dentist is on Tuesday"]
