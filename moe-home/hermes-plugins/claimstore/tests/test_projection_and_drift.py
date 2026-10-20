"""The load-bearing claim: a projected file is not drift, and never shorter.

These tests exercise the projector against the *real* built-in memory tool —
``MemoryStore`` and ``_detect_external_drift`` as shipped — rather than a
model of it. If upstream tightens the guard, these fail.

The second half is about the thing that actually costs a person something.
``~/.hermes/memories/*.md`` is memory a person can read and edit, and this
code rewrites it. Every path that could shorten it or lose a line of it has a
test here, because a memory file that quietly got shorter is not a crash and
nobody would notice.
"""

import json
import os

import pytest

from claimstore.store import ClaimStore, claim_id
from claimstore import projection


# --- what the drift guard actually tests -----------------------------------

def test_drift_guard_is_a_shape_check_not_a_provenance_check(hermes_home):
    """Pin the behaviour the whole design rests on (ONE-AGENT §1.3).

    An external writer that produces tool-shaped bytes is accepted; only
    content the tool could not have written is refused. If this ever stops
    being true, the projection approach needs revisiting — hence the test.
    """
    from tools.memory_tool import MemoryStore

    path = hermes_home / "memories" / "MEMORY.md"

    def replace_after(raw):
        path.write_text(raw, encoding="utf-8")
        store = MemoryStore()
        store.load_from_disk()
        return store.replace("memory", "alpha", "alpha updated")

    assert replace_after("alpha fact\n§\nbeta fact")["success"] is True
    assert replace_after("alpha fact\n§\nbeta fact\n")["success"] is True, (
        "the guard compares raw.strip(), so a trailing newline is not drift"
    )
    # The one signal that actually fires: an entry larger than the whole-store budget.
    oversized = replace_after("alpha fact\n§\n" + "x" * 2500)
    assert oversized["success"] is False
    assert "drift_backup" in oversized


def test_is_tool_shaped_matches_the_guard(hermes_home):
    assert projection.is_tool_shaped("a\n§\nb", 2200) is True
    assert projection.is_tool_shaped("a\n§\nb\n", 2200) is True
    assert projection.is_tool_shaped("", 2200) is True
    assert projection.is_tool_shaped("a\n§\n\n§\nb", 2200) is False, "empty entry"
    assert projection.is_tool_shaped("a\n§\n  b  ", 2200) is False, "unstripped entry"
    assert projection.is_tool_shaped("x" * 2500, 2200) is False, "entry over budget"


# --- rendering --------------------------------------------------------------

def test_render_is_always_tool_shaped(hermes_home):
    entries = ["  padded  ", "", "dup", "dup", "another"]
    rendered = projection.render(entries, 2200)
    assert projection.is_tool_shaped(rendered, 2200)
    assert projection.parse_entries(rendered) == ["padded", "dup", "another"]


def test_render_drops_claims_that_could_never_be_tool_written(hermes_home):
    rendered = projection.render(["small", "y" * 300], 200)
    assert projection.parse_entries(rendered) == ["small"]
    assert projection.is_tool_shaped(rendered, 200)


def test_render_drops_oldest_on_overflow_and_keeps_order(hermes_home):
    entries = [f"claim-{i:02d}" + "." * 20 for i in range(20)]
    rendered = projection.render(entries, 120)
    kept = projection.parse_entries(rendered)
    assert len(rendered) <= 120
    assert kept == entries[len(entries) - len(kept):], "newest kept, order preserved"


def test_overflow_does_not_drop_who_the_person_is_by_age(hermes_home):
    """2026-10-15, the owner's USER.md: 19 of 36 facts, the oldest gone —
    the account's Name: line with them. Pinned facts stay whatever their
    age, and a long recent note is passed over rather than pushing out every
    shorter, older fact behind it. Order is still first-asserted first."""
    name = "Name: Dana Cohen"
    old = ["the person is Eli's nephew", "lives in Lakewood NJ"]
    filler = ["note-%02d" % i + "." * 30 for i in range(6)]
    long_recent = "trip details " + "x" * 172          # 185 chars: fits alone, not beside the name
    entries = [name] + old + filler + [long_recent]
    rendered = projection.render(entries, 200, pinned=[name])
    kept = projection.parse_entries(rendered)
    assert len(rendered) <= 200 and projection.is_tool_shaped(rendered, 200)
    assert name in kept, "the pinned name was dropped by age"
    assert long_recent not in kept, "a too-long entry must be passed over"
    assert kept == [e for e in entries if e in kept], "order preserved"
    # The same inputs, the same bytes: a changing digest respawns the child.
    assert projection.render(entries, 200, pinned=[name]) == rendered


def test_the_person_s_own_facts_and_the_name_are_pinned(hermes_home):
    from types import SimpleNamespace as C
    live = [C(text="Name: Dana Cohen", source=projection.ACCOUNT_SOURCE),
            C(text="likes tea", source="user"), C(text="said in a turn", source="moe:turn"),
            C(text="from mail", source="learn:mail")]
    assert projection.pinned_texts(live) == {"Name: Dana Cohen", "likes tea"}


def test_a_claim_too_big_for_the_digest_stays_in_the_ledger(hermes_home, ledger_dir):
    """Dropped from the file, not from the store. The ledger is the store."""
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "y" * 2500, source="user")
    store.assert_claim("memory", "small", source="user")
    projection.project(store, "memory")
    assert projection.parse_entries(
        projection.memory_path("memory").read_text(encoding="utf-8")) == ["small"]
    assert len(store.live("memory")) == 2, "the long one is still live in the ledger"


# --- projection round-trip against the real memory tool ---------------------

def test_projected_file_is_visible_to_the_memory_tool(hermes_home, ledger_dir, memory_store):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "the build needs Python 3.11", source="test")
    store.assert_claim("memory", "deploys run on Fridays", source="test")
    store.assert_claim("user", "prefers terse answers", source="test")

    projection.project_all(store, ["memory", "user"])

    builtin = memory_store()
    assert builtin.memory_entries == ["the build needs Python 3.11", "deploys run on Fridays"]
    assert builtin.user_entries == ["prefers terse answers"]
    snapshot = builtin.format_for_system_prompt("memory")
    assert snapshot and "Python 3.11" in snapshot


def test_memory_tool_can_replace_and_remove_after_a_projection(
    hermes_home, ledger_dir, memory_store
):
    """The headline: the projector's writes are not drift to the tool."""
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "the build needs Python 3.9", source="test")
    store.assert_claim("memory", "deploys run on Fridays", source="test")
    projection.project(store, "memory")

    builtin = memory_store()
    replaced = builtin.replace("memory", "Python 3.9", "the build needs Python 3.11")
    assert replaced["success"] is True, replaced.get("error")

    removed = builtin.remove("memory", "Fridays")
    assert removed["success"] is True

    added = builtin.add("memory", "a new note")
    assert added["success"] is True


def test_no_bak_file_is_ever_left_behind_by_a_projection(hermes_home, ledger_dir, memory_store):
    store = ClaimStore(ledger_dir)
    for i in range(5):
        store.assert_claim("memory", f"claim number {i}", source="test")
    projection.project(store, "memory")
    memory_store().replace("memory", "number 0", "claim number zero")
    baks = list((hermes_home / "memories").glob("*.bak.*"))
    assert baks == [], f"drift guard fired: {baks}"


def test_projection_is_idempotent(hermes_home, ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "one", source="test")
    first = projection.project(store, "memory")
    assert first["written"] is True
    second = projection.project(store, "memory")
    assert second["written"] is False, "no churn when the digest is already current"


def test_projection_refuses_to_write_non_tool_shaped_bytes(hermes_home, ledger_dir, monkeypatch):
    """The invariant is asserted, not assumed."""
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "good", source="test")
    projection.project(store, "memory")
    path = projection.memory_path("memory")
    before = path.read_text(encoding="utf-8")

    monkeypatch.setattr(projection, "render", lambda entries, limit, pinned=(): "x" * (limit + 1))
    report = projection.project(store, "memory")
    assert report["written"] is False
    assert "not tool-shaped" in report["skipped"]
    assert path.read_text(encoding="utf-8") == before, "the file was left alone"


def test_char_limit_tracks_the_hosts_config(hermes_home, monkeypatch):
    import tools.memory_tool as memory_tool

    monkeypatch.setattr(
        memory_tool, "get_builtin_memory_config",
        lambda config=None: {"memory_char_limit": 999, "user_char_limit": 111},
    )
    assert projection.char_limit("memory") == 999
    assert projection.char_limit("user") == 111


# --- reconciliation with other writers --------------------------------------

def test_a_hand_edit_is_absorbed_rather_than_clobbered(hermes_home, ledger_dir):
    """The person editing MEMORY.md in an editor is a writer, not a desync."""
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "from the log", source="test")
    projection.project(store, "memory")

    path = projection.memory_path("memory")
    path.write_text("from the log\n§\ntyped by hand", encoding="utf-8")

    report = projection.project(store, "memory")
    assert len(report["absorbed"]) == 1
    assert "typed by hand" in store.live("memory")
    assert projection.parse_entries(path.read_text(encoding="utf-8")) == [
        "from the log", "typed by hand",
    ]


def test_an_entry_added_by_the_memory_tool_survives_the_next_projection(
    hermes_home, ledger_dir, memory_store
):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "from the log", source="test")
    projection.project(store, "memory")

    memory_store().add("memory", "added by the tool")

    projection.project(store, "memory")
    assert "added by the tool" in store.live("memory")
    entries = projection.parse_entries(projection.memory_path("memory").read_text(encoding="utf-8"))
    assert entries == ["from the log", "added by the tool"]


def test_absorption_does_not_resurrect_what_another_device_retracted(
    hermes_home, ledger_dir, tmp_path
):
    """The rule that only bites once a second writer exists.

    The phone deleted a fact on Tuesday. This machine's MEMORY.md still shows
    it, because nothing has rewritten the file yet. Absorbing on "not live"
    would re-assert it and undo the deletion — on every single pass, forever.

    And it is not a question either: this projector wrote that line itself,
    before the retraction arrived, so the digest marker says the file is stale
    rather than that a person put it back. Asking here would turn every
    ordinary cross-device deletion into a prompt.
    """
    store = ClaimStore(ledger_dir, state_dir=tmp_path / "h")
    store.assert_claim("memory", "I work at Kaplan", source="hermes:assistant_tool")
    store.assert_claim("memory", "deploys run on Fridays", source="hermes:assistant_tool")
    projection.project(store, "memory")

    ClaimStore(ledger_dir, device="cloud-w7").retract_claim(
        "memory", "I work at Kaplan", source="user")

    # The file is still stale at this point — that is the whole scenario.
    assert "Kaplan" in projection.memory_path("memory").read_text(encoding="utf-8")

    report = projection.project(store, "memory")
    assert report["absorbed"] == [], "a stale file re-asserted a deleted claim"
    assert report["asked"] == [], "a file we wrote ourselves is not somebody asking"
    assert projection.parse_entries(
        projection.memory_path("memory").read_text(encoding="utf-8")) == ["deploys run on Fridays"]
    # And it stays gone on every subsequent pass.
    projection.project(store, "memory")
    assert store.live("memory") == ["deploys run on Fridays"]
    assert store.resolve("memory").pending_revivals == []


def test_a_deleted_fact_typed_back_in_by_hand_becomes_a_question(
    hermes_home, ledger_dir, tmp_path
):
    """The case §3.1 has no rule for, answered by asking rather than guessing.

    The memory file carries no metadata, so "the person retyped this" and
    "this file is stale" are the same bytes — except for one thing this
    projector does know: what it last wrote. A line it did not write, whose
    claim was retracted, is somebody putting it back.

    It is still not restored. It becomes a question, with the record in the
    ledger to back it, so nothing is restored silently and nothing is dropped
    silently.
    """
    store = ClaimStore(ledger_dir, state_dir=tmp_path / "h")
    store.assert_claim("memory", "I work at Kaplan", source="hermes:assistant_tool")
    projection.project(store, "memory")
    store.retract_claim("memory", "I work at Kaplan", source="user")
    projection.project(store, "memory")
    assert projection.memory_path("memory").read_text(encoding="utf-8").strip() == ""

    # A person, in vim.
    projection.memory_path("memory").write_text("I work at Kaplan", encoding="utf-8")

    report = projection.project(store, "memory")
    assert len(report["absorbed"]) == 1
    assert store.live("memory") == [], "typing it back must not silently restore it"
    assert [q["text"] for q in report["asked"]] == ["I work at Kaplan"]
    assert [q["source"] for q in report["asked"]] == ["file"]

    # Asked once, not once per projection.
    again = projection.project(store, "memory")
    assert again["absorbed"] == []
    assert len(again["asked"]) == 1

    # And answering yes is an ordinary user-sourced assert.
    store.assert_claim("memory", "I work at Kaplan", source="user:memory-pane")
    final = projection.project(store, "memory")
    assert final["asked"] == []
    assert projection.parse_entries(
        projection.memory_path("memory").read_text(encoding="utf-8")) == ["I work at Kaplan"]


def test_a_lost_digest_marker_asks_rather_than_assumes(hermes_home, ledger_dir, tmp_path):
    """The marker is an optimisation on a question, never on a memory.

    Without it every stale line looks like somebody retyping — a spurious
    question. That is the direction it has to fail in: the alternative would
    be assuming a line we cannot account for is stale, and silently dropping
    what a person typed.
    """
    home = tmp_path / "h"
    store = ClaimStore(ledger_dir, state_dir=home)
    store.assert_claim("memory", "I work at Kaplan", source="hermes:assistant_tool")
    projection.project(store, "memory")
    ClaimStore(ledger_dir, device="cloud-w7").retract_claim(
        "memory", "I work at Kaplan", source="user")

    (home / "claimstore-digest.json").unlink()

    report = projection.project(store, "memory")
    assert len(report["asked"]) == 1, "an unknown line is asked about, not assumed"
    assert store.live("memory") == [], "and it is still not restored"


def test_a_disagreement_keeps_both_readings_in_the_file(hermes_home, ledger_dir):
    """§3.1 rule 5, at the file. Escalating means the person sees both."""
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "Izzy works at Kaplan", source="imessage", key="job")
    store.assert_claim("memory", "Izzy works at Anthropic", source="gmail", key="job")
    report = projection.project(store, "memory")
    entries = projection.parse_entries(
        projection.memory_path("memory").read_text(encoding="utf-8"))
    assert sorted(entries) == ["Izzy works at Anthropic", "Izzy works at Kaplan"]
    assert report["disagreements"] == [{"key": "job", "sources": ["imessage", "gmail"]}]


# --- what a memory-tool removal is allowed to reach --------------------------

def test_a_removal_retracts_only_what_it_addressed(hermes_home, ledger_dir, monkeypatch):
    """The digest is a subset of the live set, and a sweep does not know that.

    ``retract_matching`` used to retract every live claim containing the
    needle. Reproduced before this test existed: two live claims containing
    "Kaplan", only one of them in the digest, one ``remove`` and the ledger
    went from two live claims to zero. The one that was never in the file
    could not have been addressed by any tool call, and the person had no way
    to see it go.
    """
    import tools.memory_tool as memory_tool

    # A budget only the newest claim fits in — the ordinary state of a real
    # store rather than a contrivance: MEMORY.md is 2200 characters and a
    # person's memory is not.
    monkeypatch.setattr(memory_tool, "get_builtin_memory_config",
                        lambda config=None: {"memory_char_limit": 40, "user_char_limit": 40})

    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "I work at Kaplan", source="user")
    store.assert_claim("memory", "the Kaplan deadline is in March", source="user")
    report = projection.project(store, "memory")
    assert report["left_out"] == 1, "the setup did not actually overflow the digest"
    assert projection.digest_entries(store, "memory") == ["the Kaplan deadline is in March"]

    retracted = projection.retract_addressed(store, "memory", "Kaplan", source="hermes:user")
    assert len(retracted) == 1
    assert store.live("memory") == ["I work at Kaplan"], (
        "a removal reached a claim that was never in the file"
    )


def test_an_ambiguous_removal_retracts_nothing(hermes_home, ledger_dir):
    """The built-in tool refuses an ``old_text`` matching several entries, and
    so does this. A stale file can produce an ambiguity the tool never saw,
    and guessing would delete somebody's memory."""
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "I work at Kaplan", source="user")
    store.assert_claim("memory", "the Kaplan deadline is in March", source="user")
    projection.project(store, "memory")

    assert projection.retract_addressed(store, "memory", "Kaplan", source="hermes:user") == []
    assert len(store.live("memory")) == 2


def test_a_removal_that_addresses_nothing_retracts_nothing(hermes_home, ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "I work at Kaplan", source="user")
    projection.project(store, "memory")
    assert projection.retract_addressed(store, "memory", "Anthropic", source="x") == []
    assert store.live("memory") == ["I work at Kaplan"]


def test_addressing_is_computed_from_the_ledger_not_from_a_stale_file(
    hermes_home, ledger_dir
):
    """A file somebody else edited must not be able to address a claim.

    ``digest_entries`` renders from the ledger rather than reading the file,
    so a line that is not in the store cannot name anything.
    """
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "I work at Kaplan", source="user")
    projection.project(store, "memory")
    projection.memory_path("memory").write_text(
        "I work at Kaplan\n\u00a7\nsomething nobody asserted", encoding="utf-8")
    assert projection.digest_entries(store, "memory") == ["I work at Kaplan"]


# --- the file must never quietly get shorter --------------------------------

def test_first_run_on_a_machine_with_memory_adopts_it_rather_than_emptying_it(
    hermes_home, ledger_dir, memory_store
):
    """Installing the plugin on a machine that already has memory.

    The ledger is empty and the files are not. Rendering the empty ledger over
    them would delete somebody's memory in one pass and it would look like a
    successful projection.
    """
    (hermes_home / "memories" / "MEMORY.md").write_text(
        "an existing fact\n§\nanother existing fact", encoding="utf-8")
    (hermes_home / "memories" / "USER.md").write_text("prefers tea", encoding="utf-8")

    store = ClaimStore(ledger_dir)
    reports = projection.project_all(store, ["memory", "user"])

    assert len(reports[0]["absorbed"]) == 2
    assert store.live("memory") == ["an existing fact", "another existing fact"]
    assert store.live("user") == ["prefers tea"]
    builtin = memory_store()
    assert builtin.memory_entries == ["an existing fact", "another existing fact"]
    assert builtin.user_entries == ["prefers tea"]


def test_a_projection_never_writes_fewer_entries_than_it_absorbed(hermes_home, ledger_dir):
    """The general form of the case above, over a file full of entries."""
    path = hermes_home / "memories" / "MEMORY.md"
    entries = [f"fact number {i}" for i in range(30)]
    path.write_text("\n§\n".join(entries), encoding="utf-8")

    store = ClaimStore(ledger_dir)
    projection.project(store, "memory")
    after = projection.parse_entries(path.read_text(encoding="utf-8"))
    assert after == entries, "the file lost or reordered entries on first contact"


def test_a_memory_file_that_cannot_be_read_is_not_replaced(hermes_home, ledger_dir):
    """An unreadable file is not an empty one.

    A permissions blip must not be the thing that replaces a person's memory
    with whatever this process happens to hold.
    """
    path = hermes_home / "memories" / "MEMORY.md"
    path.write_text("something a person wrote", encoding="utf-8")
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "something else entirely", source="test")

    os.chmod(str(path), 0o000)
    try:
        if os.access(str(path), os.R_OK):  # running as root; the case cannot be made
            pytest.skip("cannot make a file unreadable as this user")
        report = projection.project(store, "memory")
        assert report["written"] is False
        assert report["skipped"]
    finally:
        os.chmod(str(path), 0o600)
    assert path.read_text(encoding="utf-8") == "something a person wrote"


def test_the_file_does_empty_when_the_person_actually_deleted_everything(
    hermes_home, ledger_dir, tmp_path
):
    """The other direction, and it has to work too, or Delete is a lie.

    Nothing above may be read as "the file only ever grows". A claim the
    person retracted leaves the digest, and a digest with nothing left in it
    is an empty file.
    """
    store = ClaimStore(ledger_dir, state_dir=tmp_path / "h")
    store.assert_claim("memory", "the only fact", source="hermes:assistant_tool")
    projection.project(store, "memory")
    store.retract_claim("memory", "the only fact", source="user")
    projection.project(store, "memory")
    assert projection.memory_path("memory").read_text(encoding="utf-8").strip() == ""
    assert len(store.claim_records("memory")) == 2, "the ledger still explains it"


def test_a_hand_edited_file_over_budget_is_shortened_and_says_so(hermes_home, ledger_dir):
    """"Same entries in the same order" is only true while everything fits.

    A person can paste eighty facts into MEMORY.md. The digest has room for
    some of them, and the rest are dropped from the *file* — which is correct,
    it is the same direction the built-in tool pushes the model in, and
    nothing is lost because the ledger is the store and recall surfaces what
    did not fit. What it must not be is silent.
    """
    entries = ["fact number %02d %s" % (i, "." * 40) for i in range(80)]
    projection.memory_path("memory").write_text("\n\u00a7\n".join(entries), encoding="utf-8")

    store = ClaimStore(ledger_dir)
    report = projection.project(store, "memory")

    assert len(report["absorbed"]) == 80, "every entry became a claim"
    assert len(store.live("memory")) == 80, "and every claim is live in the ledger"
    kept = projection.parse_entries(
        projection.memory_path("memory").read_text(encoding="utf-8"))
    assert len(kept) < 80, "this test is pointless unless it reaches the truncation branch"
    assert report["entries"] == len(kept)
    assert report["left_out"] == 80 - len(kept) > 0, "the shortening was not reported"
    assert kept == entries[80 - len(kept):], "the newest were kept, in order"
    # Nothing is lost: what did not fit is still reachable.
    assert set(entries) - set(kept) <= set(store.live("memory"))


def test_a_projection_that_raises_leaves_the_file_alone(hermes_home, ledger_dir, monkeypatch):
    path = hermes_home / "memories" / "MEMORY.md"
    path.write_text("untouched", encoding="utf-8")
    store = ClaimStore(ledger_dir)

    def boom(*a, **k):
        raise RuntimeError("the ledger is on fire")

    monkeypatch.setattr(store, "resolve", boom)
    report = projection.project(store, "memory")
    assert report["written"] is False
    assert "RuntimeError" in report["skipped"]
    assert path.read_text(encoding="utf-8") == "untouched"
