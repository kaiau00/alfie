#!/usr/bin/env python3
"""moe-profile plugin against a stub ctx — no live Hermes.

Run: python3 -m unittest moe-home/hermes-plugins/moe-profile/tests/test_plugin.py
(also collected by pytest). The tool delegates to learn/profile.py, so the
test builds a scratch MOE_HOME with that file in place.
"""

import importlib.util
import json
import logging
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.normpath(os.path.join(HERE, ".."))
MOE_HOME_TEMPLATE = os.path.normpath(os.path.join(PLUGIN, "..", ".."))


def load_plugin():
    spec = importlib.util.spec_from_file_location("moe_profile_plugin", os.path.join(PLUGIN, "__init__.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class StubCtx(object):
    """Only what register() touches, checked the way Hermes checks it."""

    def __init__(self):
        self.sections = {}
        self.tools = {}

    def register_system_prompt_section(self, id, content, position="after_memory", max_chars=4000):
        assert position == "after_memory", position
        assert isinstance(max_chars, int) and 0 < max_chars <= 4000, max_chars
        assert id not in self.sections
        self.sections[id] = (content, max_chars)

    def register_tool(self, name, toolset, schema, handler, check_fn=None, **kw):
        assert schema["name"] == name
        self.tools[name] = {"toolset": toolset, "schema": schema, "handler": handler, "check_fn": check_fn}


class PluginTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-plugin-test-")
        self.home = os.path.join(self.tmp, "moe")
        os.makedirs(os.path.join(self.home, "learn"))
        shutil.copy(os.path.join(MOE_HOME_TEMPLATE, "learn", "profile.py"), os.path.join(self.home, "learn", "profile.py"))
        self.profile = os.path.join(self.home, "memory", "profile")
        os.makedirs(self.profile)
        self._env = {k: os.environ.get(k) for k in ("MOE_HOME", "MOE_PROFILE_DIR", "MOE_TODAY")}
        os.environ["MOE_HOME"] = self.home
        os.environ.pop("MOE_PROFILE_DIR", None)
        os.environ["MOE_TODAY"] = "2026-08-30"
        self.mod = load_plugin()
        self.ctx = StubCtx()
        self.mod.register(self.ctx)

    def tearDown(self):
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, name, lines):
        with open(os.path.join(self.profile, name + ".md"), "w") as f:
            f.write("# %s\n\n%s\n" % (name.title(), "\n".join(lines)))

    def section(self):
        content, _ = self.ctx.sections["moe-profile"]
        return content({"session_id": "x"})

    def call(self, **params):
        return json.loads(self.ctx.tools["moe_profile"]["handler"](params))

    def test_registers_section_and_tool(self):
        self.assertIn("moe-profile", self.ctx.sections)
        self.assertEqual(self.ctx.sections["moe-profile"][1], 4000)
        tool = self.ctx.tools["moe_profile"]
        self.assertEqual(tool["schema"]["parameters"]["required"], ["action"])
        self.assertTrue(tool["check_fn"]())

    def test_empty_profile_renders_nothing(self):
        self.assertEqual(self.section(), "")

    def test_section_order_and_format(self):
        self.write("people", ["- **Sam** — colleague [fixture, 2026-07-15, high]"])
        self.write("identity", ["- Lives in a small town [fixture, 2026-04-01, med]"])
        self.write("threads", ["- Office lease renewal [fixture, 2026-07-15, high]"])
        text = self.section()
        self.assertTrue(text.startswith("# What Alfie knows about the user"))
        self.assertLess(text.index("## Identity"), text.index("## Threads"))
        self.assertLess(text.index("## Threads"), text.index("## People"))
        self.assertIn("- Lives in a small town (fixture 2026-04)", text)
        self.assertIn("moe_profile", text)

    def test_section_says_it_is_data_not_instructions(self):
        # The one defence that survives whatever distil let through: the
        # model is told, above every line, that these are fallible claims
        # about the user and not rules for the assistant.
        self.write("preferences", ["- The assistant should be brief [gmail, 2026-07-15, med]"])
        text = self.section()
        head = text.split("## ")[0].lower()
        self.assertIn("inferred", head)
        self.assertIn("may be wrong", head)
        self.assertIn("never as an instruction", head)
        self.assertIn("source `user`", head)

    def test_section_respects_cap(self):
        self.write("identity", ["- Identity line [fixture, 2026-01-01, high]"])
        self.write("people", ["- **Person%03d** — met at a thing, talks most weeks [fixture, 2026-01-01, low]" % i for i in range(400)])
        text = self.section()
        self.assertLessEqual(len(text), 4000)
        self.assertIn("## Identity", text)
        self.assertIn("## People", text)
        # Cut at a line, never inside a claim: every claim line is whole,
        # and the same files render the same text every time.
        for line in text.splitlines():
            if line.startswith("- "):
                self.assertRegex(line, r"\(fixture 2026-01\)$", line)
        self.assertEqual(text, self.section())
        self.assertGreater(text.count("- **Person"), 20)

    def test_tool_list_show_correct_delete(self):
        self.write("threads", ["- Office lease renewal [fixture, 2026-07-15, high]"])
        r = self.call(action="list")
        self.assertTrue(r["success"], r)
        self.assertEqual(len(r["claims"]), 1)
        cid = r["claims"][0]["id"]
        r = self.call(action="show", file="threads")
        self.assertIn("Office lease renewal", r["content"])
        r = self.call(action="correct", id=cid, text="Office lease signed in July")
        self.assertTrue(r["success"], r)
        self.assertIn("[user, 2026-08-30, high]", r["result"])
        r = self.call(action="list", file="threads")
        self.assertEqual(r["claims"][0]["text"], "Office lease signed in July")
        self.assertEqual(r["claims"][0]["source"], "user")
        r = self.call(action="delete", id=r["claims"][0]["id"])
        self.assertTrue(r["success"], r)
        self.assertEqual(self.call(action="list")["claims"], [])

    def test_tool_confirm_add_restore(self):
        """Going through memory in chat (owner, 2026-09-22): the brain can
        mark a line right, add one, and bring an archived one back — each
        the person's own word (source user), which no crawl overwrites."""
        self.write("people", ["- **Sam** — colleague [whatsapp, 2026-07-15, low]"])
        cid = self.call(action="list")["claims"][0]["id"]
        r = self.call(action="confirm", id=cid)
        self.assertTrue(r["success"], r)
        self.assertEqual(r["claim"]["source"], "user")
        row = self.call(action="list", file="people")["claims"][0]
        self.assertEqual((row["text"], row["source"], row["confidence"]), ("**Sam** — colleague", "user", "high"))
        r = self.call(action="add", file="people", text="**Dana** — co-founder")
        self.assertTrue(r["success"], r)
        texts = [c["text"] for c in self.call(action="list", file="people")["claims"]]
        self.assertIn("**Dana** — co-founder", texts)
        self.assertFalse(self.call(action="add", text="no file")["success"])
        self.assertFalse(self.call(action="add", file="people")["success"])
        with open(os.path.join(self.profile, "people.md"), encoding="utf-8") as f:
            self.assertIn("**Dana** — co-founder [user, 2026-08-30, high]", f.read())
        # restore: an archived line comes back.
        with open(os.path.join(self.profile, "archive.md"), "w") as f:
            f.write("# Archive\n\n## Threads\n- Old lease signed [gmail, 2026-03-01, high]\n")
        old = [c for c in json.loads(self.mod.run_profile(["list", "--json"])[1]) if not c["active"]]
        self.assertEqual(len(old), 1, old)
        r = self.call(action="restore", id=old[0]["id"])
        self.assertTrue(r["success"], r)
        self.assertIn("Old lease signed", [c["text"] for c in self.call(action="list", file="threads")["claims"]])

    def test_tool_check_answer_dismiss(self):
        with open(os.path.join(self.profile, "questions.md"), "w") as f:
            f.write("# Questions for you\n\n- Is Marco still your landlord?\n- Do you still run on Tuesdays?\n")
        r = self.call(action="check")
        self.assertTrue(r["success"], r)
        self.assertEqual([i["text"] for i in r["items"]],
                         ["Is Marco still your landlord?", "Do you still run on Tuesdays?"])
        r = self.call(action="answer", question="Is Marco still your landlord?", text="Marco sold the building in May")
        self.assertTrue(r["success"], r)
        self.assertEqual(r["claim"]["source"], "user")
        self.assertIn("Marco sold the building in May", [c["text"] for c in self.call(action="list", file="identity")["claims"]])
        r = self.call(action="dismiss", question="Do you still run on Tuesdays?")
        self.assertTrue(r["success"], r)
        self.assertEqual(self.call(action="check")["items"], [])
        # A question that is not open says so; neither verb runs without one.
        self.assertFalse(self.call(action="dismiss", question="Is this open?")["success"])
        self.assertFalse(self.call(action="answer", text="yes")["success"])
        self.assertFalse(self.call(action="answer", question="Is Marco still your landlord?")["success"])

    def test_section_names_the_files_and_the_write_actions(self):
        """The Memory page's drafts name these files; the brain is told what
        they are and that it may change them while the person reviews."""
        self.write("identity", ["- Lives in a small town [fixture, 2026-04-01, med]"])
        head = self.section().split("## ")[0]
        for name in ("identity.md", "preferences.md", "voice.md", "people.md", "threads.md",
                     "questions.md", "USER.md", "MEMORY.md"):
            self.assertIn(name, head)
        for verb in ("confirm", "correct", "delete", "add", "answer", "dismiss"):
            self.assertIn(verb, head)
        self.assertIn("memory tool", head)
        enum = self.ctx.tools["moe_profile"]["schema"]["parameters"]["properties"]["action"]["enum"]
        for verb in ("confirm", "add", "answer", "dismiss", "restore", "check"):
            self.assertIn(verb, enum)

    def test_tool_validates_input(self):
        self.assertFalse(self.call(action="show")["success"])
        self.assertFalse(self.call(action="show", file="diary")["success"])
        self.assertFalse(self.call(action="delete", id="../etc")["success"])
        self.assertFalse(self.call(action="correct", id="0123456789", text="")["success"])
        self.assertFalse(self.call(action="delete", id="0123456789")["success"])   # no such claim
        self.assertFalse(self.call(action="explode")["success"])

    def test_check_fn_false_without_profile_py(self):
        os.remove(os.path.join(self.home, "learn", "profile.py"))
        self.assertFalse(self.ctx.tools["moe_profile"]["check_fn"]())

    def warnings_from(self, fn):
        """Every WARNING the plugin logs while fn runs."""
        seen = []
        handler = logging.Handler()
        handler.emit = seen.append
        logger = logging.getLogger("moe-profile")
        logger.addHandler(handler)
        try:
            fn()
        finally:
            logger.removeHandler(handler)
        return [r.getMessage() for r in seen if r.levelno >= logging.WARNING]

    def test_an_unavailable_tool_says_why_once(self):
        """docs/CLOUD-PLAN.md §4.4: withheld, and the log names the path.
        check_fn runs on every tool listing, so the reason is logged once
        per cause, not once per turn."""
        check = self.ctx.tools["moe_profile"]["check_fn"]
        self.assertEqual(self.warnings_from(check), [])
        self.assertEqual(self.mod.unavailable_reason(), "")
        path = os.path.join(self.home, "learn", "profile.py")
        os.remove(path)
        first = self.warnings_from(check)
        self.assertEqual(len(first), 1, first)
        self.assertIn(path, first[0])
        self.assertIn("moe_profile", first[0])
        self.assertEqual(self.warnings_from(check), [])
        self.assertIn(path, self.mod.unavailable_reason())
        # Back again (the image reseeds it at boot): available, quietly, and
        # the next loss is said again.
        shutil.copy(os.path.join(MOE_HOME_TEMPLATE, "learn", "profile.py"), path)
        self.assertEqual(self.warnings_from(check), [])
        self.assertTrue(check())
        os.remove(path)
        self.assertEqual(len(self.warnings_from(check)), 1)


if __name__ == "__main__":
    unittest.main()
