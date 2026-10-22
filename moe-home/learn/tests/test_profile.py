#!/usr/bin/env python3
"""profile.py: stable ids, correct, delete, render, and the CLI."""

import json
import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from helpers import ScratchCase, load, TODAY, LEARN  # noqa: E402

profile = load("profile")
Store, Claim = profile.Store, profile.Claim
SCRIPT = os.path.join(LEARN, "profile.py")


class IdTest(unittest.TestCase):
    def test_id_depends_on_file_and_text_only(self):
        a = Claim("people", "**Sam** — colleague", "alpha", "2026-01-01", "high")
        b = Claim("people", "  **Sam**   — colleague ", "beta", "2026-05-05", "low")
        c = Claim("identity", "**Sam** — colleague", "alpha", "2026-01-01", "high")
        self.assertEqual(a.id, b.id)
        self.assertNotEqual(a.id, c.id)
        self.assertEqual(len(a.id), 10)

    def test_line_parses_back(self):
        c = Claim("threads", "Ship the thing by 2026-09-01", "notes", "2026-08-01", "med")
        m = profile.CLAIM_RE.match(c.line())
        self.assertEqual(m.group("text"), c.text)
        self.assertEqual(m.group("source"), "notes")
        self.assertEqual(m.group("conf"), "med")


class StoreTest(ScratchCase):
    def setUp(self):
        super().setUp()
        self.store = Store(self.profile)
        self.store.write("people", [
            Claim("people", "**Zed** — cousin", "fixture", "2026-02-01", "low", "person:zed"),
            Claim("people", "**Ann** — colleague", "fixture", "2026-03-01", "high", "person:ann"),
        ])
        self.store.write("identity", [Claim("identity", "Lives in a small town", "fixture", "2026-04-01", "med")])

    def test_people_sorted_and_keys_kept(self):
        text = self.read("people.md")
        self.assertLess(text.index("**Ann**"), text.index("**Zed**"))
        claims = self.store.read("people")
        self.assertEqual([c.key for c in claims], ["person:ann", "person:zed"])
        self.assertTrue(self.read(".keys.json"))

    def test_hand_edited_file_still_reads(self):
        with open(os.path.join(self.profile, "identity.md"), "a") as f:
            f.write("some prose a human typed\n- Also cycles [user, 2026-05-05, high]\n")
        self.assertEqual([c.text for c in self.store.read("identity")], ["Lives in a small town", "Also cycles"])

    def test_delete_tombstones(self):
        cid = self.store.read("identity")[0].id
        gone = self.store.delete(cid)
        self.assertEqual(gone.text, "Lives in a small town")
        self.assertEqual(self.store.read("identity"), [])
        self.assertIn(cid, self.store.tombstones())
        self.assertIsNone(self.store.delete(cid))

    def test_correct_is_the_users_word(self):
        cid = [c for c in self.store.read("people") if "Ann" in c.text][0].id
        new = self.store.correct(cid, "**Ann** — my manager [pasted, 2020-01-01, low]")
        self.assertEqual(new.text, "**Ann** — my manager")
        self.assertEqual((new.source, new.date, new.confidence), ("user", TODAY, "high"))
        self.assertEqual(new.key, "person:ann")
        self.assertIn(cid, self.store.tombstones())
        self.assertNotEqual(new.id, cid)
        self.assertIn("**Ann** — my manager [user, %s, high]" % TODAY, self.read("people.md"))
        with self.assertRaises(ValueError):
            self.store.correct(new.id, "   ")

    def test_render_order_and_budget(self):
        self.store.write("threads", [Claim("threads", "A live thread", "fixture", "2026-08-01", "high")])
        self.store.write("voice", [Claim("voice", "Terse in chat", "fixture", "2026-08-01", "high")])
        text = profile.render(self.store)
        self.assertLess(text.index("## Identity"), text.index("## Threads"))
        self.assertLess(text.index("## Threads"), text.index("## People"))
        self.assertLess(text.index("## People"), text.index("## Voice"))
        self.assertIn("(fixture 2026-04)", text)
        # A tiny budget keeps identity whole and drops the rest at a line.
        small = profile.render(self.store, max_chars=60)
        self.assertLessEqual(len(small), 60)
        self.assertIn("## Identity", small)

    def test_render_is_under_hermes_cap_when_files_are_big(self):
        self.store.write("people", [Claim("people", "**Person%03d** — someone met at a thing, talks weekly" % i,
                                          "fixture", "2026-01-01", "low") for i in range(300)])
        self.assertLessEqual(len(profile.render(self.store)), 4000)
        self.assertIn("## Identity", profile.render(self.store))


class CliTest(ScratchCase):
    def run_cli(self, *args):
        p = subprocess.run([sys.executable, SCRIPT] + list(args), stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True)
        return p.returncode, p.stdout, p.stderr

    def test_list_show_correct_delete_expire(self):
        Store(self.profile).write("preferences", [
            Claim("preferences", "Prefers short answers", "fixture", "2026-08-01", "high"),
            Claim("preferences", "No calls before nine", "fixture", "2025-01-01", "med")])
        rc, out, _ = self.run_cli("list", "--json")
        rows = json.loads(out)
        self.assertEqual(rc, 0)
        self.assertEqual(len(rows), 2)
        cid = rows[0]["id"]
        rc, out, _ = self.run_cli("list")
        self.assertIn(cid, out)
        rc, out, _ = self.run_cli("show", "preferences")
        self.assertIn("# Preferences", out)
        rc, out, _ = self.run_cli("correct", cid, "Prefers one-line answers")
        self.assertEqual(rc, 0, out)
        self.assertIn("[user, %s, high]" % TODAY, out)
        rc, out, err = self.run_cli("delete", "0000000000")
        self.assertEqual(rc, 1)
        rc, out, _ = self.run_cli("expire", "--days", "365")
        self.assertIn("1 claim(s) expired", out)
        rc, out, _ = self.run_cli("list", "--json")
        self.assertEqual([r["text"] for r in json.loads(out)], ["Prefers one-line answers"])
        rc, out, _ = self.run_cli("show", "voice")
        self.assertIn("(nothing yet)", out)


class SecondPersonTest(unittest.TestCase):
    """Questions are said to the person: "your", never "the user's"."""

    def test_the_owners_three_questions(self):
        sp = profile.second_person
        self.assertEqual(sp("Is Rebecca the user's sister, and is 'Jordie' the user's regular nickname among family?"),
                         "Is Rebecca your sister, and is 'Jordie' your regular nickname among family?")
        self.assertEqual(sp("In a WhatsApp message the user introduced themselves as 'Casey Avery' — is that "
                            "another name they go by, distinct from Jordan Avery?"),
                         "In a WhatsApp message you introduced yourself as 'Casey Avery' — is that "
                         "another name you go by, distinct from Jordan Avery?")
        # "they" here is the brother AND the user: left alone.
        self.assertEqual(sp("Is the user's brother now running the food drive instead of the user this "
                            "year, or are they co-running it?"),
                         "Is your brother now running the food drive instead of you this year, "
                         "or are they co-running it?")

    def test_verbs_quotes_and_idempotence(self):
        sp = profile.second_person
        self.assertEqual(sp("Does the user still work at Acme?"), "Do you still work at Acme?")
        self.assertEqual(sp("Is the user in Denver?"), "Are you in Denver?")
        q = 'Which is right: "Calls the user Jordie" or "Ima calls the user Jordan"?'
        self.assertEqual(sp(q), q)          # quoted profile lines are how questions find them
        self.assertEqual(sp("Is Dani your sister?"), "Is Dani your sister?")
        for x in ("Is the user's brother here?", "The user introduced themselves as Al — is that what they go by?"):
            self.assertEqual(sp(sp(x)), sp(x))
        self.assertTrue(profile.same_question("Is Rebecca the user's sister?", "Is Rebecca your sister?"))


class AnswerDismissTest(ScratchCase):
    def run_cli(self, *args):
        p = subprocess.run([sys.executable, SCRIPT] + list(args), stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True)
        return p.returncode, p.stdout, p.stderr

    def setUp(self):
        super().setUp()
        os.makedirs(self.profile, exist_ok=True)
        with open(os.path.join(self.profile, "questions.md"), "w", encoding="utf-8") as f:
            f.write("# Questions for you\n\n- Is Rebecca the user's sister?\n- Still at the studio?\n")
        store = Store(self.profile)
        m = store.meta()
        m["check_extra"] = ["Is the user still in Denver?"]
        store.save_meta(m)

    def test_check_says_you(self):
        rc, out, _ = self.run_cli("check", "--json")
        self.assertEqual(rc, 0)
        texts = [it["text"] for it in json.loads(out)]
        self.assertIn("Is Rebecca your sister?", texts)
        self.assertIn("Are you still in Denver?", texts)
        self.assertFalse(any("the user" in t for t in texts))

    def test_answer_keeps_the_line_and_closes_the_question(self):
        rc, out, _ = self.run_cli("answer", "Is Rebecca your sister?", "Rebecca is my sister", "--json")
        self.assertEqual(rc, 0, out)
        obj = json.loads(out)
        self.assertTrue(obj["ok"])
        self.assertEqual(obj["claim"]["source"], "user")
        self.assertIn("- Rebecca is my sister [user, %s, high]" % TODAY, self.read("identity.md"))
        self.assertNotIn("Rebecca", self.read("questions.md"))
        self.assertIn("Still at the studio?", self.read("questions.md"))
        rc, out, _ = self.run_cli("answer", "Is Rebecca your sister?", "again", "--json")
        self.assertEqual(rc, 1)
        self.assertFalse(json.loads(out)["ok"])
        rc, _, _ = self.run_cli("answer", "Still at the studio?", "   ", "--json")
        self.assertEqual(rc, 2)

    def test_dismiss_closes_open_and_check_extra_questions(self):
        rc, out, _ = self.run_cli("dismiss", "Are you still in Denver?", "--json")
        self.assertEqual(rc, 0, out)
        self.assertEqual(Store(self.profile).meta().get("check_extra"), [])
        rc, _, _ = self.run_cli("dismiss", "Still at the studio?", "--json")
        self.assertEqual(rc, 0)
        rc, _, _ = self.run_cli("dismiss", "Is Rebecca the user's sister?")
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(os.path.join(self.profile, "questions.md")))
        rc, out, _ = self.run_cli("dismiss", "Never asked?", "--json")
        self.assertEqual(rc, 1)


class AddTest(ScratchCase):
    """`add`: "+ Add something Alfie should know" on the Memory page. The line
    is the person's own — source `user`, high, today — in the file they
    added it under, with that file's kind."""

    def run_cli(self, *args):
        p = subprocess.run([sys.executable, SCRIPT] + list(args), stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True)
        return p.returncode, p.stdout, p.stderr

    def test_add_writes_the_persons_own_line(self):
        rc, out, _ = self.run_cli("add", "identity", "  Lives in   Monroe, NJ ", "--json")
        self.assertEqual(rc, 0, out)
        obj = json.loads(out)
        self.assertTrue(obj["ok"])
        self.assertEqual(obj["claim"]["source"], "user")
        self.assertEqual(obj["claim"]["kind"], "stable")
        self.assertIn("- Lives in Monroe, NJ [user, %s, high]" % TODAY, self.read("identity.md"))
        rc, out, _ = self.run_cli("add", "threads", "Dentist on Friday", "--json")
        self.assertEqual(rc, 0, out)
        self.assertEqual(json.loads(out)["claim"]["kind"], "event")
        rc, out, _ = self.run_cli("add", "people", "**Dana** — co-founder", "--json")
        self.assertEqual(rc, 0, out)
        self.assertIn("- **Dana** — co-founder [user, %s, high]" % TODAY, self.read("people.md"))
        rows = json.loads(self.run_cli("list", "--json")[1])
        self.assertEqual(sorted(r["text"] for r in rows),
                         ["**Dana** — co-founder", "Dentist on Friday", "Lives in Monroe, NJ"])

    def test_add_twice_is_one_line_and_a_pasted_tag_is_dropped(self):
        self.run_cli("add", "preferences", "Short answers")
        self.run_cli("add", "preferences", "Short answers [gmail, 2026-01-01, low]")
        self.assertEqual(self.read("preferences.md").count("Short answers"), 1)
        self.assertIn("[user, %s, high]" % TODAY, self.read("preferences.md"))

    def test_add_refuses_empty_and_unknown_files(self):
        rc, out, _ = self.run_cli("add", "identity", "   ", "--json")
        self.assertEqual(rc, 2)
        self.assertFalse(json.loads(out)["ok"])
        rc, _, _ = self.run_cli("add", "nowhere", "x")
        self.assertNotEqual(rc, 0)
        self.assertFalse(os.path.exists(os.path.join(self.profile, "identity.md")))

    def test_an_archived_sentence_comes_back_rather_than_twice(self):
        store = Store(self.profile)
        c = Claim("threads", "Moved in March", "gmail", "2026-03-10", "high")
        store.write("threads", [c])
        store.archive([c], "past")
        store.write("threads", [])
        self.assertTrue(any(x.id == c.id for x in store.read_archive()))
        rc, out, _ = self.run_cli("add", "threads", "Moved in March", "--json")
        self.assertEqual(rc, 0, out)
        self.assertFalse(any(x.id == c.id for x in Store(self.profile).read_archive()))
        rows = [r for r in json.loads(self.run_cli("list", "--json")[1]) if r["text"] == "Moved in March"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["source"], "user")


class TidyRewritesOldQuestionsTest(ScratchCase):
    def test_nightly_tidy_fixes_a_third_person_questions_md(self):
        os.makedirs(self.profile, exist_ok=True)
        with open(os.path.join(self.profile, "questions.md"), "w", encoding="utf-8") as f:
            f.write("# Questions for you\n\n- Is Rebecca the user's sister?\n")
        cons = load("consolidate")
        store = cons.P.Store(self.profile)
        cons.tidy_questions(store, store.read_all(), [], ["Does the user still work at Acme?"])
        self.assertEqual(self.read("questions.md"),
                         "# Questions for you\n\n- Is Rebecca your sister?\n- Do you still work at Acme?\n")


if __name__ == "__main__":
    unittest.main()
