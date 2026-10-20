#!/bin/bash
# check-hermes-seed-runs.sh <seed-dir>
#
# Refuses a Hermes seed whose Python cannot start.
#
# 0.3.13 shipped one that could not. `stage-hermes-seed.sh` copies the Hermes
# install with `cp -RL`, which dereferences the venv's interpreter symlink into
# a 17.3 MB copy — and a python-build-standalone binary copied out of its
# prefix cannot find its own standard library. It falls back to the prefix
# compiled into it, `/install`, and dies:
#
#     ModuleNotFoundError: No module named 'encodings'
#
# Every gate that seed passed on the way out was a gate about its *shape*: the
# commit stamp matched, no absolute links, no dangling links, no builder path,
# no placeholder left behind, the right size. A working seed and a dead one are
# identical under every one of those. The only difference is that one starts.
#
# So this one starts it. The seed is cloned to a scratch root, the
# `@HERMES_ROOT@` placeholder is substituted exactly as HermesSeed.swift does
# at first launch, and the venv's own python is asked to import a few modules
# and say where it thinks it lives. Both halves matter: exit 0 alone would pass
# if it had found some *other* Python on the machine, so the answer also has to
# be a prefix inside the scratch root — a user's Mac has no other interpreter
# to fall back to.
#
# On APFS the clone is `cp -Rc`: copy-on-write, no bytes moved.
set -u

SEED="${1:-}"
[ -n "$SEED" ] || { echo "usage: check-hermes-seed-runs.sh <seed-dir>" >&2; exit 2; }
[ -d "$SEED" ] || { echo "✗ no seed at $SEED" >&2; exit 1; }

[ -d "$SEED/hermes-agent/.venv" ] || {
  echo "✗ $SEED has no hermes-agent/.venv — that is not a seed" >&2; exit 1; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/moe-seed-run.XXXXXX")" || exit 1
ROOT="$SCRATCH/hermes"
trap 'rm -rf "$SCRATCH"' EXIT

# Clone, preserving symlinks. Dereferencing here would reproduce the very bug
# this is looking for and then report the seed healthy.
cp -Rc "$SEED" "$ROOT" 2>/dev/null || cp -R "$SEED" "$ROOT" || {
  echo "✗ could not clone $SEED to test it" >&2; exit 1; }

# The physical path, for the comparison at the bottom. On macOS mktemp hands
# back /var/folders/… while /var is a symlink to /private/var, so Python — which
# reports a resolved prefix — disagrees with the string we built, and a seed
# that started perfectly well from its own runtime was called a failure. The
# first run of this check found exactly that.
ROOTP="$(cd "$ROOT" && pwd -P)"

# The placeholder → this scratch root, in text files only, the way the app does.
python3 - "$ROOT" <<'PYEOF'
import os, sys

root = sys.argv[1]
for dirpath, _dirs, files in os.walk(root):
    for name in files:
        path = os.path.join(dirpath, name)
        if os.path.islink(path):
            continue
        try:
            if os.path.getsize(path) > 4_000_000:
                continue
            with open(path, "rb") as f:
                raw = f.read()
        except OSError:
            continue
        if b"@HERMES_ROOT@" not in raw:
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        mode = os.stat(path).st_mode
        with open(path, "w", encoding="utf-8") as f:
            f.write(text.replace("@HERMES_ROOT@", root))
        os.chmod(path, mode)
PYEOF

PY="$ROOT/hermes-agent/.venv/bin/python"
[ -x "$PY" ] || { echo "✗ the seed's venv has no runnable python at .venv/bin/python" >&2; exit 1; }

# yaml too: upstream's 3.14 line dropped PyYAML from Hermes's core, and Moe's
# configure-hermes.py and plugins import it — it reaches the seed only through
# its extras. A seed without it is a Moe that cannot configure its brain.
out="$("$PY" -c 'import encodings, json, ssl, sys, yaml; print(sys.base_prefix)' 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "✗ the seed's Python cannot start — this seed is a Moe that cannot think" >&2
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  echo "  The venv's bin/python3.x has to be a relative symlink into the seed's" >&2
  echo "  own runtime (tools/python-…), not a copy of it. See scripts/stage-hermes-seed.sh." >&2
  exit 1
fi

case "$out" in
  "$ROOT"/*|"$ROOTP"/*) ;;
  *) echo "✗ the seed's Python started, but from $out — outside the seed." >&2
     echo "  It found another interpreter on this Mac. A user's Mac has none." >&2
     exit 1 ;;
esac

echo "✓ the seed's Python starts, from its own runtime"

# ── Hermes itself, laid down where a Mac would put it ───────────────────────
# A seed since the Python 3.14 move carries Hermes's own tool store (tools/),
# and Hermes finds Node, npm and its browser there and nowhere else. So the
# clone is used as HERMES_HOME — exactly what HermesSeed does with ~/.hermes —
# and Hermes is asked, with lazy installs off as Memoe runs it, to start and
# to name its Node. Both answers must come from inside the clone, and the run
# must leave no dependency environment behind: a seed that "works" by
# building a new one on first launch is the self-mutation this seed exists
# to prevent.
if [ -d "$ROOT/tools" ]; then
  SCRATCH_HOME="$SCRATCH/home"
  mkdir -p "$SCRATCH_HOME"
  run_seed() {
    (cd / && env -i PATH=/usr/bin:/bin HOME="$SCRATCH_HOME" HERMES_HOME="$ROOT" \
       HERMES_DISABLE_LAZY_INSTALLS=1 "$@")
  }
  ver="$(run_seed "$ROOT/hermes-agent/.venv/bin/hermes" --version 2>&1)" || {
    echo "✗ the seed's hermes did not start:" >&2
    printf '%s\n' "$ver" | tail -5 | sed 's/^/    /' >&2
    exit 1; }
  node="$(run_seed "$PY" -c 'import hermes_bootstrap
from hermes_constants import find_node_executable
print(find_node_executable("node") or "")' 2>&1 | tail -1)"
  # Three spellings of one place: as built ($TMPDIR may end in "/", leaving a
  # "//" in it), normalised, and physical (/var is /private/var).
  ROOTN="$(cd "$ROOT" && pwd)"
  case "$node" in
    "$ROOT"/tools/*|"$ROOTN"/tools/*|"$ROOTP"/tools/*) ;;
    *) echo "✗ Hermes from the seed did not find Node in the seed's tool store (it said: ${node:-nothing})." >&2
       echo "  MCP servers and the WhatsApp bridge would ask pm to download one, and pm is not allowed to." >&2
       exit 1 ;;
  esac
  if [ -n "$(find "$ROOT/installs" -type d -name environments -mindepth 2 -maxdepth 2 2>/dev/null)" ] \
     || [ -n "$(find "$ROOT/installs" -name facts.json 2>/dev/null)" ]; then
    echo "✗ starting Hermes from the seed built a dependency environment under installs/ —" >&2
    echo "  it would boot from that, not from the signed seed." >&2
    exit 1
  fi
  echo "✓ Hermes starts from the seed and finds its own Node: $(printf '%s' "$ver" | head -1)"
fi
