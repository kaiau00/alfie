"""The person's name, seeded once from the Mac account (docs/MEMORY.md §7).

A week of use and 579 turns never carried the owner's name; nothing seeded
it; "who am I" came back blank. The Mac knew it the whole time (`id -F`).
"""
from __future__ import annotations

from claimstore import projection
from claimstore.store import ClaimStore, claim_id

from test_placeholders import REAL  # the owner's three real facts


def test_the_name_is_seeded_once_under_its_own_source(hermes_home, ledger_dir):
    store = ClaimStore(ledger_dir)
    for text in REAL:
        store.assert_claim("user", text, source="file")
    cid = projection.seed_account_name(store, "Pat Example")
    assert cid == claim_id("user", "Name: Pat Example")
    assert "Name: Pat Example" in store.live("user")
    live_before = list(store.records())
    # Again: nothing appended.
    assert projection.seed_account_name(store, "Pat Example") is None
    assert store.records() == live_before
    # The source names the Mac account, so the Memory page can say where it came from.
    from claimstore.store import parse_claim
    seeded = [parse_claim(r, store.opening_keys) for r in store.claim_records("user")]
    assert any(c and c["claim"] == cid and c["source"] == projection.ACCOUNT_SOURCE for c in seeded)


def test_a_name_the_person_set_or_removed_wins(hermes_home, ledger_dir):
    store = ClaimStore(ledger_dir)
    # The person said their name first: the account's is not added beside it.
    store.assert_claim("user", "Name: Jordy", source="memory-tool")
    assert projection.seed_account_name(store, "Jordan Avery") is None
    assert store.live("user") == ["Name: Jordy"]
    # A fresh ledger where the seed landed and the person then removed it:
    # never put back.
    other = ClaimStore(ledger_dir / "other")
    cid = projection.seed_account_name(other, "Pat Example")
    other.retract_id("user", cid, source="memory-tool")
    assert other.live("user") == []
    assert projection.seed_account_name(other, "Pat Example") is None
    assert other.live("user") == []


def test_no_name_no_seed_and_a_bare_label_does_not_count_as_a_name(hermes_home, ledger_dir):
    store = ClaimStore(ledger_dir)
    assert projection.seed_account_name(store, "") is None
    assert projection.seed_account_name(store, "   ") is None
    # A leftover "Name:" label is not "the person set their name".
    store.assert_claim("user", "Name:", source="file")
    assert projection.seed_account_name(store, "Pat Example") == claim_id("user", "Name: Pat Example")


def test_the_projection_seeds_it_on_a_mac_and_reports_it(hermes_home, ledger_dir, monkeypatch):
    store = ClaimStore(ledger_dir)
    monkeypatch.setattr(projection, "account_full_name", lambda: "Pat Example")
    report = projection.project(store, "user")
    assert report["seeded_name"] == claim_id("user", "Name: Pat Example")
    entries = projection.parse_entries(projection.memory_path("user").read_text(encoding="utf-8"))
    assert "Name: Pat Example" in entries
    # Not on the machine (no account name there): nothing.
    monkeypatch.setattr(projection, "account_full_name", lambda: "")
    other = ClaimStore(ledger_dir / "cloud")
    assert projection.project(other, "user")["seeded_name"] is None
    assert other.live("user") == []


def test_account_full_name_is_a_real_name_or_nothing(monkeypatch):
    import subprocess
    real = projection.account_full_name_unpatched   # the conftest stubs the live one
    class Out:
        def __init__(self, stdout, rc=0): self.stdout, self.returncode = stdout, rc
    monkeypatch.setattr(projection.sys, "platform", "darwin")
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: Out("Pat Example\n"))
    assert real() == "Pat Example"
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: Out("patexample\n"))
    assert real() == ""
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: Out("", rc=1))
    assert real() == ""
    monkeypatch.setattr(projection.sys, "platform", "linux")
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: Out("Pat Example\n"))
    assert real() == ""
