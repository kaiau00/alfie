#!/usr/bin/env python3
"""claimstore from the command line: the Memory page's writes to Hermes's memory.

    cli.py list [--json]                  every live claim, both targets
    cli.py correct <id> "<text>" [--json]  the line, reworded by the person
    cli.py delete <id> [--json]            the line, forgotten by the person
    cli.py neutral [--target user] [--apply] [--json]
                                           first-person-from-Alfie lines ("Prefers
                                           I take action") reworded to name Alfie;
                                           a dry run unless --apply
    cli.py tidied [--json]                 the nightly tidy's changes, last 30 days
    cli.py undo <change> [--json]          one tidy change put back (Restore)
    cli.py revivals [--json]               deleted facts noticed again (To check)
    cli.py revive <id> yes|no [--json]     the person's answer to one of them

Why this exists. ``~/.hermes/memories/USER.md`` and ``MEMORY.md`` are this
plugin's *projection* of the ledger. An editor's change to a file is absorbed
as a new claim, but a line removed from a file is never read as a retraction
(README, "Reconciliation") — so the app could not correct or forget one of
these lines by editing the file: the old line came straight back on the next
projection. It used to hand the change to the model in Chat instead. This
does what the memory tool's ``replace``/``remove`` do, without a model:

  * ``correct``: a ``retract`` of the old claim and an ``assert`` of the new
    text, both on this Mac's device chain (§13.1, the app's ``device.json``),
    the text sealed under ``moe:memory`` when the key is held (§13.4) — the
    same records ``ClaimLedger`` in Sources/MoeLedger/Claims.swift writes, so
    they converge to the cloud machine like any other claim;
  * ``delete``: the ``retract`` alone;
  * then **the projection runs at once**, so USER.md/MEMORY.md are rewritten
    before this returns and the next prompt build sees the change.

The source on both records is ``user:memory-page`` — a person's own word,
which is what may later revive a retracted fact (``store.revives``); the
page only calls this when the person typed.

Output with --json is ONE object, the contract profile.py's verbs use:

    {"ok": true, "action": "correct"|"delete", "id": "<id passed>",
     "claim": {"id", "target", "text", "source", "key"}}      # the new/removed line
    {"ok": false, "action": ..., "id": ..., "error": "..."}   # exit 1 (2: empty text)

Run it with Hermes's interpreter (it needs ``cryptography`` to seal and
Hermes's ``tools.memory_tool`` to project): ``~/.hermes/hermes-agent/.venv/
bin/python ~/.hermes/plugins/claimstore/cli.py list --json``. The ledger is
``$MOE_HOME/ledger`` (``memory.claimstore.ledger_dir`` when set) and the
files are ``$HERMES_HOME/memories``, as for the provider itself.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

PAGE_SOURCE = "user:memory-page"
HERE = Path(__file__).resolve().parent


def _bootstrap() -> None:
    """Make ``claimstore``, its sibling ``moeledger`` and Hermes importable
    when this file is run as a script."""
    for p in (HERE.parent, HERE.parent / "moe-ledger"):
        if str(p) not in sys.path:
            sys.path.insert(0, str(p))
    agent = os.environ.get("MOE_HERMES_AGENT") or str(
        Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes") / "hermes-agent")
    if os.path.isdir(agent) and agent not in sys.path:
        sys.path.append(agent)


def open_store(ledger_dir: Optional[Path] = None, hermes_home: Optional[Path] = None):
    """The store the Mac's provider opens: the ledger dir, this Mac's device,
    the keyring at ``<ledger>/thread-keys.json``, state under HERMES_HOME."""
    import claimstore
    from claimstore.store import ClaimStore

    ledger = Path(ledger_dir) if ledger_dir else claimstore.resolve_ledger_dir()
    home = Path(hermes_home) if hermes_home else Path(
        os.environ.get("HERMES_HOME") or Path.home() / ".hermes").expanduser()
    keyring = None
    lib = claimstore._moeledger()
    if lib is not None:
        try:
            keyring = lib.vault.Keyring(ledger / "thread-keys.json")
        except Exception:
            keyring = None
    return ClaimStore(ledger, state_dir=home, keyring=keyring)


def _targets() -> List[str]:
    import claimstore
    return claimstore.resolve_targets()


def _row(live) -> Dict[str, Any]:
    return {"id": live.id, "target": live.target, "text": live.text,
            "source": live.source, "key": live.key}


def live_claims(store, targets: Sequence[str]) -> List[Dict[str, Any]]:
    """Every live claim this reader can open, USER first, in ledger order,
    each marked with whether it is in the file the prompt reads."""
    from claimstore import projection

    out = []
    for target in sorted(targets, key=lambda t: 0 if t == "user" else 1):
        try:
            in_file = set(projection.parse_entries(
                projection.memory_path(target).read_text(encoding="utf-8")))
        except OSError:
            in_file = set()
        for live in store.resolve(target).live:
            row = _row(live)
            row["in_file"] = live.text in in_file
            out.append(row)
    return out


def _find(store, cid: str, targets: Sequence[str]):
    for target in targets:
        for live in store.resolve(target).live:
            if live.id == cid:
                return live
    return None


def _project(store, targets: Sequence[str]) -> None:
    from claimstore.projection import project_all
    project_all(store, targets)


def correct(store, cid: str, text: str, targets: Sequence[str]) -> Optional[Dict[str, Any]]:
    """Retract ``cid`` and assert ``text`` in its place, then re-project.
    None for an id that is not live; ValueError for empty text."""
    from claimstore.store import claim_id

    text = " ".join((text or "").split())
    if not text:
        raise ValueError("empty correction")
    old = _find(store, cid, targets)
    if old is None:
        return None
    new_id = claim_id(old.target, text)
    if new_id != old.id:
        # Both records name what this device has seen, so the retraction is
        # causally before the assert and a peer resolves them the same way.
        store.retract_id(old.target, old.id, source=PAGE_SOURCE)
        store.assert_claim(old.target, text, source=PAGE_SOURCE)
    _project(store, targets)
    now = _find(store, new_id, targets)
    return _row(now) if now is not None else {"id": new_id, "target": old.target, "text": text,
                                               "source": PAGE_SOURCE, "key": None}


def delete(store, cid: str, targets: Sequence[str]) -> Optional[Dict[str, Any]]:
    old = _find(store, cid, targets)
    if old is None:
        return None
    store.retract_id(old.target, old.id, source=PAGE_SOURCE)
    _project(store, targets)
    return _row(old)


# -- first person, from Moe -----------------------------------------------------
#
# USER.md is written by the model, about the person, and before 2026-09-22
# nothing told it which voice to use; the owner's read "Prefers I take action
# over explaining: wants me to say what I'm doing once". On the Memory page
# "I" reads as the person. In USER.md ("user" target) every I/me/my is Moe —
# the target is facts about the person, written by the assistant — so naming
# Moe is exact. MEMORY.md is NOT rewritten by default: it holds the person's
# own words too ("Never send anything on my behalf without reading it to me
# first" — there "my" is theirs), and a regex cannot tell the two apart.

_FIRST = [
    (r"\bI'm\b", "Alfie is"), (r"\bI am\b", "Alfie is"), (r"\bI've\b", "Alfie has"),
    (r"\bI'll\b", "Alfie will"), (r"\bI'd\b", "Alfie would"), (r"\bI\b", "Alfie"),
    (r"\bmyself\b", "itself"), (r"\bme\b", "Alfie"), (r"\bmy\b", "Alfie's"), (r"\bMy\b", "Alfie's"),
]


def neutral(text: str) -> str:
    """"Prefers I take action over explaining: wants me to say what I'm
    doing once" → "Prefers Alfie take action over explaining: wants Alfie to say
    what Alfie is doing once". Quoted text is left as it is."""
    parts = re.split(r'("[^"]*"|“[^”]*”)', text)
    for i in range(0, len(parts), 2):
        for pat, rep in _FIRST:
            parts[i] = re.sub(pat, rep, parts[i])
    return "".join(parts)


def neutral_plan(store, targets: Sequence[str]) -> List[Dict[str, str]]:
    """The lines ``neutral`` would change: [{"id", "target", "from", "to"}]."""
    plan = []
    for target in targets:
        for live in store.resolve(target).live:
            new = neutral(live.text)
            if new != live.text:
                plan.append({"id": live.id, "target": target, "from": live.text, "to": new})
    return plan


def main(argv: Optional[Sequence[str]] = None, store=None) -> int:
    ap = argparse.ArgumentParser(description="Hermes's memory, as the Memory page edits it")
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("list")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("correct")
    p.add_argument("id")
    p.add_argument("text")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("delete")
    p.add_argument("id")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("neutral")
    p.add_argument("--target", action="append", choices=("user", "memory"))
    p.add_argument("--apply", action="store_true")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("tidied")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("undo")
    p.add_argument("change")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("revivals")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("revive")
    p.add_argument("id")
    p.add_argument("answer", choices=("yes", "no"))
    p.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    if not args.cmd:
        ap.print_help()
        return 2
    store = store if store is not None else open_store()
    targets = _targets()

    if args.cmd == "list":
        rows = live_claims(store, targets)
        if args.json:
            print(json.dumps(rows, ensure_ascii=False))
        else:
            for r in rows:
                print("%s  %-6s %s" % (r["id"], r["target"], r["text"]))
        return 0

    if args.cmd in ("tidied", "revivals", "undo", "revive"):
        from claimstore import tidy
        if args.cmd == "tidied":
            rows = tidy.recent()
        elif args.cmd == "revivals":
            rows = tidy.revivals(store, targets)
        elif args.cmd == "undo":
            rows = tidy.undo(store, args.change, targets)
        else:
            rows = tidy.answer_revival(store, args.id, args.answer == "yes", targets)
        if rows is None:
            what = "nothing to put back for %s" % (getattr(args, "change", None) or args.id)
            if args.json:
                print(json.dumps({"ok": False, "action": args.cmd, "error": what}))
            else:
                print(what, file=sys.stderr)
            return 1
        if args.json:
            print(json.dumps(rows if isinstance(rows, list) else {"ok": True, "action": args.cmd,
                                                                    "change": rows},
                             ensure_ascii=False))
        else:
            print(json.dumps(rows, ensure_ascii=False, indent=1))
        return 0

    if args.cmd == "neutral":
        plan = neutral_plan(store, args.target or ["user"])
        if args.apply:
            for step in plan:
                store.retract_id(step["target"], step["id"], source=PAGE_SOURCE)
                store.assert_claim(step["target"], step["to"], source=PAGE_SOURCE)
            if plan:
                _project(store, targets)
        if args.json:
            print(json.dumps({"ok": True, "applied": bool(args.apply), "changes": plan},
                             ensure_ascii=False))
        else:
            for step in plan:
                print("- %s\n+ %s\n" % (step["from"], step["to"]))
            print("%d line(s) %s" % (len(plan), "rewritten" if args.apply
                                     else "would change — run again with --apply"))
        return 0

    def say(obj: Dict[str, Any], code: int, human: str) -> int:
        if args.json:
            print(json.dumps(obj, ensure_ascii=False))
        else:
            print(human, file=sys.stderr if code else sys.stdout)
        return code

    try:
        if args.cmd == "correct":
            row = correct(store, args.id, args.text, targets)
        else:
            row = delete(store, args.id, targets)
    except ValueError as e:
        return say({"ok": False, "action": args.cmd, "id": args.id, "error": str(e)}, 2, str(e))
    if row is None:
        what = "no memory line with id %s" % args.id
        return say({"ok": False, "action": args.cmd, "id": args.id, "error": what}, 1, what)
    return say({"ok": True, "action": args.cmd, "id": args.id, "claim": row}, 0,
               "%s %s: %s" % (args.cmd, row["id"], row["text"]))


if __name__ == "__main__":
    _bootstrap()
    from claimstore.cli import main as _main   # the package's copy, so imports resolve
    sys.exit(_main())
