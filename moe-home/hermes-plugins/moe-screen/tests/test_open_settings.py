"""docs/FIXABLE-FAILURES.md slice 4: `moe_open_settings` opens only an
allowlisted pane, and only in the person's own live turn at the Mac.

Every refusal asserts the side effect — the app was NOT signalled — not just
the verdict. Called the way Hermes calls a plugin tool: one dict, first.

The presence cases also run against the fork's real `turn_presence` (contextvars set the way the
api_server sets them for X-Hermes-Turn-Origin), not only against a stand-in.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import types

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.normpath(os.path.join(HERE, ".."))


def load():
    spec = importlib.util.spec_from_file_location("moe_screen_open_settings",
                                                  os.path.join(PLUGIN, "open_settings.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def tool(monkeypatch):
    mod = load()
    posted = []
    monkeypatch.setattr(mod, "post", lambda pane: posted.append(pane) or True)
    mod.posted = posted
    return mod


def verdict(monkeypatch, v):
    """A stand-in for the fork's tools.browser_chrome_extension."""
    fake = types.ModuleType("tools.browser_chrome_extension")
    fake.turn_presence = lambda: v
    pkg = sys.modules.get("tools") or types.ModuleType("tools")
    monkeypatch.setitem(sys.modules, "tools", pkg)
    monkeypatch.setitem(sys.modules, "tools.browser_chrome_extension", fake)


def call(mod, **args):
    return json.loads(mod.handle_tool(args))


PERSON = {"live": True, "why": "the person's own turn"}


def test_opens_an_allowlisted_pane_on_the_persons_turn(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    out = call(tool, pane="Privacy_AllFiles")
    assert out == {"success": True, "result": "opened Privacy_AllFiles, watching for the switch"}
    assert tool.posted == ["Privacy_AllFiles"]


@pytest.mark.parametrize("pane", [
    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
    "https://example.com",
    "file:///Applications/Calculator.app",
    "Privacy_AllFiles?x=1",
    "privacy_allfiles",
    "Privacy_SpeechRecognition",   # a real pane, but no fix names it
    "",
    None,
    ["Privacy_AllFiles"],
])
def test_refuses_anything_but_an_allowlisted_pane_id(tool, monkeypatch, pane):
    verdict(monkeypatch, PERSON)
    out = call(tool, pane=pane)
    assert out["success"] is False and "never a URL" in out["error"]
    assert tool.posted == []


@pytest.mark.parametrize("v", [
    {"live": False, "why": "a scheduled job"},
    {"live": False, "why": "a background note from the app"},
    {"live": False, "why": "a background helper started earlier"},
    {"live": False, "why": "an API turn whose client did not say a person started it"},
    # Live, but on a phone: the person is not at the Mac.
    {"live": True, "why": "the person's message"},
    # A helper inside the person's turn is not the person.
    {"live": True, "auto": False, "why": "a helper working on the person's turn"},
    "garbage",
])
def test_refuses_when_nobody_is_at_the_mac(tool, monkeypatch, v):
    verdict(monkeypatch, v)
    out = call(tool, pane="Privacy_AllFiles")
    assert out["success"] is False and "Not opened" in out["error"]
    assert tool.posted == []


def test_no_presence_answer_fails_closed(tool, monkeypatch):
    broken = types.ModuleType("tools.browser_chrome_extension")   # no turn_presence at all
    monkeypatch.setitem(sys.modules, "tools", sys.modules.get("tools") or types.ModuleType("tools"))
    monkeypatch.setitem(sys.modules, "tools.browser_chrome_extension", broken)
    out = call(tool, pane="Privacy_AllFiles")
    assert out["success"] is False and tool.posted == []


def test_the_schema_offers_only_the_allowlist(tool):
    assert tool.TOOL_SCHEMA["parameters"]["properties"]["pane"]["enum"] == list(tool.PANES)
    assert all(p.startswith("Privacy_") and p.isidentifier() for p in tool.PANES)


REPO = os.path.normpath(os.path.join(PLUGIN, "..", "..", ".."))


def _has_turn_origin(tree):
    try:
        with open(os.path.join(tree, "gateway", "session_context.py")) as f:
            return "def set_turn_origin" in f.read()
    except OSError:
        return False


def _pin():
    import re
    with open(os.path.join(REPO, "scripts", "install-hermes.sh")) as f:
        m = re.search(r'^HERMES_COMMIT="\$\{HERMES_COMMIT-([0-9a-f]{40})\}"', f.read(), re.M)
    return m.group(1) if m else None


@pytest.fixture(scope="session")
def fork(tmp_path_factory):
    """The fork to judge presence with: MOE_HERMES_FORK when set; else the
    commit install-hermes.sh pins, exported (read-only, `git archive`) from
    whichever checkout has it — ~/hermes-agent-fork, then the installed
    Hermes — the way ToolFixVocabularyTests finds it."""
    env = os.environ.get("MOE_HERMES_FORK")
    if env:
        assert _has_turn_origin(env), "MOE_HERMES_FORK=%s has no set_turn_origin" % env
        return env
    import subprocess
    pin = _pin()
    for repo in (os.path.expanduser("~/hermes-agent-fork"), os.path.expanduser("~/.hermes/hermes-agent")):
        if not pin or subprocess.run(["git", "-C", repo, "cat-file", "-e", pin + "^{commit}"],
                                     capture_output=True).returncode:
            continue
        out = tmp_path_factory.mktemp("fork")
        arch = subprocess.run(["git", "-C", repo, "archive", pin], capture_output=True, check=True)
        subprocess.run(["tar", "-x", "-C", str(out)], input=arch.stdout, check=True)
        if _has_turn_origin(str(out)):
            return str(out)
    pytest.skip("the pinned Hermes %s is in no checkout here: git -C ~/hermes-agent-fork fetch fork" % pin)


@pytest.mark.parametrize("origin,cron,opened", [
    ("person", "", True),
    ("background", "", False),
    ("", "", False),
    ("person", "1", False),     # a cron job's turn, whatever the header said
])
def test_against_the_forks_own_presence(tool, monkeypatch, fork, origin, cron, opened):
    monkeypatch.syspath_prepend(fork)
    # Whatever Hermes PYTHONPATH already imported is not the pinned one.
    for name in [m for m in sys.modules if m.split(".")[0] in ("tools", "gateway", "agent", "hermes_cli")]:
        monkeypatch.delitem(sys.modules, name)
    monkeypatch.delenv("HERMES_MCP_TOOL_PROFILE", raising=False)
    monkeypatch.delenv("HERMES_KANBAN_TASK", raising=False)
    from gateway import session_context as sc
    # Session vars fall back to the environment when no contextvar is bound.
    monkeypatch.setenv("HERMES_SESSION_PLATFORM", "api_server")
    if cron:
        monkeypatch.setenv("HERMES_CRON_SESSION", cron)
    else:
        monkeypatch.delenv("HERMES_CRON_SESSION", raising=False)
    token = sc.set_turn_origin(origin)
    try:
        out = call(tool, pane="Privacy_AllFiles")
    finally:
        sc.reset_turn_origin(token)
    assert out["success"] is opened, out
    assert tool.posted == (["Privacy_AllFiles"] if opened else [])
