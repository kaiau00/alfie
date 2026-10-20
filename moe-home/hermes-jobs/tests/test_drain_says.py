"""The say drain: a sentence the machine had nobody to tell, spoken here
(LEDGER-WIRE §16, CLOUD-PLAN §6 item 7).

Drives the REAL drain — `moe-drain-intents.py`'s `drain()`, the whole
function, through the same `Mac` fixture the intent suite uses — rather than
`drain_says` in isolation. That is deliberate and it is the point of this
file: the say pass sits *before* the "nothing outstanding" early return, and
a test that called `drain_says` directly would pass just as well with the call
site deleted, leaving says spoken only on ticks that happened to carry an
intent. §13.3 is the record of a slice that shipped green and inert for
exactly that reason.

Nothing here sends: the fixture replaces `fan_out` with a raise, so a say
that is "spoken" reaches the island inbox and nowhere else, which is what a
Mac with no reminderChannels does anyway.
"""

from __future__ import annotations

import json
import os
import time

import pytest

from test_drain_intents import MACHINE, THREAD, Mac, Sender, load_drain, mac, run  # noqa: F401

SENTENCE = "Your flight moved to 6am."


@pytest.fixture(autouse=True)
def no_real_sends(mac, monkeypatch):
    """The intent fixture's guard, made precise rather than relaxed.

    `test_drain_intents.mac` replaces `fan_out` with an unconditional raise,
    which is right for that suite: nothing there should ever reach a
    connector. A spoken say goes through `deliver.deliver`, which calls
    `fan_out` with the channel list — EMPTY here, since this Mac configures no
    reminderChannels — so the blunt guard fires on a call that sends nothing.

    This one still refuses a real send, which is the property worth keeping,
    and it also asserts the list is empty: a say that quietly started
    forwarding to a connector would otherwise pass as "spoken".
    """
    def only_if_it_would_send(text, channels, **kw):
        assert not channels, "a test tried to actually send a message to %r" % (channels,)
        return {}
    monkeypatch.setattr(mac.deliver, "fan_out", only_if_it_would_send)


def says_lib(mac):
    lib = mac.drain.says_module(mac.lib)
    assert lib is not None, "moeledger.says must import from the payload"
    return lib


def write_say(mac, *, text=SENTENCE, runtime="mac", reason="no-channels",
              expires_in=3600, device=MACHINE, key=None, thread=THREAD):
    """One `say`, on the MACHINE's chain — the away machine wrote it."""
    sy = says_lib(mac)
    body = sy.say_body(thread, runtime, reason, {"text": text, "source": "cron",
                                                 "job": "moe-proactive"},
                       key if key is not None else mac.key,
                       expires=sy.expiry(ttl=expires_in))
    return mac.append("say", body, device=device)


def inbox(mac):
    d = mac.moe / "inbox"
    return sorted(d.glob("*.json")) if d.is_dir() else []


def spoken_texts(mac):
    return [json.loads(p.read_text())["text"] for p in inbox(mac)]


def kinds(mac):
    return [r.kind for r in mac.vault.read_ledger()]


# ---------------------------------------------------------------------------
# The whole point
# ---------------------------------------------------------------------------

def test_a_held_sentence_is_spoken_on_this_mac(mac):
    write_say(mac)
    report = run(mac, Sender())
    assert report.says_spoken == 1
    assert spoken_texts(mac) == [SENTENCE]
    assert "say.spoken" in kinds(mac) and "say.attempt" in kinds(mac)


def test_it_is_spoken_on_a_tick_with_no_intents_at_all(mac):
    # The case the call site's POSITION exists for. A machine writes says
    # when nobody could be reached, which is a different event from a person
    # queueing work — so the ordinary tick that carries a say carries no
    # intent, and a say pass placed after the "nothing outstanding" return
    # would never run on it.
    write_say(mac)
    assert not [r for r in mac.vault.read_ledger() if r.kind == "intent"]
    report = run(mac, Sender())
    assert report.says_spoken == 1 and report.outcomes == []
    assert spoken_texts(mac) == [SENTENCE]


def test_a_second_drain_says_nothing_and_writes_nothing(mac):
    # Exactly-once, and the assertion that matters is the ISLAND, not the
    # counter: the counter could be right while the person hears it twice.
    write_say(mac)
    run(mac, Sender())
    before = inbox(mac)
    report = run(mac, Sender())
    assert report.says_spoken == 0
    assert inbox(mac) == before


def test_a_say_addressed_to_the_machine_is_not_spoken_here(mac):
    # What stops the machine draining what it wrote for the Mac — and, on a
    # Mac, stops a say meant for the other runtime being read out loud.
    write_say(mac, runtime="cloud")
    report = run(mac, Sender())
    assert report.says_spoken == 0 and inbox(mac) == []


def test_a_say_past_its_deadline_is_recorded_expired_and_never_spoken(mac):
    # A reminder four days late read out at breakfast is worse than one
    # missed (§14.4 rule 3).
    write_say(mac, expires_in=-60)
    report = run(mac, Sender())
    assert report.says_expired == 1 and report.says_spoken == 0
    assert inbox(mac) == []
    assert "say.spoken" in kinds(mac)          # recorded, so it stops being examined
    assert "say.attempt" not in kinds(mac)     # and never attempted


def test_a_say_this_mac_cannot_open_is_left_entirely_alone(mac):
    # Present-but-unreadable is not absent: the thread key may not have
    # arrived. Nothing is written, so a later tick with the key still speaks it.
    write_say(mac, key=os.urandom(32))
    report = run(mac, Sender())
    assert report.says_unreadable == 1 and report.says_spoken == 0
    assert inbox(mac) == []
    assert "say.attempt" not in kinds(mac) and "say.spoken" not in kinds(mac)


def test_the_attempt_is_recorded_before_the_sentence_is_spoken(mac):
    # The ordering IS the exactly-once guarantee: a Mac that dies between the
    # two has spent the attempt. Asserted by making the speaking fail — the
    # attempt must still be on the chain, and the say must not be spoken later.
    write_say(mac)
    deliver = mac.deliver
    original = deliver.deliver
    try:
        deliver.deliver = lambda *a, **kw: (False, "the island is on fire")
        report = run(mac, Sender())
    finally:
        deliver.deliver = original
    assert report.says_spoken == 0
    assert "say.attempt" in kinds(mac), "the attempt must be written BEFORE the delivery"
    assert "say.spoken" not in kinds(mac)
    # And the cap means it is not tried again — the trade §14.3a makes.
    report = run(mac, Sender())
    assert report.says_spoken == 0 and inbox(mac) == []


def test_two_held_sentences_are_spoken_in_the_order_they_were_said(mac):
    write_say(mac, text="first")
    write_say(mac, text="second")
    run(mac, Sender())
    assert spoken_texts(mac) == ["first", "second"]


def test_nothing_is_spoken_on_a_machine(mac, monkeypatch):
    # §14.4 rule 6 at the top of `drain()`: this job is a Mac's. A machine
    # draining its own says would speak them into a void.
    monkeypatch.setenv("MOE_RUNS_IN", "cloud")
    write_say(mac)
    report = run(mac, Sender())
    assert report.says_spoken == 0 and inbox(mac) == []


def test_the_sentence_never_reaches_the_log(mac, capsys):
    # The drain's log on a machine is Fly's, in the clear, and the text is
    # sealed precisely so it is not there. Ids and reasons only.
    #
    # `capsys`, NOT `caplog`. This job's `log()` writes to sys.stderr
    # directly rather than through the logging module, so the first version
    # of this test watched a stream nothing was ever written to and passed
    # against a drain that logged the sentence in full. A mutation that put
    # `say.text` in the log line survived it, which is how it was found.
    write_say(mac)
    run(mac, Sender())
    captured = capsys.readouterr()
    assert SENTENCE not in captured.err
    assert SENTENCE not in captured.out


def test_a_say_from_a_revoked_machine_is_never_spoken(mac):
    # §14.4 rule 7. A machine the person has removed must not be able to put
    # words on their island afterwards — the whole reason `trusted` is
    # threaded through the say pass rather than left None.
    write_say(mac)
    mac.write_peers([MACHINE], revoked=[MACHINE])
    report = run(mac, Sender())
    assert report.says_untrusted == 1 and report.says_spoken == 0
    assert inbox(mac) == []
    assert "say.attempt" not in kinds(mac)
