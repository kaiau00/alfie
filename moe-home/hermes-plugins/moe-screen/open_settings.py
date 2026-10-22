"""``moe_open_settings(pane)``: the brain opens the System Settings pane that
fixes a failure, while the person is there (docs/FIXABLE-FAILURES.md §3–4).

A tool result that carries a fixable ``code`` names its ``pane``
(``Privacy_AllFiles`` …). Alfie says the cause, offers to open the setting, and
on a yes calls this. The Alfie app does the opening, because only the app can
watch the grant afterwards (GrantWatch) and carry the task on once it flips.

Three things this refuses, each tested:

* **Anything but an allowlisted pane id.** Not a URL, not a scheme, not a
  path: the app turns the id into the one ``x-apple.systempreferences`` link
  it already knows. ``PANES`` is kept equal to the app's
  ``ToolFix.knownPanes`` by ``GrantWatchTests``.
* **A turn nobody is at.** Opening System Settings on someone's screen
  unasked is intrusive, so it needs the person's own live turn at the Mac:
  never a cron job, a background note from the app, a helper, or a chat
  message from a phone. Presence is the fork's judgement
  (``tools.browser_chrome_extension.turn_presence``, which reads the
  X-Hermes-Turn-Origin the app declared, over the tool bridge under the
  claude-code runtime), and it fails closed: no answer is "not present".
* **Nothing else.** It cannot toggle a grant; macOS does not allow that.

The app checks again on its side — it acts only while a turn the person
started is in flight on its own screen — so this plugin is not the only gate.
The signal is a distributed notification (the same channel MoeConfirm uses),
which a web page cannot post.
"""
from __future__ import annotations

import json
import sys

TOOL_NAME = "moe_open_settings"
#: Its own toolset, listed in configure-hermes.py's MOE_TOOLSETS (the Mac)
#: and not in MOE_CHAT_TOOLSETS. That is not the gate: under the claude-code
#: runtime Hermes offers every registered tool whatever the toolsets say, so
#: a chat platform's turn can see this tool too. The `why` check below (and
#: the app's own) is what refuses it there.
TOOLSET = "moe_settings"

#: The distributed notification the app listens for; the object is the pane id.
SIGNAL = "com.moe.openSettings"

#: Every pane a fix can name: the app's `ToolFix.knownPanes`, each of which
#: is a PermissionGuide.catalogue pane (GrantWatchTests holds both).
PANES = (
    "Privacy_AllFiles",
    "Privacy_FilesAndFolders",
    "Privacy_Automation",
    "Privacy_Accessibility",
    "Privacy_ScreenCapture",
    "Privacy_Microphone",
    "Privacy_Calendars",
    "Privacy_Reminders",
    "Privacy_Contacts",
)

#: The fork's words for a live turn at the Mac itself. "the person's message"
#: is live too, but on a chat platform — the person may be anywhere.
_AT_THE_MAC = "the person's own turn"

TOOL_SCHEMA = {
    "name": TOOL_NAME,
    "description": (
        "Open the System Settings pane that fixes a failed tool, on the "
        "person's Mac, and watch for them to switch it on. Call it only after "
        "they said yes to your offer to open it. `pane` is the `pane` field "
        "of the failed tool's result (e.g. Privacy_AllFiles). When the switch "
        "flips you get a background note saying so: then carry on."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "pane": {
                "type": "string",
                "enum": list(PANES),
                "description": "The failed result's `pane`, exactly.",
            },
        },
        "required": ["pane"],
    },
}


def _ok(msg: str) -> str:
    return json.dumps({"success": True, "result": msg})


def _no(msg: str) -> str:
    return json.dumps({"success": False, "error": msg})


def presence() -> dict:
    """``{"live": bool, "why": str}`` from the fork, or not live."""
    try:
        from tools.browser_chrome_extension import turn_presence
        verdict = turn_presence()
        return verdict if isinstance(verdict, dict) else {"live": False, "why": "no answer"}
    except Exception as e:  # an older fork, no bridge: fail closed
        return {"live": False, "why": "presence could not be established (%s)" % type(e).__name__}


def post(pane: str) -> bool:
    """Post SIGNAL with the pane id as its object, through CoreFoundation."""
    if sys.platform != "darwin":
        return False
    try:
        import ctypes
        import ctypes.util
        cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFNotificationCenterGetDistributedCenter.restype = ctypes.c_void_p
        cf.CFNotificationCenterPostNotification.argtypes = [
            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_bool]
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        utf8 = 0x08000100
        name = cf.CFStringCreateWithCString(None, SIGNAL.encode(), utf8)
        obj = cf.CFStringCreateWithCString(None, pane.encode(), utf8)
        cf.CFNotificationCenterPostNotification(cf.CFNotificationCenterGetDistributedCenter(),
                                                name, obj, None, True)
        cf.CFRelease(name)
        cf.CFRelease(obj)
        return True
    except Exception:
        return False


def handle_tool(params=None, **kwargs) -> str:
    """Hermes calls ``handler(args_dict, **kw)``. Always JSON, never raises."""
    try:
        args = params if isinstance(params, dict) else dict(kwargs)
        pane = args.get("pane")
        if not isinstance(pane, str) or pane not in PANES:
            return _no("moe_open_settings takes one of these pane ids, never a URL: " + ", ".join(PANES))
        verdict = presence()
        if not verdict.get("live") or verdict.get("why") != _AT_THE_MAC:
            return _no("Not opened: this is %s, and System Settings is only opened while the person "
                       "is at the Mac in their own turn. Tell them what to switch on instead."
                       % (verdict.get("why") or "not the person's own turn"))
        if not post(pane):
            return _no("Not opened: the Alfie app could not be reached.")
        return _ok("opened %s, watching for the switch" % pane)
    except Exception as e:
        return _no("%s: %s" % (type(e).__name__, e))


def available() -> bool:
    return sys.platform == "darwin"
