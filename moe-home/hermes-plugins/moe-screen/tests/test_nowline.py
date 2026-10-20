"""Ticket #9, the chat half: every message arriving on a chat channel — on
this Mac's gateway or on the away machine — reaches the model with the Now
line first, in the person's zone. Stdlib module, loaded by path."""
from __future__ import annotations

import importlib.util
import json
import os
from datetime import datetime, timezone

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.normpath(os.path.join(HERE, ".."))
REPO = os.path.normpath(os.path.join(PLUGIN, "..", "..", ".."))

#: 18:08 EDT on 2026-09-23, the ticket's moment.
TICKET = datetime(2026, 9, 23, 22, 8, tzinfo=timezone.utc)


def load():
    spec = importlib.util.spec_from_file_location("moe_screen_nowline", os.path.join(PLUGIN, "nowline.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("MOE_HOME", str(tmp_path / "moe"))
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))
    monkeypatch.delenv("HERMES_TIMEZONE", raising=False)
    (tmp_path / "moe").mkdir()
    (tmp_path / "hermes").mkdir()
    return tmp_path


class Event:
    def __init__(self, text, channel_context=None):
        self.text = text
        self.channel_context = channel_context


def test_the_line_is_the_swift_line(home):
    n = load()
    (home / "moe" / "tz.json").write_text(json.dumps({"iana": "America/New_York", "at": 1}))
    assert n.now_line(TICKET) == "Now: Wednesday 23 September 2026, 6:08 PM (evening), New York time (EDT, UTC-4)."


def test_the_full_line_matches_the_shared_fixture():
    """The same file NowLineTests.swift reads: one line, island and chat."""
    n = load()
    from zoneinfo import ZoneInfo
    with open(os.path.join(REPO, "Tests", "fixtures", "now-lines.tsv"), encoding="utf-8") as f:
        rows = [ln.rstrip("\n").split("\t", 1) for ln in f if ln.strip()]
    assert len(rows) == 6
    for zone, want in rows:
        assert n.line(TICKET.astimezone(ZoneInfo(zone)), zone) == want, zone


def test_the_away_machine_uses_the_persons_zone_not_its_own_utc(home):
    n = load()
    # No tz.json yet, but the tz document has landed in config.yaml.
    (home / "hermes" / "config.yaml").write_text("model:\n  default: x\ntimezone: 'Asia/Jerusalem'\n")
    assert n.now_line(TICKET) == "Now: Thursday 24 September 2026, 1:08 AM (night), Jerusalem time (UTC+3)."


def test_tz_json_wins_over_config(home):
    n = load()
    (home / "hermes" / "config.yaml").write_text("timezone: Asia/Jerusalem\n")
    (home / "moe" / "tz.json").write_text(json.dumps({"iana": "America/New_York"}))
    assert "New York time" in n.now_line(TICKET)


def test_the_line_goes_first_ahead_of_other_context(home):
    n = load()
    (home / "moe" / "tz.json").write_text(json.dumps({"iana": "America/New_York"}))
    e = Event("what's up", channel_context="Earlier, you told them: call Dani")
    assert n.attach(event=e) is None
    assert e.channel_context.startswith("Now: ")
    first, rest = e.channel_context.split("\n", 1)
    assert first.startswith("Now: ") and first.endswith(").")
    assert rest.startswith(n.RULE)
    assert e.channel_context.endswith("Earlier, you told them: call Dani")
    assert e.text == "what's up"            # the person's words are untouched


def test_a_bare_message_gets_it_too(home):
    n = load()
    e = Event("hello")
    n.attach(event=e)
    assert e.channel_context.startswith("Now: ")


def test_slash_commands_are_left_alone(home):
    n = load()
    e = Event("/new")
    n.attach(event=e)
    assert e.channel_context is None


def test_nothing_breaks_dispatch(home):
    n = load()
    (home / "moe" / "tz.json").write_text(json.dumps({"iana": "Not/AZone"}))
    e = Event("hi")
    assert n.attach(event=e) is None       # an unknown zone falls back to the OS's
    assert e.channel_context.startswith("Now: ")
    assert n.attach(event=None) is None


def test_parts_of_the_day():
    n = load()
    assert [n.part_of_day(h) for h in (0, 4, 5, 7, 8, 11, 12, 16, 17, 20, 21, 23)] == [
        "night", "night", "early morning", "early morning", "morning", "morning",
        "afternoon", "afternoon", "evening", "evening", "night", "night"]


def test_the_rule_is_the_macs_rule():
    """Held equal from the Swift side too (ConductorNowLineTests)."""
    n = load()
    with open(os.path.join(REPO, "Sources", "Moe", "Brain", "BrainPrompt.swift"), encoding="utf-8") as f:
        swift = f.read()
    assert 'static let nowRule = "%s"' % n.RULE in swift
