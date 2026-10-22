"""Shared helpers for the Hermes-backed connection scripts (hermes-catalog.py,
hermes-connections.py). Not a connector: there is no manifest beside it, so
lib/connectors.sh never runs it.

Three jobs:
  * find Hermes ($HERMES_HOME, the checkout, its venv) the same way
    configure-hermes.py does, so tests can redirect all of it;
  * read YAML with PyYAML when it is importable, re-exec'ing under the
    Hermes venv when it is not (that venv always has it), and fall back to a
    small parser that covers the subset Hermes's manifests actually use, so
    a machine with no venv still gets an answer instead of a traceback;
  * squash foreign text (catalog descriptions, MCP tool names, error output)
    to one printable line before it reaches a terminal or a markdown file.
    Tool descriptions are attacker-controlled by design (CONNECTORS.md); the
    catalog is reviewed, but the same rule applies to everything we did not
    write.

Python 3.9, stdlib only.
"""
import fcntl
import os
import re
import subprocess
import sys

# ── Where Hermes is ───────────────────────────────────────────────────────


def hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def agent_dir():
    return os.environ.get("HERMES_AGENT_DIR") or os.path.join(hermes_home(), "hermes-agent")


def venv_python():
    py = os.path.join(agent_dir(), ".venv", "bin", "python")
    return py if os.path.exists(py) else None


def hermes_bin():
    """The `hermes` executable: $HERMES_BIN, then PATH, then the venv.
    Tests put a fake one first on PATH; nothing here ever runs the live
    gateway, only its CLI subcommands."""
    explicit = os.environ.get("HERMES_BIN")
    if explicit:
        return explicit
    for d in os.environ.get("PATH", "").split(os.pathsep):
        cand = os.path.join(d, "hermes")
        if d and os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    cand = os.path.join(agent_dir(), ".venv", "bin", "hermes")
    return cand if os.path.exists(cand) else None


def skill_roots():
    """Where SKILL.md files live, in the order Hermes itself prefers: the
    synced copy under HERMES_HOME (what the gateway runs), then the checkout's
    bundled and optional sets. Deduplicated by skill name by the caller."""
    return [
        ("synced", os.path.join(hermes_home(), "skills")),
        ("bundled", os.path.join(agent_dir(), "skills")),
        ("optional", os.path.join(agent_dir(), "optional-skills")),
    ]


def catalog_dir():
    return os.environ.get("HERMES_OPTIONAL_MCPS_DIR") or os.path.join(agent_dir(), "optional-mcps")


def platforms_dir():
    return os.path.join(agent_dir(), "plugins", "platforms")


# ── YAML ──────────────────────────────────────────────────────────────────

_REEXEC_FLAG = "MOE_HERMESLIB_REEXEC"


def ensure_yaml():
    """Make `import yaml` work, or fall back. Called once at start-up by the
    scripts. If PyYAML is missing and the Hermes venv exists, re-exec the
    whole script under that interpreter (once — the flag stops a loop when
    the venv has no yaml either). Returns True when the real library is
    available afterwards."""
    try:
        import yaml  # noqa: F401
        return True
    except ImportError:
        pass
    py = venv_python()
    if py and os.environ.get(_REEXEC_FLAG) != "1" and os.path.realpath(py) != os.path.realpath(sys.executable):
        env = dict(os.environ)
        env[_REEXEC_FLAG] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        try:
            os.execve(py, [py, os.path.abspath(sys.argv[0])] + sys.argv[1:], env)
        except OSError:
            pass
    return False


_NO_YAML_FLAG = "MOE_HERMESLIB_NO_YAML"     # =1 forces the fallback (tests)


def load_yaml_text(text):
    """Parsed YAML, or None when it cannot be read honestly: a PyYAML error,
    or the fallback meeting a construct it does not implement (anchors,
    tags, multi-document files, tabs …). None, never a guess — a config.yaml
    read as "no mcp_servers" would report every server as not connected."""
    if os.environ.get(_NO_YAML_FLAG) != "1":
        try:
            import yaml
            try:
                return yaml.safe_load(text)
            except Exception:       # PyYAML's own error classes
                return None
        except ImportError:
            pass
    try:
        return _mini_yaml(text)
    except _Unsupported:
        return None


def load_yaml_file(path):
    """Parsed YAML, or None when the file is missing/unreadable/invalid.
    Callers treat None as "no such thing", never as an error to print."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return load_yaml_text(f.read())
    except (OSError, ValueError):
        return None
    except Exception:  # PyYAML's own error classes
        return None


# A deliberately small YAML reader: block maps and lists by indentation,
# lists of maps ("- name: x" then indented keys), block scalars (| and >,
# with -/+ chomping), quoted and bare scalars, comments, one-line flow
# style ([a, b], {k: v}, nested). That is every construct in
# optional-mcps/*/manifest.yaml, plugins/platforms/*/plugin.yaml, SKILL.md
# frontmatter and the keys of config.yaml we read. Anything it does not
# implement — anchors/aliases, tags, multi-document files, multi-line plain
# scalars, tabs in indentation, a line it cannot place — raises
# _Unsupported and the whole document reads as None, so a caller says
# "could not be read" instead of "not connected". Checked against PyYAML
# in scripts/test-connections.sh.

_SCALARS = {"true": True, "false": False, "yes": True, "no": False, "on": True, "off": False,
            "null": None, "~": None, "": None}


class _Unsupported(Exception):
    """The fallback met YAML it does not implement."""


def _scalar(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        inner = s[1:-1]
        return inner.replace('\\"', '"').replace("\\n", "\n") if s[0] == '"' else inner.replace("''", "'")
    if s[:1] in "&*!":
        # Anchor, alias or tag: PyYAML would resolve/apply it; we cannot.
        raise _Unsupported("anchor/alias/tag")
    if s.startswith("[") and s.endswith("]"):
        body = s[1:-1].strip()
        return [_scalar(x) for x in _split_flow(body)] if body else []
    if s.startswith("{") and s.endswith("}"):
        out = {}
        for part in _split_flow(s[1:-1]):
            if ":" in part:
                k, v = part.split(":", 1)
                out[_scalar(k)] = _scalar(v)
        return out
    low = s.lower()
    if low in _SCALARS:
        return _SCALARS[low]
    if re.fullmatch(r"-?\d+", s):
        return int(s)
    if re.fullmatch(r"-?\d+\.\d+", s):
        return float(s)
    return s


def _split_flow(body):
    """Split a flow body on top-level commas, honouring quotes and nested
    brackets ({a: {b: 1}, c: [1, 2]} → two parts)."""
    out, cur, q, depth = [], "", None, 0
    for ch in body:
        if q:
            cur += ch
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
            cur += ch
        elif ch in "[{":
            depth += 1
            cur += ch
        elif ch in "]}":
            depth -= 1
            cur += ch
        elif ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [x.strip() for x in out]


def _strip_comment(line):
    out, q = "", None
    for i, ch in enumerate(line):
        if q:
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        out += ch
    return out.rstrip()


_BLOCK_MARK = re.compile(r"^(.*?):\s*([|>][+-]?)$")


def _mini_yaml(text):
    """Pre-pass: one tuple (indent, stripped, raw) per meaningful line. A
    block scalar (key: | …) is gathered here, raw and with its blank lines,
    into a single tuple whose text is the finished string — so a '#' inside
    it is content, not a comment, and chomping sees the blank lines."""
    raw_lines = text.splitlines()
    lines, n, k = [], len(raw_lines), 0
    while k < n:
        raw = raw_lines[k]
        k += 1
        if raw.strip() == "---":
            if lines:
                raise _Unsupported("multi-document")    # PyYAML refuses these too
            continue
        if raw.strip() == "...":
            break
        s = _strip_comment(raw)
        if not s.strip():
            continue
        lead = s[:len(s) - len(s.lstrip())]
        if "\t" in lead:
            raise _Unsupported("tab in indentation")     # a YAML error
        indent = len(lead)
        m = _BLOCK_MARK.match(s.strip())
        if m and not (s.strip().startswith("- ") or s.strip() == "-") and m.group(1)[:1] not in "[{":
            # Gather the block: every following line that is blank or
            # indented deeper than the key.
            body = []
            while k < n and (not raw_lines[k].strip() or len(raw_lines[k]) - len(raw_lines[k].lstrip(" ")) > indent):
                if raw_lines[k].strip() and "\t" in raw_lines[k][:len(raw_lines[k]) - len(raw_lines[k].lstrip())]:
                    raise _Unsupported("tab in indentation")
                body.append(raw_lines[k])
                k += 1
            lines.append((indent, m.group(1).strip() + ": \x00BLOCK", _block_scalar(body, m.group(2))))
            continue
        lines.append((indent, s.strip(), raw))
    if not lines:
        return None
    if lines[0][0] == 0 and lines[0][1][:1] in "[{":
        # A whole document in flow style (JSON is YAML). One-liners only.
        if len(lines) != 1:
            raise _Unsupported("multi-line flow document")
        return _scalar(lines[0][1])
    val, nxt = _parse_block(lines, 0, -1)
    if nxt != len(lines):
        raise _Unsupported("unplaced line %d" % nxt)
    return val


def _block_scalar(body, marker):
    """The string a | or > block denotes, from its raw lines (trailing blank
    lines included) and its chomping indicator."""
    trailing = 0
    while body and not body[-1].strip():
        body.pop()                       # trailing blanks only matter for chomping
        trailing += 1
    base = None
    for ln in body:
        if ln.strip():
            base = len(ln) - len(ln.lstrip(" ")) if base is None else min(base, len(ln) - len(ln.lstrip(" ")))
    base = base or 0
    out = [ln[base:] if len(ln) > base else "" for ln in body]
    text = "\n".join(out)
    if marker.startswith(">"):
        text = re.sub(r"(?<!\n)\n(?!\n)", " ", text)
        text = text.replace("\n\n", "\n")
    if not body:
        return "", marker
    # Chomping: strip (-) none, clip (default) one, keep (+) all trailing newlines.
    if marker.endswith("-"):
        return text, marker
    return text + "\n" * (1 + trailing if marker.endswith("+") else 1), marker


def _parse_block(lines, i, parent_indent):
    """Parse the block whose lines are indented more than parent_indent.
    Returns (value, next_index)."""
    if i >= len(lines) or lines[i][0] <= parent_indent:
        return None, i
    indent = lines[i][0]
    if lines[i][1].startswith("- ") or lines[i][1] == "-":
        out = []
        while i < len(lines) and lines[i][0] == indent and (lines[i][1].startswith("- ") or lines[i][1] == "-"):
            item = lines[i][1][1:].strip()
            if not item:
                v, i = _parse_block(lines, i + 1, indent)
                out.append(v)
            elif re.match(r"^[^\s'\"\[{][^:]*:(\s|$)", item) and not item.startswith(("http:", "https:")):
                # "- key: value" — a map whose first key sits on the dash line.
                # Rewrite it as a map line at indent+2 and let the map parser
                # collect the sibling keys that follow.
                lines[i] = (indent + 2, item, lines[i][2])
                v, i = _parse_block(lines, i, indent)
                out.append(v)
            else:
                out.append(_scalar(item))
                i += 1
        return out, i
    out = {}
    while i < len(lines) and lines[i][0] == indent:
        s = lines[i][1]
        m = re.match(r"^([^\s'\"\[{][^:]*?|'[^']*'|\"[^\"]*\"):(?:\s+(.*))?$", s)
        if not m:
            i += 1
            continue
        key = _scalar(m.group(1))
        rest = (m.group(2) or "").strip()
        if rest == "\x00BLOCK":
            out[key] = lines[i][2][0]
            i += 1
        elif rest:
            out[key] = _scalar(rest)
            i += 1
        elif i + 1 < len(lines) and lines[i + 1][0] == indent and lines[i + 1][1].startswith(("- ", "-")) \
                and (lines[i + 1][1] == "-" or lines[i + 1][1][1] == " "):
            # "key:" followed by "- item" at the SAME indent (an indentless
            # sequence — what PyYAML's dump writes, so what Hermes's own
            # config writer puts in config.yaml: hooks.pre_tool_call,
            # mcp_servers.<x>.args, claude_code.deny). Without this the list
            # was read as a stray key and every later top-level key was
            # dropped, so a fallback parse of config.yaml lost mcp_servers.
            out[key], i = _parse_block(lines, i + 1, indent - 1)
        else:
            out[key], i = _parse_block(lines, i + 1, indent)
    return out, i


# ── .env: names only ──────────────────────────────────────────────────────


def env_keys(path):
    """The set of KEY names with a non-empty value in a dotenv file. Values
    are read to test emptiness and dropped on the spot; nothing here returns
    or logs one."""
    keys = set()
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[7:].lstrip()
                if "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip().strip("'\"")
                if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k) and v:
                    keys.add(k)
    except OSError:
        pass
    return keys


# ── Foreign text ──────────────────────────────────────────────────────────

_MD_LEADING = re.compile(r"^(?=[#>\-+*|`]|\d+[.)]\s)")
_MD_LINK = re.compile(r"\[([^\]]*)\]\(([^)]*)\)")


def one_line(text, limit=120):
    """Any text we did not write, squashed to one short printable line:
    control characters and newlines gone, markdown links flattened, a
    leading markdown structure character escaped."""
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or ""))
    text = re.sub(r"\s+", " ", text).strip()
    text = _MD_LINK.sub(r"\1 (\2)", text)
    text = _MD_LEADING.sub("\\\\", text, count=1)
    return text[:limit]


_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def env_name(name):
    """An environment-variable name a manifest asked for, or None. The same
    rule Hermes applies (skills_tool._ENV_VAR_NAME_RE); catalog text is not
    ours, and this is the string connect.sh puts in a prompt and a .env line."""
    name = str(name or "")
    return name if _ENV_NAME_RE.match(name) else None


def safe_name(name):
    """Server/skill/platform names are used as file names, config keys and
    argv. Refuse anything outside [A-Za-z0-9_.-] — Hermes's own catalog rule
    is the same set minus the dot."""
    name = str(name or "")
    # A leading '-' would be read as an option by `hermes mcp test|login|remove`.
    return name if _NAME_RE.match(name) and not name.startswith((".", "-")) else None


# ── .env: writing ─────────────────────────────────────────────────────────


class _dotenv_lock:
    """Serialise Alfie's own read-modify-write of .env: two connect.sh runs at
    once (say, the app and a terminal) would otherwise each read the old
    file and the second rename would drop the first one's key. flock on a
    sibling file, held only for the milliseconds of the rewrite. Hermes's
    writer does not take it, so Alfie-vs-Hermes at the same instant remains
    last-writer-wins — the same as Hermes-vs-Hermes today; readers are safe
    either way because every writer renames a complete file into place."""

    def __init__(self, path):
        self.lock = os.path.join(os.path.dirname(path) or ".", ".env.lock")
        self.fd = None

    def __enter__(self):
        self.fd = os.open(self.lock, os.O_WRONLY | os.O_CREAT, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)

    def __exit__(self, *exc):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def dotenv_set(path, key, value):
    """Set KEY in a dotenv file, line by line: every other line, comment
    included, survives byte for byte; the file ends up 0600; the write is
    atomic (rename over, so the gateway — which re-reads .env every turn —
    sees the old file or the new one, never a torn one). Hermes's own writer
    (hermes_cli.config.save_env_value) does the same."""
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
        raise ValueError("bad env var name")
    if "\n" in value or "\r" in value:
        raise ValueError("value must be one line")
    os.makedirs(os.path.dirname(path) or ".", mode=0o700, exist_ok=True)
    with _dotenv_lock(path):
        _dotenv_set_locked(path, key, value)


def _dotenv_set_locked(path, key, value):
    lines = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        pass
    # Values are quoted only when they need to be: Hermes uses python-dotenv,
    # which reads both forms, and a bare token is what its wizard writes.
    if re.fullmatch(r"[A-Za-z0-9_./:@+=,-]*", value):
        rendered = value
    else:
        # python-dotenv decodes escapes inside double quotes, so a backslash
        # must be doubled or "a\nb" (two characters) would come back as a newline.
        rendered = '"%s"' % value.replace("\\", "\\\\").replace('"', '\\"')
    new = "%s=%s" % (key, rendered)
    done = False
    for i, line in enumerate(lines):
        bare = line[7:] if line.startswith("export ") else line
        if bare.split("=", 1)[0].strip() == key:
            lines[i] = new
            done = True
    if not done:
        lines.append(new)
    _write_dotenv(path, lines)


def dotenv_unset(path, keys):
    # An empty or malformed key would match every line that has no '=' —
    # blank lines included — so only real names count.
    keys = {k for k in keys if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k or "")}
    if not keys or not os.path.isfile(path):
        return
    with _dotenv_lock(path):
        _dotenv_unset_locked(path, keys)


def _dotenv_unset_locked(path, keys):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return
    keep = []
    for line in lines:
        bare = line[7:] if line.startswith("export ") else line
        if bare.split("=", 1)[0].strip() in keys:
            continue
        keep.append(line)
    _write_dotenv(path, keep)


def _write_dotenv(path, lines):
    d = os.path.dirname(path) or "."
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = os.path.join(d, ".env.%d.tmp" % os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + ("\n" if lines else ""))
        os.replace(tmp, path)
    except BaseException:
        # Never leave a half-written copy of the secrets file behind.
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.chmod(path, 0o600)


# ── Pairing: who is waiting to be approved ────────────────────────────────

PAIRING_TTL = 3600          # gateway/pairing.py CODE_TTL_SECONDS: codes expire after an hour


def pairing_dir():
    """Where Hermes keeps <platform>-pending.json: the legacy ~/.hermes/pairing
    when it exists with content, else ~/.hermes/platforms/pairing — the same
    rule as hermes_constants.get_hermes_dir("platforms/pairing", "pairing")."""
    old = os.path.join(hermes_home(), "pairing")
    try:
        if os.path.isdir(old) and any(True for _ in os.scandir(old)):
            return old
    except OSError:
        pass
    return os.path.join(hermes_home(), "platforms", "pairing")


def pending_pairings():
    """Pending pairing requests, read from the store files the gateway writes
    (gateway/pairing.py PairingStore): one dict per request with platform,
    request_id, user_name, user_id, age_minutes, created_at. Nothing else is
    read out: the code is stored as a salted hash and stays there. Expired
    entries (older than the TTL) and legacy ones without an approvable id are
    left out — nothing the app could act on."""
    d = pairing_dir()
    out = []
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return out
    now = _now()
    for fn in names:
        if not fn.endswith("-pending.json") or fn.startswith("_"):
            continue
        platform = safe_name(fn[:-len("-pending.json")])
        if not platform:
            continue
        try:
            with open(os.path.join(d, fn), encoding="utf-8") as f:
                import json
                pending = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(pending, dict):
            continue
        for entry_id, info in pending.items():
            if not isinstance(info, dict) or not isinstance(info.get("hash"), str) or not isinstance(info.get("salt"), str):
                continue
            created = info.get("created_at")
            if not isinstance(created, (int, float)) or isinstance(created, bool):
                continue
            if now - created > PAIRING_TTL:
                continue
            rid = str(entry_id)
            if len(rid) != 16 or not all(c in "0123456789abcdefABCDEF" for c in rid):
                continue
            out.append({
                "platform": platform,
                "request_id": rid.lower(),
                "user_name": one_line(info.get("user_name") or "", 60),
                "user_id": one_line(info.get("user_id") or "", 60),
                "age_minutes": int((now - created) / 60),
                "created_at": int(created),
            })
    out.sort(key=lambda r: r["created_at"])
    return out


def _now():
    import time
    return time.time()


def run(argv, timeout, env=None):
    """subprocess.run with a timeout; returns (rc, stdout, stderr), rc -1 on
    timeout or a missing executable. Never raises."""
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                           env=env, stdin=subprocess.DEVNULL)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "timed out after %ss" % timeout
    except OSError as e:
        return -1, "", str(e)


if __name__ == "__main__":
    # connect.sh's .env writer: `hermeslib.py dotenv-set KEY` reads the value
    # from stdin (never argv, never ps), `dotenv-unset KEY…` deletes.
    _cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    _env = os.path.join(hermes_home(), ".env")
    if _cmd == "dotenv-set" and len(sys.argv) == 3:
        _val = sys.stdin.readline().rstrip("\r\n")
        if not _val:
            print("hermeslib.py: refusing to write an empty value", file=sys.stderr)
            sys.exit(1)
        try:
            dotenv_set(_env, sys.argv[2], _val)
        except ValueError as e:
            print("hermeslib.py: %s" % e, file=sys.stderr)   # never the value
            sys.exit(1)
    elif _cmd == "dotenv-unset" and len(sys.argv) > 2:
        dotenv_unset(_env, set(sys.argv[2:]))
    elif _cmd == "pending-pairings":
        # pairing.sh list --json
        import json as _json
        _json.dump(pending_pairings(), sys.stdout, indent=1)
        print()
    else:
        print("usage: hermeslib.py dotenv-set KEY < value | dotenv-unset KEY… | pending-pairings", file=sys.stderr)
        sys.exit(2)
