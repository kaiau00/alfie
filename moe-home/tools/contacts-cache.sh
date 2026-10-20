#!/bin/bash
# Builds a phone-number → name map from your Mac's Contacts.
#
# WhatsApp's linked-device protocol doesn't send your address book, so
# one-to-one chats arrive labelled with a bare number. Your Mac already knows
# who those numbers are; this just puts the two together, locally.
#
# Numbers are keyed on their last 9 digits, because the same person appears as
# +1 (555) 010-4477, 5550104477 and 15550104477 depending on who typed it.
set -uo pipefail

OUT="${1:-$HOME/.moe/contacts.json}"
mkdir -p "$(dirname "$OUT")"

/usr/bin/perl -e 'alarm 90; exec @ARGV' osascript <<'AS' 2>/dev/null > "$OUT.raw"
set out to ""
tell application "Contacts"
  repeat with p in people
    try
      set n to name of p
      repeat with ph in phones of p
        set out to out & n & "\t" & (value of ph) & linefeed
      end repeat
    end try
  end repeat
end tell
return out
AS

python3 - "$OUT.raw" "$OUT" <<'PY'
import json, re, sys
raw_path, out_path = sys.argv[1], sys.argv[2]
mapping = {}
try:
    text = open(raw_path, encoding="utf-8", errors="replace").read()
except OSError:
    text = ""

for line in text.splitlines():
    if "\t" not in line:
        continue
    name, number = line.split("\t", 1)
    name = name.strip()
    digits = re.sub(r"\D", "", number)
    if not name or len(digits) < 7:
        continue
    # Last 9 digits is enough to identify a person and survives country codes
    # and local formatting alike.
    key = digits[-9:]
    mapping.setdefault(key, name)

json.dump(mapping, open(out_path, "w"), ensure_ascii=False, indent=0)
print(f"{len(mapping)} numbers mapped to names")
PY
rm -f "$OUT.raw"
