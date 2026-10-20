"""Two backstops for text read from a connection on a schedule.

Both are BACKSTOPS. The primary control is elsewhere: a background pass
reads metadata only (never rows), an agent turn that sees the text holds
no connector tools, and what it says or saves names the kind of change,
never the record. These exist for the day that discipline slips.

``drop_flagged(text)`` — honour the SOURCE's own marker. Pulse writes
"treat as PII and keep it off shared or scheduled surfaces" into the
description of a column it considers personal; a line carrying that
marker is dropped at READ time, in lib/mcp_read.py, so it reaches neither
memory nor a delivery. Source-authored, so near-zero false positives, and
the same lock for the watch and the gather pass.

``scrub_ids(text)`` — unambiguous shapes only: a US SSN (ddd-dd-dddd) and a
token explicitly labelled SSN / MRN / patient id. Applied at each WRITE
point (deliver.py before the inbox and the fan-out; the gather pass before
a memory write). Deliberately NOT a broad digit-run filter: that would
eat row counts, versions and dates, and lull everyone into thinking there
is a real filter where there is a guess.

Python 3.9+, stdlib only. Import-safe.
"""

import re

#: What a source says about its own field when it means "personal". Pulse's
#: exact phrase first; the shorter forms cover a rewording. Matched
#: case-insensitively against one LINE of read output.
FLAG_MARKERS = (
    "keep it off shared or scheduled surfaces",
    "treat as pii",
    "treat as phi",
)

_SSN = re.compile(r"\b\d{3}-\d{2}-\d{4}\b")
# "SSN: 123456789", "MRN 00123", "patient id: A-99" — a label, then a token.
_LABELLED = re.compile(
    r"\b(?P<label>SSN|social security(?: number)?|MRN|medical record(?: number)?|patient(?: |-)?id|member id)"
    r"(?P<sep>\s*[:#=]?\s*)(?P<val>[A-Za-z0-9-]{3,})",
    re.I,
)


def is_flagged(line):
    low = (line or "").lower()
    return any(m in low for m in FLAG_MARKERS)


def drop_flagged(text):
    """Every line carrying a source PII marker is removed, with a stub in its
    place so a reader (and a diff) can see something was there. Lines are
    the unit because that is how search_schema renders a column: one line,
    name, type, description."""
    out = []
    dropped = 0
    for line in (text or "").splitlines():
        if is_flagged(line):
            dropped += 1
            continue
        out.append(line)
    if dropped:
        out.append("[%d field(s) the source marks as personal were left out]" % dropped)
    return "\n".join(out)


def scrub_ids(text):
    """SSN shapes and explicitly labelled identifiers become '•••'."""
    text = _SSN.sub("•••-••-••••", text or "")
    return _LABELLED.sub(lambda m: "%s%s•••" % (m.group("label"), m.group("sep")), text)
