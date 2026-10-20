"""The reading half of CLOUD-PLAN §15.1, against the shared vectors.

``Tests/vectors/retired-keys.json`` is generated from the Swift
(``Tests/MoeLedgerTests/RetiredKeyVectorTests.swift``) and read here, in
``moe-ledger/tests/test_retired_key_vectors.py``, and by the Swift itself.
This is the side that matters most on a real Mac: claimstore is the Mac's
memory provider, and the Swift claim code has no callers at all.

``test_retired_key_reads.py`` next door drives the same rule through stores
this suite builds for itself. What this one adds is that the keyring it reads
is **the Swift's own file, byte for byte**, and the ciphertext it opens was
sealed by the Swift under the key the Swift retired. Two implementations
agreeing about a fixture they each invented is what a conformance file exists
to stop.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path

import pytest

from claimstore.store import ClaimStore, open_text, parse_claim

MEMORY = "moe:memory"
VECTORS_PATH = Path(__file__).resolve().parents[4] / "Tests" / "vectors" / "retired-keys.json"


def _names(section):
    """The vector names, read at collection time so each is its own test."""
    try:
        return [v["name"] for v in
                json.loads(VECTORS_PATH.read_text(encoding="utf-8"))[section]]
    except (OSError, ValueError, KeyError, TypeError):
        return ["(vectors missing)"]


@pytest.fixture(scope="module")
def corpus():
    if not VECTORS_PATH.exists():
        pytest.skip("Tests/vectors/retired-keys.json is not present (it is generated from "
                    "the Swift by RetiredKeyVectorTests)")
    return json.loads(VECTORS_PATH.read_text(encoding="utf-8"))


def _raw(encoded):
    return base64.b64decode(encoded, validate=True)


def _store(tmp_path, vector):
    """A ClaimStore reading the vector's keyring, byte for byte off disk."""
    from moeledger.vault import Keyring

    path = tmp_path / (vector["name"] + ".json")
    path.write_text(vector["text"], encoding="utf-8")
    return ClaimStore(directory=tmp_path / "ledger", device="mac-EXAMPLE0001",
                      keyring=Keyring(path))


def _sealed(vector):
    return {sample["under"]: sample for sample in vector["sealed"]}


@pytest.fixture(scope="module")
def joined(corpus):
    """The §15.1 vector itself: a Mac that ran free and then joined a tenant."""
    return next(v for v in corpus["written"] if v["name"] == "a-free-mac-that-joined-a-tenant")


def test_the_corpus_is_where_all_three_suites_expect_it(corpus, joined):
    assert len(corpus["written"]) >= 5
    assert len(joined["sealed"]) >= 2, "the sealed samples are gone and nothing opens anything"


@pytest.mark.parametrize("name", _names("written"))
def test_the_stores_opening_keys_are_the_vectors(corpus, tmp_path, name):
    """What the store's own ``resolve`` and ``claim_records`` are handed.

    ``opening_keys`` is what reads and ``key`` is what seals, and keeping them
    apart is the whole safety property: a retired key that could still seal
    would put new claims beyond the reach of every other device in the tenant.
    """
    vector = next(v for v in corpus["written"] if v["name"] == name)
    expect = vector["expect"][MEMORY]
    store = _store(tmp_path, vector)
    assert [base64.b64encode(k).decode() for k in store.opening_keys] == expect["opening"]
    assert base64.b64encode(store.key).decode() == expect["sealing"]
    assert store.opening_keys[0] == store.key, \
        "the key that seals must be the first one tried"


def test_the_store_opens_what_the_swift_sealed_under_a_retired_key(joined, tmp_path):
    """The point of the whole slice, on one artefact and across two languages.

    The ciphertext here was produced by CryptoKit, under the key this Mac
    minted while it ran free — the key the courier then retired. If this ever
    fails, the fact a person told their Mac before they subscribed is still on
    the chain and can no longer be read.
    """
    store = _store(tmp_path, joined)
    samples = _sealed(joined)

    for sample in samples.values():
        assert open_text(sample["combined"], store.opening_keys) == sample["text"], sample["under"]

    # And the store's own reader path, not just the function under it: a
    # record carrying that ciphertext resolves to the text a person said.
    record = {"kind": "claim", "id": "r1",
              "body": {"op": "assert", "claim": "c1", "target": "memory",
                       "text_enc": samples["retired"]["combined"]}}
    claim = parse_claim(record, store.opening_keys)
    assert claim is not None and claim["readable"] is True
    assert claim["text"] == samples["retired"]["text"]


def test_a_retired_key_is_never_the_one_sealing_uses(joined, tmp_path):
    """The defect this fixes, pointing the other way.

    ``key`` is the current key alone, so what the retired key sealed does not
    open under it — which is exactly what a device that never ran free sees,
    and why §15.1 carries the content to the tenant as documents rather than
    re-sealing a signed record.
    """
    store = _store(tmp_path, joined)
    samples = _sealed(joined)
    assert open_text(samples["retired"]["combined"], store.key) is None
    assert open_text(samples["current"]["combined"], store.key) == samples["current"]["text"]

    # Read with only the current key — what this did before §15.1 — the claim
    # is present and unreadable, which is worse than missing and was silent.
    record = {"kind": "claim", "id": "r1",
              "body": {"op": "assert", "claim": "c1", "target": "memory",
                       "text_enc": samples["retired"]["combined"]}}
    stale = parse_claim(record, store.key)
    assert stale is not None and stale["text"] is None and stale["readable"] is False


def test_a_wrong_key_yields_nothing_rather_than_nonsense(joined, tmp_path):
    """Why trying several keys is allowed to exist at all.

    GCM authenticates, so a key that is not the right one produces no
    plaintext rather than plausible text. Without that, reading under several
    keys could hand somebody another conversation's words.
    """
    samples = _sealed(joined)
    retired = _raw(json.loads(joined["text"])["retired"][MEMORY][0])
    stranger = bytes(range(200, 232))
    assert open_text(samples["retired"]["combined"], [stranger]) is None
    assert open_text(samples["retired"]["combined"], [stranger, retired]) == \
        samples["retired"]["text"]


@pytest.mark.parametrize("name", _names("refused"))
def test_a_keyring_the_store_cannot_read_costs_it_nothing_but_the_history(corpus, tmp_path, name):
    """A store whose keyring is unreadable must not raise into a digest.

    ``opening_keys`` swallows the keyring's failure and says so in the log,
    because an unreadable keyring is one fact missing from a recall, not a
    memory that fails to load. Pinned against the files both implementations
    genuinely refuse.
    """
    vector = next(v for v in corpus["refused"] if v["name"] == name)
    store = _store(tmp_path, vector)
    assert store.opening_keys == []
    assert store.seals is False, "a store with no readable key must not seal anything"
