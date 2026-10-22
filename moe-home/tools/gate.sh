#!/bin/bash
# gate.sh — the list of what Moe's send gate does with every tool, and the
# place to change your mind.
#
#   gate.sh list [word]      every tool Moe knows of, and whether it asks
#   gate.sh why <tool>       what the gate does with one tool, and why
#   gate.sh allow <tool>     run it without asking, from now on — a call that
#                            carries a recipient and a message is still shown:
#                            allowing silences acts, never messages
#   gate.sh ask <tool>       ask every time, from now on (beats any label)
#   gate.sh forget <tool>    drop your decision; back to what is declared
#   gate.sh trust <server>   run that server's tools without asking — a call
#                            that looks like a message still asks
#   gate.sh distrust <server>
#
# How the gate decides, in order, first answer wins:
#   1. your decision (this file's allow/ask/trust, or "Always allow" in the
#      dialog) — kept in ~/.moe/gate/policy.json, which nothing the agent
#      runs may write;
#   2. Moe's connector manifests (verbs= / sends=);
#   3. Moe's table of Hermes's own tools;
#   4. the server's own labels (readOnlyHint), when they say anything —
#      a server that labels every tool the same has said nothing;
#   5. otherwise it asks, and offers to remember.
# The classifier itself lives in hermes/hooks/confirm-send.sh; this script
# only reads its inventory and edits the policy file, so there is exactly one
# definition of "what does this tool do".
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MOE_HOME="${MOE_HOME:-$HOME/.moe}"
POLICY="$MOE_HOME/gate/policy.json"
HOOK=""
for candidate in "$HERE/../hermes/hooks/confirm-send.sh" "$MOE_HOME/hermes/hooks/confirm-send.sh"; do
  if [ -r "$candidate" ]; then HOOK="$candidate"; break; fi
done
if [ -z "$HOOK" ]; then
  echo "gate.sh: cannot find hermes/hooks/confirm-send.sh — run scripts/install.sh" >&2
  exit 1
fi

CMD="${1:-list}"
ARG="${2:-}"

inventory() { MOE_HOME="$MOE_HOME" bash "$HOOK" --inventory; }

edit_policy() { # decision-kind(tools|servers) name decision|forget
  ( umask 077
    mkdir -p "$MOE_HOME/gate" || exit 1
    python3 - "$POLICY" "$1" "$2" "$3" <<'PY'
import datetime, json, os, sys
path, table, name, decision = sys.argv[1:5]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    data = {}
if not isinstance(data, dict):
    data = {}
data.setdefault("version", 1)
rows = data.setdefault(table, {})
if decision == "forget":
    rows.pop(name, None)
else:
    rows[name] = {"decision": decision, "by": "you, with gate.sh",
                  "when": datetime.datetime.now().isoformat(timespec="seconds")}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=1, sort_keys=True)
    fh.write("\n")
os.replace(tmp, path)
PY
  )
}

case "$CMD" in
  list)
    inventory | python3 -c '
import signal, sys
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
word = sys.argv[1].lower()
rows = [l.rstrip("\n").split("\t") for l in sys.stdin if l.strip()]
rows = [r for r in rows if len(r) == 4]
# Own connector verbs appear twice (bare, and through the moe bridge): once is enough.
rows = [r for r in rows if not r[0].startswith("mcp__moe__")]
if word:
    rows = [r for r in rows if word in r[0].lower() or word in r[3].lower()]
if not rows:
    print("nothing matches" if word else "no tools known — is Hermes installed?"); sys.exit(0)
def server_of(name):
    return name.split("__")[1] if name.startswith("mcp__") and name.count("__") >= 2 else ""
asks = sum(1 for r in rows if r[2].startswith("asks"))
runs = sum(1 for r in rows if r[2].startswith("runs"))
print("%d tools: %d run without asking, %d ask first, %d follow shell/key rules" % (
    len(rows), runs, asks, len(rows) - asks - runs))
print()
# Without a filter, a server with many tools is one line, not two thousand.
groups = {}
for r in rows:
    groups.setdefault(server_of(r[0]), []).append(r)
FOLD = 25
shown = []
for srv in sorted(groups, key=lambda k: (k != "", k)):
    g = groups[srv]
    if not word and srv and len(g) > FOLD:
        a = sum(1 for r in g if r[2].startswith("asks")); u = sum(1 for r in g if r[2].startswith("runs"))
        why = sorted({r[3] for r in g}, key=lambda w: -sum(1 for r in g if r[3] == w))[0]
        print("%-24s  %5d tools — %d run, %d ask   %s" % (srv, len(g), u, a, why))
        print("%-24s         gate.sh list %s to see them; gate.sh trust %s to let them run" % ("", srv, srv))
    else:
        shown.extend(g)
if shown:
    print()
    width = min(max(len(r[0]) for r in shown), 56)
    for name, kind, human, why in shown:
        print("%-*s  %-28s %s" % (width, name[:56], human, why))
print()
print("gate.sh why <tool> · allow <tool> · ask <tool> · forget <tool> · trust <server>")
' "$ARG"
    ;;
  why)
    [ -n "$ARG" ] || { echo "gate.sh why <tool>" >&2; exit 2; }
    LINE="$(inventory | awk -F'\t' -v t="$ARG" '$1 == t')"
    if [ -z "$LINE" ]; then
      echo "$ARG: not a tool Alfie knows of right now. If it is called, the gate asks"
      echo "(nothing has declared it), and the dialog offers to remember your answer."
      exit 0
    fi
    printf '%s\n' "$LINE" | awk -F'\t' '{ printf "%s\n  %s\n  because: %s\n", $1, $3, $4 }'
    ;;
  allow|ask)
    [ -n "$ARG" ] || { echo "gate.sh $CMD <tool>" >&2; exit 2; }
    DECISION=run; [ "$CMD" = "ask" ] && DECISION=ask
    if [ "$CMD" = "allow" ]; then
      case "$(printf '%s' "$ARG" | tr 'A-Z' 'a-z')" in
        *send*|*reply*|*forward*|*post*|*publish*|*notify*|*tweet*|*_dm|*_dm_*|*mail*)
          echo "note: '$ARG' reads like something that sends. Allowing it stops the" >&2
          echo "      act dialog; a call carrying a recipient and a message is still shown." >&2 ;;
      esac
    fi
    edit_policy tools "$ARG" "$DECISION" && {
      if [ "$DECISION" = run ]; then echo "$ARG will run without asking, from now on."
      else echo "$ARG will ask every time, from now on."; fi
    }
    ;;
  forget)
    [ -n "$ARG" ] || { echo "gate.sh forget <tool|server>" >&2; exit 2; }
    edit_policy tools "$ARG" forget && edit_policy servers "$ARG" forget \
      && echo "$ARG: your decision is dropped; the gate goes by what is declared."
    ;;
  trust)
    [ -n "$ARG" ] || { echo "gate.sh trust <server>" >&2; exit 2; }
    edit_policy servers "$ARG" run \
      && echo "$ARG's tools run without asking. A call that looks like a message still asks."
    ;;
  distrust)
    [ -n "$ARG" ] || { echo "gate.sh distrust <server>" >&2; exit 2; }
    edit_policy servers "$ARG" forget && echo "$ARG: back to its own labels."
    ;;
  -h|--help|help)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "gate.sh: unknown command '$CMD' — try: list, why, allow, ask, forget, trust, distrust" >&2
    exit 2
    ;;
esac
