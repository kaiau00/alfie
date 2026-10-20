---
name: composio-google-calendar
description: "Read before any GOOGLECALENDAR_* call through Composio. Which of the five read tools answers which question, why the all-calendars view is the cheap one and its own event cap is inert, and the tool to call FIRST when the person said 'tomorrow' or 'next Monday'."
version: 1.0.0
author: Moe
license: MIT
metadata:
  hermes:
    tags: [Composio, Calendar, Google, MCP, Scheduling]
    toolkit: googlecalendar
    related_skills: [composio-router]
---

# Google Calendar through Composio

Read `composio-router` first for the method. Measured 2026-09-04 against a
real calendar.

## Call this one first when the question is relative

`GOOGLECALENDAR_GET_CURRENT_DATE_TIME` (takes an optional `timezone`).
"Tomorrow", "next Monday", "this afternoon" are all off-by-one-day bugs
waiting to happen across timezones, and this is one small call.

## Which tool answers which question

| the question | the tool |
|---|---|
| what's on today / this week, everything | `GOOGLECALENDAR_EVENTS_LIST_ALL_CALENDARS` |
| which calendars does this person have | `GOOGLECALENDAR_LIST_CALENDARS` |
| find the meeting about X | `GOOGLECALENDAR_FIND_EVENT` |
| the full detail of one event | `GOOGLECALENDAR_EVENTS_GET` |
| when does this recurring thing actually happen | `GOOGLECALENDAR_EVENTS_INSTANCES` |

`EVENTS_LIST_ALL_CALENDARS` is the one to reach for by default: it needs
`time_min` and `time_max` and it spans every calendar, so it answers "what's
on" without first asking which calendars exist.

## Calendar is the toolkit that gets defaults right — and one wrong

`response_detail` defaults to `'minimal'`, **the cheap one**, and it works:

    response_detail omitted (minimal)     4,563 B
    response_detail: "full"              24,607 B     5.4x

`minimal` gives a compact summary view without the events array. Ask for
`full` only when you need per-event fields, and say why to yourself first.

**`max_results_per_calendar` is inert.** Documented as "maximum number of
events returned per calendar", verified byte-identical at 1, at 2 and
omitted — 24,607 B every time, on the same window. It is not a cap. If a
range is too big, narrow `time_min`/`time_max`; that is the only thing that
actually reduces the answer here.

Same toolkit, different tools, `max_results` **is** honoured:

    GOOGLECALENDAR_LIST_CALENDARS   omitted 1,624 B   max_results: 1   981 B

which is the cleanest available proof that these are per-tool facts and not
platform behaviour. `GOOGLECALENDAR_FIND_EVENT.max_results` defaults to 10.

## Two things that fail quietly

- **An inverted or wrong time range returns an empty list, not an error.** An
  empty `items` is "no events matched these filters", never "this person has
  nothing on". Check the range before you say the day is clear.
- `display_url` duplicates `htmlLink` byte for byte in every row. Read either;
  do not treat them as two facts.

## Time ranges

`time_min` / `time_max` are RFC3339 with a zone (`2026-09-05T00:00:00Z`).
Use a bounded window sized to the question — a day for "what's on today", a
week for "this week". Nothing downstream will trim it for you.
