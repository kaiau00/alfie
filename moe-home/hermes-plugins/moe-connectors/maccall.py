"""A Mac-only connector, called on the machine, carried out on the Mac now.

CHANNELS-CONNECTORS-DECISIONS §5: *live proxy over the relay when the Mac is
awake; queue-and-drain when it is not, person told so.* Until this file the
machine had only the second half: a `runs_in=mac` connector is **detached**
there (LEDGER-WIRE §14), and calling it appended an `intent` the Mac's
five-minute drain carried out later — so "what's on my Reminders today",
asked from the phone with the Mac awake two rooms away, was answered "I'll do
it when your Mac wakes" about a Mac that was not asleep.

Two halves, one file, because they are the two ends of one wire and the
seal has to be the same on both.

The machine's half — `try_proxy`
--------------------------------

Runs inside the tool handler, before `queue_intent`. It seals the call under
the conversation's **thread key** — the same key an intent is sealed under,
held by both devices and by nothing at the edge — and asks the edge to put
it to the tenant's live Mac: `POST /v1/relay/mac/call`, then
`GET /v1/relay/mac/call/{id}` until the Mac has answered. The edge forwards a
`mac_call` frame over the relay socket the Mac's gateway already holds and
hands the Mac's `mac_call_result` back verbatim; it reads nothing.

**`None` means "queue it"**, and it is said only when queueing is the right
next thing: no live Mac, nothing to ask with (no edge, no token, no shared
thread), the edge unreachable, or a Mac that does not hold this thread's key
yet (the intent, sealed under the same key, will open once it does). A Mac
that WAS awake and did not answer in time is **not** then queued as well —
a note created twice is worse than a note created late — and the sentence
says so.

The wait is polled, not held: one request is under a minute, because that
is the idle timeout the proxies between a Fly app and the world apply, and a
verb that asks the person (a `send` is confirmed on the Mac's own screen)
can take the best part of the Mac's timeout for it. The deadline is the
Mac's own per-verb timeout plus a margin — a backstop must be looser than
what it backs — and never `verb_timeout()`, which on the away machine means
the away gate's hour and says nothing about what the Mac will do.

The Mac's half — `answer_mac_call`, `install_receiver`
-------------------------------------------------------

The relay socket on a Mac is held by the Hermes gateway's
`WebSocketRelayTransport`, not by Memoe.app, and that transport dispatches
frames through a class-level table, `_FRAME_HANDLERS`. `install_receiver`
adds one row to it at plugin load — a Moe plugin, not a fork edit — and the
row's handler hands the frame to a thread and returns, so the read loop is
never behind a connector.

`answer_mac_call` opens the frame under the thread key, finds the connector
in the same manifests the Mac's own brain reads, and runs the verb through
**this plugin's own `run_verb`** — the function the drain uses and the
function the Mac's brain uses, so the subprocess, the scrubbed environment,
the per-verb timeout and every gate in front of a `send` are exactly what
they would be had the person asked the Mac. Never through the model: this is
a verb call, not a turn. The output is sealed back under the same key.

Wherever a sentence is written here it is Moe's own words about its own
machinery; the person's data — the arguments in, the output back — crosses
the edge only inside a seal.
"""

import asyncio
import collections
import json
import logging
import threading
import time
import uuid

import httpx

logger = logging.getLogger("moe-connectors")

#: The frame pair, spelled once on this side. The "Mac calls" section of
#: the edge's relay is the other end.
FRAME = "mac_call"
RESULT_FRAME = "mac_call_result"
CALL_PATH = "/v1/relay/mac/call"

#: How long one poll asks the edge to hold. Under the edge's own cap
#: (`MAC_CALL_WAIT_MAX_S`, 50) and under the minute the proxies in between
#: are known to cut a quiet response at.
POLL_WAIT_S = 45.0
#: Over the Mac's per-verb timeout: the connector is killed there at that
#: mark, so an answer — the timeout's own sentence — is on its way by then.
DEADLINE_MARGIN_S = 30.0
#: How long the Mac may be off the wire before the call is given up on. The
#: fork re-dials a second after any close; a lid closing does not re-dial.
MAC_GONE_GRACE_S = 20.0
#: TCP connect to the edge. The wait is on the poll, not the connect.
HTTP_CONNECT_S = 10.0
#: The sealed answer has to fit inside one relay frame (256 KiB) with the
#: frame's clear fields and base64 beside it.
OUTPUT_MAX_BYTES = 150_000

#: Tests point this at an `httpx.MockTransport`; production leaves it None.
TRANSPORT = None

#: The key inside the sealed payload that binds it to its frame. The seal
#: (`threadcrypto.seal`, AES-GCM with no associated data) proves only that
#: its CONTENTS came from a holder of the thread key; the frame's clear
#: `via`, `target`, `action`, `thread` and `callId` travel beside it, and the
#: edge — which never has the key — could otherwise rewrite them: turn a
#: sealed `notes pull` into `notes create` with the same arguments, or write
#: the same sealed call to the Mac twice. So the machine seals a copy of all
#: five, and when it was issued and for how long it stands, and the Mac
#: refuses a frame whose clear fields disagree with the sealed copy.
#: Binding by copy rather than by AAD, because `threadcrypto` is the wire
#: every other sealed field of the protocol uses and it takes no AAD.
BINDING = "call"
#: A call issued further in the future than this, by the Mac's clock, is
#: refused. A clock-skew allowance, not a validity window: the past side
#: is the call's own sealed deadline.
CLOCK_SKEW_S = 120.0
#: The longest deadline a Mac honours. The edge forgets a call after its
#: `MAC_CALL_TTL_S` (3900), so no caller can be waiting past it.
MAX_DEADLINE_S = 3900.0
#: How many callIds a Mac remembers to refuse a replay. A call is refused as
#: stale once its deadline passes, so an id need be remembered only until
#: then; the edge keeps at most sixteen pending per tenant, so this is
#: hundreds of deadlines' worth.
SEEN_MAX = 1024

# The three states the Mac answers with in the clear, because each is a
# fact about the wire rather than about the person's data: it could not
# find the key, the seal would not open, or this is not work it does.
NO_KEY = "no-key"
UNREADABLE = "unreadable"
REFUSED = "refused"
DONE = "done"
FAILED = "failed"

STALE = "this call was issued %d seconds ago and its deadline was %d seconds"
FUTURE = "this call says it was issued %d seconds from now"
REPLAYED = "this Mac has already taken call %s"
TAMPERED = ("the call's %s on the wire is not the %s it was sealed with — "
            "something between the two devices changed it")
UNBOUND = "this call carries no sealed binding to its frame"

TIMED_OUT = ("Your Mac was awake but didn't answer about your %s within %d seconds. "
             "Nothing was queued, so nothing will happen twice — ask me again.")
MAC_GONE = ("Your Mac went to sleep while it was looking at your %s, and I can't "
            "tell whether it finished. Nothing was queued, so nothing will happen "
            "twice — ask me again when it's awake.")
MAC_REFUSED = "Your Mac wouldn't take this: %s"
MAC_UNREADABLE = ("Your Mac couldn't read this call — it has a different key for this "
                  "conversation than I do. Nothing ran and nothing was queued.")
MAC_ANSWER_UNREADABLE = ("Your Mac answered, but I couldn't read the answer. "
                         "Nothing was queued — ask me again.")


# ---------------------------------------------------------------------------
# The machine's half


def _lib(plugin):
    """`moeledger`, through the plugin's own sibling loader, or None."""
    try:
        return plugin._moeledger()
    except Exception:  # noqa: BLE001 - a broken sibling is "cannot proxy"
        return None


def conversation(plugin):
    """`(vault, identity, thread, key)` for the conversation this tool call is
    inside, or None when any of the four is missing.

    The same four `queue_intent` needs, read the same way — the session
    `moe-ledger` filed under the gateway's session key, the thread it chose
    for it, the key in the keyring — and read only. Nothing here mints a
    thread or a key: a conversation the two devices do not share yet has
    nowhere to file an intent and nowhere to send a call.
    """
    if _lib(plugin) is None:
        return None
    try:
        from moeledger.vault import Vault
    except Exception:  # noqa: BLE001
        return None
    try:
        vault = Vault(plugin.vault_root())
        identity = vault.identity(create=False)
    except Exception:  # noqa: BLE001
        logger.info("moe-connectors: could not open the vault at %s; no live call",
                    plugin.vault_root(), exc_info=True)
        return None
    if identity is None:
        return None
    key_name = plugin.session_key()
    try:
        thread = vault.session_state(key_name).get("thread") if key_name else None
    except Exception:  # noqa: BLE001
        thread = None
    if not isinstance(thread, str) or not thread:
        return None
    try:
        key = vault.key(thread)
    except Exception:  # noqa: BLE001
        key = None
    if key is None:
        return None
    return vault, identity, thread, key


def _edge(plugin, vault):
    """`(url, bearer)` this device dials the edge with, or None."""
    try:
        from moeledger.client import check_edge_url
    except Exception:  # noqa: BLE001
        return None
    url = vault.edge_url()
    token = vault.token()
    if not url or token is None:
        return None
    try:
        return check_edge_url(url), token.text
    except Exception as exc:  # noqa: BLE001 - an unacceptable URL is "cannot proxy"
        logger.info("moe-connectors: the edge URL will not do for a live call: %s", exc)
        return None


def _client(url, bearer, wait_s):
    return httpx.Client(base_url=url, transport=TRANSPORT,
                        headers={"Authorization": "Bearer " + bearer},
                        timeout=httpx.Timeout(wait_s + 15.0, connect=HTTP_CONNECT_S))


def deadline_for(plugin, verb):
    """What the Mac will do, plus a margin: its own per-verb subprocess
    timeout (`TIMEOUT_SECONDS`), not this machine's `verb_timeout()`, which
    on the away machine is the away gate's hour and is about a dialog the
    Mac never opens."""
    return float(plugin.TIMEOUT_SECONDS.get(verb, plugin.DEFAULT_TIMEOUT)) + DEADLINE_MARGIN_S


def _failure(label, sentence):
    return json.dumps({"success": False, "error": sentence, "ran_on": "mac"})


def try_proxy(plugin, name, verb, args, stdin_text, asked, label, deadline_s=None):
    """Carry one detached call out on the live Mac. A tool-result JSON
    string, or None — which means *queue it*, and is said only when queueing
    is the right next thing (see the module header)."""
    ctx = conversation(plugin)
    if ctx is None:
        return None
    vault, _identity, thread, key = ctx
    edge = _edge(plugin, vault)
    if edge is None:
        return None
    url, bearer = edge

    from moeledger import intents, threadcrypto
    from moeledger.records import canonical_json

    what = "%s %s" % (name, verb)
    call_id = uuid.uuid4().hex
    deadline = deadline_for(plugin, verb) if deadline_s is None else float(deadline_s)
    payload = intents.intent_payload(
        args=args, stdin=stdin_text or "", asked=asked or "",
        **{BINDING: binding(call_id, thread, plugin.VIA_CONNECTOR, name, verb,
                            time.time(), deadline)})
    sealed = threadcrypto.seal(canonical_json(payload), key)
    started = time.monotonic()

    def remaining():
        return deadline - (time.monotonic() - started)

    body = {"callId": call_id, "thread": thread, "via": plugin.VIA_CONNECTOR,
            "target": name, "action": verb, "sealed": sealed,
            "wait_s": max(0.0, min(POLL_WAIT_S, remaining()))}
    try:
        with _client(url, bearer, POLL_WAIT_S) as http:
            answer = _begin(http, body)
            if answer is None:
                return None
            gone_since = None
            while not answer.get("done"):
                if remaining() <= 0:
                    logger.info("moe-connectors: %s: the Mac did not answer call %s in %ds",
                                what, call_id, deadline)
                    return _failure(label, TIMED_OUT % (label, int(deadline)))
                if answer.get("mac_live") is False:
                    gone_since = gone_since or time.monotonic()
                    if time.monotonic() - gone_since > MAC_GONE_GRACE_S:
                        logger.info("moe-connectors: %s: the Mac left the wire during call %s",
                                    what, call_id)
                        return _failure(label, MAC_GONE % label)
                    # The edge answers at once for a Mac that is not there;
                    # give a re-dial a moment rather than spinning on it.
                    time.sleep(min(1.0, POLL_WAIT_S))
                else:
                    gone_since = None
                answer = _poll(http, call_id, max(0.0, min(POLL_WAIT_S, remaining())))
                if answer is None:
                    return _failure(label, TIMED_OUT % (label, int(deadline)))
    except httpx.HTTPError as exc:
        logger.info("moe-connectors: %s: the edge could not be reached for a live call "
                    "(%s); queueing instead", what, type(exc).__name__)
        return None

    return _read_answer(plugin, name, verb, label, key, answer.get("result"), what, call_id)


def binding(call_id, thread, via, target, action, issued, deadline):
    """The sealed copy of a frame's clear fields, and its validity: see
    `BINDING`."""
    return {"id": call_id, "thread": thread, "via": via, "target": target,
            "action": action, "issued": float(issued), "deadline": float(deadline)}


def _begin(http, body):
    """The first request. `None` when this call is to be queued instead:
    no live Mac, or an edge that refused the call (a revoked device, a full
    pending list) — none of which improves by waiting here."""
    response = http.post(CALL_PATH, json=body)
    if response.status_code != 200:
        logger.info("moe-connectors: the edge refused a live call (%d %s); queueing instead",
                    response.status_code, response.text[:200])
        return None
    answer = response.json()
    if not isinstance(answer, dict) or not answer.get("live"):
        return None
    return answer


def _poll(http, call_id, wait_s):
    response = http.get("%s/%s" % (CALL_PATH, call_id), params={"wait_s": wait_s})
    if response.status_code != 200:
        # The call is gone from the edge — collected, or past its TTL. Either
        # way there is no answer to wait for.
        logger.info("moe-connectors: the edge lost call %s (%d)", call_id, response.status_code)
        return None
    answer = response.json()
    return answer if isinstance(answer, dict) else None


def _read_answer(plugin, name, verb, label, key, result, what, call_id=None):
    """The Mac's result object, opened. `None` — queue it — only for a Mac
    that does not hold the key yet."""
    from moeledger import threadcrypto

    state = result.get("state") if isinstance(result, dict) else None
    if state == NO_KEY:
        logger.info("moe-connectors: %s: the Mac does not hold this thread's key yet; "
                    "queueing for when it does", what)
        return None
    if state == REFUSED:
        return _failure(label, MAC_REFUSED % (result.get("why") or "no reason given"))
    if state == UNREADABLE:
        return _failure(label, MAC_UNREADABLE)
    if state not in (DONE, FAILED):
        return _failure(label, MAC_ANSWER_UNREADABLE)
    opened = threadcrypto.open_sealed(result.get("sealed"), key)
    try:
        body = json.loads(opened) if opened is not None else None
    except ValueError:
        body = None
    if not isinstance(body, dict):
        return _failure(label, MAC_ANSWER_UNREADABLE)
    if call_id is not None and body.get("callId") != call_id:
        # The answer is sealed under the same thread key as every other call
        # in this conversation, so without this the edge could hand back an
        # older call's sealed "done" — a note created last week — as this
        # call's answer. The Mac seals the callId it answered inside it.
        logger.warning("moe-connectors: %s: the Mac's answer names call %r, not %s; "
                       "refused", what, body.get("callId"), call_id)
        return _failure(label, MAC_ANSWER_UNREADABLE)
    logger.info("moe-connectors: %s ran on the Mac (%s, %.1fs)", what, state,
                float(body.get("seconds") or 0))
    if state == FAILED:
        return _failure(label, str(body.get("error") or "the connector failed on your Mac"))
    text = str(body.get("output") or "")
    # The same framing a pull run HERE gets: the output is the person's data
    # and much of it is somebody else's words.
    if verb in plugin.UNTRUSTED_VERBS:
        text = plugin.wrap_untrusted(plugin.tool_name(name, verb), text)
    return json.dumps({"success": True, "result": text, "ran_on": "mac"})


# ---------------------------------------------------------------------------
# The Mac's half


def _refused(why):
    return {"state": REFUSED, "why": why}


class SeenCalls:
    """The callIds this Mac has taken, each until its deadline passes —
    after which the call is refused as stale anyway. Bounded: past
    `SEEN_MAX` the expired go first and then the oldest. Thread-safe,
    because every call is answered on a thread of its own."""

    def __init__(self, limit=SEEN_MAX):
        self.limit = limit
        self._until = collections.OrderedDict()
        self._lock = threading.Lock()

    def claim(self, call_id, until, now):
        """True the first time `call_id` is claimed; False for a replay."""
        with self._lock:
            if call_id in self._until:
                return False
            for old in [k for k, v in self._until.items() if v < now]:
                del self._until[old]
            while len(self._until) >= self.limit:
                dropped, _ = self._until.popitem(last=False)
                logger.warning("moe-connectors: %d live call ids remembered; forgetting %s "
                               "early", self.limit, dropped)
            self._until[call_id] = until
            return True


SEEN = SeenCalls()


def check_binding(frame, payload, now):
    """None when the sealed binding matches the frame and the call is still
    current; otherwise the reason it is refused."""
    bound = payload.get(BINDING)
    if not isinstance(bound, dict):
        return UNBOUND
    for clear, sealed_as in (("callId", "id"), ("thread", "thread"), ("via", "via"),
                             ("target", "target"), ("action", "action")):
        if frame.get(clear) != bound.get(sealed_as):
            return TAMPERED % (clear, clear)
    issued, deadline = bound.get("issued"), bound.get("deadline")
    if not all(isinstance(v, (int, float)) and not isinstance(v, bool)
               for v in (issued, deadline)) or not 0 < deadline <= MAX_DEADLINE_S:
        return UNBOUND
    if issued > now + CLOCK_SKEW_S:
        return FUTURE % int(issued - now)
    if now - issued > deadline:
        return STALE % (int(now - issued), int(deadline))
    return None


def answer_mac_call(plugin, frame):
    """One `mac_call` frame → the result object the Mac sends back. Sync,
    and blocking for as long as the verb takes: the caller puts it on a
    thread."""
    lib = _lib(plugin)
    if lib is None:
        return _refused("this Mac has no ledger library, so it cannot open the call")
    from moeledger import intents, threadcrypto
    from moeledger.records import canonical_json
    from moeledger.vault import Vault

    if not isinstance(frame, dict):
        return _refused("a mac_call is an object")
    for field in ("callId", "thread", "via", "target", "action", "sealed"):
        if not isinstance(frame.get(field), str) or not frame[field]:
            return _refused("a mac_call carries %s" % field)
    if frame["via"] != plugin.VIA_CONNECTOR:
        return _refused("this Mac's connectors plugin carries out via=%s, not via=%s"
                        % (plugin.VIA_CONNECTOR, frame["via"]))
    target, action = frame["target"], frame["action"]

    try:
        key = Vault(plugin.vault_root()).key(frame["thread"])
    except Exception:  # noqa: BLE001
        logger.info("moe-connectors: could not read the keyring for a mac_call", exc_info=True)
        key = None
    if key is None:
        return {"state": NO_KEY}
    opened = threadcrypto.open_sealed(frame["sealed"], key)
    try:
        payload = json.loads(opened) if opened is not None else None
    except ValueError:
        payload = None
    if not isinstance(payload, dict):
        return {"state": UNREADABLE}

    # The clear fields are the edge's to rewrite and the seal is not, so the
    # sealed copy is the call and the frame must agree with it; and a call is
    # taken once, while it is current. Both before anything runs.
    now = time.time()
    why = check_binding(frame, payload, now)
    if why is not None:
        logger.warning("moe-connectors: refused mac_call %s: %s", frame["callId"], why)
        return _refused(why)
    bound = payload[BINDING]
    if not SEEN.claim(frame["callId"], bound["issued"] + bound["deadline"], now):
        logger.warning("moe-connectors: refused a replay of mac_call %s", frame["callId"])
        return _refused(REPLAYED % frame["callId"])

    def sealed(state, output="", error="", seconds=0.0):
        body = intents.result_payload(output=_bounded(output), error=error, seconds=seconds,
                                      callId=frame["callId"])
        return {"state": state, "sealed": threadcrypto.seal(canonical_json(body), key)}

    # The same three questions the drain's `ConnectorExecutor.missing` asks,
    # and the same answers: these are transient absences on this Mac and
    # the sentences name the thing to fix.
    if plugin.connector_script(target) is None:
        return sealed(FAILED, error="the %s connector's script is not on this Mac right now"
                      % target)
    entry = next((e for e in plugin.read_manifests() if e.get("name") == target), None)
    if entry is None:
        return sealed(FAILED, error="the %s connector declares no verbs on this Mac right now"
                      % target)
    if action not in (entry.get("verbs") or []):
        return sealed(FAILED, error="the %s connector does not declare a `%s` verb right now"
                      % (target, action))
    kind, _fields = (entry.get("inputs") or {}).get(action, (None, []))
    args = [str(a) for a in (payload.get("args") or [])]
    stdin_text = str(payload.get("stdin") or "") if kind == "stdin" else None

    logger.info("moe-connectors: running %s %s for the machine (call %s)", target, action,
                frame.get("callId", "?"))
    started = time.time()
    text, failed = plugin.run_verb(target, action, args, stdin_text)
    seconds = time.time() - started
    if failed:
        return sealed(FAILED, error=text, seconds=seconds)
    return sealed(DONE, output=text, seconds=seconds)


def _bounded(text):
    raw = text.encode("utf-8", "ignore")
    if len(raw) <= OUTPUT_MAX_BYTES:
        return text
    cut = raw[:OUTPUT_MAX_BYTES].decode("utf-8", "ignore")
    return cut + "\n\n[cut here — the answer was too long to carry back in one piece.]"


_MISSING = object()


def _default_importer():
    from gateway.relay.ws_transport import WebSocketRelayTransport
    return WebSocketRelayTransport


def install_receiver(plugin, *, transport_class=_MISSING, importer=None):
    """Add the `mac_call` row to the relay transport's frame table. True when
    it is there (already, or now); False, with the reason in the log, when
    there is no transport to add it to — in which case the queue still
    drains and nothing else changes."""
    if transport_class is _MISSING:
        try:
            transport_class = (importer or _default_importer)()
        except Exception as exc:  # noqa: BLE001 - not in a gateway, or an older fork
            transport_class = None
            logger.info("moe-connectors: no relay transport to receive live Mac calls on "
                        "(%s); the intent queue still drains", exc)
    if transport_class is None:
        logger.info("moe-connectors: no relay transport to receive live Mac calls on; "
                    "the intent queue still drains")
        return False
    table = getattr(transport_class, "_FRAME_HANDLERS", None)
    if not isinstance(table, dict):
        logger.info("moe-connectors: this relay transport has no frame table to add "
                    "mac_call to; the intent queue still drains")
        return False
    existing = table.get(FRAME)
    if existing is not None and getattr(existing, "_moe_mac_call", False):
        return True

    async def on_mac_call(transport, frame):
        # The read loop must not wait on a connector: hand off and return.
        asyncio.get_running_loop().create_task(_serve(plugin, transport, frame))

    on_mac_call._moe_mac_call = True
    table[FRAME] = on_mac_call
    logger.info("moe-connectors: receiving live Mac calls on the relay socket")
    return True


async def _serve(plugin, transport, frame):
    call_id = frame.get("callId") if isinstance(frame, dict) else None
    try:
        result = await asyncio.to_thread(answer_mac_call, plugin, frame)
    except Exception:  # noqa: BLE001 - the answer is a frame, never a dead reader
        logger.warning("moe-connectors: a mac_call could not be carried out", exc_info=True)
        result = _refused("this Mac could not carry the call out; its log says why")
    try:
        await transport._send({"type": RESULT_FRAME, "callId": call_id, "result": result})
    except Exception:  # noqa: BLE001
        logger.warning("moe-connectors: could not send the answer to mac_call %s", call_id,
                       exc_info=True)
