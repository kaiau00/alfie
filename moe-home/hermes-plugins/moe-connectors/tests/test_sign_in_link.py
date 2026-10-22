"""The cloud computer's sign-in link, machine side (signin.py).

What must hold: the person's tap lands where they tapped, their typing is
inserted as typed, every frame reaches the edge and is acknowledged (Chrome
stops sending after an unacknowledged one), Done ends it and puts the page
back to its own size, and the tool exists only on the machine. The two
sockets are stood in for; the CDP commands are what Chrome documents.
"""

import base64
import importlib.util
import json
import os
import sys
import threading
import unittest

_PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_PKG, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


signin = _load("moe_connectors_signin_test", "signin.py")


class Sock:
    """One end of a websocket: what the relay sent, and a script of what it reads."""

    def __init__(self, script=()):
        self.sent = []
        self.script = list(script)
        self.closed = False
        self.more = threading.Event()

    def send(self, data):
        self.sent.append(data)

    def recv(self, timeout=None):
        if self.script:
            return self.script.pop(0)
        if self.closed:
            raise EOFError
        self.more.wait(timeout or 0.01)
        raise TimeoutError

    def close(self):
        self.closed = True

    def cdp(self):
        return [json.loads(m) for m in self.sent if isinstance(m, str)]

    def methods(self):
        return [m["method"] for m in self.cdp()]


def relay_with(page, edge):
    socks = {"page": page, "edge": edge}
    connect = lambda url, **kw: socks["edge" if url.startswith("wss://") else "page"]  # noqa: E731
    return signin.Relay("wss://edge/v1/live/x/machine", "bearer", "ws://127.0.0.1:1/devtools/page/T",
                        connect=connect)


class TheRelay(unittest.TestCase):

    def run_script(self, edge_script, page_script=()):
        page, edge = Sock(page_script), Sock(edge_script)
        relay = relay_with(page, edge)
        relay.run()
        return relay, page, edge

    def test_the_phone_size_sets_a_mobile_page_and_starts_the_screen(self):
        _, page, _ = self.run_script([json.dumps({"t": "size", "w": 390, "h": 700, "dpr": 3}),
                                      json.dumps({"t": "done"})])
        sent = page.cdp()
        metrics = next(m for m in sent if m["method"] == "Emulation.setDeviceMetricsOverride")
        self.assertEqual(metrics["params"], {"width": 390, "height": 700, "deviceScaleFactor": 2.0,
                                             "mobile": True})
        cast = next(m for m in sent if m["method"] == "Page.startScreencast")
        self.assertEqual((cast["params"]["maxWidth"], cast["params"]["maxHeight"]), (780, 1400))

    def test_a_tap_is_a_click_where_they_tapped(self):
        _, page, _ = self.run_script([json.dumps({"t": "tap", "x": 120.5, "y": 300}),
                                      json.dumps({"t": "done"})])
        clicks = [m["params"] for m in page.cdp() if m["method"] == "Input.dispatchMouseEvent"]
        self.assertEqual([c["type"] for c in clicks], ["mouseMoved", "mousePressed", "mouseReleased"])
        self.assertTrue(all((c["x"], c["y"]) == (120.5, 300.0) for c in clicks))
        self.assertEqual(clicks[1]["button"], "left")

    def test_typing_is_inserted_as_typed_and_enter_submits(self):
        _, page, _ = self.run_script([json.dumps({"t": "text", "s": "hunter2 é"}),
                                      json.dumps({"t": "key", "k": "Enter"}),
                                      json.dumps({"t": "done"})])
        sent = page.cdp()
        self.assertIn({"text": "hunter2 é"},
                      [m["params"] for m in sent if m["method"] == "Input.insertText"])
        keys = [m["params"] for m in sent if m["method"] == "Input.dispatchKeyEvent"]
        self.assertEqual([k["type"] for k in keys], ["keyDown", "keyUp"])
        self.assertEqual((keys[0]["key"], keys[0]["windowsVirtualKeyCode"], keys[0]["text"]),
                         ("Enter", 13, "\r"))

    def test_a_key_that_is_not_declared_is_not_pressed(self):
        _, page, _ = self.run_script([json.dumps({"t": "key", "k": "F12"}),
                                      json.dumps({"t": "done"})])
        self.assertNotIn("Input.dispatchKeyEvent", page.methods())

    def test_done_puts_the_page_back_and_closes_both(self):
        relay, page, edge = self.run_script([json.dumps({"t": "done"})])
        self.assertEqual(relay.ended, "done")
        self.assertEqual(page.methods()[-2:], ["Page.stopScreencast",
                                               "Emulation.clearDeviceMetricsOverride"])
        self.assertTrue(page.closed and edge.closed)

    def test_the_address_is_shown_from_the_start(self):
        page, edge = Sock(), Sock([json.dumps({"t": "done"})])
        socks = {"page": page, "edge": edge}
        relay = signin.Relay("wss://edge/m", "b", "ws://127.0.0.1:1/devtools/page/T", url="https://x.com/login",
                             connect=lambda url, **kw: socks["edge" if url.startswith("wss://") else "page"])
        relay.run()
        self.assertEqual(json.loads(edge.sent[0]), {"t": "page", "url": "https://x.com/login"})

    def test_the_edge_going_away_ends_it_too(self):
        class Gone(Sock):
            def recv(self, timeout=None):
                raise ConnectionError("closed 4000")
        page = Sock()
        relay = relay_with(page, Gone())
        relay.run()
        self.assertEqual(relay.ended, "ended")
        self.assertIn("Emulation.clearDeviceMetricsOverride", page.methods())


class ThePageSide(unittest.TestCase):

    def test_every_frame_goes_to_the_edge_as_bytes_and_is_acknowledged(self):
        relay = relay_with(Sock(), Sock())
        relay.page, relay.edge = Sock(), Sock()
        jpeg = b"\xff\xd8\xff not really a jpeg"
        relay.on_page_event(json.dumps({"method": "Page.screencastFrame", "params": {
            "data": base64.b64encode(jpeg).decode(), "sessionId": 7, "metadata": {}}}))
        self.assertEqual(relay.edge.sent, [jpeg])
        self.assertEqual(relay.page.cdp()[-1], {"id": 1, "method": "Page.screencastFrameAck",
                                                "params": {"sessionId": 7}})

    def test_the_main_frame_address_is_shown_and_an_iframe_is_not(self):
        relay = relay_with(Sock(), Sock())
        relay.page, relay.edge = Sock(), Sock()
        relay.on_page_event(json.dumps({"method": "Page.frameNavigated", "params": {
            "frame": {"id": "a", "parentId": "main", "url": "https://ads.example"}}}))
        relay.on_page_event(json.dumps({"method": "Page.frameNavigated", "params": {
            "frame": {"id": "main", "url": "https://x.com/login"}}}))
        self.assertEqual([json.loads(m) for m in relay.edge.sent],
                         [{"t": "page", "url": "https://x.com/login"}])


class MakeLink(unittest.TestCase):

    def setUp(self):
        self.opened = []
        signin.open_page = lambda url: (self.opened.append(url) or (9222, "T1", url, None))
        signin._origin_mod = lambda: type("rp", (), {"_origin": staticmethod(lambda: type("bt", (), {})())})

    def test_no_edge_credential_says_so(self):
        out = signin.make_link("x.com", None, None)
        self.assertFalse(out["success"])
        self.assertIn("not signed in to Alfie", out["error"])

    def test_the_link_comes_back_and_the_relay_dials_the_machine_end(self):
        posted = []

        class R:
            status_code = 200

            def json(self):
                # Even an edge that sent the url back is not trusted to keep it out.
                return {"delivered": True, "channel": "telegram", "id": "L",
                        "url": "https://edge/live/tok", "machine_path": "/v1/live/L/machine",
                        "expires_in": 600}
        out = signin.make_link("x.com", "https://x.com/login", ("https://edge.example", "b"),
                               post=lambda path, body: posted.append((path, body)) or R(), start=False)
        self.assertTrue(out["success"])
        # The link never enters the result: the model cannot pass on what it never saw.
        self.assertNotIn("/live/tok", json.dumps(out))
        self.assertNotIn("link", out)
        self.assertEqual(out["sent_to"], "the person's own telegram chat")
        self.assertIn("do not write any link yourself", out["next"])
        self.assertEqual(out["works_for_minutes"], 10)
        self.assertEqual(posted, [("/v1/live", {"site": "x.com"})])
        self.assertEqual(self.opened, ["https://x.com/login"])
        self.assertEqual(signin.ws_url("https://edge.example", "/v1/live/L/machine"),
                         "wss://edge.example/v1/live/L/machine")

    def test_not_delivered_is_a_failure_with_no_relay(self):
        class R:
            status_code = 200

            def json(self):
                return {"delivered": False, "error": "the owner has no chat this account can reach"}
        out = signin.make_link("x.com", None, ("https://edge.example", "b"),
                               post=lambda path, body: R(), start=False)
        self.assertFalse(out["success"])
        self.assertIn("no chat", out["error"])

    def test_an_edge_refusal_is_said(self):
        class R:
            status_code = 403
        out = signin.make_link("x.com", None, ("https://edge.example", "b"),
                               post=lambda path, body: R(), start=False)
        self.assertFalse(out["success"])
        self.assertIn("403", out["error"])


class Registration(unittest.TestCase):

    class Ctx:
        def __init__(self):
            self.tools = {}

        def register_hook(self, *_a):
            pass

        def register_tool(self, **kw):
            self.tools[kw["name"]] = kw

    def _register(self, runs_in):
        old = os.environ.get("MOE_RUNS_IN")
        os.environ["MOE_RUNS_IN"] = runs_in
        try:
            plugin = _load("moe_connectors_signin_reg_%s" % runs_in, "__init__.py")
            ctx = self.Ctx()
            plugin.register(ctx)
            return ctx.tools
        finally:
            if old is None:
                os.environ.pop("MOE_RUNS_IN", None)
            else:
                os.environ["MOE_RUNS_IN"] = old

    def test_only_the_machine_offers_it(self):
        cloud = self._register("cloud")
        self.assertIn(signin.TOOL, cloud)
        spec = cloud[signin.TOOL]["schema"]
        self.assertEqual(spec["parameters"]["required"], ["site"])
        self.assertEqual(set(spec["parameters"]["properties"]), {"site", "url"})
        self.assertNotIn(signin.TOOL, self._register("mac"))


if __name__ == "__main__":
    unittest.main()
