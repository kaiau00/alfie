"""The blueprint tools, against Hermes's real catalog.

No stubbing of the catalog: the whole point of the plugin is that Hermes's 16
templates are real and were unreachable, so a test that mocks them would pass
on a machine where the feature does not work.
"""

import importlib.util
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = os.path.expanduser("~/.hermes/hermes-agent")
if os.path.isdir(AGENT) and AGENT not in sys.path:
    sys.path.insert(0, AGENT)

_spec = importlib.util.spec_from_file_location(
    "moe_blueprints", os.path.join(os.path.dirname(HERE), "__init__.py"))
plugin = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(plugin)


def _hermes_cron_available():
    try:
        import cron.blueprint_catalog  # noqa: F401
        return True
    except Exception:
        return False


@unittest.skipUnless(_hermes_cron_available(), "needs a Hermes checkout")
class BlueprintListTest(unittest.TestCase):
    def test_lists_every_blueprint_with_its_questions(self):
        out = json.loads(plugin._list())
        self.assertTrue(out["success"])
        self.assertGreaterEqual(len(out["blueprints"]), 16)
        mb = [b for b in out["blueprints"] if b["key"] == "morning-brief"]
        self.assertTrue(mb, "morning-brief missing from the catalog")
        asks = {a["name"] for a in mb[0]["asks"]}
        # `deliver` is Moe's to answer, never a question — the owner was
        # asked "here, Telegram only, WhatsApp only, or a file?" with no chat
        # app connected (2026-09-11).
        self.assertEqual(asks, {"time"})

    def test_every_entry_carries_what_the_model_must_ask(self):
        """A blueprint with no `asks` is one the model would fill by guessing."""
        for b in json.loads(plugin._list())["blueprints"]:
            self.assertTrue(b["key"], b)
            self.assertIsInstance(b["asks"], list)


@unittest.skipUnless(_hermes_cron_available(), "needs a Hermes checkout")
class BlueprintCreateGuardsTest(unittest.TestCase):
    """Everything here must fail BEFORE create_job, so no test writes a job
    into the caller's real cron store. The one path that would create is not
    exercised — it is covered live, once, by hand."""

    def test_an_unknown_key_is_refused(self):
        out = json.loads(plugin._create({"key": "nope", "values": {}}))
        self.assertFalse(out["success"])
        self.assertIn("no blueprint called", out["error"])

    def test_a_missing_key_is_refused(self):
        out = json.loads(plugin._create({"values": {}}))
        self.assertFalse(out["success"])
        self.assertIn("key is required", out["error"])

    def test_defaults_are_not_answers(self):
        """Every slot of custom-reminder is non-optional AND has a default —
        `what` defaults to "take a break and stretch". Accepting defaults meant
        a user who said "remind me daily" got somebody else's reminder, at
        somebody else's time, delivered somewhere they would never look. That
        job was really created during development; this is why."""
        out = json.loads(plugin._create({"key": "custom-reminder", "values": {}}))
        self.assertFalse(out["success"])
        for slot in ("what", "time", "recurrence"):
            self.assertIn(slot, out["error"])
        self.assertNotIn("deliver", out["error"], "where it lands is never a question")

    def test_the_job_it_makes_is_the_persons_and_says_what_they_said(self):
        """The create path, with Hermes's job store stood in for so nothing is
        written. Three things found on the owner's Mac on 2026-09-11, the first
        end-to-end run: the job was named `moe-workday-start`, which every
        reader takes to mean one of Moe's OWN jobs — so it never travelled to
        the cloud machine; the model was made to ask where it should land;
        and the job's prompt said nothing about the inbox the person had
        asked for, because the template's words replaced theirs."""
        from unittest import mock
        import cron.jobs
        made = {}
        with mock.patch.object(cron.jobs, "create_job",
                               side_effect=lambda **kw: made.update(kw) or {"id": "j1"}), \
             mock.patch.object(cron.jobs, "list_jobs", return_value=[]), \
             mock.patch.object(cron.jobs, "ensure_dirs", return_value=None):
            out = json.loads(plugin._create({
                "key": "morning-brief", "values": {"time": "08:00"},
                "ask": "every weekday at 8am, tell me what's on my calendar and "
                       "anything in my inbox that's waiting on me"}))
        self.assertTrue(out["success"], out)
        self.assertEqual(made["name"], "morning-brief", "the key is the name — not moe-<key>")
        self.assertFalse(made["name"].startswith("moe-"))
        self.assertEqual(made["deliver"], plugin._DEFAULT_DELIVER, "unasked, it lands where their reminders do")
        self.assertIn("anything in my inbox that's waiting on me", made["prompt"])
        self.assertIn("their words are the content", made["prompt"])

    def test_a_partial_answer_still_names_what_is_left(self):
        out = json.loads(plugin._create(
            {"key": "custom-reminder", "values": {"what": "call mum"}}))
        self.assertFalse(out["success"])
        self.assertNotIn("what", out["error"].split(":", 1)[1])
        self.assertIn("time", out["error"])

    def test_values_as_a_json_string_is_understood(self):
        """Models pass an object-shaped argument as a string often enough that
        refusing it would read as the tool being broken."""
        out = json.loads(plugin._create(
            {"key": "custom-reminder", "values": '{"what": "call mum"}'}))
        self.assertFalse(out["success"])
        self.assertIn("time", out["error"])

    def test_unparseable_values_says_so(self):
        out = json.loads(plugin._create({"key": "custom-reminder", "values": "{not json"}))
        self.assertFalse(out["success"])
        self.assertIn("values must be an object", out["error"])


class RegistrationTest(unittest.TestCase):
    def test_both_tools_land_in_a_toolset_that_reaches_the_model(self):
        """`connectors`, not `blueprints`. Their own toolset registered in the
        gateway and never reached the model through the MCP bridge — measured:
        /v1/toolsets showed it enabled with both tools while tool_search found
        neither. The two toolsets that do arrive are the two pinned in Hermes's
        _DIRECT_SURFACE_TOOLSETS, and riding one costs no fork patch."""
        seen = []

        class Ctx:
            def register_tool(self, name, toolset, schema, handler, **kw):
                seen.append((name, toolset, schema, handler, kw))

        plugin.register(Ctx())
        self.assertEqual([s[0] for s in seen], ["blueprint_list", "blueprint_create"])
        self.assertEqual({s[1] for s in seen}, {"connectors"})
        for name, _toolset, schema, handler, kw in seen:
            self.assertEqual(schema["name"], name)
            self.assertIn("parameters", schema)
            self.assertTrue(callable(handler))
            self.assertTrue(callable(kw.get("check_fn")))

    def test_the_handlers_take_one_positional_dict(self):
        """Hermes hands a plugin tool its arguments as ONE POSITIONAL dict
        (hermes_cli/plugins.py). A handler defined as `def h(**kwargs)` fails
        on every call — which is exactly how every moe-connectors tool was
        broken once, silently, for as long as it took to notice."""
        for fn in (plugin._list, plugin._create):
            out = fn({})
            self.assertIsInstance(out, str)
            json.loads(out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
