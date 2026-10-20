"""Second review of slice 4 (2026-09-25): a staged change and the tidy's own
changes in one run, and the guards' false positives. Each failed on c6395686."""
import json
import pytest
from claimstore import tidy
from claimstore.store import ClaimStore

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


def pend(s, t):
    return [q.text for q in s.resolve(t).pending_revivals]


def stage(hermes_home, pid, target, ops):
    d = hermes_home / "pending" / "memory"
    d.mkdir(parents=True, exist_ok=True)
    (d / ("%s.json" % pid)).write_text(json.dumps({
        "id": pid, "action": "batch", "created_at": 1.0,
        "payload": {"action": "batch", "target": target, "operations": ops}}), encoding="utf-8")


def filler(s, n=6):
    for i in range(n):
        s.assert_claim("memory", "Standing note %s about the studio" % "ABCDEFGH"[i], source="moe:turn")


# A: merge retracts a line; a staged add of that same wording then vanishes into a revival
def test_staged_add_of_line_merged_away(store, hermes_home):
    filler(store)
    store.assert_claim("memory", "Likes green tea", source="moe:turn")
    store.assert_claim("memory", "Likes tea in the morning", source="moe:turn")
    stage(hermes_home, "s1", "memory", [{"action": "add", "old_text": "", "new_text": "Likes green tea"}])
    L = lab(store)
    tidy.run(store, T, ans([
        {"do": "merge", "ids": [L["Likes green tea"], L["Likes tea in the morning"]],
         "text": "Likes green tea in the morning"},
        {"do": "staged", "id": "S1", "apply": True}]))
    print("live", live(store, "memory"), "pending", pend(store, "memory"))
    assert "Likes green tea" not in pend(store, "memory"), "staged assert became a question"


# B: staged replace's old_text now substring-matches the merge's new line -> replaces the merged line
def test_staged_replace_hits_merged_line(store, hermes_home):
    filler(store)
    store.assert_claim("memory", "Gym on Mondays", source="moe:turn")
    store.assert_claim("memory", "Gym with Dana", source="moe:turn")
    stage(hermes_home, "s1", "memory", [{"action": "replace", "old_text": "Gym on Mondays",
                                         "new_text": "Gym on Mondays at 7"}])
    L = lab(store)
    tidy.run(store, T, ans([
        {"do": "merge", "ids": [L["Gym on Mondays"], L["Gym with Dana"]], "text": "Gym on Mondays with Dana"},
        {"do": "staged", "id": "S1", "apply": True}]))
    lv = live(store, "memory")
    print("live", lv)
    assert any("Dana" in t for t in lv), "Dana lost"


# C: staged replace to the same wording (retract then assert) -> revival
def test_staged_replace_same_text(store, hermes_home):
    filler(store)
    store.assert_claim("memory", "Invoices go out on the 1st", source="moe:turn")
    stage(hermes_home, "s1", "memory", [{"action": "replace", "old_text": "Invoices go out",
                                         "new_text": "Invoices go out on the 1st"}])
    tidy.run(store, T, ans([{"do": "staged", "id": "S1", "apply": True}]))
    print("live", live(store, "memory"), "pending", pend(store, "memory"))
    assert "Invoices go out on the 1st" in live(store, "memory")


# D: holds() ignores negation and small numbers
@pytest.mark.parametrize("line,other", [
    ("Is not allergic to nuts", "Is allergic to nuts"),
    ("Dentist at 9", "Dentist at 10"),
    ("Flight lands in 2027", "Flight lands in 2026"),
])
def test_holds_false_positive(line, other):
    assert not tidy.holds(line, other)


# E: duplicate accepted for negated line -> fact dropped
def test_duplicate_negation(store):
    filler(store)
    store.assert_claim("user", "Is allergic to nuts", source="moe:turn")
    store.assert_claim("user", "Is not allergic to nuts", source="hermes:assistant_tool")
    L = lab(store)
    e = tidy.run(store, T, ans([{"do": "duplicate", "id": L["Is not allergic to nuts"], "of": L["Is allergic to nuts"]}]))
    print(e["refused"], live(store, "user"))
    assert "Is not allergic to nuts" in live(store, "user")


# F: mutual cover retire — both lines retired, fact gone
def test_mutual_cover_retire(store):
    filler(store, 8)
    store.assert_claim("memory", "Studio rent paid by Izzy", source="moe:turn")
    store.assert_claim("memory", "Izzy paid studio rent", source="hermes:assistant_tool")
    L = lab(store)
    e = tidy.run(store, T, ans([{"do": "retire", "id": L["Studio rent paid by Izzy"]},
                                {"do": "retire", "id": L["Izzy paid studio rent"]}]))
    lv = live(store, "memory")
    print(e["refused"], lv)
    assert any("rent" in t for t in lv), "both retired"


# G: _WHEN false positives on standing facts
# "Lives at 12/3 Herzl Street" is read as a date and stays a known limit:
# 12/3 is a valid day. Worst case a standing fact is set aside, restorable.
@pytest.mark.parametrize("t", ["Works 9-5 on weekdays", "Sister May lives in Haifa"])
def test_is_dated_false_positive(t):
    assert not tidy.is_dated(t)


# H: Hebrew
def test_hebrew_holds():
    print(tidy._words("גר בחיפה עם אשתו"), tidy._words("גר בתל אביב"))
    assert not tidy.holds("גר בחיפה", "גר בתל אביב")
    assert not tidy.holds("לא אוכל בשר", "אוכל בשר")
