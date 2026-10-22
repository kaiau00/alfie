#!/usr/bin/env python3
"""What Alfie knows how to do, and the one key that turns a piece of it off.

Settings › Skills reads this. `hermes skills list` prints a rich table with
no `--json` anywhere in the subcommand, and it truncates every name past
twenty characters — `calendar-meeting-jo…`, `songwriting-and-ai-…` — so the
one thing a pane needs from it, a name it can write back into config, is the
one thing it does not give. This reads the same three stores that command
reads and answers in JSON.

    skills-catalogue.py list
    skills-catalogue.py set --name NAME --state on|off

**The stores, and which fact each one owns.** None of them is guessed at:

  ~/.hermes/skills/<category>/<name>/SKILL.md   the skill itself. The
      directory above it is the category; the frontmatter is the name, the
      description, and what the skill needs installed.
  ~/.hermes/skills/.bundled_manifest            the names Hermes shipped.
      `name:hash` per line (v2) or a bare name (v1); both are in the wild
      and both are read, exactly as `tools/skills_sync._read_manifest` does.
  ~/.hermes/skills/.hub/lock.json               the ones installed from a
      registry, with the source and the trust level the scanner gave them.
  ~/.hermes/skills/.usage.json                  how many times each has been
      opened, and when last. Hermes's own counter, not ours.
  ~/.hermes/config.yaml `skills.disabled`       the only thing we write.

**`prerequisites.commands` is checked here because nothing else checks it.**
A SKILL.md may declare the commands it shells out to. `tools/skills_tool.py`
builds its result with `"required_commands": []` and
`"missing_required_commands": []` **hard-coded** (measured 2026-09-04, lines
1874 and 1877), so the model is never told a skill's command is absent: it
reads the skill, runs `memo`, gets `command not found`, and spends the turn
finding out. That is why §4.5 calls curation a security property rather than
a nicety, and it is bigger than the four names Alfie disables — on this Mac
**eleven** of the fourteen skills that declare a command are missing it, and
seven of those eleven are switched on.

**The command search does not use PATH alone.** A GUI application launched
from the Dock inherits launchd's PATH, which is `/usr/bin:/bin:/usr/sbin:
/sbin` — no Homebrew, no `~/.local/bin` — so a `shutil.which` answer taken
inside Alfie would report half the machine missing. The directories Hermes
itself would find a command in are searched as well, and the answer is about
the *machine*, not about this process's environment.

**The write is surgical, and it is verified.** `config.yaml` opens with a
twenty-line comment block that `configure-hermes.py` re-writes on every
launch and that a `yaml.safe_load` → `safe_dump` round-trip silently
destroys. So the `disabled:` list is replaced as TEXT, in place, and then —
where PyYAML is available — the file is parsed again and compared against
what it should be. Anything different anywhere else and the backup goes
back and the write is reported as refused. Without PyYAML there is no
verification available, so there is no write either: `can_write` is false
and the pane says so rather than editing a shared file blind.

**Hermes subtracts `ESSENTIAL_SKILLS` from whatever is in that key**
(`agent/skill_utils.py`: `frozenset({"hermes-agent"})`), so a name written
there by mistake cannot take out something Hermes needs. This refuses to
write it anyway: a switch that appears to work and is undone by the loader
is worse than one that says no.

One JSON object on stdout, always: `{"ok": true, …}` or
`{"ok": false, "error": "…"}`, and exit 0 for both — a refusal is an answer
with words in it. A non-zero exit with no JSON means this crashed, which is
a different thing the pane says differently.

Read-only except for `set`. Python 3.9, stdlib only for everything but the
verification, which imports PyYAML when it is there and does without when it
is not.
"""

import argparse
import json
import os
import re
import shutil
import sys
import tempfile
import time

#: Hermes refuses to disable these, so neither do we.
#: `agent/skill_utils.ESSENTIAL_SKILLS`, read 2026-09-04.
ESSENTIAL = frozenset(("hermes-agent",))

#: Directory names that are never a skill. `agent/skill_utils` splits these
#: into two frozensets — junk (`.git`, `node_modules`, `__pycache__`) and the
#: four progressive-disclosure support directories that live INSIDE a skill.
#: Both are pruned here for the same reason it prunes them: a skill package
#: preserved under `references/` still has a SKILL.md, and listing it as a
#: skill would offer a switch for something the loader never loads.
EXCLUDED_DIRS = frozenset((
    ".git", ".github", ".hub", ".archive", ".venv", "venv", "node_modules",
    "site-packages", "__pycache__", ".tox", ".nox", ".pytest_cache",
    ".mypy_cache", ".ruff_cache",
))
SUPPORT_DIRS = frozenset(("references", "templates", "assets", "scripts"))

#: Where a command might be, beyond whatever PATH this process was handed.
#:
#: Moe launched from the Dock has launchd's PATH — /usr/bin:/bin:/usr/sbin:
#: /sbin — and nothing else. Asking `shutil.which` under that would report
#: `jq`, `curl` from Homebrew and everything in ~/.local/bin as missing, and
#: the pane would tell a person their machine was empty. The question is
#: "does this Mac have the command", so the places a Mac keeps commands are
#: searched too.
EXTRA_BIN_DIRS = (
    "/opt/homebrew/bin", "/opt/homebrew/sbin",
    "/usr/local/bin", "/usr/local/sbin",
    "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    "~/.local/bin", "~/bin", "~/.cargo/bin",
    "/opt/local/bin",
)

#: Every key each answer carries, whether or not it has anything to say.
#:
#: A contract with Swift, not tidiness. Swift's synthesised `Decodable` does
#: NOT fall back to a property's default for a missing key — it throws
#: `keyNotFound` and the WHOLE answer decodes to nothing. One absent `error`
#: on a success turned a working Reminders pane into "Moe couldn't reach the
#: part of itself that keeps the clock" on 2026-09-04, after the work was
#: done. The Swift side reads every key with `decodeIfPresent` as well; this
#: is the second of two halves, because the failure is silent in exactly the
#: direction that matters.
SHAPES = {
    "list": {"ok": False, "error": "", "skills": [], "disabled": [],
             "essential": sorted(ESSENTIAL), "can_write": False, "why_not": "",
             "config": "", "root": "", "counted": 0},
    "set": {"ok": False, "error": "", "name": "", "state": "",
            "disabled": [], "changed": False},
}

#: Every key a skill row carries. Same contract, one level down.
ROW = {
    "name": "", "category": "", "description": "", "source": "", "trust": "",
    "enabled": True, "essential": False, "path": "", "needs": [], "missing": [],
    "uses": 0, "last_used": "", "only_in": [], "platforms": [],
}


def answer(kind, fields):
    out = dict(SHAPES[kind])
    out.update(fields)
    return out


def emit(obj):
    json.dump(obj, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def hermes_home():
    # `.get(k, default)` returns "" for a variable that is SET and empty, and
    # expanduser("") is "" — so HERMES_HOME= would point every path below at
    # the current directory. `or` is the idiom this repo uses.
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def skills_root():
    return os.path.join(hermes_home(), "skills")


def config_path():
    return os.path.join(hermes_home(), "config.yaml")


def load_json(path, fallback):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return fallback


# ---------------------------------------------------------------------------
# The skills on disk
# ---------------------------------------------------------------------------

#: A frontmatter line: `key: value`, at the very start of the line.
#:
#: A narrow reader rather than PyYAML, and it is narrow on measurement, not
#: on hope: all 96 SKILL.md files on this Mac carry `description` as a
#: single-line scalar — 68 quoted, 28 bare — and not one uses a `>` or `|`
#: block. So the three fields this needs are exactly the shape this reads,
#: and a file that ever isn't gets an empty description rather than a wrong
#: one or a crash.
_FIELD = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):[ \t]*(.*)$")
#: `commands: [memo, jq]` and the block form under `prerequisites:`.
_INLINE_LIST = re.compile(r"^\[(.*)\]$")


def unquote(text):
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    return text


def frontmatter(path):
    """What a SKILL.md declares about itself, as a dict of five fields.

    An empty dict for a file with no frontmatter, which is not an error: the
    loader indexes such a skill by its directory name, and so does the
    caller.

    `platforms` and `environments` are read because Hermes FILTERS on them
    (`agent/skill_utils.skill_matches_platform` / `skill_matches_environment`)
    and this must not disagree with what Hermes actually offers. Measured on
    this Mac: 89 skills declare `platforms` and every one of them includes
    macos, so that field changes nothing here — it is read anyway rather
    than assumed, because "it happens to be true today" is not a rule.
    `environments` is declared by exactly one skill (`sdlc-review`, kanban),
    and it is the whole of the difference between the 96 skills on disk and
    the 94 `hermes skills list` prints. Without this, that one skill would
    show a switch that changes nothing a person can see.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            head = f.read(16384)
    except OSError:
        return {}
    if not head.startswith("---"):
        return {}
    end = head.find("\n---", 3)
    if end < 0:
        return {}
    block = head[head.index("\n") + 1:end + 1]

    out = {"name": "", "description": "", "commands": [],
           "platforms": [], "environments": []}
    lines = block.splitlines()
    for i, line in enumerate(lines):
        m = _FIELD.match(line)
        if not m:
            continue
        key, value = m.group(1), m.group(2).strip()
        if key == "name" and not out["name"]:
            out["name"] = unquote(value)
        elif key == "description" and not out["description"]:
            out["description"] = unquote(value)
        elif key == "prerequisites":
            out["commands"] = _commands_under(lines, i)
        elif key in ("platforms", "environments") and not out[key]:
            out[key] = _list_at(lines, i, value)
    return out


def _list_at(lines, index, rest):
    """A YAML list written either way: `[a, b]` on the line, or `- a` under it."""
    inline = _INLINE_LIST.match(rest)
    if inline:
        return [unquote(p) for p in inline.group(1).split(",") if p.strip()]
    if rest:
        return [unquote(rest)]
    out = []
    j = index + 1
    while j < len(lines) and lines[j].strip().startswith("- "):
        out.append(unquote(lines[j].strip()[2:]))
        j += 1
    return [v for v in out if v]


def _commands_under(lines, start):
    """`commands:` inside the indented block that follows `prerequisites:`.

    Both spellings are in the live tree: `commands: [memo]` on one line, and
    a `- memo` block under it. Anything at indent zero ends the block, which
    is what stops a later top-level `commands:` being read as this one's.
    """
    out = []
    i = start + 1
    while i < len(lines):
        line = lines[i]
        if line.strip() and not line[:1].isspace():
            break
        stripped = line.strip()
        if stripped.startswith("commands:"):
            rest = stripped[len("commands:"):].strip()
            inline = _INLINE_LIST.match(rest)
            if inline:
                out = [unquote(p) for p in inline.group(1).split(",") if p.strip()]
            elif rest:
                out = [unquote(rest)]
            else:
                j = i + 1
                while j < len(lines) and lines[j].strip().startswith("- "):
                    out.append(unquote(lines[j].strip()[2:]))
                    j += 1
            break
        i += 1
    return [c for c in out if c]


def have(command):
    """Is this command on this MAC — not merely on this process's PATH.

    See EXTRA_BIN_DIRS. A bare name with a slash in it is a path, and is
    tested as one.
    """
    if not command:
        return True
    if os.sep in command:
        return os.path.isfile(os.path.expanduser(command)) and \
            os.access(os.path.expanduser(command), os.X_OK)
    if shutil.which(command):
        return True
    for d in EXTRA_BIN_DIRS:
        candidate = os.path.join(os.path.expanduser(d), command)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return True
    return False


def walk_skills(root):
    """Every directory under `root` holding a SKILL.md, with its category.

    The category is the FIRST path segment under the root, which is how
    `hermes skills list` derives it and how `configure-hermes.py` builds an
    install destination. A skill sitting directly in the root has no
    category, which is a real shape (`skills/<name>/SKILL.md`) and comes
    back as "".
    """
    found = []
    if not os.path.isdir(root):
        return found
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIRS
                       and not d.startswith(".")]
        if "SKILL.md" not in filenames:
            continue
        rel = os.path.relpath(dirpath, root)
        parts = [] if rel == "." else rel.split(os.sep)
        if any(p in EXCLUDED_DIRS for p in parts):
            continue
        # A SKILL.md under references/ or templates/ belongs to the skill
        # above it — it is documentation the loader never activates.
        if len(parts) >= 2 and parts[-2] in SUPPORT_DIRS:
            continue
        if not parts:
            continue
        found.append((dirpath, parts[0] if len(parts) > 1 else "",
                      parts[-1]))
    return found


def catalogue():
    """Every skill on disk, with where it came from and whether it can run."""
    root = skills_root()
    manifest = read_manifest(root)
    hub = load_json(os.path.join(root, ".hub", "lock.json"), {})
    installed = hub.get("installed") if isinstance(hub, dict) else {}
    installed = installed if isinstance(installed, dict) else {}
    usage = load_json(os.path.join(root, ".usage.json"), {})
    usage = usage if isinstance(usage, dict) else {}
    disabled = set(read_disabled())

    rows = []
    for path, category, folder in walk_skills(root):
        fm = frontmatter(os.path.join(path, "SKILL.md"))
        commands = fm.get("commands") or []
        description = fm.get("description") or ""
        # The frontmatter name wins, because that is the name Hermes indexes
        # and therefore the name `skills.disabled` has to carry. The folder
        # is the fallback for a SKILL.md with no frontmatter at all.
        name = fm.get("name") or folder
        entry = installed.get(name) if isinstance(installed.get(name), dict) else None
        if entry:
            source = str(entry.get("source") or "hub")
            trust = str(entry.get("trust_level") or "community")
        elif name in manifest:
            source, trust = "builtin", "builtin"
        else:
            source, trust = "local", "local"
        seen = usage.get(name) if isinstance(usage.get(name), dict) else {}
        row = dict(ROW)
        row.update({
            "name": name,
            "category": category,
            "description": description,
            "source": source,
            # `hermes skills list` shows "official" in the trust column for a
            # skill whose SOURCE is official, whatever the scanner recorded.
            # Kept identical so two screens do not disagree about one word.
            "trust": "official" if source == "official" else trust,
            "enabled": name not in disabled,
            "essential": name in ESSENTIAL,
            "path": path,
            "needs": commands,
            "missing": [c for c in commands if not have(c)],
            "uses": int(seen.get("use_count") or 0),
            "last_used": str(seen.get("last_used_at") or ""),
            "only_in": [str(v) for v in (fm.get("environments") or [])],
            "platforms": [str(v) for v in (fm.get("platforms") or [])],
        })
        rows.append(row)
    rows.sort(key=lambda r: (r["category"], r["name"]))
    return rows, sorted(disabled), root


def read_manifest(root):
    """The names Hermes shipped. `name:hash` (v2) or a bare name (v1).

    Both formats are live — `tools/skills_sync._read_manifest` reads both —
    and a v1 line has no colon, so splitting unconditionally would produce
    an empty name and every builtin would read as local.
    """
    out = set()
    try:
        with open(os.path.join(root, ".bundled_manifest"), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                out.add(line.split(":", 1)[0].strip() if ":" in line else line)
    except OSError:
        return set()
    return out


# ---------------------------------------------------------------------------
# skills.disabled — the one key this writes
# ---------------------------------------------------------------------------

def config_text():
    try:
        with open(config_path(), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def yaml_module():
    """PyYAML, or None. Present under the Hermes venv, absent under
    /usr/bin/python3 — and the difference decides whether this may write."""
    try:
        import yaml  # noqa: F401
        return yaml
    except Exception:
        return None


def read_disabled():
    """The names in `skills.disabled`.

    PyYAML where it is there. Where it is not, a narrow read of the one
    block — which is enough to SHOW the switches correctly on a Mac with no
    venv, and is never enough to write one.
    """
    text = config_text()
    if text is None:
        return []
    yaml = yaml_module()
    if yaml is not None:
        try:
            cfg = yaml.safe_load(text) or {}
        except Exception:
            return narrow_disabled(text)
        return normalise(((cfg.get("skills") or {}) if isinstance(cfg, dict) else {}).get("disabled"))
    return narrow_disabled(text)


def normalise(value):
    """Hermes's own normalisation, and the bug it names.

    `skills_config._normalize_skill_names`: YAML null is empty, and a bare
    scalar (`disabled: my-skill`) is a ONE-ITEM list — not a set of its
    characters, which is issue #13026 upstream and would here turn one
    disabled skill into twelve switches for letters.
    """
    if value is None:
        return []
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, (list, tuple, set)):
        return []
    return sorted({str(v).strip() for v in value if str(v).strip()})


def narrow_disabled(text):
    """`skills:` → `disabled:` read out of the text, without a YAML parser.

    Only ever used to DISPLAY. The block form and the inline `[]` form are
    both read because `configure-hermes.py` writes the first and a person
    editing by hand writes the second.
    """
    lines = text.splitlines()
    start = block_bounds(lines)
    if start is None:
        return []
    _, key_line, first, last = start
    if key_line is None:
        return []
    rest = lines[key_line].split(":", 1)[1].strip()
    inline = _INLINE_LIST.match(rest)
    if inline:
        return normalise([unquote(p) for p in inline.group(1).split(",") if p.strip()])
    return normalise([unquote(lines[i].strip()[2:]) for i in range(first, last)
                      if lines[i].strip().startswith("- ")])


def block_bounds(lines):
    """Where `skills:` and its `disabled:` list sit in the file.

    Returns `(skills_line, disabled_line, first_item, end)` — `end` is one
    past the last item — or None when there is no top-level `skills:` key.
    `disabled_line` is None when the section exists without that key.

    Top-level means column zero: a `skills:` nested under something else is
    a different key entirely, and replacing it would move a stranger's
    setting.
    """
    skills_line = None
    for i, line in enumerate(lines):
        if line.startswith("skills:") and not line[:1].isspace():
            skills_line = i
            break
    if skills_line is None:
        return None
    disabled_line = None
    i = skills_line + 1
    while i < len(lines):
        line = lines[i]
        if line.strip() and not line[:1].isspace():
            break            # back at column zero: the section ended
        if re.match(r"^\s+disabled:", line):
            disabled_line = i
            break
        i += 1
    if disabled_line is None:
        return skills_line, None, None, None
    first = disabled_line + 1
    end = first
    while end < len(lines):
        stripped = lines[end].strip()
        if not stripped:
            break
        if not lines[end][:1].isspace():
            break
        if not stripped.startswith("- "):
            break
        end += 1
    return skills_line, disabled_line, first, end


def render(names, indent="  "):
    if not names:
        return ["%sdisabled: []" % indent]
    return ["%sdisabled:" % indent] + ["%s- %s" % (indent, n) for n in names]


def rewrite(text, names):
    """The file with only `skills.disabled` changed, as text.

    Text, not a YAML round-trip, and the reason is in the header: this file
    opens with twenty lines of comment that `safe_dump` deletes without a
    word. Three shapes have to be handled because all three occur — the key
    present with a list, the section present without the key, and no section
    at all.
    """
    lines = text.splitlines()
    bounds = block_bounds(lines)
    if bounds is None:
        tail = "" if text.endswith("\n") or not text else "\n"
        return text + tail + "\n".join(["skills:"] + render(names)) + "\n"
    skills_line, disabled_line, first, end = bounds
    if disabled_line is None:
        out = lines[:skills_line + 1] + render(names) + lines[skills_line + 1:]
        return "\n".join(out) + "\n"
    indent = lines[disabled_line][:len(lines[disabled_line]) - len(lines[disabled_line].lstrip())]
    out = lines[:disabled_line] + render(names, indent) + lines[end:]
    return "\n".join(out) + "\n"


def atomic_write(path, content):
    """Beside, then rename — the same shape `install.sh` uses on a bundle.
    An interrupted write must leave the config that was working."""
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".moe-skills-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def do_set(name, state):
    name = (name or "").strip()
    if not name:
        return answer("set", {"error": "No skill was named."})
    if name in ESSENTIAL:
        # Hermes subtracts these from the key on read, so writing one would
        # be a switch that appears to work and is undone by the loader. A
        # well-formed setting that resolves to nothing is worse than a
        # refusal, because a refusal is honest.
        return answer("set", {"name": name, "state": state,
                              "error": "%s can't be switched off — Alfie needs it to "
                                       "work at all." % name})
    yaml = yaml_module()
    if yaml is None:
        return answer("set", {
            "name": name, "state": state,
            "error": "Alfie can't safely change that from here — it has no way to "
                     "check its own work afterwards."})
    text = config_text()
    if text is None:
        return answer("set", {"name": name, "state": state,
                              "error": "Alfie couldn't find its settings file."})
    try:
        before = yaml.safe_load(text) or {}
    except Exception as e:
        return answer("set", {"name": name, "state": state,
                              "error": "Alfie's settings file didn't parse: %s" % e})
    if not isinstance(before, dict):
        return answer("set", {"name": name, "state": state,
                              "error": "The settings file isn't in the shape Alfie expects."})

    current = normalise(((before.get("skills") or {}) if isinstance(before.get("skills"), dict) else {}).get("disabled"))
    wanted = sorted(set(current) - {name}) if state == "on" else sorted(set(current) | {name})
    if wanted == current:
        return answer("set", {"ok": True, "name": name, "state": state,
                              "disabled": current, "changed": False})

    backup = "%s.%s.moe-skills.bak" % (config_path(), time.strftime("%Y%m%d-%H%M%S"))
    n = 1
    while os.path.exists(backup):
        backup = "%s.%s-%d.moe-skills.bak" % (config_path(), time.strftime("%Y%m%d-%H%M%S"), n)
        n += 1
    try:
        atomic_write(backup, text)
        atomic_write(config_path(), rewrite(text, wanted))
    except OSError as e:
        return answer("set", {"name": name, "state": state,
                              "error": "Alfie couldn't save that: %s" % e})

    # THE check this write exists to survive. A surgical text edit can go
    # wrong in exactly one interesting way — it can hit the wrong block — and
    # nothing downstream would notice until a person's approvals list or
    # platform toolsets had quietly moved. So the file is parsed again and
    # compared against what it should be, key for key. Anything else changed
    # and the backup goes back.
    expected = json.loads(json.dumps(before, default=str))
    expected.setdefault("skills", {})
    if not isinstance(expected["skills"], dict):
        expected["skills"] = {}
    expected["skills"]["disabled"] = wanted
    try:
        after = yaml.safe_load(config_text() or "") or {}
        same = json.loads(json.dumps(after, default=str)) == expected
    except Exception:
        same = False
    if not same:
        try:
            atomic_write(config_path(), text)
        except OSError:
            pass
        return answer("set", {
            "name": name, "state": state, "disabled": current,
            "error": "Alfie changed more of its settings than it meant to, so it "
                     "put them back. Nothing was switched."})
    return answer("set", {"ok": True, "name": name, "state": state,
                          "disabled": wanted, "changed": True})


def do_list():
    root = skills_root()
    if not os.path.isdir(root):
        return answer("list", {
            "error": "There are no skills on this Mac yet.",
            "root": root, "config": config_path()})
    rows, disabled, root = catalogue()
    yaml = yaml_module()
    return answer("list", {
        "ok": True,
        "skills": rows,
        "disabled": disabled,
        "can_write": yaml is not None and os.path.isfile(config_path()),
        "why_not": "" if yaml is not None else
                   "Alfie can't change these from here — the part of itself that "
                   "edits settings safely isn't installed.",
        "config": config_path(),
        "root": root,
        "counted": len(rows),
    })


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action", choices=("list", "set"))
    # `--name=NAME`, joined, at the call site. A skill may legitimately be
    # called `-ish`, and `--name -ish` makes argparse exit 2 with an empty
    # stdout — which is not a refusal a pane can read.
    ap.add_argument("--name", default="")
    ap.add_argument("--state", choices=("on", "off"), default="on")
    args = ap.parse_args(argv)
    kind = args.action
    try:
        out = do_list() if args.action == "list" else do_set(args.name, args.state)
    except Exception as e:
        # A refusal has to be shaped like the answer that was asked for, or
        # the pane cannot read it at all. See SHAPES.
        return emit(answer(kind, {"error": "%s: %s" % (type(e).__name__, e)}))
    return emit(out)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
