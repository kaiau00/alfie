#!/usr/bin/env python3
"""Your chat apps, reaching Moe wherever Moe is awake.

A chat app can talk to the Moe on this Mac, or to the one in the cloud when
this Mac is asleep — one bot, one thread, whichever is awake. The edge decides
that (`select_runtime`: your preference first, and always failing over to
whatever is actually reachable). This script is how the Mac sets it up.

  channels.py status                 what is connected, and what is waiting
  channels.py slack-install          the one-click "Add to Slack" link
  channels.py slack-status           which Slack workspaces Moe is in
  channels.py slack-confirm <id>     say yes to an Add to Slack waiting for this Mac
  channels.py slack-unlink           disconnect Moe's own Slack app
  channels.py email-status           your Moe email address, and whose mail is yours
  channels.py email-name <name>      choose, or change, your Moe email address
  channels.py email-release          let your Moe email address go
  channels.py register <channel>     point your bot at Moe, both ways
  channels.py socket <channel>       hand the cloud a Slack/Discord socket key
  channels.py migrate                move every connected chat app over, asking nothing
  channels.py knocks                 who has messaged and is not let in
  channels.py approve <channel> <chat>   let one in
  channels.py forget <channel>       stop carrying that channel in the cloud
  channels.py owner-claim            where to confirm your own chat (the code is shown on your Mac)
  channels.py owner-status [--quiet] which chat apps reach you, as the cloud says

**Five channels, and only WhatsApp needs a person's hand.** The edge takes any
of telegram, slack, discord, whatsapp or line — the routing, the sealing and
the exactly-once id are the same for all five. What differs is how a message
gets to the edge at all. Telegram and LINE have an API that says "send here".
**Slack and Discord are not pointed anywhere**: neither will deliver a plain
message to an address you hand it, so the edge opens a connection outwards to
them and holds it, with the key this Mac has held since the app was connected
(`channels.py socket`). WhatsApp Business is configured in Meta's dashboard,
so `register` prints the URL for a person to paste. Saying "connected" for a
channel nothing is actually carrying would be the same lie as the one that hid
a dead Telegram for a day — and for the socket channels that means the
platform itself has confirmed the connection, not that a key was accepted.

**Registering Telegram takes it off this Mac.** Telegram allows a webhook OR
polling and never both, so pointing the bot at the cloud stops the local
gateway receiving anything. That is the whole point — it is what makes the bot
answer while the Mac is shut — but it is a real change to how a working thing
works, so `register telegram` says so and refuses without `--yes`.

**Upgrading uses the credential Moe already has.** `register` reads the
channel's token out of ~/.hermes/.env (`LOCAL_CREDS`) rather than asking a
person to paste it. It had to: on the free tier the one-click Telegram bot
puts its token straight into .env and never shows it — "the token never
reaches this shell" — so somebody upgrading was being asked for a secret they
had never seen, for a bot they never made by hand. That was the whole of the
upgrade path and it was a dead end. What Moe does not hold is still asked
for: **WhatsApp Business's app secret**, on the one channel still verified by
signature. Slack's signing secret and Discord's public key are no longer asked
for at all — they prove an HTTP body came from the platform, and on a socket
the edge opened there is no body to prove.

**WhatsApp is two products with one word, and this refuses to conflate them.**
The Mac links a *device* (a QR scan bound to this Mac); the cloud carries
*WhatsApp Business Cloud API* (a Meta app, a phone number id, an access
token). A linked device cannot move to a machine, so `register whatsapp` on a
Mac with a scanned session says so instead of pretending.

Nothing here holds a secret of its own: the device credential in
~/.moe/cloud/credential.json is the same one every other edge route takes, and
the bot's own token goes to the edge and is never written here.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 20
VAULT = os.path.join(os.environ.get("MOE_CLOUD_VAULT")
                     or os.path.expanduser("~/.moe/cloud"))

#: The channels the edge carries. Kept as one list so a channel added there
#: and not here is a visible gap rather than a silent one.
CHANNELS = ("telegram", "slack", "discord", "whatsapp", "line")

#: What a person has to fetch, per channel, and where from. `token` is what
#: replies are sent with; `secret` is what proves an incoming webhook.
#: Telegram has no secret to fetch — it echoes one we choose — so it is
#: minted here rather than asked for.
NEEDS = {
    "telegram": {
        "token": "Bot token from @BotFather",
        "secret": None,          # we choose it, and setWebhook carries it
        "help": "https://t.me/BotFather",
    },
    "slack": {
        "token": "Bot token (starts with xoxb-)",
        "secret": "Signing secret (Basic Information > App Credentials)",
        "help": "https://api.slack.com/apps",
    },
    "discord": {
        "token": "Bot token (Developer Portal > Bot)",
        "secret": "Public key (General Information)",
        "help": "https://discord.com/developers/applications",
    },
    "whatsapp": {
        "token": "<phone number id>:<access token>",
        "secret": "App secret (Meta app > Settings > Basic)",
        "help": "https://developers.facebook.com/apps/",
    },
    "line": {
        "token": "Channel access token (long-lived)",
        "secret": "Channel secret (Basic settings)",
        "help": "https://developers.line.biz/console/",
    },
}

#: Where a person points the provider by hand, when there is no API for it.
#: Absent means this script can do it — see `point_provider`.
#:
#: **Slack and Discord were here and are not any more.** Pointing either at a
#: Request URL was the webhook route, and it is not a route these two offer
#: for a message: they are reached over a socket the edge opens outwards
#: (`SOCKET_CHANNELS`). Leaving the two lines here would have left the file
#: saying two things — the docstring above says nobody pastes a URL for them
#: — and a person following the stale half would have configured something
#: that never delivers.
BY_HAND = {
    "whatsapp": "Meta app > WhatsApp > Configuration > Callback URL",
}


def die(msg, code=1):
    print("✗ " + msg, file=sys.stderr)
    sys.exit(code)


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def env_value(key):
    """One value out of ~/.hermes/.env, or "".

    Read rather than imported: the names are owned by Hermes plugins that
    live in a checkout this script cannot count on importing. They are stable
    and the file is two lines away.
    """
    path = os.path.join(os.environ.get("HERMES_HOME")
                        or os.path.expanduser("~/.hermes"), ".env")
    prefix = key + "="
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("export "):
                    line = line[7:].lstrip()
                if line.startswith(prefix):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def relay_url():
    """`GATEWAY_RELAY_URL` — the edge this Mac dials."""
    return env_value("GATEWAY_RELAY_URL")


#: The credential Moe ALREADY holds for a channel, per channel:
#: (token env vars, secret env var or None).
#:
#: **This is the whole of the upgrade path, and it did not exist.** A person
#: connects Telegram on the free tier with the one-click bot; the token goes
#: straight from the onboarding service into ~/.hermes/.env and is never
#: shown to them (connect-telegram-bot.sh: "The token never reaches this
#: shell"). Two weeks later they buy Moe Away, and `register` asked them to
#: **paste the bot token** — a token they have never seen, for a bot they
#: never made by hand. The only way out was BotFather, a bot list, and a
#: /token command, for something the app had done silently on their behalf.
#:
#: So the token is taken from where Moe put it, and the person is asked only
#: for what Moe genuinely does not have (Slack's signing secret, Discord's
#: public key — Hermes uses Socket Mode and never needs either).
#:
#: Two tokens are joined with ":" for WhatsApp Cloud because that is the
#: shape NEEDS documents and the edge's adapter expects.
LOCAL_CREDS = {
    "telegram": (["TELEGRAM_BOT_TOKEN"], None),
    "slack": (["SLACK_BOT_TOKEN"], "SLACK_SIGNING_SECRET"),
    "discord": (["DISCORD_BOT_TOKEN"], None),
    "line": (["LINE_CHANNEL_ACCESS_TOKEN"], "LINE_CHANNEL_SECRET"),
    "whatsapp": (["WHATSAPP_CLOUD_PHONE_NUMBER_ID", "WHATSAPP_CLOUD_ACCESS_TOKEN"],
                 "WHATSAPP_CLOUD_APP_SECRET"),
}


#: **Who this Mac already lets talk to it, per channel, as CHAT IDS.**
#:
#: The failure, in the owner's words on 2026-09-14: *"This is the bot that I
#: made from my Telegram account… That shouldn't be happening to any other
#: user, not just in Telegram, but in any channel."* `migrate` moved their
#: Telegram token to the edge and moved nothing about who was allowed to use
#: it, so the edge started with an empty allowlist and the very first message
#: — from the owner, on their own bot, from their own account — landed in
#: `moe_auth.channel_knocks` as a stranger. Moe went silent with no
#: explanation until somebody ran `channels.py approve`.
#:
#: Upgrading must never turn somebody you already allowed into a stranger. So
#: every channel is asked what this Mac holds for it, and **where a channel
#: genuinely holds nothing, that is written down here rather than left to be
#: discovered by a customer.**
#:
#: `chats` are keys whose value already IS a chat id at the edge.
#: `dm_users` are keys holding USER ids, carried only where a direct message's
#: chat id is that same user id — which is true of Telegram (``chat.id`` of a
#: DM is the user's id) and of WhatsApp Cloud (``message.from`` is the phone
#: number), and **false of Slack and Discord**, where a member id (``U…``) and
#: a conversation id (``D…``/``C…``) are different namespaces that cannot be
#: derived from one another without asking the platform. Carrying one as the
#: other would write a binding that matches nothing — a well-formed identifier
#: resolving to nothing, which is worse than the honest gap.
#: `pairing` is the platform name under `$HERMES_HOME/platforms/pairing`, whose
#: `<platform>-approved.json` is the record of people approved by pairing code.
#: Hermes mirrors an approval into `<P>_ALLOWED_USERS` **only when one is
#: already configured** (`gateway/pairing.py::_approve_user`), so on a Mac with
#: no allowlist the pairing file is the only record and reading the env alone
#: would miss everybody.
#: `gap` is what this channel cannot carry, and why. Printed by `migrate`.
CARRY_ALLOWED = {
    "telegram": {
        # `TELEGRAM_ALLOWED_USERS` is the key the owner's own .env carries.
        "chats": ("TELEGRAM_HOME_CHANNEL", "TELEGRAM_GROUP_ALLOWED_CHATS"),
        "dm_users": ("TELEGRAM_ALLOWED_USERS",),
        "pairing": "telegram",
        "gap": "",
    },
    "slack": {
        "chats": ("SLACK_HOME_CHANNEL",),
        "dm_users": (),
        "pairing": None,
        "gap": "the people you approved on Slack are member ids (U…) and a "
               "Slack chat is a conversation id (D…/C…); Moe cannot turn one "
               "into the other without asking Slack, so they knock once each",
    },
    "discord": {
        "chats": ("DISCORD_HOME_CHANNEL",),
        "dm_users": (),
        "pairing": None,
        "gap": "the people you approved on Discord are user ids and a Discord "
               "chat is a channel id; Moe cannot turn one into the other "
               "without asking Discord, so they knock once each",
    },
    "whatsapp": {
        # The CLOUD keys, not the linked device's: the edge carries WhatsApp
        # Business Cloud API, whose inbound `from` is the bare phone number
        # these hold. `WHATSAPP_ALLOWED_USERS` belongs to the Baileys linked
        # device, which never migrates (see `cmd_migrate`) and whose JIDs are
        # a different spelling of the same person.
        "chats": ("WHATSAPP_CLOUD_HOME_CHANNEL",),
        "dm_users": ("WHATSAPP_CLOUD_ALLOWED_USERS",),
        "pairing": "whatsapp_cloud",
        "gap": "",
    },
    "line": {
        "chats": (),
        "dm_users": (),
        "pairing": None,
        # Measured, not assumed: `_PLATFORM_ALLOWLIST_ENV` in
        # gateway/pairing.py has no LINE entry and `_ENV_STEPS` in
        # gateway/config_env.py has no LINE platform at all. Hermes never ran
        # LINE on this Mac, so there is nobody here to carry — which is a
        # different thing from carrying nobody by accident.
        "gap": "Hermes has no LINE platform on this Mac, so there is no list "
               "of allowed people to carry — the first person to message it "
               "knocks once",
    },
}


def _strip_jid(value):
    """``447700900000@s.whatsapp.net`` -> ``447700900000``.

    WhatsApp is the one channel whose identity is spelled two ways: Hermes
    stores a JID, Meta's Cloud API delivers a bare phone number as the
    message's ``from``, and the edge's `whatsapp_parse` uses that verbatim as
    the chat id. A binding written with the ``@`` half attached would match
    nothing for ever.
    """
    return value.split("@", 1)[0] if "@" in value else value


def _split_list(raw):
    """A comma-separated Hermes allowlist, cleaned. Hermes splits on "," and
    strips (`gateway/pairing.py::_split_allowlist`); this is the same rule, so
    a value that works there works here."""
    return [part.strip() for part in str(raw or "").split(",") if part.strip()]


def pairing_approved(platform):
    """User ids approved by pairing code on this Mac, for one HERMES platform.

    ``$HERMES_HOME/platforms/pairing/<platform>-approved.json`` is a JSON
    object keyed by user id (`PairingStore._approve_user`); the legacy location
    is ``$HERMES_HOME/pairing/``. Both are read, because a Mac upgraded in
    place has the old one. Unreadable or absent is an empty list — never a
    refusal, because a missing pairing file is the ordinary case.
    """
    if not platform:
        return []
    home = os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")
    out = []
    for folder in (os.path.join(home, "platforms", "pairing"),
                   os.path.join(home, "pairing")):
        approved = read_json(os.path.join(folder, "%s-approved.json" % platform))
        if isinstance(approved, dict):
            out.extend(str(k).strip() for k in approved if str(k).strip())
    return out


def already_allowed(channel):
    """Every chat id this Mac already lets talk to it on ``channel``.

    Ordered and de-duplicated, so `migrate` reports the same thing twice
    running and a re-run binds nothing new.
    """
    rule = CARRY_ALLOWED.get(channel) or {}
    found = []
    for key in rule.get("chats", ()):
        found.extend(_split_list(env_value(key)))
    if rule.get("dm_users"):
        users = []
        for key in rule["dm_users"]:
            users.extend(_split_list(env_value(key)))
        users.extend(pairing_approved(rule.get("pairing")))
        found.extend(users)
    if channel == "whatsapp":
        found = [_strip_jid(v) for v in found]
    seen, out = set(), []
    for value in found:
        # A Hermes allowlist may carry `*` or `all` as "everybody" on some
        # platforms. That is a POLICY, not a chat, and the edge has no such
        # binding — carrying it as a chat id would write a binding named `*`
        # that nothing ever matches. Dropped, and named in the gap below.
        if value in ("*", "all", "any") or value in seen:
            continue
        seen.add(value)
        out.append(value)
    return out


def carry_allowed(channel, base=None, token=None, quiet=False):
    """Let everyone this Mac already allows keep talking, after a migration.

    ``(carried, refused, gap)``. Each chat id goes through the same
    `/v1/channels/<c>/bind` route `cmd_approve` uses — this is approval, taken
    on the strength of an approval the person already gave on this Mac, and it
    grants nothing they had not already granted.

    **Never fatal.** A channel whose people could not be carried is still a
    migrated channel; they knock instead, which is the state this whole change
    exists to avoid but is not worse than before. `cmd_approve` and the knock
    flow stay exactly as they were, for people who are genuinely new.
    """
    rule = CARRY_ALLOWED.get(channel) or {}
    chats = already_allowed(channel)
    carried, refused = [], []
    for chat_id in chats:
        status, body = call("POST", "/v1/channels/%s/bind" % channel,
                            {"chat_id": chat_id,
                             "thread_id": "chat-%s-%s" % (channel, chat_id)},
                            base=base, token=token)
        if status < 400:
            carried.append(chat_id)
        elif "already bound" in str((body or {}).get("detail", "")):
            # Re-running a migration is ordinary, and a chat that is already
            # let in is the outcome this wanted.
            carried.append(chat_id)
        else:
            refused.append((chat_id, str((body or {}).get("detail", status))[:120]))
    return carried, refused, rule.get("gap", "")


#: **Who the owner is, is the cloud's to say — never this Mac's.** The first
#: version of reaching the owner read `TELEGRAM_HOME_CHANNEL` here and told the
#: edge that chat was the owner's; Hermes's `/sethome` writes that key, so any
#: contact allowed to talk to the bot could have made every "message me" go to
#: them. The edge now records the owner itself — the managed bot's creator, or
#: whoever sends the bot a one-time code from the signed-in app
#: (the edge's owner-reach module) — and this Mac only asks for a code and reads
#: back which channels reach the owner.
OWNER_STATUS_FILE = "owner-reach.json"


def owner_status_path():
    home = os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")
    return os.path.join(home, "cloud", OWNER_STATUS_FILE)


def cmd_owner_claim(channel="telegram"):
    """The code that confirms the owner's own chat is shown on the Mac, in
    Connections › Telegram › Confirm it's you, and nowhere else. This script
    runs where the brain can run it, so it never asks for one and never prints
    one: a code in the brain's hands is a code it could hand to anybody."""
    print("The code is shown on your Mac: Connections › Telegram › Confirm it's you.")
    return 0


def cmd_owner_status(quiet=False):
    """Which chat apps reach the owner, as the cloud says — written to
    `cloud/owner-reach.json` for the brief, which says "connected through
    Memoe" only for these. Names only; the edge never hands a chat back."""
    status, body = call("GET", "/v1/owner/status")
    if status >= 400:
        if not quiet:
            print("✗ the cloud did not answer: %s" % (body or {}).get("detail", status))
        return 1
    names = sorted(str(c) for c in (body or {}).get("channels") or [] if isinstance(c, str))
    path = owner_status_path()
    try:
        if names:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump({"channels": names, "at": int(time.time())}, fh)
            os.replace(tmp, path)
        elif os.path.exists(path):
            # Only a positive answer is kept: "none" is asked again next time.
            os.remove(path)
    except OSError as e:
        print("  (could not note it on this Mac: %s)" % e, file=sys.stderr)
    if not quiet:
        print(("✓ Moe can reach you on: %s" % ", ".join(names)) if names else
              "Moe cannot reach you on a chat app yet — confirm your own chat on your Mac: "
              "Connections › Telegram › Confirm it's you")
    return 0


#: The channels the edge reaches over a socket it holds open, rather than over
#: a webhook the provider posts to. Neither will deliver a plain message to an
#: address you hand it: Discord's HTTP webhook events contain no message event
#: at all, and Slack's require an app a person configures by hand on its own
#: site. The edge's socket module records the measurements, all read
#: 2026-09-14.
SOCKET_CHANNELS = ("slack", "discord")

#: What a channel's SOCKET opens with, when that is not the token replies are
#: sent with. **Slack's Socket Mode takes an app-level `xapp-` token and
#: nothing else** — and this Mac has held one all along: `connect.sh` has
#: always refused to connect Slack without it (`scripts/test-connections.sh`
#: asserts "✗ SLACK_APP_TOKEN is required"), and it was simply missing from
#: `LOCAL_CREDS` above. Discord's Gateway takes the bot token, which is
#: already there, so Discord needs no entry here.
SOCKET_CREDS = {"slack": "SLACK_APP_TOKEN"}


def socket_credential(channel):
    """The extra credential this channel's socket needs, or "" when it needs
    none beyond the token. "" is not a refusal for Discord and is one for
    Slack; `cmd_register_socket` is where that distinction lives."""
    key = SOCKET_CREDS.get(channel)
    return env_value(key) if key else ""


def local_credential(channel):
    """(token, secret) that Moe already has for this channel; "" for absent."""
    keys, secret_key = LOCAL_CREDS.get(channel, ([], None))
    parts = [env_value(k) for k in keys]
    token = ":".join(parts) if all(parts) else ""
    return token, (env_value(secret_key) if secret_key else "")


def edge():
    """(base URL, device token). Both, or a refusal that says which is missing.

    `MOE_EDGE_URL` wins, the way the vault's own `edge_url()` reads it, so a
    test or a local edge does not need the file rewritten.
    """
    cred = read_json(os.path.join(VAULT, "credential.json")) or {}
    token = cred.get("token")
    # The same order `Vault.edge_url()` reads: the environment first, then
    # `edge.json`. The first version of this looked in `cloud-sync.json`,
    # which holds the ledger's high-water marks and has never had a `url` —
    # so on a Mac that IS enrolled it said "not enrolled" and stopped. Two
    # readers of one vault must agree about where things are, and the way to
    # make that true is to read the file the vault documents.
    url = os.environ.get("MOE_EDGE_URL", "").strip()
    if not url:
        url = ((read_json(os.path.join(VAULT, "edge.json")) or {})
               .get("url") or "").strip()
    if not url:
        # The relay dials the same edge, and its URL is written when the Mac
        # enrols. Reading it here means a Mac that relays can also register a
        # channel without a second thing to configure.
        url = relay_url()
    if not url:
        die("this Mac is not enrolled with the cloud yet — nothing to register with")
    if not token:
        die("no device credential in %s — enrol this Mac first" % VAULT)
    return url.rstrip("/"), token


def call(method, path, body=None, base=None, token=None, timeout=TIMEOUT):
    """One edge request. Returns (status, parsed body)."""
    if base is None or token is None:
        base, token = edge()
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Authorization": "Bearer " + token}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, data=data, headers=headers,
                                 method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as answer:
            raw = answer.read()
            return answer.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, json.loads(raw)
        except ValueError:
            return exc.code, {"detail": raw.decode("utf-8", "replace")[:200]}
    except urllib.error.URLError as exc:
        die("could not reach the cloud: %s" % exc.reason)


def ask(prompt, secret=False):
    """One value from the person. Never echoed back and never logged."""
    if not sys.stdin.isatty():
        line = sys.stdin.readline()
        if not line:
            die("nothing on stdin for: %s" % prompt)
        return line.strip()
    import getpass
    return (getpass.getpass(prompt + ": ") if secret else input(prompt + ": ")).strip()


# ── pointing the provider at us ────────────────────────────────────────────

#: Where the two providers with an API for this are reached. Overridable the
#: way connect-telegram-bot.sh's is (MOE_TELEGRAM_API_BASE), so a test can
#: stand a fake in front of them: until 2026-09-11 test-platform-credentials
#: set the Telegram override, this file never read it, and the suite's
#: "migrate" section quietly posted a fake token to the real api.telegram.org
#: and passed on the refusal.
def _telegram_api_base():
    return (os.environ.get("MOE_TELEGRAM_API_BASE") or "https://api.telegram.org").rstrip("/")


def _line_api_base():
    return (os.environ.get("MOE_LINE_API_BASE") or "https://api.line.me").rstrip("/")


def point_provider(channel, token, url, secret):
    """Tell the provider where to send. (done, what to say).

    `done` is False when there is no API for it — three of the five are set in
    a dashboard by a person, and pretending otherwise would leave somebody
    with a channel that says connected and receives nothing.
    """
    if channel == "telegram":
        body = urllib.parse.urlencode({"url": url, "secret_token": secret,
                                       "drop_pending_updates": "false"}).encode()
        req = urllib.request.Request(
            "%s/bot%s/setWebhook" % (_telegram_api_base(), token), data=body,
            method="POST")
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as answer:
                said = json.loads(answer.read() or b"{}")
        except urllib.error.HTTPError as exc:
            return False, "Telegram refused: %s" % exc.read().decode("utf-8", "replace")[:160]
        except urllib.error.URLError as exc:
            return False, "could not reach Telegram: %s" % exc.reason
        if not said.get("ok"):
            return False, "Telegram refused: %s" % said.get("description", "")
        return True, "Telegram is now sending to Moe. This bot no longer polls."
    if channel == "line":
        body = json.dumps({"endpoint": url}).encode()
        req = urllib.request.Request(
            "%s/v2/bot/channel/webhook/endpoint" % _line_api_base(), data=body,
            headers={"Authorization": "Bearer " + token,
                     "Content-Type": "application/json"}, method="PUT")
        try:
            urllib.request.urlopen(req, timeout=TIMEOUT).read()
        except urllib.error.HTTPError as exc:
            return False, "LINE refused: %s" % exc.read().decode("utf-8", "replace")[:160]
        except urllib.error.URLError as exc:
            return False, "could not reach LINE: %s" % exc.reason
        return True, "LINE is now sending to Moe."
    return False, BY_HAND.get(channel, "your app's settings")


# ── the verbs ──────────────────────────────────────────────────────────────

def cmd_status():
    base, token = edge()
    status, body = call("GET", "/v1/channels/knocks", base=base, token=token)
    if status == 401:
        print("not connected: this Mac's cloud credential was not accepted")
        return 1
    if status >= 400:
        print("unavailable: %s" % body.get("detail", status))
        return 3
    knocks = body.get("knocks") or []
    print("ok: the cloud is reachable and this Mac is enrolled")
    print("    %d chat(s) waiting to be let in" % len(knocks))
    for k in knocks:
        print("      %s  %s  %s" % (k["channel"], k["chat_id"], k.get("sender") or ""))
    return 0


def cmd_register(channel, yes=False, quiet=False):
    if channel not in CHANNELS:
        die("Moe's cloud does not carry '%s'. It carries: %s"
            % (channel, ", ".join(CHANNELS)))
    if channel in SOCKET_CHANNELS:
        # The docstring says Slack's signing secret and Discord's public key
        # are "no longer asked for at all", and this is what makes that true
        # rather than only true of `migrate`. Typing `register slack` used to
        # walk somebody through fetching a signing secret and pasting a
        # Request URL — the webhook route, which neither platform offers for
        # a message. A refusal that names the verb that does work.
        die("%s is not pointed at an address — Moe's cloud opens a connection "
            "to it and holds it. Run: channels.py socket %s" % (channel, channel))
    need = NEEDS[channel]
    if channel == "telegram" and not yes:
        die("Registering Telegram points your bot at the cloud, and Telegram "
            "allows a webhook OR polling, never both — so this Mac stops "
            "receiving directly. That is what makes the bot answer while the "
            "Mac is shut. Re-run with --yes when you are ready.")

    # What Moe already has beats what a person can be asked to find. See
    # LOCAL_CREDS: on the one-click Telegram bot the person has never seen
    # the token, so asking for it was a dead end rather than a step.
    have_token, have_secret = local_credential(channel)
    if channel == "whatsapp" and not have_token \
            and os.path.exists(os.path.join(os.environ.get("HERMES_HOME")
                                            or os.path.expanduser("~/.hermes"),
                                            "whatsapp", "session", "creds.json")):
        # Two different products share one word, and conflating them is the
        # most confusable thing in this area. The Mac links a *device* (a QR
        # scan, a session bound to this Mac); the cloud carries the *Business
        # Cloud API* (a phone number id and an access token from Meta). A
        # linked device cannot move to a machine — the session is bound to
        # the hardware that scanned it — so this refuses rather than pretends.
        die("The WhatsApp on this Mac is a linked device — the QR code you scanned "
            "is tied to this Mac and cannot move to the cloud. The cloud carries "
            "WhatsApp Business Cloud API instead, which is a separate Meta app with "
            "its own phone number id and access token. Connect that first, or leave "
            "WhatsApp on the Mac.")

    if have_token:
        if not quiet:
            print("Using the %s credential Moe already has." % channel)
        token = have_token
    elif quiet:
        # Driven, not typed: there is nobody to ask. `migrate` decides what
        # to skip; this only refuses to turn a migration into a prompt.
        die("no %s credential on this Mac to move" % channel)
    else:
        print("Where to get these: %s" % need["help"])
        token = ask(need["token"], secret=True)
    if not token:
        die("nothing to send replies with")
    if need["secret"] is None:
        secret = os.urandom(24).hex()      # Telegram: we choose, setWebhook carries
    elif have_secret:
        secret = have_secret
    elif quiet:
        die("no %s on this Mac to move" % need["secret"])
    else:
        # Only what Moe genuinely does not hold. Hermes talks to Slack over
        # Socket Mode and to Discord over the gateway, so neither ever needed
        # the signing secret / public key a webhook has to be verified with.
        print("Where to get this: %s" % need["help"])
        secret = ask(need["secret"], secret=True)
        if not secret:
            die("nothing to prove an incoming webhook with")

    base, device = edge()
    status, body = call("POST", "/v1/channels/%s/app" % channel,
                        {"webhook_secret": secret, "outbound_token": token},
                        base=base, token=device)
    if status >= 400:
        die("the cloud refused: %s" % body.get("detail", status))
    url = base + body["webhook_url"]

    # **Point the provider first; let go only after it says yes.**
    #
    # `_mark_registered` used to be written HERE, before the provider was
    # pointed anywhere — and that marker is what makes
    # `configure-hermes.py::apply_channel_holder` switch this platform off on
    # the next launch. So a `setWebhook` that failed left the Mac having given
    # the channel up to a cloud the provider had never been told about, and
    # NEITHER side received. The owner lost two messages to that window on
    # 2026-09-14. The order is the whole fix: confirm, then let go.
    #
    # And a provider that CANNOT be asked (WhatsApp Business, pointed by hand
    # in Meta's dashboard) is never confirmed, so this Mac never lets go of
    # it. Deliberately the conservative direction: for a channel nothing can
    # verify, two receivers is a nuisance and none is a silence.
    done, said = point_provider(channel, token, url, secret)
    if done:
        _mark_registered(channel, url)
    print()

    # Who may talk is a separate question from who receives, so it is answered
    # either way: a person who pastes the URL tomorrow should not then find
    # themselves knocking at their own bot.
    carried, refused, gap = carry_allowed(channel, base=base, token=device,
                                          quiet=quiet)
    if done:
        print("✓ %s" % said)
        if carried:
            print("  %d person(s) you already allowed here can keep talking to Moe."
                  % len(carried))
        if refused and not quiet:
            for chat_id, why in refused:
                print("  (could not carry %s across: %s)" % (chat_id, why))
        if gap and not quiet:
            print("  Note: %s." % gap)
        if have_token:
            # The token is still in ~/.hermes/.env and the local gateway will
            # keep trying to use it. For Telegram that is now a 409 on every
            # poll, forever, because a webhook and getUpdates cannot coexist —
            # and a Connections screen reading "key saved" over a bot that
            # answers through the cloud is the same lie as the dead Telegram
            # that hid for a day. Left in place rather than deleted so
            # `forget` can put the bot back on polling, but said out loud.
            print("  Moe on this Mac no longer receives %s directly — the cloud does, "
                  "and hands it to whichever Moe is awake." % channel)
    elif channel in BY_HAND:
        # Deliberately not an error. The edge half is genuinely registered;
        # what is missing is a step only a person can take, and the URL is
        # the whole of what they need. **And this Mac has not let go**: the
        # marker is unwritten, so the platform keeps running here until
        # something can confirm the provider is pointed at the cloud — which
        # for WhatsApp Business nothing can. See `point_provider`.
        print("One step left, and only you can take it. Paste this URL into:")
        print("    %s" % said)
        print()
        print("    %s" % url)
        print()
        print("(Moe is ready for it either way — nothing arrives until you do, "
              "and this Mac keeps receiving %s until then.)" % channel)
    else:
        # **A provider Moe CAN ask, that said no.** An error, and a loud one:
        # the cloud now holds the credential and the provider is still
        # pointing wherever it was. The one thing that must not have happened
        # is this Mac letting go, and it has not — the marker above is
        # written only when the provider confirmed.
        print("✗ %s" % said)
        print("  Nothing has changed: %s still reaches Moe on this Mac, because "
              "it was never pointed away from it." % channel.capitalize())
        print("  Try again, or connect %s again in Settings › Away." % channel)
        return 2
    return 0


def cmd_knocks():
    status, body = call("GET", "/v1/channels/knocks")
    if status >= 400:
        die("the cloud refused: %s" % body.get("detail", status))
    knocks = body.get("knocks") or []
    if not knocks:
        print("Nobody is waiting.")
        return 0
    print("Waiting to be let in:")
    for k in knocks:
        # A stranger chose `sender`. One line, capped at the database, and
        # printed as plain text.
        who = (k.get("sender") or "").replace("\n", " ")[:60] or "(no name)"
        print("  %-9s %-18s %s   %s attempt(s)"
              % (k["channel"], k["chat_id"], who, k.get("attempts", 1)))
    print()
    print("Let one in:  channels.py approve <channel> <chat>")
    return 0


def cmd_approve(channel, chat_id, thread=None):
    if channel not in CHANNELS:
        die("Moe's cloud does not carry '%s'" % channel)
    # One thread per chat, named after the chat unless the caller says
    # otherwise: "message your agent and it knows this morning's conversation"
    # is only true if a channel lands in a thread that persists.
    thread = thread or ("chat-%s-%s" % (channel, chat_id))
    status, body = call("POST", "/v1/channels/%s/bind" % channel,
                        {"chat_id": chat_id, "thread_id": thread})
    if status >= 400:
        die("the cloud refused: %s" % body.get("detail", status))
    print("✓ %s %s can now reach Moe, in thread %s"
          % (channel, chat_id, body.get("thread_id", thread)))
    return 0


def _socket_keys(channel, quiet=False):
    """The two credentials this channel's socket opens with, or None.

    Refused here rather than by the vendor minutes later: a well-formed
    request with a missing key comes back as "invalid auth" from Slack, which
    names nothing a person can act on.
    """
    token, _secret = local_credential(channel)
    if not token:
        if not quiet:
            die("no %s credential on this Mac to move" % channel)
        return None
    app_token = socket_credential(channel)
    if SOCKET_CREDS.get(channel) and not app_token:
        if not quiet:
            die("Moe has no %s for this Mac's Slack. Reconnect Slack and it will "
                "be saved with the bot key." % SOCKET_CREDS[channel])
        return None
    payload = {"outbound_token": token}
    if app_token:
        payload["app_token"] = app_token
    return payload


def _socket_handover(channel, quiet=False):
    """Give the cloud the keys. True when it took them.

    **This is not "moved".** The edge now has what it needs to dial; whether
    the platform accepted the connection is a separate question, and
    `_socket_open` is the only thing that answers it.
    """
    payload = _socket_keys(channel, quiet=quiet)
    if payload is None:
        return False
    status, body = call("POST", "/v1/channels/%s/socket" % channel, payload)
    if status == 503:
        if not quiet:
            print("The cloud is not holding channel sockets yet.")
        return False
    if status >= 400:
        if not quiet:
            die("the cloud refused: %s" % body.get("detail", status))
        return False
    return True


def _socket_open(channel):
    """`(open, detail)` — whether the PLATFORM confirmed the connection.

    Slack's `hello`, Discord's `READY`. The marker the Connections screen
    reads is written here and only here, and removed when this says no: a
    channel whose keys are saved over a socket nobody opened must not read as
    connected. That is the same lie as the LINE row that went green over a
    listener LINE could never call.
    """
    status, body = call("GET", "/v1/channels/%s/socket" % channel)
    if status >= 400:
        return False, (body or {}).get("detail", "the cloud refused")
    if (body or {}).get("open"):
        _mark_registered(channel, "/v1/channels/%s/socket" % channel)
        return True, ""
    _mark_registered(channel, None)
    return False, ((body or {}).get("stopped") or (body or {}).get("last_error")
                   or "it has not opened yet")


def _wait_open(channels_, budget_s):
    """Poll the named channels TOGETHER until each opens or the budget runs
    out. Returns `{channel: detail}` for the ones that did not.

    Together rather than one after another, because the budget is a person's
    patience and it does not double because they connected two chat apps.
    """
    waiting = list(channels_)
    reasons = {}
    deadline = time.time() + budget_s
    while True:
        still = []
        for channel in waiting:
            ok, detail = _socket_open(channel)
            if ok:
                reasons.pop(channel, None)
            else:
                reasons[channel] = detail
                still.append(channel)
        waiting = still
        if not waiting or time.time() >= deadline:
            return reasons
        time.sleep(SOCKET_POLL_S)


def cmd_register_socket(channel, quiet=False):
    """Hand the cloud the keys for a channel it reaches over a socket.

    **Nothing is typed and no dashboard is visited.** Slack and Discord are
    not *pointed* anywhere — there is no address to give them. The edge opens
    a connection outwards and holds it, with the credential this Mac has held
    since the day the app was connected. Neither of the two secrets Moe has
    never held is needed: Slack's signing secret and Discord's public key
    prove that an HTTP body came from the platform, and on a socket the edge
    opened there is no body to prove.

    Somebody typed this and is watching it, so it waits the long budget.
    `migrate` is different, and says why there.
    """
    if not _socket_handover(channel, quiet=quiet):
        return 1
    reasons = _wait_open([channel], SOCKET_WAIT_S)
    if not reasons:
        if not quiet:
            print("✓ %s now answers from the cloud too." % channel)
        return 0
    if not quiet:
        print("… %s is not answering from the cloud yet: %s."
              % (channel, reasons[channel]))
    return 1


#: How long a person who typed `channels.py socket` waits. The dial itself is
#: one round trip to Slack or Discord; thirty seconds is long enough that a
#: slow one is not called a failure. **A chosen number, not a measurement.**
SOCKET_WAIT_S = 30
#: How long `migrate` waits, and it is deliberately much shorter. See there.
MIGRATE_WAIT_S = 8
SOCKET_POLL_S = 2


def cmd_migrate(yes=False):
    """Move every chat app this Mac has onto the cloud, without asking.

    **This is what "buy Moe Away and your bots keep working" actually means,
    and until 2026-09-09 nothing did it.** The pieces were all here — the edge
    holds the token, both Moes dial out, `select_runtime` fails over — and the
    join between them was a CLI verb a person had to know to run, that then
    asked them to paste a bot token by hand. For the one-click Telegram bot
    that token has never been shown to anybody, so the upgrade path asked for
    a secret that does not exist anywhere a person can reach.

    So this is the verb provisioning calls when a machine is created. It takes
    every channel the edge carries for which this Mac already holds a
    credential, registers it, and points the provider where that can be done
    from here. Nothing is typed and nothing is asked.

    It is deliberately **not** all-or-nothing. WhatsApp Business can only be
    pointed at Moe from Meta's own dashboard, and the one that needs a
    person's hand must not stop the four that do not. Each channel's outcome is reported on its own line
    and the exit code is 0 when at least one moved — a partial migration is
    the normal case here, not a failure.

    Returns 0 when something moved or there was nothing to move, 1 when
    everything that could be tried failed.
    """
    moved, pending, failed, skipped, handed = [], [], [], [], []
    for channel in CHANNELS:
        token, _secret = local_credential(channel)
        if not token:
            skipped.append(channel)
            continue
        if channel == "whatsapp":
            # The Mac's WhatsApp is a linked device bound to this Mac; the
            # cloud's is Business Cloud API. A person holding the first does
            # not thereby hold the second, and quietly registering one as the
            # other would produce a channel that verifies nothing.
            skipped.append(channel)
            continue
        if channel in SOCKET_CHANNELS:
            # **These two do not get pointed anywhere.** Neither platform will
            # deliver a plain message to an address you hand it — Discord has
            # no such thing at all, and Slack only for an app configured by
            # hand — so the edge opens a connection outwards and holds it,
            # using the key this Mac has had since the app was connected.
            #
            # This branch replaces what used to stand here: "needs its
            # Signing secret, which Moe has never held". That was true about
            # the webhook route and false about the only route these two
            # offer, and it was the whole of why buying Away left a person's
            # Slack and Discord behind.
            # The handover only. Waiting for the platform to confirm happens
            # ONCE, below, for all of them together — see there.
            if _socket_handover(channel, quiet=True):
                handed.append(channel)
            else:
                failed.append((channel, "the cloud would not take its keys"))
            continue
        need = NEEDS[channel]
        if need["secret"] is not None and not _secret:
            # A channel still on the webhook route whose secret Moe does not
            # hold. Named, not silently dropped.
            pending.append((channel, "needs its %s, which Moe has never held"
                            % need["secret"]))
            continue
        try:
            rc = cmd_register(channel, yes=True, quiet=True)
        except SystemExit as exc:      # die() inside a single channel
            failed.append((channel, "refused (%s)" % (exc.code or 1)))
            continue
        if rc == 0:
            moved.append(channel)
        elif rc == 2:
            # The provider refused to be pointed. `cmd_register` has already
            # said so and, crucially, has NOT let go — this Mac still holds
            # the channel, which is why this is "stays here" and not "lost".
            pending.append((channel, "its provider would not be pointed at the "
                                     "cloud, so it stays on this Mac"))
        else:
            failed.append((channel, "did not complete"))
    # **One short wait, shared, and "moving" is not "moved".** This runs by
    # itself the moment a machine is created (`CloudSync.migrateChannels`), so
    # its budget is somebody's first minute of Away and not a technical
    # number: waiting per channel would have made two chat apps cost twice as
    # long as one, for no reason a person could see. So every socket is asked
    # together, briefly — and one that has not opened by then is reported as
    # still coming rather than as a failure, because it usually is. The marker
    # stays unwritten until the platform confirms, so `status` and the
    # Connections screen tell the truth in the meantime and correct themselves
    # without anybody re-running anything.
    if handed:
        late = _wait_open(handed, MIGRATE_WAIT_S)
        moved.extend(c for c in handed if c not in late)
        pending.extend((c, "the cloud is still opening its connection (%s)" % why)
                       for c, why in late.items())
        # A socket channel never goes through `cmd_register`, so its people
        # are carried here. Same rule, same route, same reason: upgrading must
        # not turn somebody you already allowed into a stranger.
        for channel in handed:
            if channel not in late:
                carried_socket, _refused, _gap = carry_allowed(channel, quiet=True)
                if carried_socket:
                    print("✓ %d person(s) you already allowed on %s can keep talking."
                          % (len(carried_socket), channel))
    for channel in moved:
        print("✓ %s now answers from the cloud too." % channel)
        gap = (CARRY_ALLOWED.get(channel) or {}).get("gap")
        if gap:
            # **Named, not silent.** A channel whose allowlist cannot be
            # carried is a channel whose people will each knock once, and a
            # person is owed that sentence at the moment it becomes true
            # rather than the moment somebody messages them.
            print("  Note: %s." % gap)
    for channel, why in pending:
        print("… %s stays on this Mac: %s." % (channel, why))
    for channel, why in failed:
        print("✗ %s could not be moved: %s." % (channel, why))
    if not moved and not pending and not failed:
        print("Nothing to move: no chat app is connected on this Mac yet.")
        return 0
    return 0 if moved or pending else 1


def _registered_path(channel):
    home = os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")
    return os.path.join(home, "cloud", "channel-%s.json" % channel)


def _mark_registered(channel, url, **extra):
    """The Mac's own record that the cloud carries this channel.

    The Connections screen reads it: a channel whose keys are saved but which
    no cloud carries receives nothing, and must not read as connected (LINE
    did, 2026-09-11 — "key saved" and green, over a bot nobody could reach).
    Written only after the edge accepted the registration; removed by
    `forget`. `url=None` removes it."""
    path = _registered_path(channel)
    try:
        if url is None:
            os.remove(path)
            return
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(dict(extra, channel=channel, webhook_url=url, at=int(time.time())), fh)
        os.replace(tmp, path)
    except FileNotFoundError:
        pass
    except OSError as e:
        print("  (could not note the registration on this Mac: %s)" % e, file=sys.stderr)


def cmd_forget(channel):
    """Stop carrying this channel in the cloud: clear its credentials.

    The bindings are left alone on purpose. Someone turning the cloud half off
    and on again should not have to re-approve every chat, and a binding
    without an app registered receives nothing anyway.
    """
    if channel not in CHANNELS:
        die("Moe's cloud does not carry '%s'" % channel)
    status, body = call("POST", "/v1/channels/%s/app" % channel,
                        {"webhook_secret": None, "outbound_token": None})
    if status >= 400:
        die("the cloud refused: %s" % body.get("detail", status))
    _mark_registered(channel, None)
    print("✓ the cloud no longer holds %s credentials." % channel)
    print("  Its webhook will be refused from now on. Point the provider "
          "somewhere else, or turn polling back on.")
    return 0


def cmd_slack_install():
    """The one-click "Add to Slack" link, for the browser to open.

    Moe has its own Slack app (slice G1), so there are no keys to find: the
    edge mints a ONE-TIME link and this prints it as `SIGN_IN_URL=`, which is
    the line the Connections sheet already knows how to open (the Telegram
    bot maker prints the same). The device credential stays in the header of
    this request and never goes into the URL.

    503 means the cloud cannot offer Add to Slack yet: its Slack app, or the
    Google web client the install page proves the account with, is not set up
    (third review of slice G1 — without the Google sign-in there are no install
    links at all). That is said as "not available yet", and noted in Moe's
    Slack marker so the Connections row reads the same; the paste-the-keys
    path is the right fallback and still works.
    """
    status, body = call("POST", "/v1/channels/slack/install-link", {})
    if status == 503:
        _note_moe_slack_available(False)
        die("Add to Slack is not available yet — Moe's cloud isn't set up for it. "
            "A Slack app of your own still works: add its two keys instead.")
    if status >= 400:
        die("the cloud refused: %s" % body.get("detail", status))
    url = (body or {}).get("url") or ""
    if not url.startswith("https://"):
        die("the cloud did not give a usable link")
    _note_moe_slack_available(True)
    print("SIGN_IN_URL=%s" % url)
    # The page names this Moe account first (masked) and asks for a Google
    # sign-in as it: a link that reaches somebody else's browser shows them
    # whose account it is, and they cannot get past it.
    print("Check the page names your Memoe account, sign in with Google as it, then pick the "
          "workspace you want Moe in, choose Allow, and confirm it here in Connections.")
    return 0


#: Moe's own Slack app's marker (slice G1). **Its own file, never
#: `channel-slack.json`.** That one says "this Mac's OWN Slack app was
#: migrated and the edge holds its socket" — `relayconfig.edge_holds`, the
#: handover, `channel-holder.py` and Connections all read it, and it is written
#: and removed by `socket slack` alone. Moe's shared app is a different app on
#: a different token: sharing the file made every Connections poll delete a
#: migrated Slack's marker (the Mac then took Slack back — two consumers on one
#: `xapp-`, §5c/§5d), and adding Moe's app switched a Mac's own Slack off. No
#: reader of either file falls back to the other.
MOE_SLACK_MARKER = "channel-slack-moe.json"


def _moe_slack_path():
    home = os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")
    return os.path.join(home, "cloud", MOE_SLACK_MARKER)


def _mark_moe_slack(linked, receiving, pending=(), available=True, trouble=()):
    """Write or remove Moe's own Slack app's marker.

    Written when a workspace is linked, OR an install is waiting for this
    Mac's word, OR the cloud said Add to Slack is not available there yet;
    removed when none. `linked` says which, because a waiting install reaches
    nothing and must never read as connected (`hermes-connections.py` shows it
    as something to confirm instead), and `available` false is what makes the
    Connections row read "not available yet" rather than offer a button the
    cloud can only refuse (third review of slice G1). `trouble` is what went
    wrong per workspace, from the cloud (fourth review): a workspace Moe was
    removed from because Slack refused its key, and the latest reason a reply
    there was given up on — kept even when nothing is linked any more, because
    "Moe was removed from Acme" is exactly the case with nothing linked."""
    path = _moe_slack_path()
    try:
        if not linked and not pending and available and not trouble:
            os.remove(path)
            return
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"app": "moe", "channel": "slack", "linked": bool(linked),
                       "receiving": bool(receiving), "pending": list(pending),
                       "available": bool(available), "trouble": list(trouble),
                       "at": int(time.time())}, fh)
        os.replace(tmp, path)
    except FileNotFoundError:
        pass
    except OSError as e:
        print("  (could not note Moe's Slack app on this Mac: %s)" % e, file=sys.stderr)


def _note_moe_slack_available(available):
    """Record whether the cloud can offer Add to Slack, keeping whatever else
    the marker says (a linked workspace, an install waiting)."""
    try:
        with open(_moe_slack_path(), encoding="utf-8") as fh:
            data = json.load(fh)
        data = data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        data = None
    if data is None:
        _mark_moe_slack(False, True, (), available)
        return
    _mark_moe_slack(data.get("linked", True) is not False, data.get("receiving", True) is not False,
                    [p for p in (data.get("pending") or []) if isinstance(p, dict)], available,
                    [t for t in (data.get("trouble") or []) if isinstance(t, dict)])


def cmd_slack_status(quiet=False):
    """Which Slack workspaces this account is linked in — and the Mac's own
    record of Moe's Slack app kept in step with the answer.

    The install finishes in a browser, so nothing on this Mac hears about it;
    this is what the Connections screen's polling reaches. It writes (or
    removes) `MOE_SLACK_MARKER` and **never touches `channel-slack.json`**,
    which belongs to a migrated Slack app of the person's own (see above).
    An edge that cannot answer changes nothing at all.
    """
    status, body = call("GET", "/v1/channels/slack/link")
    if status == 503:
        if not quiet:
            print("Moe's own Slack app is not set up on the cloud yet.")
        return 0
    if status >= 400:
        if quiet:
            return 0
        die("the cloud refused: %s" % body.get("detail", status))
    spaces = (body or {}).get("workspaces") or []
    # **Added is not receiving** (DECISIONS §5c.7): Slack reaches Moe over a
    # socket the cloud holds, and the marker says whether Slack has confirmed
    # it, so Connections never reads a deaf Slack as connected. An edge too
    # old to say is taken at its word.
    receiving = (body or {}).get("receiving", True) is not False
    # Whether Add to Slack can work on this cloud at all. An edge too old to
    # say is taken as able, the way `receiving` is.
    available = (body or {}).get("available", True) is not False
    pending = []
    for p in (body or {}).get("pending") or []:
        pid = str((p or {}).get("id") or "")
        if len(pid) == 16 and all(c in "0123456789abcdef" for c in pid):
            pending.append({"id": pid, "workspace": str(p.get("workspace") or "")[:120],
                            "as": str(p.get("as") or "")[:80], "since": p.get("since") or ""})
    trouble = []
    for t in (body or {}).get("trouble") or []:
        if not isinstance(t, dict):
            continue
        entry = {k: " ".join(str(t.get(k) or "").split())[:160]
                 for k in ("workspace", "removed", "removed_at", "last_failure", "failed_at")}
        if entry["removed"] or entry["last_failure"]:
            trouble.append(entry)
    _mark_moe_slack(bool(spaces), receiving, pending, available, trouble)
    if quiet:
        return 0
    for t in trouble:
        if t["removed"]:
            print("✗ Moe was removed from Slack workspace %s: Slack stopped accepting its key "
                  "(%s). Add Moe to Slack again to reconnect it."
                  % (t["workspace"] or "(unnamed)", t["removed"]))
        elif t["last_failure"]:
            print("… a reply in Slack workspace %s couldn't be sent: %s"
                  % (t["workspace"] or "(unnamed)", t["last_failure"]))
    for p in pending:
        print("… Slack workspace %s%s wants to connect to this Memoe account — confirm it in "
              "Connections, or: channels.py slack-confirm %s"
              % (p["workspace"] or "(unnamed)", (" as %s" % p["as"]) if p["as"] else "", p["id"]))
    if not spaces:
        print("Moe is not in any Slack workspace yet."
              + ("" if available else " Add to Slack is not available yet on Moe's cloud."))
        return 0
    for space in spaces:
        print("✓ Moe is in %s" % (space.get("name") or "your workspace"))
    if not receiving:
        print("  …but Moe's cloud is not connected to Slack right now. It keeps "
              "trying.")
    return 0


def cmd_slack_confirm(pending_id, accept=True):
    """Say yes (or, with `--decline`, no) to an Add to Slack waiting for this
    account's word — what Connections' Confirm runs, through `pairing.sh
    approve slack_link <id>`.

    Every install waiting here was already proved on the install page: the
    browser signed in with Google as this Moe account before Slack was shown
    (third review of slice G1 — the cloud keeps no unproved install, and would
    refuse to link one). The yes is the second layer: this Mac agreeing to a
    workspace and a Slack name it recognises."""
    if len(pending_id) != 16 or any(c not in "0123456789abcdef" for c in pending_id):
        die("that is not an install id (16 hex characters)")
    status, body = call("POST", "/v1/channels/slack/link/confirm",
                        {"id": pending_id, "accept": bool(accept)})
    if status >= 400:
        die("the cloud refused: %s" % (body or {}).get("detail", status))
    outcome = (body or {}).get("outcome") or ""
    workspace = (body or {}).get("workspace") or "that workspace"
    cmd_slack_status(quiet=True)
    if outcome == "linked":
        print("✓ Moe is in %s now" % workspace)
        return 0
    if outcome == "declined":
        print("✓ not connected — %s was turned away" % workspace)
        return 0
    if outcome == "taken":
        die("that Slack account already uses a different Memoe account, so nothing was changed")
    die("that install has expired — choose Add to Slack again")


def cmd_slack_unlink():
    """Disconnect Moe's own Slack app from this account: every workspace link
    ends on the cloud, and so do the chats those links bound, and this Mac's
    `MOE_SLACK_MARKER` goes. What Connections' Disconnect runs for a Slack
    added in one click (`connect.sh --remove platform/slack`), and what the
    page a refused install shows tells a person to do. Never touches
    `channel-slack.json`."""
    status, body = call("POST", "/v1/channels/slack/unlink", {})
    if status == 503:
        print("Moe's own Slack app is not set up on the cloud.")
        return 0
    if status >= 400:
        die("the cloud refused: %s" % (body or {}).get("detail", status))
    _mark_moe_slack(False, False)
    print("✓ Moe's Slack app is disconnected from this account (%d link(s) ended)."
          % int((body or {}).get("links_ended") or 0))
    return 0


#: Moe's email address's marker (slice G3). **The channel is `moemail`, never
#: `email`**: `email` is the person's own IMAP mailbox in Hermes, and this Mac's
#: holder rule switches a platform off by the name in `channel-<name>.json` for
#: the chat apps it knows (`relayconfig.CHAT_CHANNELS`, which does not name
#: this one). Written from the cloud's answer; `hermes-connections.py` reads it
#: offline, so the Connections screen opens with the network down.
MOE_EMAIL_MARKER = "channel-moemail.json"


def _moe_email_path():
    home = os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")
    return os.path.join(home, "cloud", MOE_EMAIL_MARKER)


def _mark_moe_email(available, address="", owners=(), suppressed=0, unverified=None,
                    replies=None):
    """Write the marker, or remove it when the cloud offers email and this
    account has no address: that row is simply "not connected" and needs no
    file. `available` false is what makes the row read "not available yet"."""
    path = _moe_email_path()
    try:
        if available and not address:
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
            return
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"app": "moe", "channel": "moemail", "available": bool(available),
                       "address": address, "owner_addresses": list(owners)[:5],
                       "suppressed": int(suppressed or 0), "unverified": unverified,
                       "replies": replies or {}, "at": int(time.time())}, fh)
        os.replace(tmp, path)
    except OSError as e:
        print("  (could not note Moe's email on this Mac: %s)" % e, file=sys.stderr)


def cmd_email_status(quiet=False):
    """This account's Moe email address, from the cloud, and the marker kept in
    step. An edge that cannot answer changes nothing."""
    status, body = call("GET", "/v1/channels/moemail")
    if status == 503:
        _mark_moe_email(False)
        if not quiet:
            print("Moe's email isn't set up on the cloud yet.")
        return 0
    if status >= 400:
        if quiet:
            return 0
        die("the cloud refused: %s" % (body or {}).get("detail", status))
    body = body or {}
    address = " ".join(str(body.get("address") or "").split())[:80]
    owners = [" ".join(a.split())[:80] for a in (body.get("owner_addresses") or [])
              if isinstance(a, str)][:5]
    # Mail from this person's own address that the cloud could not verify
    # (slice G3): kept as the cloud said it, words and all, for the row.
    raw = body.get("unverified") if isinstance(body.get("unverified"), dict) else None
    unverified = None
    if raw:
        unverified = {k: " ".join(str(raw.get(k) or "").split())[:200]
                      for k in ("at", "domain", "reason", "signer", "sentence")}
        try:
            unverified["events"] = int(raw.get("events") or 0)
        except (TypeError, ValueError):
            unverified["events"] = 0
    _mark_moe_email(True, address, owners, body.get("suppressed") or 0, unverified,
                    _moe_email_replies(body))
    if quiet:
        return 0
    if not address:
        print("No Moe email address yet. Choose one: channels.py email-name <name>")
        return 0
    print("✓ Write to Moe at %s" % address)
    if unverified and unverified.get("sentence"):
        print("  %s" % unverified["sentence"])
    if owners:
        print("  Mail from %s reaches Moe as you; anyone else has to be let in first."
              % ", ".join(owners))
    return 0


def _moe_email_replies(body):
    """What became of Moe's email replies this week, as the cloud said it
    (slice G3, docs/EMAIL-SETUP.md §10): parts dropped past their follow-ups,
    replies that came in a second email, parts kept out of the email as the
    engine's own status notes, approval requests never emailed, and replies
    that could not be sent. Counts and times only; never words."""
    def count(obj, key):
        try:
            return max(0, int((obj or {}).get(key) or 0))
        except (TypeError, ValueError, AttributeError):
            return 0

    def at(obj, key="at"):
        return " ".join(str((obj or {}).get(key) or "").split())[:40]

    def section(name):
        value = body.get(name)
        return value if isinstance(value, dict) else {}

    late, follow, held, unsent = (section("late_reply_parts"), section("follow_ups"),
                                  section("held_back"), section("unsent"))
    # Reply-to-confirm (owner decision D1): questions still waiting, and mail
    # held without one because the hour's questions were spent.
    confirm = section("confirmations")
    return {"confirm_waiting": count(confirm, "waiting"), "confirm_held": count(confirm, "held"),
            "confirm_held_at": at(confirm),
            "late_parts": count(late, "parts"), "late_at": at(late),
            "follow_ups": count(follow, "emails"), "follow_up_at": at(follow),
            "held_back": count(held, "parts"), "held_back_at": at(held),
            "approvals": count(held, "approvals"), "approvals_at": at(held, "approvals_at"),
            "unsent": count(unsent, "replies"), "unsent_at": at(unsent)}


def cmd_email_name(name):
    """Choose, or change, this account's Moe email address. The cloud decides
    every rule; this says what it said."""
    name = (name or "").strip().lower()
    status, body = call("POST", "/v1/channels/moemail/name", {"name": name})
    detail = (body or {}).get("detail") or ""
    if status == 503:
        _mark_moe_email(False)
        die("Moe's email isn't set up on the cloud yet.")
    if status == 409:
        die("%s@… is taken, or was someone's in the last thirty days — try another name" % name)
    if status == 429:
        die(detail or "your address has been changed too often — try again later")
    if status >= 400:
        die(detail or "the cloud refused that name")
    cmd_email_status(quiet=True)
    print("✓ Your Moe email address is %s" % (body or {}).get("address", ""))
    return 0


def cmd_email_release():
    """Let this account's Moe email address go. Nobody else can take it for
    thirty days, so mail still on its way is not delivered to a stranger."""
    status, body = call("POST", "/v1/channels/moemail/release", {})
    if status == 503:
        print("Moe's email isn't set up on the cloud.")
        return 0
    if status >= 400:
        die("the cloud refused: %s" % (body or {}).get("detail", status))
    _mark_moe_email(True)
    released = (body or {}).get("released") or ""
    if released:
        print("✓ %s is no longer your Moe address; nobody else can take it for thirty days."
              % released)
    else:
        print("✓ this account had no Moe email address.")
    return 0


#: The command list, lifted from the docstring by CONTENT rather than by
#: paragraph number — the first version took index 1 and printed the wrong
#: paragraph the moment a sentence was added above it.
USAGE = "\n".join(line for line in __doc__.split("\n")
                  if line.startswith("  channels.py"))


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    verb, rest = argv[0], argv[1:]
    yes = "--yes" in rest
    rest = [a for a in rest if a != "--yes"]
    if verb == "status":
        return cmd_status()
    if verb == "socket":
        if not rest:
            die("which channel? one of: %s" % ", ".join(SOCKET_CHANNELS))
        return cmd_register_socket(rest[0])
    if verb == "slack-install":
        return cmd_slack_install()
    if verb == "slack-status":
        return cmd_slack_status(quiet="--quiet" in rest)
    if verb == "slack-unlink":
        return cmd_slack_unlink()
    if verb == "slack-confirm":
        if not rest:
            die("which install? channels.py slack-confirm <id> [--decline]")
        return cmd_slack_confirm(rest[0], accept="--decline" not in rest)
    if verb == "email-status":
        return cmd_email_status(quiet="--quiet" in rest)
    if verb == "email-name":
        if not rest:
            die("which name? channels.py email-name <name>")
        return cmd_email_name(rest[0])
    if verb == "email-release":
        return cmd_email_release()
    if verb == "register":
        if not rest:
            die("which channel? one of: %s" % ", ".join(CHANNELS))
        return cmd_register(rest[0], yes=yes)
    if verb == "migrate":
        return cmd_migrate(yes=yes)
    if verb == "knocks":
        return cmd_knocks()
    if verb == "approve":
        if len(rest) < 2:
            die("approve <channel> <chat>")
        return cmd_approve(rest[0], rest[1], rest[2] if len(rest) > 2 else None)
    if verb == "forget":
        if not rest:
            die("forget <channel>")
        return cmd_forget(rest[0])
    if verb == "owner-claim":
        return cmd_owner_claim(rest[0] if rest and not rest[0].startswith("-") else "telegram")
    if verb == "owner-status":
        return cmd_owner_status(quiet="--quiet" in rest)
    print(USAGE)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
