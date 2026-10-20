#!/bin/bash
# Chrome history and bookmarks, read off the disk. No authentication, no
# extension, no sign-in: Chrome's own profile directory is a SQLite file and a
# JSON file, and they are already on this Mac.
#
#   ~/Library/Application Support/Google/Chrome/<Profile>/History    SQLite
#   ~/Library/Application Support/Google/Chrome/<Profile>/Bookmarks  JSON
#
# Every profile, not just Default — a work profile and a personal profile are
# the normal setup and reading only one of them quietly lies.
#
# Three rules this connector exists to keep:
#
#   1. OPT-IN, OFF BY DEFAULT. Browsing history is the most invasive thing on
#      the machine: it is medical, financial and political all at once. It is
#      gated on the same recorded, revocable, per-source consent the learn-me
#      crawl uses (learn/consent.sh) — one file, one place to look, one place
#      to revoke — and the gate covers `pull` as well as `crawl`, which is not
#      true of any other connector. No marker, no data, and `status` says so.
#      Consent here is never asked for in passing: because `status` is not
#      "ok:" until it is granted, learn.sh skips Chrome rather than prompting
#      mid-crawl. Turning it on is a deliberate act:
#        ~/.moe/learn/consent.sh grant chrome
#   2. NEVER OPEN THE LIVE DATABASE. Chrome holds an exclusive lock on
#      History while it is running, and an sqlite reader that trips over that
#      lock has a habit of leaving a stale -wal behind. The file is copied to
#      a temporary directory, the copy is read, the copy is deleted.
#   3. NO QUERY STRINGS. A URL's query is where password-reset links, magic
#      links and OAuth codes live. Every URL below is rebuilt from its host
#      and path, so the query and fragment cannot survive even by accident.
set -uo pipefail

CHROME_DIR="${MOE_CHROME_DIR:-$HOME/Library/Application Support/Google/Chrome}"
APPS_DIR="${MOE_CHROME_APPS_DIR:-/Applications}"
CONSENT="${MOE_HOME:-$HOME/.moe}/learn/consent.sh"
PULL_HOURS="${MOE_CHROME_HOURS:-24}"
PULL_LIMIT="${MOE_CHROME_LIMIT:-40}"

# crawl [--since DAYS] [--max-bytes N]: the learn-me pass (learn.sh). Same
# read path as pull, wider window, and a hard byte cap so one chatty source
# cannot swamp the rest. Both values are validated as plain integers before
# they go anywhere near a query.
crawl_args() {
  SINCE_DAYS=90; MAX_BYTES="${MOE_CRAWL_MAX_BYTES:-400000}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --since)     SINCE_DAYS="${2:-}"; shift ;;
      --max-bytes) MAX_BYTES="${2:-}"; shift ;;
      *) echo "crawl: unknown option $1" >&2; exit 2 ;;
    esac
    shift
  done
  # Each on its own: concatenated, an empty --since would hide behind a
  # valid --max-bytes and reach the query as "-  days".
  case "$SINCE_DAYS" in ''|*[!0-9]*) echo "crawl: --since takes a whole number of days" >&2; exit 2 ;; esac
  case "$MAX_BYTES"  in ''|*[!0-9]*) echo "crawl: --max-bytes takes a whole number" >&2; exit 2 ;; esac
}

# Fail closed: no consent.sh (a checkout without an install) means no consent.
consent_granted() {
  [ -x "$CONSENT" ] || return 1
  "$CONSENT" check chrome >/dev/null 2>&1
}

chrome_py() { # mode hours-or-days limit budget
  python3 - "$1" "$CHROME_DIR" "$APPS_DIR" "$2" "$3" "$4" <<'PY'
import json, os, re, shutil, sqlite3, sys, tempfile, time
from urllib.parse import urlsplit

MODE, CHROME_DIR, APPS = sys.argv[1:4]
WINDOW, LIMIT, BUDGET = (int(x) for x in sys.argv[4:7])

# Chrome timestamps are microseconds since 1601-01-01 UTC.
EPOCH_DELTA = 11644473600

# ── Foreign text ──────────────────────────────────────────────────────────
# Page titles are written by whoever owns the page. They end up in a markdown
# file the model reads, so they get the same treatment as any other foreign
# string (connectors/hermeslib.py one_line()).
_MD_LEADING = re.compile(r"^(?=[#>\-+*|`]|\d+[.)]\s)")
_MD_LINK = re.compile(r"\[([^\]]*)\]\(([^)]*)\)")


def one_line(text, limit=120):
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or ""))
    text = re.sub(r"\s+", " ", text).strip()
    text = _MD_LINK.sub(r"\1 (\2)", text)
    text = _MD_LEADING.sub("\\\\", text, count=1)
    return text[:limit]


def site(url, with_path=False):
    """host, or host+path — rebuilt from the parts, never sliced out of the
    original string. The query and the fragment are dropped by construction,
    which is the only way to be sure a reset token never lands in a file."""
    try:
        parts = urlsplit(str(url or ""))
    except ValueError:
        return ""
    # http(s) only: chrome://, file:// and extension pages are either local
    # paths or Chrome's own furniture, and neither says anything about a day.
    if parts.scheme not in ("http", "https"):
        return ""
    host = (parts.hostname or "").lower()
    if not host:
        return ""
    if not with_path:
        return one_line(host, 80)
    path = (parts.path or "").rstrip("/")
    return one_line(host + path, 120)


# ── Profiles ──────────────────────────────────────────────────────────────
# Not Chrome's own scratch profiles: "System Profile" holds no browsing and
# "Guest Profile" is by definition not the user.
SKIP = {"System Profile", "Guest Profile", "Crashpad", "ShaderCache", "GrShaderCache"}


class Denied(Exception):
    """Full Disk Access is off. Distinct from 'Chrome is not installed' —
    the fix is a different System Settings pane."""


def profiles():
    try:
        names = sorted(os.listdir(CHROME_DIR))
    except PermissionError:
        raise Denied()
    except OSError:
        return []
    out = []
    for name in names:
        if name in SKIP or name.startswith("."):
            continue
        path = os.path.join(CHROME_DIR, name)
        if not os.path.isdir(path):
            continue
        if os.path.exists(os.path.join(path, "History")) or os.path.exists(os.path.join(path, "Bookmarks")):
            out.append((name, path))
    # Default first, then Profile 1, Profile 2 — the order Chrome shows them.
    out.sort(key=lambda p: (p[0] != "Default", p[0]))
    return out


def installed():
    if os.path.isdir(os.path.join(APPS, "Google Chrome.app")):
        return True
    try:
        return os.path.isdir(CHROME_DIR)
    except OSError:
        return False


# ── Reading History without touching History ──────────────────────────────

def visits(profile_dir, since_ts, limit):
    """(timestamp, url, title) newest first, read from a copy.

    Chrome keeps an exclusive lock on the live file whenever it is running,
    so the live file is never opened. The copy lands in a temporary directory
    of our own and is deleted before this returns, whatever happens."""
    src = os.path.join(profile_dir, "History")
    if not os.path.exists(src):
        return []
    tmp = tempfile.mkdtemp(prefix="moe-chrome-")
    try:
        dst = os.path.join(tmp, "History")
        # The -wal holds everything written since the last checkpoint; without
        # it the copy is silently missing today's browsing.
        for suffix in ("", "-wal", "-shm"):
            try:
                shutil.copy2(src + suffix, dst + suffix)
            except FileNotFoundError:
                continue
            except PermissionError:
                raise Denied()
        conn = sqlite3.connect(dst)
        try:
            cur = conn.execute(
                "SELECT v.visit_time, u.url, u.title "
                "FROM visits v JOIN urls u ON u.id = v.url "
                "WHERE v.visit_time > ? ORDER BY v.visit_time DESC LIMIT ?",
                (int((since_ts + EPOCH_DELTA) * 1000000), limit))
            return [(int(t), url, title) for t, url, title in cur.fetchall()]
        finally:
            conn.close()
    except sqlite3.Error:
        # A profile mid-upgrade, or a schema this build does not know. One
        # unreadable profile must not take the others down with it.
        return []
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def bookmarks(profile_dir, limit):
    """(name, host+path) from the Bookmarks JSON tree, in tree order."""
    src = os.path.join(profile_dir, "Bookmarks")
    try:
        with open(src, "rb") as fh:
            data = json.loads(fh.read(8 << 20).decode("utf-8", "replace"))
    except PermissionError:
        raise Denied()
    except (OSError, ValueError):
        return []
    out = []

    def walk(node, depth):
        if len(out) >= limit or depth > 12 or not isinstance(node, dict):
            return
        if node.get("type") == "url":
            where = site(node.get("url"), with_path=True)
            if where:
                out.append((one_line(node.get("name"), 100), where))
            return
        for child in node.get("children") or []:
            walk(child, depth + 1)

    roots = data.get("roots") if isinstance(data, dict) else None
    if isinstance(roots, dict):
        for key in sorted(roots):
            walk(roots[key], 0)
    return out


def when(ts, fmt="%Y-%m-%d %H:%M"):
    return time.strftime(fmt, time.localtime(ts))


def chrome_time(us):
    return us / 1000000.0 - EPOCH_DELTA


# ── The verbs ─────────────────────────────────────────────────────────────
# `probe` answers "could we read this at all", separately from consent, so
# status can name the real blocker: not installed, no data, or no permission.

def cmd_probe():
    try:
        found = profiles()
    except Denied:
        print("needs-setup: grant Full Disk Access to Memoe.app in System Settings › "
              "Privacy & Security, then try again")
        return 1
    if not found:
        if installed():
            print("unavailable: Google Chrome is installed but has no profile data on this Mac")
        else:
            print("unavailable: Google Chrome is not installed on this Mac")
        return 3
    print(len(found))
    return 0


def cmd_pull():
    """Recent titles and the site they were on. Not the URL: a domain and a
    title say what the day was about, and a path adds mostly risk."""
    since = time.time() - WINDOW * 3600
    rows = []
    seen = set()
    try:
        for name, path in profiles():
            for us, url, title in visits(path, since, LIMIT * 4):
                host = site(url)
                if not host:
                    continue
                text = one_line(title, 110) or host
                key = (host, text)
                if key in seen:
                    continue
                seen.add(key)
                rows.append((chrome_time(us), name, host, text))
    except Denied:
        print("needs-setup: grant Full Disk Access to Memoe.app", file=sys.stderr)
        return 1
    rows.sort(reverse=True)
    for ts, _profile, host, text in rows[:LIMIT]:
        print("%s | %s | %s" % (when(ts), host, text))
    return 0


def cmd_crawl():
    """The learn-me pass: what this person reads, over a long window. Paths
    are included here (queries still are not) because a bare domain cannot
    tell a hobby from a job."""
    since = time.time() - WINDOW * 86400
    spent = 0
    try:
        found = profiles()
    except Denied:
        print("needs-setup: grant Full Disk Access to Memoe.app", file=sys.stderr)
        return 1
    for name, path in found:
        try:
            rows = visits(path, since, 20000)
            marks = bookmarks(path, 400)
        except Denied:
            print("needs-setup: grant Full Disk Access to Memoe.app", file=sys.stderr)
            return 1
        if not rows and not marks:
            continue
        head = "### Chrome profile %s — pages visited\n" % one_line(name, 40)
        spent += len(head.encode("utf-8", "replace"))
        sys.stdout.write(head)
        for us, url, title in rows:
            if spent >= BUDGET:
                return 0
            where = site(url, with_path=True)
            if not where:
                continue
            line = "%s | %s | %s\n" % (when(chrome_time(us)), where, one_line(title, 140) or where)
            spent += len(line.encode("utf-8", "replace"))
            sys.stdout.write(line)
        if marks:
            head = "\n### Chrome profile %s — bookmarks\n" % one_line(name, 40)
            spent += len(head.encode("utf-8", "replace"))
            sys.stdout.write(head)
            for label, where in marks:
                if spent >= BUDGET:
                    return 0
                line = "%s | %s\n" % (where, label or where)
                spent += len(line.encode("utf-8", "replace"))
                sys.stdout.write(line)
        sys.stdout.write("\n")
    return 0


sys.exit({"probe": cmd_probe, "pull": cmd_pull, "crawl": cmd_crawl}[MODE]())
PY
}

case "${1:-status}" in
status)
  # The real blocker first: "turn it on" is unhelpful advice for a Mac with
  # no Chrome on it.
  count="$(chrome_py probe 0 0 0)"; rc=$?
  if [ "$rc" -ne 0 ]; then echo "$count"; exit "$rc"; fi
  if consent_granted; then
    echo "ok: reading $count Chrome profile(s)"
  else
    echo "needs-setup: Chrome browsing is off until you turn it on — run ~/.moe/learn/consent.sh grant chrome"
    exit 1
  fi
  ;;
pull)
  case "$PULL_HOURS" in ''|*[!0-9]*) echo "MOE_CHROME_HOURS must be a whole number of hours" >&2; exit 2 ;; esac
  case "$PULL_LIMIT" in ''|*[!0-9]*) echo "MOE_CHROME_LIMIT must be a whole number" >&2; exit 2 ;; esac
  # Nothing on stdout and a non-zero exit: sync.sh then deletes any context
  # file from before, which is what withdrawing consent has to mean.
  consent_granted || {
    echo "chrome: off until you turn it on — ~/.moe/learn/consent.sh grant chrome" >&2; exit 1; }
  chrome_py pull "$PULL_HOURS" "$PULL_LIMIT" 0
  ;;
crawl)
  shift; crawl_args "$@"
  consent_granted || {
    echo "chrome: off until you turn it on — ~/.moe/learn/consent.sh grant chrome" >&2; exit 1; }
  chrome_py crawl "$SINCE_DAYS" 0 "$MAX_BYTES" | { head -c "$MAX_BYTES"; cat >/dev/null; }
  exit "${PIPESTATUS[0]}"
  ;;
*) echo "usage: chrome.sh [status|pull|crawl [--since DAYS] [--max-bytes N]]"; exit 2 ;;
esac
