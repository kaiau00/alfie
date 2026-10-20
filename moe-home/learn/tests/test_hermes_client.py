#!/usr/bin/env python3
"""hermes_client.chat: the X-Hermes-Enabled-Toolsets header (toolset narrowing).
No network — build_opener is stubbed to capture the outgoing request. Run:
python3 -m unittest discover -s moe-home/learn/tests"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from helpers import ScratchCase, load  # noqa: E402

hc = load("hermes_client")


class _FakeResp:
    headers = {"Content-Type": "application/json"}

    def read(self):
        return b'{"choices":[{"message":{"content":"ok"}}]}'

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class HeaderTest(ScratchCase):
    def setUp(self):
        super().setUp()
        hc.reset_capability()   # each test starts with a fresh capability probe

    def _call(self, applied="ECHO", **kw):
        """Run chat() with build_opener stubbed. `applied` controls the gateway's
        echoed X-Hermes-Applied-Toolsets on EVERY request (the preflight probe
        AND the real turn): "ECHO" = a correct gateway (echoes what it applied =
        the requested toolsets minus the 'none' sentinel it strips); None = an
        old gateway that omits the header; any literal simulates a specific
        (mis)behaving gateway. Returns the last request's headers (lowercased)."""
        captured = {}

        def fake_build_opener(*a):
            class _O:
                def open(self_, req, timeout=None):
                    h = {k.lower(): v for k, v in req.header_items()}
                    captured["h"] = h
                    reqd = h.get("x-hermes-enabled-toolsets")
                    if applied == "ECHO":
                        if reqd is None:
                            val = None
                        else:
                            rset = {t.strip() for t in reqd.split(",") if t.strip()}
                            val = ",".join(sorted(rset - {hc.NO_TOOLS}))
                    else:
                        val = applied
                    resp = _FakeResp()
                    hdrs = {"Content-Type": "application/json"}
                    if val is not None:
                        hdrs["X-Hermes-Applied-Toolsets"] = val
                    resp.headers = hdrs
                    return resp
            return _O()

        orig = hc.urllib.request.build_opener
        hc.urllib.request.build_opener = fake_build_opener
        try:
            hc.chat("system", "user", "moe-learn", **kw)
        finally:
            hc.urllib.request.build_opener = orig
        return captured["h"]

    def test_memory_only_header_sent(self):
        h = self._call(enabled_toolsets=["memory"])
        self.assertEqual(h.get("x-hermes-enabled-toolsets"), "memory")

    def test_multiple_toolsets_comma_joined(self):
        h = self._call(enabled_toolsets=["connectors", "memory"])
        self.assertEqual(h.get("x-hermes-enabled-toolsets"), "connectors,memory")

    def test_no_header_when_not_restricting(self):
        h = self._call()
        self.assertNotIn("x-hermes-enabled-toolsets", h)

    def test_header_sent_even_without_api_key(self):
        self.assertEqual(hc.resolve_endpoint()[1], "")   # confirm no key
        h = self._call(enabled_toolsets=["memory"])
        self.assertEqual(h.get("x-hermes-enabled-toolsets"), "memory")
        self.assertNotIn("authorization", h)             # and no auth header

    # --- the no-tools sentinel (distil/merge run with zero tools) ---
    def test_no_tools_verified_when_gateway_strips(self):
        h = self._call(enabled_toolsets=[hc.NO_TOOLS])   # correct gateway → empty applied
        self.assertEqual(h.get("x-hermes-enabled-toolsets"), "none")

    def test_no_tools_fail_closed_if_a_tool_survives(self):
        with self.assertRaises(hc.HermesError):
            self._call(applied="memory", enabled_toolsets=[hc.NO_TOOLS])

    # --- fail closed (these trip at the PREFLIGHT, before any data is sent) ---
    def test_passes_when_gateway_confirms_the_narrowing(self):
        self._call(applied="memory", enabled_toolsets=["memory"])

    def test_fail_closed_when_gateway_omits_the_echo(self):
        with self.assertRaises(hc.HermesError):
            self._call(applied=None, enabled_toolsets=["memory"])

    def test_fail_closed_when_gateway_did_not_narrow(self):
        with self.assertRaises(hc.HermesError):
            self._call(applied="memory,terminal", enabled_toolsets=["memory"])

    def test_fail_closed_on_empty_applied(self):
        with self.assertRaises(hc.HermesError):
            self._call(applied="", enabled_toolsets=["memory"])

    def test_no_verification_when_not_restricting(self):
        self._call(applied=None)

    def test_empty_or_blank_restriction_rejected(self):
        # a present-but-blank restriction must not silently skip the preflight
        for bad in ([], [""], ["  "]):
            with self.assertRaises(hc.HermesError):
                self._call(enabled_toolsets=bad)

    def test_preflight_runs_before_untrusted_data_is_sent(self):
        # an incapable gateway (no echo) must make the seam raise at the benign
        # PREFLIGHT — the restricted real turn is never sent.
        seen = []

        def fake_build_opener(*a):
            class _O:
                def open(self_, req, timeout=None):
                    seen.append({k.lower(): v for k, v in req.header_items()})
                    r = _FakeResp()
                    r.headers = {"Content-Type": "application/json"}   # no echo
                    return r
            return _O()

        orig = hc.urllib.request.build_opener
        hc.urllib.request.build_opener = fake_build_opener
        try:
            with self.assertRaises(hc.HermesError):
                hc.chat("s", "the untrusted crawl text", "moe-learn", enabled_toolsets=["memory"])
        finally:
            hc.urllib.request.build_opener = orig
        self.assertEqual(len(seen), 1)   # only the probe; the real turn never ran

    def test_capability_cached_across_calls(self):
        calls = {"n": 0}

        def fake_build_opener(*a):
            class _O:
                def open(self_, req, timeout=None):
                    calls["n"] += 1
                    h = {k.lower(): v for k, v in req.header_items()}
                    reqd = h.get("x-hermes-enabled-toolsets") or ""
                    r = _FakeResp()
                    r.headers = {"Content-Type": "application/json",
                                 "X-Hermes-Applied-Toolsets":
                                 ",".join(sorted({t for t in reqd.split(",") if t} - {hc.NO_TOOLS}))}
                    return r
            return _O()

        orig = hc.urllib.request.build_opener
        hc.urllib.request.build_opener = fake_build_opener
        try:
            hc.chat("s", "u", "k", enabled_toolsets=["memory"])
            hc.chat("s", "u", "k", enabled_toolsets=["memory"])
        finally:
            hc.urllib.request.build_opener = orig
        self.assertEqual(calls["n"], 3)   # 1 probe + 2 real turns (probe not repeated)


if __name__ == "__main__":
    unittest.main()
