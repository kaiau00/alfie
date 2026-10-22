---
name: composio-gmail
description: "Read before any GMAIL_* call through Composio. Which of the four read tools answers which question, and the exact arguments that turn a 167 KB answer into a 5 KB one. Gmail's defaults are the expensive ones, `verbose` means three different things inside this one toolkit, and one innocuous call returns a megabyte."
version: 1.0.0
author: Alfie
license: MIT
metadata:
  hermes:
    tags: [Composio, Gmail, Email, MCP, Cost]
    toolkit: gmail
    related_skills: [composio-router]
---

# Gmail through Composio

Read `composio-router` first for the method. This page is what is specific to
Gmail, all of it measured against a real mailbox on 2026-09-04.

## Which tool answers which question

| the question | the tool | notes |
|---|---|---|
| who emailed me / what's in the inbox / find mail about X | `GMAIL_FETCH_EMAILS` | with **both** flags false — see below |
| just the ids, to fetch some of them properly after | `GMAIL_FETCH_EMAILS` + `ids_only: true` | 826 B for five — 165 B/message |
| what does THIS message say | `GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID` | `format` is mandatory in practice |
| what conversations are there | `GMAIL_LIST_THREADS` | leave `verbose` alone — see the trap |
| what have I got half-written | `GMAIL_LIST_DRAFTS` | `verbose` defaults to false here |

You never need the by-id fetch to answer "who emailed me". That is the single
most expensive mistake available in this toolkit.

## GMAIL_FETCH_EMAILS — pass both flags, every time

Two independent levers, each ~3.5–4.5x, **both defaulting to the expensive
setting**. Same five messages, called directly:

    (defaults)                                167,231 B    33,446 B/msg
    include_payload: false                     49,071 B     9,814 B/msg
    verbose: false                             37,064 B     7,412 B/msg
    verbose: false, include_payload: false      4,979 B       995 B/msg

Neither flag alone gets you metadata. **Both together do**, and what survives
is ids, labels, timestamps, subject, sender, recipients and a preview
snippet — which is the answer to almost every question anyone asks about
their inbox.

Also: **`max_results` defaults to 1.** Its own description says so and says it
is useless. Set it.

    {"query": "in:inbox newer_than:2d", "max_results": 20,
     "verbose": false, "include_payload": false}

**The path matters on this tool.** Through `COMPOSIO_MULTI_EXECUTE_TOOL` the
MIME payload is absent whatever you pass, so `include_payload` is inert there
(49,218 B with and without — byte-identical) and `verbose: false` is the only
lever (5,126 B). Passing both is correct on either path; passing only
`include_payload: false` saves nothing through the multiplexer.

`query` is ordinary Gmail search syntax (`from:`, `is:unread`,
`newer_than:2d`, `has:attachment`). Spam and trash are excluded unless you
ask for them. Results are **not sorted by recency** — sort on `internalDate`
yourself, and use `internalDate` rather than the `Date` header.

## GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID — always pass `format`

    format omitted → 'full'    54,837 B
    format: "metadata"          6,174 B     8.9x
    format: "minimal"             255 B

Its own description calls `metadata` *"recommended for most use cases"* and
then defaults to `full` anyway. `full` is a complete MIME structure — 50+
headers, nested parts, base64url bodies — and you want it only when you are
actually parsing attachments or the raw body.

This tool is **path-insensitive**: direct and multiplexed differ by a
constant 162-byte envelope. Whatever you learn here holds on both paths.

## The trap: GMAIL_LIST_THREADS with verbose

`verbose` here defaults to **false**, which is the cheap one — the opposite
of `GMAIL_FETCH_EMAILS`, in the same toolkit, under the same name. Leave it
alone. Measured, five threads:

    default (verbose false)          1,202 B        240 B/thread
    verbose: true                1,059,050 B    211,810 B/thread

Nothing else caps it. `max_results` defaults to 10, so a verbose list you
forgot to cap is roughly two megabytes. If you need message bodies from a
thread, list the thread cheaply and fetch the one message you want by id.

## The name `verbose` is not a convention

Inside Gmail alone:

- `GMAIL_FETCH_EMAILS.verbose` — default **true**, description talks about
  speed and content, never size, and it is a 4.5x size lever.
- `GMAIL_LIST_THREADS.verbose` — default **false**, and turning it on is an
  881x size lever.
- `GMAIL_LIST_DRAFTS.verbose` — default **false**, and it is what gets you
  subject and recipient at all.

There is nothing to carry from one to the next. Check the tool you are
calling.

## Sending

Send tools are outside this skill's scope and Alfie's send gate may stop and
ask before anything leaves. Two things worth knowing anyway: a reply needs
the Gmail **thread id**, not a message id, and it must NOT carry a `subject`
— a custom subject starts a new conversation. Never tell the person a message
was sent because the tool returned success; confirm by re-reading the thread.

## Never write mail content anywhere it does not belong

Subjects, senders, addresses and bodies belong in the answer to the person
who asked, and nowhere else — not in a note, a log, a filename or a summary
handed to another agent.
