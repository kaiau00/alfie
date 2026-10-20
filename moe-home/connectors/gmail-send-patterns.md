# Gmail sends and the confirm-send hook

How `gmail.py send` is gated today, what `hermes/hooks/confirm-send.sh` does
with it, and the one change its owner should make. `hermes/` is owned
elsewhere, so the change is specified here and not made. The fixture
`tests/gmail-send-fixtures.jsonl` runs the real hook against every shape
below; `scripts/test-gmail-send.sh` asserts the `confirm` and `pass` rows and
reports the `gap` row.

This file replaces `google-send-patterns.md`, which described sends through
the Hermes google-workspace skill. That OAuth path is retired (CONNECTORS.md
§Google: the decision); sending is now Moe's own SMTP connector.

## Two gates, not one

**Gate 1 — the connector asks, for every caller.** `gmail.py send` calls
`tools/confirm.sh` itself before it opens a socket, exactly as `whatsapp.sh
send` does. The dialog is drawn by the OS, says which mailbox it is going
out from, and shows every recipient (cc included) and the words; nothing is
sent unless a human clicks Send. Three properties make this the load-bearing
gate:

- It is **not** a field in the request. The model writes the JSON on stdin,
  and text Moe reads in your mail can talk a model into writing anything —
  `"confirmed": true` included. An unknown key is an error, so a request
  carrying one is refused rather than honoured.
- The path to `confirm.sh` is derived from `gmail.py`'s own location
  (`…/connectors/gmail.py` → `…/tools/confirm.sh`), never from an
  environment variable. There is no `MOE_CONFIRM_BIN`-shaped switch to point
  it at `/bin/true`.
- It **fails closed**: a missing, non-executable, crashing or timed-out
  dialog is a refusal, not a pass.

**Gate 2 — the hook, as belt-and-braces.** `confirm-send.sh`'s layer 2
already carries `("Gmail", r"gmail", r"\bsend\b")`, and every way an agent
can reach the connector (`~/.moe/connectors/gmail.py send` through
`terminal`, the same line through `execute_code`) contains both words. So
the new send path landed in a shape the hook gates **without any edit to
`confirm-send.sh`** — verified, not assumed, by the fixture rows below.

## What the hook does now (measured, 2026-08-30)

| Shape | Today | Recipient shown |
|---|---|---|
| `~/.moe/connectors/gmail.py send` (terminal) | confirm | `(see command)` |
| the same with the JSON piped in | confirm | `(see command)` |
| the same from `execute_code` | confirm | `(see command)` |
| `gmail_send_email` (a Hermes-native tool) | confirm | the `to` argument |
| `gmail.py status` / `pull` / `crawl` | passes (correct) | — |
| raw `smtplib` to `smtp.gmail.com` from `execute_code` | **passes silently** | — |

The recipient column is why the section below exists: the message travels on
**stdin**, deliberately (nothing about a private message or its recipients
belongs in `ps`), so there is nothing in the command text for the hook to
show. Its dialog can only say `(see command)`.

## The change (TODO for the hermes/ owner)

**Narrow the Gmail row so it stops matching Moe's own connector**, which
confirms itself with the real recipients:

```python
# was: ("Gmail", r"gmail", r"\bsend\b"),
("Gmail", r"gmail(?!\.py)", r"\bsend\b"),
```

Why: today a single `gmail.py send` raises **two** dialogs — the hook's,
which can only show the shell command, and then the connector's, which shows
the actual recipients and words. `confirm-send.sh`'s own header gives the
reason this is worse than one: *"a dialog there confirms nothing … and being
asked after every call teaches people to click Send without reading, which
is exactly what makes the gate worthless for the sends that matter."* The
first dialog is the uninformative one, and it is the one that trains the
habit. The same header already states the principle — *"Connector `send`
verbs confirm themselves (whatsapp.sh calls confirm.sh with the resolved
contact name, for every caller), so they are deliberately absent"* — and
`gmail.py send` is now one of those verbs.

Nothing is lost by making this change: no send escapes, because gate 1 is
unconditional and inside the connector. And nothing breaks if the owner
prefers to leave the row alone: the user is simply asked twice.

`gmail_send_email` and every other Hermes-native or MCP send tool keeps
being caught by layer 1 on its name — that is untouched by this.

## The gap that stays a gap

`import smtplib; SMTP_SSL('smtp.gmail.com', 465)` from `execute_code` is not
gated by anything here: the connector is not involved, so gate 1 does not
apply, and layer 2 is a denylist over free-form text, which is bypassable by
construction (`confirm-send.sh`'s header says so). It needs an app password
to succeed, which is in the Keychain and which `security` will surrender to
anything running as the user — so this is the same class of exposure as
`sendmail`, already listed there under "Known bypasses".

**What stands between an agent and this bypass today is the terminal
approval policy, and nothing else.** Be exact about that, because the
temptation is to name a control that is not there. Claude Code's deny list
(`~/.moe/.claude/settings.json`, written from `FirstRun.swift`) allows
`Bash` wholesale and denies three commands — `rm -rf`, `sudo`, `git push` —
plus a handful of `mcp__claude_ai_Gmail__*` tools. It holds no rule that
matches `python3 -c "import smtplib…"`, and a denylist over free-form
command text could not hold one that did: `python3 -c` has an unbounded
number of spellings. Recorded here so nobody reads the fixture's `gap` row
as an oversight — or reads this paragraph as a claim that it is covered.

The narrowest thing that would narrow it is layer 2 learning the shape
rather than the word. Today `("Gmail", r"gmail", r"\bsend\b")` misses
`s.send_message(m)`: `\bsend\b` does not match inside `send_message`.
Dropping the trailing `\b` catches that row, and `sendMail` and
`send_email` with it. Like the change above, it is in a file this repo does
not own, so it is written down rather than made.

## What the connector will not do

- No `bcc`. A recipient the human approving the dialog cannot see is not a
  recipient Moe adds. Unknown keys are refused rather than dropped, so a
  request that asks for one gets an error.
- No display names in `to`/`cc`. Bare addresses only: what the dialog shows
  must be exactly what the envelope gets, and `Ada <ada@example.com>` is a
  place to hide a second address.
- No newline in any header value. That is how an extra `Bcc:` gets smuggled
  onto a message a human already approved.
- No control characters and no bidi overrides, in an address or in any of
  the text. A NUL cannot be put on the dialog's argv at all — before this
  was checked, `a\0b@example.com` produced a Python traceback where a
  dialog should have been — and U+202E RIGHT-TO-LEFT OVERRIDE makes macOS
  draw one address on screen while another goes in the envelope. A gate
  whose display can be steered is not a gate.
- Nothing the dialog cannot show whole. Addresses are capped at RFC 5321's
  254 characters, subjects at 300, and a recipient line longer than 900
  characters is refused outright rather than shown in part: a recipient
  below the fold is a recipient the human did not approve. `tools/confirm.sh`
  refuses such a list a second time, on its own.
- The same address twice is one recipient, so "sent to N recipients" is a
  count of people.

**What it cannot promise.** `display dialog` has no scroll bar, and a dialog
taller than the screen is clipped with nothing to say so. A message longer
than about 1,800 characters is therefore shown as far as it fits, with the
number of characters it is *not* showing stated in the dialog and a line
telling the reader to cancel if they have not read them. That is the honest
limit of this dialog, not a comfortable one: the real answer for long mail
is a scrolling review window, and until there is one, a person can approve
an email whose tail they were shown a count of rather than the words.

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
also stops the rest of a compound command riding along. The Memoe app's
offers go by `whatsapp.sh send-offer`, the chat and words on stdin from the
app's memory, accepted only when the connector's parent process is the signed
app.
