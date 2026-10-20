#!/usr/bin/env python3
"""Fetch the real icon for every connector the Connections screen can show.

Reads the connector list from the Hermes catalogue itself (65 MCP servers,
the credentialed skills, the gateway platforms) plus the Mac-native rows, so
it cannot drift out of sync with what the screen actually lists. The first
version of this was a hand-typed list of 61 and missed half the catalogue.

Why at build time and not at runtime: asking each company for its favicon on
the user's Mac would hand every one of them a list of which tools that user
has connected, break offline, and look ragged. Fetching here, once, ships a
folder of images and the user's machine never makes the request.

Order of preference per service:

  1. an explicit URL, for the brands whose domain serves the parent
     company's mark rather than the product's (every Google product, Chrome)
  2. Simple Icons — CC0, vector, served already tinted in the brand's own
     hex. Crisp at any size, and it covers most of the catalogue.
  3. the site's own apple-touch-icon (180px), then DuckDuckGo, then Google's
     favicon service

Simple Icons outranks the favicon here, unlike the first version: a 32px
.ico upscaled to 128 looks soft next to fifty crisp ones, and consistency
across a long list matters more than a couple of full-colour marks.

    ./scripts/fetch-service-icons.py            # everything
    ./scripts/fetch-service-icons.py --missing  # only what has no icon yet

The output is committed, so a normal build never touches the network.
"""

import json
import os
import re
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "ServiceIcons")
CATALOG = os.path.join(ROOT, "moe-home", "connectors", "hermes-catalog.py")
SIZE = 128
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"

# Mac-native rows. Apple's own apps are deliberately absent — they get SF
# Symbols, which say what the source *is* better than five Apple logos would.
NATIVE = {
    "gmail": "mail.google.com",
    "drive": "drive.google.com",
    "drive-docs": "docs.google.com",
    "chrome": "google.com",
    "telegram": "telegram.org",
    "whatsapp": "whatsapp.com",
}

# name -> domain, where the connector name is not simply <name>.com.
DOMAINS = {
    "atlassian": "atlassian.com", "aws-knowledge": "aws.amazon.com",
    "betterstack": "betterstack.com", "bluebubbles": "bluebubbles.app",
    "comfy-cloud": "comfy.org", "context7": "context7.com",
    "deepwiki": "deepwiki.com", "google_chat": "workspace.google.com",
    "hugging_face": "huggingface.co", "homeassistant": "home-assistant.io",
    "microsoft-learn": "learn.microsoft.com", "monday": "monday.com",
    "motherduck": "motherduck.com", "prisma-postgres": "prisma.io",
    "teams-meeting-pipeline": "teams.microsoft.com", "teams": "teams.microsoft.com",
    "twelve-data": "twelvedata.com", "twilio-docs": "twilio.com",
    "unreal-engine": "unrealengine.com", "wordpress-com": "wordpress.com",
    "whatsapp_cloud": "whatsapp.com", "1password": "1password.com",
    "gif-search": "tenor.com", "siyuan": "b3log.org", "canvas": "instructure.com",
    "sms": "twilio.com", "email": "gmail.com", "webhook": "webhook.site",
    "irc": "libera.chat", "simplex": "simplex.chat", "buzz": "buzz.chat",
    "qqbot": "qq.com", "weixin": "weixin.qq.com", "wecom": "work.weixin.qq.com",
    "yuanbao": "hunyuan.tencent.com", "feishu": "feishu.cn",
    "dingtalk": "dingtalk.com", "photon": "apple.com", "ntfy": "ntfy.sh",
    "kiwi": "kiwi.com", "close": "close.com", "attio": "attio.com",
    "n8n": "n8n.io", "neon": "neon.tech", "railway": "railway.app",
    "square": "squareup.com", "strava": "strava.com", "semgrep": "semgrep.dev",
    "globalping": "globalping.io", "alltrails": "alltrails.com",
    "trivago": "trivago.com", "indeed": "indeed.com", "gamma": "gamma.app",
    "craft": "craft.do", "canva": "canva.com", "miro": "miro.com",
    "klaviyo": "klaviyo.com", "mixpanel": "mixpanel.com", "plaid": "plaid.com",
    "postman": "postman.com", "robinhood": "robinhood.com", "webflow": "webflow.com",
    "wolfram": "wolframalpha.com", "fireflies": "fireflies.ai",
    "cloudinary": "cloudinary.com", "buildkite": "buildkite.com",
    "circleci": "circleci.com", "algolia": "algolia.com", "amplitude": "amplitude.com",
}

# Simple Icons slug, where it differs from the connector name.
SLUGS = {
    "hugging_face": "huggingface", "aws-knowledge": "amazonwebservices",
    "microsoft-learn": "microsoft", "teams-meeting-pipeline": "microsoftteams",
    "teams": "microsoftteams", "google_chat": "googlechat", "gmail": "gmail",
    "drive": "googledrive", "drive-docs": "googledocs", "chrome": "googlechrome",
    "monday": "mondaydotcom", "wordpress-com": "wordpress",
    "whatsapp_cloud": "whatsapp", "1password": "1password", "sms": "twilio",
    "email": "gmail", "unreal-engine": "unrealengine", "twilio-docs": "twilio",
    "twelve-data": "twelvedata", "prisma-postgres": "prisma",
    "betterstack": "betterstack", "homeassistant": "homeassistant",
    "gif-search": "tenor", "canvas": "instructure", "n8n": "n8n",
    "comfy-cloud": "comfyui", "motherduck": "duckdb", "photon": "apple",
    "bluebubbles": "imessage", "irc": "internetcomputer",
}

# Explicit URLs for the products whose domain serves someone else's mark.
OVERRIDE = {
    "chrome": "https://www.google.com/chrome/static/images/favicons/apple-touch-icon.png",
    "gmail": "https://www.gstatic.com/images/branding/product/2x/gmail_2020q4_96dp.png",
    "drive": "https://www.gstatic.com/images/branding/product/2x/drive_2020q4_96dp.png",
    "drive-docs": "https://www.gstatic.com/images/branding/product/2x/docs_2020q4_96dp.png",
}


def catalog_names():
    """Connector names straight out of the Hermes catalogue."""
    try:
        out = subprocess.run([sys.executable, CATALOG], capture_output=True,
                             text=True, timeout=120).stdout
    except Exception as exc:                       # noqa: BLE001
        print(f"! could not read the catalogue ({exc}); using the native list only")
        return []
    names = []
    for line in out.splitlines():
        m = re.match(r"^  ([a-z0-9][a-z0-9_.-]+)\s{2,}", line)
        if m:
            names.append(m.group(1))
    return names


def get(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def width_of(path):
    """`sips` prints "<nil>" rather than failing for a non-image, so this has
    to check for digits before comparing as a number."""
    try:
        out = subprocess.run(["sips", "-g", "pixelWidth", path],
                             capture_output=True, text=True).stdout
    except Exception:                              # noqa: BLE001
        return 0
    m = re.search(r"pixelWidth:\s*(\d+)", out)
    return int(m.group(1)) if m else 0


def save_png(data, dest):
    tmp = dest + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    if width_of(tmp) < 48:
        os.remove(tmp)
        return False
    subprocess.run(["sips", "-s", "format", "png", "-z", str(SIZE), str(SIZE),
                    tmp, "--out", dest], capture_output=True)
    os.remove(tmp)
    return os.path.exists(dest) and os.path.getsize(dest) > 0


def fetch(name):
    """Returns the extension written, or None."""
    base = os.path.join(OUT, name)

    if name in OVERRIDE:
        try:
            if save_png(get(OVERRIDE[name]), base + ".png"):
                return "png"
        except Exception:                          # noqa: BLE001
            pass

    slug = SLUGS.get(name, name.replace("_", "").replace("-", "").replace(".", ""))
    try:
        svg = get(f"https://cdn.simpleicons.org/{slug}", timeout=15)
        if svg.lstrip()[:4] == b"<svg":
            with open(base + ".svg", "wb") as f:
                f.write(svg)
            return "svg"
    except Exception:                              # noqa: BLE001
        pass

    domain = NATIVE.get(name) or DOMAINS.get(name) or f"{name.replace('_', '-')}.com"
    for url in (f"https://{domain}/apple-touch-icon.png",
                f"https://{domain}/apple-touch-icon-precomposed.png",
                f"https://icons.duckduckgo.com/ip3/{domain}.ico",
                f"https://www.google.com/s2/favicons?sz={SIZE}&domain={domain}"):
        try:
            if save_png(get(url), base + ".png"):
                return "png"
        except Exception:                          # noqa: BLE001
            continue
    return None


def main():
    only_missing = "--missing" in sys.argv
    os.makedirs(OUT, exist_ok=True)

    names = sorted(set(list(NATIVE) + catalog_names()))
    print(f"› {len(names)} connectors\n")

    got, missing = 0, []
    for name in names:
        have = [e for e in ("png", "svg", "pdf")
                if os.path.exists(os.path.join(OUT, f"{name}.{e}"))]
        if have and only_missing:
            got += 1
            continue
        ext = fetch(name)
        if ext:
            got += 1
            # One file per connector: a leftover .png beside a new .svg would
            # win the lookup and quietly keep the worse art.
            for other in ("png", "svg"):
                if other != ext:
                    stale = os.path.join(OUT, f"{name}.{other}")
                    if os.path.exists(stale):
                        os.remove(stale)
            print(f"  ✓ {name:<26} {ext}")
        else:
            missing.append(name)
            print(f"  ✗ {name:<26} no icon found")

    print(f"\n› {got} icons in Resources/ServiceIcons, {len(missing)} missing")
    if missing:
        print("› missing: " + " ".join(missing))
    print("› anything missing falls back to a monogram in the service's own "
          "colour — never a broken tile.")


if __name__ == "__main__":
    main()
