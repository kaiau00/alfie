"""The agreement between the two languages that write this ledger.

The Swift half is ``Tests/MoeLedgerTests/ClaimConformanceTests.swift``, and it
asserts the same three things against the same committed file:

* every claim-id vector — the id two devices must agree on or diverge silently;
* every record's ``id`` recomputed from its own fields, which is the record
  hash and therefore the canonical-JSON encoding agreeing across two JSON
  writers;
* every case's resolution under §3.1 — live set, disagreements, superseded.

A claim id that differs by one character between the two runtimes does not
crash anything. It produces two halves of one person's memory that never
notice each other, forever. That is the worst failure this design has, and it
is invisible without exactly this file.

Regenerate the fixture with ``tests/make_conformance.py`` only when a rule
changes on purpose, and expect the Swift test to fail until Swift matches.
"""

import json
from pathlib import Path

import pytest

from claimstore.store import (
    ClaimStore, claim_id, normalise, ordered, record_id, resolve, revives,
)

FIXTURE = Path(__file__).resolve().parent / "claim-conformance.json"


@pytest.fixture(scope="module")
def fixture():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def test_the_vector_file_is_there_and_has_not_been_emptied(fixture):
    assert len(fixture["claim_ids"]) >= 8
    assert len(fixture["cases"]) >= 10


def test_claim_ids_match_the_committed_vectors(fixture):
    for vector in fixture["claim_ids"]:
        assert normalise(vector["text"]) == vector["normalised"], vector["text"]
        assert claim_id(vector["target"], vector["text"]) == vector["id"], vector["text"]


def test_only_the_person_revives_a_deleted_claim():
    """The revival rule, source class by source class.

    ``revives`` is a two-line function and it was wrong: it accepted any
    ``hermes:`` source, on the reasoning that a memory-tool write is the user
    telling the Mac to remember something. Swift accepted only ``user``, so
    over identical bytes the two sides gave different answers — Python keeping
    a deleted fact live, Swift dropping it. Asserted directly here, and again
    through the fixture below, because that divergence survived a whole
    conformance suite that only checked the live set.
    """
    for source in ("user", "user:memory-pane", "user:notch"):
        assert revives(source), source
    for source in ("hermes:assistant_tool", "hermes:background_review",
                   "hermes:side_question", "gmail", "imessage", "file",
                   "unknown", "", "users", "user-ish"):
        assert not revives(source), (
            "%s must not be able to undo a person's deletion" % source)


def test_the_revival_matrix_covers_every_source_class(fixture):
    rows = [c for c in fixture["cases"] if c["name"].startswith("restated-after-deletion-by-")]
    assert len(rows) >= 8, "the revival matrix lost rows"
    seen = set()
    for row in rows:
        expect = row["expect"]
        pending = expect["pending_revivals"]
        source = (pending[0]["source"] if pending else expect["live_sources"][0])
        seen.add(source)
        assert revives(source) == bool(expect["live"]), row["name"]
        assert bool(pending) == (not expect["live"]), (
            "%s: a refused revival must become a question" % row["name"])
    # Every write_origin Hermes actually produces, by name. None of them is a
    # person, and the point of listing them is that the next one added upstream
    # shows up here as a gap rather than as a silently reviving source.
    assert {"hermes:assistant_tool", "hermes:background_review",
            "hermes:side_question"} <= seen
    assert {"user", "user:memory-pane"} <= seen


def test_normalisation_is_whitespace_only_and_codepoint_wise():
    # The three edges the enumerated whitespace set exists for. `\r\n` is one
    # Character in Swift and two code points here; the C1 and no-break spaces
    # are whitespace to one language's built-in test and not the other's.
    assert normalise("a\r\nb") == "a b"
    assert normalise("a\x0bb\x0cc") == "a b c"
    assert normalise("\xa0x\xa0") == "\xa0x\xa0", "a no-break space is a character"
    assert claim_id("memory", "one two") == claim_id("memory", "  one \t two \n")
    assert claim_id("memory", "x") != claim_id("user", "x")
    assert len(claim_id("memory", "x")) == 12


def test_every_record_rehashes_to_the_id_it_carries(fixture):
    checked = 0
    for case in fixture["cases"]:
        for record in case["records"]:
            unsigned = {k: v for k, v in record.items() if k != "id"}
            assert record_id(unsigned) == record["id"], (
                "record %s rehashes differently: the canonical JSON encoding drifted"
                % record["id"])
            checked += 1
    assert checked >= 20


def test_every_case_resolves_the_way_the_fixture_says(fixture):
    for case in fixture["cases"]:
        decoded = [ClaimStore._decode(json.dumps(r)) for r in case["records"]]
        assert all(d is not None for d in decoded), case["name"]
        projection = resolve(ordered(decoded), case["target"])
        expect = case["expect"]
        assert projection.texts == expect["live"], case["name"]
        assert [c.source for c in projection.live] == expect["live_sources"], case["name"]
        assert [c.text for c in projection.superseded] == expect["superseded"], case["name"]
        assert [{"source": q.source, "text": q.text} for q in projection.pending_revivals] \
            == expect["pending_revivals"], case["name"]
        assert len(projection.disagreements) == len(expect["disagreements"]), case["name"]
        for mine, theirs in zip(projection.disagreements, expect["disagreements"]):
            assert mine["key"] == theirs["key"], case["name"]
            assert sorted(mine["sources"]) == theirs["sources"], case["name"]
            assert sorted(c.text for c in mine["readings"]) == theirs["readings"], case["name"]


def test_a_ledger_written_by_this_side_is_readable_as_the_fixture_shape(ledger_dir):
    """The other direction: what this plugin writes has the fields the Swift
    reader requires, hashes to the id it carries, and orders the same way."""
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "the build needs Python 3.11", source="user", key="build")
    store.assert_claim("memory", "deploys run on Fridays", source="gmail")
    store.retract_claim("memory", "deploys run on Fridays", source="user")

    lines = (ledger_dir / (store.device + ".jsonl")).read_text(encoding="utf-8").splitlines()
    assert len(lines) == 3
    for line in lines:
        record = json.loads(line)
        assert set(record) >= {"id", "kind", "at", "device", "seq", "after", "body"}
        assert record["kind"] == "claim"
        assert record_id({k: v for k, v in record.items() if k != "id"}) == record["id"]
    # seq/prev chain this device's own writes, so loss is detectable.
    seqs = [json.loads(line)["seq"] for line in lines]
    assert seqs == [1, 2, 3]
    assert json.loads(lines[1])["prev"] == json.loads(lines[0])["id"]
    assert store.live("memory") == ["the build needs Python 3.11"]
