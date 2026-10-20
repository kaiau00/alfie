#!/bin/bash
# Google Drive with no authentication of any kind.
#
# Google Drive for Desktop already syncs the user's Drive to this Mac. Once it
# has, Drive is just files on a disk — so Moe reads the disk. No OAuth, no
# consent screen, no app password, no API quota, nothing to revoke: if Drive
# for Desktop is signed in, Moe can read what it synced, and if it is not,
# Moe reads nothing. That is the whole design.
#
# Three layouts, all supported, and all of them at once (people have two
# accounts):
#   ~/Library/CloudStorage/GoogleDrive-<account>/   Drive for Desktop, current
#   ~/Google Drive/                                 legacy Backup and Sync
#   /Volumes/GoogleDrive/                           legacy File Stream mount
#
# Two things this connector must never do, both of which the walk below is
# built around:
#
#   1. Follow a symlink. A link inside Drive can point at ~/.ssh; Drive itself
#      never creates one. Every symlink is skipped, so nothing under a Drive
#      root can name a file outside it.
#   2. Put a filename in a shell command. Filenames come from whoever shared
#      the folder, so the walk lives in python3 (stdlib only) and every path
#      that reaches /usr/bin/textutil or /usr/bin/mdls goes as argv, never
#      through a shell.
#
# `pull` is an index — name, folder, size, date — and deliberately reads no
# file contents. `crawl` (the learn-me pass) does read text, from formats that
# are actually text.
set -uo pipefail

# Overridable so the tests can point the two absolute paths at a scratch dir;
# nothing else in here is absolute except the two Apple binaries.
APPS_DIR="${MOE_DRIVE_APPS_DIR:-/Applications}"
VOLUMES_DIR="${MOE_DRIVE_VOLUMES:-/Volumes}"
PULL_DAYS="${MOE_DRIVE_DAYS:-30}"
PULL_LIMIT="${MOE_DRIVE_LIMIT:-40}"

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

# One python program, three modes. Arguments go by argv so no value here is
# ever parsed by a shell.
drive_py() { # mode days limit budget
  python3 - "$1" "$HOME" "$APPS_DIR" "$VOLUMES_DIR" "$2" "$3" "$4" <<'PY'
import json, os, re, subprocess, sys, time

MODE, HOME, APPS, VOLS = sys.argv[1:5]
DAYS, LIMIT, BUDGET = (int(x) for x in sys.argv[5:8])

# ── Foreign text ──────────────────────────────────────────────────────────
# Filenames, folder names and file contents are written by whoever shared the
# folder, and everything below ends up in a markdown file the model reads.
# Same rules as connectors/hermeslib.py one_line(): no control characters, no
# markdown structure, no clickable links.
_MD_LEADING = re.compile(r"^(?=[#>\-+*|`]|\d+[.)]\s)")
_MD_LINK = re.compile(r"\[([^\]]*)\]\(([^)]*)\)")


def one_line(text, limit=120):
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or ""))
    text = re.sub(r"\s+", " ", text).strip()
    text = _MD_LINK.sub(r"\1 (\2)", text)
    text = _MD_LEADING.sub("\\\\", text, count=1)
    return text[:limit]


def block(text, max_lines=160, limit=400):
    """A file's text, line by line, each one neutralised. A code fence or a
    '### heading' inside someone's document must not become structure in the
    file Moe reads."""
    out = []
    for raw in str(text or "").splitlines():
        line = one_line(raw, limit)
        if not line:
            continue
        out.append(line)
        if len(out) >= max_lines:
            out.append("…")
            break
    return "\n".join(out)


# ── Where Drive is ────────────────────────────────────────────────────────

def roots():
    """(account label, absolute path) for every Drive folder on this Mac,
    current layout first. Multiple accounts are the normal case."""
    found = []
    cloud = os.path.join(HOME, "Library", "CloudStorage")
    try:
        names = sorted(os.listdir(cloud))
    except OSError:
        names = []
    for name in names:
        # OneDrive and Dropbox live here too; only Google's prefix.
        if not name.startswith("GoogleDrive-"):
            continue
        path = os.path.join(cloud, name)
        if os.path.isdir(path):
            found.append((name[len("GoogleDrive-"):] or name, path))
    legacy = os.path.join(HOME, "Google Drive")
    if os.path.isdir(legacy):
        found.append(("Google Drive", legacy))
    for vol in ("GoogleDrive", "Google Drive"):
        path = os.path.join(VOLS, vol)
        if os.path.isdir(path):
            found.append((vol, path))
    return found


def installed():
    """Is Drive for Desktop on this Mac at all? The app bundle, or the support
    directory it leaves behind — either answers 'installed but not synced yet'
    differently from 'never installed', and those need different advice."""
    for app in ("Google Drive.app", "Google Drive File Stream.app",
                "Backup and Sync from Google.app"):
        if os.path.isdir(os.path.join(APPS, app)):
            return True
    return os.path.isdir(os.path.join(HOME, "Library", "Application Support", "Google", "DriveFS"))


# ── The walk ──────────────────────────────────────────────────────────────
# Native Google files are JSON stubs holding a document id, not the document.
NATIVE = {
    ".gdoc": "Google Doc", ".gsheet": "Google Sheet", ".gslides": "Google Slides",
    ".gdraw": "Google Drawing", ".gform": "Google Form", ".gsite": "Google Site",
    ".gtable": "Google Table", ".gjam": "Google Jamboard", ".gscript": "Google Apps Script",
    ".gmap": "Google My Map", ".glink": "Drive shortcut",
}
PLAIN = {".txt", ".md", ".markdown", ".csv", ".tsv", ".log", ".json",
         ".yaml", ".yml", ".rst", ".tex", ".org"}
TEXTUTIL = {".rtf", ".html", ".htm", ".doc", ".docx", ".webarchive"}
SPOTLIGHT = {".pdf", ".pages", ".numbers", ".key", ".xlsx", ".pptx", ".epub"}

MAX_ENTRIES = 50000     # a Drive of any size still finishes in seconds
MAX_DEPTH = 12
MAX_READ = 2_000_000    # never pull a 4 GB video through textutil


def human(n):
    for unit, size in (("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)):
        if n >= size:
            return "%.1f %s" % (n / float(size), unit)
    return "%d B" % n


def gstub(path):
    """The URL inside a .gdoc/.gsheet/.gslides stub, or "". These files are
    tiny JSON pointers; there is no document text in them, and inventing some
    is the one unforgivable failure mode here."""
    try:
        with open(path, "rb") as fh:
            data = json.loads(fh.read(65536).decode("utf-8", "replace"))
    except (OSError, ValueError):
        return ""
    if not isinstance(data, dict):
        return ""
    url = data.get("url") or ""
    if not url:
        # Older stubs carry only an id, sometimes as "document:<id>".
        rid = data.get("resource_id") or data.get("doc_id") or ""
        rid = str(rid).split(":")[-1]
        if rid:
            url = "https://drive.google.com/open?id=" + rid
    url = str(url)
    return url if url.startswith("https://") else ""


def walk(cutoff):
    """Every non-hidden regular file under every Drive root, modified at or
    after `cutoff`. Symlinks are skipped outright — not followed, not listed —
    so nothing outside a Drive root can be reached from inside one."""
    seen = 0
    for label, root in roots():
        stack = [(root, "", 0)]
        while stack:
            here, rel, depth = stack.pop()
            try:
                # `with` so the directory handle closes even on a huge tree.
                with os.scandir(here) as it:
                    entries = sorted(it, key=lambda e: e.name)
            except OSError:
                continue
            for entry in entries:
                if seen >= MAX_ENTRIES:
                    return
                try:
                    if entry.is_symlink():
                        continue
                    # .DS_Store, .tmp.drivedownload, .shortcut-targets-by-id:
                    # Drive's own bookkeeping, never the user's content.
                    if entry.name.startswith("."):
                        continue
                    if entry.is_dir(follow_symlinks=False):
                        if depth < MAX_DEPTH:
                            stack.append((entry.path, rel + "/" + entry.name if rel else entry.name, depth + 1))
                        continue
                    if not entry.is_file(follow_symlinks=False):
                        continue
                    st = entry.stat(follow_symlinks=False)
                except OSError:
                    continue
                seen += 1
                if st.st_mtime < cutoff:
                    continue
                yield {
                    "account": label, "folder": rel, "name": entry.name,
                    "path": entry.path, "size": st.st_size, "mtime": st.st_mtime,
                    "ext": os.path.splitext(entry.name)[1].lower(),
                    # Drive's streaming mode leaves files with no local blocks.
                    # Opening one downloads it; an index must not do that.
                    "local": not (getattr(st, "st_blocks", 1) == 0 and st.st_size > 0),
                }


def when(ts, fmt="%Y-%m-%d %H:%M"):
    return time.strftime(fmt, time.localtime(ts))


def where(item):
    return one_line("%s/%s" % (item["account"], item["folder"]) if item["folder"] else item["account"], 100)


# ── Reading text, only from things that are text ──────────────────────────

def run(argv):
    """A macOS text extractor, or None if it is missing or unhappy. Paths are
    absolute (they are built from an absolute root), so no filename can be
    read as an option, and argv means no shell ever sees one."""
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0 or not p.stdout:
        return None
    return p.stdout.decode("utf-8", "replace")


def extract(item):
    """(text, why-not). Exactly one of the two is set."""
    if not item["local"]:
        return None, "in Drive but not downloaded to this Mac"
    if item["size"] > MAX_READ:
        return None, "too large to read (%s)" % human(item["size"])
    ext = item["ext"]
    if ext in PLAIN:
        try:
            with open(item["path"], "rb") as fh:
                return fh.read(MAX_READ).decode("utf-8", "replace"), None
        except OSError:
            return None, "could not be read"
    if ext in TEXTUTIL:
        out = run(["/usr/bin/textutil", "-convert", "txt", "-stdout", item["path"]])
        return (out, None) if out else (None, "no readable text")
    if ext in SPOTLIGHT:
        # Spotlight has already indexed the text of PDFs and iWork documents.
        # Asking mdls for it adds no dependency and, unlike a PDF parser,
        # cannot be made to execute anything.
        out = run(["/usr/bin/mdls", "-raw", "-name", "kMDItemTextContent", item["path"]])
        if out and out.strip() not in ("(null)", ""):
            return out, None
        return None, "not indexed by Spotlight"
    return None, "not a text format"


# ── The three verbs ───────────────────────────────────────────────────────

def cmd_status():
    found = roots()
    if not found:
        if installed():
            print("needs-setup: Google Drive for Desktop is installed but has not synced a folder "
                  "yet — open it, sign in there, and let it finish")
        else:
            print("needs-setup: install Google Drive for Desktop to let Moe read your Drive "
                  "(no sign-in needed)")
        return 1
    folders = 0
    unreadable = 0
    for _label, root in found:
        try:
            with os.scandir(root) as it:
                for entry in it:
                    if entry.name.startswith("."):
                        continue
                    if not entry.is_symlink() and entry.is_dir(follow_symlinks=False):
                        folders += 1
        except OSError:
            unreadable += 1
    if unreadable == len(found):
        print("unavailable: found a Google Drive folder but could not read it — "
              "grant Full Disk Access to Memoe.app in System Settings › Privacy & Security")
        return 3
    print("ok: %d folder%s across %d account%s"
          % (folders, "" if folders == 1 else "s", len(found), "" if len(found) == 1 else "s"))
    return 0


def cmd_pull():
    """An index, not a dump: name, folder, size, date. No file is opened
    except a native-Google stub, which is a URL and nothing else."""
    if not roots():
        # Not connected is not "nothing new". Returning 0 with no output here
        # meant Moe answered "nothing in your Drive today" to somebody who
        # has never installed Drive at all — the one outright lie an audit of
        # every read verb found. `status` already has the sentence.
        return cmd_status()
    cutoff = time.time() - DAYS * 86400
    items = sorted(walk(cutoff), key=lambda i: i["mtime"], reverse=True)[:LIMIT]
    if not items:
        return 0
    lines = []
    natives = 0
    for item in items:
        kind = NATIVE.get(item["ext"])
        if kind:
            natives += 1
            # Even a stub is only opened once it is actually on the disk:
            # reading a streamed placeholder is what makes Drive download it.
            url = gstub(item["path"]) if item["local"] else ""
            tail = "%s — link only, contents not read%s" % (kind, (": " + one_line(url, 200)) if url else "")
        else:
            tail = human(item["size"])
            if not item["local"]:
                tail += ", not downloaded"
        lines.append("%s | %s | %s | %s"
                     % (when(item["mtime"]), where(item), one_line(item["name"], 120), tail))
    if natives:
        # Said before the list, because this is the sentence that stops Moe
        # claiming it read a Google Doc it has only ever seen the name of.
        print("Note: .gdoc, .gsheet and .gslides entries are links to documents that live on "
              "Google's servers. Moe has the name and the link, never the contents.")
    print("\n".join(lines))
    return 0


def cmd_crawl():
    """Filenames, paths and dates for everything in the window; text as well
    for the formats that are text. Newest first — when the byte cap bites, an
    index of this month is worth more than one of three years ago."""
    cutoff = time.time() - DAYS * 86400
    items = sorted(walk(cutoff), key=lambda i: i["mtime"], reverse=True)
    spent = 0
    for item in items:
        if spent >= BUDGET:
            break
        head = "### %s/%s (%s)" % (where(item), one_line(item["name"], 120), when(item["mtime"], "%Y-%m-%d"))
        kind = NATIVE.get(item["ext"])
        if kind:
            url = gstub(item["path"]) if item["local"] else ""
            body = "%s — a link to a document on Google's servers, not its contents.%s" \
                   % (kind, ("\n" + one_line(url, 200)) if url else "")
        else:
            text, why = extract(item)
            body = block(text) if text else "(%s, %s)" % (human(item["size"]), why)
        out = head + "\n" + body + "\n\n"
        spent += len(out.encode("utf-8", "replace"))
        sys.stdout.write(out)
    return 0


sys.exit({"status": cmd_status, "pull": cmd_pull, "crawl": cmd_crawl}[MODE]())
PY
}

case "${1:-status}" in
status)
  drive_py status 0 0 0
  ;;
pull)
  case "$PULL_DAYS"  in ''|*[!0-9]*) echo "MOE_DRIVE_DAYS must be a whole number of days" >&2; exit 2 ;; esac
  case "$PULL_LIMIT" in ''|*[!0-9]*) echo "MOE_DRIVE_LIMIT must be a whole number" >&2; exit 2 ;; esac
  drive_py pull "$PULL_DAYS" "$PULL_LIMIT" 0
  ;;
crawl)
  shift; crawl_args "$@"
  # The cap is applied inside (so nothing huge is ever built) and again here,
  # the way every other connector ends its crawl.
  drive_py crawl "$SINCE_DAYS" 0 "$MAX_BYTES" | { head -c "$MAX_BYTES"; cat >/dev/null; }
  exit "${PIPESTATUS[0]}"
  ;;
*) echo "usage: drive.sh [status|pull|crawl [--since DAYS] [--max-bytes N]]"; exit 2 ;;
esac
