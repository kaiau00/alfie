#!/bin/bash
# Is the Hermes seed the Hermes the installer pins? build.sh asks before it
# bundles one.
#
#   scripts/check-hermes-seed-commit.sh <seed-dir> <install-hermes.sh>
#
# The seed inside 0.3.12 was staged before the pin moved — no GitHub in the
# catalogue, no CLI lane for the helper model (so "I can't see your screen;
# every tool comes back dead"), none of the relay work — and nothing in the
# build could tell, because a seed carries no version anywhere the build
# reads. stage-hermes-seed.sh now writes hermes-agent/.moe-seed-commit from
# the checkout it staged; this compares that stamp with the sha on the
# installer's pin line, the same line HermesPin.parse and
# scripts/test-hermes-upgrade.sh read:
#
#     HERMES_COMMIT="${HERMES_COMMIT-<40 hex>}"
#
# A seed with NO stamp is refused, not passed: every seed staged before the
# stamp existed — the one in 0.3.12 among them — has none, and a gate that
# only fired on a stamp that differs would have let exactly that seed
# through again. Unknown is not the same as right.
set -u
SEED="${1:?seed directory}"
INSTALLER="${2:?path to install-hermes.sh}"

pin="$(sed -n 's/^HERMES_COMMIT="\${HERMES_COMMIT-\([0-9a-f]\{40\}\)}"$/\1/p' "$INSTALLER" | head -1)"
if [ -z "$pin" ]; then
  echo "✗ cannot read the Hermes pin out of $INSTALLER (no HERMES_COMMIT=\"\${HERMES_COMMIT-<sha>}\" line)" >&2
  exit 1
fi

stamp_file="$SEED/hermes-agent/.moe-seed-commit"
if [ ! -f "$stamp_file" ]; then
  echo "✗ the Hermes seed does not say which Hermes it is: no hermes-agent/.moe-seed-commit." >&2
  echo "  A seed staged from a tree without .git has no stamp, and a seed with no stamp is unknown," >&2
  echo "  not current. Re-stage from a git checkout at the pin: ./scripts/stage-hermes-seed.sh" >&2
  exit 1
fi
stamp="$(tr -d '[:space:]' < "$stamp_file")"
case "$stamp" in
  *[!0-9a-f]*|"") echo "✗ $stamp_file does not hold a commit sha" >&2; exit 1 ;;
esac
if [ ${#stamp} -ne 40 ]; then
  echo "✗ $stamp_file holds '${stamp}', not a full 40-character sha" >&2
  exit 1
fi

if [ "$stamp" != "$pin" ]; then
  echo "✗ the Hermes seed is at ${stamp:0:10} but the installer pins ${pin:0:10}." >&2
  echo "  Shipping it would hand every downloader a Hermes the app was not built for, with no way" >&2
  echo "  to move it forward (a seed copy has no .git). Re-stage at the pin: ./scripts/stage-hermes-seed.sh" >&2
  exit 1
fi
echo "  hermes:  seed is the pinned Hermes (${pin:0:10})"
# The half a shipper cannot see from here. This gate is about the seed a FRESH
# download gets, and it always passes at ship time because the seed was just
# re-staged. Existing Macs are moved by scripts/refresh-hermes-seed.sh, which
# refuses any range that changes uv.lock / pyproject.toml / .python-version —
# so a bump of that kind ships to new users and reaches nobody who already has
# Moe, loudly on their Mac and silently here. install-hermes.sh's HERMES_COMMIT
# comment carries the one command that answers it.
echo "           (existing installs move by source refresh only — a pin whose range"
echo "            touches uv.lock/pyproject.toml/.python-version reaches new Macs only)"
exit 0
