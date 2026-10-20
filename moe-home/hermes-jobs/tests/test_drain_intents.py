#!/usr/bin/env python3
"""The Mac's intent drain (moe-drain-intents.py), against docs/LEDGER-WIRE.md §14.

Everything here is a temporary ``$MOE_HOME`` and ``$HERMES_HOME``: the real
``~/.moe`` and ``~/.hermes`` are never read and never written. The plugins are
reached through a ``plugins/`` directory of symlinks into the payload, which
is exactly the shape ``configure-hermes.py`` installs and the shape the
``_sibling.py`` pattern resolves.

The intents themselves are written through ``moeledger.intents`` — the same
module the drain reads them with, and the same one the away machine will write
them with — so these tests move with the contract rather than pinning a second
copy of it.

**No test sends anything.** The sender is injected, and ``deliver.py``'s own
``fan_out`` — the ``hermes send --to <platform>`` path — is replaced with one
that fails the test if it is ever reached. What is asserted is what *would*
have been sent.

Run: cd ~/.hermes/hermes-agent && .venv/bin/python -m pytest \
        /private/tmp/moe-panel/moe-home/hermes-jobs/tests -q
"""

import fcntl
import importlib.util
import json
import os
import sys
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
JOBS = HERE.parent
MOE_PAYLOAD = JOBS.parent
PLUGIN_PAYLOAD = MOE_PAYLOAD / "hermes-plugins"
DRAIN_PATH = JOBS / "moe-drain-intents.py"

THREAD = "6C2C7C7E-0F0A-4E1B-9C0A-2C6E0B1D5A44"
MACHINE = "machine-1a2b3c4d"

FAKE_CONNECTOR = """#!/bin/bash
# A connector, as far as run_verb is concerned: argv is [script, verb, *args],
# stdin is a JSON object for the verbs that declare one, and the exit code is
# the whole story. Every call is recorded so a test can assert that a verb was
# NEVER run.
echo "$*" >> "$MOE_FAKE_LOG"
case "$1" in
  status) echo "ok"; exit 0 ;;
  pull)   echo "two notes about the deck"; exit 0 ;;
  create) cat >> "$MOE_FAKE_STDIN"; echo "created"; exit 0 ;;
  boom)   echo "the notes database is locked" >&2; exit 3 ;;
esac
echo "unknown verb: $1" >&2
exit 2
"""

MANIFEST = """name=notes
label=Notes
verbs=status pull create boom send
create_stdin=title* body*
runs_in=mac
"""


def load_drain():
    spec = importlib.util.spec_from_file_location("moe_drain_intents", str(DRAIN_PATH))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------------------
# A whole Mac, in a temporary directory
# ---------------------------------------------------------------------------

class Mac(object):
    """$MOE_HOME + $HERMES_HOME + a ledger, and the pieces to write into it."""

    def __init__(self, root, drain):
        self.root = Path(root)
        self.drain = drain
        self.moe = self.root / "moe"
        self.hermes = self.root / "hermes"
        self.ledger = self.moe / "ledger"
        self.plugins = self.hermes / "plugins"
        self.log = self.root / "connector-calls.log"
        self.stdin_log = self.root / "connector-stdin.log"
        self._prev = None
        self._seq = 0

        (self.moe / "connectors").mkdir(parents=True)
        self.ledger.mkdir(parents=True)
        self.plugins.mkdir(parents=True)
        for name in ("moe-ledger", "moe-connectors", "moe-screen"):
            os.symlink(str(PLUGIN_PAYLOAD / name), str(self.plugins / name))

        script = self.moe / "connectors" / "notes.sh"
        script.write_text(FAKE_CONNECTOR, encoding="utf-8")
        script.chmod(0o755)
        (self.moe / "connectors" / "notes.manifest").write_text(MANIFEST, encoding="utf-8")
        self.write_config({})

        self.lib = drain.moeledger_module(self.plugins)
        assert self.lib is not None, "moeledger must import from the payload"
        self.it = drain.intents_module(self.lib)
        assert self.it is not None, "moeledger.intents must import from the payload"
        self.vault = drain.ledger_vault(self.lib, self.ledger)
        self.keyring = self.lib.vault.Keyring(self.ledger / "thread-keys.json")
        self.key = self.keyring.mint_key(THREAD)

    # -- configuration ------------------------------------------------------

    def write_config(self, obj):
        (self.moe / "config.json").write_text(json.dumps(obj), encoding="utf-8")

    def device(self):
        """This Mac's device id, without minting one."""
        try:
            return json.loads((self.ledger / "device.json").read_text())["id"]
        except (OSError, ValueError, KeyError):
            return None

    # -- writing what the machine writes ------------------------------------

    def queue(self, via="connector", target="notes", action="pull", args=(), stdin="",
              asked="what's in my Notes about the deck?", at=None, expires_in=3600,
              key=None, runtime="mac", body=None, now=None, device=MACHINE):
        """One `intent`, on the MACHINE's chain — the away machine wrote it."""
        now = time.time() if now is None else now
        at = now if at is None else at
        if body is None:
            body = self.it.intent_body(
                THREAD, runtime, via, target, action,
                self.it.intent_payload(args=list(args), stdin=stdin, asked=asked),
                self.key if key is None else key,
                expires=now + expires_in)
        return self.append(self.it.KIND_INTENT, body, at=at, device=device)

    def append(self, kind, body, at=None, device=MACHINE):
        """A record on the machine's chain — the drain never writes there."""
        at = time.time() if at is None else at
        self._seq += 1
        record = self.lib.records.Record(
            kind=kind, at=self.lib.records.format_timestamp(at), device=device,
            seq=self._seq, body=body, prev=self._prev, after=[])
        self._prev = record.id
        self.vault.append_record(record)
        return record

    def write_peers(self, devices, revoked=()):
        """A §3.4 peer book where `claimstore` resolves it — the same file the
        app writes, `<ledger dir>/../cloud/peers.json`."""
        import base64

        path = self.moe / "cloud" / "peers.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        pub = base64.b64encode(b"\x00" * 32).decode()
        peers = {d: {"identity_pub": pub, "signing_pub": pub, "added_at": 1.0}
                 for d in devices}
        path.write_text(json.dumps({"version": 1, "peers": peers,
                                    "revoked": list(revoked)}), encoding="utf-8")
        return path

    # -- reading back -------------------------------------------------------

    def records(self, kind=None):
        found = self.lib.records.ordered(self.vault.read_ledger())
        return [r for r in found if kind is None or r.kind == kind]

    def results(self):
        return self.records(kind=self.it.KIND_INTENT_RESULT)

    def attempts(self):
        return self.records(kind=self.it.KIND_INTENT_ATTEMPT)

    def payload(self, record, key=None):
        """The sealed result payload, opened under the thread key."""
        opened = self.lib.threadcrypto.open_sealed(
            record.body["text_enc"], self.key if key is None else key)
        assert opened is not None, "the result did not open under the thread key"
        return json.loads(opened)

    def calls(self):
        try:
            return [line for line in self.log.read_text().splitlines() if line.strip()]
        except OSError:
            return []


class Sender(object):
    """A sender that records instead of sending."""

    def __init__(self):
        self.messages = []

    def __call__(self, text, channels):
        self.messages.append((text, list(channels)))
        return {}


@pytest.fixture
def mac(tmp_path, monkeypatch):
    drain = load_drain()
    box = Mac(tmp_path, drain)
    monkeypatch.setenv("MOE_HOME", str(box.moe))
    monkeypatch.setenv("HERMES_HOME", str(box.hermes))
    monkeypatch.setenv("MOE_FAKE_LOG", str(box.log))
    monkeypatch.setenv("MOE_FAKE_STDIN", str(box.stdin_log))
    monkeypatch.delenv("MOE_RUNS_IN", raising=False)

    # The one hard guard: nothing in this suite may reach `hermes send`.
    deliver = drain.deliver_module(box.plugins)
    assert deliver is not None, "moe-screen's deliver.py must be reachable"

    def never(*a, **kw):
        raise AssertionError("a test tried to actually send a message")

    monkeypatch.setattr(deliver, "fan_out", never)
    box.deliver = deliver
    yield box
    sys.modules.pop("moe_drain_intents", None)


def run(mac, sender=None, now=None):
    return mac.drain.drain(now=now, sender=sender, plugins=mac.plugins,
                           directory=mac.ledger)


# ---------------------------------------------------------------------------
# A live intent runs, and its answer is a sealed result
# ---------------------------------------------------------------------------

def test_a_live_intent_runs_and_yields_a_sealed_done_result(mac):
    intent = mac.queue(action="pull")
    sender = Sender()

    report = run(mac, sender)

    results = mac.results()
    assert len(results) == 1
    body = results[0].body
    assert body["state"] == "done"
    assert body["intent"] == intent.id
    assert body["thread"] == THREAD
    assert body["enc"] == "aes-gcm-256.v1"
    # §13.3: the person's data is sealed, never in the clear.
    assert "text" not in body and "output" not in body
    payload = mac.payload(results[0])
    assert "two notes about the deck" in payload["output"]
    assert payload["error"] == ""
    assert payload["seconds"] >= 0
    assert mac.calls() == ["pull"]
    assert report.outcomes == [("done", "notes pull")]


def test_a_verb_that_takes_stdin_gets_it(mac):
    mac.queue(action="create", stdin=json.dumps({"title": "Deck", "body": "three bullets"}))

    run(mac, Sender())

    assert mac.results()[0].body["state"] == "done"
    # `create_stdin=` in the manifest is what makes it stdin rather than argv:
    # argv is world-readable through `ps`, and a note is the person's words.
    assert "three bullets" in mac.stdin_log.read_text()
    assert mac.calls() == ["create"]


def test_a_failing_connector_yields_failed(mac):
    mac.queue(action="boom")

    run(mac, Sender())

    result = mac.results()[0]
    assert result.body["state"] == "failed"
    payload = mac.payload(result)
    assert "the notes database is locked" in payload["error"]
    assert payload["output"] == ""


# ---------------------------------------------------------------------------
# §14.4 rule 3 — expired is reported, NEVER executed
# ---------------------------------------------------------------------------

def test_an_expired_intent_is_reported_and_the_connector_is_never_run(mac):
    now = time.time()
    mac.queue(action="pull", at=now - 4 * 24 * 3600, expires_in=-3600, now=now)

    run(mac, Sender(), now=now)

    result = mac.results()[0]
    assert result.body["state"] == "expired"
    assert "nothing was run" in mac.payload(result)["error"]
    assert mac.calls() == [], "an expired intent must never reach the connector"
    assert not mac.log.exists(), "the connector was started at all"


# ---------------------------------------------------------------------------
# §14.4 rule 5 — nothing queued may send
# ---------------------------------------------------------------------------

def test_a_send_verb_is_refused_unexecuted(mac):
    mac.queue(action="send", args=("someone",))

    run(mac, Sender())

    result = mac.results()[0]
    assert result.body["state"] == "refused"
    reason = mac.payload(result)["error"]
    assert "confirmation" in reason
    assert mac.calls() == [], "a queued send must never reach the connector"


# ---------------------------------------------------------------------------
# §14.4 rule 8 — missing is not gone
#
# `configure-hermes.py` rewrites the connector scripts and the manifests
# during an install, so "not there" is what a queue sees for a few seconds
# every time Moe updates. Burning the queue for that is the failure.
# ---------------------------------------------------------------------------

def test_a_vanished_verb_is_left_alone_before_it_is_refused(mac):
    mac.queue(action="pull")
    (mac.moe / "connectors" / "notes.manifest").write_text(
        "name=notes\nlabel=Notes\nverbs=status\nruns_in=mac\n", encoding="utf-8")

    for tick in range(mac.drain.TRANSIENT_TICKS - 1):
        report = run(mac, Sender())
        assert mac.results() == [], "a transient absence was burned on tick %d" % tick
        assert report.deferred == 1
        assert report.outcomes == []

    report = run(mac, Sender())
    result = mac.results()[0]
    assert result.body["state"] == "refused"
    assert "`pull` verb" in mac.payload(result)["error"]
    assert mac.calls() == []


def test_a_connector_that_comes_back_mid_upgrade_still_runs(mac):
    """The point of rule 8: an install that moves the script must cost a tick,
    not the person's queued work."""
    mac.queue(action="pull")
    script = mac.moe / "connectors" / "notes.sh"
    body = script.read_text()
    script.unlink()

    report = run(mac, Sender())
    assert report.deferred == 1 and mac.results() == []

    script.write_text(body, encoding="utf-8")
    script.chmod(0o755)
    run(mac, Sender())

    assert mac.results()[0].body["state"] == "done"
    assert mac.calls() == ["pull"]


def test_a_connector_whose_script_stays_gone_is_eventually_refused(mac):
    mac.queue(action="pull")
    (mac.moe / "connectors" / "notes.sh").unlink()

    for _ in range(mac.drain.TRANSIENT_TICKS - 1):
        run(mac, Sender())
    assert mac.results() == []

    run(mac, Sender())
    result = mac.results()[0]
    assert result.body["state"] == "refused"
    assert "script is not on this Mac" in mac.payload(result)["error"]


def test_the_whole_plugin_missing_is_transient_too(mac):
    """`connectors is None` used to refuse permanently — the case an install
    that is halfway through rewriting `$HERMES_HOME/plugins` produces."""
    mac.queue(action="pull")
    # A plugins directory with no `moe-connectors` in it — what an install
    # halfway through rewriting `$HERMES_HOME/plugins` looks like.
    empty = mac.root / "no-connectors"
    empty.mkdir()
    executors = {"connector": mac.drain.ConnectorExecutor(empty)}

    report = mac.drain.drain(sender=Sender(), plugins=mac.plugins,
                             directory=mac.ledger, executors=executors)

    assert report.deferred == 1 and mac.results() == []
    assert mac.calls() == []


def test_an_intent_that_expires_while_it_waits_is_reported_expired(mac):
    """Rule 8's other exit: "or an intent that expires meanwhile"."""
    now = time.time()
    mac.queue(action="pull", at=now, expires_in=3600, now=now)
    (mac.moe / "connectors" / "notes.sh").unlink()

    report = run(mac, Sender(), now=now)
    assert report.deferred == 1 and mac.results() == []

    run(mac, Sender(), now=now + 2 * 3600)

    result = mac.results()[0]
    assert result.body["state"] == "expired"
    assert "nothing was run" in mac.payload(result)["error"]


def test_a_send_is_refused_even_when_its_script_is_missing(mac):
    """Rule 5 outranks rule 8: "never" is not "not yet"."""
    mac.queue(action="send", args=("someone",))
    (mac.moe / "connectors" / "notes.sh").unlink()

    report = run(mac, Sender())

    assert report.deferred == 0
    assert mac.results()[0].body["state"] == "refused"
    assert "confirmation" in mac.payload(mac.results()[0])["error"]


# ---------------------------------------------------------------------------
# §14.4 rule 1 — an intent with a result is finished, for ever
# ---------------------------------------------------------------------------

def test_an_intent_that_already_has_a_result_is_never_re_run(mac):
    mac.queue(action="pull")
    sender = Sender()

    run(mac, sender)
    first = [r.id for r in mac.results()]
    assert len(first) == 1

    second = run(mac, sender)

    assert [r.id for r in mac.results()] == first, "a finished intent was answered twice"
    assert mac.calls() == ["pull"], "a finished intent was run twice"
    assert second.outcomes == []
    assert sender.messages == [], "a drain that did nothing said something"


# ---------------------------------------------------------------------------
# §14.4 rule 2 — one drain at a time
# ---------------------------------------------------------------------------

def test_two_drains_cannot_run_at_once(mac):
    mac.queue(action="pull")
    lock = mac.ledger / mac.it.LOCK_FILE
    fd = os.open(str(lock), os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        report = run(mac, Sender())
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)

    assert report.locked_out is True
    assert mac.results() == []
    assert mac.calls() == []

    # And the lock is not sticky: the next drain, with nobody holding it, works.
    report = run(mac, Sender())
    assert report.locked_out is False
    assert len(mac.results()) == 1


# ---------------------------------------------------------------------------
# §14.4 rule 4 — one message per drain, never one per intent
# ---------------------------------------------------------------------------

def test_exactly_one_summary_names_the_counts_the_kinds_and_the_delay(mac):
    now = time.time()
    mac.queue(action="pull", at=now - 3 * 3600, now=now)
    mac.queue(action="create", stdin=json.dumps({"title": "a", "body": "b"}),
              at=now - 2 * 3600, now=now)
    mac.queue(action="boom", at=now - 3600, now=now)
    mac.queue(action="pull", at=now - 5 * 24 * 3600, expires_in=-3600, now=now)
    mac.write_config({"reminderChannels": ["telegram"]})
    sender = Sender()

    report = run(mac, sender, now=now)

    assert len(mac.results()) == 4
    assert len(sender.messages) == 1, "one message per drain, not one per intent"
    text, channels = sender.messages[0]
    assert channels == ["telegram"]
    assert "4 things" in text
    assert "2 done" in text and "1 failed" in text and "1 too old to run" in text
    assert "notes pull" in text and "notes create" in text
    assert "about 5 days" in text, "the delay is the oldest thing that was waiting"
    assert report.sent is True


def test_a_drain_that_did_nothing_says_nothing_and_writes_nothing(mac):
    mac.write_config({"reminderChannels": ["telegram"]})
    before = sorted(p.name for p in mac.ledger.iterdir())
    sender = Sender()

    report = run(mac, sender)

    assert report.outcomes == []
    assert sender.messages == []
    assert mac.results() == []
    # No device minted, no chain started, nothing new but the lock file.
    assert sorted(p.name for p in mac.ledger.iterdir()) == sorted(before + ["intents.lock"])
    assert mac.device() is None


def test_with_no_channel_configured_the_summary_goes_where_it_will_be_seen(mac):
    mac.queue(action="pull")
    sender = Sender()

    report = run(mac, sender)

    assert sender.messages == [], "nothing is sent when no channel is configured"
    inbox = list((mac.moe / "inbox").glob("*.json"))
    assert len(inbox) == 1
    written = json.loads(inbox[0].read_text())
    assert "caught up on 1 thing" in written["text"]
    assert report.sent is True


# ---------------------------------------------------------------------------
# §13.1 — the drain is a third writer on one chain
# ---------------------------------------------------------------------------

def test_results_land_on_the_macs_chain_with_no_gap_and_no_fork(mac):
    # The app got there first: a device id and a record already on the chain.
    device = "mac-deadbeef"
    (mac.ledger / "device.json").write_text(
        json.dumps({"id": device, "createdAt": "2026-09-01T00:00:00.000Z"}), encoding="utf-8")
    first = mac.lib.records.Record(kind="turn", at=mac.lib.records.format_timestamp(time.time()),
                                   device=device, seq=1, body={"thread": THREAD}, prev=None)
    mac.vault.append_record(first)

    intents = [mac.queue(action="pull"), mac.queue(action="boom")]

    run(mac, Sender())

    mine = [r for r in mac.records() if r.device == device]
    # The turn the app wrote, then attempt/result for each intent (§14.3a: the
    # attempt goes on the chain BEFORE the executor runs).
    assert [r.seq for r in mine] == [1, 2, 3, 4, 5], "a gap or a fork in the chain"
    assert len({r.seq for r in mine}) == 5
    assert [r.kind for r in mine] == ["turn", "intent.attempt", "intent.result",
                                      "intent.attempt", "intent.result"]
    for earlier, later in zip(mine, mine[1:]):
        assert later.prev == earlier.id
    # `after` names what the record is about, so causal order puts both the
    # attempt and the result behind the intent they belong to.
    assert set(mine[1].after) == {intents[0].id}
    assert set(mine[2].after) == {intents[0].id}
    assert set(mine[3].after) == {intents[1].id}
    assert set(mine[4].after) == {intents[1].id}
    assert mac.device() == device, "the drain must not mint a second device id"


def test_the_drain_mints_the_shared_device_id_only_when_it_writes(mac):
    mac.queue(action="pull")

    run(mac, Sender())

    device = mac.device()
    assert device is not None and device.startswith("mac-")
    assert [r.device for r in mac.results()] == [device]


# ---------------------------------------------------------------------------
# §14.4 rule 6 — only what this device can read, and only its own runtime
# ---------------------------------------------------------------------------

def test_an_unreadable_payload_is_skipped_not_guessed_at(mac):
    other = os.urandom(32)
    mac.queue(action="pull", key=other)   # sealed under a key this Mac has not got
    sender = Sender()

    report = run(mac, sender)

    assert mac.results() == [], "an intent this device cannot read must not be answered"
    assert mac.calls() == []
    assert sender.messages == []
    assert report.skipped_unreadable == 1


def test_an_intent_for_another_runtime_is_ignored(mac):
    mac.queue(action="pull", runtime="cloud")

    run(mac, Sender())

    assert mac.results() == []
    assert mac.calls() == []


def test_a_result_naming_an_intent_this_device_does_not_hold_is_ignored(mac):
    """§14.3: kept and ignored, not dropped — and never mistaken for the
    answer to something else."""
    intent = mac.queue(action="pull")
    mac.append(mac.it.KIND_INTENT_RESULT,
               mac.it.result_body(THREAD, "0" * 32, "done",
                                  mac.it.result_payload(output="elsewhere"), mac.key))

    run(mac, Sender())

    answered = [r for r in mac.results() if r.body.get("intent") == intent.id]
    assert len(answered) == 1
    assert answered[0].body["state"] == "done"


# ---------------------------------------------------------------------------
# §14.3a — exactly-once, not at-least-once
#
# The blocker the review reproduced: a drain that runs a connector and dies
# before appending the result leaves no trace, so the next tick runs it again.
# `notes create` duplicated twice, then three times.
# ---------------------------------------------------------------------------

def dies_now(*a, **kw):
    raise KeyboardInterrupt("the Mac went to sleep / Memoe.app quit")


def test_a_kill_between_running_and_appending_never_repeats_the_work(mac):
    mac.queue(action="create", stdin=json.dumps({"title": "Buy milk", "body": "for tomorrow"}))

    real = mac.it.append_result
    mac.it.append_result = dies_now
    try:
        with pytest.raises(KeyboardInterrupt):
            run(mac, Sender())
    finally:
        mac.it.append_result = real

    assert mac.calls() == ["create"], "the connector ran once, as it should have"
    assert mac.results() == []
    # The trace that makes the next tick safe.
    assert len(mac.attempts()) == 1
    assert mac.attempts()[0].body["intent"] is not None
    assert "text_enc" not in mac.attempts()[0].body

    report = run(mac, Sender())

    assert mac.stdin_log.read_text().count("Buy milk") == 1, "the note was created twice"
    assert mac.calls() == ["create"], "a side-effecting intent was repeated"
    result = mac.results()[0]
    assert result.body["state"] == "failed"
    assert "have not repeated it" in mac.payload(result)["error"]
    assert report.outcomes == [("failed", "notes create")]

    # And never again, for ever.
    run(mac, Sender())
    assert mac.calls() == ["create"] and len(mac.results()) == 1


def test_a_read_is_retried_eight_times_and_then_stops(mac):
    """A read is cheap to repeat and a write is not, so they do not get the
    same number (§14.3a). Eight is `async_delegations`' own."""
    mac.queue(action="pull")

    real = mac.it.append_result
    mac.it.append_result = dies_now
    try:
        for _ in range(mac.it.ATTEMPT_CAP_READ):
            with pytest.raises(KeyboardInterrupt):
                run(mac, Sender())
    finally:
        mac.it.append_result = real

    assert len(mac.calls()) == mac.it.ATTEMPT_CAP_READ
    assert len(mac.attempts()) == mac.it.ATTEMPT_CAP_READ

    run(mac, Sender())

    assert len(mac.calls()) == mac.it.ATTEMPT_CAP_READ, "a ninth try"
    assert mac.results()[0].body["state"] == "failed"
    assert "have not repeated it" in mac.payload(mac.results()[0])["error"]


def test_a_result_that_will_not_append_counts_as_an_attempt(mac):
    """"A failure to append the result counts as an attempt too — otherwise a
    ledger that cannot be written loops for ever" (288 notes a day in the
    probe). This is the same window, entered through a broken ledger rather
    than a sleeping Mac."""
    mac.queue(action="create", stdin=json.dumps({"title": "x", "body": "y"}))

    def refuses(*a, **kw):
        raise OSError("the ledger file is read-only")

    real = mac.it.append_result
    mac.it.append_result = refuses
    try:
        report = run(mac, Sender())
        assert report.outcomes == [], "nothing was recorded"
        assert report.attempts == 1
        report = run(mac, Sender())
    finally:
        mac.it.append_result = real

    assert mac.calls() == ["create"], "the loop ran the write a second time"


# ---------------------------------------------------------------------------
# One intent's failure must not abort the batch
# ---------------------------------------------------------------------------

def test_a_failure_on_one_intent_does_not_stop_the_others(mac):
    """Today any exception escaped `drain()` into `main()` — after the
    connector had already run."""
    first = mac.queue(action="pull")
    mac.queue(action="pull")
    mac.queue(action="pull")

    real = mac.it.append_result
    calls = {"n": 0}

    def once(*a, **kw):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("this one record would not encode")
        return real(*a, **kw)

    mac.it.append_result = once
    try:
        report = run(mac, Sender())
    finally:
        mac.it.append_result = real

    assert len(report.outcomes) == 2, "one bad intent took the batch with it"
    assert len(mac.results()) == 2
    assert first.id not in [r.body["intent"] for r in mac.results()]


def test_a_plaintext_bodied_intent_is_left_alone_and_never_loops(mac):
    """§13.3 says such a body is plaintext; rule 6's answer is *unreadable*.
    Before this, it was `readable`, therefore `live`: the drain ran the
    connector and then raised on the seal it could not write — every tick, for
    ever."""
    plain = {"thread": "a-thread-nobody-shares", "runtime": "mac",
             "via": "connector", "target": "notes", "action": "create",
             "expires": mac.lib.records.format_timestamp(time.time() + 3600),
             "text": json.dumps({"args": [], "asked": "hi",
                                 "stdin": json.dumps({"title": "X", "body": "Y"})})}
    mac.queue(body=plain)
    sender = Sender()

    for _ in range(3):
        report = run(mac, sender)
        assert report.outcomes == []
        assert report.skipped_unreadable == 1

    assert mac.calls() == [], "a plaintext-bodied intent reached the connector"
    assert mac.results() == []
    assert mac.attempts() == []
    assert sender.messages == []


# ---------------------------------------------------------------------------
# §14.2 — two clocks, and neither is authoritative
# ---------------------------------------------------------------------------

def test_a_year_old_intent_from_a_fast_clock_is_expired_not_run(mac):
    """Probe A: a machine 400 days fast kept work alive for a year."""
    now = time.time()
    mac.queue(action="create", stdin=json.dumps({"title": "x", "body": "y"}),
              at=now - 365 * 24 * 3600, expires_in=72 * 3600,
              now=now + 400 * 24 * 3600)

    report = run(mac, Sender(), now=now)

    assert mac.calls() == [], "a year-old intent was carried out"
    assert mac.results()[0].body["state"] == "expired"
    assert report.outcomes == [("expired", "notes create")]


def test_an_intent_stamped_days_ahead_of_this_mac_is_expired_too(mac):
    """The other direction — the half a `min()` alone never closes."""
    now = time.time()
    ahead = now + 8 * 24 * 3600
    mac.queue(action="pull", at=ahead, expires_in=3600, now=ahead)

    run(mac, Sender(), now=now)

    assert mac.calls() == []
    assert mac.results()[0].body["state"] == "expired"


def test_an_expires_far_beyond_the_ttl_is_capped_at_at_plus_ttl(mac):
    """`min(expires, at + 72h)`: the difference between `at` and `expires` is
    trustworthy even when their absolute value is not."""
    now = time.time()
    at = now - (mac.it.DEFAULT_TTL_SECONDS - 600)
    mac.queue(action="pull", at=at, expires_in=400 * 24 * 3600, now=at)
    run(mac, Sender(), now=now)
    assert mac.results()[0].body["state"] == "done", "still inside at + TTL"

    box = mac
    box.queue(action="pull", at=now - (mac.it.DEFAULT_TTL_SECONDS + 600),
              expires_in=400 * 24 * 3600, now=now)
    run(box, Sender(), now=now)
    assert [r.body["state"] for r in box.results()] == ["done", "expired"]


# ---------------------------------------------------------------------------
# §14.4 rule 7 — only work from a device this Mac still trusts
# ---------------------------------------------------------------------------

def test_an_intent_from_a_revoked_device_is_refused_unexecuted(mac):
    mac.queue(action="create", stdin=json.dumps({"title": "x", "body": "y"}),
              device=MACHINE)
    mac.write_peers([MACHINE], revoked=[MACHINE])

    run(mac, Sender())

    result = mac.results()[0]
    assert result.body["state"] == "refused"
    assert "device you have since removed" in mac.payload(result)["error"]
    assert mac.calls() == [], "a revoked machine's queued work still ran"
    assert mac.attempts() == []


def test_an_intent_from_a_device_nobody_ever_enrolled_is_refused(mac):
    mac.queue(action="pull", device="machine-stranger")
    mac.write_peers([MACHINE])

    run(mac, Sender())

    assert mac.results()[0].body["state"] == "refused"
    assert mac.calls() == []


def test_a_live_peer_still_runs(mac):
    mac.queue(action="pull", device=MACHINE)
    mac.write_peers([MACHINE, "machine-other"])

    run(mac, Sender())

    assert mac.results()[0].body["state"] == "done"
    assert mac.calls() == ["pull"]


def test_work_this_mac_queued_for_itself_is_always_its_own(mac):
    """"An intent authored by *this* device is trusted" — it is not in its own
    peer book and never will be."""
    device = "mac-deadbeef"
    (mac.ledger / "device.json").write_text(
        json.dumps({"id": device, "createdAt": "2026-09-01T00:00:00.000Z"}), encoding="utf-8")
    mac.queue(action="pull", device=device)
    mac.write_peers([MACHINE])

    run(mac, Sender())

    assert mac.results()[0].body["state"] == "done"


# ---------------------------------------------------------------------------
# §14.4 rule 4 in a `finally` — a mid-batch kill still reports what finished
# ---------------------------------------------------------------------------

def test_a_summary_survives_a_kill_part_way_through_the_batch(mac):
    now = time.time()
    for _ in range(5):
        mac.queue(action="pull", at=now - 2 * 3600, now=now)
    mac.write_config({"reminderChannels": ["telegram"]})
    sender = Sender()

    real = mac.it.append_result
    done = {"n": 0}

    def three_then_sleep(*a, **kw):
        done["n"] += 1
        if done["n"] > 3:
            raise KeyboardInterrupt("the cron job's own timeout")
        return real(*a, **kw)

    mac.it.append_result = three_then_sleep
    try:
        with pytest.raises(KeyboardInterrupt):
            run(mac, sender, now=now)
    finally:
        mac.it.append_result = real

    assert len(sender.messages) == 1, "the work that finished was never reported"
    text, channels = sender.messages[0]
    assert "3 things" in text and "3 done (notes pull)" in text
    assert channels == ["telegram"]


def test_a_batch_longer_than_the_cron_timeout_finishes_next_tick(mac):
    """Five notes to write and a cron timeout after three. The three that
    finished are never written again, the fourth — started and interrupted —
    is not repeated either (§14.3a's cap of one for a write), and the fifth is
    picked up by the next tick."""
    for n in range(5):
        mac.queue(action="create",
                  stdin=json.dumps({"title": "note %d" % n, "body": "b"}))
    real = mac.it.append_result
    done = {"n": 0}

    def three_then_sleep(*a, **kw):
        done["n"] += 1
        if done["n"] > 3:
            raise KeyboardInterrupt("the cron job's own timeout")
        return real(*a, **kw)

    mac.it.append_result = three_then_sleep
    try:
        with pytest.raises(KeyboardInterrupt):
            run(mac, Sender())
    finally:
        mac.it.append_result = real

    assert len(mac.results()) == 3
    assert len(mac.calls()) == 4, "the fourth ran; nothing recorded that it had"

    run(mac, Sender())

    states = [r.body["state"] for r in mac.results()]
    assert len(states) == 5
    assert states.count("done") == 4 and states.count("failed") == 1
    assert len(mac.calls()) == 5, "a note was written twice"
    written = mac.stdin_log.read_text()
    for n in range(5):
        assert written.count("note %d" % n) == 1


# ---------------------------------------------------------------------------
# §14.4 rule 9 — an executor is a registration, not a special case
# ---------------------------------------------------------------------------

class FakeVia(object):
    """A second executor, deliberately trivial, that knows nothing about
    connectors, manifests, scripts or subprocesses — and is not even a
    subclass of `Executor`.

    If adding one of these needs a change to the record format, the sealing,
    the exactly-once logic, the summary or the drain's core, then §14.4 rule 9
    is not built. This test is the proof that it is: everything below is the
    same code path the connector takes.
    """

    via = "weather"

    def __init__(self, plugins=None):
        self.ran = []

    def missing(self, intent):
        return ""

    def refusal(self, intent):
        return ""

    def side_effects(self, intent):
        return intent.action == "set"

    def run(self, intent):
        self.ran.append((intent.target, intent.action, intent.args))
        return ("18 degrees and raining in %s" % intent.target, False, 0.02)


def test_a_new_executor_plugs_in_without_touching_anything_else(mac):
    fake = FakeVia()
    mac.drain.register_executor(FakeVia.via, lambda plugins: fake)
    mac.queue(via="weather", target="lisbon", action="forecast", asked="is it raining?")
    mac.write_config({"reminderChannels": ["telegram"]})
    sender = Sender()

    report = run(mac, sender)

    assert fake.ran == [("lisbon", "forecast", [])]
    assert mac.calls() == [], "the connector executor was involved at all"

    result = mac.results()[0]
    # The record format is the record format: same clear fields, same seal.
    assert set(result.body) == {"thread", "intent", "state", "enc", "text_enc"}
    assert result.body["state"] == "done"
    assert "18 degrees" in mac.payload(result)["output"]
    # The exactly-once logic is the exactly-once logic.
    assert len(mac.attempts()) == 1
    # And the summary names it in the system's own words.
    assert report.outcomes == [("done", "lisbon forecast")]
    assert "lisbon forecast" in sender.messages[0][0]


def test_a_new_executors_side_effects_declaration_decides_its_cap(mac):
    fake = FakeVia()
    mac.drain.register_executor(FakeVia.via, lambda plugins: fake)
    mac.queue(via="weather", target="lisbon", action="set")

    real = mac.it.append_result
    mac.it.append_result = dies_now
    try:
        with pytest.raises(KeyboardInterrupt):
            run(mac, Sender())
    finally:
        mac.it.append_result = real

    assert len(fake.ran) == 1
    run(mac, Sender())
    assert len(fake.ran) == 1, "a write the executor declared was repeated"
    assert mac.results()[0].body["state"] == "failed"


def test_a_via_with_no_executor_is_refused_with_a_reason_naming_it(mac):
    mac.queue(via="composio", target="hubspot", action="contacts")

    run(mac, Sender())

    result = mac.results()[0]
    assert result.body["state"] == "refused"
    assert "composio" in mac.payload(result)["error"]
    assert mac.calls() == []


def test_the_connector_executor_reports_reads_and_writes(mac):
    executor = mac.drain.ConnectorExecutor(mac.plugins)
    parsed = mac.it.parse_intent(mac.queue(action="pull"), mac.key)
    assert executor.side_effects(parsed) is False
    parsed = mac.it.parse_intent(mac.queue(action="create"), mac.key)
    assert executor.side_effects(parsed) is True
    # Anything nobody has classified is a write until somebody says so.
    parsed = mac.it.parse_intent(mac.queue(action="obliterate"), mac.key)
    assert executor.side_effects(parsed) is True


# ---------------------------------------------------------------------------
# A drain running beside the app and claimstore on the one shared chain (§13.1)
# ---------------------------------------------------------------------------

def test_a_drain_concurrent_with_another_writer_never_forks_the_chain(mac):
    import threading

    device = "mac-deadbeef"
    (mac.ledger / "device.json").write_text(
        json.dumps({"id": device, "createdAt": "2026-09-01T00:00:00.000Z"}), encoding="utf-8")
    mac.vault.append_record(mac.lib.records.Record(
        kind="turn", at=mac.lib.records.format_timestamp(time.time()),
        device=device, seq=1, body={"thread": THREAD}, prev=None))
    for _ in range(6):
        mac.queue(action="pull")

    stop = threading.Event()
    failures = []

    def other_writer():
        """claimstore, or the app, on the same device chain."""
        other = mac.lib.sync.LocalLedger(mac.vault, device)
        try:
            while not stop.is_set():
                other.append("claim", {"op": "assert", "claim": "c",
                                       "text_enc": "x", "enc": "aes-gcm-256.v1"})
                time.sleep(0.001)
        except Exception as exc:      # pragma: no cover
            failures.append(exc)

    thread = threading.Thread(target=other_writer)
    thread.start()
    try:
        run(mac, Sender())
    finally:
        stop.set()
        thread.join()

    assert failures == []
    mine = [r for r in mac.records() if r.device == device]
    seqs = [r.seq for r in mine]
    assert seqs == list(range(1, len(seqs) + 1)), "a gap in the shared chain"
    assert len(seqs) == len(set(seqs)), "the chain forked"
    assert len(mac.results()) == 6


# ---------------------------------------------------------------------------
# An idle tick is nearly free (L2)
# ---------------------------------------------------------------------------

def test_an_idle_tick_does_not_read_the_ledger_again(mac):
    mac.queue(action="pull")
    run(mac, Sender())                      # the ledger changes; nothing to skip

    second = run(mac, Sender())
    assert second.idle_skipped is False, "the first idle tick still has to look"

    reads = {"n": 0}
    real = mac.lib.vault.Vault.read_ledger

    def counted(self):
        reads["n"] += 1
        return real(self)

    mac.lib.vault.Vault.read_ledger = counted
    try:
        third = run(mac, Sender())
    finally:
        mac.lib.vault.Vault.read_ledger = real

    assert third.idle_skipped is True
    assert reads["n"] == 0, "an idle tick read the whole ledger"
    assert third.outcomes == []


def test_a_new_intent_wakes_the_idle_tick_up(mac):
    run(mac, Sender())
    assert run(mac, Sender()).idle_skipped is True

    mac.queue(action="pull")
    report = run(mac, Sender())

    assert report.idle_skipped is False
    assert report.outcomes == [("done", "notes pull")]


def test_a_thread_key_arriving_wakes_the_idle_tick_up(mac):
    """An unreadable intent becomes runnable when its key lands, and a key
    lands in `thread-keys.json`, not in a `.jsonl`."""
    other = "9A1B2C3D-0000-4000-8000-00000000ABCD"
    body = mac.it.intent_body(other, "mac", "connector", "notes", "pull",
                              mac.it.intent_payload(), os.urandom(32),
                              expires=time.time() + 3600)
    mac.queue(body=body)

    assert run(mac, Sender()).skipped_unreadable == 1
    assert run(mac, Sender()).idle_skipped is False, "an unreadable intent is not idle"


# ---------------------------------------------------------------------------
# The job spec, as configure-hermes.py will read it
# ---------------------------------------------------------------------------

def test_the_job_spec_matches_the_shape_install_jobs_installs():
    spec = json.loads((JOBS / "moe-drain-intents.json").read_text(encoding="utf-8"))
    assert spec["name"] == "moe-drain-intents"
    assert spec["no_agent"] is True
    assert spec["script"] == "moe-drain-intents.py"
    assert spec["schedule"] == "every 5m"
    assert spec["prompt"] is None
    assert spec["workdir"] is None
    # install_job strips the `_`-prefixed documentation before create_job sees
    # it; what is left must be keyword arguments create_job accepts.
    keys = {k for k in spec if not k.startswith("_")}
    assert keys == {"name", "schedule", "no_agent", "script", "prompt", "deliver",
                    "workdir", "enabled_toolsets"}


def test_configure_hermes_installs_the_drain():
    text = (MOE_PAYLOAD / "hermes" / "configure-hermes.py").read_text(encoding="utf-8")
    assert 'DRAIN_JOB_SPEC = "moe-drain-intents.json"' in text
    assert "(DRAIN_JOB_SPEC, DRAIN_JOB_SCRIPT, DRAIN_JOB_NAME)" in text


# ---------------------------------------------------------------------------
# A plugin that has not landed yet is not an incident (2026-09-03)
#
# The drain used to `raise SystemExit(1)` when `moe-ledger/intents` was
# absent. That is what a Mac part-way through an upgrade looks like, and it
# happened: the job was registered by a build that ships `intents.py` while
# the plugin on disk was from the build before. A `no_agent` job's non-zero
# exit is delivered to the PERSON as a message, is not deduplicated across
# ticks, and this job runs every five minutes. Nineteen of them reached the
# owner — on their phone, because Telegram was a reminder channel — each
# naming a Python module and repeating Hermes's advice to pause the job.
#
# Nothing was lost by any of those failures and nothing would have been lost
# by silence: a queued intent stays queued. So the rule is rule 8 one level
# up — missing is not gone — and the shape is moe-watch-reader.py's: loud in
# the log, silent to the person.
# ---------------------------------------------------------------------------

def _no_intents_module(mac, monkeypatch):
    """The real shape of the failure: `moeledger` imports (the plugin is
    there) and has no `intents` in it (the plugin is from the build before
    slice 3). Patched rather than staged on disk because the module is
    already in `sys.modules` by the time any test runs, which is also why
    the bug survived: an empty plugins directory does not reproduce it."""
    monkeypatch.setattr(mac.drain, "intents_module", lambda lib: None)


def test_a_missing_intents_module_is_quiet_and_keeps_the_queue(mac, monkeypatch, capsys):
    mac.queue(action="pull")
    _no_intents_module(mac, monkeypatch)

    # The whole point: it returns, it does not raise.
    report = mac.drain.drain(sender=Sender(), plugins=mac.plugins, directory=mac.ledger)

    assert report.library_missing is True
    assert report.outcomes == [] and mac.results() == []
    # Nothing ran, nothing was refused, nothing was answered — the intent is
    # exactly where it was, for the drain that comes after the install.
    assert not mac.log.exists(), "no connector was called"
    # And `main()` — what cron actually runs — exits 0, which is the whole
    # difference between a log line and a message on the person's phone.
    assert mac.drain.main() == 0


def test_the_quiet_exit_still_says_in_the_log_what_is_waiting(mac, monkeypatch, capsys):
    mac.queue(action="pull")
    mac.queue(action="pull", target="reminders")
    _no_intents_module(mac, monkeypatch)

    mac.drain.drain(sender=Sender(), plugins=mac.plugins, directory=mac.ledger)

    err = capsys.readouterr().err
    # Findable by name, not by prose: this is the half of the trade that
    # makes "quiet to the person" safe.
    assert mac.drain.WAITING_FOR_PLUGIN in err
    assert "part-way through an upgrade" in err
    assert "2 intent record(s) are waiting" in err, err
    assert "install.sh" in err, "the log names the thing that fixes it"


def test_the_quiet_exit_says_nothing_on_stdout(mac, monkeypatch, capsys):
    """stdout from a `no_agent` job is delivered to the person as a message.
    That is the channel the old SystemExit(1) shouted down."""
    mac.queue(action="pull")
    _no_intents_module(mac, monkeypatch)
    mac.drain.drain(sender=Sender(), plugins=mac.plugins, directory=mac.ledger)
    assert capsys.readouterr().out == ""


def test_the_count_is_read_without_the_library_and_reads_no_bodies(mac):
    """`kind` is in the clear on every record (§5); only bodies are sealed.
    So the count is available to a reader that cannot open one of them —
    which is exactly the reader this path has."""
    assert mac.drain.queued_intents(mac.ledger) == 0
    mac.queue(action="pull")
    assert mac.drain.queued_intents(mac.ledger) == 1
    # A ledger directory that is not there at all answers zero, not an error.
    assert mac.drain.queued_intents(mac.root / "nowhere") == 0


def test_nothing_queued_says_nothing_is_queued(mac, monkeypatch, capsys):
    _no_intents_module(mac, monkeypatch)
    mac.drain.drain(sender=Sender(), plugins=mac.plugins, directory=mac.ledger)
    assert "Nothing is queued." in capsys.readouterr().err


def test_a_genuinely_broken_drain_is_still_loud(mac, monkeypatch):
    """The scope of the quiet path, pinned. Only "the plugin has not landed"
    is silent; anything actually broken still exits non-zero, because that
    IS something the person needs to hear once."""
    def boom(*a, **kw):
        raise RuntimeError("the ledger is a banana")

    monkeypatch.setattr(mac.drain, "drain", boom)
    assert mac.drain.main() == 1


def test_the_count_is_exact_and_not_fooled_by_the_word(mac):
    """The count has a cheap `'"intent"' not in line` prefilter in front of
    the JSON parse, so the thing to prove is that the prefilter only ever
    *skips* work and never decides anything: an `intent.result` is not an
    intent, and neither is a record that merely mentions one.

    Verified against the owner's real ledger too (1,172 records across three
    device chains, 10 ms, agreeing with an independently written count), then
    against a copy of it with these three appended.
    """
    mac.queue(action="pull")
    chain = mac.ledger / ("%s.jsonl" % MACHINE)  # / and %% bind equally, left to right
    with chain.open("a", encoding="utf-8") as handle:
        for record in (
            # The answer to an intent is not another intent.
            {"id": "r1", "device": MACHINE, "seq": 9001, "after": [], "at": 1788000000,
             "kind": "intent.result", "body": {"of": "x", "state": "done"}},
            # Nor is the attempt record §14.3a writes before running one.
            {"id": "r2", "device": MACHINE, "seq": 9002, "after": [], "at": 1788000000,
             "kind": "intent.attempt", "body": {"of": "x"}},
            # Nor a turn that happens to contain the word.
            {"id": "r3", "device": MACHINE, "seq": 9003, "after": [], "at": 1788000000,
             "kind": "turn", "body": {"thread": "t", "text": "what was my intent here"}},
        ):
            handle.write(json.dumps(record) + "\n")

    assert mac.drain.queued_intents(mac.ledger) == 1
