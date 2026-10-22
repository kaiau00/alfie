#!/bin/bash
# Signal support, fetched the first time somebody connects Signal — never
# before, and never for anybody who does not.
#
#   fetch-signal-cli.sh            fetch, verify and unpack (idempotent)
#   fetch-signal-cli.sh --check    exit 0 when a verified copy is ready
#   fetch-signal-cli.sh --paths    print JAVA_HOME=… and SIGNAL_CLI=… (exit 1 if not ready)
#
# **Why a download and not part of the app** (docs/SIGNAL.md §2, measured
# 2026-09-11): signal-cli 0.14.8 is 125.4 MB and needs Java 25; together with
# a Java runtime that is +152–163 MB on a 1.3 GB download that everybody pays
# for and few will use. Fetched here it costs nothing to anyone who never
# connects Signal, and 181.6 MB, once, to someone who does.
#
# **What is fetched, exactly, and unmodified:**
#   - signal-cli 0.14.8 (GPL-3.0), the release tarball from AsamK/signal-cli
#     on GitHub. Its libsignal-client jar (AGPL-3.0) carries the macOS arm64
#     native library (libsignal_jni_aarch64.dylib, ad-hoc signed) and extracts
#     it to a temp directory at run time (libsignal's Native.copyToTempDirAndLoad).
#   - Eclipse Temurin JRE 25.0.4.1+1 for macOS aarch64 (GPL-2.0 with the
#     Classpath Exception), from Adoptium's release on GitHub.
# Neither is changed in any way: no file removed from a jar, nothing
# re-signed. That is the licence plan (LICENSES.md, "signal-cli") and it is
# also why the Java runtime is Temurin's own rather than a jlink'd one of
# ours: Temurin signs `java` with its Developer ID under the hardened runtime
# and the entitlements a JVM plus libsignal need — allow-jit, and
# disable-library-validation, without which the extracted libsignal dylib is
# refused ("Missing required native library dependency: libsignal-client",
# measured). A copy we re-signed would have to get those right ourselves.
#
# **What is checked before anything is used** — every one of these refuses
# and leaves nothing installed:
#   1. each archive's SHA-256 against the pin below (the pins are GitHub's
#      own asset digests, read from the releases API on 2026-09-11);
#   2. the JRE's `java`: /usr/bin/codesign --verify --strict, Team ID JCDTMS22B4
#      (Eclipse Foundation), the hardened runtime flag, and both entitlements
#      above present;
#   3. and then the artefact is *run*: `signal-cli --version` must print
#      exactly the pinned version. A verified download that cannot start is
#      not ready, and only running it can tell.
# signal-cli's own PGP signature (.asc) is NOT checked here: there is no gpg
# on a stock Mac. The SHA-256 pin is what binds this script to one exact file.
#
# Layout, under Moe's home:  signal/runtime/signal-cli-<v>/   (the tarball, as shipped)
#                            signal/runtime/jre/               (Temurin's bundle, as shipped)
#                            signal/runtime/.ready             (written last: versions + pins)
# Unpacked beside and swapped in by rename, so an interrupted fetch leaves
# either the old copy or none — never half of one that looks ready.
#
# **A slow line still gets there.** The app gives the whole connect 900 s
# (ConnectFlow.signalScanTimeout). At ~1.5 Mbit/s 182 MB takes longer than
# that, and before 2026-09-14 every try started again from zero, so it never
# finished. Now each archive downloads into signal/.download/<its pinned
# SHA-256> — named by the checksum, not the release file name, so a
# download for one pin is never resumed onto by another — which survives a
# killed run, and the next run carries on from where it
# stopped (curl -C -). A partial file is only ever *used* after its SHA-256
# matches the pin, exactly like a whole one. A connection that stalls (under
# 16 KB/s for 60 s) is dropped and retried rather than waiting out the app's
# clock. Leftovers of a killed run — signal/.fetch.<pid> and
# signal/.runtime-old.<pid> whose pid is gone — are removed at the start.
#
# Redirection for tests: MOE_HOME; MOE_SIGNAL_ARCHIVES (a directory holding
# already-downloaded archives by their release file names — the pins still
# apply, byte for byte); MOE_SIGNAL_CLI_URL + MOE_SIGNAL_CLI_SHA256 and
# MOE_SIGNAL_JRE_URL + MOE_SIGNAL_JRE_SHA256 (a URL override is honoured only
# with its own checksum beside it, so no override can skip the check);
# MOE_SIGNAL_SPEED_LIMIT (bytes/s) and MOE_SIGNAL_SPEED_TIME (s), the stall
# rule above, so a test can stall a download in seconds, not minutes.
# Bash 3.2 and `set -u` clean.
set -euo pipefail
umask 077

SIGNAL_CLI_VERSION="0.14.8"
SIGNAL_CLI_FILE="signal-cli-$SIGNAL_CLI_VERSION.tar.gz"
SIGNAL_CLI_URL_PINNED="https://github.com/AsamK/signal-cli/releases/download/v$SIGNAL_CLI_VERSION/$SIGNAL_CLI_FILE"
SIGNAL_CLI_SHA256_PINNED="ccd408e831eff7e41ebaaf309704840bb00d78a7869f35ad700dbae5b5a5bb65"
# Not fetched on its own: libsignal ships inside the signal-cli archive above,
# as lib/libsignal-client-<version>.jar. This MUST match the jar inside the
# pinned archive. The licence notices (NOTICE, Licenses.notice, the site,
# LICENSES.md) offer source for this exact version and
# scripts/test-legal-pages.sh holds them to it; the unpack below refuses an
# archive whose jar is any other version, so the two cannot drift silently.
LIBSIGNAL_VERSION="0.102.1"

JRE_VERSION="25.0.4.1+1"
JRE_FILE="OpenJDK25U-jre_aarch64_mac_hotspot_25.0.4.1_1.tar.gz"
JRE_URL_PINNED="https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.4.1%2B1/$JRE_FILE"
JRE_SHA256_PINNED="5b02bcc908da092e7e00b9772d4f9bbb87f44a60b7c90f7cf5a91a1d98f37e1b"
JRE_TEAM="JCDTMS22B4"          # Developer ID Application: Eclipse Foundation, Inc.
# By absolute path, never `codesign` off PATH. This decides whether a
# downloaded runtime may run, and a check that any earlier PATH entry can
# answer is not a check — scripts/test-stubs has a `codesign` stub, and with a
# bare name it was that stub, not macOS, refusing Temurin's own signed java.
CODESIGN="/usr/bin/codesign"

MOE="${MOE_HOME:-$HOME/.moe}"
RUNTIME="$MOE/signal/runtime"
READY="$RUNTIME/.ready"

# The stamp names what was verified; a stamp for another version is not ready.
stamp_text() {
  printf 'signal-cli %s %s\njre %s %s\n' "$SIGNAL_CLI_VERSION" "$SIGNAL_CLI_SHA256_PINNED" \
    "$JRE_VERSION" "$JRE_SHA256_PINNED"
}
java_home_in() { # <runtime dir> → the JRE's Contents/Home, or nothing
  local h
  for h in "$1"/jre/*/Contents/Home; do [ -x "$h/bin/java" ] && { printf '%s\n' "$h"; return 0; }; done
  return 1
}
is_ready() {
  [ -f "$READY" ] && [ "$(cat "$READY")" = "$(stamp_text)" ] \
    && [ -x "$RUNTIME/signal-cli-$SIGNAL_CLI_VERSION/bin/signal-cli" ] \
    && java_home_in "$RUNTIME" >/dev/null
}

case "${1:-}" in
  --check) is_ready; exit $? ;;
  --paths)
    is_ready || exit 1
    printf 'JAVA_HOME=%s\n' "$(java_home_in "$RUNTIME")"
    printf 'SIGNAL_CLI=%s\n' "$RUNTIME/signal-cli-$SIGNAL_CLI_VERSION/bin/signal-cli"
    exit 0 ;;
  "") ;;
  -h|--help) sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "✗ unknown option $1"; exit 1 ;;
esac

if is_ready; then
  echo "✓ Signal support is already on this Mac (signal-cli $SIGNAL_CLI_VERSION)."
  exit 0
fi

# Only the build that was measured. Moe itself is built for Apple silicon; an
# Intel Mac would need the x64 JRE, whose pin is recorded in docs/SIGNAL.md but
# was never run.
if [ "$(uname -m)" != arm64 ] && [ -z "${MOE_SIGNAL_ANY_ARCH:-}" ]; then
  echo "✗ Signal support is only available on Macs with Apple silicon for now."
  exit 3
fi

# An override URL is a test's, and it brings its own checksum or it is refused.
CLI_URL="$SIGNAL_CLI_URL_PINNED"; CLI_SHA="$SIGNAL_CLI_SHA256_PINNED"
JRE_URL="$JRE_URL_PINNED";         JRE_SHA="$JRE_SHA256_PINNED"
if [ -n "${MOE_SIGNAL_CLI_URL:-}" ]; then
  [ -n "${MOE_SIGNAL_CLI_SHA256:-}" ] || { echo "✗ MOE_SIGNAL_CLI_URL needs MOE_SIGNAL_CLI_SHA256 beside it"; exit 1; }
  CLI_URL="$MOE_SIGNAL_CLI_URL"; CLI_SHA="$MOE_SIGNAL_CLI_SHA256"
fi
if [ -n "${MOE_SIGNAL_JRE_URL:-}" ]; then
  [ -n "${MOE_SIGNAL_JRE_SHA256:-}" ] || { echo "✗ MOE_SIGNAL_JRE_URL needs MOE_SIGNAL_JRE_SHA256 beside it"; exit 1; }
  JRE_URL="$MOE_SIGNAL_JRE_URL"; JRE_SHA="$MOE_SIGNAL_JRE_SHA256"
fi

mkdir -p "$MOE/signal"
chmod 700 "$MOE/signal"
# A killed run's leftovers. Named after the pid that made them, so a run
# still going (another click, another window) keeps its own; anything else —
# a dead pid, or a name from before the pid was in it — goes.
for left in "$MOE"/signal/.fetch.* "$MOE"/signal/.runtime-old.*; do
  [ -e "$left" ] || continue
  owner="${left##*.}"
  case "$owner" in
    ''|*[!0-9]*) ;;
    *) [ "$owner" != "$$" ] && kill -0 "$owner" 2>/dev/null && continue ;;
  esac
  rm -rf "$left"
done
WORK="$MOE/signal/.fetch.$$"
rm -rf "$WORK"; mkdir -m 700 "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
# Kept across runs on purpose (see the header): what has arrived so far.
PARTIAL="$MOE/signal/.download"
mkdir -p "$PARTIAL"; chmod 700 "$PARTIAL"
# A download for a pin this run does not want (a Moe release moved it) is
# never going to be used; it is 180 MB of disk.
for f in "$PARTIAL"/*; do
  [ -e "$f" ] || continue
  case "${f##*/}" in "$CLI_SHA"|"$JRE_SHA") ;; *) rm -rf "$f" ;; esac
done
SPEED_LIMIT="${MOE_SIGNAL_SPEED_LIMIT:-16384}"
SPEED_TIME="${MOE_SIGNAL_SPEED_TIME:-60}"
case "$SPEED_LIMIT$SPEED_TIME" in *[!0-9]*) echo "✗ the download speed rule is not a number"; exit 1 ;; esac

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

get() { # <url> <file name> <expected sha256> → $PARTIAL/<expected sha256>, verified
  # Left in $PARTIAL, not moved into $WORK: if signal-cli arrives and the
  # Java runtime then fails, the next run must not fetch signal-cli again.
  local url="$1" name="$2" want="$3" part="$PARTIAL/$3" got tries=0 rc
  if [ -n "${MOE_SIGNAL_ARCHIVES:-}" ] && [ -f "$MOE_SIGNAL_ARCHIVES/$name" ]; then
    cp "$MOE_SIGNAL_ARCHIVES/$name" "$part"
  elif [ -f "$part" ] && [ "$(sha_of "$part")" = "$want" ]; then
    :   # finished by an earlier run that was stopped before it could unpack
  else
    while :; do
      tries=$((tries + 1)); rc=0
      curl -fsSL -C - --connect-timeout 20 --speed-limit "$SPEED_LIMIT" --speed-time "$SPEED_TIME" \
        -o "$part" "$url" || rc=$?
      [ "$rc" -eq 0 ] && break
      # 22 (an HTTP error — a partial longer than the file gets 416), 33 (the
      # server will not resume) and 36 (a bad resume offset): what is on disk
      # cannot be carried on from, so this file starts again. Anything else —
      # a stall (28), a dropped connection — keeps it and resumes.
      case "$rc" in 22|33|36) rm -f "$part" ;; esac
      if [ "$tries" -ge 3 ]; then
        echo "✗ Could not download $name. Check the network and try again — what already arrived is kept, and the next try carries on from there."
        return 1
      fi
      sleep 1
    done
  fi
  got="$(sha_of "$part")"
  if [ "$got" != "$want" ]; then
    # Said plainly and never "try again": a different file at a pinned URL is
    # not a network hiccup, and nothing from it may run. The partial goes
    # too, so a corrupt one is never resumed from.
    echo "✗ $name is not the file Alfie expects (its checksum does not match), so nothing was installed."
    rm -f "$part"
    return 1
  fi
}

echo "Downloading Signal support for the first time (about 180 MB, once)…"
get "$CLI_URL" "$SIGNAL_CLI_FILE" "$CLI_SHA" || exit 3
get "$JRE_URL" "$JRE_FILE" "$JRE_SHA" || exit 3

STAGE="$WORK/runtime"
mkdir -p "$STAGE/jre"
tar -xzf "$PARTIAL/$CLI_SHA" -C "$STAGE" || { echo "✗ Could not unpack signal-cli."; exit 3; }
tar -xzf "$PARTIAL/$JRE_SHA" -C "$STAGE/jre" || { echo "✗ Could not unpack the Java runtime."; exit 3; }

CLI="$STAGE/signal-cli-$SIGNAL_CLI_VERSION/bin/signal-cli"
[ -x "$CLI" ] || { echo "✗ The signal-cli download has no bin/signal-cli."; exit 3; }
[ -f "$STAGE/signal-cli-$SIGNAL_CLI_VERSION/lib/libsignal-client-$LIBSIGNAL_VERSION.jar" ] || {
  echo "✗ The signal-cli download does not carry libsignal $LIBSIGNAL_VERSION, the version Alfie's licence notices name, so nothing was installed."
  exit 3; }
JH="$(java_home_in "$STAGE" || true)"
[ -n "$JH" ] || { echo "✗ The Java runtime download has no bin/java."; exit 3; }

# The runtime's signature: whose it is, that it is intact, and that it carries
# what a JVM running libsignal needs under the hardened runtime.
# Matched with `case`, never `printf … | grep -q`: under `pipefail` grep's
# early exit on a match SIGPIPEs the printf and the pipeline reports failure
# — which refused Temurin's own, correctly signed `java` on its first real run.
java_ok() {
  local j="$1" d ent k nl='
'
  "$CODESIGN" --verify --strict "$j" >/dev/null 2>&1 || { echo "its signature does not verify"; return 1; }
  d="$nl$("$CODESIGN" -dvv "$j" 2>&1 || true)$nl"
  case "$d" in *"${nl}TeamIdentifier=$JRE_TEAM$nl"*) ;; *) echo "it is not signed by Eclipse (Temurin)"; return 1 ;; esac
  case "$d" in *"flags="*"(runtime)"*|*"flags="*",runtime"*|*"flags="*"runtime,"*) ;;
    *) echo "it is not built for the hardened runtime"; return 1 ;; esac
  ent="$("$CODESIGN" -d --entitlements - --xml "$j" 2>/dev/null || true)"
  for k in com.apple.security.cs.allow-jit com.apple.security.cs.disable-library-validation; do
    case "$ent" in *"$k"*) ;; *) echo "it lacks $k"; return 1 ;; esac
  done
}
if ! why="$(java_ok "$JH/bin/java")"; then
  echo "✗ The Java runtime failed its signature check ($why), so nothing was installed."
  exit 3
fi

# Run it. The pinned version, printed by the pinned version, or it is not ready.
said="$(JAVA_HOME="$JH" "$CLI" --version 2>&1 | tail -n 1 || true)"
if [ "$said" != "signal-cli $SIGNAL_CLI_VERSION" ]; then
  echo "✗ Signal support was downloaded but does not start (it said: $(printf '%s' "$said" | tr -d '\n' | cut -c1-120))."
  exit 3
fi

stamp_text > "$STAGE/.ready"
OLD="$MOE/signal/.runtime-old.$$"
[ -e "$RUNTIME" ] && mv "$RUNTIME" "$OLD"
mv "$STAGE" "$RUNTIME"
rm -rf "$OLD" "$PARTIAL"
echo "✓ Signal support is ready (signal-cli $SIGNAL_CLI_VERSION, Java $JRE_VERSION)."
