"""lib/travel.py: the situations tick carries the engine's documents itself
(status #7, 2026-09-29) — what it sends, how often the read positions ride,
and that nothing it does can break a tick. The sealing and pushing are
tested where they live: claimstore/tests/test_job_travel.py (Mac) and
moe-ledger/tests/test_job_travel.py (machine).

Run: python3 moe-home/hermes-jobs/tests/test_travel.py
"""

import importlib.util
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.normpath(os.path.join(HERE, "..", "..", "lib", "travel.py"))
JOB = os.path.normpath(os.path.join(HERE, "..", "moe-situations.py"))


def load():
    spec = importlib.util.spec_from_file_location("travel_under_test", LIB)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TravelTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-travel-")
        os.environ["MOE_HOME"] = self.tmp
        self.t = load()
        self.calls = []

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def runner(self, names, receive, send):
        self.calls.append((list(names), receive, send))
        return {"written": [], "applied": []}

    def test_the_engines_names_and_no_other(self):
        from_ledger = ("proactive/situations", "proactive/promises", "feed/cursors", "proactive/open",
                       "proactive/said", "proactive/closed", "proactive/calendar-said",
                       "proactive/offer-state", "proactive/offer-feedback", "settings/background",
                       "proactive/holds", "proactive/mentions")
        self.assertEqual(set(self.t.ENGINE_NAMES), set(from_ledger))
        self.t.receive(self.runner)
        self.assertEqual(self.calls[-1], (list(self.t.ENGINE_NAMES), True, False))

    def test_read_positions_ride_at_most_every_fifteen_minutes(self):
        now = 1_790_000_000.0
        self.t.send(self.runner, now=now)
        self.assertIn("feed/cursors", self.calls[-1][0])
        self.t.send(self.runner, now=now + 300)
        self.assertNotIn("feed/cursors", self.calls[-1][0])
        self.assertIn("proactive/situations", self.calls[-1][0], "the rest go every tick")
        self.t.send(self.runner, now=now + 15 * 60)
        self.assertIn("feed/cursors", self.calls[-1][0])
        self.assertTrue(all(c[1] is False and c[2] is True for c in self.calls))

    def test_a_failed_send_leaves_the_positions_due(self):
        now = 1_790_000_000.0
        self.t.send(lambda *_a: {"error": "edge down"}, now=now)
        self.t.send(self.runner, now=now + 60)
        self.assertIn("feed/cursors", self.calls[-1][0], "not sent, so still due")

    def test_a_failure_is_said_never_raised(self):
        def boom(*_a):
            raise RuntimeError("no ledger here")
        self.assertIn("RuntimeError", self.t.receive(boom)["error"])
        self.assertIn("RuntimeError", self.t.send(boom)["error"])

    def test_the_job_receives_before_the_tick_and_sends_after(self):
        src = open(JOB, encoding="utf-8").read()
        r, tick, s = src.index("trip.receive()"), src.index("situations.tick("), src.index("trip.send()")
        self.assertLess(r, tick)
        self.assertLess(tick, s)


if __name__ == "__main__":
    unittest.main()
