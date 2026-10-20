"""A person is at the screen, unless a test says otherwise.

`make_handler` holds a send for the owner when the fork's `turn_presence`
says nobody started this turn (hold_for_owner). Under pytest there is no
turn at all, so the real answer is "not live" and every send test would be
held rather than run. The held path has tests of its own that set the
verdict they need; everything else runs as a person's live turn — which is
the path where the card, not this plugin, is the gate.
"""

import pytest


@pytest.fixture(autouse=True)
def _a_person_is_present(monkeypatch):
    try:
        import tools.browser_chrome_extension as presence
    except Exception:
        return
    monkeypatch.setattr(presence, "turn_presence",
                        lambda: {"live": True, "why": "the person's own turn"})
