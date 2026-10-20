#!/usr/bin/env python3
"""Everything Hermes can connect to — read from files, no network, no gateway.

Moe's connections ARE Hermes's connections (CONNECTORS.md). This script is
the discovery half of that: it enumerates, from the Hermes checkout alone,

  * the MCP catalog      optional-mcps/<name>/manifest.yaml  (65+ servers)
  * skills that need a credential   skills/ + optional-skills/ SKILL.md
                                    frontmatter (notion, airtable, …), minus
                                    SKILL_SKIP
  * gateway platforms    plugins/platforms/<name>/plugin.yaml requires_env
                         (telegram, slack, discord, whatsapp, email, …) plus
                         the built-ins that live in gateway/platforms/*.py
                         and have no manifest to read (signal, bluebubbles, …)

  hermes-catalog.py            human table, grouped
  hermes-catalog.py --json     one JSON object: {"mcp": [...], "skills": [...], "platforms": [...]}
  hermes-catalog.py --names    "<kind>/<name>" per line (what connect.sh completes on)

Nothing is cached: the whole thing is a few hundred small files and runs in
well under a second, and a cache would be one more thing to be stale.

Every string that came from a manifest is squashed with one_line() before it
is printed. Descriptions are reviewed text in a Nous-approved catalog, but
the rule is the same for anything we did not write.
"""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hermeslib as H  # noqa: E402

H.ensure_yaml()

# Gateway platforms implemented directly in gateway/platforms/*.py rather than
# as plugins. They have no plugin.yaml, so the env vars that enable them are
# copied here from gateway/config.py's _apply_env_overrides (the variables a
# platform is enabled *from*, not every knob it reads). api_server is Moe's
# own brain channel and local is the CLI; neither is a user connection.
BUILTIN_PLATFORMS = {
    "signal": ("Signal", ["SIGNAL_HTTP_URL", "SIGNAL_ACCOUNT"]),
    "bluebubbles": ("iMessage via BlueBubbles", ["BLUEBUBBLES_SERVER_URL", "BLUEBUBBLES_PASSWORD"]),
    "whatsapp_cloud": ("WhatsApp Business Cloud API", ["WHATSAPP_CLOUD_PHONE_NUMBER_ID", "WHATSAPP_CLOUD_ACCESS_TOKEN"]),
    "weixin": ("Weixin", ["WEIXIN_ACCOUNT_ID", "WEIXIN_TOKEN"]),
    "qqbot": ("QQ Bot", ["QQ_APP_ID", "QQ_CLIENT_SECRET"]),
    "yuanbao": ("Yuanbao", ["YUANBAO_APP_ID", "YUANBAO_APP_SECRET"]),
    "webhook": ("Inbound webhooks", ["WEBHOOK_ENABLED", "WEBHOOK_SECRET"]),
}

# Credentials a plugin.yaml under-declares. Its `requires_env` is a manifest
# somebody wrote by hand, and where it disagrees with the code that reads the
# values, the code wins — so these are additions measured against Hermes's own
# loader, not opinions.
#
# **email** is the one that has actually cost a person a connection.
# `plugins/platforms/email/plugin.yaml` lists EMAIL_ADDRESS, EMAIL_PASSWORD,
# EMAIL_SMTP_HOST. `gateway/config.py::_apply_env_overrides` enables the
# platform only on `all([address, password, imap_host, smtp_host])`, and the
# adapter's own `connect()` refuses **non-retryably** with "Not configured —
# missing EMAIL_IMAP_HOST" (plugins/platforms/email/adapter.py). So the app
# asked for three fields, saved all three, said "key saved", and mail could
# never once arrive — the exact shape CLAUDE.md calls a well-formed
# identifier that resolves to nothing. The wording for the field was already
# sitting in PLATFORM_HELP["email"]; nothing ever asked for it.
#
# scripts/test-platform-credentials.sh is the falsifier: it feeds each
# platform exactly this list into a scratch HERMES_HOME and makes Hermes's
# own config loader say whether the platform came out configured. Delete the
# line below and it goes red.
#
# **sms** is the same shape, found by the same scan. `sms/adapter.py`:
#
#     if not self._webhook_url and not insecure_no_sig:
#         "[sms] Refusing to start: SMS_WEBHOOK_URL is required for Twilio
#          signature validation."
#         self._set_fatal_error("sms_missing_webhook_url", msg, retryable=False)
#
# Moe asked for the three Twilio values and never for the public URL Twilio
# posts to, so SMS could be connected and refused to start every time. Asking
# for it is honest even though a Mac behind a router usually cannot supply
# one: a field that says what it needs is a row a person can decide about,
# and a row that silently never works is not.
PLATFORM_EXTRA_REQUIRED = {
    "email": ["EMAIL_IMAP_HOST"],
    "sms": ["SMS_WEBHOOK_URL"],
}

# Platform plugins that are transports for Hermes itself rather than a service
# the user "connects": a2a (agent-to-agent) and raft need config.yaml, not a
# token, and buzz/photon/simplex are shown but the user rarely wants them.
PLATFORM_SKIP = {"a2a", "raft"}

# The chat apps Moe lists and promises: the five the cloud carries
# (the edge's channel table, `CHANNELS` in connectors/channels.py), each one
# verified to start in the gateway with exactly what the app collects
# (scripts/test-platform-credentials.sh). Decided with the owner on
# 2026-09-11 (docs/CHANNELS-CONNECTORS-DECISIONS.md §2): everything else
# Hermes speaks is `shown: false` until somebody verifies it — Matrix, IRC,
# DingTalk and Feishu cannot even import their packages from the seed, and a
# row nobody can finish is worse than no row.
#
# Hidden is not removed. The entry is still in the catalogue with its
# credentials, so a platform somebody configured by hand in ~/.hermes still
# runs, still reports its state in hermes-connections.py, and is still a
# place the brain knows it can deliver to — the app just does not offer it.
# Sources/Moe/Connections/ConnectionsModel.swift keeps the same five as its
# own lock (`shownPlatforms`), for an installed ~/.moe whose catalogue script
# is older than the app; scripts/test-connections-ui.sh requires the two
# lists to agree.
#
# Signal joined as the sixth on 2026-09-11 (§5b, slice G4): a linked device
# of the person's own account by QR, driven end to end by
# scripts/connect-signal.sh — Mac-only, like the WhatsApp you link.
SHOWN_PLATFORMS = {"telegram", "whatsapp", "signal", "slack", "discord", "line"}

# `advanced: true` — folded away in the app's list. Platforms a non-technical
# user will not have (a Nostr relay, a SimpleX daemon, a BlueBubbles server,
# enterprise Chinese chat suites, raw webhooks), and skills whose credential
# is only half the job because a CLI must be installed first.
ADVANCED_PLATFORMS = {
    "webhook", "bluebubbles", "photon", "buzz", "simplex", "irc", "ntfy", "weixin",
    "wecom", "qqbot", "yuanbao", "dingtalk", "feishu", "whatsapp_cloud",
    "msgraph_webhook", "a2a", "raft", "homeassistant", "matrix", "mattermost",
    "google_chat", "sms",
}
ADVANCED_SKILLS = {"1password", "gif-search", "shopify"}

# Skills Hermes ships that Moe deliberately does not offer. google-workspace
# is the whole Google OAuth story: it works, and connecting it needs a Google
# Cloud project, a verification review, and CASA for the restricted mail
# scopes — none of which a person installing a menu-bar app is going to do
# (CONNECTORS.md §Google: the decision). Moe reaches the same data without
# it: Calendar.app already holds the user's Google calendars, Contacts.app
# their Google contacts, and connectors/gmail.py reads and sends Gmail with
# an app password. Listing a row nobody can finish is worse than no row.
SKILL_SKIP = {"google-workspace"}

# Moe's own connectors that need a sign-in of their own. Everything else
# Mac-native either needs no credential at all (Calendar.app, the Drive for
# Desktop folder) or takes one in a sheet the app draws itself (Gmail's app
# password), so this list is short on purpose — it exists for the rows that
# have a browser sign-in but no Hermes entry to describe them.
#
# `drive-docs` is separate from `drive` by necessity, not by taste. Google's
# desktop picker flow allows exactly one scope, drive.file, and says it
# "can't be combined with any other scope" — so the contents of the
# documents the user ticks can never share a sign-in with anything else, and
# folding the two rows into one Google row is not an option that exists.
MAC_NATIVE = [
    {"kind": "mac", "name": "drive-docs", "label": "Google Docs and Sheets",
     "description": "The contents of the Google Docs, Sheets and Slides you pick, and nothing else.",
     "auth": "oauth", "credentials": [], "allowed_users": "", "prompts": {},
     "docs": "https://support.google.com/drive/answer/2424384",
     "advanced": False, "source": "connectors/drive-docs.manifest",
     "companion": "drive"},
]

# What the app shows above each paste box, and where the value comes from,
# for platforms whose plugin.yaml has no `url` (19 of them) or whose wording
# is an env var name with the underscores taken out. Curated, so a person
# who has never heard of "xapp" knows what to fetch. `help` is the page to
# open; `prompts` override the manifest's per-field text where given. Only
# https URLs — the app opens them.
PLATFORM_HELP = {
    "telegram": {"help": "https://t.me/BotFather",
                 "prompts": {"TELEGRAM_BOT_TOKEN": "Bot token from @BotFather"}},
    "discord": {"help": "https://discord.com/developers/applications",
                "prompts": {"DISCORD_BOT_TOKEN": "Bot token (Developer Portal › Bot › Reset Token)"}},
    "slack": {"help": "https://api.slack.com/apps",
              "prompts": {"SLACK_BOT_TOKEN": "Bot token (starts with xoxb-)",
                          "SLACK_APP_TOKEN": "App token (starts with xapp-, Socket Mode)"}},
    "whatsapp": {"help": "https://faq.whatsapp.com/1317564962315842",
                 "prompts": {"WHATSAPP_ENABLED": "Pair by QR (Linked devices)"}},
    "email": {"help": "https://support.google.com/accounts/answer/185833",
              "prompts": {"EMAIL_ADDRESS": "Email address", "EMAIL_PASSWORD": "App password (not your login password)",
                          "EMAIL_SMTP_HOST": "Outgoing (SMTP) server, e.g. smtp.gmail.com",
                          "EMAIL_IMAP_HOST": "Incoming (IMAP) server, e.g. imap.gmail.com"}},
    # Nothing is typed: connect-signal.sh links this Mac by QR and writes both
    # values itself. The prompts only name what the scan fills in.
    "signal": {"help": "https://support.signal.org/hc/en-us/articles/360007320551-Linked-Devices",
               "prompts": {"SIGNAL_HTTP_URL": "Filled in when you scan (Linked devices)",
                           "SIGNAL_ACCOUNT": "Pair by QR (Linked devices)"}},
    "sms": {"help": "https://console.twilio.com/",
            "prompts": {"TWILIO_ACCOUNT_SID": "Twilio account SID", "TWILIO_AUTH_TOKEN": "Twilio auth token",
                        "TWILIO_PHONE_NUMBER": "Your Twilio phone number",
                        # Twilio POSTs here and signs the request against this
                        # exact URL, so it is not optional and it cannot be a
                        # 127.0.0.1 address. Most Macs need a tunnel.
                        "SMS_WEBHOOK_URL": "Public URL Twilio posts to (e.g. https://example.com/webhooks/twilio)"}},
    "teams": {"help": "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade",
              "prompts": {"TEAMS_CLIENT_ID": "Application (client) ID", "TEAMS_CLIENT_SECRET": "Client secret value",
                          "TEAMS_TENANT_ID": "Directory (tenant) ID"}},
    "matrix": {"help": "https://matrix.org/ecosystem/clients/",
               "prompts": {"MATRIX_HOMESERVER": "Homeserver address, e.g. https://matrix.org",
                           "MATRIX_ACCESS_TOKEN": "Access token (Settings › Help & About in Element)"}},
    "mattermost": {"help": "https://developers.mattermost.com/integrate/reference/bot-accounts/",
                   "prompts": {"MATTERMOST_URL": "Server address", "MATTERMOST_TOKEN": "Bot account token"}},
    "line": {"help": "https://developers.line.biz/console/",
             "prompts": {"LINE_CHANNEL_ACCESS_TOKEN": "Channel access token", "LINE_CHANNEL_SECRET": "Channel secret"}},
    "google_chat": {"help": "https://developers.google.com/workspace/chat/authenticate-authorize-chat-app",
                    "prompts": {"GOOGLE_CHAT_SERVICE_ACCOUNT_JSON": "Path to the service-account JSON file"}},
    "homeassistant": {"help": "https://www.home-assistant.io/docs/authentication/#your-account-profile",
                      "prompts": {"HASS_TOKEN": "Long-lived access token (profile page)", "HASS_URL": "Home Assistant address"}},
    "irc": {"help": "https://libera.chat/guides/connect",
            "prompts": {"IRC_SERVER": "Server, e.g. irc.libera.chat", "IRC_CHANNEL": "Channel, e.g. #moe",
                        "IRC_NICKNAME": "Nickname for the bot"}},
    "ntfy": {"help": "https://docs.ntfy.sh/",
             "prompts": {"NTFY_TOPIC": "Topic name to listen on"}},
    "simplex": {"help": "https://simplex.chat/docs/cli.html",
                "prompts": {"SIMPLEX_WS_URL": "SimpleX CLI websocket address, e.g. ws://127.0.0.1:5225"}},
    "buzz": {"help": "https://github.com/nostr-protocol/nips",
             "prompts": {"BUZZ_RELAY_URL": "Relay address (wss://…)", "BUZZ_PRIVATE_KEY": "Nostr private key (nsec…)"}},
    "photon": {"help": "https://app.photon.codes/",
               "prompts": {"PHOTON_PROJECT_ID": "Project ID", "PHOTON_PROJECT_SECRET": "Project secret"}},
    "bluebubbles": {"help": "https://docs.bluebubbles.app/",
                    "prompts": {"BLUEBUBBLES_SERVER_URL": "BlueBubbles server address",
                                "BLUEBUBBLES_PASSWORD": "Server password"}},
    "webhook": {"help": "https://hermes-agent.nousresearch.com/docs/user-guide/messaging/webhook",
                "prompts": {"WEBHOOK_ENABLED": "Turn on (true)", "WEBHOOK_SECRET": "Shared secret senders must present"}},
    "whatsapp_cloud": {"help": "https://developers.facebook.com/apps/",
                       "prompts": {"WHATSAPP_CLOUD_PHONE_NUMBER_ID": "Phone number ID (Meta app › WhatsApp)",
                                   "WHATSAPP_CLOUD_ACCESS_TOKEN": "Access token"}},
    "dingtalk": {"help": "https://open-dev.dingtalk.com/",
                 "prompts": {"DINGTALK_CLIENT_ID": "App key", "DINGTALK_CLIENT_SECRET": "App secret"}},
    "feishu": {"help": "https://open.feishu.cn/app",
               "prompts": {"FEISHU_APP_ID": "App ID", "FEISHU_APP_SECRET": "App secret"}},
    "wecom": {"help": "https://work.weixin.qq.com/wework_admin/frame#apps",
              "prompts": {"WECOM_BOT_ID": "Bot ID", "WECOM_SECRET": "Secret"}},
    "weixin": {"help": "https://mp.weixin.qq.com/",
               "prompts": {"WEIXIN_ACCOUNT_ID": "Account ID", "WEIXIN_TOKEN": "Token"}},
    "qqbot": {"help": "https://q.qq.com/",
              "prompts": {"QQ_APP_ID": "App ID", "QQ_CLIENT_SECRET": "Client secret"}},
    "yuanbao": {"help": "https://yuanbao.tencent.com/",
                "prompts": {"YUANBAO_APP_ID": "App ID", "YUANBAO_APP_SECRET": "App secret"}},
}

# Skill credentials: the same, for the skills a person is likely to connect.
SKILL_HELP = {
    "notion": {"help": "https://www.notion.so/profile/integrations", "prompts": {"NOTION_API_KEY": "Internal integration secret"}},
    "airtable": {"help": "https://airtable.com/create/tokens", "prompts": {"AIRTABLE_API_KEY": "Personal access token"}},
    "canvas": {"help": "https://community.canvaslms.com/t5/Student-Guide/How-do-I-manage-API-access-tokens-as-a-student/ta-p/273",
               "prompts": {"CANVAS_API_TOKEN": "Access token (Account › Settings)", "CANVAS_BASE_URL": "Your school's Canvas address"}},
    "gif-search": {"help": "https://developers.google.com/tenor/guides/quickstart", "prompts": {"TENOR_API_KEY": "Tenor API key"}},
    "1password": {"help": "https://developer.1password.com/docs/service-accounts/",
                  "prompts": {"OP_SERVICE_ACCOUNT_TOKEN": "Service account token (needs the 1Password command-line tool installed)"}},
    "shopify": {"help": "https://shopify.dev/docs/apps/build/authentication-authorization/access-tokens",
                "prompts": {"SHOPIFY_ACCESS_TOKEN": "Admin API access token", "SHOPIFY_STORE_DOMAIN": "Store domain (….myshopify.com)",
                            "SHOPIFY_API_VERSION": "API version, e.g. 2025-07"}},
    "siyuan": {"help": "https://github.com/siyuan-note/siyuan/blob/master/API.md",
               "prompts": {"SIYUAN_TOKEN": "Access token (Settings › About)", "SIYUAN_URL": "SiYuan address, e.g. http://127.0.0.1:6806"}},
    "teams-meeting-pipeline": {"help": "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade",
                               "prompts": {"MSGRAPH_TENANT_ID": "Directory (tenant) ID", "MSGRAPH_CLIENT_ID": "Application (client) ID",
                                           "MSGRAPH_CLIENT_SECRET": "Client secret value"}},
}


_BLURB_DROP = [
    r"https?://\S+",
    # Platform plugins all open with "<Name> gateway adapter for Hermes Agent."
    # — true, and useless to a person choosing a chat app.
    r"^[^.]*\bgateway adapter for Hermes Agent\b[^.]*\.\s*",
    # A whole "via …" clause goes, to the end of its sentence (a dot inside a
    # word — discord.py, Node.js — is not the end): "via curl + jq", "via
    # Atlassian's hosted remote MCP", "via gws CLI or Python", "via API token"
    # — every one of them is the how, and the how is Hermes's business.
    r"\s*\bvia\b(?:[^.;:]|\.(?!\s|$))*",
    r"\s*\+\s*\w+ CLI\b", r"\bremote MCP\b", r"\bstdio bridge\b", r"\bMCP\b",
    r"\bREST APIs?\b", r"\bGraphQL APIs?\b", r"\bAPIs?\b", r"\bCLI\b",
    r"\(\s*\)",
]


def plain_blurb(text, limit=90):
    """A catalog description as a sentence for a person, not a developer:
    the transport words gone ("MCP", "remote MCP", "stdio bridge", "API",
    "via curl + jq"), URLs gone, doubled spaces and orphaned punctuation
    tidied, sentence case, at most `limit` characters ending on a word.
    Built on one_line, so nothing foreign gets through either."""
    s = H.one_line(text, 400)
    s = s.replace("op CLI", "1Password")           # "Set up op CLI" — op is 1Password's tool
    for pat in _BLURB_DROP:
        s = re.sub(pat, " ", s)
    # The engine's name is not one the person chose ("workflows from Hermes").
    # After the drops: the adapter boilerplate above names Hermes too.
    s = re.sub(r"\bHermes Agent\b", "Moe", s)
    s = re.sub(r"\bHermes\b", "Moe", s)
    s = re.sub(r"\s+([,.;:])(?=\s|$)", r"\1", s)   # "Notion , pages" → "Notion, pages" (not ".NET")
    s = re.sub(r"([,;:])\s*([,;:.])", r"\2", s)    # ", ." → "."
    s = re.sub(r",?\s+(?:and|or)\s*([.;:])(?=\s|$)", r"\1", s)   # "environments, and." → "environments."
    s = re.sub(r",?\s+(?:and|or)\s*$", "", s)
    s = re.sub(r"\s*\+\s*(?=\w)", " and ", s)         # "Twilio + inbound webhook" → "Twilio and inbound webhook"
    s = re.sub(r"\(\s*[,;:]\s*", "(", s)           # "(, no public port)" → "(no public port)"
    s = re.sub(r"\s+", " ", s).strip(" ,;:-–—")
    s = re.sub(r"^(via|using|through|with|from)\s+", "", s, flags=re.I)
    s = s.strip(" ,;:-–—")
    if not s:
        return ""
    if s[0].islower():
        s = s[0].upper() + s[1:]
    if len(s) > limit:
        cut = s[:limit].rsplit(" ", 1)[0].rstrip(" ,;:-–—")
        s = (cut if len(cut) >= limit // 2 else s[:limit - 1].rstrip()) + "…"
    return s


def _apply_help(entry, table):
    """Merge a curated PLATFORM_HELP / SKILL_HELP row into a catalog entry:
    curated prompts win over manifest wording, the manifest's docs URL is
    kept when it has one, else the curated help page fills it."""
    row = table.get(entry["name"])
    if not row:
        return entry
    prompts = dict(entry.get("prompts") or {})
    for k, v in (row.get("prompts") or {}).items():
        if H.env_name(k):
            prompts[k] = v
    entry["prompts"] = prompts
    if not entry.get("docs"):
        entry["docs"] = _https(row.get("help"))
    return entry


def _https(url):
    """A documentation URL from a manifest, or "" — only https, one line."""
    url = H.one_line(url, 200)
    return url if url.startswith("https://") and " " not in url else ""


# ── MCP catalog ───────────────────────────────────────────────────────────

def mcp_entries():
    root = H.catalog_dir()
    out = []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return out
    for d in names:
        path = os.path.join(root, d, "manifest.yaml")
        if not os.path.isfile(path):
            continue
        m = H.load_yaml_file(path)
        if not isinstance(m, dict):
            continue
        name = H.safe_name(m.get("name") or d)
        if not name:
            continue
        transport = m.get("transport") if isinstance(m.get("transport"), dict) else {}
        auth = m.get("auth") if isinstance(m.get("auth"), dict) else {}
        kind = str(auth.get("type") or "none").lower().replace("_", "-")   # api_key → api-key
        # Env var names are manifest text: only a real name gets through
        # (it ends up in a prompt and on a .env line via connect.sh).
        env, prompts = [], {}
        for spec in auth.get("env") or []:
            n = H.env_name(spec.get("name")) if isinstance(spec, dict) else H.env_name(spec)
            if n:
                env.append(n)
                # The manifest's own wording for the field ("Stripe API key"),
                # what the app shows above the paste box. Manifest text: one line.
                if isinstance(spec, dict) and spec.get("prompt"):
                    prompts[n] = H.one_line(spec.get("prompt"), 60)
        # Hermes derives the bearer-token env name for http+api_key servers.
        if kind == "api-key" and transport.get("type") == "http" and not env:
            env = ["MCP_%s_API_KEY" % name.upper().replace("-", "_")]
        out.append({
            "kind": "mcp",
            "name": name,
            "label": name,
            "description": H.one_line(m.get("description"), 100),
            "blurb": plain_blurb(m.get("description")),
            "auth": kind,                         # oauth | api-key | none
            # Hermes "case 2": OAuth through a third-party provider, signed in
            # with `hermes auth <provider>`, not `hermes mcp login`.
            "provider": H.safe_name(auth.get("provider")) or "" if kind == "oauth" else "",
            "transport": H.one_line(transport.get("type") or "?", 12),
            "url": H.one_line(transport.get("url"), 120) if transport.get("url") else "",
            "credentials": env,
            "prompts": prompts,
            # Where a key comes from / what the service is: the manifest's
            # `source`. https only — it becomes a link the app opens.
            "docs": _https(m.get("source")),
            "install": "hermes mcp install %s" % name,
            "source": path,
        })
    return out


# ── Skills with credentials ───────────────────────────────────────────────

def _frontmatter(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return None
    text = text.lstrip("﻿")
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    if end < 0:
        return None
    fm = H.load_yaml_text(text[3:end])
    return fm if isinstance(fm, dict) else None


def _skill_credentials(fm):
    """The four shapes Hermes's skills_tool.py merges (see
    _get_required_environment_variables there), flattened to
    (env_names, credential_files)."""
    env, files = [], []
    pre = fm.get("prerequisites") if isinstance(fm.get("prerequisites"), dict) else {}
    for v in pre.get("env_vars") or []:
        env.append(H.env_name(v))
    req = fm.get("required_environment_variables")
    for v in [req] if isinstance(req, dict) else (req or []):     # Hermes accepts a lone dict too
        if isinstance(v, dict) and not v.get("optional"):
            env.append(H.env_name(v.get("name") or v.get("env_var")))
        elif isinstance(v, str):
            env.append(H.env_name(v))
    setup = fm.get("setup") if isinstance(fm.get("setup"), dict) else {}
    for v in setup.get("collect_secrets") or []:
        if isinstance(v, dict):
            env.append(H.env_name(v.get("env_var") or v.get("name")))
    env = [e for e in env if e]          # frontmatter text: only real names
    for v in fm.get("required_credential_files") or []:
        if isinstance(v, dict) and (v.get("path") or v.get("name")):
            files.append(str(v.get("path") or v.get("name")))
        elif isinstance(v, str):
            files.append(v)
    seen, env_u = set(), []
    for e in env:
        if e not in seen:
            seen.add(e)
            env_u.append(e)
    return env_u, files


def skill_entries():
    out, seen = [], set()
    for origin, root in H.skill_roots():
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            if "SKILL.md" not in filenames:
                continue
            fm = _frontmatter(os.path.join(dirpath, "SKILL.md"))
            if not fm:
                continue
            name = H.safe_name(fm.get("name") or os.path.basename(dirpath))
            if not name or name in seen or name in SKILL_SKIP:
                continue
            env, files = _skill_credentials(fm)
            if not env and not files:
                continue          # a skill with no credential is not a connection
            seen.add(name)
            rel = os.path.relpath(dirpath, root).split(os.sep)
            category = rel[0] if len(rel) > 1 else ""
            out.append(_apply_help({
                "kind": "skill",
                "name": name,
                "label": name,
                "description": H.one_line(fm.get("description"), 100),
                "blurb": plain_blurb(fm.get("description")),
                "category": category,
                "origin": origin,                 # synced | bundled | optional
                "auth": "credential-file" if files else "api-key",
                "credentials": env + files,
                "prompts": {},
                "docs": "",
                "advanced": name in ADVANCED_SKILLS,
                "source": os.path.join(dirpath, "SKILL.md"),
            }, SKILL_HELP))
    out.sort(key=lambda e: e["name"])
    return out


# ── Gateway platforms ─────────────────────────────────────────────────────

def platform_entries():
    out = {}
    root = H.platforms_dir()
    try:
        names = sorted(os.listdir(root))
    except OSError:
        names = []
    for d in names:
        if d in PLATFORM_SKIP:
            continue
        path = os.path.join(root, d, "plugin.yaml")
        if not os.path.isfile(path):
            continue
        m = H.load_yaml_file(path)
        if not isinstance(m, dict):
            continue
        name = H.safe_name(d)
        if not name:
            continue
        def names(lst):
            out_ = [H.env_name(v.get("name")) if isinstance(v, dict) else H.env_name(v) for v in (lst or [])]
            return [n for n in out_ if n]
        req = names(m.get("requires_env"))
        opt = names(m.get("optional_env"))
        for extra in PLATFORM_EXTRA_REQUIRED.get(name, []):
            if extra not in req:
                req.append(extra)
        # Per-field wording and the page a token comes from (BotFather, the
        # Discord developer portal …), for the app's paste box.
        prompts, docs = {}, ""
        for v in (m.get("requires_env") or []) + (m.get("optional_env") or []):
            if not isinstance(v, dict):
                continue
            n = H.env_name(v.get("name"))
            if n and v.get("prompt"):
                prompts[n] = H.one_line(v.get("prompt"), 60)
            if not docs and n in req:
                docs = _https(v.get("url"))
        # Hermes denies every sender until an allowlist exists; connecting a
        # chat platform without one is not a connection anyone can use.
        allowed = [v for v in opt if v.endswith("_ALLOWED_USERS")]
        out[name] = _apply_help({
            "kind": "platform",
            "name": name,
            "label": H.one_line(m.get("label") or name, 40),
            "description": H.one_line(m.get("description"), 100),
            "blurb": plain_blurb(m.get("description")),
            "auth": "token",
            "credentials": req,
            "allowed_users": allowed[0] if allowed else "",
            "prompts": prompts,
            "docs": docs,
            "advanced": name in ADVANCED_PLATFORMS,
            "shown": name in SHOWN_PLATFORMS,
            "source": path,
        }, PLATFORM_HELP)
    for name, (label, req) in BUILTIN_PLATFORMS.items():
        out.setdefault(name, _apply_help({
            "kind": "platform", "name": name, "label": label, "description": "", "blurb": "",
            "auth": "token", "credentials": list(req), "allowed_users": "",
            "prompts": {}, "docs": "", "advanced": name in ADVANCED_PLATFORMS,
            "shown": name in SHOWN_PLATFORMS,
            "source": "gateway/platforms/%s.py" % name,
        }, PLATFORM_HELP))
    return [out[k] for k in sorted(out)]


# ── Output ────────────────────────────────────────────────────────────────

def mac_entries():
    """Moe's own rows. Nothing here is read from the Hermes checkout, so this
    is the one list that still answers when Hermes is not installed."""
    return [dict(e, blurb=plain_blurb(e["description"])) for e in MAC_NATIVE]


def composio_entries():
    """The services reachable through the Composio broker, one entry each.

    This is the one part of the catalogue that is NOT read from files. Every
    other list here comes from the Hermes checkout, which is why this script
    can promise "no network, no gateway" — and that promise still holds for
    those, because this returns nothing at all unless a composio server is
    configured, and Moe does not configure one unless the owner connected it.

    The services are Composio's to name, never ours. A hard-coded list would
    freeze the catalogue at whatever we happened to type, which is exactly
    the failure `hermes-catalog.py` exists to avoid for MCP servers.

    Failures are silent by design: an unreachable broker means the entries
    are absent, and hermes-connections.py is the half that says so out loud.
    The catalogue answering "what could be connected" should degrade to a
    shorter list, not to an error in a screen about something else.
    """
    snapshot = _composio_snapshot()
    #: slug -> whether Composio holds that service's sign-in. The live route
    #: answers this itself; the snapshot is the fallback for a Mac whose
    #: installed composio.py predates the field.
    #:
    #: **Where this dict has no opinion, the answer is True — listed.** Both
    #: unknowns point that way on purpose: a slug the snapshot has never heard
    #: of is a service Composio added since the release, and an EMPTY dict is
    #: a ~/.moe with no snapshot file at all. Defaulting to False there would
    #: empty the Connections screen because a data file was missing, silently
    #: and with no error anywhere — the shape of failure this repo keeps
    #: paying for. A too-long list is a bad list; a list that vanishes is a
    #: broken app.
    managed = {k.get("slug"): bool(k.get("managed_auth")) for k in snapshot}
    #: slug -> every way Composio can authenticate it (`auth_schemes` in the
    #: snapshot). Decides the ROUTE for the unmanaged ones: a service with a
    #: key scheme gets the paste sheet; one with none stays as it was.
    schemes = {k.get("slug"): [str(x) for x in (k.get("auth_schemes") or [])] for k in snapshot}

    ranking = _composio_ranking()

    def listed(slug, managed_auth):
        """Before search: the ranking's verdict when it has one (popular AND
        connectable today), Composio's managed-sign-in answer otherwise — a
        service added since the ranking was made keeps the old rule."""
        r = ranking.get(slug)
        return bool(r["top"]) if r else bool(managed_auth)

    live = _composio_live_rows()
    out = []
    seen = set()
    for row in live:
        slug = row.get("slug") or ""
        if not slug:
            continue
        seen.add(slug)
        featured = row.get("managed_auth")
        if featured is None:
            featured = managed.get(slug, True)
        out.append(_composio_entry(slug, row.get("label") or slug, "composio",
                                   featured=bool(featured),
                                   auth_schemes=schemes.get(slug, []),
                                   listed=listed(slug, featured), rank=ranking.get(slug)))
    # What the live list cannot say — before this Mac has a key, and for
    # every page after the first (the session route pages by twenty and
    # `composio.py list` reads one page): the snapshot the release carries,
    # taken from a session by scripts/snapshot-composio-catalog.sh. Still
    # Composio's list; the snapshot is a copy of its answer, not a list of
    # ours. A slug the live list already named keeps the live entry.
    for kit in snapshot:
        slug = kit.get("slug") or ""
        if not slug or slug in seen:
            continue
        seen.add(slug)
        out.append(_composio_entry(slug, kit.get("label") or slug, "composio-snapshot",
                                   featured=bool(kit.get("managed_auth")),
                                   auth_schemes=schemes.get(slug, []),
                                   listed=listed(slug, kit.get("managed_auth")),
                                   rank=ranking.get(slug)))
    # Listed by the ranking and in neither list: Composio's newer `*_mcp`
    # toolkits, which the session route omits from its catalogue and a
    # session reaches all the same. The ranking carries their names.
    for slug, r in sorted(ranking.items()):
        if slug in seen or not r.get("top") or not r.get("label"):
            continue
        seen.add(slug)
        out.append(_composio_entry(slug, r["label"], "composio-ranking", featured=False,
                                   auth_schemes=r.get("schemes") or [], listed=True, rank=r))
    return out


#: Auth schemes where the person supplies the credential and the account is
#: live at once (composio.py KEY_SCHEMES, same list). OAuth schemes redirect.
COMPOSIO_KEY_SCHEMES = ("API_KEY", "BEARER_TOKEN", "BASIC", "BASIC_WITH_JWT")


def composio_auth(featured, auth_schemes):
    """Which flow Connect starts for a brokered row.

    "oauth": Composio holds the sign-in — a link, a page, done. That is 119 of
    1,378 and it is the row's own promise ("One sign-in, nothing to paste").

    "api-key": Composio holds no sign-in and the service authenticates by a
    key the person pastes — 1,122 API_KEY-only plus the BASIC / BEARER ones.
    The row is drawn with the paste sheet, and the field names come from
    Composio's record of the service at connect time (composio.py fields),
    not from here: what a service calls its key is its fact, not ours.

    "oauth" again for the rest — OAuth-only with no managed app (the person
    would have to register their own client), and the 13 that need no auth.
    Unchanged from before 2026-09-11, and still the honest gap: those rows
    end in "Composio did not return a sign-in link". Measured over the
    shipped snapshot: 1,197 rows take the key route, 181 the link.
    """
    if featured:
        return "oauth"
    if any(str(x).upper() in COMPOSIO_KEY_SCHEMES for x in auth_schemes or []):
        return "api-key"
    # Nothing to sign in to: a session calls these with no account at all
    # (Yelp, Hacker News, OpenWeatherMap — measured 2026-09-30).
    if auth_schemes and all(str(x).upper() == "NO_AUTH" for x in auth_schemes):
        return "none"
    return "oauth"


def _composio_live_rows():
    """`composio.py list --json`, when this Mac has a Composio server and a
    key; `[]` otherwise, silently (see composio_entries)."""
    cfg_path = os.path.join(H.hermes_home(), "config.yaml")
    try:
        with open(cfg_path, encoding="utf-8") as fh:
            if not re.search(r"(?m)^\s{2}composio:\s*$", fh.read()):
                return []
    except OSError:
        return []
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "composio.py")
    if not os.path.exists(script):
        return []
    try:
        r = subprocess.run([sys.executable, script, "list", "--json"],
                           capture_output=True, text=True, timeout=25)
        return json.loads(r.stdout or "{}").get("connections") or []
    except Exception:
        return []


#: Beside this script: what a Composio session offered when the release was
#: cut. scripts/snapshot-composio-catalog.sh writes it.
COMPOSIO_SNAPSHOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "composio-catalog.json")


def _composio_snapshot():
    """The toolkits in the shipped snapshot, or `[]` when there is none or it
    does not parse — the catalogue degrades to a shorter list, never to an
    error in a screen about something else."""
    try:
        with open(COMPOSIO_SNAPSHOT, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return []
    kits = doc.get("toolkits") if isinstance(doc, dict) else None
    return [k for k in (kits or []) if isinstance(k, dict)]


#: Beside this script: how popular each service is, for the order the pane
#: shows them in. scripts/rank-composio-catalog.py writes it.
COMPOSIO_RANKING = os.path.join(os.path.dirname(os.path.abspath(__file__)), "composio-ranking.json")


def _composio_ranking():
    """{slug: {"score", "shelf", "top"}}, or {} when there is no ranking —
    which leaves every row on the managed-sign-in rule it had before."""
    try:
        with open(COMPOSIO_RANKING, encoding="utf-8") as fh:
            kits = json.load(fh).get("toolkits")
    except (OSError, ValueError, AttributeError):
        return {}
    return {k: v for k, v in (kits or {}).items()
            if isinstance(v, dict) and "score" in v and "top" in v}


def _composio_entry(slug, label, source, featured=True, auth_schemes=None, listed=None, rank=None):
    # `featured` below is whether Composio holds the sign-in (it decides the
    # route and the blurb); `listed` is whether the pane shows the row before
    # a search, which the popularity ranking decides.
    if listed is None:
        listed = featured
    # The description becomes the "What Moe can do with it" line, so it has
    # to answer that question. It used to read "Sign in once, nothing to
    # paste", which is how you CONNECT — true, useful, and not what the
    # heading asked. Seen in a screenshot; no amount of reading JSON would
    # have shown it.
    desc = "Moe can read and work with your %s, and change things when you ask." % label
    # "One sign-in, nothing to paste" is only true where Composio holds the
    # sign-in — 119 of the 1,378 (`featured`). For the rest the sign-in wants
    # a client id and secret the person would have to register themselves,
    # and this row has nowhere to put them: `credentials` is empty below, by
    # construction. So the sentence is dropped rather than repeated falsely
    # 1,259 times. Those services are still here and still searchable; the
    # pane just does not lead with them.
    blurb = "Moe can read and work with your %s, and change things when you ask." % label
    auth = composio_auth(featured, auth_schemes)
    if featured:
        blurb += " One sign-in, nothing to paste."
    elif auth == "none":
        blurb = "Always on: Moe uses %s whenever you ask. Nothing to sign in to." % label
    elif auth == "api-key":
        # Kept under 120 characters with the longest label the catalogue
        # carries; scripts/test-connections-ui.sh holds that line.
        blurb = "Moe can work with your %s once you paste a key from its settings." % label
    return {
        "kind": "composio",
        "name": slug,
        "label": label,
        "description": desc,
        "blurb": blurb,
        # Whether the Connections pane lists this before you search. The rule
        # is Composio's own answer, not a name we typed: see
        # scripts/snapshot-composio-catalog.sh and docs/COMPOSIO.md.
        "featured": bool(listed),
        # Popularity: the pane's order, most used first. Never drawn.
        "rank": int((rank or {}).get("score") or 0),
        # "personal" | "business": which shelf a listed row sits on.
        "shelf": str((rank or {}).get("shelf") or ""),
        # Measured not working at Composio (scripts/rank-composio-catalog.py
        # BROKEN): the row says so instead of offering it.
        "broken": bool((rank or {}).get("broken")),
        # oauth: clicking Connect means "a URL opens". api-key: the paste
        # sheet, whose fields the app asks composio.py for at connect time
        # (`connect.sh --fields`), which is why `credentials` stays empty
        # even then — the names are the service's, read from its record,
        # never a list kept here. Either way the broker holds the credential
        # and nothing is stored on this Mac.
        "auth": auth,
        "provider": "composio",
        "transport": "http",
        "url": "",
        "credentials": [],
        "prompts": {},
        "docs": "https://composio.dev/",
        "install": "connect.sh composio/%s" % slug,
        "source": source,
    }


def catalog():
    return {"mcp": mcp_entries(), "skills": skill_entries(), "platforms": platform_entries(),
            "mac": mac_entries(), "composio": composio_entries(),
            "hermes_agent_dir": H.agent_dir()}


def print_table(cat):
    if not os.path.isdir(H.agent_dir()):
        print("Hermes checkout not found at %s — install Hermes first (scripts/install.sh)." % H.agent_dir())
        return 1
    print("MCP servers (%d)  — hermes mcp install <name>" % len(cat["mcp"]))
    for e in cat["mcp"]:
        print("  %-18s %-8s %-6s %s" % (e["name"], e["auth"], e["transport"], e["description"]))
    print()
    print("Skills with credentials (%d)" % len(cat["skills"]))
    for e in cat["skills"]:
        print("  %-18s %-16s %s  [%s]" % (e["name"], e["auth"], e["description"], ", ".join(e["credentials"])))
    print()
    shown = [e for e in cat["platforms"] if e.get("shown")]
    print("Chat apps Moe offers (%d)  — a token in ~/.hermes/.env" % len(shown))
    for e in shown:
        print("  %-18s %-28s %s" % (e["name"], e["label"], ", ".join(e["credentials"])))
    print("Chat apps Hermes speaks but Moe does not list (%d)  — run by hand only"
          % (len(cat["platforms"]) - len(shown)))
    for e in cat["platforms"]:
        if not e.get("shown"):
            print("  %-18s %-28s %s" % (e["name"], e["label"], ", ".join(e["credentials"])))
    print()
    print("This Mac, with a sign-in of their own (%d)  — connect.sh <name>" % len(cat["mac"]))
    for e in cat["mac"]:
        print("  %-18s %-28s %s" % (e["name"], e["label"], e["description"]))
    return 0


def main(argv):
    cat = catalog()
    if "--json" in argv:
        json.dump(cat, sys.stdout, indent=1)
        print()
        return 0
    if "--names" in argv:
        for kind in ("mcp", "skills", "platforms", "mac"):
            for e in cat[kind]:
                print("%s/%s" % (e["kind"], e["name"]))
        return 0
    return print_table(cat)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
