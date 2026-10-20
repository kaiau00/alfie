"""LEDGER-WIRE §13 on the Mac's side: sealed claims, the shared key, the
§13.1 migration, and ``document`` records through this provider.

Everything runs in temp directories; ``moeledger`` is the sibling plugin's
library, loaded the way ``claimstore._sibling`` loads it.
"""

from __future__ import annotations

import json
import logging
import os
import time

import pytest

import claimstore
from claimstore import projection
from claimstore.store import ordered as store_ordered
from claimstore.store import (ASSERT, ClaimStore, MEMORY_KEY_ID, claim_id, parse_claim,
                              record_id)

from moeledger import documents, threadcrypto
from moeledger.records import decode_line
from moeledger.vault import Keyring


# -- §13.2 the key, §13.4 the sealed body --------------------------------------------

def test_a_claim_is_sealed_under_moe_memory_and_its_id_is_over_the_plaintext(
        ledger_dir, memory_key, tmp_path):
    store = ClaimStore(ledger_dir, device="mac-9f3c1a2b", state_dir=tmp_path / "h", key=memory_key)
    assert store.seals
    cid = store.assert_claim("memory", "I work at Kaplan", source="user", key="job")
    line = store.path.read_text(encoding="utf-8").splitlines()[0]
    record = json.loads(line)
    body = record["body"]
    assert set(body) == {"op", "claim", "target", "key", "source", "enc", "text_enc"}
    assert body["enc"] == "aes-gcm-256.v1" and "text" not in body
    assert body["claim"] == cid == claim_id("memory", "I work at Kaplan")
    assert body["key"] == "job" and body["source"] == "user"       # labels stay clear
    assert "Kaplan" not in line
    # §1.7 exactly: the sibling's primitive opens it, and moeledger's decoder
    # reads the line as a record that is not plaintext.
    assert threadcrypto.open_sealed(body["text_enc"], memory_key) == "I work at Kaplan"
    decoded = decode_line(line)
    assert decoded is not None and not decoded.is_plaintext and decoded.is_content_addressed
    assert record_id({k: v for k, v in record.items() if k != "id"}) == record["id"]
    # And this reader, holding the key, projects it.
    assert store.live("memory") == ["I work at Kaplan"]


def test_a_retract_carries_the_id_and_no_text(ledger_dir, memory_key, tmp_path):
    store = ClaimStore(ledger_dir, device="mac-9f3c1a2b", state_dir=tmp_path / "h", key=memory_key)
    store.assert_claim("memory", "likes tea", source="user")
    store.retract_claim("memory", "likes tea", source="user")
    retract = json.loads(store.path.read_text(encoding="utf-8").splitlines()[1])["body"]
    assert retract["op"] == "retract" and retract["claim"] == claim_id("memory", "likes tea")
    assert "text" not in retract and "text_enc" not in retract
    assert store.live("memory") == []


def test_without_the_key_a_sealed_claim_is_present_but_unreadable(ledger_dir, memory_key,
                                                                    tmp_path):
    """§13.4: counted, never projected, never retracted on the person's behalf."""
    writer = ClaimStore(ledger_dir, device="mac-9f3c1a2b", state_dir=tmp_path / "w",
                        key=memory_key)
    cid = writer.assert_claim("memory", "I work at Kaplan", source="user")
    writer.assert_claim("memory", "the deploy is on Friday", source="gmail")

    blind = ClaimStore(ledger_dir, device="mac-bbbbbbbb", state_dir=tmp_path / "b")
    assert blind.key is None and not blind.seals
    assert blind.live("memory") == [], "never projected"
    assert blind.unreadable("memory") == [cid, claim_id("memory", "the deploy is on Friday")]
    assert len(blind.claim_records("memory")) == 2, "still counted"
    # Not retracted on the person's behalf: the reader cannot address it.
    assert blind.retract_claim("memory", "I work at Kaplan", source="user") is None
    assert projection.retract_addressed(blind, "memory", "Kaplan", source="user") == []
    # Re-stating it adds no plaintext copy either: the fact is already there.
    assert blind.assert_claim("memory", "I work at Kaplan", source="user") == cid
    assert len(blind.claim_records("memory")) == 2
    # Matched to its retract by id, even blind: a retract from a key holder
    # takes the claim out of the unreadable set too.
    writer.retract_claim("memory", "I work at Kaplan", source="user")
    blind.refresh()
    assert blind.unreadable("memory") == [claim_id("memory", "the deploy is on Friday")]
    # The key arrives (the courier delivered it): readable at once.
    with_key = ClaimStore(ledger_dir, device="mac-bbbbbbbb", state_dir=tmp_path / "b",
                          key=memory_key)
    assert with_key.live("memory") == ["the deploy is on Friday"]
    assert with_key.unreadable("memory") == []


def test_a_readable_copy_lends_its_text_to_a_sealed_one(ledger_dir, memory_key, tmp_path):
    """One claim id is one sentence: a plaintext legacy record and a sealed
    copy of the same claim resolve to one readable claim without the key."""
    plain = ClaimStore(ledger_dir, device="hermes-EXAMPLE02", state_dir=tmp_path / "p")
    plain.assert_claim("memory", "I work at Kaplan", source="user")
    sealed = ClaimStore(ledger_dir, device="mac-9f3c1a2b", state_dir=tmp_path / "s",
                        key=memory_key)
    sealed.append("claim", sealed.claim_body(ASSERT, claim_id("memory", "I work at Kaplan"),
                                             "memory", "user", "I work at Kaplan"))
    blind = ClaimStore(ledger_dir, device="mac-cccccccc", state_dir=tmp_path / "b")
    assert blind.live("memory") == ["I work at Kaplan"]
    assert blind.unreadable("memory") == []


def test_parse_claim_reads_id_as_well_as_claim():
    """§13.4's sketch names the field ``id``; Claims.swift and this store
    write ``claim``. Both read."""
    record = {"kind": "claim", "body": {"op": "assert", "id": "abc123abc123", "target": "user",
                                        "text": "x"}}
    assert parse_claim(record)["claim"] == "abc123abc123"


def test_the_keyring_is_shared_with_the_app_file_wins(ledger_dir):
    """§13.2: whichever writer first needs ``moe:memory`` mints it; the other
    finds it in ``thread-keys.json`` under the same lock (``.fileWins``)."""
    swift = Keyring(ledger_dir / "thread-keys.json")       # the app's ThreadKeyring
    python = Keyring(ledger_dir / "thread-keys.json")      # this plugin's
    first = python.mint_key(MEMORY_KEY_ID)
    assert swift.mint_key(MEMORY_KEY_ID) == first
    assert swift.key(MEMORY_KEY_ID) == python.key(MEMORY_KEY_ID) == first
    assert (ledger_dir / "thread-keys.json.lock").exists()
    assert os.stat(str(ledger_dir / "thread-keys.json")).st_mode & 0o777 == 0o600
    data = json.loads((ledger_dir / "thread-keys.json").read_text(encoding="utf-8"))
    assert set(data) == {"README", "keys", "version"} and MEMORY_KEY_ID in data["keys"]
    # Never destroyed (§13.2).
    swift.destroy_key(MEMORY_KEY_ID)
    assert python.key(MEMORY_KEY_ID) == first


def test_the_provider_mints_the_key_and_seals_from_the_first_write(provider, ledger_dir):
    assert provider.keyring is not None
    assert provider.keyring.key(MEMORY_KEY_ID) is not None
    provider.on_memory_write("add", "memory", "a sealed fact", {"write_origin": "assistant_tool"})
    lines = (ledger_dir / (provider.store.device + ".jsonl")).read_text(encoding="utf-8")
    claim_lines = [json.loads(l) for l in lines.splitlines() if '"kind":"claim"' in l]
    assert claim_lines and all("text_enc" in r["body"] and "text" not in r["body"]
                               for r in claim_lines)
    assert "a sealed fact" not in lines
    assert provider.store.live("memory") == ["a sealed fact"]


# -- §13.1 migration -------------------------------------------------------------------

def _legacy_file(ledger_dir, device, entries):
    """A pre-§13.1 claimstore file: plaintext claims on its own chain.
    ``entries`` are (op, target, text, source, key)."""
    from claimstore.store import canonical_json, unsigned_fields

    ledger_dir.mkdir(parents=True, exist_ok=True)
    lines, prev, ids = [], None, []
    for seq, (op, target, text, source, key) in enumerate(entries, start=1):
        body = {"op": op, "claim": claim_id(target, text), "target": target, "source": source}
        if op == "assert":
            body["text"] = text
        if key:
            body["key"] = key
        unsigned = unsigned_fields("claim", "2026-08-30T10:%02d:00.000Z" % seq, device, seq,
                                   prev, [], body)
        rid = record_id(unsigned)
        lines.append(canonical_json(dict(unsigned, id=rid)))
        prev = rid
        ids.append(rid)
    (ledger_dir / (device + ".jsonl")).write_text("\n".join(lines) + "\n", encoding="utf-8")
    return ids


def _peer_turn_file(ledger_dir, device):
    from claimstore.store import canonical_json, unsigned_fields

    unsigned = unsigned_fields("turn", "2026-08-30T11:00:00.000Z", device, 1, None, [],
                               {"thread": "T", "turn_id": "x", "role": "you",
                                "at": "2026-08-30T11:00:00.000Z", "enc": "aes-gcm-256.v1",
                                "text_enc": "QUJD"})
    line = canonical_json(dict(unsigned, id=record_id(unsigned)))
    (ledger_dir / (device + ".jsonl")).write_text(line + "\n", encoding="utf-8")
    return line


@pytest.fixture
def legacy_ledger(ledger_dir, tmp_path):
    """A Mac that ran the old plugin: its ``hermes-EXAMPLE02`` claims, the
    app's ``device.json``, and an enrolled machine ``hermes-EXAMPLE01`` whose
    file holds turns and whose id is in the peer book."""
    ledger_dir.mkdir(parents=True)
    (ledger_dir / "device.json").write_text(json.dumps({"id": "mac-9f3c1a2b"}), encoding="utf-8")
    legacy_ids = _legacy_file(ledger_dir, "hermes-EXAMPLE02", [
        ("assert", "memory", "I work at Kaplan", "hermes:assistant_tool", "job"),
        ("assert", "memory", "deploys run on Fridays", "gmail", None),
        ("retract", "memory", "deploys run on Fridays", "user", None),
        ("assert", "user", "prefers terse answers", "file", None),
    ])
    peer_line = _peer_turn_file(ledger_dir, "hermes-EXAMPLE01")
    # A Mac that enrolled a machine has a keyring (it sealed thread keys to
    # the joiner); without one beside a peer book the §13.2 mint guard would
    # read this as a lost keyring and wait rather than mint.
    Keyring(ledger_dir / "thread-keys.json").mint_key("6F0C1A2B-THREAD")
    cloud = tmp_path / "moe" / "cloud"
    cloud.mkdir(parents=True)
    (cloud / "peers.json").write_text(json.dumps({
        "version": 1, "peers": {"hermes-EXAMPLE01": {"identity_pub": "x", "signing_pub": "y",
                                                     "added_at": 1.0}}}), encoding="utf-8")
    return {"legacy_ids": legacy_ids, "peer_line": peer_line, "peers": cloud / "peers.json"}


def test_migration_reasserts_live_legacy_claims_sealed_under_the_shared_id_once(
        hermes_home, ledger_dir, legacy_ledger, monkeypatch, caplog):
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    p = claimstore.ClaimStoreProvider()
    p.initialize("s1", hermes_home=str(hermes_home), agent_context="primary")

    assert p.store.device == "mac-9f3c1a2b"
    marker = json.loads((ledger_dir / "claimstore-migrated.json").read_text(encoding="utf-8"))
    assert marker["from"] == ["hermes-EXAMPLE02"] and marker["claims"] == 2
    assert marker["retractions"] == 1
    assert len(marker["at"]) == 24
    mine = [json.loads(l) for l in (ledger_dir / "mac-9f3c1a2b.jsonl")
            .read_text(encoding="utf-8").splitlines()]
    migrated = [r for r in mine if r["kind"] == "claim" and r["body"]["op"] == "assert"]
    assert len(migrated) == 2, "only what is live is re-asserted"
    # The deletion travels too: one retract, after the legacy tombstone, no
    # text, source preserved — so a machine that never held the old file
    # still knows "deploys run on Fridays" was deleted.
    tombstones = [r for r in mine if r["kind"] == "claim" and r["body"]["op"] == "retract"]
    assert len(tombstones) == 1
    assert tombstones[0]["body"] == {"op": "retract", "target": "memory", "source": "user",
                                     "claim": claim_id("memory", "deploys run on Fridays")}
    assert tombstones[0]["after"] == [legacy_ledger["legacy_ids"][2]]
    by_text = {}
    key = p.keyring.key(MEMORY_KEY_ID)
    for r in migrated:
        body = r["body"]
        assert "text_enc" in body and "text" not in body, "sealed"
        by_text[threadcrypto.open_sealed(body["text_enc"], key)] = r
    assert set(by_text) == {"I work at Kaplan", "prefers terse answers"}
    kaplan = by_text["I work at Kaplan"]
    assert kaplan["body"]["source"] == "hermes:assistant_tool", "source preserved"
    assert kaplan["body"]["key"] == "job"
    assert kaplan["after"] == [legacy_ledger["legacy_ids"][0]], "after names the legacy record"
    assert kaplan["body"]["claim"] == claim_id("memory", "I work at Kaplan")
    # The legacy file is left in place; the peer's file is untouched.
    assert (ledger_dir / "hermes-EXAMPLE02.jsonl").exists()
    assert (ledger_dir / "hermes-EXAMPLE01.jsonl").read_text(encoding="utf-8").strip() \
        == legacy_ledger["peer_line"]
    # Resolution treats old and new as one claim: nothing doubled.
    assert p.store.live("memory") == ["I work at Kaplan"]
    assert p.store.live("user") == ["prefers terse answers"]

    # Idempotent: a second start appends nothing.
    before = (ledger_dir / "mac-9f3c1a2b.jsonl").read_text(encoding="utf-8")
    q = claimstore.ClaimStoreProvider()
    q.initialize("s2", hermes_home=str(hermes_home), agent_context="primary")
    assert q.store.migrate_legacy(legacy_ledger["peers"])["skipped"] == "already migrated"
    after = (ledger_dir / "mac-9f3c1a2b.jsonl").read_text(encoding="utf-8")
    assert [json.loads(l)["body"].get("claim") for l in after.splitlines()
            if '"kind":"claim"' in l] == [json.loads(l)["body"].get("claim")
                                          for l in before.splitlines() if '"kind":"claim"' in l]


def test_migration_falls_back_to_content_when_the_peer_book_is_unreadable(
        ledger_dir, legacy_ledger, tmp_path, memory_key, caplog):
    legacy_ledger["peers"].write_text("{not json", encoding="utf-8")
    store = ClaimStore(ledger_dir, state_dir=tmp_path / "h", key=memory_key)
    with caplog.at_level(logging.WARNING, logger="claimstore.store"):
        report = store.migrate_legacy(legacy_ledger["peers"])
    assert report["from"] == ["hermes-EXAMPLE02"], "the turn-holding peer file is still skipped"
    assert any("peer book" in m and "unreadable" in m for m in caplog.messages)


def test_migration_waits_for_a_key_rather_than_writing_plaintext(ledger_dir, legacy_ledger,
                                                                  tmp_path):
    store = ClaimStore(ledger_dir, state_dir=tmp_path / "h")
    report = store.migrate_legacy(legacy_ledger["peers"])
    assert report["skipped"].startswith("no moe:memory key")
    assert not (ledger_dir / "claimstore-migrated.json").exists()
    assert not (ledger_dir / "mac-9f3c1a2b.jsonl").exists()


# -- §13.5 documents -------------------------------------------------------------------

def _document_records(store):
    return [r for r in store.records() if r["kind"] == "document"]


def test_the_writer_seals_each_changed_source_at_initialize_and_session_end(
        hermes_home, ledger_dir, moe_home, monkeypatch):
    (hermes_home / "SOUL.md").write_text("Be brief.", encoding="utf-8")
    (moe_home / "CLAUDE.md").write_text("You are Moe.", encoding="utf-8")
    profile = moe_home / "memory" / "profile"
    profile.mkdir(parents=True)
    (profile / "people.md").write_text("# People\nDana — sister\n", encoding="utf-8")
    (profile / ".keys.json").write_text('{"people": ["dana"]}', encoding="utf-8")
    (hermes_home / "config.yaml").write_text("skills:\n  disabled: [weather, zeta, weather]\n",
                                            encoding="utf-8")
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    p = claimstore.ClaimStoreProvider()
    p.initialize("s1", hermes_home=str(hermes_home), agent_context="primary")

    key = p.keyring.key(MEMORY_KEY_ID)
    docs = {r["body"]["name"]: r for r in _document_records(p.store)}
    # The §14.4a capability tables are deliberately NOT here: asking every
    # connector its own `status` is 2.25 s on a real Mac, and session-start
    # is the notch's first turn. They arrive at session end, below.
    assert set(docs) == {"soul", "who", "profile/people.md", "profile/.keys.json",
                         "hermes/skills-disabled"}
    for name, record in docs.items():
        body = record["body"]
        assert set(body) == {"name", "bytes", "enc", "text_enc"}, "no hash on the wire"
        assert body["enc"] == "aes-gcm-256.v1"
        text = threadcrypto.open_sealed(body["text_enc"], key)
        assert body["bytes"] == len(text.encode("utf-8"))
    assert threadcrypto.open_sealed(docs["soul"]["body"]["text_enc"], key) == "Be brief."
    assert threadcrypto.open_sealed(docs["hermes/skills-disabled"]["body"]["text_enc"], key) \
        == '["weather","zeta"]', "sorted, deduplicated, compact"
    assert "Dana" not in (ledger_dir / (p.store.device + ".jsonl")).read_text(encoding="utf-8")
    state = json.loads((hermes_home / "claimstore-documents.json").read_text(encoding="utf-8"))
    assert state["documents"]["who"] == documents.sha256_hex("You are Moe.")

    # Session end: the two capability tables arrive, off the critical path.
    # An empty tree honestly produces empty ones — this fixture has no
    # connectors and no mcp_servers. Empty is a real answer and not the same
    # as absent: the reader treats a table it has as authority, and a target
    # missing from one as silence (§14.4a, "an omission does not").
    p.on_session_end([])
    docs = {r["body"]["name"]: r for r in _document_records(p.store)}
    assert set(docs) == {"soul", "who", "profile/people.md", "profile/.keys.json",
                         "hermes/skills-disabled",
                         "capability/connector", "capability/mcp"}
    for via in ("connector", "mcp"):
        text = threadcrypto.open_sealed(docs["capability/" + via]["body"]["text_enc"], key)
        assert json.loads(text) == {}

    # And a second session end with nothing changed writes nothing at all —
    # or a table nobody touched would be republished on every session. It is
    # `table_text`'s canonical JSON and the cache's fingerprint that keep it
    # stable.
    p.on_session_end([])
    assert len(_document_records(p.store)) == 7
    (moe_home / "CLAUDE.md").write_text("You are Moe, and terse.", encoding="utf-8")
    p.on_session_end([])
    records = _document_records(p.store)
    assert len(records) == 8 and records[-1]["body"]["name"] == "who"
    # A removed source becomes a removal record.
    (profile / ".keys.json").unlink()
    p.shutdown()
    last = _document_records(p.store)[-1]["body"]
    assert last == {"name": "profile/.keys.json", "bytes": 0, "enc": "aes-gcm-256.v1",
                    "text_enc": ""}


def test_the_writer_skips_a_document_over_256_kb_and_says_so(hermes_home, ledger_dir, moe_home,
                                                              monkeypatch, caplog):
    (moe_home / "CLAUDE.md").write_text("x" * (256 * 1024 + 1), encoding="utf-8")
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    p = claimstore.ClaimStoreProvider()
    with caplog.at_level(logging.WARNING):
        p.initialize("s1", hermes_home=str(hermes_home), agent_context="primary")
    assert "who" not in {r["body"]["name"] for r in _document_records(p.store)}
    assert any("over the 262144-byte cap" in m for m in caplog.messages)
    # Exactly the cap is fine.
    (moe_home / "CLAUDE.md").write_text("x" * (256 * 1024), encoding="utf-8")
    p.on_session_end([])
    assert "who" in {r["body"]["name"] for r in _document_records(p.store)}


def test_the_reader_applies_what_the_app_pulled_including_removal_and_skills(
        hermes_home, ledger_dir, moe_home, monkeypatch, memory_key):
    """The app's CloudSync pulls records into the ledger dir; claimstore's
    stat-based refresh sees them at initialize and at prefetch."""
    (hermes_home / "config.yaml").write_text("skills:\n  disabled: [old]\nother: 1\n",
                                            encoding="utf-8")
    (moe_home / "memory" / "profile").mkdir(parents=True)
    (moe_home / "memory" / "profile" / "threads.md").write_text("stale", encoding="utf-8")
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    p = claimstore.ClaimStoreProvider()
    p.initialize("s1", hermes_home=str(hermes_home), agent_context="primary")

    # Another device's records arrive (the app adopted them into its file),
    # stamped a second later than the provider's own initialize-time writes.
    #
    # The explicit `at` is the point of this comment. "Latest in ledger order
    # wins" (§13.5) falls back to the record id when two documents of one name
    # share a millisecond, and an id is a hash over a randomly-nonced
    # ciphertext — so a tie is decided afresh on every run. That is *correct*
    # for the product: every device hashes the same bytes and so picks the
    # same winner, which is what convergence needs. It is useless in a test,
    # which would be asserting a coin flip. Two devices a second apart is also
    # what the real case looks like.
    later = time.time() + 1
    other = ClaimStore(ledger_dir, device="hermes-EXAMPLE01", state_dir=hermes_home / "o",
                       key=memory_key)
    other.append("document", documents.document_body("who", "You are Moe, from afar.", memory_key),
                 at=later)
    other.append("document", documents.document_body("profile/people.md", "# People\nRemote\n",
                                                     memory_key), at=later)
    other.append("document", documents.document_body("profile/threads.md", None, memory_key),
                 at=later)
    other.append("document", documents.document_body("hermes/skills-disabled",
                                                     '["weather","zeta"]', memory_key), at=later)
    p.prefetch("what is on the calendar for the review")     # refresh sees the new records
    assert (moe_home / "AGENTS.md").read_text(encoding="utf-8") == "You are Moe, from afar."
    assert os.stat(str(moe_home / "AGENTS.md")).st_mode & 0o777 == 0o600
    assert (moe_home / "memory" / "profile" / "people.md").read_text(encoding="utf-8") \
        == "# People\nRemote\n"
    assert not (moe_home / "memory" / "profile" / "threads.md").exists(), "bytes: 0 removes"
    import yaml

    config = yaml.safe_load((hermes_home / "config.yaml").read_text(encoding="utf-8"))
    assert config["skills"]["disabled"] == ["weather", "zeta"] and config["other"] == 1
    state = json.loads((hermes_home / "claimstore-documents.json").read_text(encoding="utf-8"))
    assert state["documents"]["who"] == documents.sha256_hex("You are Moe, from afar.")
    assert state["documents"]["profile/threads.md"] == documents.sha256_hex("")

    # Applied, so not re-written by the writer at session end. Counted
    # without the §14.4a capability tables, which this session has not
    # published yet and which are about this Mac's own hands rather than
    # about anything that arrived — a different question from the one this
    # assertion asks.
    def files_written():
        return [r for r in _document_records(p.store)
                if not r["body"]["name"].startswith("capability/")]

    before = len(files_written())
    p.on_session_end([])
    assert len(files_written()) == before
    # ...and a local edit after that is carried, not clobbered.
    (moe_home / "AGENTS.md").write_text("You are Moe, edited here.", encoding="utf-8")
    p.on_session_end([])
    last = _document_records(p.store)[-1]["body"]
    assert last["name"] == "who"
    assert threadcrypto.open_sealed(last["text_enc"], memory_key) == "You are Moe, edited here."
    assert (moe_home / "AGENTS.md").read_text(encoding="utf-8") == "You are Moe, edited here."


def test_a_document_without_the_key_is_not_applied_until_the_key_arrives(
        hermes_home, ledger_dir, moe_home, monkeypatch, tmp_path):
    other_key = os.urandom(32)
    other = ClaimStore(ledger_dir, device="hermes-EXAMPLE01", state_dir=tmp_path / "o",
                       key=other_key)
    other.append("document", documents.document_body("who", "sealed elsewhere", other_key))
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    p = claimstore.ClaimStoreProvider()
    p.initialize("s1", hermes_home=str(hermes_home), agent_context="primary")
    assert not (moe_home / "AGENTS.md").exists()
    # The key is installed (a courier delivery): the next look applies it.
    p.keyring.install_key(MEMORY_KEY_ID, other_key)
    p.store.refresh()
    p._apply_documents("test")
    assert (moe_home / "AGENTS.md").read_text(encoding="utf-8") == "sealed elsewhere"


def test_a_cron_session_applies_documents_but_writes_none(hermes_home, ledger_dir, moe_home,
                                                          monkeypatch, memory_key, tmp_path):
    other = ClaimStore(ledger_dir, device="hermes-EXAMPLE01", state_dir=tmp_path / "o",
                       key=memory_key)
    other.append("document", documents.document_body("who", "from the machine", memory_key))
    (hermes_home / "SOUL.md").write_text("local persona", encoding="utf-8")
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    p = claimstore.ClaimStoreProvider()
    p.initialize("s1", hermes_home=str(hermes_home), agent_context="cron")
    assert (moe_home / "AGENTS.md").read_text(encoding="utf-8") == "from the machine"
    assert [r for r in p.store.records() if r.get("device") == p.store.device] == []


def test_two_devices_that_tie_on_a_document_still_agree_on_the_winner(
        hermes_home, ledger_dir, moe_home, memory_key):
    """§13.5's "latest wins" has to answer the tie, and its answer is a hash.

    When two devices write the same document name in the same millisecond
    there is no "later", so the order falls through to the record id — a
    hash over bytes that include a random nonce. Which one wins is therefore
    arbitrary. What must never be arbitrary is that *both devices pick the
    same one*: an ordering that differed per reader would leave two Macs
    quietly holding different files with no way to notice. This is that
    property, and it is the reason the arbitrary tie is acceptable rather
    than a bug to chase.
    """
    same = time.time()
    a = ClaimStore(ledger_dir, device="mac-aaaaaaaa", state_dir=hermes_home / "a", key=memory_key)
    b = ClaimStore(ledger_dir, device="hermes-bbbbbbbb", state_dir=hermes_home / "b",
                   key=memory_key)
    a.append("document", documents.document_body("who", "written on the Mac", memory_key), at=same)
    b.append("document", documents.document_body("who", "written on the machine", memory_key),
             at=same)

    raw = a.records()
    assert len({r["id"] for r in raw if r["kind"] == "document"}) == 2

    def winner(shuffled):
        bodies = [r["body"] for r in store_ordered(shuffled) if r["kind"] == "document"]
        return documents.newest_documents(bodies, memory_key)["who"].text

    forwards = winner(list(raw))
    backwards = winner(list(reversed(raw)))
    assert forwards == backwards, "two readers of one ledger disagreed on the winner"
    assert forwards in ("written on the Mac", "written on the machine")
