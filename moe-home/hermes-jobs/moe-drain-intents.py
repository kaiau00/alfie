#!/usr/bin/env python3
"""Carry out the work the away machine could not: drain queued `intent`
records on the Mac (docs/LEDGER-WIRE.md §14, docs/CLOUD-PLAN.md §13).

A tool that lives on this Mac stays *callable* on the machine; calling it
there appends an `intent` to the ledger and tells the person it will happen
when their Mac wakes. This script is the other half of that promise. It runs
as a Hermes **no_agent** cron job — Hermes's gateway hooks are lifecycle
events and there is no periodic hook, so cron is the only tick, and it ticks
while Memoe.app is open, which is exactly "while the Mac is awake".

No model is involved anywhere in here. What it does, in order:

  1. `flock` on ``<ledger dir>/intents.lock`` (§14.4 rule 2), non-blocking.
     Another drain holding it means one is already running; this one exits
     quietly rather than queueing behind work that is being done.
  2. Stat the ledger directory. If nothing in it has changed since a tick
     that had nothing to do, stop here without reading a byte — an idle tick
     every five minutes must not cost a full read of a 50 MB ledger.
  3. Read the ledger — this Mac's shared chain and every device's file — and
     ask ``moeledger.intents.pending`` what is outstanding (§14.4 rule 1: an
     intent with an `intent.result` is finished for ever, and one whose
     attempts have reached its cap is finished too; status is derived, never
     stored. Rule 6: only this runtime's, and only what opens. Rule 7: only
     from a device this Mac still trusts).
  4. For each **live** intent, look its `via` up in the executor table
     (§14.4 rule 9), append an `intent.attempt` **before** handing over
     (§14.3a), and run it. An **expired** intent is reported and never
     executed (rule 3); an executor that is merely not here *right now* is
     left for a later tick (rule 8).
  5. Append one sealed `intent.result` per intent on this Mac's own device
     chain, through the §13.1 append path (``LocalLedger``, via the intents
     library's ``append_result``): this drain is the *third* writer on that
     chain, after the app and ``claimstore``, and the lock in there is what
     keeps it from forking.
  6. One message per drain, never one per intent (rule 4), naming the count,
     the kinds and how long the person waited — written in a ``finally``, so
     a Mac that sleeps mid-batch still reports the work that finished. A
     drain that did nothing says nothing at all — no writes, no message,
     quick exit.

**Nothing in here is about connectors.** §14.2 and §14.4 rule 9 make the
executor a *registration*: `via` names it, the table below maps `via` to
something that can say whether it can run here, whether an action changes the
world, and how to carry it out. `connector` is the only one built. Adding
Composio, a Mac-only MCP server or a skill is a row in that table and nothing
at all in the record format, the sealing, the exactly-once rule, the summary,
or the loop at the bottom of this file.

**Nothing queued may send** (§14.4 rule 5). A `send` or `voice` verb is
refused here, unexecuted, with a reason the person can read. It is not belt
and braces any more: gmail became `runs_in=mac` on 2026-09-14, so its `send`
is a detached verb on the machine. The plugin refuses to queue it (the live
proxy or nothing); this is the second line, for an intent written by anything
else.

Output discipline, because this is a no_agent job: **stdout is a message to
the person.** Everything this script has to say about itself goes to stderr,
which Hermes keeps only when the run fails. Stdout stays empty unless a human
has to do something about it. The summary is not printed — it is sent,
through the same ``hermes send --to <platform>`` path ``moe-screen``'s
``deliver.py`` uses, so it reaches the person where they are (they are away;
that is why the intent existed) rather than the screen of the Mac they are
not sitting at.
"""

import importlib.util
import json
import os
import sys
import time
from pathlib import Path

#: What Hermes calls this job; used to label the message and the log lines.
JOB_NAME = "moe-drain-intents"
#: The one state this job reports quietly (stderr, exit 0) rather than as a
#: message to the person: its plugin has not been installed yet. Named so it
#: can be grepped for without matching the prose around it.
WAITING_FOR_PLUGIN = "waiting-for-plugin"

#: §14.2: `runtime` is where the intent MUST run, and a device whose own
#: runtime does not match ignores the record entirely — which is what stops
#: the machine draining its own intents. MOE_RUNS_IN is the same variable
#: `moe-connectors` reads; unset means a Mac.
RUNTIME_ENV = "MOE_RUNS_IN"
RUNTIME_DEFAULT = "mac"

#: §14.4 rule 8 — **missing is not gone.** An executor, a script or a plugin
#: that is not there *right now* (mid-upgrade: `configure-hermes.py` rewrites
#: exactly these paths during an install) leaves the intent alone for a later
#: tick. Only a condition that persists this many consecutive ticks — or an
#: intent that expires meanwhile — becomes `refused`. At five minutes a tick
#: that is a quarter of an hour of absence before anything is burned.
TRANSIENT_TICKS = 3

#: The drain's own bookkeeping, beside the ledger and deliberately not in it:
#: how many ticks each absent executor has been absent (rule 8) and the stamp
#: of a ledger directory that had nothing to do (the idle fast path). Neither
#: is protocol; a lost file costs one wasted read and a reset counter.
STATE_FILE = "moe-drain-intents.json"

#: §14.4 rule 9: a `via` with no executor is refused with a reason naming it,
#: rather than leaving the person in silence until the TTL.
NO_EXECUTOR = ("This Mac's Alfie doesn't know how to do `%s` work yet, so there was "
               "nothing here to run it — update Alfie.")

#: Rule 8, once the absence has stopped being transient.
GAVE_UP = ("This could not be run because %s, and that has not changed in %d "
           "checks, so I have stopped waiting for it.")

#: §14.4 rule 5. A send gate is a dialog on a person's screen; an intent is by
#: definition something queued while nobody was at that screen, so a queued
#: send would be a message sent with nobody's confirmation.
#:
#: WHEN THE HEADLESS CONFIRM GATE EXISTS (slice 4), THIS IS WHERE IT GOES.
#: §14.4 rule 5: a queued send passes the confirm gate on drain *regardless of
#: the intent's age*, and the seam is `moe-home/hermes/hooks/confirm-send.sh`'s
#: CONFIRM resolution. So `ConnectorExecutor.refusal` becomes: ask the gate; on
#: a yes, return "" and let it run like any other action; on a no or no answer,
#: refuse with what the gate said. Until that exists the only honest answer is
#: to refuse and say so — a tool that is offered and always refuses is a lie,
#: but a queued send that goes out unconfirmed is worse.
SEND_REFUSAL = ("Alfie does not send anything that was queued while you were away — a send "
                "needs your confirmation, and nobody was here to give it. Ask again now "
                "and it goes straight out.")


def log(message):
    """To stderr, never stdout: stdout is delivered to the person."""
    sys.stderr.write("%s: %s\n" % (JOB_NAME, message))


# ---------------------------------------------------------------------------
# Where things are
# ---------------------------------------------------------------------------

def moe_home():
    return Path(os.environ.get("MOE_HOME") or (Path.home() / ".moe")).expanduser()


def hermes_home():
    return Path(os.environ.get("HERMES_HOME") or (Path.home() / ".hermes")).expanduser()


def plugins_dir():
    """``$HERMES_HOME/plugins`` — where the plugins find each other."""
    return hermes_home() / "plugins"


def ledger_dir():
    """``$MOE_HOME/ledger``, the same directory ``claimstore`` resolves.

    Not under ``$HERMES_HOME``: the ledger is Alfie's, it holds conversations as
    well as memory, and Hermes is one of several writers to it.
    """
    return moe_home() / "ledger"


def runtime():
    return (os.environ.get(RUNTIME_ENV) or RUNTIME_DEFAULT).strip().lower() or RUNTIME_DEFAULT


# ---------------------------------------------------------------------------
# The sibling plugins
#
# The `_sibling.py` pattern, from a script rather than from a plugin: put
# `$HERMES_HOME/plugins` on sys.path (append, never ahead of the stdlib) and
# import `moeledger` by name. `moe-connectors` and `moe-screen` are not legal
# module names — a dash — so those are loaded from their file path, which is
# the same code the gateway runs, not a copy of it.
# ---------------------------------------------------------------------------

_by_path = {}


def _load_module(path, name):
    """One module, from its file, loaded at most once per path."""
    path = Path(path)
    cached = _by_path.get(str(path))
    if cached is not None:
        return cached
    if not path.is_file():
        return None
    spec = importlib.util.spec_from_file_location(name, str(path))
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:  # pragma: no cover — a broken install, reported here
        sys.modules.pop(name, None)
        log("could not import %s (%s)" % (path, sys.exc_info()[1]))
        return None
    _by_path[str(path)] = module
    return module


def moeledger_module(plugins=None):
    """The ``moeledger`` library inside the ``moe-ledger`` plugin."""
    if "moeledger" in sys.modules:
        return sys.modules["moeledger"]
    root = Path(plugins or plugins_dir()) / "moe-ledger"
    if not (root / "moeledger" / "__init__.py").is_file():
        return None
    if str(root) not in sys.path:
        sys.path.append(str(root))
    try:
        import moeledger  # noqa: WPS433
    except ImportError:
        log("moe-ledger is beside this Mac's plugins but moeledger will not import "
            "(missing `cryptography`?); no intent can be read or answered")
        return None
    return moeledger


def intents_module(lib):
    """``moeledger.intents`` — §14 itself, and the ONE place this script is
    coupled to it.

    Everything below goes through this module: the two kinds, the bodies and
    their sealing, ``pending``'s derived status, ``append_result``'s writer and
    ``drain_lock``'s ``flock``. None of it is re-implemented here — a second
    reading of §14 that drifts from the first is exactly how an append-only
    log stops being one.
    """
    module = getattr(lib, "intents", None)
    if module is not None:
        return module
    from importlib import import_module

    try:
        return import_module("moeledger.intents")
    except ImportError:
        return None


def connectors_module(plugins=None):
    """The ``moe-connectors`` plugin — for ``run_verb`` and nothing else.

    Imported rather than re-implemented on purpose: §14 says the drain runs a
    connector *exactly as the gateway does*, and the only way to keep that
    true a year from now is for there to be one ``run_verb``.
    """
    return _load_module(Path(plugins or plugins_dir()) / "moe-connectors" / "__init__.py",
                        "moe_connectors")


def deliver_module(plugins=None):
    """``moe-screen``'s ``deliver.py`` — the ``hermes send --to <platform>``
    path, which needs no gateway, and the screen inbox behind it."""
    return _load_module(Path(plugins or plugins_dir()) / "moe-screen" / "deliver.py",
                        "moe_screen_deliver")


# ---------------------------------------------------------------------------
# This Mac's chain
# ---------------------------------------------------------------------------

def ledger_vault(lib, directory):
    """A ``moeledger.vault.Vault`` rooted so it reads THIS Mac's ledger.

    The machine's vault keeps its ledger at ``<root>/ledger`` and its keyring
    at ``<root>/thread-keys.json``. A Mac's ledger directory *is*
    ``~/.moe/ledger``, with the keyring inside it (that is the file
    ``claimstore`` opens and the app writes). Rooting the Vault at the ledger
    directory puts the keyring in the right place; ``ledger_dir`` is the only
    thing that has to move. Everything below it — ``ledger_lock``,
    ``file_head``, ``append_record`` — is the plugins' own §13.1 protocol,
    untouched, which is the whole point: this drain is a third writer on a
    chain two other writers already share.
    """

    class _MacVault(lib.vault.Vault):
        @property
        def ledger_dir(self):
            return self.root

    return _MacVault(Path(directory))


def resolve_device(lib, directory):
    """§13.1: one device per Mac — ``<ledger dir>/device.json``'s ``id``.

    The same file, in the same form, that the app (``Ledger.resolveDevice``)
    and ``claimstore`` (``ClaimStore._resolve_device``) use: whoever is first
    is the author for all three, so a record this drain writes is signed by
    the app at push time as the same device. Minting is deliberately left
    until a result actually has to be written, so a drain with nothing to do
    writes nothing at all.
    """
    import uuid

    path = Path(directory) / "device.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict) and isinstance(data.get("id"), str) and data["id"]:
            return data["id"]
    except (OSError, ValueError):
        pass
    device = "mac-" + uuid.uuid4().hex[:8]
    body = {"id": device, "createdAt": lib.records.format_timestamp(time.time())}
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(str(path.parent), 0o700)
        except OSError:
            pass
        tmp = path.with_name(path.name + ".%d.tmp" % os.getpid())
        tmp.write_text(lib.records.foundation_pretty_json(body), encoding="utf-8")
        os.chmod(str(tmp), 0o600)
        os.replace(str(tmp), str(path))
        log("minted device %s into %s (the app will use it too)" % (device, path))
    except OSError as exc:
        log("could not persist a device id at %s (%s)" % (path, exc))
    return device


# ---------------------------------------------------------------------------
# Executors (§14.2, §14.4 rule 9)
#
# "An executor is a registration, not a special case." The drain looks `via`
# up in this table and hands over `target`, `action` and the opened payload;
# it knows nothing else about the work. `connector` is the only one built;
# `mcp` and `skill` are the named next ones, and anything the owner adds later
# is a call to `register_executor` and nothing on the wire.
# ---------------------------------------------------------------------------

class Executor(object):
    """What the drain needs from a `via`, and the whole of it.

    Four questions, and no fifth:

      * ``missing(intent)`` — why this cannot run *right now*, ``""`` when it
        can. A non-empty answer is §14.4 rule 8's transient absence: the
        intent is left alone for a later tick, never burned.
      * ``refusal(intent)`` — why this must *never* run. A non-empty answer is
        a `refused` result carrying that sentence.
      * ``side_effects(intent)`` — does carrying this out change the world?
        This is the only place that question is answered, and §14.3a's cap
        (one, or eight) follows from it.
      * ``run(intent)`` — ``(text, failed, seconds)``.

    Nothing above this class knows what any of those mean.
    """

    via = ""

    def missing(self, intent):
        return ""

    def refusal(self, intent):
        return ""

    def side_effects(self, intent):
        """The careful default: work nobody has classified is a write."""
        return True

    def run(self, intent):
        raise NotImplementedError


class ConnectorExecutor(Executor):
    """`via: connector` — the twelve hand-written manifests, and the only
    executor built today.

    It is deliberately thin: the argv shape, the cwd, the scrubbed
    environment and the per-verb timeout stay in `moe-connectors`' own
    ``run_verb``, so the drain runs a connector *exactly as the gateway does*
    because it is the same function. What this class adds is only the three
    answers the table above asks for.
    """

    via = "connector"

    #: The verbs that only look. Everything else — `create`, and anything a
    #: manifest declares tomorrow — changes the world and gets §14.3a's cap of
    #: one. Named the safe way round on purpose: a verb nobody has classified
    #: is a write until somebody says so, because repeating a read is cheap
    #: and repeating a write is not.
    READ_ACTIONS = ("status", "pull", "find", "crawl", "chats", "accounts")

    def __init__(self, plugins=None):
        self.plugins = plugins
        self._module = None
        self._looked = False

    @property
    def connectors(self):
        if not self._looked:
            self._module = connectors_module(self.plugins)
            self._looked = True
        return self._module

    def side_effects(self, intent):
        return intent.action not in self.READ_ACTIONS

    def _entry(self, intent):
        for entry in self.connectors.read_manifests():
            if entry.get("name") == intent.target:
                return entry
        return None

    def missing(self, intent):
        """Rule 8's list, and every item on it is a path `configure-hermes.py`
        rewrites during an install. Before this was rule 8, each of them
        refused permanently, so a Mac that upgraded while an intent was queued
        answered "the notes connector is not on this Mac any more" about a
        connector that was back thirty seconds later."""
        connectors = self.connectors
        if connectors is None:
            return "Alfie's connectors are not installed on this Mac right now"
        if connectors.connector_script(intent.target) is None:
            return "the %s connector's script is not on this Mac right now" % intent.target
        entry = self._entry(intent)
        if entry is None:
            return "the %s connector declares no verbs on this Mac right now" % intent.target
        if intent.action not in (entry.get("verbs") or []):
            return ("the %s connector does not declare a `%s` verb right now"
                    % (intent.target, intent.action))
        return ""

    def refusal(self, intent):
        connectors = self.connectors
        headless = getattr(connectors, "HEADLESS_VERBS", ("send", "voice"))
        if intent.action in headless:
            return SEND_REFUSAL
        return ""

    def run(self, intent):
        """`stdin` is passed only when the manifest declares the action takes
        one (``<verb>_stdin=…``), exactly as ``make_handler`` decides it: argv
        is world-readable through `ps` and a note is the person's words."""
        entry = self._entry(intent) or {}
        kind, _fields = (entry.get("inputs") or {}).get(intent.action, (None, []))
        stdin_text = intent.stdin if kind == "stdin" else None
        started = time.time()
        text, failed = self.connectors.run_verb(intent.target, intent.action,
                                                intent.args, stdin_text)
        return (text, failed, time.time() - started)


#: `via` -> a callable taking the plugins directory and returning an
#: :class:`Executor`. A row here is the whole of "add a new kind of work".
EXECUTORS = {}


def register_executor(via, factory):
    """Add one executor to the table. §14.4 rule 9's "registered, never a new
    record kind": nothing about the wire, the sealing, the exactly-once rule
    or the summary changes when this is called."""
    EXECUTORS[via] = factory
    return factory


register_executor(ConnectorExecutor.via, ConnectorExecutor)


def build_executors(plugins=None):
    """One instance per `via`, for one drain. Built per pass so an executor
    may cache whatever it likes for the length of a tick and nothing longer."""
    table = {}
    for via, factory in sorted(EXECUTORS.items()):
        try:
            table[via] = factory(plugins)
        except Exception as exc:  # a broken row must not take the table with it
            log("executor %r would not start (%s); work for it is left alone" % (via, exc))
    return table


def attempt_cap(it, table, intent):
    """§14.3a's cap for one intent, asked of its own executor (§14.4 rule 9).

    This is the reason `pending` has no list of verbs in it: the drain knows
    which `via` it is talking to and the executor knows whether the action
    changes the world; the library only counts.
    """
    executor = table.get(intent.via)
    if executor is None:
        return it.ATTEMPT_CAP_SIDE_EFFECT
    try:
        writes = bool(executor.side_effects(intent))
    except Exception:
        writes = True
    return it.ATTEMPT_CAP_SIDE_EFFECT if writes else it.ATTEMPT_CAP_READ


# ---------------------------------------------------------------------------
# The drain's own state: rule 8's tick counter and the idle fast path
# ---------------------------------------------------------------------------

def state_path():
    return hermes_home() / STATE_FILE


def ledger_stamp(directory):
    """``(files, bytes, newest mtime_ns)`` for the ledger directory, or None.

    §13.1 already caches a head against a file's ``(size, mtime_ns)``; this is
    the same test over a directory. An idle tick every five minutes otherwise
    reads the whole ledger to conclude that there is nothing in it for us —
    51 ms on 986 KB in the probe, and about 2.5 s at 50 MB, for ever.

    ``thread-keys.json`` is in the stamp because a key arriving is what turns
    an unreadable intent into a runnable one, and it does not touch a
    ``.jsonl``.
    """
    directory = Path(directory)
    files = 0
    size = 0
    newest = 0
    try:
        paths = sorted(directory.glob("*.jsonl")) + [directory / "thread-keys.json"]
        for path in paths:
            try:
                stat = path.stat()
            except FileNotFoundError:
                continue
            files += 1
            size += stat.st_size
            newest = max(newest, stat.st_mtime_ns)
    except OSError:
        return None
    return [files, size, newest]


class DrainState(object):
    """Two things live in here and nothing else.

    ``waiting``: intent id -> how many *consecutive* ticks its executor has
    been missing (§14.4 rule 8). ``idle``: the ledger stamp as of a tick that
    found nothing to do, so the next one can skip the read.

    Neither is protocol and neither is in the ledger: losing this file costs
    one wasted read and a reset counter, which is exactly what it should cost.
    """

    def __init__(self, path):
        self.path = Path(path)
        self.data = {}
        self.dirty = False
        try:
            loaded = json.loads(self.path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                self.data = loaded
        except (OSError, ValueError):
            pass

    # -- rule 8 --------------------------------------------------------------

    def waiting(self):
        found = self.data.get("waiting")
        return found if isinstance(found, dict) else {}

    def defer(self, intent_id, why):
        """Count one tick of a transient absence; return the running total."""
        waiting = dict(self.waiting())
        entry = waiting.get(intent_id)
        ticks = (int(entry.get("ticks", 0)) + 1) if isinstance(entry, dict) else 1
        waiting[intent_id] = {"ticks": ticks, "why": why}
        self.data["waiting"] = waiting
        self.dirty = True
        return ticks

    def undefer(self, intent_id):
        """The absence ended: rule 8 counts *consecutive* ticks."""
        waiting = self.waiting()
        if intent_id in waiting:
            kept = dict(waiting)
            kept.pop(intent_id, None)
            self.data["waiting"] = kept
            self.dirty = True

    def forget(self, keep_ids):
        """Drop counters for intents that are no longer outstanding."""
        waiting = self.waiting()
        kept = {k: v for k, v in waiting.items() if k in keep_ids}
        if kept != waiting:
            self.data["waiting"] = kept
            self.dirty = True

    # -- the idle fast path ---------------------------------------------------

    def idle_stamp(self):
        found = self.data.get("idle")
        return found if isinstance(found, list) else None

    def note_idle(self, stamp):
        if self.data.get("idle") != stamp:
            self.data["idle"] = stamp
            self.dirty = True

    def note_busy(self):
        if self.data.get("idle") is not None:
            self.data["idle"] = None
            self.dirty = True

    # -- persistence ----------------------------------------------------------

    def save(self):
        if not self.dirty:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_name(self.path.name + ".%d.tmp" % os.getpid())
            tmp.write_text(json.dumps(self.data, sort_keys=True), encoding="utf-8")
            os.chmod(str(tmp), 0o600)
            os.replace(str(tmp), str(self.path))
            self.dirty = False
        except OSError as exc:
            log("could not save %s (%s); the next tick starts from scratch"
                % (self.path, exc))


# ---------------------------------------------------------------------------
# §14.4 rule 7 — a device only drains work from a device it still trusts
# ---------------------------------------------------------------------------

def peers_path(directory, plugins=None):
    """The app's peer book (§3.4). ``claimstore`` already resolves this —
    ``memory.claimstore.peers_path``, defaulting to
    ``<ledger dir>/../cloud/peers.json`` — so it is asked rather than
    second-guessed; the fallback is that same default."""
    try:
        root = str(Path(plugins or plugins_dir()))
        if root not in sys.path:
            sys.path.append(root)
        import claimstore  # noqa: WPS433

        return Path(claimstore.resolve_peers_path(ledger_dir=Path(directory)))
    except Exception:
        return Path(directory).parent / "cloud" / "peers.json"


def read_peers(lib, path):
    """``(live devices, every device the book mentions)`` — the peer book the
    way ``sync.py`` reads it (``PeerBook.from_json``, whose entries are what
    `verify_record` trusts), minus the book's ``revoked`` list, because §12.3's
    revocation of a stolen machine must stop what it queued and not only what
    it would queue next.

    The second set is what says whether there is a book *at all*, which is a
    different question from whether anybody is still in it: revoking the only
    machine a person ever enrolled leaves no live peer, and that must be a
    refusal, not a shrug.
    """
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return set(), set()
    except (OSError, ValueError):
        return set(), set()
    try:
        book = lib.identity.PeerBook.from_json(data)
    except Exception:
        return set(), set()
    live = {peer.device_id for peer in book.all()}
    known = set(live)
    revoked = data.get("revoked") if isinstance(data, dict) else None
    if isinstance(revoked, list):
        gone = {str(r) for r in revoked}
        live -= gone
        known |= gone
    return live, known


def trust_check(devices, known, me):
    """The callable ``pending`` takes for rule 7, or None for *no evidence*.

    CHOICE, and §14 does not settle it: with **no peer book, or one this side
    cannot read**, this Mac has never enrolled anybody and cannot tell a
    stranger from a machine the person set up five minutes ago. Refusing
    everything would turn an unreadable file into a kill switch for the whole
    queue; so nothing is judged, and the drain says so in the log. Once the
    book names anybody at all — including somebody it names only to say they
    were revoked — it is the answer: a device not in it, or in its ``revoked``
    list, is refused. Work this device queued for itself is always its own.
    """
    if not known:
        return None

    def trusted(device):
        if not device:
            return True         # a bare body with no author: nothing to judge
        if me and device == me:
            return True         # §14.4 rule 7: our own is our own
        return device in devices

    return trusted


def read_device(directory):
    """This Mac's device id if there is one, **without minting** — a drain
    that has nothing to write must leave the ledger untouched."""
    try:
        data = json.loads((Path(directory) / "device.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data.get("id") if isinstance(data, dict) and isinstance(data.get("id"), str) else None


# ---------------------------------------------------------------------------
# The answers that need no executor
# ---------------------------------------------------------------------------

def expired_answer(it, intent):
    """§14.4 rule 3: reported, never executed."""
    return (it.STATE_EXPIRED, "",
            "This expired before your Mac was awake to run it (it was good until %s), "
            "so nothing was run." % intent.expires, 0.0)


def answer_without_running(it, intent, expired_ids, exhausted_ids, untrusted_ids):
    """The outcome for an intent nothing may be run for, or None.

    Order matters. **Exhausted comes first**: an intent that was started, was
    interrupted and has since expired must say "I have not repeated it" and
    not "nothing was run", which would be a lie about work that did happen
    (§14.3a).
    """
    if intent.id in exhausted_ids:
        return (it.STATE_FAILED, "", it.EXHAUSTED_REASON, 0.0)
    if intent.id in untrusted_ids:
        return (it.STATE_REFUSED, "", it.UNTRUSTED_REASON, 0.0)
    if intent.id in expired_ids:
        return expired_answer(it, intent)
    return None


# ---------------------------------------------------------------------------
# The summary — one per drain, never one per intent
# ---------------------------------------------------------------------------

def humanise(seconds):
    """"about 3 hours", the way a person would say it."""
    seconds = max(0.0, float(seconds))
    if seconds < 90:
        return "a moment"
    minutes = seconds / 60.0
    if minutes < 60:
        return "about %d minutes" % round(minutes)
    hours = minutes / 60.0
    if hours < 36:
        return "about %d hour%s" % (round(hours), "" if round(hours) == 1 else "s")
    return "about %d days" % round(hours / 24.0)


def summarise(it, outcomes, waited):
    """One sentence naming the count, the kinds and the delay (§14.4 rule 4).

    Forty pending things is one sentence, not forty notifications. What it may
    name without the key is the count and the kind — `notes pull` is the
    manifest's words, which §14.2 keeps in the clear for exactly this. What
    the person actually asked, and what came back, is theirs and stays sealed.
    """
    if not outcomes:
        return ""
    words = ((it.STATE_DONE, "done"), (it.STATE_FAILED, "failed"),
             (it.STATE_REFUSED, "not done"), (it.STATE_EXPIRED, "too old to run"))
    parts = []
    for state, word in words:
        kinds = [kind for (s, kind) in outcomes if s == state]
        if not kinds:
            continue
        seen = []
        for kind in kinds:
            if kind not in seen:
                seen.append(kind)
        parts.append("%d %s (%s)" % (len(kinds), word, ", ".join(seen)))
    total = len(outcomes)
    return ("Your Mac was asleep for %s. I caught up on %d thing%s you asked for while it "
            "was: %s." % (humanise(waited), total, "" if total == 1 else "s", "; ".join(parts)))


def send_summary(text, deliver, sender=None):
    """Send the one summary where the person will actually see it.

    The channels are the same ``reminderChannels`` setting ``deliver.py``
    reads (Settings › Background), resolved at delivery time so flipping the
    switch takes effect without touching this job, and the send is
    ``deliver.py``'s own ``fan_out`` — ``hermes send --to <platform>``, which
    needs no gateway. With no channel set the summary goes to the screen inbox
    instead of nowhere: the person is away, which is why the intent existed at
    all, but a message on the Mac they come back to still beats a message that
    was never written.

    ``sender`` is injectable so a test can assert on what would have been sent
    without a message leaving the machine.
    """
    if not text:
        return False
    if deliver is None:
        log("moe-screen is not installed, so the summary has nowhere to go: %s" % text)
        return False
    channels = deliver.extra_channels()
    if not channels:
        log("no reminderChannels is configured (Settings › Background), so the summary "
            "goes to the screen inbox rather than nowhere")
        try:
            deliver.write_inbox(text, source=JOB_NAME, job=JOB_NAME)
        except OSError as exc:
            log("could not write the summary to the inbox: %s" % exc)
            return False
        return True
    send = sender or (lambda body, names: deliver.fan_out(body, names))
    errors = send(text, channels) or {}
    for name, why in sorted(errors.items()):
        log("the summary did not reach %s: %s" % (name, why))
    return len(errors) < len(channels)


# ---------------------------------------------------------------------------
# The drain
# ---------------------------------------------------------------------------

class Report(object):
    """What one drain did. Returned for the tests and the log; the person gets
    the summary, not this."""

    def __init__(self):
        self.locked_out = False
        self.idle_skipped = False   # the ledger had not changed; nothing read
        self.library_missing = False  # moe-ledger/intents not installed yet
        self.outcomes = []          # (state, "target action"), in ledger order
        self.skipped_unreadable = 0
        self.deferred = 0           # §14.4 rule 8: left alone for a later tick
        self.attempts = 0           # §14.3a records written this pass
        self.appended = []          # the intent.result records, in order
        self.summary = ""
        self.sent = False
        self.waited = 0.0
        # §16 says — a sentence the machine had nobody to tell. Counted apart
        # from `outcomes` on purpose: an intent is work the person ASKED for
        # and belongs in the one summary (rule 4), while a say is a message
        # Moe already meant to send and is delivered AS ITSELF. Folding them
        # together would turn "your flight moved" into a line item in a
        # progress report.
        self.says_spoken = 0
        self.says_expired = 0
        self.says_unreadable = 0
        self.says_untrusted = 0
        #: Handed over once, never confirmed. Terminal, and counted so that
        #: "lost" is never indistinguishable from "nothing happened".
        self.says_capped = 0
        #: **What is LEFT after this pass, not what happened in it.** The
        #: first version's idle guard enumerated the outcomes that write
        #: something and went idle on the rest — and there were five ways to
        #: leave a sentence behind, of which it named two. A guard that
        #: enumerates is walked past by the next name; this counts the
        #: complement instead. -1 means "the pass could not even look".
        self.says_held = 0

    @property
    def did_something(self):
        # Kept `or bool(self.says_spoken)` for correctness, and noting what a
        # review measured: this property has NO callers anywhere in the repo.
        # `return False` passes the whole suite. It is reported rather than
        # deleted because it is a Report field a future caller would reach
        # for, and it would have been wrong.
        return bool(self.outcomes) or bool(self.says_spoken)


def _ledger_order(records, intents):
    """The intents, in the order their records sit in the ledger.

    ``pending`` hands back its verdicts as separate lists; a drain runs "each
    live intent, in ledger order" (§14.4) and reports the rest in the same
    pass, so they are re-interleaved by position rather than concatenated.
    """
    position = {}
    for index, record in enumerate(records):
        position[record.id] = index
    return sorted(intents, key=lambda i: position.get(i.id, 1 << 30))


def carry_out(it, table, intent, book, chain, report, now):
    """One live intent: what to write for it, or None to leave it for a later
    tick (§14.4 rule 8).

    The order here is the whole of the exactly-once story. Nothing is run
    before an `intent.attempt` is on the chain, so a Mac that sleeps in the
    window between running the work and recording the result leaves a trace —
    and the next tick counts it instead of doing the work again.
    """
    executor = table.get(intent.via)
    if executor is None:
        # §14.4 rule 9. A plain reason naming the `via`, rather than leaving
        # the person in silence until the TTL.
        return (it.STATE_REFUSED, "", NO_EXECUTOR % intent.via, 0.0)

    reason = executor.refusal(intent)
    if reason:
        # Never run, however long it waits — rule 5's send gate is the only
        # one of these today.
        return (it.STATE_REFUSED, "", reason, 0.0)

    absent = executor.missing(intent)
    if absent:
        ticks = book.defer(intent.id, absent)
        if ticks < TRANSIENT_TICKS:
            # Rule 8: **missing is not gone.** A plugin, script or executor
            # that is not there right now — mid-upgrade, mid-install — leaves
            # the intent alone, exactly as an unreadable payload does.
            report.deferred += 1
            log("intent %s (%s) cannot run yet: %s — left for a later tick (%d of %d)"
                % (intent.id, intent.kind_of_thing, absent, ticks, TRANSIENT_TICKS))
            return None
        return (it.STATE_REFUSED, "", GAVE_UP % (absent, ticks), 0.0)
    book.undefer(intent.id)

    # §14.3a: record that we are about to act, BEFORE we act, on the same
    # chain and through the same §13.1 path as everything else. If this append
    # fails we have not run anything, and the caller leaves the intent alone.
    it.append_attempt(chain(), thread=intent.thread, intent_id=intent.id,
                      at_epoch=now, after=[intent.id])
    report.attempts += 1

    text, failed, seconds = executor.run(intent)
    if failed:
        return (it.STATE_FAILED, "", text, seconds)
    return (it.STATE_DONE, text, "", seconds)


def queued_intents(directory):
    """How many `intent` records the chain holds, read without the library.

    Only bodies are sealed (LEDGER-WIRE §5): `kind` is in the clear on every
    record, so a chain can be counted by a reader that cannot open a single
    one of them. Used only to make the "waiting for the plugin" log line say
    something true about whether anything is actually held up.

    Any unreadable line is skipped rather than raising — this runs on the
    path where things are already known to be half-installed, and a count is
    never worth failing over.
    """
    total = 0
    try:
        paths = sorted(Path(directory).glob("*.jsonl"))
    except OSError:
        return 0
    for path in paths:
        try:
            with path.open(encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line or '"intent"' not in line:
                        continue
                    try:
                        if json.loads(line).get("kind") == "intent":
                            total += 1
                    except ValueError:
                        continue
        except OSError:
            continue
    return total


def says_module(lib):
    """``moeledger.says`` — §16's record kinds and their derived status.

    Separate from :func:`intents_module` and asked for separately, because a
    build can have one and not the other: `says.py` is newer, and a Mac
    part-way through an upgrade must drain the intents it understands rather
    than refuse the whole tick over a module that has not landed.
    """
    mod = getattr(lib, "says", None)
    if mod is None:
        try:
            from importlib import import_module
            mod = import_module("moeledger.says")
        except Exception:
            return None
    return mod if hasattr(mod, "pending") and hasattr(mod, "append_spoken") else None


def drain_says(sy, records, keyring, trusted, chain, deliver, report, here, now):
    """Speak what the machine had nobody to tell (§16), inside the same lock.

    Called from :func:`drain` after the intents pass, sharing its `records`,
    `keyring`, `trusted` and `chain` — one read of the ledger, one lock, one
    device chain. A second job would have meant a second read of a 50 MB file
    and a second summary in the same tick, which is what rule 4 forbids.

    **Each say is delivered as itself, not summarised.** It was already a
    message on its way to the person when the machine ran out of places to
    put it; the Mac is finishing that delivery, so it goes through
    `deliver.deliver` — the island, and whatever channels THIS Mac has ticked,
    which is the point: the machine had none and the Mac may.

    The attempt record goes down BEFORE the delivery and the `say.spoken`
    after, which is §14.3a's discipline and buys the same thing here: a Mac
    that sleeps between writing the island and recording it speaks the
    sentence once, not on every tick for ever. The cap is one.
    """
    if sy is None or deliver is None:
        # No `says` module, or no moe-screen to speak through. Not an error
        # and not silent: the records stay on the chain, and the next tick
        # with both present says them. What must NOT happen is marking them
        # spoken by a Mac that had no mouth.
        #
        # `says_held` is set WITHOUT reading the ledger, and that is the whole
        # point of it being a count of what is left rather than of what
        # happened. This path writes nothing, so the ledger's stamp does not
        # move, so the idle fast path would remember the stamp and never read
        # the ledger again — a held sentence stranded until something
        # unrelated happened to write, which on a machine whose person is
        # away is exactly never. -1 means "unknown, and not zero".
        report.says_held = -1
        return

    waiting = sy.pending(records, runtime=here, now=now, keys=keyring.key,
                         trusted=trusted)

    for say in waiting.unreadable:
        # The thread key has not arrived yet. Left entirely alone — the same
        # rule as an unreadable intent, and for the stronger reason that this
        # one is a sentence somebody wrote.
        report.says_unreadable += 1
        report.says_held += 1
        log("say %s will not open with the key held for its thread; left alone" % say.id)

    for say in waiting.untrusted:
        report.says_untrusted += 1
        # Held rather than terminal: a device can be trusted again, and a
        # peer book that cannot be read reports nobody as trusted. Leaving
        # this out of the count let the tick go idle and never look again.
        report.says_held += 1
        log("say %s came from a device this Mac no longer trusts; refused" % say.id)

    for say in waiting.capped:
        # Tried its one attempt and never confirmed — §14.3a's trade, taken
        # deliberately: at most one telling, possibly none, never two. It is
        # FINISHED, and this line is the only place anyone will ever learn the
        # sentence existed, so it is not optional. `pending` used to drop these
        # out of every list while a comment beside it promised "the drain
        # reports it"; nothing did, and a message vanished with nobody told.
        report.says_capped += 1
        log("say %s was handed over once and never confirmed; it will not be "
            "tried again" % say.id)

    for say in waiting.expired:
        # Recorded as expired rather than left to be re-examined every tick
        # for ever, and NEVER spoken: a reminder four days late read out at
        # breakfast is worse than one missed (§14.4 rule 3).
        try:
            sy.append_spoken(chain(), thread=say.thread, say_id=say.id,
                             state=sy.STATE_EXPIRED, after=[say.id])
        except Exception:
            logger_exception("could not record say %s as expired" % say.id)
            report.says_held += 1
            continue
        report.says_expired += 1
        log("say %s was past its deadline; recorded expired, not spoken" % say.id)

    for say in waiting.live:
        try:
            sy.append_attempt(chain(), thread=say.thread, say_id=say.id,
                              at_epoch=now, after=[say.id])
        except Exception:
            # Nothing has been spoken. Leave it; the next tick tries again,
            # and the cap has not been spent because the record is not there.
            logger_exception("could not record an attempt at say %s; not speaking it" % say.id)
            report.says_held += 1
            continue
        try:
            ok, err = deliver.deliver(say.text, source=say.source or "away", job=say.job)
        except Exception:
            # `deliver()` raises outside its own OSError guard — `apply_trailers`
            # and `note_said` do file I/O and `fan_out` spawns a subprocess. This
            # was the ONE unguarded call in the pass, and unguarded it took out
            # far more than the sentence: the rest of the batch, the INTENT pass
            # below it, `book.save()`, and the tick itself. `main()` returns 1,
            # and this is a `no_agent` job on a five-minute timer — which is the
            # incident this very file records at §"the drain job incident":
            # nineteen failure messages naming a Python module, fanned out to
            # the owner's phone. One say's failure counts its attempt and moves
            # to the next, exactly as one intent's does.
            logger_exception("could not deliver say %s on this Mac" % say.id)
            continue
        if not ok:
            # The attempt is spent — deliberately, and this is the trade
            # §14.3a makes: one try for anything with a side effect. A
            # delivery that half-happened must not be repeated.
            #
            # **A known limit, taken in the conservative direction.** A
            # failure where PROVABLY nothing happened — an inbox write that
            # raised before any connector was called — should refund, and
            # this does not: `deliver()` folds "nothing was written" and
            # "something may have gone out" into one `False`, and telling
            # them apart here would mean matching on the error's words, which
            # is a guard that enumerates names and is walked past by the next
            # one. §18.29i met the identical choice on the edge's transport
            # failures and made the identical call: burn it rather than risk
            # a duplicate. The cost is one sentence, once; the alternative is
            # a person hearing the same thing twice.
            log("say %s could not be delivered on this Mac either: %s" % (say.id, err))
            continue
        try:
            sy.append_spoken(chain(), thread=say.thread, say_id=say.id, after=[say.id])
        except Exception:
            # Spoken, unrecorded. The attempt record is what stops a second
            # telling, which is exactly why it is written first.
            logger_exception("say %s was spoken but could not be recorded" % say.id)
        report.says_spoken += 1
        # The id, never the sentence — and the reason only if it is one of
        # OURS. `say_body` refuses a free-text reason precisely so the
        # person's words have exactly one home, and then `parse_say` accepts
        # any string (deliberately, so a newer build's vocabulary is not
        # dropped) and this line printed it. The guard was on the writer and
        # the door was on the reader.
        log("say %s spoken on this Mac (%s)"
            % (say.id, say.reason if say.reason in sy.REASONS else "unrecognised"))


def logger_exception(message):
    """stderr, with the traceback, the way `log` does. A helper so the say
    pass reads as prose rather than as five identical try/except blocks."""
    import traceback
    log("%s\n%s" % (message, traceback.format_exc()))


def drain(now=None, sender=None, plugins=None, directory=None, executors=None,
          state=None):
    """One pass. Cheap when there is nothing to do: no reads, no writes, no
    message."""
    now = time.time() if now is None else now
    directory = Path(directory) if directory is not None else ledger_dir()
    report = Report()

    here = runtime()
    if here != RUNTIME_DEFAULT:
        # §14.2/§14.4 rule 6: a device only drains intents whose `runtime` is
        # its own, and `mac` is the only value a machine writes. Belt and
        # braces: configure-hermes installs this job on a Mac and nowhere else.
        log("this is not a Mac (%s=%s); nothing here drains intents" % (RUNTIME_ENV, here))
        return report

    if not directory.is_dir():
        return report  # no ledger: Moe Away was never set up on this Mac

    lib = moeledger_module(plugins)
    it = intents_module(lib) if lib is not None else None
    if lib is None or it is None:
        # The ledger is there and the library that reads it is not — a Mac
        # part-way through an upgrade: the job was registered by a build that
        # ships `intents.py` and the plugin on disk is from the build before.
        #
        # This used to `raise SystemExit(1)`, on the reasoning that a non-zero
        # exit is the only channel a `no_agent` job has for saying so and
        # Hermes would raise one deduplicated incident. Both halves were
        # wrong, and it cost a person real trouble before anyone noticed
        # (2026-09-03): a `no_agent` job's failure is delivered as a MESSAGE,
        # it is not deduplicated across ticks, and this one runs every five
        # minutes. Nineteen failures reached the owner — fanned out to their
        # phone, because Telegram was ticked as a reminder channel, each one
        # carrying Hermes's own "pause it with hermes cron pause" advice, plus
        # a proactive nudge about the pattern it saw in the brief. They asked
        # twice what the messages were. The sentence they were being shown
        # named a Python module.
        #
        # The rule, and it is general: **a job whose plugin cannot answer yet
        # is not an incident.** Nothing is lost by waiting — a queued intent
        # stays queued, and rule 8's "missing is not gone" is the same
        # principle one level up. Loud in the log, silent to the person, the
        # way moe-watch-reader.py handles a recipe it cannot load.
        #
        # The count is read from the raw chain rather than through the library
        # that is missing: `kind` is in the clear on every record (only bodies
        # are sealed), so this can say whether anything is actually waiting
        # without being able to read a word of it.
        # A stable slug first, then the prose. The trade this path makes is
        # "quiet to the person, loud in the log", and that is only the right
        # trade if the log is findable — so the state has a NAME that does
        # not move when the sentence around it is reworded:
        #
        #     grep waiting-for-plugin <the job's stderr>
        #
        # A genuinely broken drain is a different thing and is still loud:
        # `main()` catches every other exception, logs it and returns 1. Only
        # "the plugin has not landed yet" is silent here.
        waiting = queued_intents(directory)
        log("%s: no moe-ledger/intents under %s — this Mac is part-way through "
            "an upgrade. %s Nothing is lost: the drain answers them once the "
            "plugin lands (scripts/install.sh), and stays quiet until then."
            % (WAITING_FOR_PLUGIN, Path(plugins or plugins_dir()),
               "Nothing is queued." if waiting == 0
               else "%d intent record(s) are waiting." % waiting))
        report.library_missing = True
        return report

    # §14.4 rule 2, non-blocking: a drain that queued behind another would
    # only find the work already done.
    with it.drain_lock(directory, blocking=False) as held:
        if not held:
            report.locked_out = True
            log("another drain holds %s; leaving it to that one" % it.LOCK_FILE)
            return report

        book = DrainState(state if state is not None else state_path())

        # The stamp is taken BEFORE the read, deliberately. Taken after, a
        # record appended by the app between the two would be inside the
        # stamp and outside what we read, and the next tick would skip it.
        stamp = ledger_stamp(directory)
        if stamp is not None and book.idle_stamp() == stamp:
            report.idle_skipped = True
            return report

        vault = ledger_vault(lib, directory)
        records = lib.records.ordered(vault.read_ledger())
        keyring = lib.vault.Keyring(directory / "thread-keys.json")

        table = executors if executors is not None else build_executors(plugins)
        me = read_device(directory)
        peers, peers_known = read_peers(lib, peers_path(directory, plugins))
        trusted = trust_check(peers, peers_known, me)
        if trusted is None:
            log("no peer book names anybody at %s, so §14.4 rule 7 has nothing to "
                "check against this tick" % peers_path(directory, plugins))

        waiting = it.pending(records, runtime=here, now=now, keys=keyring.key,
                             attempt_cap=lambda intent: attempt_cap(it, table, intent),
                             trusted=trusted)

        for intent in waiting.unreadable:
            # §14.4 rule 6: an intent whose payload will not open is left
            # alone — not answered, not run, not guessed at. Its thread key
            # may simply not have arrived yet, and a §13.3 plaintext body is
            # unreadable here for the same reason: it is not ours to guess at.
            report.skipped_unreadable += 1
            log("intent %s (%s) will not open with the key held for its thread; left alone"
                % (intent.id, intent.kind_of_thing))

        book.forget({i.id for i in waiting.outstanding})

        local = []

        def chain():
            """This Mac's own chain — the device id is minted on first write
            only, so a drain with nothing to write writes nothing at all."""
            if not local:
                local.append(lib.sync.LocalLedger(vault, resolve_device(lib, directory)))
            return local[0]

        # §16, BEFORE the "nothing outstanding" return below. A tick with no
        # intents and one held sentence is the ordinary case — the machine
        # writes says when nobody could be reached, which is a different
        # event from a person queueing work — and putting this after that
        # return would have meant says were only ever spoken on a tick that
        # happened to have an intent in it. That is the shape of §13.3's
        # "shipped green and inert", and it is why this call is here and not
        # twenty lines lower where it reads more naturally.
        sy = says_module(lib)
        drain_says(sy, records, keyring, trusted, chain,
                   deliver_module(plugins), report, here, now)

        if not waiting:
            # No intents outstanding. The stamp is remembered only when there
            # is also nothing unreadable — a key arriving would otherwise
            # never be noticed — and only when the say pass also had nothing
            # left, or a held sentence whose key has not arrived would be
            # skipped for as long as the ledger sat still.
            # `report.says_held` and NOT a list of the things that went
            # wrong. Two clauses used to stand here — `says_unreadable` and
            # `says_spoken` — and between them they covered two of the five
            # ways a say can be left behind. A review reproduced all five and
            # showed the ledger then sitting still for ever, which on a
            # machine whose person is away is the ordinary state and not an
            # edge case; one of them ran past the say's own deadline, so the
            # sentence was recorded expired and nobody ever heard it.
            #
            # `says_spoken` was also a check that could not fire: speaking
            # writes an attempt, which moves the stamp taken BEFORE the read,
            # so `note_idle` could never store a matching one anyway.
            if (stamp is not None and not waiting.unreadable and not book.waiting()
                    and report.says_held == 0):
                book.note_idle(stamp)
            book.save()
            return report

        book.note_busy()

        expired_ids = {i.id for i in waiting.expired}
        exhausted_ids = {i.id for i in waiting.exhausted}
        untrusted_ids = {i.id for i in waiting.untrusted}

        oldest = [None]

        def note_age(intent):
            at = lib.records.parse_timestamp(intent.at or "")
            if at is not None and (oldest[0] is None or at < oldest[0]):
                oldest[0] = at

        try:
            for intent in _ledger_order(records, waiting.outstanding):
                # One intent's failure counts an attempt and moves to the
                # next; it never aborts the batch. Before this, any exception
                # escaped `drain` into `main` *after the connector had already
                # run*, so the work was done and nothing recorded it — which
                # is the same window §14.3a's attempt record closes, arriving
                # by a different road.
                try:
                    answer = answer_without_running(it, intent, expired_ids,
                                                    exhausted_ids, untrusted_ids)
                    if answer is None:
                        answer = carry_out(it, table, intent, book, chain, report, now)
                    if answer is None:
                        continue    # rule 8: left for a later tick
                    state_word, output, error, seconds = answer
                    result = it.append_result(
                        chain(), thread=intent.thread, intent_id=intent.id,
                        state=state_word, key=keyring.key(intent.thread),
                        output=output, error=error, seconds=seconds,
                        after=[intent.id])
                    report.appended.append(result)
                    report.outcomes.append((state_word, intent.kind_of_thing))
                    note_age(intent)
                except (KeyboardInterrupt, SystemExit):
                    raise
                except Exception as exc:
                    # An attempt is already on the chain for anything that
                    # reached the executor, so §14.3a's cap bounds this: a
                    # ledger that will not take the result stops the work
                    # instead of repeating it every five minutes for ever.
                    log("intent %s (%s) could not be finished this tick (%s: %s); "
                        "moving on" % (intent.id, intent.kind_of_thing,
                                       type(exc).__name__, exc))
        finally:
            # §14.4 rule 4, in a `finally`: a Mac that sleeps or a cron that
            # times out mid-batch still tells the person about the work that
            # DID finish. Losing the summary for four completed things
            # because the fifth was interrupted is the silence rule 4 exists
            # to prevent.
            book.save()
            if report.outcomes:
                report.waited = max(0.0, now - oldest[0]) if oldest[0] is not None else 0.0
                report.summary = summarise(it, report.outcomes, report.waited)
                report.sent = send_summary(report.summary, deliver_module(plugins),
                                           sender=sender)
                log("drained %d intent(s): %s" % (len(report.outcomes), report.summary))
        return report


def main(argv=None):
    try:
        drain()
    except SystemExit:
        raise
    except Exception as exc:  # a broken drain is a person's problem, once
        import traceback

        log("failed: %s: %s" % (type(exc).__name__, exc))
        traceback.print_exc(file=sys.stderr)
        return 1
    # Stdout stays empty: the summary was SENT, not printed, and a no_agent
    # job's stdout is delivered to the person as a message.
    return 0


if __name__ == "__main__":
    sys.exit(main())
