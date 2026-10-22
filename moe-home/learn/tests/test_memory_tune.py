#!/usr/bin/env python3
"""The 2026-09-22 tune after the owner's first re-learn: the check list is
five items, a first seed flags nothing as new, the summary is durable facts
with at most three current events and no past tense, card lines do not
carry passing events, and an owner's edit or "Right" sticks through every
nightly pass. Every fixture is synthetic; each test goes red when the rule
it names is reverted."""

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from helpers import ScratchCase, load, TODAY, LEARN  # noqa: E402

profile = load("profile")
merge = load("merge")
cons = load("consolidate")
Store, Claim = profile.Store, profile.Claim
SCRIPT = os.path.join(LEARN, "profile.py")
# TODAY is 2026-08-30.


def C(file, text, source="whatsapp", date="2026-08-01", conf="high", key=None, **kw):
    return Claim(file, text, source, date, conf, key, **kw)


class Base(ScratchCase):
    def cli(self, *args):
        p = subprocess.run([sys.executable, SCRIPT] + list(args), stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True, env=dict(os.environ))
        return p.returncode, p.stdout, p.stderr

    def list_json(self):
        rc, out, err = self.cli("list", "--json", "--active")
        self.assertEqual(rc, 0, err)
        return json.loads(out)

    def flags(self):
        return {r["text"]: r["flag"] for r in self.list_json() if "flag" in r}

    def merge_claims(self, claims, source="whatsapp"):
        p = os.path.join(self.tmp, "digest.json")
        with open(p, "w") as f:
            json.dump({"source": source, "claims": claims}, f)
        src, cl, qs = merge.load_digest(p)
        return merge.merge(Store(self.profile), src, cl, qs, use_llm=False)

    def check_md_items(self):
        return [ln[2:] for ln in self.read("check.md").splitlines() if ln.startswith("- ")]

    def write_questions(self, qs):
        os.makedirs(self.profile, exist_ok=True)
        with open(os.path.join(self.profile, "questions.md"), "w") as f:
            f.write("# Questions for you\n\n" + "".join("- %s\n" % q for q in qs))


class CheckListTest(Base):
    def test_whole_list_is_five_in_priority_order_and_flags_agree(self):
        store = Store(self.profile)
        pair = [C("identity", "Speaks fluent Hebrew", key="identity:hebrew", first_seen="2026-01-01"),
                C("identity", "Hebrew is basic", key="identity:hebrew", conf="med", first_seen="2026-01-01"),
                C("identity", "Works at Pulse", key="identity:employer", first_seen="2026-01-01"),
                C("identity", "Works at Acme", key="identity:employer", source="gmail", first_seen="2026-01-01")]
        for x in pair:
            x.flag = "contradicts"
        store.write("identity", pair
                    + [C("identity", "Unsure fact %d about work" % i, conf="low", first_seen="2026-01-01")
                       for i in range(4)]
                    + [C("identity", "Fresh fact %d about home" % i, first_seen=TODAY) for i in range(6)])
        self.write_questions(['Which is right: "Speaks fluent Hebrew" or "Hebrew is basic"?',
                              'Two sources disagree: "Works at Pulse" (whatsapp) vs "Works at Acme" (gmail)?',
                              "Is the brother running the business this year?"])
        meta = store.meta()
        meta["latest_run"] = TODAY
        meta["had_profile"] = True
        store.save_meta(meta)
        stats = cons.consolidate(store, use_llm=False)
        items = self.check_md_items()
        self.assertEqual(len(items), 5, items)
        self.assertEqual([i.split(" — ")[0] for i in items],
                         ["Contradiction", "Contradiction", "Question", "Not sure", "Not sure"])
        self.assertEqual(stats["check"], 5)
        # list --json flags exactly the lines the list is about
        flags = self.flags()
        self.assertEqual(sorted(flags.values()), ["contradicts"] * 4 + ["unsure"] * 2)
        self.assertNotIn("new", flags.values(), "new is last: nothing is left for it under the cap")
        # check --json is the same list
        rc, out, _ = self.cli("check", "--json")
        got = json.loads(out)
        self.assertEqual([g["kind"] for g in got], ["contradicts", "contradicts", "question", "unsure", "unsure"])

    def test_new_shows_when_there_is_room(self):
        store = Store(self.profile)
        store.write("identity", [C("identity", "Old fact about work", first_seen="2026-01-01"),
                                 C("identity", "Fresh fact about home", first_seen=TODAY)])
        meta = store.meta()
        meta["had_profile"] = True
        store.save_meta(meta)
        cons.consolidate(store, use_llm=False)
        self.assertEqual(self.flags(), {"Fresh fact about home": "new"})
        self.assertEqual(self.check_md_items(), ["New — Fresh fact about home"])


class SeedIsNotNewTest(Base):
    def test_first_seed_flags_nothing_and_the_next_run_flags_only_its_additions(self):
        self.merge_claims([{"file": "identity", "text": "Lives in Monroe", "date": "2026-08-20", "confidence": "high"},
                           {"file": "identity", "text": "Builds Alfie, a Mac assistant", "date": "2026-08-25",
                            "confidence": "high"}])
        stats = cons.consolidate(Store(self.profile), use_llm=False)
        self.assertTrue(stats.get("seed"))
        self.assertEqual(self.flags(), {}, "a seed: everything is new, so nothing is")
        self.assertNotIn("New —", self.read("check.md"))
        # the next day's run adds one line: only it is new
        os.environ["MOE_TODAY"] = "2026-08-31"
        self.merge_claims([{"file": "identity", "text": "Plays chess on Sundays", "date": "2026-08-31",
                            "confidence": "high"}])
        cons.consolidate(Store(self.profile), use_llm=False)
        self.assertEqual(self.flags(), {"Plays chess on Sundays": "new"})

    def test_a_seed_that_crosses_midnight_is_still_a_seed(self):
        store = Store(self.profile)
        store.retire_all()                       # an empty profile, marked as such
        self.merge_claims([{"file": "identity", "text": "Lives in Monroe", "date": "2026-08-20",
                            "confidence": "high"}])
        os.environ["MOE_TODAY"] = "2026-08-31"   # the same learn run, after midnight
        self.merge_claims([{"file": "identity", "text": "Builds Alfie, a Mac assistant", "date": "2026-08-25",
                            "confidence": "high"}], source="gmail")
        cons.consolidate(Store(self.profile), use_llm=False)
        self.assertEqual(self.flags(), {})

    def test_after_retire_all_the_reseed_is_a_seed(self):
        store = Store(self.profile)
        store.write("identity", [C("identity", "Old fact", first_seen="2026-01-01")])
        meta = store.meta()
        meta["latest_run"] = "2026-01-01"
        meta["had_profile"] = True
        store.save_meta(meta)
        store.retire_all()
        self.merge_claims([{"file": "identity", "text": "Old fact", "date": "2026-08-20", "confidence": "high"},
                           {"file": "identity", "text": "Another fact", "date": "2026-08-20", "confidence": "high"}])
        self.assertEqual(self.flags(), {}, "between retire-all and the seed's consolidate, nothing is new")
        cons.consolidate(store, use_llm=False)
        self.assertEqual(self.flags(), {})

    def test_a_seed_left_by_an_older_consolidate_is_not_all_new(self):
        # the owner's Mac on 2026-09-22: latest_run set by the seed itself
        store = Store(self.profile)
        store.write("identity", [C("identity", "Fact %d" % i, first_seen=TODAY) for i in range(8)])
        meta = store.meta()
        meta["latest_run"] = TODAY
        store.save_meta(meta)
        self.assertEqual(self.flags(), {})


class SummaryTest(Base):
    def profile_with_events(self):
        store = Store(self.profile)
        store.write("identity", [C("identity", "Builds Alfie, a Mac assistant"), C("identity", "Lives in Monroe"),
                                 C("identity", "Was testing a Telegram bot named Otto")])
        store.write("threads", [
            C("threads", "Trip to Thailand", kind="event", occurred_start="2026-10-20", occurred_end="2026-12-20"),
            C("threads", "Alfie launch", kind="event", occurred_start="2026-09-15"),
            C("threads", "Wedding in Brooklyn", kind="event", occurred_start="2026-09-05"),
            C("threads", "Conference in Austin", kind="event", occurred_start="2026-11-02"),
            C("threads", "Handling a costly mistake by Modche", kind="event", date="2026-08-28"),
            C("threads", "Wrapped up the Kaporos season", kind="event", occurred_end="2026-09-10"),
            C("threads", "Runs Project Atlas with the Pulse team", kind="stable"),
            C("threads", "Just finished the Kaporos delivery leg", kind="stable"),
        ])
        return store

    def test_plain_summary_is_durable_with_three_current_events(self):
        store = self.profile_with_events()
        cons.consolidate(store, use_llm=False)
        s = store.summary()
        self.assertIn("Builds Alfie", s)
        self.assertIn("Runs Project Atlas", s)
        for gone in ("Was testing", "costly mistake", "Wrapped up", "Just finished"):
            self.assertNotIn(gone, s)
        events = [e for e in ("Thailand", "Alfie launch", "Wedding", "Austin") if e in s]
        self.assertEqual(len(events), 3, s)
        self.assertNotIn("Austin", s, "the latest-starting of four upcoming events is left out")

    def test_model_sees_only_durable_lines_and_current_events(self):
        store = self.profile_with_events()
        seen = {}

        def chat(system, user, key, **kw):
            seen["user"], seen["system"] = user, system
            return json.dumps({"summary": ["Builds Alfie, a Mac assistant", "Lives in Monroe",
                                           "Was testing a Telegram bot named Otto",
                                           "Recently returned from a trip"], "check": []})
        cons.consolidate(store, use_llm=True, chat=chat)
        self.assertNotIn("Otto", seen["user"])
        self.assertNotIn("costly mistake", seen["user"])
        self.assertLessEqual(seen["user"].count("[event]"), cons.SUMMARY_EVENTS)
        self.assertIn("at most 3 lines on events", seen["system"])
        s = store.summary()
        self.assertIn("Lives in Monroe", s)
        self.assertNotIn("Otto", s)
        self.assertNotIn("Recently returned", s)


class CardLinesTest(Base):
    def test_people_lose_passing_events_identity_events_move(self):
        store = Store(self.profile)
        store.write("people", [
            C("people", "**Zorach Grynhaus** — friend with an easy joking rapport; recently returned from "
                        "seminary as of September 2026", key="person:zorach-grynhaus"),
            C("people", "**Dani** — sister; talks daily"),
            C("people", "**Moshe** — just got back from Israel"),
            C("people", "**Ima** — mother; was visiting last week", source="user"),
        ])
        store.write("identity", [C("identity", "Was testing a Telegram bot named Otto"),
                                 C("identity", "Lives in Monroe")])
        stats = cons.consolidate(store, use_llm=False)
        people = sorted(c.text for c in store.read("people"))
        self.assertEqual(people, ["**Dani** — sister; talks daily",
                                  "**Ima** — mother; was visiting last week",       # the person's own word
                                  "**Zorach Grynhaus** — friend with an easy joking rapport"])
        self.assertEqual(store.read("people")[-1].key, "person:zorach-grynhaus")
        self.assertEqual([c.text for c in store.read("identity")], ["Lives in Monroe"])
        threads = {c.text for c in store.read("threads")}
        self.assertIn("Was testing a Telegram bot named Otto", threads)
        self.assertEqual(stats["trimmed"], 1)
        reasons = {c.text: c.reason for c in store.read_archive()}
        self.assertEqual(reasons[
            "**Zorach Grynhaus** — friend with an easy joking rapport; recently returned from seminary as of "
            "September 2026"], "superseded")

    def test_eventish(self):
        for t in ("Was testing a bot", "Recently moved offices", "Just wrapped up the season",
                  "returned from seminary", "friend, as of September 2026", "was shopping for a car"):
            self.assertTrue(profile.eventish(t), t)
        for t in ("Builds Alfie, a Mac assistant", "Moved to Jerusalem in 2026-03", "**Dani** — sister; talks daily",
                  "Lives in Monroe", "Prefers the terminal"):
            self.assertFalse(profile.eventish(t), t)


class OwnerEditsStickTest(Base):
    def test_two_corrections_on_one_person_both_survive(self):
        store = Store(self.profile)
        store.write("people", [C("people", "**Dani** — sister"), C("people", "**Dani** — lives in Haifa")])
        a, b = store.read("people")
        store.correct(a.id, "**Dani** — older sister")
        store.correct(b.id, "**Dani** — lives in Tel Aviv")
        cons.consolidate(store, use_llm=False)
        self.assertEqual(sorted(c.text for c in store.read("people")),
                         ["**Dani** — lives in Tel Aviv", "**Dani** — older sister"])

    def test_corrected_lines_survive_caps_expiry_trim_and_are_never_flagged(self):
        store = Store(self.profile)
        store.write("threads", [C("threads", "Sukkah job for a friend", kind="event", occurred_end="2025-10-01",
                                  date="2025-09-20", conf="low")]
                    + [C("threads", "Project %02d going on" % i, kind="stable", first_seen=TODAY) for i in range(20)])
        mine = store.correct(store.read("threads")[0].id, "Was building sukkahs for friends")
        meta = store.meta()
        meta["latest_run"], meta["had_profile"] = TODAY, True
        store.save_meta(meta)
        cons.consolidate(store, use_llm=False)
        cons.consolidate(store, use_llm=False)
        texts = [c.text for c in store.read("threads")]
        self.assertIn(mine.text, texts, "past-dated, eventish, over the cap: still the person's")
        self.assertNotIn(mine.text, self.flags())

    def test_confirm_clears_the_flag_and_settles_the_contradiction(self):
        store = Store(self.profile)
        store.write("identity", [C("identity", "Speaks fluent Hebrew", key="identity:hebrew", date="2026-07-01"),
                                 C("identity", "Hebrew is basic", key="identity:hebrew", date="2026-07-20",
                                   conf="med")])
        cons.consolidate(store, use_llm=False)
        flags = self.flags()
        self.assertEqual(set(flags.values()), {"contradicts"})
        right = next(c for c in store.read("identity") if c.text == "Speaks fluent Hebrew")
        rc, out, err = self.cli("confirm", right.id, "--json")
        self.assertEqual(rc, 0, err)
        res = json.loads(out)
        self.assertEqual((res["ok"], res["action"], res["id"]), (True, "confirm", right.id))
        self.assertEqual((res["claim"]["id"], res["claim"]["source"], res["claim"]["confidence"]),
                         (right.id, "user", "high"), "same text, same id — the page's row stays put")
        self.assertNotIn("flag", res["claim"])
        self.assertEqual([c.text for c in store.read("identity")], ["Speaks fluent Hebrew"])
        loser = next(c for c in store.read_archive() if c.text == "Hebrew is basic")
        self.assertEqual((loser.reason, loser.by), ("superseded", right.id))
        self.assertEqual(self.read("questions.md"), "")
        self.assertEqual(self.flags(), {})
        # the nightly pass and the next crawl both leave it alone
        cons.consolidate(store, use_llm=False)
        self.merge_claims([{"file": "identity", "key": "identity:hebrew", "text": "Hebrew is basic",
                            "date": "2026-08-29", "confidence": "high"}])
        cons.consolidate(store, use_llm=False)
        self.assertEqual([(c.text, c.source) for c in store.read("identity")], [("Speaks fluent Hebrew", "user")])
        self.assertEqual(self.flags(), {})

    def test_confirm_a_new_or_unsure_line(self):
        store = Store(self.profile)
        store.write("identity", [C("identity", "Old fact", first_seen="2026-01-01"),
                                 C("identity", "Fresh fact", first_seen=TODAY),
                                 C("identity", "Maybe a runner", conf="low", first_seen="2026-01-01")])
        meta = store.meta()
        meta["latest_run"], meta["had_profile"] = TODAY, True
        store.save_meta(meta)
        cons.consolidate(store, use_llm=False)
        self.assertEqual(self.flags(), {"Fresh fact": "new", "Maybe a runner": "unsure"})
        for t in ("Fresh fact", "Maybe a runner"):
            cid = next(c.id for c in store.read("identity") if c.text == t)
            rc, _, err = self.cli("confirm", cid)
            self.assertEqual(rc, 0, err)
        self.assertEqual(self.flags(), {})
        self.assertEqual(self.read("check.md"), "", "confirm rewrites check.md; nothing is left to check")
        rc, out, _ = self.cli("confirm", "0123456789", "--json")
        self.assertEqual((rc, json.loads(out)["ok"]), (1, False))

    def test_correct_and_delete_answer_in_json_and_close_questions(self):
        store = Store(self.profile)
        store.write("identity", [C("identity", "Speaks fluent Hebrew", key="identity:hebrew", date="2026-07-01"),
                                 C("identity", "Hebrew is basic", key="identity:hebrew", date="2026-07-20",
                                   conf="med")])
        cons.consolidate(store, use_llm=False)
        a = next(c for c in store.read("identity") if c.text == "Hebrew is basic")
        rc, out, err = self.cli("correct", a.id, "Hebrew is good enough for work", "--json")
        self.assertEqual(rc, 0, err)
        res = json.loads(out)
        self.assertEqual((res["action"], res["id"], res["claim"]["source"]), ("correct", a.id, "user"))
        self.assertNotEqual(res["claim"]["id"], a.id, "new text, new id")
        self.assertEqual(self.read("questions.md"), "", "the question about the corrected line is closed")
        b = next(c for c in store.read("identity") if c.text == "Speaks fluent Hebrew")
        rc, out, _ = self.cli("delete", b.id, "--json")
        self.assertEqual(json.loads(out)["claim"]["text"], "Speaks fluent Hebrew")
        cons.consolidate(store, use_llm=False)
        self.assertEqual([(c.text, c.source) for c in store.read("identity")],
                         [("Hebrew is good enough for work", "user")])


if __name__ == "__main__":
    import unittest
    unittest.main()
