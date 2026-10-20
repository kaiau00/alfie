"""moe-memory-tidy.py: when the nightly tidy runs, and that it prints nothing.

Falsifiers: run whenever the gap passes without the idle check, never run a
Mac that is always busy, or let the away machine tidy — each turns red.
"""
import importlib.util
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
JOB = os.path.normpath(os.path.join(HERE, "..", "moe-memory-tidy.py"))


def load():
    spec = importlib.util.spec_from_file_location("moe_memory_tidy_job", JOB)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class DueTest(unittest.TestCase):
    def setUp(self):
        self.j = load()
        self.now = 1_000_000.0

    def test_idle_after_twenty_hours(self):
        self.assertTrue(self.j.due(self.now, self.now - 21 * 3600, 20 * 60))

    def test_not_while_the_person_is_at_the_mac(self):
        self.assertFalse(self.j.due(self.now, self.now - 21 * 3600, 30))
        self.assertFalse(self.j.due(self.now, self.now - 21 * 3600, None))

    def test_not_twice_a_day(self):
        self.assertFalse(self.j.due(self.now, self.now - 3600, 10 * 3600))

    def test_a_busy_mac_is_still_tidied(self):
        self.assertTrue(self.j.due(self.now, self.now - 37 * 3600, 0))


class SilentTest(unittest.TestCase):
    def test_the_away_machine_never_tidies_and_nothing_is_printed(self):
        j = load()
        with tempfile.TemporaryDirectory() as home, \
                mock.patch.dict(os.environ, {"MOE_HOME": home, "MOE_RUNS_IN": "cloud",
                                             "MOE_TIDY_NOW": "1"}):
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(j.main(), 0)
            self.assertEqual(out.getvalue(), "")
            self.assertFalse(os.path.exists(os.path.join(home, "memory", "tidy", "last-run")))

    def test_background_thinking_off_means_no_tidy(self):
        j = load()
        with tempfile.TemporaryDirectory() as home, \
                mock.patch.dict(os.environ, {"MOE_HOME": home, "MOE_RUNS_IN": "mac",
                                             "MOE_TIDY_NOW": "1"}):
            with open(os.path.join(home, "config.json"), "w") as f:
                f.write('{"backgroundThinking": false}')
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(j.main(), 0)
            self.assertEqual(out.getvalue(), "")
            self.assertFalse(os.path.exists(os.path.join(home, "memory", "tidy", "last-run")))


class RunPathTest(unittest.TestCase):
    """The path that actually tidies, with claimstore and cheap_model stubbed:
    the two tests above return before it and could not catch a print."""

    def test_a_real_run_prints_nothing_and_logs_one_line(self):
        import types
        j = load()
        calls = []
        tidy = types.SimpleNamespace(run=lambda store, targets, call: (
            calls.append(call([{"role": "user", "content": "x"}])),
            print("noise from inside the tidy"),
            {"outcome": "1 change(s)", "changes": [{}], "refused": []})[2])
        claimstore = types.ModuleType("claimstore")
        claimstore.resolve_targets = lambda: ["memory", "user"]
        claimstore.tidy = tidy
        cli = types.ModuleType("claimstore.cli")
        cli.open_store = lambda: object()
        cheap = types.ModuleType("cheap_model")
        cheap.call = lambda m, max_tokens, timeout: '{"changes": []}'
        mods = {"claimstore": claimstore, "claimstore.tidy": tidy, "claimstore.cli": cli,
                "cheap_model": cheap}
        with tempfile.TemporaryDirectory() as home, \
                mock.patch.dict(os.environ, {"MOE_HOME": home, "MOE_RUNS_IN": "mac",
                                             "MOE_TIDY_NOW": "1",
                                             "HERMES_HOME": os.path.join(home, "hermes")}), \
                mock.patch.dict(sys.modules, mods), \
                mock.patch.object(sys, "path", list(sys.path)):
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(j.main(), 0)
            self.assertEqual(calls, ['{"changes": []}'])
            with open(os.path.join(home, "logs", "memory-tidy.jsonl")) as f:
                self.assertIn('"1 change(s)"', f.read())
        # Whatever the tidy prints must not reach stdout, which is a message.
        self.assertEqual(out.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
