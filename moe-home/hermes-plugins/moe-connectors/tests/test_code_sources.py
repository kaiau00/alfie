"""The person's Gmail as the engine's source of sign-in codes (Moe ticket #13).

The engine (Hermes agent/vault_code_sources.py) decides which message and which code; this plugin
only answers "what mail arrived recently, from every Gmail account this person connected". These
tests hand it the Composio result shape measured on the owner's inbox on 2026-09-24 -- the
multiplexer's envelope, with messageText / subject / sender / messageTimestamp -- and check what the
engine receives, and that each account is read as itself.
"""

import importlib.util
import json
import os
import sys
import types
import unittest
from dataclasses import dataclass
from unittest import mock

_PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location("moe_connectors_code_sources", os.path.join(_PKG, "__init__.py"))
plugin = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(plugin)


@dataclass
class MailMessage:  # the engine's type, as the plugin constructs it
    sender: str
    subject: str
    text: str
    at: float
    mailbox: str = ""


def _envelope(messages):
    """What registry.dispatch returns for a muxed GMAIL_FETCH_EMAILS, as measured."""
    inner = {"data": {"results": [{"response": {"successful": True, "data": {"messages": messages}},
                                   "tool_slug": "GMAIL_FETCH_EMAILS", "index": 0}]}, "successful": True}
    return json.dumps({"result": json.dumps(inner)})


class FakeRegistry:
    def __init__(self, by_account):
        self.by_account, self.calls = by_account, []

    def get_all_tool_names(self):
        return ["mcp__composio__COMPOSIO_SEARCH_TOOLS", "mcp__composio__GMAIL_FETCH_EMAILS", "gmail_status"]

    def dispatch(self, name, args):
        self.calls.append((name, dict(args)))
        return _envelope(self.by_account.get(args.get("account"), []))


class CodeSourceTests(unittest.TestCase):
    def setUp(self):
        self.registered = {}
        engine = types.ModuleType("agent.vault_code_sources")
        engine.MailMessage = MailMessage
        engine.register_code_source = lambda name, fn: self.registered.__setitem__(name, fn)
        self.registry = FakeRegistry({
            "owner@example.com": [{"sender": "TinyLaunch <hello@tinylaunch.com>", "subject": "Your login code",
                                   "messageText": "Your code is 482913", "messageTimestamp": "2026-09-24T19:46:40Z"}],
            "work@example.com": [{"sender": "a@b.com", "subject": "hi", "preview": "tinylaunch mention",
                                  "messageTimestamp": "2026-09-24T19:00:00Z"}],
        })
        registry_mod = types.ModuleType("tools.registry")
        registry_mod.registry = self.registry
        self.patches = [mock.patch.dict(sys.modules, {"agent.vault_code_sources": engine,
                                                      "tools.registry": registry_mod}),
                        mock.patch.object(plugin, "composio_connected",
                                          return_value={"gmail": ["owner@example.com", "work@example.com"]})]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()

    def test_registered_with_the_engine(self):
        self.assertTrue(plugin.register_code_sources())
        self.assertIs(self.registered["moe-gmail"], plugin.gmail_code_messages)

    def test_every_connected_account_is_read_as_itself(self):
        got = plugin.gmail_code_messages("tinylaunch", 0)
        self.assertEqual([c[1].get("account") for c in self.registry.calls],
                         ["owner@example.com", "work@example.com"])
        self.assertTrue(all(c[0] == "mcp__composio__GMAIL_FETCH_EMAILS" for c in self.registry.calls))
        first = self.registry.calls[0][1]
        self.assertEqual(first["query"], "newer_than:1h tinylaunch")
        self.assertEqual((first["verbose"], first["include_payload"]), (True, False))
        self.assertEqual(len(got), 2)
        code_mail = got[0]
        self.assertEqual((code_mail.sender, code_mail.subject, code_mail.text, code_mail.mailbox),
                         ("TinyLaunch <hello@tinylaunch.com>", "Your login code", "Your code is 482913",
                          "owner@example.com"))
        self.assertAlmostEqual(code_mail.at, 1790279200.0)
        self.assertEqual(got[1].text, "tinylaunch mention", "preview stands in when there is no body")

    def test_no_composio_gmail_tool_reads_nothing(self):
        self.registry.get_all_tool_names = lambda: ["gmail_status"]
        self.assertEqual(plugin.gmail_code_messages("tinylaunch", 0), [])
        self.assertEqual(self.registry.calls, [])

    def test_an_older_hermes_without_code_sources_is_left_alone(self):
        with mock.patch.dict(sys.modules, {"agent.vault_code_sources": None}):
            self.assertFalse(plugin.register_code_sources())


if __name__ == "__main__":
    unittest.main()
