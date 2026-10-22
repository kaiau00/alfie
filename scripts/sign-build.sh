#!/bin/bash
# Signs a freshly built Memoe.app (build.sh's last step), and answers which
# Developer ID identity this keychain holds (install.sh asks).
#
#   scripts/sign-build.sh <path/to/Memoe.app>   sign it
#   scripts/sign-build.sh --devid-sha1           print the SHA-1 of the
#                                                Developer ID Application
#                                                identity for our team, or
#                                                exit 1 when there is none
#   scripts/sign-build.sh --check-team <app>     install.sh's refusal: when
#                                                this keychain has that
#                                                identity, <app> must carry
#                                                its TeamIdentifier
#
# ## Which identity, and why the order matters
#
# A **local** build (install.sh, catch-up.sh, Memoe Dev) is signed, in order
# of preference, with:
#
#   1. our Developer ID Application identity (team MOE_DEVID_TEAM),
#      chosen by SHA-1 out of `security find-identity -v`, never by display
#      name, so another team's Developer ID in the same keychain is not it;
#   2. the self-signed "Moe Code Signing" certificate, pinned by hash;
#   3. ad-hoc.
#
# It says which. The order is the whole point. macOS partitions a legacy
# keychain item by the creating app's Team ID, and an app signed without one
# (self-signed or ad-hoc) gets `cdhash:<this build>` instead — so every
# rebuild was a stranger to its own consent key, got -25293, deleted it and
# minted another, and the owner was asked to sign in to Google again after
# every catch-up (2026-10-06; docs/KEYS.md). Under the Developer ID the item
# is `teamid:5Y8C3ZR5X6` and its ACL holds identifier + team, which every
# later build of the same app satisfies. It is also the identity the
# published release carries, so a Sparkle update over a catch-up build no
# longer changes who the app is to TCC or the keychain.
#
# Local signatures are fast on purpose: `--timestamp=none` (a timestamp is a
# network round trip, and this Mac's proxy has broken Apple network checks
# before) and no notarization — a local build is never quarantined. And no
# hardened runtime: the runtime is not part of the designated requirement,
# so TCC and the keychain see the same app either way, and turning it on
# here would mean re-signing Sparkle's ad-hoc framework and ~160 seed
# binaries with library-validation entitlements, which is release.sh's job
# and the reason it exists. The app does carry release's entitlements
# (scripts/Moe.entitlements: audio-input, apple-events), so
# `codesign -d --entitlements` reads the same on both; without the runtime
# they are inert, exactly as the mic and Apple Events were for every
# self-signed local build before this.
#
# A **published** build (MOE_RELEASE_IS_PUBLISHED=1, set by
# publish-release.sh) keeps its old order untouched: release.sh re-signs the
# whole bundle with the Developer ID, hardened and timestamped, afterwards,
# and refuses anything else. What this script must still do there is refuse
# to let a build headed for other people go out ad-hoc or under the wrong
# certificate.
#
# Codesign needs unsandboxed Bash on this Mac: errSecInternalComponent from a
# sandboxed shell is the sandbox, never a lost key. Never re-mint anything.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MOE_DEVID_TEAM="${MOE_DEVID_TEAM:-5Y8C3ZR5X6}"
MOE_CERT_ROOT="${MOE_CERT_ROOT:-62682376eacbd0f8a0699d2ef02d7d4e882e6e45}"
ENTITLEMENTS="${MOE_APP_ENTITLEMENTS:-$HERE/Alfie.entitlements}"
IDENTITY="Moe Code Signing"

# The SHA-1 of a *valid* "Developer ID Application: … (TEAM)" identity, or
# nothing. `-v` drops expired, revoked and untrusted ones (a missing Apple G2
# intermediate makes the real one vanish from this list — that falls through
# to "Moe Code Signing", and install.sh then refuses the result loudly).
devid_sha1() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -v want="(${MOE_DEVID_TEAM})\"" '
        /"Developer ID Application: / {
          if (substr($0, length($0) - length(want) + 1) == want) { print $2; exit }
        }'
}

if [ "${1:-}" = --devid-sha1 ]; then
  sha="$(devid_sha1 || true)"
  [ -n "$sha" ] || exit 1
  printf '%s\n' "$sha"
  exit 0
fi

if [ "${1:-}" = --check-team ]; then
  # When this keychain holds our Developer ID, a local build must carry its
  # Team ID. One without it partitions its keychain items by code hash, so
  # the next build cannot read the consent key, deletes it, mints another and
  # asks the owner to sign in to Google again — after every catch-up, which
  # is what 2026-10-06 measured. The signing step above falls back to "Moe
  # Code Signing" quietly when the Developer ID is unusable (a missing G2
  # intermediate, a sandboxed codesign), so the side effect is asserted on
  # the bundle about to be installed, not the choice that was printed.
  BUILT="${2:?usage: scripts/sign-build.sh --check-team <app>}"
  sha="$(devid_sha1 || true)"
  [ -n "$sha" ] || exit 0
  got="$(codesign -dv "$BUILT" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1 || true)"
  if [ "$got" != "$MOE_DEVID_TEAM" ]; then
    echo "✗ $BUILT is not signed with Alfie's Developer ID, and this Mac has it." >&2
    echo "    expected TeamIdentifier=$MOE_DEVID_TEAM (identity $sha)" >&2
    echo "    the build has TeamIdentifier=${got:-not set}" >&2
    echo "  Installed, it could not read the previous build's consent key, so Alfie" >&2
    echo "  would ask you to sign in again, and again after every rebuild. Nothing was" >&2
    echo "  installed. Run ./build.sh from an unsandboxed shell and read its signing line." >&2
    exit 1
  fi
  echo "✓ signed with the Developer ID (TeamIdentifier=$got)"
  exit 0
fi

APP="${1:?usage: scripts/sign-build.sh <path/to/Memoe.app> | --devid-sha1 | --check-team <app>}"
[ -d "$APP" ] || { echo "✗ no app at $APP" >&2; exit 1; }

FOUND_ROOT="$(security find-certificate -c "$IDENTITY" -Z 2>/dev/null \
    | sed -n 's/^SHA-1 hash: //p' | head -1 | tr '[:upper:]' '[:lower:]' || true)"
DEVID_SHA="$(devid_sha1 || true)"
PUBLISHED="${MOE_RELEASE_IS_PUBLISHED:-0}"

wrong_cert() {
  echo "✗ \"$IDENTITY\" in this keychain is not the certificate installed copies trust."
  echo "  installed copies trust: $MOE_CERT_ROOT"
  echo "  this keychain has:      $FOUND_ROOT"
  echo "  Restore the original from ~/moe-signing-cert-BACKUP.p12:"
  echo "    security import ~/moe-signing-cert-BACKUP.p12 -k ~/Library/Keychains/login.keychain-db -P \"<p12 password from its Bitwarden note>\" -T /usr/bin/codesign"
}

KIND=""
if [ "$PUBLISHED" = 1 ]; then
  # Unchanged from before local builds moved to the Developer ID. release.sh
  # replaces this signature with its own; what matters here is the refusals.
  DEVID_NAME="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1 || true)"
  if [ -n "$FOUND_ROOT" ] && [ "$FOUND_ROOT" = "$MOE_CERT_ROOT" ]; then
    echo "› signing as \"$IDENTITY\"…"
    SIGN_AS="$IDENTITY"; KIND=moe-cert
  elif [ -n "$DEVID_NAME" ]; then
    echo "› signing as \"$DEVID_NAME\"…"
    SIGN_AS="$DEVID_NAME"; KIND=devid-published
  elif [ -n "$FOUND_ROOT" ]; then
    wrong_cert
    exit 1
  else
    echo "✗ No stable signing identity in this keychain, and this build is going to other people."
    echo "  An ad-hoc signature changes hash every build, so macOS would ask every person"
    echo "  for Microphone, Automation and Full Disk Access again on this release."
    echo "  Either a Developer ID Application identity, or restore ours:"
    echo "    security import ~/moe-signing-cert-BACKUP.p12 -k ~/Library/Keychains/login.keychain-db -P \"<p12 password from its Bitwarden note>\" -T /usr/bin/codesign"
    exit 1
  fi
  # Inside out: a nested executable signed after its bundle breaks the seal.
  codesign --force --sign "$SIGN_AS" "$APP/Contents/MacOS/moe-confirm"
  codesign --force --sign "$SIGN_AS" "$APP"
  exit 0
fi

# Local.
EXTRA=()
if [ -n "$DEVID_SHA" ]; then
  echo "› signing with the Developer ID (team $MOE_DEVID_TEAM, $DEVID_SHA), local: no timestamp, no notarization…"
  SIGN_AS="$DEVID_SHA"; KIND=devid
  EXTRA=(--entitlements "$ENTITLEMENTS")
elif [ -n "$FOUND_ROOT" ] && [ "$FOUND_ROOT" = "$MOE_CERT_ROOT" ]; then
  echo "› signing as \"$IDENTITY\" — no Developer ID for team $MOE_DEVID_TEAM in this keychain."
  echo "  It has no Team ID, so this build's keychain items (the consent key) are"
  echo "  unreadable to the next build, and Alfie asks you to sign in again after each one."
  SIGN_AS="$IDENTITY"; KIND=moe-cert
elif [ -n "$FOUND_ROOT" ]; then
  wrong_cert
  echo "  (local build — continuing, but this app cannot be released)"
  SIGN_AS="$IDENTITY"; KIND=moe-cert
else
  echo "› signing ad-hoc (run ./scripts/make-signing-cert.sh to stop"
  echo "  macOS asking for permissions again after every rebuild)…"
  SIGN_AS="-"; KIND=adhoc
fi

# Inside out. A nested executable signed after its bundle invalidates the
# bundle's seal, and one never signed at all is only sealed as a resource —
# which for the binary that decides whether your mail goes out is not enough.
codesign --force --timestamp=none --sign "$SIGN_AS" "$APP/Contents/MacOS/moe-confirm"
codesign --force --timestamp=none --sign "$SIGN_AS" ${EXTRA[@]+"${EXTRA[@]}"} "$APP"

# The side effect, not the verdict: a Developer ID signature that came out
# without our Team ID is the cdhash partition back again.
if [ "$KIND" = devid ]; then
  team="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
  if [ "$team" != "$MOE_DEVID_TEAM" ]; then
    echo "✗ signed with the Developer ID, but $APP reports TeamIdentifier=${team:-none}, not $MOE_DEVID_TEAM" >&2
    exit 1
  fi
  echo "✓ signed: TeamIdentifier=$team"
fi
