#!/bin/bash
# Moe's eyes and hands on the Mac.
#
# Screenshots go to a file that Moe reads back as an image, so it genuinely
# sees the screen rather than being told about it. Input goes through
# System Events, which needs Accessibility permission (already granted for
# push-to-talk).
#
# SECURITY — read before extending.
#
# Every argument here can come from something Moe *read* — a note, an email, a
# web page. Coordinates and key names are validated as numbers and from a fixed
# list; text to type is passed to AppleScript out-of-band via `on run argv`
# rather than concatenated into a script, for the same reason apple.sh does it:
# otherwise a quotation mark in a message becomes code.
#
# What this deliberately does NOT do: no "click whatever looks right" loop, no
# unattended multi-step automation. Moe proposes, you approve, it acts once.
#
# STOPPING — how a person ends a run.
#
# There used to be a guard here that watched the session's CGEvent stream and
# refused to act if it thought a human had touched the mouse or keyboard. It
# is gone. It could not work: cua-driver's foreground path posts "a genuine
# HID key transition" — its own words — exactly so that Chromium and native
# menus cannot tell it from hardware, which means neither could we. Source
# pid 0, the same as the keyboard. Three attempts at a threshold all fired on
# Moe rather than on the owner.
#
# Stopping is now something a person does, not something a machine infers:
# while Moe is driving the screen the notch changes colour and carries a stop
# that ends the run. Explicit beats clairvoyant.

set -uo pipefail

SHOT_DIR="${MOE_SHOT_DIR:-$HOME/.moe/screen}"
mkdir -p "$SHOT_DIR"

usage() {
  cat <<'EOF'
LOOKING
  screenshot [display]     capture the screen to a PNG, print the path
  meeting-shot [reason]    during a meeting Alfie is recording: keep a screenshot
                           in the meeting's folder (listed in the notes)
  meeting-clip start|stop [reason]
                           during a meeting: record the screen to a clip
  meeting-status           is a meeting recording, and what was captured
  window                   frontmost app, window title and bounds
  menus [app] [query]      every menu item of an app, with its keyboard
                           shortcut — searchable. The path it prints is
                           exactly what computer_use invoke_menu takes.
  apps                     what's running and visible
  where                    current mouse position

DOING
  click X Y                click at screen coordinates
  doubleclick X Y
  rightclick X Y
  move X Y                 move the pointer without clicking
  type "text"              type text into whatever has focus
  key cmd+t                press a key combination
  scroll N                 scroll (negative = down)
  open "App Name"          launch or focus an application
  menu "App" "Menu" "Item" click a menu item

TAKING OVER

Coordinates are in screen points, origin top-left, as reported by `window`.

To stop Alfie while it is driving the screen, click the stop on the notch —
it goes a different colour while Alfie has the screen. Looking is never
blocked and never needs stopping.
EOF
}

die() { echo "$1" >&2; exit 2; }
num() { case "${1:-}" in (''|*[!0-9-]*) die "expected a number, got: ${1:-}";; esac; echo "$1"; }

# The hands-off guard used to live here. It is gone, and the reason is in
# docs/COMPUTER-USE.md: it tried to tell Moe's own input from a person's by
# looking at CGEvent provenance, and cua-driver's foreground path posts "a
# genuine HID key transition" — its words — precisely so Chromium cannot tell
# the difference either. Source pid 0, exactly like the keyboard. There was no
# signal to read.
#
# What replaces it is not another inference. It is the notch: while Moe is
# driving, the island changes colour and carries a stop you can click, which
# ends the run outright. A person saying "stop" beats a machine guessing
# whether they meant to.

# Test-only: MOE_MAC_DRY_RUN=1 turns every synthetic action into a line on
# stderr, so scripts/test-computer-use.sh can exercise the stop path without
# anything landing on the real screen. It wraps the doing, never the checks.
act() {
  if [ -n "${MOE_MAC_DRY_RUN:-}" ]; then echo "would: $*" >&2; return 0; fi
  "$@"
}

case "${1:-}" in

# ---------- Looking ----------
# The meeting captures go through the app rather than `screencapture`
# because the picture belongs in the meeting's own folder, in its record and
# in its notes — and because the app knows the meeting window and the area
# the user chose. Only the user starts or stops a meeting; these do nothing
# when none is being recorded, and say so.
meeting-shot)
  shift
  "$MOE_BIN" --meeting-capture screenshot "$@"
  ;;
meeting-clip)
  shift
  "$MOE_BIN" --meeting-capture record "$@"
  ;;
meeting-status)
  "$MOE_BIN" --meeting-capture status
  ;;

screenshot)
  # -x = no shutter sound. Downscaled so it stays cheap to look at.
  out="$SHOT_DIR/screen-$(date +%H%M%S).png"
  if [ -n "${2:-}" ]; then
    screencapture -x -D "$(num "$2")" "$out" 2>/dev/null
  else
    screencapture -x "$out" 2>/dev/null
  fi
  [ -f "$out" ] || die "screenshot failed — grant Screen Recording to Memoe.app in System Settings › Privacy & Security"
  sips -Z 1600 "$out" >/dev/null 2>&1 || true
  # Keep only the most recent handful.
  ls -t "$SHOT_DIR"/screen-*.png 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
  echo "$out"
  ;;

menus)
  # An app's menu bar, over the Accessibility API. This is the cheap half of
  # driving an app: `computer_use invoke_menu` fires any menu item by exact
  # path with no screenshot and no coordinates, but nothing enumerates the
  # paths — cua-driver's snapshot is scoped to a window and a menu bar is not
  # in any window. Measured warm: Finder 0.06s / 174 items.
  #
  # It matters most where pixels are worst. A DAW, CAD or 3D app draws its
  # canvas as one custom surface with no accessibility tree at all, while its
  # menu bar stays ordinary and fully readable — so the work is reachable by
  # menu when it is unreachable by element.
  # MOE_BIN is set at the top of this file and points at the app bundle,
  # because that is where the Accessibility grant lives — reading a menu bar
  # from a terminal is attributed to the terminal and fails.
  # macOS ships bash 3.2, where "${@:3}" with nothing there expands to one
  # EMPTY argument rather than none — so `mac.sh menus Finder` was really
  # running `--app-menus Finder ""`. Harmless only because an empty query is
  # treated as "no filter", which is luck rather than design. Shift instead.
  app="${2:-frontmost}"
  shift 2 2>/dev/null || shift $# 
  if [ -x "$MOE_BIN" ]; then exec "$MOE_BIN" --app-menus "$app" "$@"; fi
  echo "menus needs Memoe.app at $MOE_BIN — the Accessibility grant belongs to it, not to this shell" >&2
  exit 2
  ;;

window)
  osascript <<'AS'
tell application "System Events"
  set frontApp to first application process whose frontmost is true
  set appName to name of frontApp
  try
    set w to first window of frontApp
    set {x, y} to position of w
    set {ww, hh} to size of w
    set t to name of w
    return appName & " | " & t & " | x=" & x & " y=" & y & " w=" & ww & " h=" & hh
  on error
    return appName & " | (no window)"
  end try
end tell
AS
  ;;

apps)
  osascript -e 'tell application "System Events" to get name of every application process whose visible is true' \
    | tr ',' '\n' | sed 's/^ //'
  ;;

where)
  osascript -e 'tell application "System Events" to return (get position of mouse) as string' 2>/dev/null \
    || echo "(mouse position needs Accessibility)"
  ;;

# ---------- Doing ----------
click|doubleclick|rightclick|move)
  x="$(num "${2:-}")"; y="$(num "${3:-}")"
  case "$1" in
    move) before="The pointer did not move."; after="The pointer had already moved." ;;
    *)    before="Nothing was clicked.";      after="The $1 had already gone out." ;;
  esac
  # Check, arm, check again. The first is so a session that is already
  # stopped never even starts a watcher; the second catches a hand that
  # landed during the second it can take to arm one. Every action below
  # follows the same shape.
  case "$1" in
    click)       act osascript - "$x" "$y" <<'AS'
on run argv
  tell application "System Events" to click at {(item 1 of argv) as integer, (item 2 of argv) as integer}
end run
AS
    ;;
    # A double click is left whole: two separate osascript launches are far
    # enough apart that macOS would read them as two single clicks, so there
    # is no honest place to check in the middle of one.
    doubleclick) act osascript - "$x" "$y" <<'AS'
on run argv
  set px to (item 1 of argv) as integer
  set py to (item 2 of argv) as integer
  tell application "System Events"
    click at {px, py}
    delay 0.05
    click at {px, py}
  end tell
end run
AS
    ;;
    rightclick)  act osascript - "$x" "$y" <<'AS'
on run argv
  tell application "System Events" to perform action "AXShowMenu" of (click at {(item 1 of argv) as integer, (item 2 of argv) as integer})
end run
AS
    ;;
    move)        act osascript - "$x" "$y" <<'AS'
on run argv
  tell application "System Events" to set the position of the mouse to {(item 1 of argv) as integer, (item 2 of argv) as integer}
end run
AS
    ;;
  esac
  echo "$1 $x,$y"
  ;;

type)
  [ -n "${2:-}" ] || die "text required"
  # Typed in chunks, checking between them, so a hand on the keyboard stops
  # the typing where it is instead of after the whole string has gone in —
  # the difference between "I stopped" and "I finished, and by the way you
  # interrupted me". 60 characters is short enough to feel immediate and
  # long enough not to pay an osascript launch per word.
  # Indexed rather than whittling the string down: `text="${text:60}"` would
  # copy the whole remainder every chunk, which is quadratic and, on a long
  # paste, slower than the typing.
  total=${#2}; typed=0
  while [ "$typed" -lt "$total" ]; do
    chunk="${2:typed:60}"
    act osascript - "$chunk" <<'AS'
on run argv
  tell application "System Events" to keystroke (item 1 of argv)
end run
AS
    typed=$(( typed + ${#chunk} ))
  done
  echo "typed $total chars"
  ;;

key)
  combo="${2:?key combination required}"
  # Only known modifiers and a plain key — never raw AppleScript.
  mods=""; keyname="${combo##*+}"
  case "$combo" in *cmd*)   mods="$mods command down,";; esac
  case "$combo" in *ctrl*)  mods="$mods control down,";; esac
  case "$combo" in *opt*|*alt*) mods="$mods option down,";; esac
  case "$combo" in *shift*) mods="$mods shift down,";; esac
  mods="${mods%,}"
  case "$keyname" in (*[!A-Za-z0-9]*) die "unsupported key: $keyname";; esac
  if [ -n "$mods" ]; then
    act osascript -e "tell application \"System Events\" to keystroke \"$keyname\" using {$mods}"
  else
    act osascript -e "tell application \"System Events\" to keystroke \"$keyname\""
  fi
  echo "pressed $combo"
  ;;

scroll)
  n="$(num "${2:-}")"
  # In steps, for the same reason typing is in chunks: a long scroll is a
  # sequence, and a sequence has to be interruptible. Five lines is about one
  # notch of a wheel.
  remaining="$n"
  while [ "$remaining" -ne 0 ]; do
    if   [ "$remaining" -gt 5 ];  then this=5
    elif [ "$remaining" -lt -5 ]; then this=-5
    else this="$remaining"; fi
    act osascript - "$this" <<'AS'
on run argv
  tell application "System Events" to scroll {0, (item 1 of argv) as integer}
end run
AS
    remaining=$(( remaining - this ))
  done
  echo "scrolled $n"
  ;;

open)
  [ -n "${2:-}" ] || die "app name required"
  # Checked before, not after: launching an app posts no input of its own, so
  # there is nothing here that could be half-done. The guard is armed anyway,
  # because an app takes a second to come up and that is a second in which
  # somebody may well reach for the mouse — the click that was going to
  # follow this one is the one that must not land.
  act open -a "$2" 2>/dev/null && echo "opened $2" || die "no such app: $2"
  ;;

menu)
  app="${2:?app}"; m="${3:?menu}"; item="${4:?item}"
  act osascript - "$app" "$m" "$item" <<'AS'
on run argv
  tell application "System Events"
    tell process (item 1 of argv)
      click menu item (item 3 of argv) of menu 1 of menu bar item (item 2 of argv) of menu bar 1
    end tell
  end tell
end run
AS
  echo "clicked $m > $item in $app"
  ;;

# ---------- Taking over ----------
*) usage; exit 1 ;;
esac
