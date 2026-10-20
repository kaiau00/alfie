#!/usr/bin/env python3
"""The checks behind open loops: tier 0, no model (docs/LOOPS.md §2–3).

Every five minutes Hermes runs this as a ``no_agent`` job. It reads the
open-loop ledger, finds the loops whose ``check`` is due, runs each one, and
records what it saw. That is the whole job: a poll that costs nothing until
the world moves, and then costs one line in a file.

    "You spoke about a flight; it checks that flight a day later and says
    'I saw you didn't book this, the price went up.'"

A check is ``{"via": "url", "url": …, "find": <regex>, "every": "6h"}``,
attached by the brain in the person's own turn (``moe_followups open``).
Only ``url`` exists so far. It is a conditional GET — ``If-None-Match`` and
``If-Modified-Since`` from the last fetch, so an unchanged page is a 304 and
no body at all — and the bit ``find`` matches (or the whole page, tags
stripped, when there is no ``find``) is what gets hashed. Same hash: ``seen``
is rewritten with a fresh stamp and nothing else happens; the monitor's
digest ignores ``seen`` on purpose. Different: ``deliver.note_seen`` marks
the loop ``changed`` and pulls it due, and the proactive pass takes it from
there on its next tick.

What this script must not do, and why:

* **Print.** A ``no_agent`` job's stdout IS the message to the person.
  Everything here goes to stderr, which Hermes keeps only when the run
  fails. A check that could not be made is a retry next tick, never a
  sentence on the island.
* **Write the ledger itself.** ``deliver.py`` owns the ledger's lock and
  its atomic write; this imports it from ``$HERMES_HOME/plugins/moe-screen``
  the way ``moe-drain-intents.py`` imports its siblings, and calls the one
  function written for it.
* **Fetch anything it was not given.** No redirects off the given host's
  scheme, a 256 KiB cap, a 20 s timeout, and a plain user agent. The URL is
  whatever the brain wrote down from the conversation; the page is
  somebody else's words and is treated as bytes to hash and an excerpt to
  print, never as text to act on.
* **Poll too hard.** ``every`` is floored at fifteen minutes by ``deliver.py``
  when the check is stored, and again here when it is read.

Off switches: none of its own, deliberately. It runs no model, so the
Background thinking switch does not apply; a person who does not want a
loop watched closes it. ``nudges: false`` still silences what the pass
would SAY; the check keeps the ledger true.
"""

import hashlib
import html
import importlib.util
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

JOB_NAME = "moe-loop-check"
TIMEOUT = 20
MAX_BYTES = 256 * 1024
USER_AGENT = "Moe/1 (a personal assistant checking a page its person looked at)"
#: Per run, so a ledger full of watches cannot hold the tick for minutes.
MAX_CHECKS_PER_RUN = 12
#: Where the last conditional-GET validators live. Not in the ledger: they
#: are this script's own bookkeeping, and an ETag is not something the
#: monitor should ever print.
STATE_FILE = "loop-check.json"
_TAG = re.compile(r"<[^>]+>")
_WS = re.compile(r"\s+")


def log(message):
    """To stderr, never stdout: stdout is delivered to the person."""
    sys.stderr.write("%s: %s\n" % (JOB_NAME, message))


def moe_home():
    return Path(os.environ.get("MOE_HOME") or "~/.moe").expanduser()


def hermes_home():
    return Path(os.environ.get("HERMES_HOME") or "~/.hermes").expanduser()


def load_deliver():
    """``deliver.py`` from the moe-screen plugin beside this Hermes, or None.

    Absent between an install and the next app launch, or on a Hermes that
    has not been configured yet. Then there is nothing to write to and the
    tick is a no-op, said once to stderr."""
    path = hermes_home() / "plugins" / "moe-screen" / "deliver.py"
    override = os.environ.get("MOE_DELIVER_PY")
    if override:
        path = Path(override)
    if not path.is_file():
        log("no moe-screen plugin at %s — nothing to check against" % path)
        return None
    try:
        spec = importlib.util.spec_from_file_location("moe_screen_deliver", str(path))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception as e:  # noqa: BLE001
        log("moe-screen's deliver.py will not import: %s: %s" % (type(e).__name__, e))
        return None


def tell_failed_jobs(deliver, now):
    """``routine_health.tell_failures`` over Hermes's job records. The
    module sits beside ``deliver.py`` in the plugin; loaded the same way,
    and a missing or broken one is a stderr line, never a failed tick."""
    try:
        path = Path(getattr(deliver, "__file__", "") or "").parent / "routine_health.py"
        if not path.is_file():
            log("no routine_health.py beside deliver.py — failed jobs not told")
            return []
        spec = importlib.util.spec_from_file_location("moe_screen_routine_health", str(path))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        told = mod.tell_failures(mod.read_jobs(str(hermes_home())), deliver, now=now)
        if told:
            log("told the person about failed job(s): %s" % ", ".join(told))
        return told
    except Exception as e:  # noqa: BLE001
        log("telling failed jobs failed: %s: %s" % (type(e).__name__, e))
        return []


def state_path(deliver):
    return Path(deliver.open_dir()) / STATE_FILE


def read_state(deliver):
    try:
        with open(state_path(deliver), encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write_state(deliver, state):
    """Atomic and 0600 like everything else in proactive/. Never raises:
    losing the validators costs one full fetch."""
    path = state_path(deliver)
    tmp = str(path) + ".tmp.%d" % os.getpid()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f, sort_keys=True)
        os.chmod(tmp, 0o600)
        os.replace(tmp, str(path))
    except OSError as e:
        log("could not write %s: %s" % (path, e))
        try:
            os.unlink(tmp)
        except OSError:
            pass


def parse_stamp(text):
    text = str(text or "").strip()
    if not text:
        return None
    if text[-1:] in ("Z", "z"):
        text = text[:-1] + "+00:00"
    try:
        when = datetime.fromisoformat(text)
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        return when.astimezone(timezone.utc)
    except (ValueError, OverflowError, OSError):
        return None


def due(entry, deliver, now):
    """Is this loop's check due? No check, or one that ran within its
    `every`, is not."""
    minutes = deliver.check_minutes(entry)
    if not minutes:
        return False
    seen = entry.get("seen")
    at = parse_stamp(seen.get("at")) if isinstance(seen, dict) else None
    if at is None:
        return True
    return now - at >= timedelta(minutes=minutes)


def fetch(url, validators):
    """(status, body_text, new_validators). 304 → body None.

    Only http(s), and a redirect may not change the scheme: the URL came
    out of a conversation and a page that bounces to ``file:`` is not a page
    to follow."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT,
                                                "Accept": "text/html,application/json,text/plain;q=0.9,*/*;q=0.5"})
    etag = validators.get("etag")
    modified = validators.get("last_modified")
    if etag:
        req.add_header("If-None-Match", etag)
    if modified:
        req.add_header("If-Modified-Since", modified)

    class _Redirects(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req_, fp, code, msg, headers, newurl):
            if not str(newurl).lower().startswith(("http://", "https://")):
                raise urllib.error.HTTPError(newurl, code, "refusing a non-http redirect", headers, fp)
            return urllib.request.HTTPRedirectHandler.redirect_request(
                self, req_, fp, code, msg, headers, newurl)

    opener = urllib.request.build_opener(_Redirects())
    try:
        with opener.open(req, timeout=TIMEOUT) as resp:
            raw = resp.read(MAX_BYTES + 1)
            info = resp.info()
            new = {"etag": info.get("ETag") or "", "last_modified": info.get("Last-Modified") or ""}
            charset = info.get_content_charset() or "utf-8"
            body = raw[:MAX_BYTES].decode(charset, "replace")
            return resp.status, body, new
    except urllib.error.HTTPError as e:
        if e.code == 304:
            return 304, None, validators
        raise


def excerpt_of(body, find):
    """The bit that matters: the first `find` match (its first group when it
    has one), or the whole page with tags gone. One line, bounded."""
    text = body
    if find:
        try:
            m = re.search(find, body, re.I | re.S)
        except re.error:
            m = None
        if not m:
            return ""
        text = m.group(1) if m.groups() else m.group(0)
    text = html.unescape(_TAG.sub(" ", text))
    return _WS.sub(" ", text).strip()[:2000]


def main():
    deliver = load_deliver()
    if deliver is None:
        return 0
    now = datetime.now(timezone.utc)
    # The morning: anything quiet hours held for the person's phone goes
    # out now, once. Before the checks, so a change found this tick is not
    # queued behind last night's.
    try:
        release = getattr(deliver, "release_held", None)
        if release is not None:
            release(now=now)
    except Exception as e:  # noqa: BLE001
        log("release of held messages failed: %s" % e)
    # The person's own jobs that failed and that they have not heard about
    # (ticket #15): one card per failure, with something to tap. Before the
    # checks, and whether or not any loop is due.
    tell_failed_jobs(deliver, now)
    loops = deliver.read_open()
    todo = [(slug, entry) for slug, entry in sorted(loops.items())
            if isinstance(entry, dict) and due(entry, deliver, now)]
    if not todo:
        return 0
    state = read_state(deliver)
    ran = 0
    for slug, entry in todo[:MAX_CHECKS_PER_RUN]:
        check = entry.get("check") or {}
        url = str(check.get("url") or "")
        if not url.lower().startswith(("http://", "https://")):
            log("%s: check has no http url — skipped" % slug)
            continue
        validators = state.get(slug) if isinstance(state.get(slug), dict) else {}
        try:
            status, body, new = fetch(url, validators)
        except Exception as e:  # noqa: BLE001 — a failed fetch is a retry next tick
            log("%s: %s: %s" % (slug, type(e).__name__, str(e)[:120]))
            continue
        ran += 1
        seen = entry.get("seen") if isinstance(entry.get("seen"), dict) else {}
        if status == 304 or body is None:
            # Nothing moved, by the server's own word. Stamp it and move on.
            deliver.note_seen(slug, seen.get("hash") or "", seen.get("excerpt") or "", now=now)
            continue
        excerpt = excerpt_of(body, check.get("find"))
        digest = hashlib.sha256(excerpt.encode("utf-8", "replace")).hexdigest()[:16]
        state[slug] = {k: v for k, v in (new or {}).items() if v}
        before = str(seen.get("hash") or "")
        if not before:
            # First look: a baseline, not a change.
            deliver.note_seen(slug, digest, excerpt, now=now)
        elif digest != before:
            deliver.note_seen(slug, digest, excerpt, now=now, changed=True,
                              was=str(seen.get("excerpt") or ""))
            log("%s: changed" % slug)
        else:
            deliver.note_seen(slug, digest, excerpt, now=now)
    # Validators for loops that are gone go with them.
    state = {s: v for s, v in state.items() if s in loops}
    write_state(deliver, state)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001 — never a traceback on the island
        log("failed: %s: %s" % (type(e).__name__, e))
        sys.exit(1)
