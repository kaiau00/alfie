#!/usr/bin/env python3
"""consent.sh: no consent means no, the file shape, and the prompt's answers."""

import json
import os
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from helpers import ScratchCase, MOE_HOME, TODAY  # noqa: E402

FIXTURE_CONN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixture-connectors")


class ConsentTest(ScratchCase):
    def setUp(self):
        super().setUp()
        # A scratch MOE_HOME with the real lib/ and learn/ and only the
        # synthetic connector, so a stray name can never reach a real one.
        home = os.environ["MOE_HOME"]
        os.makedirs(home)
        shutil.copytree(os.path.join(MOE_HOME, "lib"), os.path.join(home, "lib"))
        shutil.copytree(os.path.join(MOE_HOME, "learn"), os.path.join(home, "learn"), ignore=shutil.ignore_patterns("tests"))
        shutil.copytree(FIXTURE_CONN, os.path.join(home, "connectors"))
        self.script = os.path.join(home, "learn", "consent.sh")

    def run_consent(self, *args, stdin=None):
        env = dict(os.environ)
        if stdin is not None:
            env["MOE_CONSENT_STDIN"] = "1"
        p = subprocess.run(["bash", self.script] + list(args), input=stdin or "", stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True, env=env)
        return p.returncode, p.stdout, p.stderr

    def consent_json(self):
        return json.loads(self.read("consent.json"))

    def test_no_consent_is_no(self):
        self.assertEqual(self.run_consent("check", "fixture")[0], 1)
        self.assertEqual(self.read("consent.json"), "")

    def test_unknown_source_refused(self):
        rc, _, err = self.run_consent("grant", "nonesuch")
        self.assertEqual(rc, 2)
        self.assertIn("not a connector", err)
        self.assertEqual(self.run_consent("grant", "../x")[0], 2)

    def test_grant_revoke_shape(self):
        rc, out, _ = self.run_consent("grant", "fixture")
        self.assertEqual(rc, 0)
        self.assertEqual(self.consent_json(), {"fixture": {"granted": True, "date": TODAY}})
        self.assertEqual(self.run_consent("check", "fixture")[0], 0)
        self.run_consent("revoke", "fixture")
        self.assertEqual(self.consent_json()["fixture"]["granted"], False)
        self.assertEqual(self.run_consent("check", "fixture")[0], 1)
        rc, out, _ = self.run_consent("show")
        self.assertIn("fixture", out)
        self.assertIn("refused", out)

    def test_ask_says_what_and_where(self):
        rc, out, _ = self.run_consent("ask", "fixture", stdin="y\n")
        self.assertEqual(rc, 0, out)
        self.assertIn("stays on this Mac", out)
        self.assertIn("Fixture source", out)          # the manifest label
        self.assertIn("revoke fixture", out)
        self.assertTrue(self.consent_json()["fixture"]["granted"])

    def test_ask_default_is_no(self):
        rc, out, _ = self.run_consent("ask", "fixture", stdin="\n")
        self.assertEqual(rc, 1)
        self.assertFalse(self.consent_json()["fixture"]["granted"])
        rc, _, _ = self.run_consent("ask", "fixture", stdin="nope\n")
        self.assertEqual(rc, 1)

    def test_ask_without_terminal_cannot_consent(self):
        rc, out, _ = self.run_consent("ask", "fixture")     # stdin is a pipe, no override
        self.assertEqual(rc, 1)
        self.assertIn("no terminal", out)
        self.assertEqual(self.read("consent.json"), "")

    def test_forged_shapes_are_no(self):
        # A hand-written consent.json in the wrong shape must not count as
        # consent, and must not crash the gate into an unclear state.
        path = os.path.join(self.profile, "consent.json")
        os.makedirs(self.profile, exist_ok=True)
        for forged in ('{"fixture": true}', '{"fixture": "granted"}', '["fixture"]',
                       '{"fixture": {"granted": "true"}}', '{"fixture": {"granted": 1}}', "not json"):
            with open(path, "w") as f:
                f.write(forged)
            rc, out, err = self.run_consent("check", "fixture")
            self.assertEqual(rc, 1, forged)
            self.assertNotIn("Traceback", err, forged)

    def test_ask_is_a_noop_once_granted(self):
        self.run_consent("grant", "fixture")
        rc, out, _ = self.run_consent("ask", "fixture")
        self.assertEqual(rc, 0)
        self.assertEqual(out, "")


class NativesListedTest(unittest.TestCase):
    """Every Mac source Alfie reads by itself has a row, since each needs its
    own "Learn and watch" yes (2026-09-29): one it only keeps ready (Apple
    Mail: pull and items, no read-back) as well as one it reads back."""

    def test_a_pull_only_source_is_listed_and_a_non_reader_is_not(self):
        import importlib.util
        import tempfile
        here = os.path.dirname(os.path.abspath(__file__))
        spec = importlib.util.spec_from_file_location("consent_list_t", os.path.join(here, "..", "consent_list.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        d = tempfile.mkdtemp()
        try:
            for name, body in (("mail", "verbs=status pull items\ndeep_crawl=no\n"),
                               ("notes", "verbs=status pull crawl\ndeep_crawl=yes\n"),
                               ("contacts", "verbs=status find\ndeep_crawl=no\n"),
                               ("channels", "verbs=status register\ndeep_crawl=no\n")):
                with open(os.path.join(d, name + ".manifest"), "w") as f:
                    f.write(body)
            mod.conn_dir = lambda: d
            self.assertEqual(sorted(n for n, _ in mod.natives()), ["mail", "notes"])
        finally:
            shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
