"""Third review of slice 4 (2026-09-25). Each failed on 61bfe1dc."""
import json, pytest
from claimstore import tidy
from claimstore.store import ClaimStore
T = ["memory", "user"]

@pytest.fixture
def store(hermes_home, ledger_dir, memory_key, moe_home, monkeypatch):
    monkeypatch.setattr("claimstore._config", lambda: {"ledger_dir": str(ledger_dir)})
    return ClaimStore(ledger_dir, device="mac-9f3c1a2b", state_dir=hermes_home, key=memory_key)

def ans(ch): return lambda m: json.dumps({"changes": ch})
def lab(s): return {ln["text"]: l for l, ln in tidy.snapshot(s, T)["lines"].items()}
def live(s, t): return {c.text: c.source for c in s.resolve(t).live}
def stage(hh, pid, target, ops):
    d = hh / "pending" / "memory"; d.mkdir(parents=True, exist_ok=True)
    (d / ("%s.json" % pid)).write_text(json.dumps({"id": pid, "action": "batch", "created_at": 1.0,
        "payload": {"action": "batch", "target": target, "operations": ops}}))
def filler(s, n=8):
    for i in range(n):
        s.assert_claim("memory", "Standing note %s about the studio" % "ABCDEFGH"[i], source="moe:turn")

def test_silent_skip(store, hermes_home):
    filler(store)
    store.assert_claim("memory", "Uses the long form of the report template always", source="moe:turn")
    stage(hermes_home, "s1", "memory", [{"action": "replace", "old_text": "long form", "new_text": "Uses the short report template"}])
    L = lab(store)
    e = tidy.run(store, T, ans([
        {"do": "rewrite", "id": L["Uses the long form of the report template always"], "text": "Uses the long report template always"},
        {"do": "staged", "id": "S1", "apply": True}]))
    print("changes", [c["do"] for c in e["changes"]], "refused", e["refused"])
    assert len(e["changes"]) + len(e["refused"]) == 2, "one vetted change left no trace"

def test_cover_removed_by_staged(store, hermes_home):
    filler(store)
    store.assert_claim("memory", "Prefers Signal", source="moe:turn")
    store.assert_claim("memory", "Prefers Signal for work chats", source="moe:turn")
    stage(hermes_home, "s1", "memory", [{"action": "remove", "old_text": "Signal for work", "new_text": ""}])
    L = lab(store)
    e = tidy.run(store, T, ans([
        {"do": "retire", "id": L["Prefers Signal"]},
        {"do": "staged", "id": "S1", "apply": True}]))
    print(live(store, "memory"))
    assert any("Signal" in t for t in live(store, "memory")), "both Signal lines gone"

def test_month_prefix():
    for s in ["Married 12 years", "Runs 3 marathons a year", "Drinks decaf 2 cups a day",
              "Has 2 separate bank accounts", "Mark 2 is his favourite gospel"]:
        print(s, tidy.is_dated(s))
    assert not tidy.is_dated("Runs 3 marathons a year")

def test_negation_scope():
    assert not tidy.holds("Doesn't like tea", "Doesn't like coffee but likes tea")


def test_a_crash_between_retract_and_assert_leaves_a_restorable_record(store, monkeypatch):
    store.assert_claim("user", "Lives in Brooklyn", source="moe:turn")
    store.assert_claim("user", "Lives in Brooklyn, NY", source="moe:turn")
    L = {ln["text"]: l for l, ln in tidy.snapshot(store, ["memory", "user"])["lines"].items()}
    real = store.assert_claim

    def boom(*a, **k):
        raise OSError("disk full")
    monkeypatch.setattr(store, "assert_claim", boom)
    with pytest.raises(OSError):
        tidy.run(store, ["memory", "user"], lambda m: json.dumps({"changes": [
            {"do": "merge", "ids": [L["Lives in Brooklyn"], L["Lives in Brooklyn, NY"]],
             "text": "Lives in Brooklyn (NY)"}]}))
    monkeypatch.setattr(store, "assert_claim", real)
    assert not [c for c in store.resolve("user").live if "Brooklyn" in c.text]
    rows = tidy.recent()
    assert len(rows) == 1
    tidy.undo(store, rows[0]["n"], ["memory", "user"])
    assert sorted(c.text for c in store.resolve("user").live if "Brooklyn" in c.text) == [
        "Lives in Brooklyn", "Lives in Brooklyn, NY"]


@pytest.mark.parametrize("line,other,held", [
    ("No car", "Has a Volvo, no cargo space", False),
    ("Doesn't eat meat", "Doesn't eat meatballs", False),
    ("Doesn't drink", "Doesn't drink coffee", False),
    ("Doesn’t like tea", "Doesn't like tea", True),
    ("Doesn't like tea", "Loves coffee; doesn't like tea.", True),
])
def test_a_negation_is_held_only_where_it_ends_a_clause(line, other, held):
    assert tidy.holds(line, other) is held
