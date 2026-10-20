"""lib/cheap_model.py: every background reader Moe runs on its own uses the
cheapest model the person's CURRENT provider serves (model-tiers.json), and a
provider the table does not know keeps the person's chosen model.

Why it exists (CLAUDE.md, "Moe is not Claude-specific"): Hermes's
``call_llm(task="classify")`` with nothing pinned is served on a non-Claude
brain by the auxiliary auto chain, whose first step is the main provider AND
the main model — so the loop sweep, the situations sensor, the Composio
planner and per-turn learning all ran on the conversation's model, billed per
call on an API key. The providers below are stubs; the table is the real one.

    python3 -m unittest moe-home/hermes-jobs/tests/test_cheap_model.py
"""

import importlib.util
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MOE_SRC = os.path.abspath(os.path.join(HERE, "..", ".."))
LIB = os.path.join(MOE_SRC, "lib")
TIERS = os.path.join(MOE_SRC, "hermes", "model-tiers.json")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Recorder:
    """Hermes's call_llm, recording what each call pinned."""

    def __init__(self, refuse_model=None):
        self.calls = []
        self.refuse_model = refuse_model

    def __call__(self, task=None, **kw):
        self.calls.append(dict(kw, task=task))
        if self.refuse_model and kw.get("model") == self.refuse_model:
            raise ValueError("model not supported on this account")
        return "[]"


class CheapModelTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        os.environ["MOE_HOME"] = self.home  # no installed table: the repo's is read
        os.environ.pop("MOE_MODEL_TIERS", None)
        sys.modules.pop("cheap_model", None)
        self.cm = load("cheap_model", os.path.join(LIB, "cheap_model.py"))
        with open(TIERS, encoding="utf-8") as f:
            self.table = json.load(f)["cheapest"]

    def test_each_provider_gets_its_own_cheapest_model(self):
        self.assertGreaterEqual(len(self.table), 5, "the real table, not an invented one")
        for provider, cheap in self.table.items():
            llm = Recorder()
            self.cm.call([{"role": "user", "content": "x"}], 100, 10, llm=llm,
                         provider=provider, model="the-model-they-chose")
            self.assertEqual(llm.calls[0]["provider"], provider)
            self.assertEqual(llm.calls[0]["model"], cheap, provider)
            self.assertEqual(llm.calls[0]["task"], "classify")

    def test_a_provider_the_table_does_not_know_keeps_the_chosen_model(self):
        for provider in ("custom", "lmstudio", "ollama", ""):
            llm = Recorder()
            self.cm.call([{"role": "user", "content": "x"}], 100, 10, llm=llm,
                         provider=provider, model="qwen-local-32b")
            self.assertNotIn("model", llm.calls[0], provider)
            self.assertNotIn("provider", llm.calls[0], provider)

    def test_the_current_brain_is_read_when_nobody_says(self):
        self.cm.current_brain = lambda: ("openai-codex", "the-big-one")
        llm = Recorder()
        self.cm.call([{"role": "user", "content": "x"}], llm=llm)
        self.assertEqual(llm.calls[0]["model"], self.table["openai-codex"])

    def test_a_cheap_model_the_provider_refuses_falls_back_once_to_the_chosen_one(self):
        llm = Recorder(refuse_model=self.table["openrouter"])
        self.cm.call([{"role": "user", "content": "x"}], llm=llm, provider="openrouter", model="big")
        self.assertEqual(len(llm.calls), 2)
        self.assertEqual(llm.calls[1]["provider"], "openrouter")
        self.assertNotIn("model", llm.calls[1])

    def test_the_installed_table_wins_over_the_repo_copy(self):
        os.makedirs(os.path.join(self.home, "hermes"))
        with open(os.path.join(self.home, "hermes", "model-tiers.json"), "w") as f:
            json.dump({"cheapest": {"openai-api": "installed-small"}}, f)
        self.assertEqual(self.cm.route("openai-api", "big"), {"provider": "openai-api",
                                                              "model": "installed-small"})


class EveryBackgroundReaderUsesIt(unittest.TestCase):
    """The four readers the owner named (2026-09-24), each through its own
    default_call, on a brain that is not Claude."""

    def setUp(self):
        os.environ["MOE_HOME"] = tempfile.mkdtemp()
        sys.modules.pop("cheap_model", None)
        self.cm = load("cheap_model", os.path.join(LIB, "cheap_model.py"))
        sys.modules["cheap_model"] = self.cm
        self.cm.current_brain = lambda: ("openai-codex", "the-big-one")
        self.llm = Recorder()
        real = self.cm.call

        def call(messages, max_tokens=500, timeout=60, **kw):
            return real(messages, max_tokens, timeout, llm=self.llm, **kw)
        self.cm.call = call
        with open(TIERS, encoding="utf-8") as f:
            self.cheap = json.load(f)["cheapest"]["openai-codex"]

    def tearDown(self):
        sys.modules.pop("cheap_model", None)

    def check(self, default_call):
        default_call([{"role": "user", "content": "x"}])
        self.assertEqual(self.llm.calls[-1]["model"], self.cheap)

    def test_situations(self):
        self.check(load("situations_cheap", os.path.join(LIB, "situations.py")).default_call)

    def test_composio_items(self):
        self.check(load("composio_items_cheap", os.path.join(LIB, "composio_items.py")).default_call)

    def test_loop_sweep_and_turn_learning(self):
        plugins = os.path.join(MOE_SRC, "hermes-plugins")
        pkg = type(sys)("moe_screen_cheap")
        pkg.__path__ = [os.path.join(plugins, "moe-screen")]
        sys.modules["moe_screen_cheap"] = pkg
        sweep = load("moe_screen_cheap.sweep", os.path.join(plugins, "moe-screen", "sweep.py"))
        self.check(sweep.default_call)
        learn = load("learn_turn_cheap", os.path.join(plugins, "claimstore", "learn_turn.py"))
        self.check(learn.default_call)


if __name__ == "__main__":
    unittest.main()
