#!/usr/bin/env python3
"""Tests for migrate-memory.py against the synthetic fixture in fixture-memory/.

Run:  python3 -m unittest moe-home/hermes/tests/test_migrate_memory.py
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "migrate-memory.py")
FIXTURE = os.path.join(HERE, "fixture-memory")


def load_module():
    # The script has a hyphen in its name, so import it by path.
    spec = importlib.util.spec_from_file_location("migrate_memory", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class MigrateMemoryTest(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()
        self.tmp = tempfile.mkdtemp(prefix="moe-migrate-test-")
        self.moe_home = os.path.join(self.tmp, "moe")
        self.hermes_home = os.path.join(self.tmp, "hermes")
        shutil.copytree(FIXTURE, os.path.join(self.moe_home, "memory"))
        self.user = os.path.join(self.hermes_home, "memories", "USER.md")
        self.memory = os.path.join(self.hermes_home, "memories", "MEMORY.md")
        self.sidecar = os.path.join(self.hermes_home, "moe-migration.json")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, *extra):
        p = subprocess.run(
            [sys.executable, SCRIPT, "--moe-home", self.moe_home,
             "--hermes-home", self.hermes_home] + list(extra),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        return p.returncode, p.stdout + p.stderr

    def read(self, path):
        with open(path, encoding="utf-8") as f:
            return f.read()

    def entries(self, path):
        return self.read(path).split(self.mod.ENTRY_DELIMITER)

    # -- caps and format ---------------------------------------------------

    def test_fits_under_caps_with_margin(self):
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        user, memory = self.read(self.user), self.read(self.memory)
        # The fixture is deliberately larger than both caps combined, so the
        # packer has to leave things out.
        self.assertLessEqual(len(user), int(self.mod.USER_CHAR_LIMIT * 0.9))
        self.assertLessEqual(len(memory), int(self.mod.MEMORY_CHAR_LIMIT * 0.9))
        # …but not so timid that it wastes the room it has.
        self.assertGreater(len(user), self.mod.USER_CHAR_LIMIT * 0.5)
        self.assertGreater(len(memory), self.mod.MEMORY_CHAR_LIMIT * 0.5)

    def test_on_disk_format_matches_hermes(self):
        self.run_script()
        for path in (self.user, self.memory):
            raw = self.read(path)
            entries = raw.split(self.mod.ENTRY_DELIMITER)
            # Hermes strips each entry and re-joins; a file that round-trips
            # unchanged is one Hermes will not flag as externally drifted.
            self.assertEqual(self.mod.ENTRY_DELIMITER.join(e.strip() for e in entries if e.strip()), raw)
            for e in entries:
                self.assertNotIn("\n", e, "entries are single-line")
                self.assertNotIn("**", e, "markdown bold is stripped")

    def test_distils_not_copies(self):
        self.run_script()
        user, memory = self.entries(self.user), self.entries(self.memory)
        joined = " ".join(user)
        self.assertIn("Name: Pat Example", joined)
        self.assertIn("Where: Springfield", joined)
        # The crawl's own caveats section must not leak into the profile.
        self.assertNotIn("Before you trust", joined)
        self.assertNotIn("still don't know", joined.lower())
        mem = " ".join(memory)
        self.assertIn("Sam Example — sister", mem)
        self.assertIn("Never send anything", mem)
        # Dormant contacts are history, not memory.
        self.assertNotIn("Old Colleague", mem)
        # Newest projects win over older ones when there is not room for all.
        self.assertIn("2026-08-29: Rocket", mem)
        # No entry was cut mid-word with the truncation marker unless it had no
        # boundary to cut at — the fixture's long lines all have sentences.
        for e in user + memory:
            self.assertFalse(e.endswith("…"), e)

    def test_abbreviations_do_not_split(self):
        self.run_script()
        mem = " ".join(self.entries(self.memory))
        self.assertIn("Rabbi Dr. Lee Example — teacher", mem)

    # -- safety ------------------------------------------------------------

    def test_refuses_to_overwrite_without_force(self):
        os.makedirs(os.path.dirname(self.user))
        with open(self.user, "w") as f:
            f.write("hand-written")
        code, out = self.run_script()
        self.assertEqual(code, 2, out)
        self.assertEqual(self.read(self.user), "hand-written")
        self.assertFalse(os.path.exists(self.memory), "nothing written on refusal")
        self.assertFalse(os.path.exists(self.sidecar))

    def test_force_backs_up(self):
        os.makedirs(os.path.dirname(self.user))
        with open(self.user, "w") as f:
            f.write("hand-written")
        code, out = self.run_script("--force")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.read(self.user + ".bak"), "hand-written")
        self.assertNotEqual(self.read(self.user), "hand-written")

    def test_dry_run_writes_nothing(self):
        code, out = self.run_script("--dry-run")
        self.assertEqual(code, 0, out)
        self.assertIn("USER.md:", out)
        self.assertIn("MEMORY.md:", out)
        self.assertFalse(os.path.exists(self.hermes_home))

    def test_atomic_write_leaves_no_temp_files(self):
        self.run_script()
        leftovers = [n for n in os.listdir(os.path.dirname(self.user)) if n.startswith(".")]
        self.assertEqual(leftovers, [])

    def test_atomic_write_survives_failure(self):
        # A write that blows up mid-way must leave the old file intact and no
        # temp file behind.
        path = os.path.join(self.tmp, "target.md")
        with open(path, "w") as f:
            f.write("old")
        class Boom(Exception):
            pass
        real_replace = os.replace
        def failing_replace(a, b):
            raise Boom()
        os.replace = failing_replace
        try:
            with self.assertRaises(Boom):
                self.mod.atomic_write(path, "new")
        finally:
            os.replace = real_replace
        self.assertEqual(self.read(path), "old")
        self.assertEqual([n for n in os.listdir(self.tmp) if n.startswith(".moe-migrate-")], [])

    # -- idempotence -------------------------------------------------------

    def test_sidecar_makes_second_run_a_noop(self):
        self.run_script()
        side = json.loads(self.read(self.sidecar))
        self.assertEqual(set(side["sources"]), set(self.mod.SOURCE_FILES))
        self.assertIn("migrated_at", side)
        first = self.read(self.user)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertIn("already migrated", out)
        self.assertEqual(self.read(self.user), first)

    def test_changed_source_is_detected(self):
        self.run_script()
        before = json.loads(self.read(self.sidecar))
        about_me = os.path.join(self.moe_home, "memory", "about-me.md")
        # Put the new fact first: about-me has a fixed share of USER.md and
        # a fact appended at the end would rightly be the one left out.
        with open(about_me, encoding="utf-8") as f:
            original = f.read()
        with open(about_me, "w", encoding="utf-8") as f:
            f.write(original.replace("- **Name:**", "- **New fact:** something changed.\n- **Name:**", 1))
        code, out = self.run_script()
        # Sources changed, so it is not a no-op — and the outputs exist, so it
        # refuses rather than clobbering. --force is the explicit path.
        self.assertEqual(code, 2, out)
        self.assertIn("refusing to overwrite", out)
        code, out = self.run_script("--force")
        self.assertEqual(code, 0, out)
        self.assertIn("New fact: something changed.", self.read(self.user))
        after = json.loads(self.read(self.sidecar))
        self.assertNotEqual(before["sources"]["about-me.md"], after["sources"]["about-me.md"])
        self.assertEqual(before["sources"]["soul.md"], after["sources"]["soul.md"])

    def test_missing_memory_dir(self):
        shutil.rmtree(os.path.join(self.moe_home, "memory"))
        code, out = self.run_script()
        self.assertEqual(code, 1)
        self.assertIn("nothing to migrate", out)

    # -- a fresh install's unfilled notes --------------------------------

    @staticmethod
    def shipped_note(name):
        """The template FirstRun.swift writes on a fresh install, verbatim —
        the artefact, not a copy of it, so a template change reaches this
        test."""
        import re
        swift = os.path.join(HERE, "..", "..", "..", "Sources", "Moe", "FirstRun.swift")
        with open(swift, encoding="utf-8") as f:
            src = f.read()
        m = re.search(r'static let %s = """\n(.*?)\n\s*"""' % name, src, re.S)
        assert m, "FirstRun.swift no longer has a `%s` template" % name
        lines = m.group(1).split("\n")
        indent = min(len(l) - len(l.lstrip()) for l in lines if l.strip())
        return "\n".join(l[indent:] for l in lines) + "\n"

    def write_shipped_notes(self):
        mem = os.path.join(self.moe_home, "memory")
        shutil.rmtree(mem)
        os.makedirs(mem)
        for swift_name, filename in (("aboutMe", "about-me.md"), ("people", "people.md"),
                                     ("projects", "projects.md"), ("preferences", "preferences.md")):
            with open(os.path.join(mem, filename), "w", encoding="utf-8") as f:
                f.write(self.shipped_note(swift_name))

    def test_unfilled_template_seeds_no_user_facts(self):
        """Day one on the owner's Mac (2026-09-16): about-me.md was the
        shipped form, untouched, and USER.md came out as six labels —
        "Name:", "What I do:", … — which then sat in every system prompt for
        a week. A label with nothing after it is not a fact about anyone."""
        self.write_shipped_notes()
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.read(self.user), "", "USER.md should be empty, got: %r"
                         % self.read(self.user))
        for label in ("Name:", "What I do:", "Where I am / timezone:",
                      "Family and the people I talk about most:",
                      "What I'm working on right now:", "What I want Alfie to handle for me:"):
            self.assertNotIn(label, self.read(self.memory))
        # The two shipped preferences are real defaults and still travel.
        self.assertIn("Answers: short and spoken", self.read(self.memory))

    def test_filled_lines_kept_unfilled_lines_dropped(self):
        """The same form, half filled in: what the person typed is a fact,
        what they left blank is not."""
        self.write_shipped_notes()
        about = os.path.join(self.moe_home, "memory", "about-me.md")
        text = self.read(about).replace("- Name:\n", "- Name: Pat Example\n")
        text = text.replace("- Where I am / timezone:\n", "- Where I am / timezone: Springfield, US/Eastern\n")
        with open(about, "w", encoding="utf-8") as f:
            f.write(text)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        entries = self.entries(self.user)
        self.assertEqual(entries, ["Name: Pat Example", "Where I am / timezone: Springfield, US/Eastern"])

    def test_is_placeholder(self):
        p = self.mod.is_placeholder
        self.assertTrue(p("Name:"))
        self.assertTrue(p("**What I do:**"))
        self.assertTrue(p("Family and the people I talk about most: "))
        self.assertFalse(p("Name: Pat"))
        self.assertFalse(p("Keeps a strict no-meetings rule before 11am."))
        self.assertFalse(p("Never send anything on my behalf without reading it to me first."))
        # A sentence that happens to end in a colon and has clauses is not a label.
        self.assertFalse(p("Rule: no meetings before 11am, ever, unless the client asks:"))


if __name__ == "__main__":
    unittest.main()
