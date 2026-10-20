"""Shared bits for the learn tests: import-by-path and a scratch MOE_HOME.

The modules under learn/ have plain names (profile.py collides with the
stdlib profiler), so tests load them by path. Every test pins MOE_TODAY so
dates in fixtures never drift, and points MOE_PROFILE_DIR at a temp dir so
nothing under ~/.moe is ever read or written.
"""

import importlib.util
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LEARN = os.path.normpath(os.path.join(HERE, ".."))
MOE_HOME = os.path.normpath(os.path.join(LEARN, ".."))   # the moe-home template
TODAY = "2026-08-30"


def load(name):
    spec = importlib.util.spec_from_file_location("moe_learn_" + name, os.path.join(LEARN, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ScratchCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-learn-test-")
        self.profile = os.path.join(self.tmp, "profile")
        self._env = {k: os.environ.get(k) for k in ("MOE_HOME", "MOE_PROFILE_DIR", "MOE_TODAY", "HERMES_HOME")}
        os.environ["MOE_HOME"] = os.path.join(self.tmp, "moe")       # exists only as a name
        os.environ["MOE_PROFILE_DIR"] = self.profile
        os.environ["MOE_TODAY"] = TODAY
        os.environ["HERMES_HOME"] = os.path.join(self.tmp, "hermes")

    def tearDown(self):
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp, ignore_errors=True)

    def read(self, name):
        try:
            with open(os.path.join(self.profile, name), encoding="utf-8") as f:
                return f.read()
        except OSError:
            return ""
