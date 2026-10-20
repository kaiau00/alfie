---
name: composio-google-docs
description: "Read before any GOOGLEDOCS_* call through Composio. There are two tools for 'read this document' and they answer different questions: one returns plain text, the other returns the document's whole structural JSON. The preloaded one is the structural one."
version: 1.0.0
author: Moe
license: MIT
metadata:
  hermes:
    tags: [Composio, Google Docs, Documents, MCP]
    toolkit: googledocs
    related_skills: [composio-router, composio-google-drive]
---

# Google Docs through Composio

Read `composio-router` first for the method.

**Byte costs on this page are unverified.** The schema facts below were read
from Composio on 2026-09-04 and are properties of the tools, true for anyone.
Sizes are not, because measuring them needs a connected Google Docs account
and this machine had none. Where a size matters, take it yourself: ask for
one document, look at the result, then decide.

## The two read tools, and why the wrong one is the obvious one

| the question | the tool |
|---|---|
| what does this document **say** | `GOOGLEDOCS_GET_DOCUMENT_PLAINTEXT` |
| where is the heading / what is the structure / who commented | `GOOGLEDOCS_GET_DOCUMENT_BY_ID` |

`GOOGLEDOCS_GET_DOCUMENT_BY_ID` is the one preloaded into the tool list, so
it is the one you will reach for without thinking. It returns the Google Docs
API document resource: a nested JSON tree of structural elements, paragraphs,
text runs and style objects. Every sentence of prose arrives wrapped in
several layers of it.

`GOOGLEDOCS_GET_DOCUMENT_PLAINTEXT` is not preloaded — reach it through
`COMPOSIO_MULTI_EXECUTE_TOOL` — and it returns a best-effort plain-text
rendering of the same document. If the person asked what a document says,
summarise it, or find something in it, this is the tool.

## Its switches, and what they default to

`GOOGLEDOCS_GET_DOCUMENT_PLAINTEXT`:

    include_tables         default TRUE    tables rendered with delimiters
    include_headers        default false
    include_footers        default false
    include_footnotes      default false
    include_tabs_content   default false    main body only
    table_cell_delimiter   default "\t"
    table_row_delimiter    default "\n"

These are content switches, not size switches, and their defaults are
sensible: you get the body and its tables, and none of the running headers.
Turn one on when the person's question is about that part.

`GOOGLEDOCS_GET_DOCUMENT_BY_ID` has exactly one switch,
`includeTabsContent` (default false). With it false the API returns the
legacy first-tab fields; with it true you get every tab. A multi-tab document
read at the default silently gives you only the first tab — which reads as a
short document rather than as an error.

Both accept a document id or a full Docs URL.

## Finding the document

Docs tools need an id. Get it from `GOOGLEDRIVE_FIND_FILE` with a
`mimeType = 'application/vnd.google-apps.document'` filter, or from a URL the
person gave you. Do not download a Doc through Drive — a Google Doc has no
file bytes; export it, or use these tools.
