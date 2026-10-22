"""Unfilled form labels are not memory.

What was measured on the owner's own Mac, 2026-09-20, after a week of use:
``~/.hermes/memories/USER.md`` held nine entries, and six of them were the
labels of the shipped about-me form — ``Name:``, ``What I do:``, ``Where I am
/ timezone:`` … — seeded by ``migrate-memory.py`` on day one (``source:
file``, ``2026-09-16T12:30:53Z``, six ``user`` claims) and rendered into the
``USER PROFILE (who the user is)`` block of every system prompt since. The
model, asked who the person was, read ``Name:`` followed by nothing and said
the profile was blank.

The seeder no longer writes them (``moe-home/hermes/tests/test_migrate_memory``
pins that). These tests pin the other half: a ledger that already carries
them — this Mac's, and through the sync its cloud machine's — loses them at
the next projection, and the retraction is a record, so it travels.
"""

from __future__ import annotations

import json

from claimstore import projection
from claimstore.store import ClaimStore, claim_id

# The six labels FirstRun.swift ships, exactly as they were seeded.
SHIPPED_LABELS = (
    "Name:",
    "What I do:",
    "Where I am / timezone:",
    "Family and the people I talk about most:",
    "What I'm working on right now:",
    "What I want Alfie to handle for me:",
)
REAL = (
    "Launching Alfie: personal assistant for Mac that you speak to instead of typing.",
    "Prefers I take action over explaining: wants me to say what I'm doing once, then get to work.",
)


def _seed_the_owners_ledger(ledger_dir):
    """The ledger as it was on 2026-09-20: labels and real facts, all ``file``."""
    store = ClaimStore(ledger_dir)
    for text in SHIPPED_LABELS + REAL:
        store.assert_claim("user", text, source="file")
    return store


def test_is_placeholder_is_a_bare_label_and_nothing_else():
    for label in SHIPPED_LABELS:
        assert projection.is_placeholder(label), label
    assert projection.is_placeholder("  Name:  ")
    assert not projection.is_placeholder("Name: Pat Example")
    assert not projection.is_placeholder("Answers: short and spoken, detail on request.")
    assert not projection.is_placeholder("Rotberg worker costs $30/hour")
    assert not projection.is_placeholder("")
    # A colon inside a sentence is not a label either.
    assert not projection.is_placeholder("Rule: no meetings before 11am, ever, unless the client asks:")


def test_seeded_labels_leave_the_ledger_and_the_file(hermes_home, ledger_dir):
    store = _seed_the_owners_ledger(ledger_dir)
    assert len(store.live("user")) == 8

    report = projection.project(store, "user")

    assert sorted(report["placeholders"]) == sorted(claim_id("user", t) for t in SHIPPED_LABELS)
    assert store.live("user") == list(REAL), "only the person's real facts stay live"
    path = projection.memory_path("user")
    entries = projection.parse_entries(path.read_text(encoding="utf-8"))
    assert entries == list(REAL)
    for label in SHIPPED_LABELS:
        assert label not in entries


def test_the_retraction_is_a_record_that_travels(hermes_home, ledger_dir):
    """A retract on the chain, not a file edit: the cloud machine reads the
    same ledger, and a claim retracted here is retracted there."""
    store = _seed_the_owners_ledger(ledger_dir)
    projection.project(store, "user")
    records = [json.loads(line) for path in ledger_dir.glob("*.jsonl")
               for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    retracts = [r for r in records
                if r.get("kind") == "claim" and (r.get("body") or {}).get("op") == "retract"]
    assert len(retracts) == len(SHIPPED_LABELS)
    assert {r["body"]["source"] for r in retracts} == {projection.PLACEHOLDER_SOURCE}


def test_second_projection_appends_nothing(hermes_home, ledger_dir):
    store = _seed_the_owners_ledger(ledger_dir)
    projection.project(store, "user")
    before = sum(len(p.read_bytes()) for p in ledger_dir.glob("*.jsonl"))
    report = projection.project(store, "user")
    assert report["placeholders"] == []
    assert sum(len(p.read_bytes()) for p in ledger_dir.glob("*.jsonl")) == before


def test_a_label_still_in_the_file_goes_in_one_pass(hermes_home, ledger_dir):
    """A machine whose ledger never saw the labels but whose USER.md still
    carries them (the file arrived before the fix): absorbed and retracted in
    the same projection, so it never lives a session as a fact."""
    store = ClaimStore(ledger_dir)
    store.assert_claim("user", REAL[0], source="file")
    projection.project(store, "user")
    path = projection.memory_path("user")
    path.write_text("Name:\n§\n" + REAL[0], encoding="utf-8")

    report = projection.project(store, "user")
    assert len(report["absorbed"]) == 1
    assert len(report["placeholders"]) == 1
    assert store.live("user") == [REAL[0]]
    assert projection.parse_entries(path.read_text(encoding="utf-8")) == [REAL[0]]


def test_the_person_saying_their_name_is_a_new_claim(hermes_home, ledger_dir):
    """Retracting ``Name:`` must not stand in the way of ``Name: Pat``."""
    store = _seed_the_owners_ledger(ledger_dir)
    projection.project(store, "user")
    store.assert_claim("user", "Name: Pat Example", source="hermes:assistant_tool")
    projection.project(store, "user")
    assert "Name: Pat Example" in store.live("user")
    assert "Name: Pat Example" in projection.parse_entries(
        projection.memory_path("user").read_text(encoding="utf-8"))


def test_provider_start_on_the_owners_mac(hermes_home, ledger_dir, monkeypatch):
    """End to end through the provider: the file on disk is what the seeder
    wrote, the ledger is what absorbed it, and after ``initialize`` neither
    holds a label."""
    import claimstore

    monkeypatch.setattr(
        claimstore, "_config",
        lambda: {"ledger_dir": str(ledger_dir), "targets": ["memory", "user"], "recall_limit": 3},
    )
    store = _seed_the_owners_ledger(ledger_dir)
    projection.memory_path("user").write_text(
        "\n§\n".join(SHIPPED_LABELS + REAL), encoding="utf-8")
    del store

    provider = claimstore.ClaimStoreProvider()
    provider.initialize("session-1", hermes_home=str(hermes_home), platform="cli",
                        agent_context="primary")
    assert provider.store.live("user") == list(REAL)
    entries = projection.parse_entries(projection.memory_path("user").read_text(encoding="utf-8"))
    assert entries == list(REAL)
