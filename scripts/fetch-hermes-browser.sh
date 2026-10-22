#!/bin/bash
# Puts the browser Hermes drives — Chrome for Testing, ~330 MB — into Hermes's
# own tool store, where the 3.14 Hermes looks for it ($HERMES_HOME/tools).
#
#   fetch-hermes-browser.sh [--home <hermes-home>] [--check]
#                           [--reuse-from <old-tool-store>] [--no-download]
#
# --reuse-from: reseed-hermes.sh passes the store it just replaced, so a Mac
# moving between two 3.14 seeds keeps the browser it already has (same pinned
# build, recorded by pm with the same sha256) instead of fetching it again.
# --no-download: reuse or nothing — the reseed path is offline by design.
#
# Why this exists: the seed ships WITHOUT it (scripts/slim-hermes-tools.py), so
# the download stays its old size. Before the 3.14 move install-hermes.sh did
# the same job with `agent-browser install` into ~/.agent-browser/browsers;
# Chrome for Testing was never in the download.
#
# This is Memoe's installer acting, not Hermes lazy-installing: Hermes's own
# switches (HERMES_DISABLE_LAZY_INSTALLS, security.allow_lazy_installs: false)
# stay on. It is ONE artefact, the build the fork's pm/lock.json pins:
#
#   - Hermes's own installer (`pm.prepare_tools(["chromium"])`) fetches it.
#     pm downloads the URL the lock names and refuses bytes whose sha256 is not
#     the lock's — fail closed, nothing is published. Never "latest".
#   - Or, when ~/.agent-browser/browsers already holds exactly that build
#     (chrome-<pinned version>), it is cloned in (APFS clone: no second
#     330 MB) — after checking its version and that Google's own code
#     signature on it verifies (Team ID EQHXZ8M8AV). Any other build there
#     is not the pin and is not used.
#
# While the browser is missing the store holds `.browser-pending`, and the
# fork's browser tools answer "Memoe is still downloading its browser" rather
# than vanishing. It is removed only once pm can see the browser.
#
# Exit: 0 the browser is in the store; 1 it is not (the marker stays); 2 usage.
set -u

HHOME="${HERMES_HOME:-$HOME/.hermes}"
CHECK=0 REUSE_FROM="" NO_DOWNLOAD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --home)  HHOME="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --reuse-from) REUSE_FROM="$2"; shift 2 ;;
    --no-download) NO_DOWNLOAD=1; shift ;;
    *) echo "usage: $0 [--home <hermes-home>] [--check] [--reuse-from <store>] [--no-download]" >&2; exit 2 ;;
  esac
done
AGENT="${MOE_HERMES_AGENT:-$HHOME/hermes-agent}"
STORE="$HHOME/tools"
PY="$AGENT/.venv/bin/python"
[ -x "$PY" ] || { echo "✗ no Hermes at $AGENT (no .venv/bin/python)" >&2; exit 1; }
[ -d "$STORE" ] || { echo "✗ $STORE does not exist — this Hermes has no pm tool store" >&2; exit 1; }

# PYTHONPATH: a test may put a pm of its own (a lock pointing at a local
# server) ahead of the agent's.
cd / && exec env HERMES_HOME="$HHOME" HERMES_RUNTIME_DIR="$STORE" HERMES_DISABLE_LAZY_INSTALLS=1 \
  PYTHONPATH="${MOE_PM_PATH:+$MOE_PM_PATH:}$AGENT" \
  "$PY" - "$STORE" "${MOE_AGENT_BROWSER_HOME:-$HOME}" "$CHECK" "$REUSE_FROM" "$NO_DOWNLOAD" <<'PY'
import json, os, plistlib, shutil, subprocess, sys
from pathlib import Path

store, home, check = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3] == "1"
reuse_from = Path(sys.argv[4]) if sys.argv[4] else None
no_download = sys.argv[5] == "1"
marker = store / ".browser-pending"

try:
    import pm
    from pm import current_target, get_package, paths
    # In-process, not pm.client: the client runs installs in a worker env it
    # first builds from PyPI (hermes-pm-runtime) — a second environment on the
    # person's Mac, and a network dependency the pinned artefact does not need.
    from pm.build_operations import prepare_tools
except ImportError as exc:
    print(f"✗ this Hermes has no pm ({exc}); nothing to fetch into")
    sys.exit(1)

target = current_target()
lock = pm.Lockfile(paths.lockfile_path())
version = lock.version("chromium")
artifacts = lock.artifacts("chromium", target)
if not version or not artifacts:
    print(f"✗ the fork's pm/lock.json pins no Chromium for {target}")
    sys.exit(1)
chrome = version.partition("+")[2]
sha = artifacts[0]["sha256"]


def present() -> bool:
    got = pm.installed_package("chromium")
    return bool(got and got.binary and got.binary.is_file())


def finish(how: str) -> None:
    marker.unlink(missing_ok=True)
    got = pm.installed_package("chromium")
    print(f"✓ browser in Hermes's tool store: Chrome for Testing {chrome} ({how}) at {got.binary}")
    sys.exit(0)


if present():
    if not check:
        marker.unlink(missing_ok=True)
    print(f"✓ browser already in Hermes's tool store: Chrome for Testing {chrome}")
    sys.exit(0)
if check:
    print(f"› the browser is not in the store yet (pinned: Chrome for Testing {chrome}, sha256 {sha[:12]}…)")
    sys.exit(1)

marker.write_text("Alfie's installer is putting the pinned Chromium here "
                  "(scripts/fetch-hermes-browser.sh) and removes this file.\n")


def publish(src: Path, layout_parent: str | None, how: str) -> None:
    """Clone ``src`` into the store as pm's chromium entry, record it, and finish if pm sees it."""
    package = get_package("chromium")
    entry = store / package.store_entry(version, target)
    staging = store / f".{entry.name}.moe-reuse"
    shutil.rmtree(staging, ignore_errors=True)
    dest = staging / layout_parent / src.name if layout_parent else staging
    dest.parent.mkdir(parents=True, exist_ok=True)
    # clonefile: the same blocks, not a second 330 MB.
    if subprocess.run(["/bin/cp", "-Rc", str(src), str(dest)]).returncode != 0:
        shutil.rmtree(staging, ignore_errors=True)
        print(f"› could not copy {src}; not reused")
        return
    (staging / "INSTALLATION_COMPLETE").write_text("")
    reason = package.verify(staging, target)
    if reason:
        shutil.rmtree(staging, ignore_errors=True)
        print(f"› {src} is not a browser pm accepts ({reason}); not reused")
        return
    shutil.rmtree(entry, ignore_errors=True)
    staging.rename(entry)
    facts = pm.Facts(store / "facts.json")
    facts.record("chromium", version, entry.name, package.env(entry, target), store,
                 target=target, artifacts=[a["sha256"] for a in artifacts])
    facts.refresh_digests(store)
    if present():
        finish(how)
    print(f"› reusing {src} did not give pm a browser; not reused")


# ── 0. the store this one replaced, when it held the same pinned build ───────
if reuse_from is not None:
    try:
        old = json.loads((reuse_from / "facts.json").read_text()).get("packages", {}).get("chromium")
    except (OSError, ValueError):
        old = None
    if old and old.get("version") == version and sha in (old.get("artifacts") or []) \
            and (reuse_from / old.get("entry", "")).is_dir() and old.get("entry"):
        publish(reuse_from / old["entry"], None, f"kept from the previous tool store, sha256 {sha[:12]}… as recorded by pm")
    elif old:
        print(f"› the previous store's browser ({old.get('version')}, sha256 "
              f"{','.join(a[:12] for a in old.get('artifacts') or []) or 'unrecorded'}) is not the pinned "
              f"{version} (sha256 {sha[:12]}); not reused")

# ── 1. reuse the pinned build if agent-browser already downloaded it ─────────
def reusable() -> Path | None:
    base = home / ".agent-browser" / "browsers" / f"chrome-{chrome}"
    for app in (base / "Google Chrome for Testing.app",
                base / "chrome-mac-arm64" / "Google Chrome for Testing.app",
                base / "chrome-mac-x64" / "Google Chrome for Testing.app"):
        if not app.is_dir():
            continue
        try:
            info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
        except (OSError, plistlib.InvalidFileException):
            return None
        if info.get("CFBundleShortVersionString") != chrome:
            print(f"› {app} says it is {info.get('CFBundleShortVersionString')}, not the pinned {chrome}; not reused")
            return None
        req = 'anchor apple generic and certificate leaf[subject.OU] = "EQHXZ8M8AV"'
        ok = subprocess.run([os.environ.get("MOE_CODESIGN", "/usr/bin/codesign"), "--verify", "--deep",
                             "--strict", f"-R={req}", str(app)],
                            capture_output=True, text=True)
        if ok.returncode != 0:
            print(f"› {app} does not carry Google's valid signature; not reused ({ok.stderr.strip()[:200]})")
            return None
        return app
    return None


app = reusable()
if app is not None:
    plat = "chrome-mac-arm64" if target == "darwin-arm64" else "chrome-mac-x64"
    publish(app, plat, f"reused from {app.parent}, Google's signature verified")

if no_download:
    print("› not downloading (--no-download); the browser stays pending")
    sys.exit(1)

# ── 2. Hermes's own installer: the pinned URL, the pinned sha256 ─────────────
print(f"› downloading Chrome for Testing {chrome} (~330 MB, sha256 {sha[:12]}… pinned by pm/lock.json)")
try:
    prepare_tools(["chromium"], out=store, target=target)
except Exception as exc:  # pm.InstallError on a bad hash, OSError offline: nothing published
    print(f"✗ the browser did not install: {exc}")
    sys.exit(1)
if present():
    finish("downloaded, sha256 verified by pm")
print("✗ pm finished but cannot see a browser in the store")
sys.exit(1)
PY
