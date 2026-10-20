#!/usr/bin/env python3
"""shorten.py — the one-time rewrite of long profile lines (owner,
2026-09-22, "make it simpler"). Dry run by default; the person's own lines
are never touched; a model proposal is checked before it is accepted."""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from helpers import ScratchCase, load  # noqa: E402

profile = load("profile")
shorten = load("shorten")
Claim = profile.Claim

SHAINDY = ("**Rebecca** — family member (likely sister); calls the user by the nickname 'Jordie' "
           "and keeps him informed of family events")
MINE = "**Daniel** — brother, runs the food drive with me each and every fall season"


class ShortenTest(ScratchCase):
    def setUp(self):
        super().setUp()
        store = profile.Store()
        store.write("people", [Claim("people", SHAINDY, "whatsapp", "2026-08-01", "med"),
                               Claim("people", "**Eli** — colleague", "whatsapp", "2026-08-01", "med"),
                               Claim("people", MINE, "user", "2026-08-01", "high")])
        store.write("threads", [Claim("threads", "The user is planning a trip to Southeast Asia", "whatsapp",
                                      "2026-08-01", "high")])
        self.store = store

    def fake(self, answers):
        calls = []

        def chat(system, user, key, timeout=120, enabled_toolsets=None):
            calls.append((system, user, enabled_toolsets))
            ids = [json.loads(ln)["id"] for ln in user.splitlines() if ln.startswith("{")]
            return json.dumps({"lines": [{"id": i, "text": answers.get(i, "")} for i in ids]})
        return chat, calls

    def ids(self):
        return {c.text: c.id for f in ("people", "threads") for c in self.store.read(f)}

    def test_only_long_crawled_lines_and_never_the_persons_own(self):
        texts = [c.text for c in shorten.candidates(self.store)]
        self.assertIn(SHAINDY, texts)
        self.assertIn("The user is planning a trip to Southeast Asia", texts)   # says "the user"
        self.assertNotIn("**Eli** — colleague", texts)                           # already short
        self.assertNotIn(MINE, texts)                                           # source user

    def test_model_proposals_are_checked(self):
        i = self.ids()
        chat, calls = self.fake({i[SHAINDY]: "**Rebecca** — sister",
                                 i["The user is planning a trip to Southeast Asia"]: "The user travels"})
        rows = {c.text: (new, why) for c, new, why in shorten.plan(self.store, chat=chat)}
        self.assertEqual(rows[SHAINDY], ("**Rebecca** — sister", None))
        self.assertEqual(rows["The user is planning a trip to Southeast Asia"], (None, "still says the user"))
        self.assertTrue(all(ts == ["none"] for _, _, ts in calls), calls)       # no tools
        self.assertTrue(all("=== LINES" in u for _, u, _ in calls))            # fenced as data
        # A renamed person, or a line that is not shorter, is refused.
        chat, _ = self.fake({i[SHAINDY]: "**Becky** — sister"})
        rows = {c.text: why for c, _, why in shorten.plan(self.store, chat=chat)}
        self.assertEqual(rows[SHAINDY], "name changed")

    def test_dry_run_writes_nothing_and_apply_corrects_as_the_persons_word(self):
        before = self.read("people.md")
        self.assertEqual(shorten.main(["--no-llm", "--json"]), 0)
        self.assertEqual(self.read("people.md"), before)
        self.assertEqual(shorten.main(["--no-llm", "--apply", "--json"]), 0)
        people = {c.text: c for c in profile.Store().read("people")}
        self.assertIn("**Rebecca** — family member", people)
        self.assertEqual(people["**Rebecca** — family member"].source, "user")
        self.assertIn(MINE, people)                                             # untouched
        self.assertNotIn(SHAINDY, people)
        threads = [c.text for c in profile.Store().read("threads")]
        self.assertEqual(threads, ["Planning a trip to Southeast Asia"])


if __name__ == "__main__":
    unittest.main()
