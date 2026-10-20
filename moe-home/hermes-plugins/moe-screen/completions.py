"""A finished helper's result, put in front of the person now.

Hermes runs a handed-off job (``delegate_task``) in the background and, when
it finishes, looks for somewhere to deliver the result. A chat platform gets
a new message. The Mac's api_server cannot be pushed to, so upstream parks
the result on the session transcript for the person's NEXT turn — a turn
they may not start for hours, while the thing they asked for "in the
background" sits done and unreported.

This is the ``deliver_detached_completion`` hook (Moe's fork,
``gateway/run_notifications.py``): the gateway offers the completion here
first. On a Mac with a screen it goes into the inbox as a ``turn`` — the app
(``Conductor.watchForInbox``) waits until Moe is idle, then runs a turn on
it, so Moe says the outcome in its own words instead of reading a results
block aloud. Returning True tells the gateway it is delivered; anything
else and the gateway keeps its own row, so nothing is ever lost to a
screenless machine or a full disk.

Python 3.9, stdlib only, like the rest of this plugin.
"""
try:
    from . import deliver as _deliver
except ImportError:  # loaded as a lone file, the way the tests load deliver.py
    import importlib.util as _ilu
    import os as _os
    _spec = _ilu.spec_from_file_location(
        "moe_screen_deliver", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "deliver.py"))
    _deliver = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(_deliver)


def deliver_detached_completion(session_id="", text="", event=None, **_kw):
    body = (text or "").strip()
    if not body:
        return None
    if not _deliver.has_screen():
        # A cloud machine: nobody reads its inbox. The gateway's own row
        # reaches the next turn wherever that is.
        return None
    try:
        # The session it was started from goes with it, so the app can put
        # the result in the conversation that asked for it (see write_inbox).
        _deliver.write_inbox(body, source="helper", kind="turn",
                             session_id=str(session_id or "").strip())
    except OSError:
        return None
    return True
