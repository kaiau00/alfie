"""Live proxy when the Mac is awake, queue when it is not (slice E2).

CHANNELS-CONNECTORS-DECISIONS §5: a Mac-only connector called on the machine
is carried out on the Mac *now* when the Mac holds a live relay socket, and
queued as an `intent` (LEDGER-WIRE §14) when it does not. Two halves, both
in `maccall.py`:

* the **machine's** half — `try_proxy`: seals the call under the thread key,
  asks the edge, waits, opens the Mac's sealed answer; `None` means "no live
  Mac, queue it";
* the **Mac's** half — `answer_mac_call`: opens the frame under the same
  key, runs the connector verb through the plugin's own `run_verb` (the same
  function the drain and the Mac's own brain use, gates included), seals
  the output back. Never through the model: a direct verb call.

What has to be right, and is checked here:

* a live Mac answers in the turn: the tool result is the Mac's output, marked
  as run on the Mac, and NO intent is written;
* no live Mac: exactly today's queue — one sealed intent, the deferred shape;
* no edge to ask (no URL, no token, no thread): the queue, and no HTTP;
* the person's words cross the edge only inside the seal — the request body
  carries `via` / `target` / `action` in the clear and nothing else;
* a Mac that has not got the thread's key yet says so, and the call queues;
* a Mac that was awake and did not answer in time is NOT then queued as
  well — a note created twice is worse than a note created late;
* a `send` with no live Mac is refused rather than queued (§14.4 rule 5);
* on the Mac: the verb runs with the declared stdin, the answer opens under
  the thread key, a missing connector or verb is a failure sentence, a
  foreign `via` is refused, and the receiver installs itself on the
  transport's frame table and answers with a `mac_call_result`.

Nothing here reaches a real edge, a real ~/.moe or ~/.hermes, or runs a
real connector: the edge is an `httpx.MockTransport` playing both the edge
and the Mac, and the connectors are shell scripts that echo.
"""

import asyncio
import json
import os
import time
import unittest
import uuid
from unittest import mock

import httpx

from test_detached_intents import ECHOES, OK, SESSION, THREAD, Machine, plugin

from moeledger import intents, threadcrypto          # noqa: E402
from moeledger.records import canonical_json         # noqa: E402
from moeledger.vault import Vault                    # noqa: E402
from moeledger.enrolment import DeviceToken         # noqa: E402

# The plugin's own copy, not a second one loaded beside it: `TRANSPORT` and
# the timing constants the tests turn are read from the module the handler
# actually calls, and a copy of it would be turned and never consulted.
maccall = plugin._maccall()
assert maccall is not None, "maccall.py did not load beside the plugin"

EDGE = "https://edge.test"
# The shape `Vault.token()` accepts — base64 of 32 bytes — because a token
# that does not parse is a machine that never asks the edge at all, and a
# made-up string here once turned every live test into a queue test.
TOKEN = DeviceToken(b"\x07" * 32).text

CATALOGUE = [
    ("gmail", "status pull", OK, "runs_in=both\n"),
    ("notes", "status pull create", ECHOES,
     "runs_in=mac\ncreate_stdin=title* body\n"),
    ("reminders", "status pull", ECHOES, "runs_in=mac\n"),
    ("imessage", "status pull send", ECHOES,
     "runs_in=mac\nsend_args=to* text*\n"),
]


class Enrolled(Machine):
    """A `Machine` that also knows its edge and holds a device token — what a
    machine that has enrolled looks like, and what `try_proxy` needs."""

    def __init__(self, *args, edge=EDGE, token=TOKEN, **kwargs):
        super().__init__(*args, **kwargs)
        self.edge = edge
        self.token = token

    def __enter__(self):
        super().__enter__()
        if self.want_vault:
            vault = Vault(os.path.join(self.hermes_home, "moe"))
            if self.edge:
                vault.write_json(vault.edge_path, {"url": self.edge})
            if self.token:
                vault.save_credential(DeviceToken.from_text(self.token), tenant="t",
                                      sponsor_device="s", enrolment_id="e")
        return self


class FakeEdge:
    """The edge and the Mac behind it, as an httpx transport.

    `mac` is what the Mac does with the request the edge would forward it:
    a callable taking the opened payload and returning the result object
    the Mac would send back (sealed by the test under the thread key, as
    the Mac seals it). `live=False` is a tenant with no Mac on the wire.
    `pending_polls` is how many polls answer "not yet" before the answer.
    """

    def __init__(self, key, *, live=True, mac=None, pending_polls=0, mac_live=True):
        self.key = key
        self.live = live
        self.mac = mac or (lambda payload: {"state": "done", "sealed": threadcrypto.seal(
            canonical_json(intents.result_payload(output="ok: from the Mac", seconds=0.1,
                                                  callId=payload["call"]["id"])),
            key)})
        self.pending_polls = pending_polls
        self.mac_live = mac_live
        self.requests = []
        self.answer = None

    def transport(self):
        return httpx.MockTransport(self)

    def __call__(self, request):
        self.requests.append(request)
        assert request.headers.get("Authorization") == "Bearer " + TOKEN
        if request.method == "POST":
            body = json.loads(request.content)
            self.body = body
            # The real edge keeps the caller's id (`_mac_call_id`), so the
            # poll that follows is for the id the machine chose.
            self.call_id = body["callId"]
            if not self.live:
                return httpx.Response(200, json={"live": False, "callId": self.call_id,
                                                 "error": "no live mac"})
            plain = threadcrypto.open_sealed(body["sealed"], self.key)
            payload = json.loads(plain) if plain else None
            self.answer = self.mac(payload)
            if self.pending_polls > 0:
                self.pending_polls -= 1
                return httpx.Response(200, json={"live": True, "callId": self.call_id, "done": False,
                                                 "mac_live": self.mac_live})
            return httpx.Response(200, json={"live": True, "callId": self.call_id, "done": True,
                                             "result": self.answer})
        assert request.method == "GET" and request.url.path.endswith("/" + self.call_id)
        if self.pending_polls > 0:
            self.pending_polls -= 1
            return httpx.Response(200, json={"live": True, "callId": self.call_id, "done": False,
                                             "mac_live": self.mac_live})
        return httpx.Response(200, json={"live": True, "callId": self.call_id, "done": True,
                                         "result": self.answer})


def with_edge(edge):
    """Point the plugin's HTTP at the fake for the length of a call."""
    class _Use:
        def __enter__(self):
            self.previous = maccall.TRANSPORT
            maccall.TRANSPORT = edge.transport()
            return edge

        def __exit__(self, *_exc):
            maccall.TRANSPORT = self.previous

    return _Use()


# ---------------------------------------------------------------------------
# The machine's half

class LiveMac(unittest.TestCase):
    def test_a_live_mac_answers_in_the_turn_and_nothing_is_queued(self):
        with Enrolled(CATALOGUE) as m:
            edge = FakeEdge(m.key)
            with with_edge(edge):
                answer = m.call("reminders_pull")
            self.assertEqual(m.intents(), [], "an answered call must not also be queued")
        self.assertTrue(answer["success"], answer)
        self.assertNotIn("deferred", answer)
        self.assertEqual(answer["ran_on"], "mac")
        self.assertIn("ok: from the Mac", answer["result"])
        # One begin, and it was answered in that request.
        self.assertEqual([r.method for r in edge.requests], ["POST"])
        self.assertEqual(edge.requests[0].url.path, "/v1/relay/mac/call")

    def test_the_persons_words_cross_only_inside_the_seal(self):
        with Enrolled(CATALOGUE) as m:
            edge = FakeEdge(m.key)
            with with_edge(edge):
                m.call("notes_create", title="Dentist", body="Tuesday at nine, ask about the crown")
        body = edge.body
        self.assertEqual((body["via"], body["target"], body["action"]),
                         ("connector", "notes", "create"))
        self.assertEqual(body["thread"], THREAD)
        raw = edge.requests[0].content.decode("utf-8")
        for word in ("Dentist", "Tuesday", "crown", "args", "stdin"):
            self.assertNotIn(word, raw)
        # And what the Mac opened is what the verb would have been given.
        opened = json.loads(threadcrypto.open_sealed(body["sealed"], m.key))
        self.assertEqual(opened["args"], [])
        self.assertEqual(json.loads(opened["stdin"]),
                         {"title": "Dentist", "body": "Tuesday at nine, ask about the crown"})

    def test_the_answer_is_wrapped_as_untrusted_like_a_local_pull(self):
        """The Mac's output is the person's data from a third party — a
        reminder someone else wrote — and gets the same framing a pull run
        here gets. A `create`'s answer is Moe's own sentence and does not."""
        with Enrolled(CATALOGUE) as m:
            with with_edge(FakeEdge(m.key)):
                pull = m.call("reminders_pull")
                create = m.call("notes_create", title="t")
        self.assertTrue(pull["result"].startswith(
            '<untrusted_tool_result source="reminders_pull"'), pull["result"][:80])
        self.assertIn("ok: from the Mac", pull["result"])
        self.assertEqual(create["result"], "ok: from the Mac")

    def test_a_pending_answer_is_polled_for_and_then_collected(self):
        with Enrolled(CATALOGUE) as m:
            edge = FakeEdge(m.key, pending_polls=2)
            with with_edge(edge):
                answer = m.call("reminders_pull")
            self.assertEqual(m.intents(), [])
        self.assertTrue(answer["success"], answer)
        self.assertEqual([r.method for r in edge.requests], ["POST", "GET", "GET"])
        self.assertEqual(edge.requests[1].url.path, "/v1/relay/mac/call/" + edge.call_id)

    def test_a_failure_on_the_mac_is_the_macs_own_sentence(self):
        def failing(payload):
            return {"state": "failed", "sealed": threadcrypto.seal(canonical_json(
                intents.result_payload(error="needs-setup: allow Moe access to Reminders",
                                       callId=payload["call"]["id"])),
                THREAD_KEY[0])}
        with Enrolled(CATALOGUE) as m:
            THREAD_KEY[0] = m.key
            with with_edge(FakeEdge(m.key, mac=failing)):
                answer = m.call("reminders_pull")
            self.assertEqual(m.intents(), [])
        self.assertFalse(answer["success"])
        self.assertIn("needs-setup", answer["error"])
        self.assertEqual(answer["ran_on"], "mac")


THREAD_KEY = [None]


class NoLiveMac(unittest.TestCase):
    def test_no_live_mac_is_todays_queue(self):
        with Enrolled(CATALOGUE) as m:
            edge = FakeEdge(m.key, live=False)
            with with_edge(edge):
                answer = m.call("reminders_pull")
            queued = m.intents()
        self.assertTrue(answer["success"])
        self.assertTrue(answer["deferred"])
        self.assertEqual(len(queued), 1)
        self.assertEqual([r.method for r in edge.requests], ["POST"])

    def test_with_nothing_to_ask_the_queue_is_used_and_no_http_is_attempted(self):
        for missing in ("edge", "token"):
            with self.subTest(missing=missing):
                kwargs = {missing: None}
                with Enrolled(CATALOGUE, **kwargs) as m:
                    edge = FakeEdge(m.key)
                    with with_edge(edge):
                        answer = m.call("reminders_pull")
                    self.assertEqual(len(m.intents()), 1)
                self.assertTrue(answer["deferred"])
                self.assertEqual(edge.requests, [])

    def test_a_mac_without_the_threads_key_yet_is_queued_for_when_it_has_it(self):
        with Enrolled(CATALOGUE) as m:
            edge = FakeEdge(m.key, mac=lambda _p: {"state": "no-key"})
            with with_edge(edge):
                answer = m.call("reminders_pull")
            self.assertEqual(len(m.intents()), 1)
        self.assertTrue(answer["deferred"])

    def test_a_mac_that_did_not_answer_in_time_is_not_then_queued_as_well(self):
        previous = maccall.DEADLINE_MARGIN_S, maccall.POLL_WAIT_S
        maccall.POLL_WAIT_S = 0.01
        try:
            with Enrolled(CATALOGUE) as m:
                edge = FakeEdge(m.key, pending_polls=10_000)
                with with_edge(edge):
                    answer = maccall.try_proxy(plugin, "reminders", "pull", [], None, "",
                                               "Reminders", deadline_s=0.05)
                self.assertEqual(m.intents(), [])
        finally:
            maccall.DEADLINE_MARGIN_S, maccall.POLL_WAIT_S = previous
        answer = json.loads(answer)
        self.assertFalse(answer["success"])
        self.assertIn("didn't answer", answer["error"])
        self.assertIn("nothing was queued", answer["error"].lower())

    def test_a_mac_that_left_the_wire_mid_call_is_given_up_on(self):
        previous = maccall.POLL_WAIT_S, maccall.MAC_GONE_GRACE_S
        maccall.POLL_WAIT_S = 0.01
        maccall.MAC_GONE_GRACE_S = 0.05
        try:
            with Enrolled(CATALOGUE) as m:
                edge = FakeEdge(m.key, pending_polls=10_000, mac_live=False)
                with with_edge(edge):
                    answer = maccall.try_proxy(plugin, "reminders", "pull", [], None, "",
                                               "Reminders", deadline_s=30)
                self.assertEqual(m.intents(), [])
        finally:
            maccall.POLL_WAIT_S, maccall.MAC_GONE_GRACE_S = previous
        answer = json.loads(answer)
        self.assertFalse(answer["success"])
        self.assertIn("went to sleep", answer["error"])
        self.assertLess(len(edge.requests), 100)

    def test_a_send_with_no_live_mac_is_refused_never_queued(self):
        """§14.4 rule 5. With the away gate on the machine, `imessage_send` is
        offered there; a live Mac asks the person on its own screen; no live
        Mac is a refusal, not a promise about somebody else's inbox."""
        with Enrolled(CATALOGUE) as m:
            tools = os.path.join(m.moe_home, "tools")
            os.makedirs(tools)
            for name in ("confirm.sh", "confirm-away.py"):
                path = os.path.join(tools, name)
                with open(path, "w") as handle:
                    handle.write("#!/bin/sh\nexit 0\n")
                os.chmod(path, 0o755)
            self.assertIn("imessage_send", m.tools())
            with with_edge(FakeEdge(m.key, live=False)):
                answer = m.call("imessage_send", to="+15550100", text="on my way")
            self.assertEqual(m.intents(), [])
        self.assertFalse(answer["success"])
        # Not "asleep": this machine cannot tell asleep from unreachable.
        self.assertIn("couldn't reach your Mac", answer["error"])
        self.assertNotIn("asleep", answer["error"])
        self.assertNotIn("deferred", answer)


class AbsentFirst(unittest.TestCase):
    """Review D6: a hand the Mac has said is `needs-setup` is answered "set it
    up on your Mac" — never tried live first, which handed back the Mac
    connector's own raw failure instead."""

    def test_a_needs_setup_hand_is_the_absent_sentence_and_no_live_call(self):
        with Enrolled(CATALOGUE) as m:
            m.publish_capability({"reminders": {
                "pull": "needs-setup", "why": "Moe has no access to Reminders on this Mac"}})
            edge = FakeEdge(m.key)
            with with_edge(edge):
                answer = m.call("reminders_pull")
            self.assertEqual(m.intents(), [])
        self.assertFalse(answer["success"])
        self.assertTrue(answer.get("absent"), answer)
        self.assertIn("no access to Reminders", answer["error"])
        self.assertNotIn("ran_on", answer)
        self.assertEqual(edge.requests, [], "an absent hand must not be tried live")


class MachineBinding(unittest.TestCase):
    """Review D2, the machine's end: the call is bound inside its seal, and
    an answer is accepted only for the call it was made for."""

    def test_the_seal_carries_the_frames_clear_fields_and_its_validity(self):
        with Enrolled(CATALOGUE) as m:
            edge = FakeEdge(m.key)
            before = time.time()
            with with_edge(edge):
                m.call("notes_create", title="t")
            bound = json.loads(threadcrypto.open_sealed(edge.body["sealed"], m.key))["call"]
        body = edge.body
        self.assertEqual({k: bound[k] for k in ("id", "thread", "via", "target", "action")},
                         {"id": body["callId"], "thread": body["thread"], "via": body["via"],
                          "target": body["target"], "action": body["action"]})
        self.assertGreaterEqual(bound["issued"], before - 1)
        self.assertLessEqual(bound["issued"], time.time() + 1)
        self.assertEqual(bound["deadline"], maccall.deadline_for(plugin, "create"))

    def test_an_answer_sealed_for_another_call_is_refused_not_believed(self):
        """The edge could hand back an older call's sealed "done" — it is
        under the same thread key — as this call's answer."""
        def someone_elses(_payload):
            return {"state": "done", "sealed": threadcrypto.seal(canonical_json(
                intents.result_payload(output="created, last week", callId="an-old-call")),
                THREAD_KEY[0])}
        with Enrolled(CATALOGUE) as m:
            THREAD_KEY[0] = m.key
            with with_edge(FakeEdge(m.key, mac=someone_elses)):
                answer = m.call("notes_create", title="t")
            self.assertEqual(m.intents(), [])
        self.assertFalse(answer["success"])
        self.assertNotIn("last week", json.dumps(answer))
        self.assertIn("couldn't read the answer", answer["error"])


# ---------------------------------------------------------------------------
# The Mac's half

def mac_frame(key, target, action, args=(), stdin="", asked="", call_id=None,
              via="connector", thread=THREAD, issued=None, deadline=60.0, bind=True):
    """A frame as the machine writes it: the clear fields, and the payload
    sealed with its binding to them (`maccall.BINDING`). A fresh callId per
    frame by default, because the Mac refuses one it has already taken."""
    call_id = call_id or uuid.uuid4().hex
    extra = {}
    if bind:
        extra[maccall.BINDING] = maccall.binding(
            call_id, thread, via, target, action,
            time.time() if issued is None else issued, deadline)
    payload = intents.intent_payload(args=list(args), stdin=stdin, asked=asked, **extra)
    return {"type": "mac_call", "callId": call_id, "thread": thread, "via": via,
            "target": target, "action": action,
            "sealed": threadcrypto.seal(canonical_json(payload), key)}


def opened(result, key):
    return json.loads(threadcrypto.open_sealed(result["sealed"], key))


class MacBinding(unittest.TestCase):
    """Review D2, the Mac's end. The edge never holds the key but carries the
    frame, so everything in the clear is the edge's to change: the Mac trusts
    the sealed copy, refuses a frame that disagrees with it, a call past its
    deadline, and a call it has already taken — each before anything runs."""

    def run_counted(self, frame, key=None):
        with mock.patch.object(plugin, "run_verb", wraps=plugin.run_verb) as run:
            result = maccall.answer_mac_call(plugin, frame)
        return result, run.call_count

    def test_a_clear_field_changed_on_the_wire_is_refused_and_nothing_runs(self):
        with Machine(CATALOGUE, runs_in=None) as m:
            for field, value in (("action", "create"), ("target", "reminders"),
                                 ("callId", "another-call")):
                with self.subTest(field=field):
                    frame = mac_frame(m.key, "notes", "pull")
                    frame[field] = value
                    result, runs = self.run_counted(frame)
                    self.assertEqual(result["state"], "refused", result)
                    self.assertIn(field, result["why"])
                    self.assertEqual(runs, 0)

    def test_a_replayed_call_is_refused_and_runs_once(self):
        with Machine(CATALOGUE, runs_in=None) as m:
            frame = mac_frame(m.key, "notes", "create", stdin='{"title": "t"}')
            first, runs_first = self.run_counted(dict(frame))
            again, runs_again = self.run_counted(dict(frame))
        self.assertEqual(first["state"], "done")
        self.assertEqual(runs_first, 1)
        self.assertEqual(again["state"], "refused", again)
        self.assertIn("already taken", again["why"])
        self.assertEqual(runs_again, 0)

    def test_a_call_past_its_deadline_is_refused_and_nothing_runs(self):
        with Machine(CATALOGUE, runs_in=None) as m:
            stale = mac_frame(m.key, "notes", "pull", issued=time.time() - 120, deadline=60)
            result, runs = self.run_counted(stale)
        self.assertEqual(result["state"], "refused", result)
        self.assertIn("deadline", result["why"])
        self.assertEqual(runs, 0)

    def test_a_call_from_the_future_is_refused(self):
        with Machine(CATALOGUE, runs_in=None) as m:
            ahead = mac_frame(m.key, "notes", "pull", issued=time.time() + 3600)
            result, runs = self.run_counted(ahead)
        self.assertEqual(result["state"], "refused", result)
        self.assertEqual(runs, 0)

    def test_a_call_with_no_sealed_binding_is_refused(self):
        with Machine(CATALOGUE, runs_in=None) as m:
            result, runs = self.run_counted(mac_frame(m.key, "notes", "pull", bind=False))
        self.assertEqual(result["state"], "refused", result)
        self.assertEqual(runs, 0)

    def test_the_answer_seals_the_call_it_answers(self):
        with Machine(CATALOGUE, runs_in=None) as m:
            frame = mac_frame(m.key, "reminders", "pull")
            result = maccall.answer_mac_call(plugin, frame)
            self.assertEqual(opened(result, m.key)["callId"], frame["callId"])

    def test_the_seen_set_is_bounded_and_forgets_the_expired_first(self):
        seen = maccall.SeenCalls(limit=2)
        now = 1000.0
        self.assertTrue(seen.claim("a", now - 1, now - 10))
        self.assertTrue(seen.claim("b", now + 60, now))
        self.assertFalse(seen.claim("b", now + 60, now))
        # "a" has expired: it goes first, and "b" is still refused.
        self.assertTrue(seen.claim("c", now + 60, now))
        self.assertFalse(seen.claim("b", now + 60, now))
        # Full of live ids: the oldest is forgotten early, not the newest.
        self.assertTrue(seen.claim("d", now + 60, now))
        self.assertFalse(seen.claim("c", now + 60, now))
        self.assertFalse(seen.claim("d", now + 60, now))


class OnTheMac(unittest.TestCase):
    def test_the_verb_runs_and_the_answer_opens_under_the_thread_key(self):
        with Machine(CATALOGUE, runs_in=None) as m:
            result = maccall.answer_mac_call(plugin, mac_frame(m.key, "reminders", "pull",
                                                               args=["--days", "3"]))
            self.assertEqual(result["state"], "done")
            body = opened(result, m.key)
        self.assertIn("verb=pull args=--days,3", body["output"])
        self.assertEqual(body["error"], "")
        self.assertGreaterEqual(body["seconds"], 0)

    def test_stdin_reaches_a_verb_that_declares_it_and_no_other(self):
        with Machine(CATALOGUE, runs_in=None) as m:
            create = maccall.answer_mac_call(
                plugin, mac_frame(m.key, "notes", "create", stdin='{"title": "t"}'))
            pull = maccall.answer_mac_call(
                plugin, mac_frame(m.key, "notes", "pull", stdin='{"title": "t"}'))
            self.assertIn('stdin={"title": "t"}', opened(create, m.key)["output"])
            self.assertIn("stdin=", opened(pull, m.key)["output"])
            self.assertNotIn("title", opened(pull, m.key)["output"])

    def test_a_key_this_mac_does_not_hold_says_so_and_runs_nothing(self):
        with Machine(CATALOGUE, runs_in=None, key=False) as m:
            result = maccall.answer_mac_call(plugin, mac_frame(os.urandom(32), "reminders", "pull"))
        self.assertEqual(result, {"state": "no-key"})

    def test_a_seal_that_will_not_open_is_unreadable_not_a_run(self):
        with Machine(CATALOGUE, runs_in=None) as m:
            frame = mac_frame(os.urandom(32), "reminders", "pull")
            result = maccall.answer_mac_call(plugin, frame)
        self.assertEqual(result["state"], "unreadable")

    def test_a_connector_or_verb_this_mac_does_not_have_is_a_failure_sentence(self):
        with Machine(CATALOGUE, runs_in=None) as m:
            missing = maccall.answer_mac_call(plugin, mac_frame(m.key, "solaris", "pull"))
            no_verb = maccall.answer_mac_call(plugin, mac_frame(m.key, "reminders", "create"))
            self.assertEqual(missing["state"], "failed")
            self.assertIn("solaris", opened(missing, m.key)["error"])
            self.assertEqual(no_verb["state"], "failed")
            self.assertIn("create", opened(no_verb, m.key)["error"])

    def test_a_via_this_plugin_does_not_own_is_refused(self):
        with Machine(CATALOGUE, runs_in=None) as m:
            result = maccall.answer_mac_call(plugin, mac_frame(m.key, "x", "y", via="mcp"))
        self.assertEqual(result["state"], "refused")
        self.assertIn("mcp", result["why"])

    def test_a_frame_missing_its_fields_is_refused(self):
        with Machine(CATALOGUE, runs_in=None) as m:
            frame = mac_frame(m.key, "reminders", "pull")
            del frame["sealed"]
            self.assertEqual(maccall.answer_mac_call(plugin, frame)["state"], "refused")

    def test_the_receiver_installs_on_the_transport_and_answers_with_the_call_id(self):
        class FakeTransport:
            _FRAME_HANDLERS = {"descriptor": None}

            def __init__(self):
                self.sent = []

            async def _send(self, frame):
                self.sent.append(frame)

        self.assertTrue(maccall.install_receiver(plugin, transport_class=FakeTransport))
        self.assertIn("mac_call", FakeTransport._FRAME_HANDLERS)
        # Idempotent: a second install is the same handler, not a second one.
        handler = FakeTransport._FRAME_HANDLERS["mac_call"]
        self.assertTrue(maccall.install_receiver(plugin, transport_class=FakeTransport))
        self.assertIs(FakeTransport._FRAME_HANDLERS["mac_call"], handler)

        with Machine(CATALOGUE, runs_in=None) as m:
            transport = FakeTransport()

            async def drive():
                await handler(transport, mac_frame(m.key, "reminders", "pull", call_id="c-77"))
                # The handler returns before the verb has run — the read loop
                # must not wait on a connector — so give the task time.
                for _ in range(200):
                    if transport.sent:
                        break
                    await asyncio.sleep(0.05)

            asyncio.run(drive())
            self.assertEqual(len(transport.sent), 1)
            frame = transport.sent[0]
            self.assertEqual(frame["type"], "mac_call_result")
            self.assertEqual(frame["callId"], "c-77")
            self.assertEqual(frame["result"]["state"], "done")
            self.assertIn("verb=pull", opened(frame["result"], m.key)["output"])

    def test_install_without_the_transport_class_is_a_no_and_says_why(self):
        with self.assertLogs("moe-connectors", level="INFO") as log:
            self.assertFalse(maccall.install_receiver(plugin, transport_class=None,
                                                      importer=lambda: None))
        self.assertTrue(any("relay transport" in line for line in log.output), log.output)


if __name__ == "__main__":
    unittest.main()
