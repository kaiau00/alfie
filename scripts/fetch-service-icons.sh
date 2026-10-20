#!/bin/bash
# Bundle the marks for services reached through Composio.
#
# Resources/ServiceIcons/ already carries brand marks (gmail.png, drive.png,
# sheets.png …) and ServiceIcon draws them by NAME. A Composio row is named
# for its toolkit slug, so a file called `googlecalendar.png` is found with
# no mapping code at all — which is why these are saved under the slug and
# not under a prettier name.
#
# Fetched once and committed, deliberately, rather than loaded at runtime:
# a Connections screen that reaches the network to draw an icon is slow when
# the network is slow, blank when it is absent, and a tracking beacon for
# whoever hosts the image. The marks are small and they do not change.
#
# Run it again to pick up a service added later. Existing files are left
# alone unless --force, so a hand-corrected mark is never clobbered.
set -u
cd "$(dirname "$0")/.." || exit 1
OUT=Resources/ServiceIcons
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# The services the pane shows before you search: every toolkit the snapshot
# marks `managed_auth` (scripts/snapshot-composio-catalog.sh writes the flag;
# docs/COMPOSIO.md §The rule explains it). Not a list typed here — re-run the
# snapshot and this follows it.
#
# It used to read `composio.py list`, which is the SESSION's first page —
# twenty services on the Mac that happened to run it, and nothing at all on a
# Mac with no Composio key. So the marks that shipped were whichever twenty
# one developer's session returned, and every other brokered row drew as a
# coloured letter. The snapshot is the same list the release ships to a
# stranger, so fetching against it is fetching against what people will see.
SLUGS=$(/usr/bin/python3 -c 'import json,sys
try:
    doc = json.load(open("moe-home/connectors/composio-catalog.json"))
    want = {k["slug"] for k in doc["toolkits"] if k.get("managed_auth")}
    # And every service the popularity ranking lists before search
    # (composio-ranking.json `top`) — key-paste, always-on and the rest.
    rank = json.load(open("moe-home/connectors/composio-ranking.json"))["toolkits"]
    want |= {s for s, r in rank.items() if r.get("top")}
    print(" ".join(sorted(want)))
except Exception: pass')

# Plus whatever this Mac has actually connected, so a service outside the
# default set still gets its real mark once someone signs into it.
LIVE=$(./moe-home/connectors/composio.py list --json 2>/dev/null \
        | /usr/bin/python3 -c 'import json,sys
try: print(" ".join(r["slug"] for r in json.load(sys.stdin)["connections"] if r.get("connected")))
except Exception: pass')
SLUGS=$(printf '%s %s\n' "$SLUGS" "$LIVE" | tr " " "\n" | grep -v '^$' | sort -u | tr "\n" " ")

if [ -z "${SLUGS// /}" ]; then
  echo "no Composio snapshot and no Composio services configured — nothing to fetch" >&2
  exit 0
fi

got=0 kept=0 failed=0
for slug in $SLUGS; do
  # ServiceIcon tries several extensions; check the ones it would find.
  if [ "$FORCE" != 1 ] && { [ -f "$OUT/$slug.png" ] || [ -f "$OUT/$slug.svg" ]; }; then
    kept=$((kept+1)); continue
  fi
  url="https://logos.composio.dev/api/$slug"
  tmp="${TMPDIR:-/tmp}/icon.$$"
  if ! curl -fsSL --max-time 20 -o "$tmp" "$url" 2>/dev/null; then
    printf '  ✗ %-18s could not fetch\n' "$slug"; failed=$((failed+1)); continue
  fi
  # What came back decides the extension. A file named .png that is really
  # an SVG draws as nothing, and the failure looks like a missing icon
  # rather than a wrong one.
  kind=$(file -b --mime-type "$tmp" 2>/dev/null)
  case "$kind" in
    image/png)      ext=png ;;
    image/jpeg)     ext=jpg ;;
    image/svg+xml|text/xml|text/plain) ext=svg ;;
    *) printf '  ✗ %-18s not an image (%s)\n' "$slug" "$kind"; rm -f "$tmp"; failed=$((failed+1)); continue ;;
  esac
  # An SVG that is actually an HTML error page passes the mime sniff.
  if [ "$ext" = svg ] && ! grep -qi '<svg' "$tmp"; then
    printf '  ✗ %-18s served something that is not an SVG\n' "$slug"; rm -f "$tmp"; failed=$((failed+1)); continue
  fi
  mv "$tmp" "$OUT/$slug.$ext"
  printf '  ✓ %-18s %s\n' "$slug" "$slug.$ext"
  got=$((got+1))
done

echo
printf 'fetched %d, already had %d, failed %d\n' "$got" "$kept" "$failed"
# A slug with no mark is not an error — ServiceIcon falls back to a monogram
# in the service's own colour, which looks deliberate. But it is worth
# naming, because "every service in the default list has its own logo" is a
# claim scripts/test-connections-ui.sh checks and this is where it is earned.
if [ "$failed" -gt 0 ]; then
  echo "the ones above with ✗ draw as a coloured monogram until someone drops a file in $OUT" >&2
fi
