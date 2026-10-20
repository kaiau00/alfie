"""Composio triggers (slice 7; owner decisions 2026-09-28): the Mac turns
pushes on only for a paid tenant's granted, connected toolkits that cannot be
read on a clock, choosing trigger types that need no setup; the away machine
collects the events the edge sealed to it, opens them, and reads them with
the one generic shape reader.

Falsifiers: let a trigger needing configuration through, turn triggers on for
a toolkit that has a read plan or on a free tenant, keep them after a revoke,
ack an event before the engine kept it, or take another toolkit's event —
each turns a test red. Runs under Hermes's venv for the sealing test
(`cryptography`); the rest need only the stdlib.
"""
import base64
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.normpath(os.path.join(HERE, "..", "..", "lib"))
LEDGER = os.path.normpath(os.path.join(HERE, "..", "..", "hermes-plugins", "moe-ledger"))
sys.path.insert(0, LIB)


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(LIB, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


TYPES = [
    {"slug": "X_DIRECT_MESSAGE_RECEIVED", "name": "DM", "description": "a direct message", "type": "webhook",
     "required": []},
    {"slug": "X_CHANNEL_MESSAGE_RECEIVED", "name": "Msg", "description": "a channel message", "type": "webhook",
     "required": []},
    {"slug": "X_COMMIT_EVENT", "name": "Commit", "description": "a commit", "type": "webhook",
     "required": ["owner", "repo"]},
]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["MOE_HOME"] = self.tmp
        os.makedirs(os.path.join(self.tmp, "gather"))
        os.makedirs(os.path.join(self.tmp, "cloud"))
        for m in ("composio_items", "composio_triggers"):
            sys.modules.pop(m, None)
        self.t = load("composio_triggers")
        self.ci = sys.modules["composio_items"]
        self.calls = []

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def paid(self, tier="away"):
        with open(os.path.join(self.tmp, "cloud", "credential.json"), "w") as f:
            json.dump({"tenant": "t-1"}, f)
        with open(os.path.join(self.tmp, "cloud", "tier.json"), "w") as f:
            json.dump({"tier": tier}, f)

    def plan(self, slug, plan):
        self.ci._save(self.ci.plan_path(slug), plan)

    def composio(self, status=200):
        def call(method, path, body=None):
            self.calls.append((method, path, body))
            if path.startswith("/api/v3/triggers_types"):
                return 200, {"items": [{"slug": t["slug"], "name": t["name"], "description": t["description"],
                                        "type": t["type"], "config": {"required": t["required"]}}
                                       for t in TYPES]}
            if "/upsert" in path:
                return status, {"trigger_id": "ti_" + path.split("/")[4]}
            if method == "DELETE":
                return 200, {}
            return 404, {}
        return call

    def model(self, picks):
        return lambda messages: json.dumps({"triggers": picks})


class ChooseTest(Base):
    def test_only_setup_free_known_types_at_most_three(self):
        picks = [{"slug": "X_COMMIT_EVENT", "addressed": True},
                 {"slug": "X_DIRECT_MESSAGE_RECEIVED", "addressed": True},
                 {"slug": "X_MADE_UP", "addressed": True},
                 {"slug": "X_CHANNEL_MESSAGE_RECEIVED", "addressed": "yes"}]
        got = self.t.choose("x", [dict(t) for t in TYPES], self.model(picks))
        self.assertEqual(got, [{"slug": "X_DIRECT_MESSAGE_RECEIVED", "addressed": True},
                               {"slug": "X_CHANNEL_MESSAGE_RECEIVED", "addressed": False}])


class EnsureTest(Base):
    def test_a_paid_unreadable_toolkit_gets_its_triggers_and_the_subscription(self):
        self.paid()
        self.plan("x", {"tool": None, "why": "no lister", "v": 3})
        edge = []
        r = self.t.ensure("x", model_call=self.model([{"slug": "X_DIRECT_MESSAGE_RECEIVED", "addressed": True}]),
                          composio_call=self.composio(), edge_call=lambda m, p, b=None: (edge.append(p), (200, {}))[1],
                          user_id="t-1", now=1000)
        self.assertEqual(r["on"], ["X_DIRECT_MESSAGE_RECEIVED"])
        self.assertEqual(edge, ["/v1/composio/triggers/enable"])
        upsert = [c for c in self.calls if "/upsert" in c[1]][0]
        self.assertEqual(upsert[2], {"user_id": "t-1", "trigger_config": {}})
        held = self.ci.load_plan("x")["triggers"]
        self.assertEqual([t["slug"] for t in held["on"]], ["X_DIRECT_MESSAGE_RECEIVED"])
        self.assertTrue(held["on"][0]["addressed"])
        # Decided: not asked again.
        r = self.t.ensure("x", model_call=self.model([]), composio_call=self.composio(), user_id="t-1", now=2000)
        self.assertEqual(r["skip"], "already decided")

    def test_readable_or_free_is_left_alone(self):
        self.plan("gmail", {"tool": "GMAIL_FETCH_EMAILS", "args": {}, "v": 3})
        self.assertEqual(self.t.ensure("gmail", model_call=self.model([]), composio_call=self.composio())["skip"],
                         "read on a clock")
        self.plan("x", {"tool": None, "v": 3})
        self.assertEqual(self.t.ensure("x", model_call=self.model([]), composio_call=self.composio())["skip"],
                         "free tier")
        self.assertEqual([c for c in self.calls if "/upsert" in c[1]], [])

    def test_no_subscription_means_no_triggers_left_behind(self):
        self.paid()
        self.plan("x", {"tool": None, "v": 3})
        r = self.t.ensure("x", model_call=self.model([{"slug": "X_DIRECT_MESSAGE_RECEIVED", "addressed": True}]),
                          composio_call=self.composio(), edge_call=lambda m, p, b=None: (503, {}),
                          user_id="t-1", now=1000)
        self.assertEqual(r["on"], [])
        self.assertTrue(any(c[0] == "DELETE" for c in self.calls))

    def test_retire_deletes_them(self):
        self.plan("x", {"tool": None, "triggers": {"v": 1, "at": 1, "on": [
            {"slug": "X_DIRECT_MESSAGE_RECEIVED", "id": "ti_1", "addressed": True}]}})
        self.assertEqual(self.t.retire("x", composio_call=self.composio()), ["X_DIRECT_MESSAGE_RECEIVED"])
        self.assertEqual(self.ci.load_plan("x")["triggers"]["on"], [])


class EventsTest(Base):
    def setUp(self):
        super().setUp()
        sys.modules.pop("composio_events", None)
        self.e = load("composio_events")
        self.plan("x", {"tool": None, "triggers": {"v": 1, "at": 1, "on": [
            {"slug": "X_DIRECT_MESSAGE_RECEIVED", "id": "ti_1", "addressed": True}]}})

    def edge(self, events, status=200):
        log = []

        def call(method, path, body=None):
            log.append((method, path, body))
            if path == "/v1/composio/events":
                return status, {"events": events, "capped": False}
            return 200, {}
        return call, log

    def test_own_events_read_others_left_and_acked_only_next_look(self):
        # Another toolkit with live triggers: its events are left for its reader.
        self.plan("y", {"tool": None, "triggers": {"v": 1, "at": 1, "on": [{"slug": "Y_OTHER_TOOLKIT", "id": "ti_2"}]}})
        events = [{"id": 1, "messageId": "msg_1"}, {"id": 2, "messageId": "msg_2"}, {"id": 3, "messageId": "msg_3"},
                  {"id": 4, "messageId": "msg_4"}]
        opened = {
            1: {"id": "msg_1", "trigger_slug": "X_DIRECT_MESSAGE_RECEIVED", "timestamp": "2026-09-28T10:00:00Z",
                "data": {"id": "m1", "ts": "1790589600", "user": "U2", "channel": "D1",
                         "text": "Can you send the $300 deposit today?"}},
            2: {"id": "msg_2", "trigger_slug": "Y_OTHER_TOOLKIT", "data": {"text": "not ours"}},
            4: {"id": "msg_4", "trigger_slug": "Z_NO_LONGER_ANYWHERE", "data": {"text": "orphan"}},
        }

        def opener(ev):
            if ev["id"] == 3:
                raise ValueError("InvalidTag")
            return opened[ev["id"]]
        call, log = self.edge(events)
        items, cursor = self.e.items("x", "", edge=call, opener=opener, now=1_790_600_000)
        self.assertEqual([i["text"] for i in items], ["Can you send the $300 deposit today?"])
        self.assertTrue(items[0]["to_me"])
        self.assertEqual(items[0]["id"], "X_DIRECT_MESSAGE_RECEIVED/m1")
        # Ours and the unreadable one are cleared; the other toolkit's (2) and
        # one no plan here names yet (4: its plan may still be on its way from
        # the Mac) are left — the edge clears them after 24 h.
        self.assertEqual(sorted(json.loads(cursor)["ack"]), [1, 3])
        self.assertFalse(any(p == "/v1/composio/events/ack" for _, p, _ in log))
        call, log = self.edge([])
        self.e.items("x", cursor, edge=call, opener=opener)
        self.assertEqual(log[0][:2], ("POST", "/v1/composio/events/ack"))

    def test_a_failed_collect_moves_nothing(self):
        call, _ = self.edge([], status=503)
        with self.assertRaises(RuntimeError):
            self.e.items("x", "", edge=call, opener=lambda ev: None)

    def test_an_event_sealed_the_edges_way_opens_here(self):
        try:
            from cryptography.hazmat.primitives import hashes
            from cryptography.hazmat.primitives.asymmetric import x25519
            from cryptography.hazmat.primitives.ciphers.aead import AESGCM
            from cryptography.hazmat.primitives.kdf.hkdf import HKDF
        except ImportError:
            self.skipTest("cryptography is not installed (run under Hermes's venv)")
        sys.path.insert(0, LEDGER)
        try:
            from moeledger.identity import DeviceIdentity
            from moeledger.inbound import hkdf_info
        except ImportError:
            self.skipTest("moeledger needs Hermes's venv (httpx)")
        me = DeviceIdentity.from_raw("cloud-abc", os.urandom(32), os.urandom(32))
        payload = json.dumps({"id": "msg_9", "trigger_slug": "X_DIRECT_MESSAGE_RECEIVED",
                              "data": {"id": "m9", "ts": "1790589600", "text": "Lunch Tuesday?"}}).encode()
        eph = x25519.X25519PrivateKey.generate()
        eph_pub = eph.public_key().public_bytes_raw()
        shared = eph.exchange(me.agreement.public_key())
        key = HKDF(algorithm=hashes.SHA256(), length=32, salt=me.agreement_public_raw + eph_pub,
                   info=hkdf_info("composio", "msg_9", "cloud-abc")).derive(shared)
        nonce = os.urandom(12)
        sealed = nonce + AESGCM(key).encrypt(nonce, payload, None)
        ev = {"id": 9, "messageId": "msg_9", "ciphertext": base64.b64encode(sealed).decode(),
              "ephemeralPublic": base64.b64encode(eph_pub).decode(),
              "scheme": "x25519-hkdf-sha256.aes-gcm-256.inbound.v1"}
        call, _ = self.edge([ev])
        items, _ = self.e.items("x", "", edge=call, opener=lambda e: self.e._open(e, me), now=1_790_600_000)
        self.assertEqual([i["text"] for i in items], ["Lunch Tuesday?"])


class MaintainTest(Base):
    def test_revoked_or_unpaid_toolkits_lose_their_triggers(self):
        sys.modules.pop("situations", None)
        s = load("situations")
        os.environ["MOE_RUNS_IN"] = "mac"
        try:
            self.plan("x", {"tool": None, "triggers": {"v": 1, "at": 1, "on": [{"slug": "S", "id": "ti"}]}})
            self.plan("y", {"tool": None})
            s._granted = lambda: {"y"}
            s.composio_connected = lambda: {"x", "y"}
            s.consented = lambda src: True
            s._DEADLINE[0] = float("inf")
            retired, ensured = [], []
            s.maintain_triggers(1000, ensure=lambda slug: ensured.append(slug) or {"slug": slug},
                                retire=lambda slug: retired.append(slug) or ["S"], tier_fn=lambda: "away",
                                check_edge=lambda: None)
            self.assertEqual((retired, ensured), (["x"], ["y"]))
            retired, ensured = [], []
            self.plan("y", {"tool": None, "triggers": {"v": 1, "at": 1, "on": [{"slug": "S", "id": "t2"}]}})
            s.maintain_triggers(1000, ensure=lambda slug: ensured.append(slug) or {},
                                retire=lambda slug: retired.append(slug) or [], tier_fn=lambda: "free",
                                check_edge=lambda: None)
            self.assertEqual(sorted(retired), ["x", "y"])
            self.assertEqual(ensured, [])
        finally:
            os.environ.pop("MOE_RUNS_IN", None)



class ReviewFixesTest(Base):
    """Security review 2026-09-28: the records of live triggers survive a
    replan; a failed delete is kept; paging reaches past others' events."""

    def test_a_replan_keeps_the_triggers_record(self):
        self.plan("x", {"tool": None, "why": "no lister", "at": 0, "v": 2,
                        "triggers": {"v": 1, "at": 1, "on": [{"slug": "S", "id": "ti_live"}]}})
        self.ci.ensure_plan("x", tools_fn=lambda s: [], call=lambda m: "", now=10 ** 10)
        self.assertEqual(self.ci.load_plan("x")["triggers"]["on"][0]["id"], "ti_live")

    def test_a_trigger_that_would_not_delete_is_kept(self):
        self.plan("x", {"tool": None, "triggers": {"v": 1, "at": 1, "on": [
            {"slug": "A", "id": "ti_a"}, {"slug": "B", "id": ""}]}})

        def call(method, path, body=None):
            return (500, {}) if path.endswith("ti_a") else (200, {})
        self.assertEqual(self.t.retire("x", composio_call=call), [])
        self.assertEqual([t["slug"] for t in self.ci.load_plan("x")["triggers"]["on"]], ["A", "B"])

    def test_no_identity_is_decided_for_a_week_without_spending(self):
        self.paid()
        self.plan("x", {"tool": None, "v": 3})
        self.t._composio = lambda: type("C", (), {"user_id": staticmethod(lambda c: (_ for _ in ()).throw(
            RuntimeError("NoIdentity")))})()
        spent = []
        r = self.t.ensure("x", model_call=lambda m: spent.append(m), composio_call=lambda *a, **k: spent.append(a),
                          now=1000)
        self.assertEqual((r["on"], spent), ([], []))
        self.assertEqual(self.t.ensure("x", model_call=lambda m: spent.append(m), now=2000)["skip"],
                         "already decided")

    def test_paging_reaches_this_toolkits_events(self):
        sys.modules.pop("composio_events", None)
        e = load("composio_events")
        self.plan("x", {"tool": None, "triggers": {"v": 1, "at": 1, "on": [{"slug": "X_DM", "id": "t1", "addressed": True}]}})
        self.plan("y", {"tool": None, "triggers": {"v": 1, "at": 1, "on": [{"slug": "Y_DM", "id": "t2"}]}})
        pages = {0: [{"id": i, "messageId": "m%d" % i} for i in range(1, 201)],
                 200: [{"id": 201, "messageId": "m201"}], 201: []}

        def edge(method, path, body=None):
            after = int(path.split("after=")[1]) if "after=" in path else 0
            evs = pages.get(after, [])
            return 200, {"events": evs, "next": evs[-1]["id"] if evs else after}

        def opener(ev):
            if ev["id"] == 201:
                return {"id": "m201", "trigger_slug": "X_DM",
                        "data": {"id": "d1", "ts": "1790589600", "text": "Are we still on for Friday?"}}
            return {"id": ev["messageId"], "trigger_slug": "Y_DM", "data": {"text": "theirs"}}
        got, cur = e.items("x", "", edge=edge, opener=opener, now=1_790_600_000)
        self.assertEqual([i["text"] for i in got], ["Are we still on for Friday?"])
        self.assertEqual(json.loads(cur)["ack"], [201])

    def test_a_large_backlog_is_acked_in_batches_the_edge_takes(self):
        """Final review: 1,200 waiting events made a 1,200-id ack the edge
        refused (MAX_ACK 500), and the reader stopped for good."""
        sys.modules.pop("composio_events", None)
        e = load("composio_events")
        self.plan("x", {"tool": None, "triggers": {"v": 1, "at": 1, "on": [{"slug": "X_DM", "id": "t1"}]}})
        backlog = [{"id": i, "messageId": "m%d" % i} for i in range(1, 1201)]
        acked = []

        def edge(method, path, body=None):
            if path == "/v1/composio/events/ack":
                if len(body["ids"]) > 500:
                    return 400, {}
                acked.extend(body["ids"])
                return 200, {}
            after = int(path.split("after=")[1]) if "after=" in path else 0
            page = [x for x in backlog if x["id"] > after and x["id"] not in acked][:200]
            return 200, {"events": page, "next": page[-1]["id"] if page else None}

        def opener(ev):
            return {"id": ev["messageId"], "trigger_slug": "X_DM",
                    "data": {"id": ev["messageId"], "ts": "1790589600", "text": "hello %d" % ev["id"]}}
        cursor, seen = "", 0
        for _ in range(5):
            got, cursor = e.items("x", cursor, edge=edge, opener=opener, now=1_790_600_000)
            seen += len(got)
            self.assertLessEqual(len(json.loads(cursor)["ack"]), 500)
        self.assertEqual(seen, 1200)
        self.assertEqual(len(set(acked)), 1200)

if __name__ == "__main__":
    unittest.main()
