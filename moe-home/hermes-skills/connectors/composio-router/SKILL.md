---
name: composio-router
description: "Read FIRST before any Composio tool call — Gmail, Calendar, Drive, Slack, Notion, GitHub, any of the ~500 toolkits. How to pick the tool, how to call it without dumping a megabyte into the turn, and the four things Composio's own schemas will not tell you. Also: how to check whether a service is connected WITHOUT triggering a connection request."
version: 1.0.0
author: Alfie
license: MIT
metadata:
  hermes:
    tags: [Composio, MCP, Connectors, Google, Gmail, Cost]
    toolkit: "*"
    related_skills: [composio-gmail, composio-google-calendar, composio-google-drive, composio-google-docs, composio-google-sheets, composio-google-tasks, composio-google-meet]
---

# Composio, and how to call it without paying for it twice

Composio is one MCP session standing in front of ~500 toolkits. Its tools are
authored **one at a time, by different hands**, so there is no convention to
learn: two parameters with the same name in the same toolkit mean different
things, defaults are as often the expensive setting as the cheap one, and a
few advertised parameters do nothing at all.

This skill is the shape. It is true of toolkits nobody has written a skill
for. Read it before the first call, not after the result comes back too big.

## Why size is the whole game

An oversized tool result is **not delivered to you**. The client writes it to
a file and hands you a path — so answering "who emailed me" turns into
grepping a file for an answer a cheaper call would have put straight in front
of you. The cost is not the bytes; it is that the answer stops being in the
conversation. A result of a few megabytes from one Gmail call is ordinary.

So the discipline is not "be tidy". It is: **the cheap call is the one that
answers the question, and the expensive call is the one that does not.**

## The four questions, before any Composio call

Composio's schemas answer none of these. Only a measurement does.

**1. What does this parameter default to?**
Assume the expensive setting until you have checked. Measured on Gmail:
`verbose` and `include_payload` both default to the costly value, and the two
are independent — same five messages, `GMAIL_FETCH_EMAILS` called directly:

    both defaults            167,231 B
    include_payload: false    49,071 B     3.4x
    verbose: false            37,064 B     4.5x
    both false                 4,979 B    34x   (995 B/message)

Nothing in either description mentions bytes or tokens. `verbose` describes
*speed* ("~75% improvement") and then *content*; a model optimising for size
gets no signal from it at all.

**2. Does a parameter that talks about speed actually control size?**
Yes, on `GMAIL_FETCH_EMAILS`. The name is not the guide and neither is the
description's subject — the only guide is the byte count.

**3. Is the parameter honoured at all?**
`GOOGLECALENDAR_EVENTS_LIST_ALL_CALENDARS.max_results_per_calendar` is
documented as "maximum events returned per calendar" and is **inert** — 1, 2
and omitted are byte-identical, verified again 2026-09-04. A cap you believe
in and that does nothing is worse than no cap, because you stop looking.

**4. Does the invocation path change the answer?**
Sometimes, and it is per-tool. Same query, same five messages, same day:

    GMAIL_FETCH_EMAILS   direct 167,231 B   |   via MULTI_EXECUTE  49,218 B
        and through the multiplexer `include_payload` is INERT
        (49,218 B with and without, byte-identical) — `verbose` is the
        only lever there (5,126 B).

    GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID   direct 54,837 B | muxed 54,999 B
        identical but for a 162-byte envelope. Path-insensitive.

So "the path changes the answer" is a **property of the tool**, not of
Composio. Do not carry a lever from one tool to the next; check it on the
tool you are about to call.

## A wrong value costs more than no value

`GOOGLEDRIVE_FIND_FILE.fields` takes a Google field selector. Measured:

    omitted                    1,041 B     (the documented light default)
    fields: "files(id,name)"     555 B     a real selector — cheapest
    fields: "basic"            4,008 B     not a selector
    fields: "*"                4,006 B     everything

An unrecognised selector does not error. It falls back to **everything** —
four times the cost of omitting the parameter you were trying to economise
with. A well-formed value that resolves to nothing is more dangerous than an
absent one, because absence is honest.

## Some inputs are outputs

`GOOGLEDRIVE_FIND_FILE` advertises 22 input properties and **nine of them are
things the tool tells you about what it did to your request** — six booleans
described "Indicates whether …" (`pagetoken_dropped`,
`email_query_transformed`, `editors_field_removed`, …) and three
`original_*` strings. `GOOGLESHEETS_BATCH_GET` has `empty_strings_filtered`.
They are harmless to pass and they are not free: they are 40% of that tool's
11.9 KB schema, and they invite you to set a flag that means nothing.

## Pick the TOOL first. No parameter fixes the wrong one.

To answer "who emailed me today" you never need the by-id fetch. A list tool
answers it; the by-id fetch answers "what does this one message say", and
costs 55 KB at its default to do it. Every toolkit has this split, and the
names do not always make it obvious — `GOOGLEDOCS_GET_DOCUMENT_PLAINTEXT`
exists beside `GOOGLEDOCS_GET_DOCUMENT_BY_ID` and answers a different
question far more cheaply.

**Ask for one before you ask for a hundred.** One item, look at the size,
then scale. That is the whole method, and it is the only one that survives a
toolkit nobody has written down.

## Calling: the three paths

1. **Preloaded tools** are in your tool list already — a handful of reads
   for the connected toolkits, plus the five `COMPOSIO_*` meta tools. (One
   real session, measured: 13 tools, of which 8 were Google reads, and
   `tools/list` cost 52,608 B to deliver them — paid on every child spawn.)
   Call these by name.
2. **Anything else** — found by search — is not individually callable. Run it
   through `COMPOSIO_MULTI_EXECUTE_TOOL` with
   `{"tools": [{"tool_slug": "…", "arguments": {…}}]}`. Remember question 4.
3. **Discovery** is `COMPOSIO_SEARCH_TOOLS` with
   `{"queries": [{"use_case": "<plain English>"}], "session": {"generate_id": true}}`,
   then `COMPOSIO_GET_TOOL_SCHEMAS` with `tool_slugs: [...]` for the exact
   parameters. Do not guess slugs.

**Discovery is not free.** Measured 2026-09-04: one `COMPOSIO_SEARCH_TOOLS`
query costs 7–27 KB depending on the toolkit; `COMPOSIO_GET_TOOL_SCHEMAS`
costs 18–36 KB for twelve slugs. The search tool's own schema encourages you
to *split* work into more queries — each split is another 7–27 KB. Ask one
good question.

## Connection status — the one meta tool with a side effect

**`COMPOSIO_MANAGE_CONNECTIONS` is not a status check. It MINTS a connection
request for anything unconnected**, so using it to find out whether Gmail is
connected creates the state you were asking about.

Calling a tool for an unconnected toolkit returns a ~420–460 byte refusal
that names the toolkit and tells you to call `COMPOSIO_MANAGE_CONNECTIONS`.
**Do not follow that instruction on your own initiative.** Tell the person
the service is not connected and let them ask for it.

The pure read is `COMPOSIO_SEARCH_TOOLS`, whose result carries
`toolkit_connection_statuses` — per toolkit, `has_active_connection` and,
where connected, the account it is on.

**Schemas are readable for toolkits that are not connected.** A search
against an unconnected toolkit returns real slugs and real parameter
definitions. So you can always find out what a call *would* take; what you
cannot know without a connection is what it would *cost*.

## Never write an identifier down

Composio's `user_id` is a capability, not a name: anything holding it can act
as that person. It must never appear in a message, a note, a commit, a file
you write, or a summary you hand back. Fold it — `abcd…yz` — if you have to
refer to it at all.

## The per-toolkit skills

`composio-gmail`, `composio-google-calendar`, `composio-google-drive`,
`composio-google-docs`, `composio-google-sheets`, `composio-google-tasks`,
`composio-google-meet`.

Each exists because that toolkit **contradicts something above** — an
expensive default, an inert parameter, or a tool choice the names hide.
Google Photos and Google Slides have no skill on purpose: everything true of
them is already on this page (Photos' page sizes default to a sensible 20–25;
Slides' `fields` is one more instance of the selector rule). An empty skill
that exists is worse than an absent one, because opening it costs a call.

For any of the other ~490 toolkits, this page IS the skill. Ask the four
questions.
