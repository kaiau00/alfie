---
name: composio-google-sheets
description: "Read before any GOOGLESHEETS_* call through Composio. Omitting `ranges` on BATCH_GET does not mean 'a sample' — it reads the whole first sheet. Which of the four read tools answers which question, what the render options actually change, and the input that is really an output."
version: 1.0.0
author: Alfie
license: MIT
metadata:
  hermes:
    tags: [Composio, Google Sheets, Spreadsheets, MCP]
    toolkit: googlesheets
    related_skills: [composio-router, composio-google-drive]
---

# Google Sheets through Composio

Read `composio-router` first for the method.

**Byte costs on this page are unverified.** The schema facts were read from
Composio on 2026-09-04 and hold for anyone; sizes need a connected Sheets
account, and this machine had none. A spreadsheet's size is the person's, not
the tool's, so measure before you read a big one: get the sheet names first,
then one bounded range.

## Which tool answers which question

| the question | the tool |
|---|---|
| what sheets are in this workbook | `GOOGLESHEETS_GET_SHEET_NAMES` |
| the workbook's properties, not its data | `GOOGLESHEETS_GET_SPREADSHEET_INFO` |
| the values in these cells | `GOOGLESHEETS_VALUES_GET` (one range) |
| the values in several ranges at once | `GOOGLESHEETS_BATCH_GET` |
| find a spreadsheet by name | `GOOGLESHEETS_SEARCH_SPREADSHEETS` |

**Start with `GOOGLESHEETS_GET_SHEET_NAMES`.** It is the cheapest call in the
toolkit and it stops you guessing a tab name into an error, or into the wrong
tab's data.

## The unbounded read

`GOOGLESHEETS_BATCH_GET.ranges` is optional, and its description says what
happens when you leave it out: *"If this list is omitted, empty, or contains
only empty strings, all data from the first sheet of the spreadsheet will be
fetched."*

That is not a sample and not an error — it is the entire first sheet,
however many rows the person has. Always pass a range in A1 notation
(`'Sheet1'!A1:F50`). If you do not know how far the data goes, read a bounded
block first and page down from there.

`GOOGLESHEETS_VALUES_GET` **requires** a `range`, which is why it is the
safer tool when you only want one. It also takes `start_row` / `end_row`
(1-based, inclusive) to page within a range — `start_row: 1, end_row: 500`,
then `501`–`1000` — which is the right way to walk a long sheet.

Wrap a sheet name containing spaces in single quotes: `"'My Sheet'!A1:B2"`.
Without them the API reads it as something else.

## `include_grid_data`, and the field mask that overrides it

`GOOGLESHEETS_GET_SPREADSHEET_INFO` is about the workbook — titles, sheet
ids, properties. `include_grid_data: true` makes it return the cells as
well, which turns a metadata call into a full data dump. Leave it off unless
you specifically want the grid.

Its `fields` parameter is a Google field mask, and note the ordering rule in
its own description: **a field mask makes `include_grid_data` ignored.** Set
one or the other, not both, or you will not get what you asked for.

## The render options — and the same option spelled two ways

The two value-reading tools take the same three options under **different
names**, and a name from the wrong one is silently ignored:

    GOOGLESHEETS_BATCH_GET     valueRenderOption  dateTimeRenderOption  majorDimension
    GOOGLESHEETS_VALUES_GET    value_render_option  date_time_render_option  major_dimension

Check which tool you are calling before you copy an argument across.

- **value render** — default `FORMATTED_VALUE` (what a person sees, as a
  string). `UNFORMATTED_VALUE` gives numbers you can compute with;
  `FORMULA` gives the formula rather than the result. If you are going to do
  arithmetic, ask for `UNFORMATTED_VALUE` — parsing `"$1,234.00"` back into
  a number is a bug waiting to happen.
- **date-time render** — default `SERIAL_NUMBER`, i.e. dates arrive as
  spreadsheet serial numbers, **not** as dates. `FORMATTED_STRING` if you
  want to read them.
- **major dimension** — `ROWS` or `COLUMNS`, which decides the shape of the
  array you get back.

## One "input" is an output

`GOOGLESHEETS_BATCH_GET.empty_strings_filtered` is described "Indicates
whether empty strings were filtered from the response" — a note the tool
writes, not a request you make. Six properties, one of them not a parameter.
See `composio-router`; this shape recurs across Composio.
