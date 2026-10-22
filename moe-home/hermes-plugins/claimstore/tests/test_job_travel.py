"""Job-time travel on a Mac (claimstore `travel`, lib/travel.py; status #7,
2026-09-29): the situations tick seals the engine's own documents when they
changed and asks the app to push now; it applies the engine's documents the
app pulled — and nothing else, whatever arrived."""

from __future__ import annotations

import json
import time

import claimstore
from claimstore.store import ClaimStore
from moeledger import documents, threadcrypto

ENGINE = list(documents.ENGINE_NAMES)


def _docs(store):
    return [r for r in store.records() if r["kind"] == "document"]


def _enrol(moe_home):
    (moe_home / "cloud").mkdir(parents=True, exist_ok=True)
    (moe_home / "cloud" / "credential.json").write_text('{"token": "t"}', encoding="utf-8")


def test_the_tick_seals_only_what_changed_and_asks_for_a_push(hermes_home, ledger_dir, moe_home,
                                                               memory_key, monkeypatch):
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    _enrol(moe_home)
    (moe_home / "proactive").mkdir()
    (moe_home / "proactive" / "promises.json").write_text('{"prm_a": {"status": "open"}}', encoding="utf-8")
    (moe_home / "SOUL.md").write_text("never mine to send", encoding="utf-8")
    (hermes_home / "SOUL.md").write_text("Be brief.", encoding="utf-8")

    out = claimstore.travel(ENGINE, receive=False, send=True, hermes_home=hermes_home)
    assert out["error"] == ""
    assert out["written"] == ["proactive/promises"]
    assert out["nudged"] and (moe_home / "cloud" / "pull-requested").exists(), "the app is asked to push now"
    store = ClaimStore(ledger_dir, state_dir=hermes_home, key=memory_key)
    names = [r["body"]["name"] for r in _docs(store)]
    assert names == ["proactive/promises"], "the soul and the rest wait for a session"
    body = _docs(store)[0]["body"]
    assert threadcrypto.open_sealed(body["text_enc"], memory_key) == '{"prm_a": {"status": "open"}}'

    # Unchanged: nothing sealed, nobody nudged.
    (moe_home / "cloud" / "pull-requested").unlink()
    out = claimstore.travel(ENGINE, receive=False, send=True, hermes_home=hermes_home)
    assert out["written"] == [] and not out["nudged"]
    assert not (moe_home / "cloud" / "pull-requested").exists()


def test_the_tick_applies_the_engines_documents_and_nothing_else(hermes_home, ledger_dir, moe_home,
                                                                  memory_key, monkeypatch):
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    (moe_home / "proactive").mkdir()
    (moe_home / "proactive" / "situations.json").write_text(
        json.dumps({"sit_mac": {"title": "mac", "updated_at": "2026-09-29T08:00:00Z"}}), encoding="utf-8")
    (moe_home / "AGENTS.md").write_text("You are Alfie.", encoding="utf-8")
    # `who` as a session left it: applied, in the state file — so only the
    # name filter, not the keep-local rule, can keep the tick off it.
    documents.State(hermes_home / claimstore.DOCUMENTS_STATE).set("who", documents.sha256_hex("You are Alfie."))
    later = time.time() + 1
    machine = ClaimStore(ledger_dir, device="hermes-MACHINE01", state_dir=hermes_home / "m", key=memory_key)
    now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    machine.append("document", documents.document_body(
        "proactive/situations", json.dumps({"sit_cloud": {"title": "cloud", "updated_at": now_iso}}),
        memory_key), at=later)
    machine.append("document", documents.document_body("who", "You are someone else.", memory_key), at=later)

    out = claimstore.travel(ENGINE, receive=True, send=False, hermes_home=hermes_home)
    assert out["error"] == ""
    assert out["applied"] == ["proactive/situations"]
    merged = json.loads((moe_home / "proactive" / "situations.json").read_text(encoding="utf-8"))
    assert "sit_cloud" in merged, "the machine's situation arrived"
    assert (moe_home / "AGENTS.md").read_text(encoding="utf-8") == "You are Alfie.", \
        "a job applies the engine's documents only; the rest waits for the provider"


def test_nothing_to_travel_with_no_key_is_said_not_raised(hermes_home, ledger_dir, moe_home, monkeypatch):
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    (moe_home / "proactive").mkdir()
    (moe_home / "proactive" / "promises.json").write_text("{}", encoding="utf-8")
    out = claimstore.travel(ENGINE, receive=True, send=True, hermes_home=hermes_home)
    assert out["written"] == [] and not out["nudged"]


def test_a_mac_without_away_seals_nothing(hermes_home, ledger_dir, moe_home, memory_key, monkeypatch):
    """Review 2026-09-29 #4: nobody to send to, so its own ledger does not
    gain a copy of every change."""
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    (moe_home / "proactive").mkdir()
    (moe_home / "proactive" / "promises.json").write_text('{"prm_a": {}}', encoding="utf-8")
    out = claimstore.travel(ENGINE, receive=False, send=True, hermes_home=hermes_home)
    assert out["written"] == [] and not out["nudged"]
    assert _docs(ClaimStore(ledger_dir, state_dir=hermes_home, key=memory_key)) == []
