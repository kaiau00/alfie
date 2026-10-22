#!/usr/bin/env python3
"""sensitive.py: the code-enforced refusal, on synthetic lines shaped like
the ones the 2026-09-22 audit found in a real profile (none of them real)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from helpers import load, TODAY  # noqa: E402

sensitive = load("sensitive")
distil = load("distil")

# (line, category) — each shaped like a leak the audit saw.
LEAKS = [
    ("Pays the cleaner through Zelle at 201-555-0147", "phone"),
    ("**Shmuel Katz** — landlord; reach him at shmuel.k@example.com", "email"),
    ("Parents live at 14 Elm Grove Road, Lakewood", "address"),
    ("Rents a flat at 22 Oak Street, apt 4B for the summer", "address"),
    ("Lives at 9 Birch Lane", "address"),
    ("Mother's home address is on Rechov HaPalmach", "address"),
    ("Flat in Katamon, rent is $2,300 a month", "money"),
    ("Scheduled to build Levi's sukkah Tuesday 6pm for $400", "money"),
    ("Charges 350 shekels per session", "money"),
    ("Sends rent by Zelle", "payment"),
    ("Venmo handle is on file for the carpool", "payment"),
    ("Member of Clalit health fund", "health"),
    ("Sees a therapist every Thursday", "health"),
    ("Has been dealing with anxiety since the spring", "health"),
    ("Health insurance renewal with the kupat cholim is pending", "health"),
    ("Wife is pregnant with their third", "health"),
    ("password is hunter2hunter", "secret"),
    ("Card 4111 1111 1111 1111 on the shared account", "secret"),
    ("Call Dani on +972 52 555 0123", "phone"),
    ("IBAN for the Israeli account is saved in notes", "payment"),
    ("Parents live on Rechov Bar Ilan 12 in Ramat Gan", "address"),
    ("Keeps his mother's address for deliveries", "address"),
    ("Lives on Maple Avenue near the park", "address"),
    ("Rent for the flat is 2300 a month", "money"),
    ("Moved into apartment number 7 last spring", "address"),
]

# The owner's own world: must survive.
KEEP = [
    "Works as a software founder building Alfie, a Mac assistant",
    "Lives in Jerusalem",
    "Speaks Hebrew and English; writes to family in Hebrew",
    "**Dani** — sister; talks daily, mostly family news",
    "Builds sukkahs for friends most autumns",
    "Launch planned for 2026-10-15",
    "Worked at Pulse from 2024-2026",
    "Cares about token limits in LLM context windows",
    "Builds a diagnostics dashboard for the Pulse app",
    "Uses Cloudflare for routing traffic to his app",
    "Prefers short replies in the evening",
    "Keeps weekly Sunday calls with his parents",
    "Runs 5 km most mornings",
    "Rents a flat in Katamon",
    "Moved to Jerusalem in 2026-03",
    "Works on the Alfie 0.4 release",
    "Drives the kids to school on Sundays",
    "Plans a trip to Italy with 4 friends",
]


class SensitiveTest(unittest.TestCase):
    def test_a_question_with_a_phone_number_is_not_kept(self):
        import json
        _, qs = distil.parse_reply(json.dumps({"claims": [], "questions": [
            "Is 052-555-0147 Dani's number?", "Is Kim a sibling or a partner?"]}), TODAY)
        self.assertEqual(qs, ["Is Kim a sibling or a partner?"])

    def test_every_leak_is_refused_with_its_category(self):
        for line, cat in LEAKS:
            self.assertEqual(sensitive.reason(line), cat, line)

    def test_the_owners_world_is_kept(self):
        for line in KEEP:
            self.assertEqual(sensitive.reason(line), "", line)

    def test_parse_reply_drops_and_counts_them(self):
        import json
        claims = [{"file": "identity", "text": t, "date": "2026-08-01", "confidence": "high"} for t, _ in LEAKS]
        claims += [{"file": "identity", "text": t, "date": "2026-08-01", "confidence": "high"} for t in KEEP]
        stats = {}
        got, _ = distil.parse_reply(json.dumps({"claims": claims}), TODAY, stats)
        self.assertEqual(stats.get("sensitive"), len(LEAKS))
        texts = [c["text"] for c in got]
        for t, _ in LEAKS:
            self.assertNotIn(t, texts)
        self.assertEqual(len(got), len(KEEP))


if __name__ == "__main__":
    unittest.main()
