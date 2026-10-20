---
name: composio-google-meet
description: "Read before any GOOGLEMEET_* call through Composio. You cannot ask for a meeting's transcript or recording directly — there is a three-step chain through the conference record, and skipping a step is why the obvious call fails. Also: an empty transcript list often means 'not ready yet', not 'none'."
version: 1.0.0
author: Moe
license: MIT
metadata:
  hermes:
    tags: [Composio, Google Meet, Transcripts, Recordings, MCP]
    toolkit: googlemeet
    related_skills: [composio-router]
---

# Google Meet through Composio

Read `composio-router` first for the method.

**Byte costs on this page are unverified.** The schema facts were read from
Composio on 2026-09-04 and hold for anyone; sizes need a connected Google
Meet account, and this machine had none. Transcript entries are the one thing
here that can grow without bound — a long meeting is a lot of segments — so
page them rather than asking for all of them.

**Moe narrates nothing while this toolkit runs.** `googlemeet` is not one of
the toolkits `SpokenStep.place()` has words for, so a spoken turn goes quiet
for the whole chain below — and this chain is three or four calls long. Say
what you are doing yourself.

## The chain — there is no shortcut to a transcript

A *space* is the meeting room; a *conference record* is one occasion that
room was used. Everything you actually want hangs off the record, not the
room, and there is no tool that takes "yesterday's standup" and returns its
transcript.

    1. GOOGLEMEET_LIST_CONFERENCE_RECORDS        → conferenceRecords/{id}
    2a. GOOGLEMEET_GET_TRANSCRIPTS_BY_CONFERENCE_RECORD_ID  → transcript ids
    2b. GOOGLEMEET_LIST_RECORDINGS  (parent: "conferenceRecords/{id}")
    3. GOOGLEMEET_LIST_TRANSCRIPT_ENTRIES  (conference_record_id + transcript_id)
       → the actual speaker / timestamp / text segments

Step 3 is the only one that returns words anybody said. Steps 1 and 2 return
identifiers. `GOOGLEMEET_GET_CONFERENCE_RECORD_BY_NAME` fetches one record
when you already have its name; `GOOGLEMEET_GET_MEET` describes a *space*,
which is the room and not the meeting.

Note the shape of `LIST_RECORDINGS.parent`: the full resource name
`conferenceRecords/{id}`, not the bare id. `LIST_TRANSCRIPT_ENTRIES` wants
the bare `conference_record_id` **and** the `transcript_id`. Two tools in one
chain, two different conventions.

## An empty result is often "not yet"

`GET_TRANSCRIPTS_BY_CONFERENCE_RECORD_ID` says it plainly: transcripts need
processing time after a meeting ends, and an empty list may be transient.
It may also mean transcription was never switched on, or the organiser's
domain forbids it. **Do not report "there is no transcript" from one empty
call on a meeting that just finished** — say it is not available yet, and
offer to look again.

Recordings have the same property, and they land in Google Drive as MP4 —
so a recording that exists in Meet is also findable through
`composio-google-drive`.

`GOOGLEMEET_GET_MEET` warns that a newly created space returns incomplete
data; retry after a second or two rather than reporting a broken meeting.

## Page sizes

Every list tool here takes `page_size` with **no default set by Composio**,
so the API's own default applies: 25 for conference records, 10 for
recordings, 10 for transcripts, 10 for transcript entries. All are capped at
100, and values above 100 are coerced rather than refused.

Ten transcript entries is a few sentences of a meeting. Expect to page
through `page_token` for anything real — and when paginating, every other
argument must match the call that produced the token.

## Transcript entries are people talking

They carry names and what was said. They belong in the answer to the person
who asked and nowhere else — not a note, not a filename, not a hand-off.
