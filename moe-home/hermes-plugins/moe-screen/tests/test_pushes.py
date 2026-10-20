"""The other side pushed — on a Mac the gateway leaves the marker for the app.

Slice E1. The frame arrives on the gateway's relay socket; moe-ledger, which
knows how to answer it, is never `register()`ed on a Mac (claimstore is the
memory provider there), so moe-screen installs the handler. These hold:

* on a Mac, `listen` puts a `ledger_moved` handler in the transport's table,
  and a frame through it leaves `$MOE_HOME/cloud/pull-requested` with the
  high-water mark — the file `PullNudge.swift` watches;
* on the machine it installs nothing, so moe-ledger's pulling handler is
  never replaced by a marker no process reads;
* `register()` is what calls it (red with the call removed);
* the marker's spelling is the Swift watcher's.
"""

from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import sys
import types

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.normpath(os.path.join(HERE, ".."))
REPO = os.path.normpath(os.path.join(PLUGIN, "..", "..", ".."))
sys.path.insert(0, HERE)

import test_moe_screen  # noqa: E402  (load_adapter, StubCtx)


def load_pushes():
    pkg = types.ModuleType("moe_screen_pkg")
    pkg.__path__ = [PLUGIN]
    sys.modules["moe_screen_pkg"] = pkg
    spec = importlib.util.spec_from_file_location("moe_screen_pkg.pushes",
                                                  os.path.join(PLUGIN, "pushes.py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules["moe_screen_pkg.pushes"] = mod
    spec.loader.exec_module(mod)
    return mod


class FakeTransport:
    """The fork's `WebSocketRelayTransport` shape: a class-level table of
    `type -> async function(transport, frame)`, and an unknown type dropped."""
    _FRAME_HANDLERS: dict = {}

    async def handle(self, frame):
        handler = self._FRAME_HANDLERS.get(frame.get("type"))
        if handler is not None:
            await handler(self, frame)


@pytest.fixture
def home(tmp_path, monkeypatch):
    FakeTransport._FRAME_HANDLERS = {}
    monkeypatch.setenv("MOE_HOME", str(tmp_path))
    monkeypatch.delenv("MOE_RUNS_IN", raising=False)
    return tmp_path


def marker(home):
    return home / "cloud" / "pull-requested"


def test_on_a_mac_a_frame_leaves_the_marker_for_the_app(home):
    pushes = load_pushes()
    assert pushes.listen(FakeTransport) is True
    assert list(FakeTransport._FRAME_HANDLERS) == ["ledger_moved"]
    assert not marker(home).exists()

    asyncio.run(FakeTransport().handle({"type": "ledger_moved", "highWater": 41}))

    body = json.loads(marker(home).read_text())
    assert body["high_water"] == 41
    assert oct(marker(home).stat().st_mode & 0o777) == "0o600"
    # Nothing else under cloud/: the app is the client, the gateway pulls nothing.
    assert sorted(p.name for p in (home / "cloud").iterdir()) == ["pull-requested"]


def test_on_the_machine_nothing_is_installed(home, monkeypatch):
    monkeypatch.setenv("MOE_RUNS_IN", "cloud")
    pushes = load_pushes()
    assert pushes.listen(FakeTransport) is False
    assert FakeTransport._FRAME_HANDLERS == {}


def test_register_is_what_listens(home):
    """The adapter's register() with a relay transport importable installs
    the handler. Remove `_pushes.listen()` from register() and this is red."""
    mod = test_moe_screen.load_adapter()
    relay = types.ModuleType("gateway.relay")
    ws = types.ModuleType("gateway.relay.ws_transport")
    ws.WebSocketRelayTransport = FakeTransport
    gateway = types.ModuleType("gateway")
    saved = {k: sys.modules.get(k) for k in ("gateway", "gateway.relay",
                                              "gateway.relay.ws_transport")}
    sys.modules.update({"gateway": gateway, "gateway.relay": relay,
                        "gateway.relay.ws_transport": ws})
    try:
        mod.register(test_moe_screen.StubCtx())
    finally:
        for k, v in saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v
    assert "ledger_moved" in FakeTransport._FRAME_HANDLERS
    asyncio.run(FakeTransport().handle({"type": "ledger_moved", "highWater": 3}))
    assert json.loads(marker(home).read_text())["high_water"] == 3


def test_no_relay_transport_is_a_quiet_no(home):
    pushes = load_pushes()
    saved = sys.modules.get("gateway")
    sys.modules["gateway"] = types.ModuleType("gateway")  # no .relay under it
    try:
        assert pushes.listen() is False
    finally:
        if saved is None:
            sys.modules.pop("gateway", None)
        else:
            sys.modules["gateway"] = saved


def test_the_marker_is_where_the_swift_watcher_looks():
    # The watcher is the official build's closed half; a tree without it (the
    # open export) has no Swift side to agree with.
    closed = os.path.join(REPO, "cloud", "Sources")
    if not os.path.isdir(closed):
        import pytest
        pytest.skip("no closed half in this tree")
    swift = open(os.path.join(closed, "MoeCloud", "PullNudge.swift"),
                 encoding="utf-8").read()
    assert 'markerName = "pull-requested"' in swift
    conductor = open(os.path.join(closed, "MoeAway", "CloudSync.swift"),
                     encoding="utf-8").read()
    assert "PullNudge(directory: root" in conductor
