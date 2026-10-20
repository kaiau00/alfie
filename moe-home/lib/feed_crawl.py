#!/usr/bin/env python3
"""What a connected service's messages SAY, for the daily learning pass
(learn.sh), read from what the situations engine already fetched — no call
to the service at all (docs/PROACTIVE-MEMORY-STATUS.md #8; the owner,
2026-09-29: "everything in the inbox, and make it cheap").

    feed_crawl.py <source> --new STATE [--max-bytes N]
    feed_crawl.py <source> --commit STATE

``<source>`` is the engine's name for it (``composio/gmail``,
``composio/slack``). It reads ``$MOE_HOME/feed/<source>.jsonl``, which the
five-minute engine fills with every item it read, whole text, quoted replies
and signatures already cut (situations.own_words). So the learning pass pays
only for distilling, never for reading — and only for what it has not read
before: ``--new`` prints the items newer than the source's read position in
STATE and writes the position it would move to beside it; ``--commit``
moves it, once the pass has distilled and merged them (learn.sh). A failed
pass reads the same items again next time; a good one never does.

The feed holds what the engine read since it was switched on (up to 4000
items a source); there is no look back past that.

Cheap before the model sees anything, and none of it a model call:
- automated mail and notifications dropped (the engine's own test);
- one block per conversation, its newest messages only (MAX_PER_THREAD),
  each capped (ITEM_CAP), newest conversations first;
- the whole output capped (--max-bytes, learn.sh's per-source budget).

Prints plain text for distil.py. Stdlib only; writes only its own read
positions.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, Iterable, List

ITEM_CAP = 700
MAX_PER_THREAD = 6
DEFAULT_MAX_BYTES = 200_000
HERE = os.path.dirname(os.path.abspath(__file__))


def moe_home() -> str:
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def _situations():
    spec = importlib.util.spec_from_file_location("situations_for_feed_crawl", os.path.join(HERE, "situations.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def feed_items(source: str, since_days: float, now: float) -> List[Dict[str, Any]]:
    path = os.path.join(moe_home(), "feed", "%s.jsonl" % re.sub(r"[^a-z0-9_-]", "_", source.lower()))
    cut = now - since_days * 86400
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    it = json.loads(line)
                except ValueError:
                    continue
                if isinstance(it, dict) and float(it.get("at") or 0) >= cut:
                    out.append(it)
    except OSError:
        return []
    return out


#: How many item ids a source's read position remembers: the feed keeps at
#: most FEED_KEEP_PER_SOURCE (4000) items a source, so this covers it.
MAX_IDS = 5000


def read_state(path: str) -> Dict[str, List[str]]:
    """source -> the item ids already learned from. Ids, not a time: an item
    can reach the feed after a pass with an older time (the engine's overlap,
    a mail's own Date header), and a time position skipped it for good
    (review 2026-09-29 round 2)."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {k: [str(x) for x in v] for k, v in data.items() if isinstance(v, list)}


def write_state(path: str, data: Dict[str, List[str]]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({k: v[-MAX_IDS:] for k, v in data.items()}, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def render(items: Iterable[Dict[str, Any]], max_bytes: int = DEFAULT_MAX_BYTES) -> str:
    """Conversations as text, newest first, filtered and capped."""
    S = _situations()
    threads: Dict[str, List[Dict[str, Any]]] = {}
    seen = set()
    for it in items:
        text = str(it.get("text") or "").strip()
        frm = it.get("from") if isinstance(it.get("from"), dict) else {}
        if not text or it.get("id") in seen:
            continue
        seen.add(it.get("id"))
        if not frm.get("me") and (S._AUTOMATED.search(text) or S._AUTOMATED.search(str(frm.get("name") or ""))):
            continue
        threads.setdefault(str(it.get("thread") or it.get("id")), []).append(it)
    order = sorted(threads.values(), key=lambda ms: -max(float(m.get("at") or 0) for m in ms))
    out: List[str] = []
    size = 0
    for msgs in order:
        msgs = sorted(msgs, key=lambda m: float(m.get("at") or 0))[-MAX_PER_THREAD:]
        name = str(msgs[-1].get("thread_name") or "").strip() or "a conversation"
        block = ["### %s" % name[:120]]
        for m in msgs:
            frm = m.get("from") if isinstance(m.get("from"), dict) else {}
            who = "me" if frm.get("me") else (frm.get("name") or frm.get("id") or "them")
            day = datetime.fromtimestamp(float(m.get("at") or 0), timezone.utc).strftime("%Y-%m-%d")
            body = " ".join(str(m.get("text") or "").split())[:ITEM_CAP]
            block.append("[%s] %s: %s" % (day, who, body))
        text = "\n".join(block) + "\n\n"
        if size + len(text.encode("utf-8")) > max_bytes:
            break
        out.append(text)
        size += len(text.encode("utf-8"))
    return "".join(out)


def main(argv: List[str]) -> int:
    if len(argv) < 3 or not ("--new" in argv or "--commit" in argv):
        print("usage: feed_crawl.py <source> --new STATE [--max-bytes N] | --commit STATE", file=sys.stderr)
        return 2
    source = argv[1]

    def arg(name, default=None):
        if name in argv and argv.index(name) + 1 < len(argv):
            return argv[argv.index(name) + 1]
        return default
    if "--commit" in argv:
        state_path = arg("--commit")
        pending = read_state(state_path + ".next").get(source)
        if pending:
            data = read_state(state_path)
            known = data.get(source, [])
            seen = set(known)
            data[source] = known + [i for i in pending if i not in seen]
            write_state(state_path, data)
        return 0
    state_path = arg("--new")
    try:
        max_bytes = int(arg("--max-bytes", DEFAULT_MAX_BYTES))
    except ValueError:
        print("feed_crawl: --max-bytes takes a number", file=sys.stderr)
        return 2
    done = set(read_state(state_path).get(source, []))
    items = [it for it in feed_items(source, 10 ** 6, time.time()) if str(it.get("id")) not in done]
    text = render(items, max_bytes)
    # Everything considered counts as read: automated mail is never learned
    # from, and a backlog over the byte cap keeps its newest conversations —
    # the cap is the cost bound, on purpose, not a queue.
    pending = read_state(state_path + ".next")
    pending[source] = [str(it.get("id")) for it in items]
    write_state(state_path + ".next", pending)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
