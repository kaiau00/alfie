#!/usr/bin/env python3
"""The situations engine, one tick (docs/PROACTIVE-MEMORY.md §4; the engine is
moe-home/lib/situations.py).

A `no_agent` Hermes job every five minutes. **Its stdout is a message to the
person** (a no_agent job's stdout is its delivery), so it prints nothing but
an offer, and only on the away machine; on the Mac an offer is handed to
moe-screen's deliver directly, with the situation's id for the island's
card. What it did is in $MOE_HOME/logs/situations.jsonl.

Background thinking off (config.json `backgroundThinking: false`) means no
model call — no sensor, no preparer, and no Composio read plan (the adapter
is told, MOE_NO_THINK): the tick still moves the cursors, so switching it
back on does not read a backlog as if it had just arrived.

Runs under Hermes's interpreter (the scheduler runs a .py with its own
sys.executable), which is what makes `call_llm` importable.
"""
import json
import os
import sys
import time

STARTED = time.monotonic()


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def hermes_agent_dir():
    for d in (os.environ.get("HERMES_AGENT_DIR", ""),
              os.path.join(os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes"),
                           "hermes-agent"),
              "/opt/hermes"):
        if d and os.path.isdir(os.path.join(d, "agent")):
            return d
    return ""


def background_thinking_on():
    try:
        with open(os.path.join(moe_home(), "config.json"), encoding="utf-8") as f:
            return json.load(f).get("backgroundThinking", True) is not False
    except (OSError, ValueError):
        return True


def offers_on():
    """Only a Mac, and only with `situationOffers: true` in config.json,
    raises one — never the away machine, whatever the config says (owner,
    2026-09-29: offers from the cloud stay off). The machine's path is built
    and tested (`offer`, status #10.4); turning it on is this one line and
    the owner's decision."""
    if (os.environ.get("MOE_RUNS_IN") or ("mac" if sys.platform == "darwin" else "cloud")) != "mac":
        return False
    try:
        with open(os.path.join(moe_home(), "config.json"), encoding="utf-8") as f:
            return json.load(f).get("situationOffers") is True
    except (OSError, ValueError):
        return False


def owner_name():
    try:
        with open(os.path.join(moe_home(), "memory", "profile", "identity.md"), encoding="utf-8") as f:
            for line in f:
                if line.lower().startswith("name:"):
                    return line.split(":", 1)[1].strip()[:80]
    except OSError:
        pass
    return ""


def main():
    lib = os.path.join(moe_home(), "lib")
    if lib not in sys.path:
        sys.path.insert(0, lib)
    agent = hermes_agent_dir()
    if agent and agent not in sys.path:
        sys.path.insert(0, agent)
    import situations
    import cheap_model
    import prepare

    def preparer(sit):
        # Every call bounded by what the tick has left (situations.time_left):
        # the machine's claim stops the tick at 280 s, and a prepare cut off
        # there has paid for nothing (review §4).
        def plan_call(m):
            return cheap_model.call(m, max_tokens=500,
                                    timeout=max(5.0, min(45.0, situations.time_left() * 0.25)))

        def compose_call(m):
            return cheap_model.call_chosen(m, max_tokens=1500,
                                           timeout=max(5.0, min(180.0, situations.time_left() - 10)))
        return prepare.prepare(sit, plan_call=plan_call, compose_call=compose_call)
    def offerer(sit):
        return offer(sit, situations, load_deliver())

    # What the other side sent since the last tick, before this one reads
    # (lib/travel.py): the Mac's cursors on the machine, the machine's
    # situations and promises on the Mac.
    trip = travel_module()
    if trip is not None:
        got = trip.receive()
        if got.get("error"):
            print("situations: receiving documents failed: %s" % got["error"], file=sys.stderr)
    try:
        # The tick's budget counts from this process's start, not the
        # tick's: the claim shim on the machine kills the whole job at 280 s,
        # and what ran before the tick (receiving) came out of that too
        # (review 2026-09-29 #2). Ten seconds are kept back for sending.
        spent = time.monotonic() - STARTED
        situations.tick(think=background_thinking_on(), owner_name=owner_name(), preparer=preparer,
                        offerer=offerer if offers_on() else None,
                        budget_s=max(30.0, situations.TICK_BUDGET_S - spent - 10.0))
    except Exception as e:  # noqa: BLE001 — stderr only; stdout is a message
        print("situations: tick failed: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 1
    # And what this tick changed goes now, not at the next chat session.
    if trip is not None:
        sent = trip.send()
        if sent.get("error"):
            print("situations: sending documents failed: %s" % sent["error"], file=sys.stderr)
    return 0


def offer(sit, situations, deliver):
    """An offer goes where reminders go (moe-screen deliver), through
    `deliver()` on both sides, with the situation's id and the brain's note:
    on the Mac the island draws its card; on the away machine it reaches the
    person's own chat through Alfie's cloud, and the note is recorded against
    that chat, so "send it" there reaches the brain WITH the draft and the
    conversation's id (status #10.4 — printed to the job's stdout, as it
    was, the note was lost and "send it" arrived bare).

    On the machine, which only ever reaches a chat, it offers only when:
    - the person turned offers on in their chats (`situationOffersToChats`,
      carried from the Mac with the other background settings);
    - the conversation is one it can reply in — a Composio service, through
      the away send gate; WhatsApp, Messages and Mail are sent from the Mac,
      so those offers wait for it;
    - the person's zone is known (the last the Mac said, however old) and it
      is not their quiet hours — an offer is never worth a night message.
    Returns True when it went, False when delivering it failed, and None
    when it is not this side's to offer now (the engine then tries the next
    one); nothing that did not go is marked offered."""
    if deliver is None:
        return None
    texts = situations.offer_texts(sit)
    if not situations.on_mac():
        cfg = deliver.read_config()
        if not deliver.offers_to_chats(cfg):
            return None
        if not str(sit.get("source") or "").startswith("composio/"):
            return None
        if deliver.local_zone(any_age=True) is None or deliver.is_quiet(cfg=cfg, any_age=True):
            return None
    ok, err = deliver.deliver(texts["line"], source="situations", job="moe-situations",
                              offer=sit["id"], instruction=texts["note"],
                              channel_text=texts["chat"], **_subject(deliver, sit["id"]))
    if not ok:
        print("situations: offer not delivered: %s" % err, file=sys.stderr)
    return ok


def _subject(deliver, sid):
    """The offer card's subject — its situation — for a deliver.py that takes
    one; an older one is called as before (the app derives the same key from
    the offer id)."""
    import inspect
    try:
        params = inspect.signature(deliver.deliver).parameters.values()
        if any(p.name == "subject" or p.kind is inspect.Parameter.VAR_KEYWORD for p in params):
            return {"subject": "situation:%s" % sid}
    except (TypeError, ValueError):
        pass
    return {}


def travel_module():
    """lib/travel.py, or None (an older home without it travels as before)."""
    try:
        import travel
        return travel
    except Exception as e:  # noqa: BLE001
        print("situations: travel will not import: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return None


def load_deliver():
    """moe-screen's deliver.py beside this Hermes, or None."""
    import importlib.util
    path = os.path.join(os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes"),
                        "plugins", "moe-screen", "deliver.py")
    if not os.path.isfile(path):
        return None
    try:
        spec = importlib.util.spec_from_file_location("moe_screen_deliver_for_situations", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception as e:  # noqa: BLE001
        print("situations: moe-screen deliver will not import: %s: %s" % (type(e).__name__, e),
              file=sys.stderr)
        return None


if __name__ == "__main__":
    sys.exit(main())
