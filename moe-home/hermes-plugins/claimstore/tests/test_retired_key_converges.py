"""Memory converges after a free Mac joins a tenant — CLOUD-PLAN §15.1.

`test_retired_key_reads.py` is the half that lets the joiner read its own
past. This is the half that lets everybody else read it. Without it §15.1's
headline is not closed: the record sits on the shared chain sealed under a key
that exists on exactly ONE device, so the founder answers "I don't know" about
a fact the joiner remembers, and if the joiner dies the fact is gone. §15.1
said the content reached the tenant "through the document path"; it does not —
`MEMORY.md` is a projection, not one of `DOCUMENT_NAMES`, so nothing carried
it, and `KeyCourier.sealed(for:threads:)` ships only current keys, so the
retired key never left that Mac either.

The fix is to RE-ASSERT, not to re-seal: a new `claim` record with the same
claim id and the same words, sealed under the current key. The signed
append-only chain is untouched, and §3.1 treats the pair as one claim with a
newer record.
"""

import base64
import json

import claimstore
from claimstore.store import ClaimStore, claim_id, open_text


CURRENT = bytes(range(32))          # the tenant's key, minted by the founder
RETIRED = bytes(range(100, 132))    # the joiner's own, from when it ran free
FACT = "the car is due in March"
CID = claim_id("memory", FACT)


def _keyring(tmp_path, current, retired, name="thread-keys.json"):
    """A thread-keys.json in the shape Swift's ThreadKeyring writes after
    `adopt` — the tenant's key current, this Mac's own retired."""
    from moeledger.vault import Keyring

    path = tmp_path / name
    keys = {} if current is None else {"moe:memory": base64.b64encode(current).decode()}
    body = {
        "version": 1,
        "keys": keys,
        "retired": {"moe:memory": [base64.b64encode(k).decode() for k in retired]},
    }
    path.write_text(json.dumps(body), encoding="utf-8")
    return Keyring(path)


def _free_mac_that_joined(tmp_path, facts=((FACT, None),), retired=RETIRED,
                          current=CURRENT):
    """A ledger where this Mac wrote `facts` while it ran free, then joined.

    Returns the store as it is *after* joining: the tenant's key current, its
    own retired, and the records it wrote still sealed under the old one.
    """
    ledger = tmp_path / "ledger"
    free = ClaimStore(directory=ledger, device="mac-JOINER0001", key=retired)
    for text, label in facts:
        free.assert_claim("memory", text, source="user", key=label)
    return ledger, ClaimStore(directory=ledger, device="mac-JOINER0001",
                              keyring=_keyring(tmp_path, current, [retired]))


def _founder(ledger):
    """Another device in the tenant, holding ONLY the tenant's key — which is
    every device except the one that joined from free."""
    return ClaimStore(directory=ledger, device="mac-FOUNDER001", key=CURRENT)


def _joined_ledger_dir(ledger_dir, current=CURRENT, retired=(RETIRED,)):
    """A ledger directory as a joined Mac's is: the app's `device.json`, and
    a `thread-keys.json` in the shape Swift writes after `adopt`."""
    ledger_dir.mkdir(parents=True, exist_ok=True)
    (ledger_dir / "device.json").write_text(
        json.dumps({"createdAt": 0, "id": "mac-JOINER0001"}), encoding="utf-8")
    (ledger_dir / "thread-keys.json").write_text(json.dumps({
        "version": 1,
        "keys": {"moe:memory": base64.b64encode(current).decode()},
        "retired": {"moe:memory": [base64.b64encode(k).decode() for k in retired]},
    }), encoding="utf-8")


# -- the falsifier -----------------------------------------------------------------------------

def test_another_device_finds_a_fact_the_joiner_learned_while_it_was_free(tmp_path):
    """§15.1's headline, end to end, on the device that is not the joiner.

    This is the test the work exists to pass. Before the re-assertion it
    failed at the last two lines: the founder read nothing and counted one
    claim it could not open, forever.
    """
    ledger, joined = _free_mac_that_joined(tmp_path)

    founder = _founder(ledger)
    assert founder.live("memory") == [], "the defect: present, sealed, unreadable"
    assert founder.unreadable("memory") == [CID], "counted, and that was all"

    assert joined.key == CURRENT, "sealing never reaches for a retired key"
    assert joined.live("memory") == [FACT], "the joiner still reads its own past"

    assert joined.reassert_retired() == [CID]

    founder.refresh()
    assert founder.live("memory") == [FACT], "THE POINT: the tenant's memory converged"
    assert founder.unreadable("memory") == []


def test_the_reassertion_seals_under_the_current_key_and_names_what_it_restates(tmp_path):
    ledger, joined = _free_mac_that_joined(tmp_path)
    original = joined.claim_records("memory")[0]
    joined.reassert_retired()

    records = joined.claim_records("memory")
    assert len(records) == 2, "one new record, and the old one still there"
    fresh = records[-1]
    assert fresh["body"]["claim"] == CID == original["body"]["claim"], \
        "the same claim id, so §3.1 sees one claim with a newer record"
    assert open_text(fresh["body"]["text_enc"], CURRENT) == FACT
    assert open_text(fresh["body"]["text_enc"], RETIRED) is None, \
        "sealed under the tenant's key, not the retired one"
    assert fresh["after"] == [original["id"]], \
        "causally after the record it restates, never merely concurrent with it"


def test_the_original_record_is_left_exactly_as_it_was(tmp_path):
    """Re-assert, do NOT re-seal: the append-only chain is not rewritten."""
    ledger, joined = _free_mac_that_joined(tmp_path)
    path = ledger / "mac-JOINER0001.jsonl"
    before = path.read_text(encoding="utf-8").splitlines()

    joined.reassert_retired()

    after = path.read_text(encoding="utf-8").splitlines()
    assert after[:len(before)] == before, "every existing line byte for byte"
    assert len(after) == len(before) + 1
    assert open_text(json.loads(before[-1])["body"]["text_enc"], RETIRED) == FACT, \
        "and the old record is still sealed under the old key, as it always was"


def test_the_source_survives_the_reassertion(tmp_path):
    """A claim that arrived as the person's and is re-asserted as "unknown"
    stops being able to revive a retraction (§3.1's tombstone amendment), so
    the same words would resolve differently on the two devices."""
    ledger, joined = _free_mac_that_joined(tmp_path)
    joined.reassert_retired()

    assert [c.source for c in _founder(ledger).resolve("memory").live] == ["user"]


def test_the_topic_label_survives_the_reassertion(tmp_path):
    """`key` is the topic. A re-assertion that dropped it would file the fact
    under its own claim id instead, and §3.1's rules 4 and 5 — one reading
    per source, and a disagreement when two sources are left — are both
    grouped by topic, so the founder would stop being able to see that two
    readings are about one thing."""
    ledger, joined = _free_mac_that_joined(tmp_path, facts=((FACT, "car"),))
    joined.reassert_retired()

    assert [c.key for c in _founder(ledger).resolve("memory").live] == ["car"]


# -- idempotence -------------------------------------------------------------------------------

def test_running_it_twice_appends_nothing_the_second_time(tmp_path):
    """Idempotent by construction, not by a marker. The condition acted on is
    "a device with only the current key cannot read this", and the
    re-assertion itself makes that false."""
    ledger, joined = _free_mac_that_joined(tmp_path)
    assert joined.reassert_retired() == [CID]
    count = len(joined.records())

    assert joined.reassert_retired() == [], "same process, cache warm"
    assert len(joined.records()) == count

    # And the case that actually happens: the next session, a fresh store
    # with nothing cached and no marker to consult.
    tomorrow = ClaimStore(directory=ledger, device="mac-JOINER0001",
                          keyring=_keyring(tmp_path, CURRENT, [RETIRED]))
    assert tomorrow.reassert_retired() == []
    assert len(tomorrow.records()) == count


def test_a_mac_that_never_joined_from_free_appends_nothing(tmp_path):
    """The ordinary Mac, and the reason this costs it nothing: with no
    retired history there is nothing to find, and it does not go looking."""
    ledger = tmp_path / "ledger"
    store = ClaimStore(directory=ledger, device="mac-EXAMPLE0001",
                       keyring=_keyring(tmp_path, CURRENT, []))
    store.assert_claim("memory", "the dentist is on Tuesday", source="user")
    count = len(store.records())

    assert store.reassert_retired() == []
    assert len(store.records()) == count


def test_a_mac_with_no_retired_history_does_not_read_the_ledger_at_all(tmp_path):
    """"Does not go looking" as an assertion rather than a remark.

    This runs at session start, and the work it would otherwise do is two
    resolves of every target — seconds on a twenty-thousand-record ledger,
    synchronously, on the one path that has to feel instant. An early return
    nothing can observe is an early return somebody deletes as dead code, so
    the ledger is made to explode if it is touched.
    """
    ledger = tmp_path / "ledger"
    store = ClaimStore(directory=ledger, device="mac-EXAMPLE0001",
                       keyring=_keyring(tmp_path, CURRENT, []))
    store.assert_claim("memory", "the dentist is on Tuesday", source="user")

    def explode():
        raise AssertionError("the ledger was read on a Mac with no retired key")

    store.records = explode
    assert store.reassert_retired() == []


def test_a_fact_retracted_while_free_is_not_brought_back(tmp_path):
    """Only what STANDS is re-asserted. A tombstone written under the retired
    key suppresses the assert for every reader, including this one, and
    re-asserting the text would undo a deletion the person asked for."""
    ledger = tmp_path / "ledger"
    free = ClaimStore(directory=ledger, device="mac-JOINER0001", key=RETIRED)
    free.assert_claim("memory", FACT, source="user")
    free.retract_claim("memory", FACT, source="user")
    joined = ClaimStore(directory=ledger, device="mac-JOINER0001",
                        keyring=_keyring(tmp_path, CURRENT, [RETIRED]))
    assert joined.live("memory") == []

    assert joined.reassert_retired() == []
    assert _founder(ledger).live("memory") == []


def test_a_question_is_not_carried_to_another_device_as_if_it_were_a_fact(tmp_path):
    """Only what STANDS. The person deleted a fact while free and the model
    later restated it, which §3.1 makes a *pending revival* — a question this
    device has to put to the person, not a fact. Re-asserting it would move
    the question to another device instead of answering it, and a queue for
    questions is somebody else's slice (ONE-AGENT §14.3).
    """
    ledger = tmp_path / "ledger"
    free = ClaimStore(directory=ledger, device="mac-JOINER0001", key=RETIRED)
    free.assert_claim("memory", FACT, source="user")
    free.retract_claim("memory", FACT, source="user")
    free.assert_claim("memory", FACT, source="assistant_tool")
    joined = ClaimStore(directory=ledger, device="mac-JOINER0001",
                        keyring=_keyring(tmp_path, CURRENT, [RETIRED]))
    assert [q.id for q in joined.resolve("memory").pending_revivals] == [CID]
    count = len(joined.records())

    assert joined.reassert_retired() == []
    assert len(joined.records()) == count


def test_nothing_is_written_in_the_clear_when_the_current_key_is_missing(tmp_path):
    """A keyring with a history and no current entry — a keyring that lost
    its key, which §13.2's mint rule already knows how to be in the middle
    of. Without the `seals` guard this would re-assert every stranded claim
    as a PLAINTEXT record: never pushed (§13.3), never re-sealed, so the fact
    would be no more shared than before and the words would be on disk in the
    clear for nothing."""
    ledger = tmp_path / "ledger"
    free = ClaimStore(directory=ledger, device="mac-JOINER0001", key=RETIRED)
    free.assert_claim("memory", FACT, source="user")
    # Two retired keys and no current one, so the "is there any history"
    # early return cannot be what stops it.
    lost = ClaimStore(directory=ledger, device="mac-JOINER0001",
                      keyring=_keyring(tmp_path, None, [RETIRED, bytes(range(50, 82))]))
    assert lost.key is None and len(lost.opening_keys) == 2
    count = len(lost.records())

    assert lost.reassert_retired() == []
    assert len(lost.records()) == count
    assert not any("text" in r.get("body", {}) for r in lost.claim_records("memory"))


# -- the trigger, through the provider ---------------------------------------------------------

def test_session_start_is_what_notices_the_situation(hermes_home, ledger_dir, moe_home,
                                                     monkeypatch):
    """Adoption happens in Swift, in the courier, and tells this side nothing.

    So the trigger has to be a place that NOTICES rather than one that is
    told, and session start — where the store already walks its records for
    the §13.1 migration — is that place. This drives the provider rather than
    `reassert_retired` directly, which is the §18.12b lesson: a test that
    calls the layer below the change would stay green if the call site went
    away.
    """
    free = ClaimStore(ledger_dir, device="mac-JOINER0001", key=RETIRED)
    free.assert_claim("memory", FACT, source="user")
    _joined_ledger_dir(ledger_dir)
    monkeypatch.setattr(claimstore, "_config",
                        lambda: {"ledger_dir": str(ledger_dir), "targets": ["memory"]})

    p = claimstore.ClaimStoreProvider()
    p.initialize("s1", hermes_home=str(hermes_home), agent_context="primary")
    assert p.store.device == "mac-JOINER0001"

    assert _founder(ledger_dir).live("memory") == [FACT]


def test_the_provider_applies_a_document_sealed_before_this_mac_joined(
        hermes_home, ledger_dir, moe_home, monkeypatch):
    """The other call site: `_apply_documents` reads with `opening_keys`.

    `who` is the person's `CLAUDE.md`. Sealed under the key this Mac retired,
    it is the newest record of that name — so a reader holding only the
    tenant's key writes nothing, and no older record can be reached instead.
    """
    from moeledger import documents

    free = ClaimStore(ledger_dir, device="mac-JOINER0001", key=RETIRED)
    free.append("document", documents.document_body("who", "You are Alfie.", RETIRED))
    _joined_ledger_dir(ledger_dir)
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})

    p = claimstore.ClaimStoreProvider()
    p.initialize("s1", hermes_home=str(hermes_home), agent_context="primary")

    assert (moe_home / "AGENTS.md").read_text(encoding="utf-8") == "You are Alfie."
