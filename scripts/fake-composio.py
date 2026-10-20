#!/usr/bin/env python3
"""A fake Composio API for scripts/test-composio-session.sh.

Answers exactly what `composio.py session-url` needs and records what it was
asked: POST /api/v3.1/tool_router/session creates a session (the response is
the session object measured on 2026-09-06: session_id, mcp.{type,url}, config)
and GET /api/v3.1/tool_router/session/<id> returns it. Refuses any request
without an x-api-key, and (unlike the real API, which silently rents a
sandbox) a session create without `workbench: {enable: false}`. FAKE_COMPOSIO_MODE=no-mcp-url answers the create with a
session_id and no mcp block, to exercise the fallback; =refuse answers 403.
=echo-json and =echo-text refuse a key account (and an auth config made
WITH values) by quoting the values back — as JSON {"error": {"message"}}, or
as a plain-text body with the value starting at character 150, so a value
longer than 50 straddles both the 160 a refusal is cut to and the 200 a
careless caller used to cut at first — so a test can prove no value is
relayed. =echo-shape quotes them back in the shape named in the state file
`echo` (see ECHO_SHAPES): URL-quoted, JSON-escaped, as a list, split across
lines, masked, or the front two thirds of it… DELETE
/api/v3/connected_accounts/<id> and DELETE /api/v3/auth_configs/<id> remove
what a key connect made — the config UNCONDITIONALLY, as Composio documents
it — and the auth-config list carries `no_of_connections`, as Composio's does.
State `page_size` pages the toolkit-filtered list reads the prune makes;
`broken_cursor` makes any page after the first a 500; `refuse_delete` ("id,id")
makes a DELETE of those ids a 500. `disabled` ("id,id") hides those configs
from an auth-config list unless it asks `show_disabled=true`, as Composio's
does. `accounts_status` (a number) answers every connected-account list
with that status (403: a legacy scoped key). `slow` ("substring|seconds")
sleeps before answering any request whose path contains the substring.
`page_all` pages the whole-project account read too; `inline_accounts` puts
the session user's account inline on each session toolkit;
`refuse_delete_status` is the status a refused DELETE answers (500).
`hold_accounts` (a file path) holds a connected-account create, after it is
logged and before it is served, for as long as that file exists — the
window between a paste's auth config and its account. Threaded, so a held
or slow request does not stop the others.
Prints its port, then serves until killed; requests go to FAKE_COMPOSIO_LOG.
"""
import json
import os
import time
import unicodedata
import urllib.parse
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = os.environ.get("FAKE_COMPOSIO_MODE", "normal")
LOG = os.environ.get("FAKE_COMPOSIO_LOG", "")
SESSIONS = {}
COUNTER = {"n": 0}
#: Auth configs and key-made connected accounts, in the order they were made.
#: A test reads the LOG for what was asked; these are what later GETs answer.
AUTH_CONFIGS = []
KEY_ACCOUNTS = []
KEY_SCHEMES = ("API_KEY", "BEARER_TOKEN", "BASIC", "BASIC_WITH_JWT")
ECHO_MODES = ("echo-json", "echo-text", "echo-shape")
#: The forms =echo-shape can quote a value back in (the state file `echo`).
ECHO_SHAPES = ("exact-json", "exact-text", "urlquote", "urlquote-slash", "urlquote-plus",
               "json-escaped", "list", "split", "masked-star", "masked-bullet", "masked-x",
               "masked-dots", "front", "lower", "br-split", "br-split-slash", "hyphen-split",
               "urlquote3", "nfd", "u-escape", "say")


def _slow(path):
    """State `slow` ("substring|seconds"): a service that is slow to answer."""
    sub, _, secs = _state("slow").partition("|")
    if sub and sub in path:
        time.sleep(float(secs or 0))


def log(line):
    if LOG:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _echo(self, values):
        """Refuse by quoting the given values back, as some upstreams do."""
        secret = ";".join(str(v) for v in values)
        if MODE == "echo-shape":
            return self._echo_shape(secret)
        if MODE == "echo-json":
            return self._send(400, {"error": {"message": "field rejected: %s is not valid" % secret}})
        text = "upstream rejected the value: "
        text = (text + "." * (150 - len(text)) + secret + " was rejected by the service").encode()
        self._send_text(400, text)

    def _send_text(self, status, raw):
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _echo_shape(self, secret):
        """The value, in one of the forms an upstream can quote it back in."""
        shape = _state("echo")
        say = "field rejected: %s is not valid"
        if shape not in ECHO_SHAPES:
            return self._send(500, {"error": "moe's fake: no echo shape %r" % shape})
        if shape == "exact-text":
            return self._send_text(400, (say % secret).encode())
        if shape == "urlquote":
            return self._send(400, {"error": {"message": say % urllib.parse.quote(secret, safe="")}})
        if shape == "urlquote-slash":
            return self._send(400, {"error": {"message": "GET /x?key=%s rejected" % urllib.parse.quote(secret)}})
        if shape == "urlquote-plus":
            return self._send(400, {"error": {"message": "body key=%s rejected" % urllib.parse.quote_plus(secret)}})
        if shape == "json-escaped":
            # The request quoted back as JSON INSIDE the message: every `"`
            # and `\` in the value arrives escaped.
            return self._send(400, {"error": {"message": "invalid request, rejected: %s" % json.dumps({"val": secret})}})
        if shape == "list":
            # `error` as a list: printed with Python's repr, which doubles a
            # backslash.
            return self._send(400, {"error": [say % secret]})
        if shape == "split":
            chunks = [secret[i:i + 7] for i in range(0, len(secret), 7)]
            return self._send_text(400, ("field rejected:\n" + "\n".join(chunks) + "\nis not valid").encode())
        if shape == "lower":
            return self._send(400, {"error": {"message": say % secret.lower()}})
        if shape in ("br-split", "br-split-slash", "hyphen-split"):
            sep = {"br-split": "<br>", "br-split-slash": "<br/>", "hyphen-split": "-\n"}[shape]
            chunks = [secret[i:i + 7] for i in range(0, len(secret), 7)]
            return self._send_text(400, ("field rejected: " + sep.join(chunks) + " is not valid").encode())
        if shape == "urlquote3":
            quoted = secret
            for _ in range(3):
                quoted = urllib.parse.quote(quoted, safe="")
            return self._send(400, {"error": {"message": say % quoted}})
        if shape == "nfd":
            return self._send_text(400, (say % unicodedata.normalize("NFD", secret)).encode())
        if shape == "u-escape":
            # One character written as a JSON escape, in a plain-text body.
            i = min(12, len(secret) - 1)
            return self._send_text(400, (say % (secret[:i] + "\\u%04x" % ord(secret[i]) + secret[i + 1:])).encode())
        if shape == "say":
            # Not the value at all: what the test wrote in state `say`.
            return self._send(400, {"error": {"message": _state("say")}})
        if shape == "front":
            # Most of the value, unmasked: a service that shortens a long
            # value in its message rather than masking it.
            return self._send(400, {"error": {"message": say % secret[:max(1, len(secret) * 2 // 3)]}})
        if shape.startswith("masked-"):
            mask = {"masked-star": "****", "masked-bullet": "\u2022\u2022\u2022\u2022",
                    "masked-x": "xxxx", "masked-dots": "..."}[shape]
            return self._send(400, {"error": {"message": say % (secret[:12] + mask)}})
        return self._send(400, {"error": {"message": say % secret}})

    def _page(self, items, params, filtered_by):
        """A list answer, paged by `next_cursor` when state `page_size` is
        set — only on a read filtered by toolkit (`filtered_by`), which is
        what the prune reads. The Mac's own whole-project account read is
        one page, as it has always been treated."""
        size = int(_state("page_size") or 0)
        # State `page_all`: page the unfiltered, whole-project reads too —
        # the account read Disconnect makes.
        if not size or (filtered_by not in params and not _state("page_all")):
            return self._send(200, {"items": items})
        cursor = params.get("cursor") or ""
        if cursor and _state("broken_cursor"):
            return self._send(500, {"error": "moe's fake: this page could not be read"})
        at = int(cursor or 0)
        more = at + size < len(items)
        return self._send(200, {"items": items[at:at + size], "next_cursor": str(at + size) if more else None})

    def _base(self):
        return "http://%s:%d" % self.server.server_address

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        log("POST %s key=%s body=%s" % (self.path, "yes" if self.headers.get("x-api-key") else "no",
                                        json.dumps(body, sort_keys=True)))
        if not self.headers.get("x-api-key"):
            return self._send(401, {"error": "no key"})
        _slow(self.path)
        hold = _state("hold_accounts")
        if hold and self.path == "/api/v3/connected_accounts":
            give_up = time.time() + 30
            while os.path.exists(hold) and time.time() < give_up:
                time.sleep(0.05)
        # An auth config: the record that says "accounts on this toolkit
        # authenticate by <scheme>". The shape composio.py sends is the one
        # in Composio's reference (toolkit.slug + auth_config.type/authScheme
        # /credentials); anything else is refused so a drift there is a
        # failed test, not a quietly-accepted body.
        if self.path == "/api/v3/auth_configs":
            slug = ((body.get("toolkit") or {}).get("slug") or "").lower()
            ac = body.get("auth_config") or {}
            scheme = str(ac.get("authScheme") or "").upper()
            if MODE in ECHO_MODES and (ac.get("credentials") or {}):
                return self._echo((ac.get("credentials") or {}).values())
            if not slug or ac.get("type") != "use_custom_auth" or scheme not in KEY_SCHEMES \
                    or not isinstance(ac.get("credentials"), dict):
                return self._send(400, {"error": "auth config body is not the documented shape"})
            COUNTER["ac"] = COUNTER.get("ac", 0) + 1
            entry = {"id": "ac_fake%03d" % COUNTER["ac"], "auth_scheme": scheme,
                     "is_composio_managed": False, "toolkit": {"slug": slug},
                     "name": ac.get("name") or ""}
            AUTH_CONFIGS.append(entry)
            return self._send(201, {"auth_config": dict(entry), "toolkit": {"slug": slug}})
        # A connected account made from a pasted key: live at once, no
        # redirect. Refuses a body missing any field the toolkit requires —
        # the falsifier for "the pane asked for the right things" — and never
        # echoes a value back, as the real route does not need to.
        if self.path == "/api/v3/connected_accounts":
            if MODE in ECHO_MODES:
                val = ((body.get("connection") or {}).get("state") or {}).get("val") or {}
                return self._echo(v for k, v in val.items() if k != "status")
            # State `refuse_accounts`: every account create is refused AFTER
            # its auth config was made — the case where a refused paste
            # must not leave that config (and its values) behind.
            if _state("refuse_accounts"):
                return self._send(400, {"error": "moe's fake: this account was refused"})
            ac_id = (body.get("auth_config") or {}).get("id") or ""
            ac = next((a for a in AUTH_CONFIGS if a["id"] == ac_id), None)
            if ac is None:
                return self._send(400, {"error": "no such auth config"})
            conn = body.get("connection") or {}
            state = conn.get("state") or {}
            val = state.get("val") or {}
            if str(state.get("authScheme") or "").upper() != ac["auth_scheme"]:
                return self._send(400, {"error": "authScheme does not match the auth config"})
            if not conn.get("user_id"):
                return self._send(400, {"error": "no user_id"})
            slug = ac["toolkit"]["slug"]
            missing = [f for f in _key_fields(slug) if not val.get(f)]
            if missing:
                return self._send(400, {"error": "missing required field(s): %s" % ", ".join(missing)})
            COUNTER["ca"] = COUNTER.get("ca", 0) + 1
            acct = {"id": "ca_key%03d" % COUNTER["ca"], "status": "ACTIVE",
                    "user_id": conn["user_id"], "toolkit": {"slug": slug},
                    "created_at": "2026-09-11T00:00:01Z", "alias": "",
                    "auth_config": {"id": ac["id"], "auth_scheme": ac["auth_scheme"],
                                    "is_composio_managed": False, "is_disabled": False}}
            KEY_ACCOUNTS.append(acct)
            return self._send(201, {"id": acct["id"],
                                    "connectionData": {"authScheme": ac["auth_scheme"],
                                                       "val": {"status": "ACTIVE"}}})
        # The session's MCP endpoint: only COMPOSIO_MANAGE_CONNECTIONS, which
        # the real one answers by MINTING a connection request per toolkit —
        # connected or not, on a multi-account session. Logged as
        # "MCP <tool> <toolkits>" so a test can require it was never sent.
        if self.path.startswith("/tool_router/") and self.path.endswith("/mcp"):
            params = body.get("params") or {}
            args = params.get("arguments") or {}
            kits = [str(k).lower() for k in args.get("toolkits") or []]
            log("MCP %s %s" % (params.get("name"), ",".join(kits)))
            results = {}
            for k in kits:
                if _state("max_accounts"):
                    results[k] = {"toolkit": k, "status": "failed", "error_message":
                                  "Maximum of 5 accounts per toolkit reached. Remove an "
                                  "existing account before adding a new one."}
                else:
                    results[k] = {"toolkit": k, "status": "initiated",
                                  "redirect_url": "https://connect.composio.dev/link/lk_fake_" + k}
            text = json.dumps({"data": {"results": results}, "successful": True})
            raw = "data: " + json.dumps({"jsonrpc": "2.0", "id": 1,
                                        "result": {"content": [{"type": "text", "text": text}]}})
            out = raw.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        if self.path != "/api/v3.1/tool_router/session":
            return self._send(404, {"error": "no such route"})
        if MODE == "refuse":
            return self._send(403, {"error": "this key may not create sessions"})
        # The real API does NOT refuse this; it silently gives the session a
        # sudo Linux sandbox with open outbound network, billed to us
        # (docs/CLOUD-REMAINING.md D3). This fake refuses, so that a creation
        # path which forgets the flag fails a test instead of renting one.
        if (body.get("workbench") or {}).get("enable") is not False:
            return self._send(400, {"error": "moe's fake: a session create must pass "
                                             "workbench.enable=false (D3)"})
        COUNTER["n"] += 1
        sid = "trs_fake%06d" % COUNTER["n"]
        session = {
            "session_id": sid,
            "config": {"user_id": body.get("user_id"), "preload": body.get("preload") or {},
                       "toolkits": {}, "search": {}, "execute": {}, "manage_connections": {},
                       "multi_account": body.get("multi_account") or {}, "workbench": {}},
            "config_version": 1,
            "tool_router_tools": [],
            "warnings": [],
        }
        if MODE != "no-mcp-url":
            session["mcp"] = {"type": "http", "url": self._base() + "/tool_router/" + sid + "/mcp"}
        SESSIONS[sid] = session
        return self._send(200, session)

    def do_GET(self):
        log("GET %s key=%s" % (self.path, "yes" if self.headers.get("x-api-key") else "no"))
        if not self.headers.get("x-api-key"):
            return self._send(401, {"error": "no key"})
        _slow(self.path)
        path, _, query = self.path.partition("?")
        params = dict(urllib.parse.parse_qsl(query))
        prefix = "/api/v3.1/tool_router/session/"
        # The session's toolkits, paged the way the real route pages: twenty
        # per page, a `next_cursor`, no page-size parameter. Page one is
        # twenty everyday services; page two is whatever the test put in
        # FAKE_COMPOSIO_PAGE2 (comma-separated slugs). A reader that stops at
        # page one never sees page two — which is the bug this exists to
        # catch, so the page split is not optional.
        if path.startswith(prefix) and path.endswith("/toolkits"):
            sid = path[len(prefix):-len("/toolkits")]
            if sid not in SESSIONS:
                return self._send(404, {"error": "no such session"})
            page2 = [x.strip().lower() for x in _state("page2").split(",") if x.strip()]
            if params.get("cursor") == "page2":
                items = [{"slug": x, "name": x.title(), "meta": {"logo": ""},
                          "composio_managed_auth_schemes": ["OAUTH2"] if x in MANAGED else [],
                          "connected_account": None} for x in page2]
                return self._send(200, {"items": items, "next_cursor": None})
            # State `inline_accounts` (any value): each toolkit carries the
            # session user's key-made account inline, {id, user_id, status},
            # as the real route does — the account read a legacy scoped key
            # is still answered.
            who = SESSIONS[sid]["config"].get("user_id")
            def inline(x):
                if not _state("inline_accounts"):
                    return None
                hit = next((a for a in KEY_ACCOUNTS if a["toolkit"]["slug"] == x and a["user_id"] == who), None)
                return {"id": hit["id"], "user_id": hit["user_id"], "status": hit["status"]} if hit else None
            items = [{"slug": x, "name": x.title(), "meta": {"logo": ""},
                      "composio_managed_auth_schemes": ["OAUTH2"] if x in MANAGED else [],
                      "connected_account": inline(x)}
                     for x in PAGE_ONE]
            return self._send(200, {"items": items, "next_cursor": "page2" if page2 else None})
        # Every connected account on the project, as the real route returns
        # them: FAKE_COMPOSIO_CONNECTED is "slug:user_id,slug:user_id", plus
        # whatever a pasted key made.
        if path == "/api/v3/connected_accounts":
            if _state("accounts_status"):
                code = int(_state("accounts_status"))
                return self._send(code, {"error": "moe's fake: the account list answered %d" % code})
            items = []
            # An entry may carry a status and a creation time too:
            # "slug:uid:INITIALIZING:2026-09-11T00:00:00Z".
            # Ids are positional, so a new set of accounts forgets the
            # deletions made against the last one.
            if _state("connected") != LAST_CONNECTED[0]:
                LAST_CONNECTED[0] = _state("connected")
                DELETED.clear()
            for n, pair in enumerate(x for x in _state("connected").split(",") if x.strip()):
                slug, uid, st, created = (pair.strip().split(":", 3) + ["", "", ""])[:4]
                if "ca_fake%03d" % n in DELETED:
                    continue
                items.append({"id": "ca_fake%03d" % n, "status": st or "ACTIVE", "user_id": uid,
                              "toolkit": {"slug": slug.lower()},
                              "created_at": created or "2026-09-11T00:00:00Z", "alias": "",
                              # Composio's words for a link nobody opened.
                              "status_reason": ("Connection expired before authorization was started"
                                                if st == "EXPIRED" else "")})
            # State `omit` ("ca_key001,…"): accounts left out of the list, as
            # if on a page the reader never saw. Composio's no_of_connections
            # on the auth config still counts them.
            omit = {x.strip() for x in _state("omit").split(",") if x.strip()}
            items += [dict(a) for a in KEY_ACCOUNTS if a["id"] not in omit]
            # `user_ids`: Composio's own filter, honoured the way the real
            # route honours it — only those users' accounts, and so short a
            # list that one person's are never past page one.
            want = {u for u in (params.get("user_ids") or "").split(",") if u}
            if want:
                items = [a for a in items if a["user_id"] in want]
            # `statuses`: comma-separated, as the real route takes it.
            sts = {x for x in (params.get("statuses") or "").split(",") if x}
            if sts:
                items = [a for a in items if a["status"] in sts]
            return self._page(items, params, "toolkit_slugs")
        if path == "/api/v3/auth_configs":
            want = (params.get("toolkit_slug") or "").lower()
            disabled = {x.strip() for x in _state("disabled").split(",") if x.strip()}
            items = [dict(a, no_of_connections=sum(1 for c in KEY_ACCOUNTS if c["auth_config"]["id"] == a["id"]),
                          status="DISABLED" if a["id"] in disabled else "ENABLED")
                     for a in AUTH_CONFIGS if (not want or a["toolkit"]["slug"] == want)
                     and (a["id"] not in disabled or params.get("show_disabled") == "true")]
            # State `no_count`: answer without no_of_connections, so a test
            # can prove the account list alone protects a config in use.
            if _state("no_count"):
                for item in items:
                    item.pop("no_of_connections", None)
            return self._page(items, params, "toolkit_slug")
        # One toolkit by slug: a name, a tool count, and how it authenticates,
        # as /toolkits/<slug> gives. Page-one services are Composio-managed
        # OAuth; anything else takes a key, with the field names the test
        # chose (FAKE_COMPOSIO_KEYFIELDS: "slug=api_key+subdomain;other=token")
        # and `api_key` when it chose none — because the whole point of the
        # route is that the names are the service's, not ours.
        if path.startswith("/api/v3/toolkits/"):
            slug = urllib.parse.unquote(path[len("/api/v3/toolkits/"):]).lower()
            kit = {"slug": slug, "name": slug.title(), "meta": {"tools_count": 7, "logo": ""}}
            if slug in MANAGED:
                kit["composio_managed_auth_schemes"] = ["OAUTH2"]
                kit["auth_config_details"] = [{"mode": "OAUTH2", "fields": {
                    "auth_config_creation": {"required": [
                        {"name": "client_id", "displayName": "Client ID", "type": "string", "required": True},
                        {"name": "client_secret", "displayName": "Client Secret", "type": "string", "required": True}],
                        "optional": []},
                    "connected_account_initiation": {"required": [], "optional": []}}}]
            else:
                kit["composio_managed_auth_schemes"] = []
                required = []
                for f in _key_fields(slug):
                    if f == "subdomain":
                        required.append({"name": f, "displayName": "Subdomain",
                                         "description": "The part of your %s address before .%s.example." % (slug.title(), slug),
                                         "type": "string", "required": True})
                    else:
                        required.append({"name": f, "displayName": "%s %s" % (slug.title(), f.replace("_", " ").title()),
                                         "description": "Your %s %s. Find it at https://%s.example.invalid/settings/api-keys."
                                                        % (slug.title(), f.replace("_", " "), slug),
                                         "type": "string", "required": True})
                # FAKE_COMPOSIO_ACFIELDS ("slug=api_token") names fields the
                # AUTH CONFIG takes at creation, the other stage a value can
                # travel in.
                ac_required = [{"name": f, "displayName": f.replace("_", " ").title(), "type": "string",
                                "required": True} for f in (_named_fields("acfields", slug) or [])]
                kit["auth_config_details"] = [{"mode": "API_KEY", "fields": {
                    "auth_config_creation": {"required": ac_required, "optional": []},
                    "connected_account_initiation": {"required": required, "optional": [
                        {"name": "region", "displayName": "Region", "type": "string", "required": False}]}}}]
            return self._send(200, kit)
        if self.path.startswith(prefix) and self.path[len(prefix):] in SESSIONS:
            return self._send(200, SESSIONS[self.path[len(prefix):]])
        return self._send(404, {"error": "no such session"})


    def do_PATCH(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        log("PATCH %s key=%s body=%s" % (self.path, "yes" if self.headers.get("x-api-key") else "no",
                                         json.dumps(body, sort_keys=True)))
        if not self.headers.get("x-api-key"):
            return self._send(401, {"error": "no key"})
        prefix = "/api/v3.1/tool_router/session/"
        path = self.path.partition("?")[0]
        # A session's auth_configs can be changed after creation, and the
        # change is kept (measured 2026-09-30) — unlike multi_account, which
        # the real API ignores on a PATCH, so this fake ignores it too.
        if path.startswith(prefix) and path[len(prefix):] in SESSIONS:
            sess = SESSIONS[path[len(prefix):]]
            if isinstance(body.get("auth_configs"), dict):
                sess["config"]["auth_configs"] = dict(body["auth_configs"])
            return self._send(200, sess)
        if path.startswith("/api/v3/connected_accounts/"):
            return self._send(200, {"success": True})
        return self._send(404, {"error": "no such route"})

    def do_DELETE(self):
        log("DELETE %s key=%s" % (self.path, "yes" if self.headers.get("x-api-key") else "no"))
        if not self.headers.get("x-api-key"):
            return self._send(401, {"error": "no key"})
        path = self.path.partition("?")[0]
        # Composio: DELETE /api/v3/connected_accounts/{nanoid} and
        # DELETE /api/v3/auth_configs/{nanoid} (docs.composio.dev/reference/
        # v3/api-reference/auth-configs/deleteAuthConfigsByNanoid), both
        # answering {"success": true}. That page documents 400 (a bad id),
        # 401, 404 and 500 and NO refusal to delete a config in use, so this
        # fake deletes one unconditionally, like the real API — a test that
        # a config in use survives must read the request log for the DELETE
        # that should never have been sent. What becomes of accounts on a
        # deleted config is not documented; the fake assumes the worst and
        # takes them with it.
        refused = {x.strip() for x in _state("refuse_delete").split(",") if x.strip()}
        if path.startswith("/api/v3/connected_accounts/ca_fake") and path[-10:] not in refused:
            DELETED.add(path.rsplit("/", 1)[1])
            return self._send(200, {"success": True, "message": "deleted"})
        for prefix, table in (("/api/v3/connected_accounts/", KEY_ACCOUNTS),
                              ("/api/v3/auth_configs/", AUTH_CONFIGS)):
            if path.startswith(prefix):
                nid = path[len(prefix):]
                hit = next((x for x in table if x["id"] == nid), None)
                if hit is None:
                    return self._send(404, {"error": "no such record"})
                if nid in refused:
                    # State `refuse_delete_status`: the status to refuse with
                    # (403: a key that may not delete); 500 by default.
                    return self._send(int(_state("refuse_delete_status") or 500),
                                      {"error": "moe's fake: this delete failed"})
                table.remove(hit)
                if table is AUTH_CONFIGS:
                    KEY_ACCOUNTS[:] = [c for c in KEY_ACCOUNTS if c["auth_config"]["id"] != nid]
                return self._send(200, {"success": True, "message": "deleted"})
        return self._send(404, {"error": "no such route"})


#: Ids of listed (FAKE_COMPOSIO_CONNECTED) accounts that were deleted.
DELETED = set()
LAST_CONNECTED = [None]


def _state(name):
    """Test-set state, read at request time: FAKE_COMPOSIO_STATE/<name> (a
    file the test writes after the fake is up — it learns the identity it
    needs only once a session exists), else the env var FAKE_COMPOSIO_<NAME>."""
    d = os.environ.get("FAKE_COMPOSIO_STATE")
    if d:
        try:
            with open(os.path.join(d, name), encoding="utf-8") as fh:
                return fh.read().strip()
        except OSError:
            pass
    return os.environ.get("FAKE_COMPOSIO_" + name.upper()) or ""


def _named_fields(state, slug):
    """Fields the test named for `slug` in state `state`
    ("slug=api_key+subdomain;other=token"), or None when it named none."""
    for part in _state(state).split(";"):
        name, _, fields = part.strip().partition("=")
        if name.strip().lower() == slug:
            return [f.strip() for f in fields.split("+") if f.strip()]
    return None


def _key_fields(slug):
    """The field names a key connect must carry for `slug`, from the test's
    FAKE_COMPOSIO_KEYFIELDS ("slug=api_key+subdomain;other=token"); `api_key`
    when the test said nothing."""
    named = _named_fields("keyfields", slug)
    return ["api_key"] if named is None else named


#: The page-one services Composio holds a sign-in for, as it does for the
#: real ones; firecrawl, perplexityai and serpapi are API_KEY-only in the
#: shipped catalogue and stay that way here, so a test has a key service on
#: page one without inventing a slug.
MANAGED = {"airtable", "composio", "github", "gmail", "googlecalendar", "googledocs", "googledrive",
           "googlesheets", "hubspot", "jira", "linear", "notion", "outlook", "slack", "supabase",
           "twitter", "youtube", "ticktick"}

PAGE_ONE = ["airtable", "composio", "firecrawl", "github", "gmail", "googlecalendar", "googledocs",
            "googledrive", "googlesheets", "hubspot", "jira", "linear", "notion", "outlook",
            "perplexityai", "serpapi", "slack", "supabase", "twitter", "youtube"]


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    print(server.server_port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
