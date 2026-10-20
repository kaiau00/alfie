#!/usr/bin/env python3
"""Regenerate ``claim-conformance.json`` — the vector file both languages read.

    python3 tests/make_conformance.py

The fixture is committed, not generated at test time, on purpose: it is the
*agreement* between ``claimstore.store`` and ``Sources/MoeLedger/Claims.swift``,
and an agreement that both sides recompute from the same code every run proves
nothing. Regenerate it only when a rule deliberately changes, and expect the
Swift test to fail until Swift is changed to match.

Both sides assert three things against it:

* every ``claim_ids`` vector — the id two devices must agree on or diverge
  silently;
* every record's ``id`` recomputed from its own fields — which is the record
  hash, and therefore the canonical-JSON encoding, agreeing across two JSON
  writers;
* every case's resolution under §3.1 — live set, disagreements, superseded.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

from claimstore.store import (  # noqa: E402
    claim_id, format_timestamp, normalise, record_id, resolve, unsigned_fields,
)

BASE = 1788000000.0  # 2026-08-31T09:20:00Z, near enough

# Text chosen to make the canonical encoding earn its keep: a slash (Swift
# writes `withoutEscapingSlashes`, Python does not escape either), a quote and
# a backslash, an embedded newline (the body keeps the writer's own text; only
# the *id* collapses it), non-ASCII, and an emoji outside the BMP.
AWKWARD = 'He said "hi" \\ and pointed at a/b —\nnaïve, 日本語, 🍍42'

VECTORS = [
    ("memory", "The build needs Python 3.11."),
    ("memory", "  The   build  needs Python 3.11.  "),
    ("user", "The build needs Python 3.11."),
    ("memory", ""),
    ("memory", "\n\n"),
    ("memory", "a\r\nb"),
    ("memory", "a\x0bb\x0cc"),
    ("memory", AWKWARD),
    ("memory", " nbsp is not whitespace here "),
]


class Builder(object):
    """Records with correct ids, per-device seq/prev chains, explicit `after`."""

    def __init__(self):
        self.records = []
        self.heads = {}
        self.named = {}
        self.tick = 0

    def add(self, name, device, body, after=(), at=None):
        self.tick += 1
        seq, prev = self.heads.get(device, (0, None))
        stamp = format_timestamp(BASE + (self.tick if at is None else at))
        unsigned = unsigned_fields("claim", stamp, device, seq + 1, prev,
                                   [self.named[a] for a in after], body)
        record = dict(unsigned)
        record["id"] = record_id(unsigned)
        self.heads[device] = (seq + 1, record["id"])
        self.named[name] = record["id"]
        self.records.append(record)
        return record


def assert_body(target, text, source, key=None):
    body = {"op": "assert", "claim": claim_id(target, text), "target": target,
            "source": source, "text": text}
    if key:
        body["key"] = key
    return body


def retract_body(target, text, source, key=None):
    body = {"op": "retract", "claim": claim_id(target, text), "target": target,
            "source": source}
    if key:
        body["key"] = key
    return body


def case(name, why, build, target="memory"):
    b = Builder()
    build(b)
    # `at` on a record decides nothing on its own, but it is the seed order, so
    # the fixture pins it. Resolution runs over the ordered ledger, which is
    # what both sides compute for themselves from these very records.
    from claimstore.store import ClaimStore

    decoded = [ClaimStore._decode(json.dumps(r)) for r in b.records]
    from claimstore.store import ordered as order_records

    resolved = resolve(order_records(decoded), target)
    return {
        "name": name,
        "why": why,
        "target": target,
        "records": b.records,
        "expect": {
            "live": [c.text for c in resolved.live],
            "live_sources": [c.source for c in resolved.live],
            "superseded": [c.text for c in resolved.superseded],
            "disagreements": [
                {"key": d["key"], "sources": sorted(d["sources"]),
                 "readings": sorted(c.text for c in d["readings"])}
                for d in resolved.disagreements
            ],
            # Deleted facts something has stated again since. Neither restored
            # nor dropped: asked about. The two languages must agree on this
            # list exactly, because it is the other half of the revival rule
            # and a divergence here is a fact one side silently restores.
            "pending_revivals": [
                {"source": q.source, "text": q.text} for q in resolved.pending_revivals
            ],
        },
    }


MAC = "mac-9f3c1a2b"
PHONE = "cloud-w7"
HERMES = "hermes-4d5e6f70"


def build_cases():
    cases = []

    def plain(b):
        b.add("a", MAC, assert_body("memory", "deploys run on Fridays", "user"))
        b.add("c", PHONE, assert_body("memory", "the office is in Frankfurt", "gmail"))
    cases.append(case(
        "two-unrelated-claims",
        "No topic key on either, so neither can contend with the other.",
        plain))

    def same_fact_two_devices(b):
        b.add("a", MAC, assert_body("memory", "Naomi is my daughter", "imessage"))
        b.add("b", PHONE, assert_body("memory", "Naomi   is my daughter", "imessage"))
    cases.append(case(
        "two-devices-learn-the-same-fact",
        "§3.1 rule 1. Two records, one claim id: convergence with no merge step. "
        "The digest shows it once, and the words are the later record's.",
        same_fact_two_devices))

    def retraction_suppresses_concurrent(b):
        b.add("a", MAC, assert_body("memory", "I work at Kaplan", "user"))
        b.add("r", PHONE, retract_body("memory", "I work at Kaplan", "user"), after=["a"])
        # A second device that never heard about the retraction re-asserts it.
        b.add("c", MAC, assert_body("memory", "I work at Kaplan", "imessage"))
    cases.append(case(
        "a-retraction-suppresses-what-never-heard-of-it",
        "§3.1's tombstone amendment. The re-assert is concurrent with the "
        "retraction (it names nothing after it), so it is suppressed — and a "
        "crawl source could not revive it even if it were causally after.",
        retraction_suppresses_concurrent))

    # --- the revival matrix, by source class --------------------------------
    #
    # One row per *class* of writer that can re-state a deleted fact, not per
    # source that happened to get used. The first version of this fixture had
    # `hermes:assistant_tool` in exactly one case and that case had no
    # retraction in it, so Swift reviving only on the literal "user" and Python
    # also reviving on `hermes:*` passed every check while giving two different
    # answers over identical bytes. A matrix keyed on class is what makes that
    # impossible to miss again: adding a source means adding a row.
    #
    # Only `user` and `user:*` revive. Everything else becomes a question.
    REVIVAL_MATRIX = [
        ("user", True,
         "the person, through whatever surface. §3.1's own worked example: "
         "deleted on the phone on Tuesday, said again to the Mac on Wednesday."),
        ("user:memory-pane", True,
         "a surface that names itself. Still the person, and it says where."),
        ("hermes:assistant_tool", False,
         "the model, on its own initiative — Hermes's DEFAULT write_origin. "
         "This is the one that must not revive: nobody asked."),
        ("hermes:background_review", False,
         "a background pass over the transcript. Nobody asked."),
        ("hermes:side_question", False,
         "a side question's own agent. Nobody asked."),
        ("gmail", False, "a crawl re-deriving what it derived before (§3.1)."),
        ("file", False,
         "absorbed from MEMORY.md. Could be a person retyping it, could be a "
         "stale file; the bytes are identical, so it is asked rather than "
         "guessed (§14.3)."),
        ("unknown", False, "a writer that did not say. The default is to ask."),
    ]

    for source, expected, why in REVIVAL_MATRIX:
        def restated(b, source=source):
            b.add("a", MAC, assert_body("memory", "I work at Kaplan", "imessage"))
            b.add("r", PHONE, retract_body("memory", "I work at Kaplan", "user"), after=["a"])
            b.add("c", MAC, assert_body("memory", "I work at Kaplan", source), after=["r"])
        built = case(
            "restated-after-deletion-by-%s" % source.replace(":", "-"),
            "%s Revives: %s." % (why, expected),
            restated)
        assert bool(built["expect"]["live"]) is expected, (
            "the matrix and the rule disagree for %r" % source)
        assert bool(built["expect"]["pending_revivals"]) is (not expected), (
            "a refused revival must become a question, for %r" % source)
        cases.append(built)

    def concurrent_restatement(b):
        b.add("a", MAC, assert_body("memory", "I work at Kaplan", "imessage"))
        b.add("r", PHONE, retract_body("memory", "I work at Kaplan", "user"), after=["a"])
        # Names nothing after the retraction: this writer had not heard.
        b.add("c", MAC, assert_body("memory", "I work at Kaplan", "user"))
    cases.append(case(
        "a-restatement-that-never-heard-is-not-even-a-question",
        "Concurrent with the tombstone, so suppressed outright — and NOT a "
        "pending revival, because there is nothing to ask somebody who had not "
        "heard. Only a restatement causally after a deletion is a question.",
        concurrent_restatement))

    def concurrent_revival(b):
        b.add("a", MAC, assert_body("memory", "I work at Kaplan", "imessage"))
        # The phone deletes it, having seen only the assert.
        b.add("rp", PHONE, retract_body("memory", "I work at Kaplan", "user"), after=["a"])
        # The Mac deletes and re-states it, having seen only the assert and its
        # own tombstone. On its own that revival is valid; against the phone's
        # tombstone it is concurrent, and concurrent means suppressed.
        b.add("rm", MAC, retract_body("memory", "I work at Kaplan", "user"), after=["a"])
        b.add("c", MAC, assert_body("memory", "I work at Kaplan", "user"), after=["rm"])
    cases.append(case(
        "a-revival-only-revives-the-tombstone-it-can-see",
        "The amendment is causal, not positional. A `user` assert two hours "
        "later by its own clock does not undo a tombstone it never saw — "
        "otherwise which machine was awake would decide whether a deletion "
        "stuck.",
        concurrent_revival))

    def same_source_lww(b):
        b.add("a", MAC, assert_body("memory", "Izzy works at Kaplan", "gmail", key="job"))
        b.add("b", PHONE, assert_body("memory", "Izzy works at Anthropic", "gmail", key="job"))
    cases.append(case(
        "same-source-same-key-last-write-wins",
        "§3.1 rule 4. One source with two readings of one topic changed its "
        "mind; the loser stays in the ledger and is reported as superseded.",
        same_source_lww))

    def different_source_escalates(b):
        b.add("a", MAC, assert_body("memory", "Izzy works at Kaplan", "imessage", key="job"))
        b.add("b", PHONE, assert_body("memory", "Izzy works at Anthropic", "gmail", key="job"))
    cases.append(case(
        "different-sources-same-key-escalates",
        "§3.1 rule 5. Both readings stay live and the topic is raised. Nothing "
        "is dropped for want of a model.",
        different_source_escalates))

    def three_readings(b):
        b.add("a", MAC, assert_body("memory", "Izzy works at Kaplan", "gmail", key="job"))
        b.add("b", MAC, assert_body("memory", "Izzy works at Anthropic", "gmail", key="job"))
        b.add("c", PHONE, assert_body("memory", "Izzy works at Pulse", "imessage", key="job"))
    cases.append(case(
        "three-readings-two-sources",
        "Rules 4 and 5 compose: each source is collapsed to its newest reading "
        "first, and what is left is the disagreement.",
        three_readings))

    def user_target(b):
        b.add("a", HERMES, assert_body("user", "prefers terse answers", "hermes:assistant_tool"))
        b.add("b", HERMES, assert_body("memory", "prefers terse answers", "hermes:assistant_tool"))
    cases.append(case(
        "targets-are-independent",
        "The same sentence in two stores is two claims with two ids. Resolving "
        "`user` must not see the `memory` one.",
        user_target, target="user"))

    def awkward(b):
        b.add("a", HERMES, assert_body("memory", AWKWARD, "user"))
    cases.append(case(
        "awkward-text-survives-the-round-trip",
        "The body keeps the writer's own text, newline and all; only the id "
        "collapses whitespace. This case is what pins the canonical JSON "
        "encoding — slashes, quotes, backslashes, non-BMP — across two JSON "
        "writers, because the record id is a hash of those bytes.",
        awkward))

    return cases


def main():
    out = {
        "note": ("Shared conformance vectors for Moe's claim records. Read by "
                 "moe-home/hermes-plugins/claimstore/tests/test_conformance.py "
                 "and Tests/MoeLedgerTests/ClaimConformanceTests.swift. "
                 "Regenerate with tests/make_conformance.py."),
        "claim_ids": [
            {"target": t, "text": s, "normalised": normalise(s), "id": claim_id(t, s)}
            for t, s in VECTORS
        ],
        "cases": build_cases(),
    }
    path = os.path.join(HERE, "claim-conformance.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(out, handle, indent=2, ensure_ascii=False, sort_keys=False)
        handle.write("\n")
    print("wrote %s (%d vectors, %d cases)" % (path, len(out["claim_ids"]), len(out["cases"])))


if __name__ == "__main__":
    main()
