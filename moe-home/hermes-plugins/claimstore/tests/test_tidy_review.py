"""Review of slice 4 (2026-09-25): seven defects, each reproduced before it
was fixed. Each test here failed on 6c6e5d02."""

import json
import pytest
from claimstore import projection, tidy
from claimstore.store import ClaimStore, claim_id

T = ["memory", "user"]


@pytest.fixture
def store(hermes_home, ledger_dir, memory_key, moe_home, monkeypatch):
    monkeypatch.setattr("claimstore._config", lambda: {"ledger_dir": str(ledger_dir)})
    return ClaimStore(ledger_dir, device="mac-9f3c1a2b", state_dir=hermes_home, key=memory_key)


def ans(ch):
    return lambda m: json.dumps({"changes": ch})


def lab(s):
    return {ln["text"]: l for l, ln in tidy.snapshot(s, T)["lines"].items()}


def live(s, t):
    return {c.text: c.source for c in s.resolve(t).live}


# 1. two runs on one day: first run's change loses its Restore
def test_same_day_second_run_overwrites_log(store):
    store.assert_claim("memory", "Dentist appointment next Tuesday", source="moe:turn")
    store.assert_claim("memory", "Plumber visit tomorrow", source="moe:turn")
    for i in range(6):
        store.assert_claim("memory", "Standing fact number %d here" % i, source="moe:turn")
    now = 1_790_000_000.0
    L = lab(store)
    tidy.run(store, T, ans([{"do": "retire", "id": L["Dentist appointment next Tuesday"]}]), now=now)
    n1 = tidy.recent(now=now)[0]["n"]
    L = lab(store)
    tidy.run(store, T, ans([{"do": "retire", "id": L["Plumber visit tomorrow"]}]), now=now + 3600)
    ns = [r["n"] for r in tidy.recent(now=now + 3600)]
    print("after second run:", ns, "first was", n1)
    rec = tidy.undo(store, n1, T)
    print("undo first ->", rec and rec["before"])
    assert "Dentist appointment next Tuesday" in live(store, "memory"), "first change unrestorable"


# 2. merge worded as an existing (person's) line outside the merge: Restore deletes the person's line
def test_merge_into_existing_persons_line_then_undo(store):
    store.assert_claim("user", "Lives in Brooklyn, New York", source="user:memory-page")
    store.assert_claim("user", "Lives in Brooklyn", source="moe:turn")
    store.assert_claim("user", "Lives in New York", source="moe:turn")
    L = lab(store)
    tidy.run(store, T, ans([{"do": "merge", "ids": [L["Lives in Brooklyn"], L["Lives in New York"]],
                             "text": "Lives in Brooklyn, New York"}]))
    e = tidy.run(store, T, ans([]))
    # The merge above is refused: worded as a line outside it, it is a duplicate.
    assert tidy.recent() == []
    assert "Lives in Brooklyn, New York" in live(store, "user")
    # And Restore never retracts a line now standing in the person's words.
    store.assert_claim("memory", "Dentist on 9/20", source="moe:turn")
    for i in range(6):
        store.assert_claim("memory", "Note %d" % i, source="moe:turn")
    L = lab(store)
    tidy.run(store, T, ans([{"do": "rewrite", "id": L["Dentist on 9/20"], "text": "Dentist, 9/20"}]))
    # The person deletes it and says it again: it now stands in their words.
    store.retract_claim("memory", "Dentist, 9/20", source="user:memory-page")
    store.assert_claim("memory", "Dentist, 9/20", source="user:memory-page")
    tidy.undo(store, tidy.recent()[0]["n"], T)
    assert live(store, "memory").get("Dentist, 9/20") == "user:memory-page"


# 3. rewrite that only changes whitespace -> same claim id -> becomes a pending revival; line vanishes
def test_rewrite_same_id_vanishes(store):
    store.assert_claim("memory", "Invoices go out\non the 1st", source="moe:turn")
    L = lab(store)
    lbl = [l for t, l in L.items() if "Invoices" in t][0]
    e = tidy.run(store, T, ans([{"do": "rewrite", "id": lbl, "text": "Invoices go out on the 1st", "why": "date"}]))
    print("refused", e["refused"], "live", live(store, "memory"),
          "pending", [q.text for q in store.resolve("memory").pending_revivals])
    assert any("Invoices" in t for t in live(store, "memory")), "fact vanished into a revival"


# 4. rewrite of both readings of a disagreement -> same source moe:tidy, same key -> one superseded silently
def test_rewrite_both_readings_of_a_disagreement(store):
    store.assert_claim("user", "Works at Acme as the lead designer for the product team", source="moe:turn", key="job")
    store.assert_claim("user", "Works at Globex as the lead designer for the product team", source="hermes:assistant_tool", key="job")
    snap = tidy.snapshot(store, T)
    print("disagreements", snap["disagreements"])
    L = lab(store)
    a = L["Works at Acme as the lead designer for the product team"]
    b = L["Works at Globex as the lead designer for the product team"]
    e = tidy.run(store, T, ans([{"do": "rewrite", "id": a, "text": "Works at Acme as lead designer, product team"},
                                {"do": "rewrite", "id": b, "text": "Works at Globex as lead designer, product team"}]))
    print("changes", len(e["changes"]), "refused", e["refused"])
    lv = live(store, "user")
    print("live", lv)
    assert len([t for t in lv if "Works at" in t]) == 2, "one reading silently superseded"


# 5. retire guard is vacuous: 'on' makes everything dated; lowercase lines are 'covered' by anything
def test_retire_guards(store):
    print("is_dated('Izzy works on Alfie') =", tidy.is_dated("Izzy works on Alfie"))
    print("adds_something('Prefers short answers', ['Prefers tea']) =",
          tidy.adds_something("Prefers short answers", ["Prefers tea"]))
    store.assert_claim("memory", "Prefers short answers without emoji", source="moe:turn")
    store.assert_claim("memory", "Prefers tea over coffee", source="moe:turn")
    for i in range(6):
        store.assert_claim("memory", "Other note %d" % i, source="moe:turn")
    L = lab(store)
    e = tidy.run(store, T, ans([{"do": "duplicate", "id": L["Prefers short answers without emoji"],
                                 "of": L["Prefers tea over coffee"]}]))
    print("dup accepted:", len(e["changes"]), e["refused"])
    assert "Prefers short answers without emoji" in live(store, "memory")


# 6. staged replace into a previously-deleted wording: old line retracted, new one becomes a question
def test_staged_replace_into_deleted_wording(store, hermes_home):
    store.assert_claim("memory", "Uses Notion for notes", source="moe:turn")
    store.assert_claim("memory", "Uses Obsidian for notes", source="moe:turn")
    store.retract_claim("memory", "Uses Obsidian for notes", source="user:memory-page")
    d = hermes_home / "pending" / "memory"; d.mkdir(parents=True)
    (d / "a.json").write_text(json.dumps({"id": "a", "payload": {
        "target": "memory", "action": "replace", "old_text": "Notion", "content": "Uses Obsidian for notes"}}))
    tidy.run(store, T, ans([{"do": "staged", "id": "S1", "apply": True}]))
    print("live", live(store, "memory"), "pending", [q.text for q in store.resolve("memory").pending_revivals])
    assert any("notes" in t for t in live(store, "memory")), "fact vanished to To check"


# 7. person deletes a line between snapshot and apply (during the model call) -> merge brings it back
def test_deleted_during_model_call_comes_back(store):
    store.assert_claim("user", "Lives in Brooklyn", source="moe:turn")
    store.assert_claim("user", "Lives in Brooklyn, NY", source="moe:turn")
    L = lab(store)

    def call(m):
        store.retract_claim("user", "Lives in Brooklyn, NY", source="user:memory-page")
        store.retract_claim("user", "Lives in Brooklyn", source="user:memory-page")
        return json.dumps({"changes": [{"do": "merge", "ids": [L["Lives in Brooklyn"], L["Lives in Brooklyn, NY"]],
                                        "text": "Lives in Brooklyn (NY)"}]})
    tidy.run(store, T, call)
    print("live", live(store, "user"))
    assert not any("Brooklyn" in t for t in live(store, "user")), "deleted fact came back"
