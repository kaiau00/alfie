"""Sign in on the cloud computer, from the person's phone.

docs/AWAY-SIGN-IN.md step 2. The machine's browser keeps its own profile
(fork ``browser.kept_profile``), so a sign-in made in it stays. What was
missing is a way for the person to make one: nobody can see a cloud
computer's screen. This is that way.

`make_link` opens the page in the kept browser and asks the edge for a
one-time link (`POST /v1/live`, device bearer; the edge refuses anything but a
``cloud`` device). **The edge sends the link to the owner's own chat itself
and never returns it**: the link opens the owner's signed-in browser, and a
tool result the model reads is one it can repeat to whoever it is talking to
(a knock-admitted chat, a group). So nothing here ever holds the link; the
result says only which chat it went to. Then a :class:`Relay` thread dials the
edge's machine end and stays until the person taps Done, the link ends, or
:data:`LIVE_S` passes.

The relay is a screencast, not a remote desktop: Chrome's own
``Page.startScreencast`` sends JPEGs of the one page, sized to the phone
(``Emulation.setDeviceMetricsOverride``, mobile layout), and the person's
taps and typing come back as ``Input.*`` events on that page. It works on the
headless browser the image ships, with no display server. Nothing the person
types is logged, kept, or seen by the model: it goes from the edge socket
straight into ``Input.insertText``.
"""

from __future__ import annotations

import base64
import json
import logging
import threading
import time
import urllib.parse

logger = logging.getLogger(__name__)

TOOL = "browser_sign_in_link"
#: The relay's own ceiling; the edge ends the session at 20 minutes anyway.
LIVE_S = 20 * 60
#: Keys the viewer may press, with what Chrome needs to act on them.
KEYS = {
    "Enter": (13, "Enter", "\r"), "Backspace": (8, "Backspace", ""), "Tab": (9, "Tab", ""),
    "Escape": (27, "Escape", ""), "Delete": (46, "Delete", ""),
    "ArrowLeft": (37, "ArrowLeft", ""), "ArrowRight": (39, "ArrowRight", ""),
    "ArrowUp": (38, "ArrowUp", ""), "ArrowDown": (40, "ArrowDown", ""),
}

DESCRIPTION = (
    "Make a link the person opens on their phone to sign in to a website themselves, in the "
    "browser on their cloud computer. Use it when a site needs them: a password you do not "
    "have, a 2FA code, 'is this you?', a CAPTCHA you could not pass. Pass `site` (its name, "
    "e.g. \"x.com\") and `url` (the sign-in page, or omit it to show the page the browser is "
    "on). Memoe sends the one-time link to the person's own chat itself -- you never see it, "
    "and you must never write, invent or pass on a link for this. It works for 10 minutes, on "
    "the first phone that opens it. They sign in, tap Done and tell you; the "
    "sign-in stays in this browser for every later job, so ask again only if a site signs "
    "them out. Their password goes to the site, never to you.")

SCHEMA_ARGS = [
    ("site", "string", "The site's name as the person knows it, e.g. \"x.com\"."),
    ("url", "string", "The page to open for them, usually the site's sign-in page. Optional."),
]


def _origin_mod():
    from tools import browser_tool_real_profile as rp  # the fork, on the machine
    return rp


def _page_ws(port: int, target_id: str) -> str:
    return f"ws://127.0.0.1:{port}/devtools/page/{target_id}"


def open_page(url: str | None):
    """``(port, target_id, page_url, error)``: the kept browser up, and the page to show in it."""
    rp = _origin_mod()
    cdp, err = rp._real_profile_cdp()
    if err or not cdp:
        return None, None, None, err or "the browser on your cloud computer is not set up to keep sign-ins"
    port = int(cdp.rsplit(":", 1)[1])
    if url:
        try:
            target = rp._cdp_call(port, "Target.createTarget", {"url": url}).get("targetId")
        except Exception as exc:  # noqa: BLE001
            return None, None, None, f"could not open {url}: {exc}"
        return port, str(target), url, None
    page = rp._pick_page(rp.driven_pages(), "")
    if page is None:
        return None, None, None, "the browser has no page open; pass the sign-in page as `url`"
    return port, str(page["id"]), str(page.get("url") or ""), None


def ws_url(edge: str, path: str) -> str:
    parts = urllib.parse.urlsplit(edge)
    scheme = "wss" if parts.scheme == "https" else "ws"
    return urllib.parse.urlunsplit((scheme, parts.netloc, path, "", ""))


class Relay(threading.Thread):
    """One page's screen out, the person's input in, until Done."""

    def __init__(self, edge_ws: str, bearer: str, page_ws: str, *, connect=None,
                 clock=time.monotonic, touch=None, url: str = ""):
        super().__init__(name="moe-sign-in-relay", daemon=True)
        self.edge_ws, self.bearer, self.page_ws = edge_ws, bearer, page_ws
        self._connect = connect
        self._clock = clock
        self._touch = touch or (lambda: None)
        self._next_id = 0
        self._lock = threading.Lock()
        self.size = None
        self.ended = None
        self.page = None
        self.edge = None
        self.url = url

    # -- CDP -------------------------------------------------------------------
    def cdp(self, method: str, params: dict | None = None) -> None:
        with self._lock:
            self._next_id += 1
            n = self._next_id
        self.page.send(json.dumps({"id": n, "method": method, "params": params or {}}))

    def start_screen(self, size: dict) -> None:
        self.size = size
        w, h = size["w"], size["h"]
        scale = min(float(size.get("dpr") or 1), 2.0)
        self.cdp("Emulation.setDeviceMetricsOverride",
                 {"width": w, "height": h, "deviceScaleFactor": scale, "mobile": True})
        self.cdp("Page.stopScreencast")
        self.cdp("Page.startScreencast", {"format": "jpeg", "quality": 60,
                                          "maxWidth": int(w * scale), "maxHeight": int(h * scale),
                                          "everyNthFrame": 1})

    def act(self, msg: dict) -> bool:
        """The person's input, on the page. False when they are done."""
        t = msg.get("t")
        self._touch()
        if t == "size":
            self.start_screen(msg)
        elif t == "tap":
            x, y = float(msg["x"]), float(msg["y"])
            self.cdp("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y})
            for kind in ("mousePressed", "mouseReleased"):
                self.cdp("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y,
                                                      "button": "left", "clickCount": 1})
        elif t == "text":
            self.cdp("Input.insertText", {"text": str(msg["s"])})
        elif t == "key" and msg.get("k") in KEYS:
            code, key, text = KEYS[msg["k"]]
            down = {"type": "keyDown", "key": key, "code": key, "windowsVirtualKeyCode": code,
                    "nativeVirtualKeyCode": code}
            if text:
                down["text"] = text
            self.cdp("Input.dispatchKeyEvent", down)
            self.cdp("Input.dispatchKeyEvent", {"type": "keyUp", "key": key, "code": key,
                                                "windowsVirtualKeyCode": code,
                                                "nativeVirtualKeyCode": code})
        elif t == "scroll":
            size = self.size or {"w": 400, "h": 700}
            self.cdp("Input.dispatchMouseEvent", {"type": "mouseWheel", "x": size["w"] / 2,
                                                  "y": size["h"] / 2, "deltaX": 0,
                                                  "deltaY": float(msg["dy"])})
        elif t == "back":
            self.cdp("Runtime.evaluate", {"expression": "history.back()"})
        elif t == "done":
            return False
        return True

    def on_page_event(self, raw) -> None:
        msg = json.loads(raw)
        method = msg.get("method")
        if method == "Page.screencastFrame":
            params = msg["params"]
            self.edge.send(base64.b64decode(params["data"]))
            self.cdp("Page.screencastFrameAck", {"sessionId": params["sessionId"]})
            self._touch()
        elif method == "Page.frameNavigated":
            frame = msg["params"].get("frame") or {}
            if not frame.get("parentId"):
                self.edge.send(json.dumps({"t": "page", "url": str(frame.get("url") or "")}))

    # -- the two loops ---------------------------------------------------------
    def _page_loop(self) -> None:
        while self.ended is None:
            try:
                raw = self.page.recv(timeout=1.0)
            except TimeoutError:
                continue
            except Exception:  # noqa: BLE001 - the page or browser went
                self.ended = self.ended or "page closed"
                return
            try:
                self.on_page_event(raw)
            except Exception:  # noqa: BLE001 - a frame the edge would not take is dropped
                logger.debug("sign-in relay: page event not forwarded", exc_info=True)

    def run(self) -> None:
        connect = self._connect
        if connect is None:
            from websockets.sync.client import connect
        try:
            self.page = connect(self.page_ws, max_size=None, open_timeout=15)
            self.edge = connect(self.edge_ws, open_timeout=15, max_size=64 * 1024,
                                additional_headers={"Authorization": "Bearer " + self.bearer})
        except Exception as exc:  # noqa: BLE001
            logger.warning("sign-in relay: could not connect: %s", exc)
            self.ended = "could not connect"
            self._close()
            return
        self.cdp("Page.enable")
        if self.url:  # the address bar, before the page next navigates
            self.edge.send(json.dumps({"t": "page", "url": self.url}))
        pages = threading.Thread(target=self._page_loop, name="moe-sign-in-page", daemon=True)
        pages.start()
        deadline = self._clock() + LIVE_S
        try:
            while self.ended is None and self._clock() < deadline:
                try:
                    raw = self.edge.recv(timeout=1.0)
                except TimeoutError:
                    continue
                if isinstance(raw, bytes):
                    continue
                try:
                    msg = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(msg, dict) and not self.act(msg):
                    self.ended = "done"
        except Exception:  # noqa: BLE001 - the edge ended it (Done, expiry, a newer link)
            self.ended = self.ended or "ended"
        self.ended = self.ended or "time"
        self._close()
        pages.join(timeout=3)
        logger.info("sign-in relay: ended (%s)", self.ended)

    def _close(self) -> None:
        if self.page is not None:
            for method in ("Page.stopScreencast", "Emulation.clearDeviceMetricsOverride"):
                try:
                    self.cdp(method)
                except Exception:  # noqa: BLE001
                    pass
        for ws in (self.edge, self.page):
            try:
                if ws is not None:
                    ws.close()
            except Exception:  # noqa: BLE001
                pass


def make_link(site: str, url: str | None, edge_and_bearer, *, post=None, start=True) -> dict:
    """The whole tool: ``{"success", "link", ...}`` or ``{"success": False, "error"}``."""
    if edge_and_bearer is None:
        return {"success": False, "error": "this cloud computer is not signed in to Memoe, so it "
                                           "cannot make a sign-in link"}
    edge, bearer = edge_and_bearer
    port, target, page_url, err = open_page(url)
    if err:
        return {"success": False, "error": err}
    if post is None:
        import httpx
        post = lambda path, body: httpx.post(edge.rstrip("/") + path, json=body, timeout=20,  # noqa: E731
                                             headers={"Authorization": "Bearer " + bearer})
    response = post("/v1/live", {"site": site or ""})
    if response.status_code != 200:
        return {"success": False, "error": f"Memoe would not make a sign-in link ({response.status_code})"}
    minted = response.json()
    if not minted.get("delivered"):
        return {"success": False, "error": "Memoe could not send the sign-in link to the person's own "
                                           "chat (%s), so none was made. Tell them the site needs them "
                                           "and that no chat of theirs is reachable from their cloud "
                                           "computer." % (minted.get("error") or "no chat reachable")}
    minted.pop("url", None)  # never carried, whatever an edge sends
    rp = _origin_mod()
    bt = rp._origin()

    def touch():
        bt._real_profile_last_used = time.time()  # the idle reaper must not close it mid-sign-in

    relay = Relay(ws_url(edge, minted["machine_path"]), bearer, _page_ws(port, target), touch=touch,
                  url=page_url or "")
    if start:
        relay.start()
    minutes = int(minted.get("expires_in", 600)) // 60
    chat = str(minted.get("channel") or "chat").replace("_", " ")
    return {"success": True, "sent_to": f"the person's own {chat} chat", "works_for_minutes": minutes,
            "next": f"Memoe has sent the sign-in link for {site or 'the site'} to the person's own {chat} "
                    f"chat. Say in one line that it's there (\"I've sent you a link on {chat.title()} to sign "
                    f"in to {site or 'the site'}\"); do not write any link yourself. It works for {minutes} "
                    f"minutes. Then END YOUR TURN; when they say they're done, carry on in the same browser "
                    f"(browser_handoff(done=true) if you handed the page over)."}
