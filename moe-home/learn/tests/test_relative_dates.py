#!/usr/bin/env python3
"""Ticket #9: memory froze relative dates.

A WhatsApp from 2026-09-21 22:45 — "invite has been sent for tomorrow at 10"
— became "Project Atlas call scheduled for 2026-09-23 at 10am" in
threads.md (a day late: "tomorrow" was read against the crawl's run day),
and the nightly summary said "Has a Project Atlas call today at 10am", which
was still being read two days later. Each test goes red when its rule is
reverted."""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from helpers import ScratchCase, load, TODAY  # noqa: E402

distil = load("distil")
profile = load("profile")
cons = load("consolidate")
Store, Claim = profile.Store, profile.Claim
# TODAY is 2026-08-30 (helpers), a Sunday.


def C(file, text, source="whatsapp", date="2026-08-01", conf="high", key=None, **kw):
    return Claim(file, text, source, date, conf, key, **kw)


class AnchorTest(unittest.TestCase):
    def test_tomorrow_at_ten_is_the_day_after_the_message_not_after_the_crawl(self):
        line = "2026-09-21 22:45:12|Eli|invite has been sent for tomorrow at 10\n"
        out = distil.anchor_relative_dates(line)
        self.assertIn("tomorrow at 10 [= 2026-09-22 10:00]", out)
        self.assertNotIn("2026-09-23", out)

    def test_each_line_is_read_against_its_own_stamp(self):
        text = ("2026-09-21 22:45|Eli|call tomorrow at 10am\n"
                "2026-09-22 20:15|me|ok see you tonight and tomorrow at 3pm\n"
                "  still on for next week?\n")        # a continuation inherits its stamp
        out = distil.anchor_relative_dates(text).splitlines()
        self.assertIn("tomorrow at 10am [= 2026-09-22 10:00]", out[0])
        self.assertIn("tonight [= 2026-09-22 evening]", out[1])
        self.assertIn("tomorrow at 3pm [= 2026-09-23 15:00]", out[1])
        self.assertIn("next week [= week of 2026-09-28]", out[2])

    def test_just_after_midnight(self):
        out = distil.anchor_relative_dates("2026-09-22 00:03|Dani|meet today at 12pm, not yesterday\n")
        self.assertIn("today at 12pm [= 2026-09-22 12:00]", out)
        self.assertIn("yesterday [= 2026-09-21]", out)

    def test_weekdays_named_with_on_or_this(self):
        # 2026-09-23 is a Wednesday.
        out = distil.anchor_relative_dates("2026-09-23 09:00|x|on Monday, this Friday, on Wednesday\n")
        self.assertIn("on Monday [= 2026-09-28]", out)
        self.assertIn("this Friday [= 2026-09-25]", out)
        self.assertIn("on Wednesday [= 2026-09-30]", out)

    def test_nothing_without_a_stamp_and_nothing_else_moves(self):
        self.assertEqual(distil.anchor_relative_dates("see you tomorrow\n"), "see you tomorrow\n")
        plain = "2026-09-21 10:00|x|the tomorrowland festival, a todays special\n"
        self.assertEqual(distil.anchor_relative_dates(plain), plain)

    def test_quoted_and_forwarded_words_are_not_pinned(self):
        text = ("2026-09-22 09:00|Dani|> Fwd from 2026-09-10: see you tomorrow\n"
                "2026-09-22 09:05|Dani|look at this Fwd: see you tomorrow\n"
                "  and tonight too\n"
                "---------- Forwarded message ---------\n"
                "2026-09-22 09:10|me|ok, tomorrow then\n")
        out = distil.anchor_relative_dates(text).splitlines()
        self.assertEqual(out[0], "2026-09-22 09:00|Dani|> Fwd from 2026-09-10: see you tomorrow")
        self.assertEqual(out[1], "2026-09-22 09:05|Dani|look at this Fwd: see you tomorrow")
        self.assertEqual(out[2], "  and tonight too", "the forwarded block runs on")
        self.assertIn("tomorrow [= 2026-09-23]", out[4], "a new message is pinned again")

    def test_the_model_is_handed_the_anchored_text(self):
        seen = {}

        def chat(system, user, key, **kw):
            seen["user"], seen["system"] = user, system
            return json.dumps({"claims": [], "questions": []})
        distil.distil("whatsapp", "2026-09-21 22:45|Eli|invite for tomorrow at 10\n", chat=chat)
        self.assertIn("tomorrow at 10 [= 2026-09-22 10:00]", seen["user"])
        self.assertIn("use exactly that date", seen["system"])


class SummaryDatesTest(ScratchCase):
    def test_a_relative_day_or_a_past_date_never_reaches_the_summary(self):
        self.assertTrue(cons.stale_for_summary("Has a Project Atlas call today at 10am", TODAY))
        self.assertTrue(cons.stale_for_summary("Dinner with Dani tomorrow", TODAY))
        self.assertTrue(cons.stale_for_summary("Project Atlas call on 2026-08-29 at 10:00", TODAY))
        self.assertFalse(cons.stale_for_summary("Project Atlas call on 2026-08-30 at 10:00", TODAY))
        self.assertFalse(cons.stale_for_summary("Builds Alfie, a Mac assistant", TODAY))

    def test_a_durable_fact_with_a_past_date_is_kept(self):
        for fact in ("Moved to Brooklyn on 2024-03-01", "Started Alfie 2026-08-01, main work"):
            self.assertFalse(cons.stale_for_summary(fact, TODAY), fact)
            self.assertFalse(cons.stale_for_summary(fact, TODAY, event=False), fact)
        self.assertTrue(cons.stale_for_summary("Moved to Brooklyn tomorrow", TODAY, event=False),
                        "the relative-day ban holds everywhere")

    def test_the_model_summary_keeps_dated_facts(self):
        store = Store(self.profile)
        store.write("identity", [C("identity", "Builds Alfie, a Mac assistant"), C("identity", "Lives in Monroe")])

        def chat(system, user, key, **kw):
            return json.dumps({"summary": ["Moved to Brooklyn on 2024-03-01", "Started Alfie 2026-08-01, main work",
                                           "Project Atlas call on 2026-08-29 at 10:00"], "check": []})
        cons.consolidate(store, use_llm=True, chat=chat)
        s = store.summary()
        self.assertIn("Moved to Brooklyn on 2024-03-01", s)
        self.assertIn("Started Alfie 2026-08-01", s)
        self.assertNotIn("Atlas", s)

    def test_the_plain_summary_keeps_dated_identity_facts(self):
        store = Store(self.profile)
        store.write("identity", [C("identity", "Moved to Brooklyn on 2024-03-01"),
                                 C("identity", "Started Alfie 2026-08-01, main work")])
        cons.consolidate(store, use_llm=False)
        s = store.summary()
        self.assertIn("Moved to Brooklyn", s)
        self.assertIn("Started Alfie", s)

    def test_the_model_summary_drops_them(self):
        store = Store(self.profile)
        store.write("identity", [C("identity", "Builds Alfie, a Mac assistant"), C("identity", "Lives in Monroe")])
        seen = {}

        def chat(system, user, key, **kw):
            seen["system"] = system
            return json.dumps({"summary": ["Builds Alfie, a Mac assistant", "Lives in Monroe",
                                           "Has a Project Atlas call today at 10am",
                                           "Trip to Austin on 2026-08-20"], "check": []})
        cons.consolidate(store, use_llm=True, chat=chat)
        s = store.summary()
        self.assertIn("Lives in Monroe", s)
        self.assertNotIn("today at 10am", s)
        self.assertNotIn("Austin", s)
        self.assertIn('never "today", "tomorrow", "tonight"', seen["system"])

    def test_the_plain_summary_drops_a_thread_whose_date_is_gone(self):
        store = Store(self.profile)
        store.write("identity", [C("identity", "Builds Alfie, a Mac assistant")])
        store.write("threads", [
            C("threads", "Runs Project Atlas with the Pulse team", kind="stable"),
            C("threads", "Atlas kickoff held on 2026-08-12", kind="stable"),
        ])
        cons.consolidate(store, use_llm=False)
        s = store.summary()
        self.assertIn("Runs Project Atlas", s)
        self.assertNotIn("kickoff", s)


if __name__ == "__main__":
    unittest.main()
