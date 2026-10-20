#!/usr/bin/env python3
"""Distil ~/.moe/memory/*.md into Hermes's USER.md and MEMORY.md.

Hermes keeps two small, curated memory files and injects them into every
system prompt (tools/memory_tool.py in hermes-agent):

    $HERMES_HOME/memories/USER.md    who the user is        cap 1,375 chars
    $HERMES_HOME/memories/MEMORY.md  what the agent knows   cap 2,200 chars

Moe's memory is ~37 KB of markdown, most of it a 24 KB soul.md. It cannot be
copied; it has to be distilled. This script does that deterministically — no
model call — because it runs at onboarding, offline, and has to finish in the
time it takes to blink. The heuristics are deliberately dumb and transparent:
take the lines a human wrote as facts (bullets, bolded names, the first
sentences of the "who he is" section), cut each at a sentence boundary, and
pack them until the cap is nearly full. What it leaves behind is not lost —
the source files stay where they are, and Hermes's own memory tool lets the
agent add the rest as it learns which facts actually matter.

On-disk format matches MemoryStore._write_file exactly: entries are stripped,
joined with "\n§\n", no trailing newline. The character count Hermes enforces
is len(that join), so that is the number this script budgets against.

Python 3.9 — this runs on the Mac's system interpreter.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone

ENTRY_DELIMITER = "\n§\n"          # tools/memory_tool.py:78
USER_CHAR_LIMIT = 1375             # tools/memory_tool.py:179
MEMORY_CHAR_LIMIT = 2200           # tools/memory_tool.py:178

# Fill to 90% of the cap, not 100%: Hermes refuses an `add` that would
# overflow, and a store that arrives full leaves the agent no room to write
# anything it learns in its first conversation.
FILL_TARGET = 0.90

SOURCE_FILES = ("about-me.md", "soul.md", "people.md", "projects.md", "preferences.md")
SIDECAR_NAME = "moe-migration.json"

# Per-entry ceilings. A single 1,000-char project note would eat half of
# MEMORY.md on its own; one line per fact is the shape Hermes's memory works
# best with.
USER_ENTRY_MAX = 220
PEOPLE_ENTRY_MAX = 150
PROJECT_ENTRY_MAX = 160
PREF_ENTRY_MAX = 160
SOUL_SENTENCE_MAX = 220

# Sections of people.md whose contents are history, not memory.
SKIP_PEOPLE_SECTIONS = re.compile(r"past|dormant|former|not a person|archive", re.I)
# soul.md sections that describe the person rather than the crawl's own
# caveats. The first heading each regex matches wins.
SOUL_IDENTITY = re.compile(r"who (he|she|they|you) (is|are)|identity|about", re.I)
SOUL_VOICE = re.compile(r"how (he|she|they|you) talk|voice|tone|speak", re.I)
SOUL_SKIP = re.compile(r"before you trust|don'?t know|still don|caveat", re.I)


# ---------------------------------------------------------------------------
# Markdown scraping
# ---------------------------------------------------------------------------

def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""
    except (OSError, UnicodeDecodeError) as e:
        # Say so: a silent empty read would look like "the user has no
        # people.md" rather than "people.md is broken".
        print("warning: could not read %s (%s) — skipped" % (path, e), file=sys.stderr)
        return ""


def sections(text):
    """Yield (heading, body) for each '#'-headed block, in file order.

    Text before the first heading comes back with heading ''."""
    heading = ""
    body = []
    for line in text.split("\n"):
        if line.startswith("#"):
            yield heading, "\n".join(body)
            heading = line.lstrip("#").strip()
            body = []
        else:
            body.append(line)
    yield heading, "\n".join(body)


# A bullet that is a label with nothing after it. The notes Moe ships on a
# fresh install are forms — "- Name:", "- What I do:" — that the person fills
# in, or does not. Measured on the owner's own Mac on 2026-09-20: six of the
# nine entries in USER.md were these labels, seeded on day one and carried
# into every system prompt since, so the model read "Name:" with nothing after
# it for a week and told the person its profile was blank. A label is not a
# fact; an unfilled form line is skipped, whichever file it is in.
PLACEHOLDER = re.compile(r"^[^:]{1,80}:\s*$")


def is_placeholder(entry):
    """True for a bullet that is only a label — "Name:", "What I do:"."""
    return bool(PLACEHOLDER.match(clean(entry)))


def bullets(text):
    """Return top-level '- ' bullets with their wrapped continuation lines
    joined back into one line. Nested bullets are folded into their parent —
    they are almost always elaboration, and one entry per fact is the goal.
    Unfilled form lines (:func:`is_placeholder`) are not bullets at all."""
    out = []
    current = None
    for line in text.split("\n"):
        if line.startswith("- "):
            if current is not None:
                out.append(current)
            current = line[2:].strip()
        elif current is not None and line.strip() and line.startswith((" ", "\t")):
            current += " " + line.strip().lstrip("-").strip()
        else:
            if current is not None:
                out.append(current)
            current = None
    if current is not None:
        out.append(current)
    return [b for b in out if not is_placeholder(b)]


def paragraphs(text):
    """Blank-line-separated prose paragraphs, each unwrapped to one line."""
    out = []
    for block in re.split(r"\n\s*\n", text):
        joined = " ".join(l.strip() for l in block.split("\n") if l.strip())
        if joined and not joined.startswith(("- ", "_", "|", "```")):
            out.append(joined)
    return out


# Terminators that are not sentence ends. "Rabbi Dr. X" and "Sept. 22" are
# common in this corpus; a naive split turns them into three-word entries.
ABBREVIATIONS = re.compile(
    r"\b(?:Dr|Mr|Mrs|Ms|Prof|Rabbi|Rav|R|St|Jr|Sr|Inc|Ltd|Co|vs|etc|approx|No|Sept|Oct|Nov|Dec"
    r"|Jan|Feb|Aug|e\.g|i\.e|[A-Z])\.$")

# Sentences about the crawl itself rather than the person. They read as
# facts to a regex and as noise to the agent.
META_NOISE = re.compile(
    r"\b(this|these|the two|both) (document|file|source)s?\b|\bI (still )?(don'?t|do not) know"
    r"|\bunverified\b|\bsee (above|below)\b", re.I)


def sentences(text):
    """Split on sentence terminators, re-joining after known abbreviations."""
    parts = re.split(r"(?<=[.!?])\s+(?=[A-Z\"'(*])", text)
    out = []
    for p in parts:
        p = p.strip()
        if not p:
            continue
        if out and ABBREVIATIONS.search(out[-1]):
            out[-1] += " " + p
        else:
            out.append(p)
    return out


def take_sentences(text, max_len):
    """As many leading sentences as fit in max_len; at least one, clipped."""
    picked = []
    for s in sentences(text):
        if picked and len(" ".join(picked + [s])) > max_len:
            break
        picked.append(s)
    if not picked:
        return ""
    return clip(" ".join(picked), max_len)


def clean(text):
    """Strip markdown emphasis and collapse whitespace. The bold that made a
    name easy to *find* is four wasted characters once it has been found."""
    text = text.replace("**", "").replace("__", "")
    text = re.sub(r"(?<!\w)_([^_]+)_(?!\w)", r"\1", text)
    # Collapsing whitespace also guarantees an entry never contains the
    # delimiter: Hermes splits on "\n§\n", and a single-line entry has no
    # newline. A bare "§" is safe and is left alone.
    return re.sub(r"\s+", " ", text).strip()


def clip(text, max_len):
    """Truncate at a sentence boundary, else a clause, else a word."""
    if len(text) <= max_len:
        return text
    head = text[:max_len]
    for pat in (r"[.!?](?=\s)", r"[;:—](?=\s)", r","):
        cuts = [m.end() for m in re.finditer(pat, head)]
        # Do not accept a boundary so early that the entry says nothing.
        if cuts and cuts[-1] >= max_len // 2:
            return head[:cuts[-1]].rstrip(",;:— ").rstrip()
    cut = head.rfind(" ")
    if cut < max_len // 2:
        cut = max_len
    return head[:cut].rstrip() + "…"


# ---------------------------------------------------------------------------
# Extraction — one function per target file
# ---------------------------------------------------------------------------

def extract_user(memory_dir):
    """USER.md: identity, work, family, location, how to speak to them.

    Priority order matters because the packer fills top-down:
      1. about-me.md bullets — the user's own one-line facts, highest signal.
      2. soul.md "Who he is" — the leading sentences of each paragraph.
      3. soul.md "How he talks" — the register the agent should match.
    Everything else in soul.md (the shape of his days, what he has not
    resolved, how he decides) is analysis, not profile; it stays in ~/.moe.
    """
    entries = []
    for b in bullets(read_text(os.path.join(memory_dir, "about-me.md"))):
        entries.append(("about-me", clip(clean(b), USER_ENTRY_MAX)))

    soul = read_text(os.path.join(memory_dir, "soul.md"))
    identity, voice = None, None
    for heading, body in sections(soul):
        if not heading or SOUL_SKIP.search(heading):
            continue
        if identity is None and SOUL_IDENTITY.search(heading):
            identity = body
        elif voice is None and SOUL_VOICE.search(heading):
            voice = body
    if identity is None:
        # No recognisable heading: fall back to the first substantive section.
        for heading, body in sections(soul):
            if heading and not SOUL_SKIP.search(heading) and paragraphs(body):
                identity = body
                break
    for src, body, limit in (("soul/identity", identity, 4), ("soul/voice", voice, 2)):
        if not body:
            continue
        kept = 0
        for para in paragraphs(body):
            if kept >= limit:
                break
            text = take_sentences(clean(para), SOUL_SENTENCE_MAX)
            if text and not META_NOISE.search(text):
                entries.append((src, text))
                kept += 1
    return entries


def extract_memory(memory_dir):
    """MEMORY.md: named people, live projects, hard preferences.

    Entries are tagged by source so the packer can give each source a
    guaranteed share — otherwise 24 people would crowd out every project.
    """
    entries = []

    people = read_text(os.path.join(memory_dir, "people.md"))
    for heading, body in sections(people):
        if SKIP_PEOPLE_SECTIONS.search(heading):
            continue
        for b in bullets(body):
            # "**Name** — relationship. More detail." → "Name — relationship."
            entries.append(("people", take_sentences(clean(b), PEOPLE_ENTRY_MAX)))

    projects = bullets(read_text(os.path.join(memory_dir, "projects.md")))
    # Dated entries ("2026-08-28: …") are appended newest-last; the newest
    # are the live ones, so reverse before packing.
    for b in reversed(projects):
        entries.append(("projects", take_sentences(clean(b), PROJECT_ENTRY_MAX)))

    for b in bullets(read_text(os.path.join(memory_dir, "preferences.md"))):
        entries.append(("preferences", take_sentences(clean(b), PREF_ENTRY_MAX)))

    return entries


# ---------------------------------------------------------------------------
# Packing
# ---------------------------------------------------------------------------

def joined_len(entries):
    return len(ENTRY_DELIMITER.join(entries)) if entries else 0


def pack(tagged, cap, shares=None):
    """Choose entries to fit under cap * FILL_TARGET without splitting any.

    Two passes. The first gives every source up to its share of the budget
    (so each source is represented); the second fills whatever is left with
    the remaining entries in priority order. An entry that does not fit is
    skipped rather than truncated further — a fact cut mid-clause is worse
    than a fact left out. Original order is preserved in the output.
    """
    budget = int(cap * FILL_TARGET)
    shares = shares or {}
    chosen = [False] * len(tagged)
    used = 0
    per_source = {}

    def cost_of(idx):
        return len(tagged[idx][1]) + (len(ENTRY_DELIMITER) if used else 0)

    for idx, (src, text) in enumerate(tagged):
        if not text:
            continue
        share = shares.get(src)
        if share is not None and per_source.get(src, 0) + len(text) > share * budget:
            continue
        cost = cost_of(idx)
        if used + cost <= budget:
            chosen[idx] = True
            used += cost
            per_source[src] = per_source.get(src, 0) + len(text)
    for idx, (src, text) in enumerate(tagged):
        if chosen[idx] or not text:
            continue
        cost = cost_of(idx)
        if used + cost <= budget:
            chosen[idx] = True
            used += cost
    picked = [tagged[i] for i in range(len(tagged)) if chosen[i]]
    assert joined_len([t for _, t in picked]) <= budget
    return picked


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

def atomic_write(path, content):
    """Temp file in the same directory + os.replace, so a reader never sees a
    half-written file. Same approach as Hermes's own atomic_write_text."""
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".moe-migrate-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def sha256_file(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            h.update(f.read())
    except OSError:
        return None
    return h.hexdigest()


def source_hashes(memory_dir):
    return {name: sha256_file(os.path.join(memory_dir, name)) for name in SOURCE_FILES}


def load_sidecar(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def summarise(label, picked, cap, considered):
    content = ENTRY_DELIMITER.join(t for _, t in picked)
    by_src = {}
    for src, _ in picked:
        by_src[src] = by_src.get(src, 0) + 1
    print("%s: %d entries, %d/%d chars (%d%%), %d bytes on disk" % (
        label, len(picked), len(content), cap,
        100 * len(content) // cap, len(content.encode("utf-8"))))
    for src in sorted(by_src):
        total = sum(1 for s, _ in considered if s == src)
        print("  %-16s %d of %d" % (src, by_src[src], total))
    return content


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--moe-home", default=os.path.expanduser("~/.moe"))
    ap.add_argument("--hermes-home",
                    default=os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes"))
    ap.add_argument("--force", action="store_true",
                    help="overwrite existing USER.md/MEMORY.md (backed up to .bak)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print what would be written; touch nothing")
    args = ap.parse_args(argv)

    memory_dir = os.path.join(args.moe_home, "memory")
    if not os.path.isdir(memory_dir):
        print("no memory directory at %s — nothing to migrate" % memory_dir, file=sys.stderr)
        return 1

    memories_dir = os.path.join(args.hermes_home, "memories")
    user_path = os.path.join(memories_dir, "USER.md")
    memory_path = os.path.join(memories_dir, "MEMORY.md")
    sidecar_path = os.path.join(args.hermes_home, SIDECAR_NAME)

    hashes = source_hashes(memory_dir)
    previous = load_sidecar(sidecar_path)
    if (previous and previous.get("sources") == hashes
            and os.path.exists(user_path) and os.path.exists(memory_path)
            and not args.force and not args.dry_run):
        print("already migrated on %s, sources unchanged — use --force to redo"
              % previous.get("migrated_at", "?"))
        return 0

    user_entries = extract_user(memory_dir)
    memory_entries = extract_memory(memory_dir)
    # about-me.md is the user's own words about themselves and gets nearly
    # all the room; soul.md (the crawl's inference) only fills what is left.
    user_picked = pack(user_entries, USER_CHAR_LIMIT,
                       shares={"about-me": 0.75, "soul/identity": 0.15, "soul/voice": 0.10})
    # People get the largest share: names and relationships are the facts the
    # agent is least able to rediscover from a single conversation.
    memory_picked = pack(memory_entries, MEMORY_CHAR_LIMIT,
                         shares={"people": 0.45, "projects": 0.30, "preferences": 0.25})

    user_content = summarise("USER.md", user_picked, USER_CHAR_LIMIT, user_entries)
    memory_content = summarise("MEMORY.md", memory_picked, MEMORY_CHAR_LIMIT, memory_entries)

    if args.dry_run:
        print("dry run — nothing written (would write to %s)" % memories_dir)
        return 0

    existing = [p for p in (user_path, memory_path) if os.path.exists(p)]
    if existing and not args.force:
        print("refusing to overwrite: %s (use --force; a .bak is kept)"
              % ", ".join(existing), file=sys.stderr)
        return 2

    for path in existing:
        # os.replace, not copy: the backup is the actual previous file.
        os.replace(path, path + ".bak")
        print("backed up %s → %s.bak" % (os.path.basename(path), os.path.basename(path)))

    atomic_write(user_path, user_content)
    atomic_write(memory_path, memory_content)
    atomic_write(sidecar_path, json.dumps({
        "migrated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "moe_home": args.moe_home,
        "sources": hashes,
        "outputs": {"USER.md": len(user_content), "MEMORY.md": len(memory_content)},
    }, indent=2) + "\n")
    print("wrote %s and %s" % (user_path, memory_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
