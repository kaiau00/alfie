#!/usr/bin/env python3
"""merge.py: idempotence, incrementality, provenance, conflicts, expiry.
Hermes is never called — resolve_with_llm is swapped for a stub."""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from helpers import ScratchCase, load, TODAY  # noqa: E402

merge = load("merge")
Store, Claim = merge.Store, merge.Claim


def digest(source, claims, questions=None):
    return {"source": source, "generated": TODAY, "claims": claims, "questions": questions or []}


def claim(file, text, date="2026-06-01", conf="high", key=None):
    return {"file": file, "text": text, "date": date, "confidence": conf, "key": key}


class MergeTest(ScratchCase):
    def setUp(self):
        super().setUp()
        self.store = Store(self.profile)

    def fold(self, d, use_llm=False):
        source, claims, questions = merge.load_digest(self.write_digest(d))
        return merge.merge(self.store, source, claims, questions, use_llm=use_llm)

    def write_digest(self, d):
        path = os.path.join(self.tmp, "%s.json" % d["source"])
        with open(path, "w") as f:
            json.dump(d, f)
        return path

    def test_provenance_on_every_line(self):
        self.fold(digest("fixture", [claim("identity", "Works from home most days", "2026-06-01", "med"),
                                     claim("people", "**Sam** — colleague on the same team", key="person:sam")]))
        identity = self.read("identity.md")
        self.assertIn("# Identity", identity)
        self.assertIn("- Works from home most days [fixture, 2026-06-01, med]", identity)
        self.assertIn("- **Sam** — colleague on the same team [fixture, 2026-06-01, high]", self.read("people.md"))

    def test_idempotent(self):
        d = digest("fixture", [claim("threads", "Renewing the office lease before 2026-09-30")])
        s1 = self.fold(d)
        before = self.read("threads.md")
        s2 = self.fold(d)
        self.assertEqual(s1["added"], 1)
        self.assertEqual(s2["added"], 0)
        self.assertEqual(s2["refreshed"], 1)
        self.assertEqual(before, self.read("threads.md"))

    def test_reconfirm_moves_date_forward_only(self):
        self.fold(digest("fixture", [claim("identity", "Cycles to work", "2026-06-01")]))
        self.fold(digest("fixture", [claim("identity", "Cycles to work", "2026-03-01")]))
        self.assertIn("[fixture, 2026-06-01, high]", self.read("identity.md"))
        self.fold(digest("fixture", [claim("identity", "Cycles to work", "2026-08-01")]))
        self.assertIn("[fixture, 2026-08-01, high]", self.read("identity.md"))
        self.assertEqual(self.read("identity.md").count("Cycles to work"), 1)

    def test_incremental_never_touches_other_sources(self):
        self.fold(digest("alpha", [claim("threads", "Alpha thread"), claim("people", "**Kim** — neighbour", key="person:kim")]))
        self.fold(digest("beta", [claim("threads", "Beta thread")]))
        threads = self.read("threads.md")
        self.assertIn("Alpha thread [alpha,", threads)
        self.assertIn("Beta thread [beta,", threads)
        # Re-merging alpha with a smaller digest keeps beta's line and alpha's older line.
        self.fold(digest("alpha", [claim("threads", "Alpha thread two")]))
        threads = self.read("threads.md")
        self.assertIn("Beta thread [beta,", threads)
        self.assertIn("Alpha thread [alpha,", threads)
        self.assertIn("Alpha thread two [alpha,", threads)
        self.assertIn("**Kim**", self.read("people.md"))

    def test_same_source_same_key_replaces(self):
        self.fold(digest("fixture", [claim("people", "**Sam** — colleague", key="person:sam")]))
        s = self.fold(digest("fixture", [claim("people", "**Sam** — colleague, now manager", "2026-07-01", key="person:sam")]))
        self.assertEqual(s["replaced"], 1)
        people = self.read("people.md")
        self.assertNotIn("**Sam** — colleague [", people)
        self.assertIn("**Sam** — colleague, now manager [fixture, 2026-07-01, high]", people)

    def test_people_key_derived_from_bold_name(self):
        self.fold(digest("fixture", [claim("people", "**Sam** — colleague")]))
        s = self.fold(digest("fixture", [claim("people", "**sam** — colleague and friend")]))
        self.assertEqual(s["replaced"], 1)
        self.assertEqual(self.read("people.md").count("**"), 2)

    def test_identical_text_from_second_source_not_duplicated(self):
        self.fold(digest("alpha", [claim("identity", "Has two children")]))
        s = self.fold(digest("beta", [claim("identity", "Has two children")]))
        self.assertEqual(s["refreshed"], 1)
        self.assertEqual(self.read("identity.md").count("Has two children"), 1)
        self.assertIn("[alpha,", self.read("identity.md"))

    def test_cross_source_conflict_without_llm_keeps_both_and_asks(self):
        self.fold(digest("alpha", [claim("people", "**Dani** — colleague", key="person:dani")]))
        s = self.fold(digest("beta", [claim("people", "**Dani** — sister", key="person:dani")]))
        self.assertEqual(s["conflicts"], 1)
        people = self.read("people.md")
        self.assertIn("**Dani** — colleague [alpha,", people)
        self.assertIn("**Dani** — sister [beta,", people)
        q = self.read("questions.md")
        self.assertIn("# Questions for you", q)
        self.assertIn("Dani", q)
        self.assertEqual(s["questions"], 1)
        # Asking again does not append the same question twice.
        s = self.fold(digest("beta", [claim("people", "**Dani** — sister", key="person:dani")]))
        self.assertEqual(s["questions"], 0)

    def test_cross_source_conflict_llm_replace(self):
        merge.resolve_with_llm = lambda existing, new: ("replace", "")
        self.fold(digest("alpha", [claim("identity", "Works at the old firm", key="identity:employer"),
                                   claim("identity", "Lives by the sea")]))
        s = self.fold(digest("beta", [claim("identity", "Works at the new firm", "2026-08-01", key="identity:employer")]), use_llm=True)
        self.assertEqual(s["replaced"], 1)
        identity = self.read("identity.md")
        self.assertNotIn("old firm", identity)
        self.assertIn("new firm [beta, 2026-08-01, high]", identity)
        self.assertIn("Lives by the sea [alpha,", identity)   # alpha's other claim untouched

    def test_cross_source_conflict_llm_failure_asks(self):
        def boom(existing, new):
            raise merge.hermes_client.HermesError("down") if hasattr(merge, "hermes_client") else RuntimeError("down")
        merge.resolve_with_llm = boom
        self.fold(digest("alpha", [claim("threads", "Launch is in September", key="thread:launch")]))
        s = self.fold(digest("beta", [claim("threads", "Launch slipped to October", key="thread:launch")]), use_llm=True)
        self.assertEqual(s["questions"], 1)
        self.assertIn("September", self.read("threads.md"))
        self.assertIn("October", self.read("threads.md"))

    def test_tombstoned_claim_not_resurrected(self):
        self.fold(digest("fixture", [claim("identity", "Drinks tea")]))
        cid = self.store.read("identity")[0].id
        self.store.delete(cid)
        s = self.fold(digest("fixture", [claim("identity", "Drinks tea")]))
        self.assertEqual(s["skipped"], 1)
        self.assertNotIn("Drinks tea", self.read("identity.md"))

    def test_deleted_topic_not_resurrected_reworded(self):
        # An id tombstone stops the same sentence; a crawl that rewords it
        # ("Drinks tea daily") has a new id. The (file, key) tombstone
        # written on delete stops that too — from any crawl source, and
        # for people even without a digest key (derived from the name).
        self.fold(digest("fixture", [claim("identity", "Drinks tea", key="pref:drink"),
                                     claim("people", "**Dani** — sister")]))
        for c in list(self.store.read("identity")) + list(self.store.read("people")):
            self.store.delete(c.id)
        s = self.fold(digest("other", [claim("identity", "Drinks tea daily", key="pref:drink"),
                                       claim("people", "**Dani** — sister; talks daily")]))
        self.assertEqual(s["skipped"], 2)
        self.assertNotIn("tea", self.read("identity.md"))
        self.assertNotIn("Dani", self.read("people.md"))
        # The user's own word on the topic is never blocked by a tombstone:
        # a hand-written [user] line stays, and a keyless rewording of a
        # keyless claim is only stopped by its id (the documented limit).
        s = self.fold(digest("other", [claim("identity", "Drinks coffee")]))
        self.assertEqual(s["added"], 1)

    def test_old_tombstone_file_still_read(self):
        os.makedirs(self.profile, exist_ok=True)
        with open(os.path.join(self.profile, ".tombstones.json"), "w") as f:
            json.dump([merge.store_mod.claim_id("identity", "Drinks tea")], f)
        s = self.fold(digest("fixture", [claim("identity", "Drinks tea")]))
        self.assertEqual(s["skipped"], 1)

    def test_user_correction_beats_source(self):
        self.fold(digest("fixture", [claim("people", "**Sam** — colleague", key="person:sam")]))
        cid = self.store.read("people")[0].id
        self.store.correct(cid, "**Sam** — my brother")
        s = self.fold(digest("fixture", [claim("people", "**Sam** — colleague, again", key="person:sam")]))
        self.assertEqual(s["skipped"], 1)
        people = self.read("people.md")
        self.assertIn("**Sam** — my brother [user, %s, high]" % TODAY, people)
        self.assertNotIn("again", people)

    def test_expire_drops_old_but_not_user_claims(self):
        self.fold(digest("fixture", [claim("identity", "Old fact", "2025-01-01"),
                                     claim("identity", "Fresh fact", "2026-08-01")]))
        cid = [c for c in self.store.read("identity") if c.text == "Old fact"][0].id
        self.store.correct(cid, "Old fact, but mine")
        dropped = self.store.expire(180)
        self.assertEqual(dropped, [])
        self.fold(digest("fixture", [claim("threads", "Stale thread", "2025-06-01")]))
        dropped = self.store.expire(180)
        self.assertEqual([c.text for c in dropped], ["Stale thread"])
        self.assertIn("Fresh fact", self.read("identity.md"))
        self.assertIn("Old fact, but mine [user,", self.read("identity.md"))
        # Re-confirmed later, an expired claim simply comes back.
        s = self.fold(digest("fixture", [claim("threads", "Stale thread", "2026-08-20")]))
        self.assertEqual(s["added"], 1)

    def test_digest_source_is_validated(self):
        for bad in ("", "user", "../x", "a b"):
            path = self.write_digest(digest(bad or "empty", []))
            if bad == "":
                with open(path, "w") as f:
                    json.dump({"source": "", "claims": []}, f)
            with self.assertRaises(ValueError):
                merge.load_digest(path)

    def test_digest_date_must_be_a_date(self):
        s = self.fold(digest("fixture", [claim("identity", "Ten chars, no date", "not-a-date"),
                                         claim("identity", "Dated", "2026-06-01")]))
        self.assertEqual(s["added"], 1)
        self.assertNotIn("no date", self.read("identity.md"))

    def test_cli_round_trip(self):
        import subprocess
        path = self.write_digest(digest("fixture", [claim("voice", "Short messages, no punctuation")], ["Which channel is work?"]))
        p = subprocess.run([sys.executable, os.path.join(os.path.dirname(merge.__file__), "merge.py"), path, "--no-llm"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        stats = json.loads(p.stdout)
        self.assertEqual(stats["added"], 1)
        self.assertEqual(stats["questions"], 1)
        p = subprocess.run([sys.executable, os.path.join(os.path.dirname(merge.__file__), "merge.py"), "expire", "--days", "30"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(json.loads(p.stdout), {"expired": 1})


if __name__ == "__main__":
    unittest.main()
