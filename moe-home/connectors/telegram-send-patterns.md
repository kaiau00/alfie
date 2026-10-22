# Telegram sends and the confirm-send hook

How `telegram.py send` is gated, what `hermes/hooks/confirm-send.sh` does with
it, and the one change its owner should consider. Written 2026-08-31, in the
shape of `gmail-send-patterns.md`, which this follows deliberately.

`moe-home/connectors/tests/test_telegram_send.py` covers the parser and the
gate (21 tests, in `scripts/test-learn.sh`). The hook rows below were measured
against the real hook, not assumed.

## Why this verb is different from the rest of the connector

`status`, `pull` and `crawl` read. `send` writes to another person, **as the
user** — the session file is a full delegated login, the same credential
Telegram Desktop holds, and Telethon will send with it as readily as it reads.
There is no narrower scope to ask for: Telegram does not issue one.

So the gate is the feature. Everything below is about it.

## Two gates, not one

**Gate 1 — the connector asks, for every caller.** `telegram.py send` calls
`tools/confirm.sh` itself before it opens a socket, exactly as `gmail.py send`
and `whatsapp.sh send` do. Four properties make this the load-bearing gate:

- It is **not a field in the request**. The model writes the JSON on stdin,
  and text Alfie reads *in your own Telegram chats* can talk a model into
  writing anything — `"confirmed": true` included. An unknown key is an
  error, so a request carrying one is refused rather than honoured.
- The path to `confirm.sh` is derived from `telegram.py`'s own **real** path
  (`realpath`, then `…/connectors/telegram.py` → `…/tools/confirm.sh`), never
  from `$MOE_HOME`. There is no environment variable that moves the gate.
- It **fails closed**: a missing, non-executable, crashing or timed-out
  dialog is a refusal.
- The recipient is **resolved before the dialog is drawn**. Telethon's
  `get_entity` turns `@danw` or a numeric id into "Dan Whitfield (@danw)", and
  an id nobody can check is not something to approve. An entity that will not
  resolve is a refusal, not a send.

**One recipient per call, on purpose.** Not a list, not a loop. Bulk messaging
from a user account is what gets accounts limited or banned (Telethon's FAQ on
established accounts; Telegram's anti-spam since 2023), and a connector that
makes it one call away is a connector that invites it.

**Gate 2 — the hook, as belt-and-braces.** `confirm-send.sh` layer 2 carries
`("Telegram", r"telegram", r"\bsend\b")`, and `~/.moe/connectors/telegram.py
send` contains both words, so the hook raises its own dialog too.

## What the hook does now (measured, 2026-08-31)

| Shape | Today | Recipient shown |
|---|---|---|
| `~/.moe/connectors/telegram.py send` (terminal) | confirm | `(see command)` |
| `telegram.py status` / `pull` / `crawl` | passes (correct) | — |
| `~/.moe/connectors/gmail.py send` (terminal) | passes — self-gated | — |
| Hermes-native `send_message` | confirm | the `to` argument |

The third row is the comparison that matters: the Gmail row was deliberately
narrowed to `r"gmail(?!\.py)"` so Alfie's own connector, which confirms itself
with the resolved recipients, stops raising a **second** dialog. The Telegram
row has not been narrowed, so `telegram.py send` currently raises two:

1. the hook's, first, which can only say `(see command)` — the message and
   its recipient travel on stdin, deliberately, because nothing about a
   private message belongs in `ps`;
2. the connector's, second, with the resolved name and the real text.

## The change (for the hermes/ owner to decide)

**Narrow the Telegram row to `r"telegram(?!\.py)"`**, matching Gmail, so the
informative dialog is the only one. The argument for it is the one already
written into the Gmail row: an uninformative dialog shown first is the one
that teaches people to click Send without reading, which makes the second
dialog worth less too.

It is **not** made here, for two reasons. `hermes/` is owned elsewhere — the
same reason `gmail-send-patterns.md` specified its change rather than making
it. And `hermes/tests/test-confirm-hook.sh` currently *asserts* that
`python3 telegram.py send @bob hello there` raises a dialog with `@bob` read
out of argv; narrowing the row would drop that assertion, and that test is
covering a different, argv-shaped caller than this connector. Whoever narrows
the row should decide what happens to those two cases first.

Until then, two dialogs is the safe failure, not the dangerous one.

## What the hook cannot do here

Layer 2 is a denylist over free-form text and stays bypassable by
construction — `$s send`, `se""nd`, a wrapper script, base64 into bash. That
is why gate 1 is inside the connector, where the command text cannot be
rewritten to avoid it. The one thing that would bypass gate 1 is code that
imports Telethon and uses the session file directly, which is governed by
Hermes's terminal approval policy and Claude Code's deny list, not by
anything in this file.

## Since 2026-09-25: one door, and a ticket held in memory

The model has a shell under the same user, so nothing a connector reads from
a file or from its environment can decide whether it sends. The connector's
tool (whatsapp_send, gmail_send, telegram_send) is the one door: the
moe-connectors plugin, inside Hermes, judges who the send goes to
(tools/recipients.py) just before it starts the connector, and mints a
one-time ticket in its own memory — the recipients, the words, the provenance
for the card, an expiry. The connector is handed only a nonce and the address
of a socket into that process, redeems the ticket there once, and refuses
without one. A connector's send run from a shell or from code is refused by
the send hook outright ("use the gmail_send tool"), readable or not — which
also stops the rest of a compound command riding along. The Alfie app's
offers go by `whatsapp.sh send-offer`, the chat and words on stdin from the
app's memory, accepted only when the connector's parent process is the signed
app.
