---
name: composio-google-drive
description: "Read before any GOOGLEDRIVE_* call through Composio. Finding a file versus reading one, why a `fields` value Drive does not recognise costs FOUR TIMES more than omitting it, and the nine of GOOGLEDRIVE_FIND_FILE's twenty-two 'inputs' that are not inputs at all."
version: 1.0.0
author: Moe
license: MIT
metadata:
  hermes:
    tags: [Composio, Drive, Google, Files, MCP]
    toolkit: googledrive
    related_skills: [composio-router, composio-google-docs, composio-google-sheets]
---

# Google Drive through Composio

Read `composio-router` first for the method. Measured 2026-09-04 against a
real Drive.

## Which tool answers which question

| the question | the tool |
|---|---|
| find a file by name, type, date, folder | `GOOGLEDRIVE_FIND_FILE` |
| everything in this folder / a plain listing | `GOOGLEDRIVE_LIST_FILES` |
| one file's metadata, given its id | `GOOGLEDRIVE_GET_FILE_METADATA` |
| how much space is left / whose Drive is this | `GOOGLEDRIVE_GET_ABOUT` |
| the file's actual contents | `GOOGLEDRIVE_DOWNLOAD_FILE`, or `GOOGLEDRIVE_EXPORT_GOOGLE_WORKSPACE_FILE` for a Doc/Sheet/Slide |

A Google Doc, Sheet or Slide has **no bytes to download** — it is not a file
in that sense. Reading one means exporting it, or better, using the toolkit
that owns it: `composio-google-docs`, `composio-google-sheets`.

## `fields`: the wrong value costs four times the right one

This is the finding worth carrying off this page.

    fields omitted                 1,041 B    the documented "discovery" default
    fields: "files(id,name)"         555 B    a real Google field selector
    fields: "basic"                4,008 B    NOT a selector
    fields: "*"                    4,006 B    everything

`fields` takes Google's field-mask syntax. A value that is not one —
`"basic"`, `"full"`, a word you assumed was an enum — **does not error**. It
falls back to returning everything, which costs four times what you would
have paid by leaving the parameter out. Pass a real selector or pass nothing;
never pass a guess.

`GOOGLEDRIVE_GET_ABOUT` is the same lever, larger:

    fields omitted (documented default '*')   14,341 B
    fields: "user"                                544 B     26x
    fields: "storageQuota"                        398 B

Here the default really is `'*'`, on purpose. Always name the field you want.

## Nine of twenty-two "inputs" are outputs

`GOOGLEDRIVE_FIND_FILE` advertises 22 input properties. Nine of them are
notes the tool writes about what it did to *your* request:

    pagetoken_dropped              editors_field_removed
    email_query_transformed        emailaddress_field_removed
    bare_text_query_transformed    orderby_size_transformed
    original_email_query           original_bare_text_query
    original_invalid_pagetoken

Setting them means nothing. They are 40% of that tool's 11.9 KB schema. The
parameters that actually do something are `q`, `folder_id`, `fields`,
`orderBy`, `pageSize` (default 100) and `pageToken`.

`GOOGLESHEETS_BATCH_GET` carries the same shape in `empty_strings_filtered`,
so expect it elsewhere: a boolean whose description begins "Indicates
whether" is a result, not a request.

## Searching

`q` takes both bare text (auto-converted to a full-text search) and Drive
query syntax:

    q: "name contains 'invoice'"
    q: "mimeType = 'application/pdf'"
    q: "modifiedTime > '2026-09-01T00:00:00'"

`orderBy` cannot be combined with a full-text term in `q`. `corpora` defaults
to `allDrives`, so shared drives are already included.

## Do not read a person's files to measure them

Sizes, counts and key names are fair to record. File names and contents are
not — not in a note, a log, a filename or a hand-off to another agent.
