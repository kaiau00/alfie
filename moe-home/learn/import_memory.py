#!/usr/bin/env python3
"""What another AI assistant remembers about the person, brought into Moe's
memory (status #9; the owner, 2026-09-29: "copy a prompt, paste the answer";
"keep it, show it under To check").

    import_memory.py chatgpt|claude < pasted.txt

The person asks ChatGPT or Claude to list what it remembers about them
(`PROMPT`, the words Settings shows with a Copy button) and pastes the
answer. It is distilled like any learned source — the same distil.py with
its own prompt (prompts/learn-import.md), no tools, the same sensitive-data
and instruction filters — and merged into the profile under the source
`chatgpt` or `claude`. So every fact is marked where it came from, and one
that disagrees with something Moe already knows becomes a question under
Memory › To check (merge.py), never a silent overwrite. A topic the person
settled themselves is never touched.

Prints one JSON object: {"added", "refreshed", "replaced", "questions"} or
{"error"}. Exit 0 on success. The pasted text is kept only for the length
of the run (mode 600, deleted).
"""
import json
import os
import signal
import subprocess
import sys
import tempfile

SOURCES = {"chatgpt": "ChatGPT", "claude": "Claude"}
MAX_CHARS = 60_000
PROMPT = ("Please list everything you remember about me: your saved memories, and any details "
          "about me you have kept from our past conversations. Write it as a plain list, one fact "
          "per line, as it is stored, with a date where you have one. No commentary, no headings.")

HERE = os.path.dirname(os.path.abspath(__file__))


DISTIL_TIMEOUT = 600
MERGE_TIMEOUT = 240        # together under the app's 900 s for the whole run


def _stop(_sig, _frame):
    # The app ends a run that took too long with SIGTERM; raising lets the
    # `finally` below delete the pasted text (review 2026-09-29).
    raise SystemExit(143)


def main(argv):
    signal.signal(signal.SIGTERM, _stop)
    if len(argv) != 2 or argv[1] not in SOURCES:
        print(json.dumps({"error": "usage: import_memory.py chatgpt|claude < pasted.txt"}))
        return 2
    source = argv[1]
    text = sys.stdin.read()
    text = text.strip()[:MAX_CHARS]
    if len(text) < 20:
        print(json.dumps({"error": "That's empty. Paste what %s answered." % SOURCES[source]}))
        return 2
    work = tempfile.mkdtemp(prefix="moe-import-")
    raw, digest = os.path.join(work, "pasted.txt"), os.path.join(work, "digest.json")
    try:
        with open(raw, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(raw, 0o600)
        py = sys.executable
        d = subprocess.run([py, os.path.join(HERE, "distil.py"), source, raw, "--out", digest,
                            "--profile", "import"], capture_output=True, text=True, timeout=DISTIL_TIMEOUT)
        if d.returncode != 0 or not os.path.exists(digest):
            print(json.dumps({"error": "Moe couldn't read it just now (is Moe's thinking part running?). "
                                       "Nothing was changed."}))
            sys.stderr.write(d.stderr[-2000:])
            return 1
        # --no-llm: every disagreement with another source becomes a question
        # under To check. Letting a model "resolve" it could archive a line
        # from the person's own mail in favour of an old note from another
        # assistant, and the owner's rule is: keep it, and ask.
        m = subprocess.run([py, os.path.join(HERE, "merge.py"), digest, "--no-llm"], capture_output=True,
                           text=True, timeout=MERGE_TIMEOUT)
        if m.returncode != 0:
            print(json.dumps({"error": "Moe read it but couldn't save it. Nothing was changed."}))
            sys.stderr.write(m.stderr[-2000:])
            return 1
        try:
            summary = json.loads(m.stdout)
        except ValueError:
            summary = {}
        try:
            with open(digest, encoding="utf-8") as f:
                d = json.load(f)
            left_out = int(d.get("sensitive_dropped") or 0) + int(d.get("dropped_claims") or 0)
        except (OSError, ValueError, TypeError):
            left_out = 0
        out = {k: int(summary.get(k) or 0) for k in ("added", "refreshed", "replaced", "conflicts",
                                                     "skipped", "questions")}
        out["left_out"] = left_out
        print(json.dumps(out))
        return 0
    finally:
        for p in (raw, digest):
            try:
                os.remove(p)
            except OSError:
                pass
        try:
            os.rmdir(work)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main(sys.argv))
