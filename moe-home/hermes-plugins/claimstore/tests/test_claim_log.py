"""The ledger itself, from Python: content addressing, retraction, appenders."""

import json
import os

from claimstore.store import (
    ASSERT, RETRACT, ClaimStore, causally_after, claim_id, normalise, ordered,
)


# --- identity ---------------------------------------------------------------

def test_claim_id_is_content_addressed(ledger_dir):
    a = claim_id("memory", "The build needs Python 3.11.")
    b = claim_id("memory", "  The   build needs  Python 3.11.  ")
    assert a == b, "whitespace must not change a claim's identity"
    assert claim_id("user", "The build needs Python 3.11.") != a, (
        "the same sentence in a different store is a different claim"
    )
    assert len(a) == 12


def test_normalise_collapses_whitespace_only():
    assert normalise(" a\n b\t c ") == "a b c"
    assert normalise("Case Matters") == "Case Matters"


def test_the_plugin_takes_the_apps_device_id(ledger_dir, tmp_path):
    """§13.1: one device per Mac. ``device.json`` is the id for every writer,
    and the plugin appends to the app's file, on the app's chain."""
    ledger_dir.mkdir(parents=True)
    (ledger_dir / "device.json").write_text(json.dumps({"id": "mac-9f3c1a2b"}), encoding="utf-8")
    store = ClaimStore(ledger_dir, state_dir=tmp_path / "h")
    assert store.device == "mac-9f3c1a2b"
    store.assert_claim("memory", "mine", source="test")
    assert (ledger_dir / "mac-9f3c1a2b.jsonl").exists()
    assert sorted(p.name for p in ledger_dir.glob("*.jsonl")) == ["mac-9f3c1a2b.jsonl"]
    assert not (ledger_dir / "claimstore-device.json").exists()
    assert not (tmp_path / "h" / "claimstore-device.json").exists()


def test_without_the_app_the_plugin_mints_the_apps_form(ledger_dir, tmp_path):
    """Hermes ran before the app ever did: the plugin mints ``device.json``
    exactly as ``Ledger.resolveDevice`` would, so whoever is first is the
    author for both."""
    store = ClaimStore(ledger_dir, state_dir=tmp_path / "h")
    device = store.device
    assert device.startswith("mac-") and len(device) == 12
    assert all(c in "0123456789abcdef" for c in device[4:])
    path = ledger_dir / "device.json"
    assert os.stat(str(path)).st_mode & 0o777 == 0o600
    body = json.loads(path.read_text(encoding="utf-8"))
    assert set(body) == {"id", "createdAt"} and body["id"] == device
    assert len(body["createdAt"]) == 24 and body["createdAt"].endswith("Z")
    # Foundation's pretty form: two-space indent, " : " around the colon.
    assert path.read_text(encoding="utf-8").startswith('{\n  "createdAt" : "')
    # And it is stable — the app reads the same file next.
    assert ClaimStore(ledger_dir, state_dir=tmp_path / "h").device == device


def test_a_legacy_claimstore_device_file_is_no_longer_read(ledger_dir, tmp_path):
    home = tmp_path / "h"
    home.mkdir()
    (home / "claimstore-device.json").write_text(json.dumps({"id": "hermes-EXAMPLE02"}))
    (ledger_dir).mkdir(parents=True)
    (ledger_dir / "claimstore-device.json").write_text(json.dumps({"id": "hermes-EXAMPLE02"}))
    store = ClaimStore(ledger_dir, state_dir=home)
    assert store.device.startswith("mac-")


def test_two_writers_share_one_chain_without_forks_or_gaps(ledger_dir, tmp_path):
    """The §13.1 append protocol: the plugin and a simulated Swift writer —
    which appends straight to the same file, taking the same lock and
    re-reading the head from the file — interleave freely and produce one
    gapless chain."""
    from claimstore.store import _flock, canonical_json, record_id, unsigned_fields

    ledger_dir.mkdir(parents=True)
    (ledger_dir / "device.json").write_text(json.dumps({"id": "mac-9f3c1a2b"}), encoding="utf-8")
    store = ClaimStore(ledger_dir, state_dir=tmp_path / "h")
    path = ledger_dir / "mac-9f3c1a2b.jsonl"

    def swift_appends(text):
        # What Ledger.swift does from this slice: lock, head from the file's
        # highest seq, seq+1, one O_APPEND write, fsync.
        with _flock(ledger_dir / "mac-9f3c1a2b.jsonl.lock"):
            lines = [l for l in path.read_text(encoding="utf-8").splitlines() if l.strip()] \
                if path.exists() else []
            head = json.loads(lines[-1]) if lines else None
            seq = (head["seq"] if head else 0) + 1
            unsigned = unsigned_fields("turn", "2026-09-02T10:00:%02d.000Z" % seq,
                                       "mac-9f3c1a2b", seq, head["id"] if head else None, [],
                                       {"thread": "T", "turn_id": "x%d" % seq, "role": "you",
                                        "at": "2026-09-02T10:00:00.000Z",
                                        "enc": "aes-gcm-256.v1", "text_enc": text})
            record = dict(unsigned, id=record_id(unsigned))
            fd = os.open(str(path), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            try:
                os.write(fd, (canonical_json(record) + "\n").encode("utf-8"))
                os.fsync(fd)
            finally:
                os.close(fd)

    store.assert_claim("memory", "one", source="test")        # seq 1
    swift_appends("QUJD")                                      # seq 2, plugin's head is stale
    store.assert_claim("memory", "two", source="test")        # must be seq 3
    swift_appends("REVG")                                      # seq 4
    swift_appends("R0hJ")                                      # seq 5
    store.assert_claim("memory", "three", source="test")      # seq 6
    store.assert_claim("memory", "four", source="test")       # seq 7 (cached head still valid)

    records = [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines()]
    assert [r["seq"] for r in records] == [1, 2, 3, 4, 5, 6, 7]
    assert all(records[i]["prev"] == records[i - 1]["id"] for i in range(1, 7))
    assert {r["device"] for r in records} == {"mac-9f3c1a2b"}
    assert store.forked_seqs() == []
    assert store.live("memory") == ["one", "two", "three", "four"]


def test_the_head_is_the_highest_seq_not_the_last_line(ledger_dir, tmp_path):
    """§13.1 as decided: a legacy fork's stale tail (a lower seq after a
    higher one) is closed by the next append, not forked again."""
    from claimstore.store import canonical_json, record_id, unsigned_fields

    store = ClaimStore(ledger_dir, device="mac-9f3c1a2b", state_dir=tmp_path / "h")
    store.assert_claim("memory", "one", source="test")                        # seq 1
    store.assert_claim("memory", "two", source="test")                        # seq 2
    stale = unsigned_fields("claim", "2026-09-02T10:00:09.000Z", "mac-9f3c1a2b", 1, None, [],
                            {"op": "assert", "claim": claim_id("memory", "stale"),
                             "target": "memory", "source": "test", "text": "stale"})
    with open(str(store.path), "a", encoding="utf-8") as handle:
        handle.write(canonical_json(dict(stale, id=record_id(stale))) + "\n")
    cold = ClaimStore(ledger_dir, device="mac-9f3c1a2b", state_dir=tmp_path / "h")
    assert cold._head()[0] == 2
    cold.assert_claim("memory", "three", source="test")
    assert [json.loads(l)["seq"] for l in store.path.read_text(encoding="utf-8").splitlines()] \
        == [1, 2, 1, 3]


def test_the_lock_file_is_beside_the_chain_and_private(ledger_dir, tmp_path):
    store = ClaimStore(ledger_dir, device="mac-9f3c1a2b", state_dir=tmp_path / "h")
    store.assert_claim("memory", "x", source="test")
    lock = ledger_dir / "mac-9f3c1a2b.jsonl.lock"
    assert lock.exists()
    assert os.stat(str(lock)).st_mode & 0o777 == 0o600


def test_a_forked_chain_is_visible_rather_than_silent(ledger_dir, tmp_path):
    """A writer that skips the lock and trusts a stale head — what the
    pre-§13.1 plugin did — forks the chain. The sync layer tolerates it by
    sending everything; what must not happen is that it stays invisible."""
    from claimstore.store import canonical_json, record_id, unsigned_fields

    store = ClaimStore(ledger_dir, device="mac-9f3c1a2b", state_dir=tmp_path / "h")
    store.assert_claim("memory", "from process one", source="test")     # seq 1
    first = json.loads(store.path.read_text(encoding="utf-8").splitlines()[0])
    # A careless second writer: seq 2 twice, no lock, stale head.
    for text in ("careless a", "careless b"):
        unsigned = unsigned_fields("claim", "2026-09-02T10:00:05.000Z", "mac-9f3c1a2b", 2,
                                   first["id"], [], {"op": "assert", "claim": claim_id("memory", text),
                                                     "target": "memory", "source": "test",
                                                     "text": text})
        with open(str(store.path), "a", encoding="utf-8") as handle:
            handle.write(canonical_json(dict(unsigned, id=record_id(unsigned))) + "\n")
    assert store.forked_seqs() == [2], "a forked seq must be reportable"
    # Nothing is lost, and the next well-behaved append continues from the
    # file's highest seq rather than from a cached head.
    store.assert_claim("memory", "one again", source="test")
    seqs = [json.loads(l)["seq"] for l in store.path.read_text(encoding="utf-8").splitlines()]
    assert seqs == [1, 2, 2, 3]
    cold = ClaimStore(ledger_dir, device="mac-9f3c1a2b", state_dir=tmp_path / "h")
    assert sorted(cold.live("memory")) == [
        "careless a", "careless b", "from process one", "one again"]


# --- assert / retract -------------------------------------------------------

def test_assert_is_idempotent(ledger_dir):
    store = ClaimStore(ledger_dir)
    first = store.assert_claim("memory", "fact one", source="test")
    second = store.assert_claim("memory", "fact one", source="test")
    assert first == second
    assert len(store.claim_records()) == 1, "re-asserting a live claim appends nothing"


def test_retract_then_reassert(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "fact one", source="user")
    store.assert_claim("memory", "fact two", source="user")
    store.retract_claim("memory", "fact one", source="user")
    assert store.live("memory") == ["fact two"]

    store.assert_claim("memory", "fact one", source="user")
    assert store.live("memory") == ["fact two", "fact one"]
    assert len(store.claim_records()) == 4, "history is append-only; nothing was edited"


def test_nothing_but_the_person_can_reassert_what_the_person_retracted(ledger_dir):
    """§3.1's tombstone amendment, from this side of the seam.

    The ``hermes:`` half is the one that matters. A memory-tool write is the
    model deciding to record something — ``assistant_tool`` is Hermes's
    *default* write_origin — and letting that undo a deletion means a fact
    somebody removed about themselves comes back because the assistant noticed
    it again. Nobody asked. It becomes a question instead.
    """
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "I work at Kaplan", source="gmail")
    store.retract_claim("memory", "I work at Kaplan", source="user")

    store.assert_claim("memory", "I work at Kaplan", source="gmail")
    assert store.live("memory") == [], "a crawl undid a deletion"

    store.assert_claim("memory", "I work at Kaplan", source="hermes:assistant_tool")
    assert store.live("memory") == [], "the model undid a deletion nobody asked it to"

    resolved = store.resolve("memory")
    assert [q.source for q in resolved.pending_revivals] == ["hermes:assistant_tool"], (
        "a refused revival must become a question, not silence"
    )
    assert resolved.pending_revivals[0].text == "I work at Kaplan"
    assert len(store.claim_records()) == 4, "every record is kept; the digest omits them"

    # And the person, who is the only one who can.
    store.assert_claim("memory", "I work at Kaplan", source="user")
    assert store.live("memory") == ["I work at Kaplan"]
    assert store.resolve("memory").pending_revivals == [], "answered, so no longer asked"


def test_one_claim_restated_three_times_is_one_question(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "I work at Kaplan", source="gmail")
    store.retract_claim("memory", "I work at Kaplan", source="user")
    for source in ("gmail", "imessage", "hermes:assistant_tool"):
        store.assert_claim("memory", "I work at Kaplan", source=source)
    pending = store.resolve("memory").pending_revivals
    assert len(pending) == 1, "one deleted fact is one question"
    assert pending[0].source == "hermes:assistant_tool", "about the most recent restatement"


def test_a_question_can_be_answered_no(ledger_dir):
    """Retracting a pending revival must land as a record, not as the question
    quietly going away."""
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "I work at Kaplan", source="gmail")
    store.retract_claim("memory", "I work at Kaplan", source="user")
    store.assert_claim("memory", "I work at Kaplan", source="gmail")
    assert len(store.resolve("memory").pending_revivals) == 1

    assert store.retract_claim("memory", "I work at Kaplan", source="user") is not None
    assert store.resolve("memory").pending_revivals == []
    assert store.live("memory") == []
    assert len(store.claim_records()) == 4


def test_live_order_is_stable_across_reassertion(ledger_dir):
    store = ClaimStore(ledger_dir)
    for text in ("a", "b", "c"):
        store.assert_claim("memory", text, source="test")
    store.assert_claim("memory", "b", source="test")  # no-op
    assert store.live("memory") == ["a", "b", "c"]


def test_targets_are_independent(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "shared sentence", source="test")
    store.assert_claim("user", "shared sentence", source="test")
    store.retract_claim("memory", "shared sentence", source="test")
    assert store.live("memory") == []
    assert store.live("user") == ["shared sentence"]


def test_the_store_has_no_substring_sweep(ledger_dir):
    """Addressing is the file's business, not the ledger's.

    ``retract_matching`` used to live here and swept the whole live set for a
    substring. The live set is not the file — the digest is a deliberate
    subset of it — so one ``memory(remove)`` could retract claims nobody could
    see. What replaced it is ``projection.retract_addressed``, which needs the
    digest and therefore cannot live in this module.
    """
    store = ClaimStore(ledger_dir)
    assert not hasattr(store, "retract_matching")


def test_empty_text_is_not_a_claim(ledger_dir):
    store = ClaimStore(ledger_dir)
    assert store.assert_claim("memory", "   ", source="test") is None
    assert store.claim_records() == []


def test_retracting_something_nobody_asserted_writes_nothing(ledger_dir):
    store = ClaimStore(ledger_dir)
    assert store.retract_claim("memory", "never said", source="test") is None
    assert store.claim_records() == []


# --- §3.1's topic rules, locally --------------------------------------------

def test_same_source_same_key_keeps_the_newer_reading(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "Izzy works at Kaplan", source="gmail", key="job")
    store.assert_claim("memory", "Izzy works at Anthropic", source="gmail", key="job")
    resolved = store.resolve("memory")
    assert resolved.texts == ["Izzy works at Anthropic"]
    assert [c.text for c in resolved.superseded] == ["Izzy works at Kaplan"]
    assert resolved.disagreements == []


def test_different_sources_same_key_keep_both_and_raise_it(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "Izzy works at Kaplan", source="imessage", key="job")
    store.assert_claim("memory", "Izzy works at Anthropic", source="gmail", key="job")
    resolved = store.resolve("memory")
    assert sorted(resolved.texts) == ["Izzy works at Anthropic", "Izzy works at Kaplan"]
    assert len(resolved.disagreements) == 1
    assert sorted(resolved.disagreements[0]["sources"]) == ["gmail", "imessage"]


# --- other appenders --------------------------------------------------------

def test_a_second_writer_is_picked_up_by_refresh(ledger_dir):
    """The whole point: another process appends and we converge on it."""
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "mine", source="test")
    store.refresh()
    assert store.refresh() is False, "no external change yet"

    other = ClaimStore(ledger_dir, device="mac-other")
    other.assert_claim("memory", "theirs", source="other-device")

    assert store.refresh() is True
    assert store.live("memory") == ["mine", "theirs"]


def test_a_retraction_from_another_device_is_honoured(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "stale fact", source="test")
    ClaimStore(ledger_dir, device="mac-other").retract_claim(
        "memory", "stale fact", source="user")
    store.refresh()
    assert store.live("memory") == []


def test_two_devices_never_share_a_file(ledger_dir):
    a = ClaimStore(ledger_dir, device="mac-aaaa1111")
    b = ClaimStore(ledger_dir, device="mac-bbbb2222")
    a.assert_claim("memory", "from a", source="test")
    b.assert_claim("memory", "from b", source="test")
    names = sorted(p.name for p in ledger_dir.glob("*.jsonl"))
    assert names == ["mac-aaaa1111.jsonl", "mac-bbbb2222.jsonl"]


def test_a_device_id_from_a_file_cannot_escape_the_directory(tmp_path):
    ledger = tmp_path / "ledger"
    ledger.mkdir()
    (ledger / "device.json").write_text(
        json.dumps({"id": "../../escape"}), encoding="utf-8")
    store = ClaimStore(ledger)
    store.assert_claim("memory", "contained", source="test")
    assert store.path.parent == ledger
    assert not (tmp_path.parent / "escape.jsonl").exists()


def test_a_torn_tail_is_skipped_not_fatal(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "before", source="test")
    with open(str(store.path), "a", encoding="utf-8") as handle:
        handle.write('{"kind":"claim","at":"2026-08-31T09:14:02.000Z","dev')  # mid-write
    store.refresh()
    assert store.live("memory") == ["before"], "a partial line is ignored, not fatal"


def test_an_append_after_a_torn_line_starts_a_fresh_one(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "before", source="test")
    with open(str(store.path), "a", encoding="utf-8") as handle:
        handle.write('{"half a record')
    store.refresh()
    store.assert_claim("memory", "after", source="test")
    store.refresh()
    assert store.live("memory") == ["before", "after"], (
        "a crash's half-line cost the record it was going to be and nothing else"
    )


def test_a_line_this_build_cannot_read_is_skipped(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "readable", source="test")
    with open(str(store.path), "a", encoding="utf-8") as handle:
        # A record kind from a newer version, carried and not understood.
        handle.write(json.dumps({
            "id": "ffff", "kind": "something.new", "at": "2027-01-01T00:00:00.000Z",
            "device": "mac-future", "seq": 1, "after": [], "body": {"x": 1}}) + "\n")
        handle.write("not json at all\n")
    store.refresh()
    assert store.live("memory") == ["readable"]
    assert len(store.records()) == 2, "the unknown kind is carried, not dropped"


def test_a_missing_ledger_reads_as_empty(tmp_path):
    store = ClaimStore(tmp_path / "nope" / "ledger")
    assert store.records() == []
    assert store.live("memory") == []


# --- ordering ---------------------------------------------------------------

def test_records_are_ordered_causally_not_chronologically(ledger_dir):
    """A reply stamped before its question still sorts after it."""
    store = ClaimStore(ledger_dir, device="hermes-aaaa1111")
    first = store.append("claim", {"op": ASSERT, "claim": claim_id("memory", "question"),
                                   "target": "memory", "source": "user", "text": "question"},
                         at=2000)
    other = ClaimStore(ledger_dir, device="mac-bbbb2222")
    other.append("claim", {"op": ASSERT, "claim": claim_id("memory", "reply"),
                           "target": "memory", "source": "user", "text": "reply"},
                 after=[first["id"]], at=1000)  # an hour behind, and later anyway
    assert ClaimStore(ledger_dir).live("memory") == ["question", "reply"]


def test_causally_after_reads_only_what_records_say(ledger_dir):
    store = ClaimStore(ledger_dir)
    a = store.assert_claim("memory", "a", source="user")
    assert a
    records = store.records()
    first, second = records[0], None
    store.assert_claim("memory", "b", source="user")
    records = store.records()
    second = records[1]
    # `prev` is causality too, and the cheapest kind.
    assert second["id"] in causally_after(first, records)
    assert first["id"] not in causally_after(second, records)


def test_ordering_survives_being_read_in_any_file_order(ledger_dir):
    a = ClaimStore(ledger_dir, device="hermes-aaaa1111")
    b = ClaimStore(ledger_dir, device="mac-zzzz9999")
    r1 = a.append("claim", {"op": ASSERT, "claim": claim_id("memory", "one"),
                            "target": "memory", "source": "user", "text": "one"}, at=1000)
    b.append("claim", {"op": ASSERT, "claim": claim_id("memory", "two"),
                       "target": "memory", "source": "user", "text": "two"},
             after=[r1["id"]], at=1001)
    cold = ClaimStore(ledger_dir).records()
    assert [r["body"]["text"] for r in cold] == ["one", "two"]
    # The same records handed over in reverse must order the same way.
    assert [r["body"]["text"] for r in ordered(list(reversed(cold)))] == ["one", "two"]


def test_ordering_does_not_blow_the_stack_on_a_long_chain(ledger_dir):
    """A device's `prev` chain is as long as its history. A recursive walk of
    it would fail on a ledger a person could plausibly own."""
    store = ClaimStore(ledger_dir)
    for i in range(2000):
        store.append("claim", {"op": ASSERT, "claim": claim_id("memory", "fact %d" % i),
                               "target": "memory", "source": "user", "text": "fact %d" % i},
                     at=1000 + i)
    assert len(ClaimStore(ledger_dir).records()) == 2000


# --- what the log looks like ------------------------------------------------

def test_records_carry_provenance_and_the_claim_address(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "fact", source="hermes:assistant_tool", key="topic")
    line = store.path.read_text(encoding="utf-8").splitlines()[0]
    record = json.loads(line)
    assert record["kind"] == "claim"
    assert record["body"]["op"] == ASSERT
    assert record["body"]["target"] == "memory"
    assert record["body"]["source"] == "hermes:assistant_tool"
    assert record["body"]["key"] == "topic"
    assert record["body"]["claim"] == claim_id("memory", "fact")
    assert record["at"].endswith("Z")

    store.retract_claim("memory", "fact", source="user")
    retraction = json.loads(store.path.read_text(encoding="utf-8").splitlines()[1])
    assert retraction["body"]["op"] == RETRACT
    assert "text" not in retraction["body"], "a tombstone does not restate the words"
    assert retraction["body"]["key"] == "topic"


def test_the_ledger_file_is_private(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "private", source="test")
    assert os.stat(str(store.path)).st_mode & 0o777 == 0o600
