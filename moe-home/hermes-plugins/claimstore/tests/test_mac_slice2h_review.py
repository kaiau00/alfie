"""The slice 2½ review's findings, on the Mac side — each one reproduced by
a sceptical reader and each one a test here that failed before the fix.

1. Legacy retractions never travelled (``migrate_legacy`` moved live
   winners only), so a fact the person deleted pre-slice came back live on
   the machine when the model restated it.
4. ``moe:memory`` was minted whenever it was absent — including when the
   keyring had been lost, which would have split the tenant's memory in two.
6. Memory text reached the logs (``old_text`` with ``%r``; the projection
   report with ``asked[].text`` at DEBUG).
8. The plugin's cache hid an app record appended between its last refresh
   and its own append.
11. An empty ``text_enc`` on a claim was read as a plaintext claim.
"""

from __future__ import annotations

import json
import logging
import os
import shutil

import claimstore
from claimstore.store import (ASSERT, ClaimStore, MEMORY_KEY_ID, canonical_json, claim_id,
                              parse_claim, record_id, resolve, unsigned_fields)
from moeledger.vault import Keyring


# -- 8. cache coherence with the app's appends -----------------------------------------------

def _app_appends_turn(ledger_dir, device: str, n: int) -> None:
    """What ``Ledger.swift`` does: under the §13.1 lock, head from the file,
    one O_APPEND write. The plugin is not told."""
    from claimstore.store import _flock

    path = ledger_dir / (device + ".jsonl")
    with _flock(ledger_dir / (device + ".jsonl.lock")):
        lines = [l for l in path.read_text(encoding="utf-8").splitlines() if l.strip()] \
            if path.exists() else []
        head = max((json.loads(l) for l in lines), key=lambda r: r["seq"], default=None)
        seq = (head["seq"] if head else 0) + 1
        unsigned = unsigned_fields("turn", "2026-09-02T10:00:%02d.000Z" % seq, device, seq,
                                   head["id"] if head else None, [],
                                   {"thread": "T", "turn_id": "x%d" % n, "role": "you",
                                    "at": "2026-09-02T10:00:00.000Z", "enc": "aes-gcm-256.v1",
                                    "text_enc": "QUJD"})
        record = dict(unsigned, id=record_id(unsigned))
        fd = os.open(str(path), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, (canonical_json(record) + "\n").encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)


def test_an_app_record_landing_between_refresh_and_append_is_seen(ledger_dir, tmp_path):
    ledger_dir.mkdir(parents=True)
    (ledger_dir / "device.json").write_text(json.dumps({"id": "mac-9f3c1a2b"}), encoding="utf-8")
    store = ClaimStore(ledger_dir, state_dir=tmp_path / "h")
    store.assert_claim("memory", "zero", source="test")
    store.refresh()
    store.assert_claim("memory", "one", source="test")     # refresh + append: cache stamped
    _app_appends_turn(ledger_dir, "mac-9f3c1a2b", 1)      # the app appends seq 3, unseen
    store.assert_claim("memory", "two", source="test")     # head re-read from the file...
    store.refresh()                                        # ...and the cache must not hide it
    on_disk = len([l for l in (ledger_dir / "mac-9f3c1a2b.jsonl").read_text(encoding="utf-8")
                   .splitlines() if l.strip()])
    assert len(store.records()) == on_disk == 4
    assert any(r["kind"] == "turn" for r in store.records()), "the app's record is visible"
    assert [r["seq"] for r in store.records() if r["device"] == "mac-9f3c1a2b"] == [1, 2, 3, 4]
    assert store.forked_seqs() == []


# -- 1. legacy retractions travel --------------------------------------------------------------

def test_a_pre_slice_deletion_reaches_the_machine_and_a_restatement_is_a_question_on_both(
        tmp_path, memory_key, ledger_dir):
    """probe3: the person deleted "I live in Boston" under the old id. After
    migration the Mac's own file — the only thing that travels — must carry
    that tombstone, so the model restating it on the machine is a pending
    question there *and* here, never a live fact anywhere."""
    mac = ledger_dir                                   # made by the memory_key fixture
    machine = tmp_path / "machine" / "ledger"
    machine.mkdir(parents=True)
    (mac / "device.json").write_text(json.dumps({"id": "mac-aaaaaaaa"}), encoding="utf-8")
    legacy = ClaimStore(mac, device="hermes-legacy1", state_dir=tmp_path / "h1")
    legacy.assert_claim("memory", "I live in Boston", source="user")
    legacy.retract_claim("memory", "I live in Boston", source="user")
    legacy.assert_claim("memory", "I like tea", source="user")
    legacy_tombstone = [r for r in legacy.records() if r["body"]["op"] == "retract"][0]

    macstore = ClaimStore(mac, state_dir=tmp_path / "h2", key=memory_key)
    report = macstore.migrate_legacy(None)
    assert report["claims"] == 1 and report["retractions"] == 1
    mine = [r for r in macstore.records() if r["device"] == "mac-aaaaaaaa"]
    tombstones = [r for r in mine if r["body"]["op"] == "retract"]
    assert len(tombstones) == 1
    assert tombstones[0]["after"] == [legacy_tombstone["id"]]
    assert tombstones[0]["body"]["source"] == "user"
    assert "text" not in tombstones[0]["body"] and "text_enc" not in tombstones[0]["body"]
    marker = json.loads((mac / "claimstore-migrated.json").read_text(encoding="utf-8"))
    assert marker["retractions"] == 1 and marker["claims"] == 1

    # Only the Mac's own file travels.
    shutil.copy(mac / "mac-aaaaaaaa.jsonl", machine / "mac-aaaaaaaa.jsonl")
    m = ClaimStore(machine, device="hermes-machine1", state_dir=tmp_path / "h3", key=memory_key)
    assert m.live("memory") == ["I like tea"]
    m.assert_claim("memory", "I live in Boston", source="hermes:assistant_tool")
    assert m.live("memory") == ["I like tea"], "not revived by the model"
    assert [q.text for q in m.resolve("memory").pending_revivals] == ["I live in Boston"]

    shutil.copy(machine / "hermes-machine1.jsonl", mac / "hermes-machine1.jsonl")
    back = ClaimStore(mac, state_dir=tmp_path / "h2", key=memory_key)
    projection = back.resolve("memory")
    assert projection.texts == ["I like tea"]
    assert [q.text for q in projection.pending_revivals] == ["I live in Boston"]

    # And running the migration again changes nothing.
    assert back.migrate_legacy(None)["skipped"] == "already migrated"


def test_migration_does_not_retract_what_the_person_revived_or_what_already_travels(
        tmp_path, memory_key, ledger_dir):
    """A legacy tombstone the person later overrode is not re-issued (the
    claim is live); a tombstone the app already wrote under the shared id
    already travels and is not doubled."""
    (ledger_dir / "device.json").write_text(json.dumps({"id": "mac-aaaaaaaa"}), encoding="utf-8")
    legacy = ClaimStore(ledger_dir, device="hermes-legacy1", state_dir=tmp_path / "h1")
    legacy.assert_claim("memory", "revived later", source="user")
    legacy.retract_claim("memory", "revived later", source="user")
    legacy.assert_claim("memory", "revived later", source="user")     # the person, again
    legacy.assert_claim("memory", "gone for good", source="user")
    app = ClaimStore(ledger_dir, state_dir=tmp_path / "app", key=memory_key)
    app.retract_claim("memory", "gone for good", source="user")       # under the shared id
    mac = ClaimStore(ledger_dir, state_dir=tmp_path / "h2", key=memory_key)
    report = mac.migrate_legacy(None)
    assert report["claims"] == 1 and report["retractions"] == 0
    assert mac.live("memory") == ["revived later"]


# -- 4. the mint guard --------------------------------------------------------------------------

def _mac_provider(ledger_dir, hermes_home, monkeypatch, peers_path):
    monkeypatch.setattr(claimstore, "_config",
                        lambda: {"ledger_dir": str(ledger_dir), "peers_path": str(peers_path)})
    p = claimstore.ClaimStoreProvider()
    p.initialize("s1", hermes_home=str(hermes_home), agent_context="primary")
    return p


def _peer_book(path, *devices):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"version": 1, "peers": {
        d: {"identity_pub": "x", "signing_pub": "y", "added_at": 1.0} for d in devices}}),
        encoding="utf-8")


def test_mint_guard_first_run_mints(ledger_dir, hermes_home, monkeypatch, tmp_path, caplog):
    """No keyring, no peers: a Mac that has never enrolled anything. Mint."""
    peers = tmp_path / "moe" / "cloud" / "peers.json"
    with caplog.at_level(logging.WARNING):
        p = _mac_provider(ledger_dir, hermes_home, monkeypatch, peers)
    assert p.keyring.key(MEMORY_KEY_ID) is not None
    assert not any("waiting for moe:memory" in m for m in caplog.messages)


def test_mint_guard_live_tenant_without_memory_yet_mints(ledger_dir, hermes_home, monkeypatch,
                                                         tmp_path, caplog):
    """Keyring present with thread keys, a peer enrolled, no ``moe:memory``
    yet: the ordinary tenant meeting this slice for the first time. MUST
    mint, or memory never starts."""
    Keyring(ledger_dir / "thread-keys.json").mint_key("0F1E2D3C-THREAD")
    peers = tmp_path / "moe" / "cloud" / "peers.json"
    _peer_book(peers, "hermes-EXAMPLE01")
    with caplog.at_level(logging.WARNING):
        p = _mac_provider(ledger_dir, hermes_home, monkeypatch, peers)
    assert p.keyring.key(MEMORY_KEY_ID) is not None
    assert p.keyring.key("0F1E2D3C-THREAD") is not None, "the thread key is untouched"
    assert not any("waiting for moe:memory" in m for m in caplog.messages)
    p.on_memory_write("add", "memory", "sealed from the first write", {})
    assert p.store.live("memory") == ["sealed from the first write"]


def test_mint_guard_lost_keyring_beside_a_peer_waits(ledger_dir, hermes_home, monkeypatch,
                                                     tmp_path, caplog):
    """No keyring file but a peer book naming a machine: the keys were lost,
    not never made. A second mint would seal this Mac's memory under a key
    the machine — which still holds the first — cannot open. Wait for the
    machine's hourly reseal to return it."""
    peers = tmp_path / "moe" / "cloud" / "peers.json"
    _peer_book(peers, "hermes-EXAMPLE01")
    with caplog.at_level(logging.WARNING):
        p = _mac_provider(ledger_dir, hermes_home, monkeypatch, peers)
    assert p.keyring.key(MEMORY_KEY_ID) is None
    assert not (ledger_dir / "thread-keys.json").exists(), "nothing was written"
    assert any("waiting for moe:memory to come back from a peer" in m for m in caplog.messages)
    # Writes still work — plaintext and local (§13.3) — until it arrives.
    p.on_memory_write("add", "memory", "kept locally", {})
    assert p.store.live("memory") == ["kept locally"]
    line = (ledger_dir / (p.store.device + ".jsonl")).read_text(encoding="utf-8")
    assert '"text":"kept locally"' in line and "text_enc" not in line
    # The reseal returns it: the courier installs, the next session seals.
    Keyring(ledger_dir / "thread-keys.json").install_key(MEMORY_KEY_ID, os.urandom(32))
    q = _mac_provider(ledger_dir, hermes_home, monkeypatch, peers)
    assert q.keyring.key(MEMORY_KEY_ID) == p.keyring.key(MEMORY_KEY_ID)


def test_mint_guard_damaged_keyring_beside_a_peer_waits(ledger_dir, hermes_home, monkeypatch,
                                                        tmp_path, caplog):
    """The app set aside a keyring it could not parse as
    ``thread-keys.json.damaged.<stamp>``: its keys are in that file and on
    the peer. Do not mint over it — even when the app has since re-created
    a fresh keyring beside the marker."""
    ledger_dir.mkdir(parents=True)
    (ledger_dir / "thread-keys.json.damaged.2026-09-02T10-00-00Z").write_text("{corrupt",
                                                                             encoding="utf-8")
    peers = tmp_path / "moe" / "cloud" / "peers.json"
    _peer_book(peers, "hermes-EXAMPLE01")
    with caplog.at_level(logging.WARNING):
        p = _mac_provider(ledger_dir, hermes_home, monkeypatch, peers)
    assert p.keyring.key(MEMORY_KEY_ID) is None
    assert any("waiting for moe:memory to come back from a peer" in m
               and "damaged" in m for m in caplog.messages)
    Keyring(ledger_dir / "thread-keys.json").mint_key("0F1E2D3C-THREAD")
    q = _mac_provider(ledger_dir, hermes_home, monkeypatch, peers)
    assert q.keyring.key(MEMORY_KEY_ID) is None


def test_mint_guard_damaged_keyring_with_no_peer_mints(ledger_dir, hermes_home, monkeypatch,
                                                       tmp_path, caplog):
    """A damaged marker but nobody enrolled — or only a revoked device:
    nobody can deliver, so waiting would be memory that never starts. Mint."""
    ledger_dir.mkdir(parents=True)
    (ledger_dir / "thread-keys.json.damaged.2026-09-02T10-00-00Z").write_text("{corrupt",
                                                                             encoding="utf-8")
    peers = tmp_path / "moe" / "cloud" / "peers.json"
    _peer_book(peers, "hermes-EXAMPLE01")
    book = json.loads(peers.read_text(encoding="utf-8"))
    book["revoked"] = ["hermes-EXAMPLE01"]                  # the one peer is revoked
    peers.write_text(json.dumps(book), encoding="utf-8")
    with caplog.at_level(logging.WARNING):
        p = _mac_provider(ledger_dir, hermes_home, monkeypatch, peers)
    assert p.keyring.key(MEMORY_KEY_ID) is not None
    assert not any("waiting for moe:memory" in m for m in caplog.messages)


# -- 6. memory text never reaches a log ---------------------------------------------------------

def test_no_memory_text_in_the_logs_across_add_replace_remove_and_a_pending_question(
        provider, hermes_home, caplog):
    facts = {
        "added": "Izzy's sister Dana lives in Haifa",
        "twin": "Dana's twin also lives in Haifa",
        "replacement": "Izzy's sister Dana moved to Tel Aviv",
    }
    with caplog.at_level(logging.DEBUG):
        provider.on_memory_write("add", "memory", facts["added"], {})
        provider.on_memory_write("add", "memory", facts["twin"], {})
        provider.on_session_switch("s2")                      # projects: both in the digest
        # Ambiguous old_text: the warning path (used to log the needle with %r).
        provider.on_memory_write("remove", "memory", "", {"old_text": "Haifa"})
        # Nothing addressed: the info path.
        provider.on_memory_write("remove", "memory", "", {"old_text": "nowhere at all"})
        provider.on_memory_write("replace", "memory", facts["replacement"],
                                 {"old_text": facts["added"]})
        provider.on_memory_write("remove", "memory", "", {"old_text": facts["twin"]})
        # A restatement by the model after the deletion: a pending question,
        # whose text used to ride in the DEBUG projection report.
        provider.on_memory_write("add", "memory", facts["twin"], {"write_origin": "assistant_tool"})
        provider.on_session_switch("s3")
        provider.on_session_end([])
    assert provider.store.live("memory") == [facts["replacement"]]
    assert [q["text"] for q in provider.pending_revivals] == [facts["twin"]]
    assert len(provider.pending_revivals) == 1
    logged = caplog.text
    assert "Haifa" not in logged and "Dana" not in logged and "Tel Aviv" not in logged
    assert "nowhere at all" not in logged
    for text in facts.values():
        assert text not in logged
    # What the logs do say: ids and lengths.
    assert any("old_text of 5 chars addresses 2 entries" in m for m in caplog.messages)
    assert any("chars" in m and claim_id("memory", facts["twin"]) in m
               for m in caplog.messages), "the DEBUG report names the question by id"


# -- 11. an empty text_enc on a claim is malformed ----------------------------------------------

def test_a_claim_with_an_empty_text_enc_is_ignored():
    body = {"op": ASSERT, "claim": claim_id("memory", "x"), "target": "memory",
            "source": "user", "enc": "aes-gcm-256.v1", "text_enc": "", "text": "leaked"}
    unsigned = unsigned_fields("claim", "2026-09-02T10:00:00.000Z", "mac-aaaaaaaa", 1, None,
                               [], body)
    record = dict(unsigned, id=record_id(unsigned), _at=0.0)
    assert parse_claim(record, None) is None
    assert parse_claim(record, os.urandom(32)) is None
    assert resolve([record], "memory", None).live == []
    for bad in (None, 7):
        assert parse_claim(dict(record, body=dict(body, text_enc=bad)), None) is None
    retract = dict(body, op="retract", text_enc="")
    retract.pop("text")
    assert parse_claim(dict(record, body=retract), None) is None
