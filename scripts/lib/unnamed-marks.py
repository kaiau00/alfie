#!/usr/bin/env python3
"""Marks that ship but nothing in the confirmation dialog can name.

The dialog used to carry an icon column beside its service table: 57
hand-written strings mirroring `ls Resources/ServiceIcons`, policed by a test
that existed only because of the duplication, and wrong in both directions —
five platforms the gate can name had no row at all, and `buzz` had art that
could never be drawn. The column is gone; the mark is looked up by the
service key itself. This is the check that replaces it, and it runs the other
way round: given the marks we ship for things a MESSAGE can go to, is there a
key or an alias that reaches each one?
"""
import os
import re
import sys

# Only the services a message can be addressed to. The rest of the folder
# belongs to the Connections screen, which is a different surface with its
# own fallbacks.
MESSAGING = {
    "slack", "teams", "telegram", "whatsapp", "whatsapp_cloud", "discord",
    "signal", "matrix", "mattermost", "ntfy", "line", "feishu", "irc",
    "photon", "simplex", "yuanbao", "buzz", "google_chat", "sms", "email",
    "gmail", "outlook", "bluebubbles", "x", "linkedin",
}


def main(repo):
    source = open(os.path.join(repo, "Sources/MoeConfirm/ConfirmRequest.swift")).read()
    keys = {k for k, _ in re.findall(r'\("([^"]+)", "([^"]+)"\),', source)}
    aliases = set(re.findall(r'"[^"]+": "([^"]+)"', source))
    shipped = {f.rsplit(".", 1)[0]
               for f in os.listdir(os.path.join(repo, "Resources/ServiceIcons"))}
    print(" ".join(sorted((MESSAGING & shipped) - keys - aliases)))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
