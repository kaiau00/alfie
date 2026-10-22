"""docs/AWAY-HANDOFF.md slice 3, the machine's half: the marker the edge sends
becomes the person's own words (or an honest "it did not arrive"), and the
reply tells the edge the ask is done. Stdlib module, loaded by path."""
from __future__ import annotations

import importlib.util
import io
import json
import os
import types

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.normpath(os.path.join(HERE, ".."))


def load_tasks():
    spec = importlib.util.spec_from_file_location("moe_screen_tasks", os.path.join(PLUGIN, "tasks.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("MOE_HOME", str(tmp_path / "moe"))
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))
    (tmp_path / "moe" / "turns").mkdir(parents=True)
    (tmp_path / "hermes" / "moe").mkdir(parents=True)
    return tmp_path


def ask_file(home, **doc):
    body = {"task": "t-1", "thread": "TH", "words": "find me a cheap backpack",
            "text": "[brief]\nfind me a cheap backpack", "started": 1.0, "session": "s"}
    body.update(doc)
    (home / "moe" / "turns" / "inflight.json").write_text(json.dumps(body))


class Event:
    def __init__(self, text, message_id="task:t-1"):
        self.text = text
        self.message_id = message_id


def test_the_marker_is_recognised_and_nothing_else_is():
    t = load_tasks()
    assert t.marker_task("[moe-task abc-1] The person's Mac closed…") == "abc-1"
    assert t.marker_task("  [moe-task x]") == "x"
    # The gateway may put a nudge note and "[New message]" in front.
    assert t.marker_task("Earlier: a reminder…\n\n[New message]\n[moe-task y] …") == "y"
    assert t.marker_task("hello [moe-task x]") is None
    assert t.marker_task("[moe-task]") is None
    assert t.marker_task(None) is None
    assert t.marker_task("[moe-task " + "x" * 81 + "]") is None


def test_the_matching_ask_becomes_the_persons_words_behind_the_note(home):
    t = load_tasks()
    ask_file(home)
    out = t.on_inbound(Event("[moe-task t-1] The person's Mac closed while Alfie was working…"))
    assert out["action"] == "rewrite"
    text = out["text"]
    assert text.startswith("[moe-task t-1]"), "the marker stays, so the reply hook can find the turn"
    assert text.endswith("find me a cheap backpack")
    assert "[brief]" not in text, "the words, not the Mac's scaffolding"
    assert "tell them, in one line, that their mac closed" in text.lower()


def test_a_marker_the_file_does_not_know_is_an_honest_miss_never_a_guess(home):
    t = load_tasks()
    ask_file(home, task="t-other", words="book the dentist")
    out = t.on_inbound(Event("[moe-task t-1] …"))
    assert out["action"] == "rewrite"
    assert "did not reach this machine" in out["text"] and "dentist" not in out["text"]
    # No file at all: the same honest miss.
    os.unlink(home / "moe" / "turns" / "inflight.json")
    assert "did not reach" in t.on_inbound(Event("[moe-task t-1] …"))["text"]
    # An ordinary message is left alone, marker or not inside it.
    assert t.on_inbound(Event("hi, what did we say about backpacks?")) is None
    assert t.on_inbound(Event("quote: [moe-task t-1]")) is None
    assert t.on_inbound(None) is None


def test_only_a_message_the_edge_minted_is_honoured(home):
    """The hook runs before authorization and anybody who can type into a
    bound chat could send the marker; the edge sends it under a `task:` id
    and a chat app's ids are numbers, so that is the gate."""
    t = load_tasks()
    ask_file(home)
    assert t.on_inbound(Event("[moe-task t-1] …", message_id="4211")) is None
    assert t.on_inbound(Event("[moe-task t-1] …", message_id=None)) is None
    assert t.on_inbound(Event("[moe-task t-1] …", message_id="task:t-1"))["action"] == "rewrite"
