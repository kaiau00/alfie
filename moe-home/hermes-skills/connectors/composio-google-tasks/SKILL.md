---
name: composio-google-tasks
description: "Read before any GOOGLETASKS_* call through Composio. The default task list is the literal string '@default' and nothing else works; there is no full-text search so filtering is yours to do; and the tool that reads every list at once has a built-in cap of a thousand tasks, which is a cap in name only."
version: 1.0.0
author: Alfie
license: MIT
metadata:
  hermes:
    tags: [Composio, Google Tasks, Todo, MCP]
    toolkit: googletasks
    related_skills: [composio-router]
---

# Google Tasks through Composio

Read `composio-router` first for the method.

**Byte costs on this page are unverified.** The schema facts were read from
Composio on 2026-09-04 and hold for anyone; sizes need a connected Google
Tasks account, and this machine had none.

**Alfie narrates nothing while this toolkit runs.** `googletasks` is not one of
the toolkits `SpokenStep.place()` has words for, so a spoken turn goes quiet
for the whole call. Keep the work short, or say what you are doing yourself.

## Which tool answers which question

| the question | the tool |
|---|---|
| what lists are there | `GOOGLETASKS_LIST_TASK_LISTS` |
| what's on my list | `GOOGLETASKS_LIST_TASKS` (needs a `tasklistId`) |
| what have I got to do, anywhere | `GOOGLETASKS_LIST_ALL_TASKS` |
| this one list's details | `GOOGLETASKS_GET_TASK_LIST` |

## `@default`, and nothing else

`GOOGLETASKS_LIST_TASKS.tasklistId` for the person's primary list is the
literal string **`'@default'`**. Its own description says `'primary'`,
`'default'` and every other variation are rejected. If you have a real list
id from `LIST_TASK_LISTS`, use that; otherwise use `@default` exactly.

Multiple lists can share a name. Confirm by id, not by title.

## The cap that is not a cap

`GOOGLETASKS_LIST_ALL_TASKS.max_tasks_total` defaults to **1000**, described
as a "hard limit … to prevent large payloads". A thousand tasks is not a
small payload; it is a ceiling set where nobody will hit it. Set it to what
you actually need — twenty, fifty — and page if there is more.

`GOOGLETASKS_LIST_TASK_LISTS.maxResults` defaults to 20 and is **silently
truncated to 100** above that, so asking for 500 gets you 100 and no error.
`GOOGLETASKS_LIST_TASKS.maxResults` has the same 100 ceiling with an API
default of 20.

## Two things that will surprise you

- **There is no full-text search.** Neither list tool takes a query. Filtering
  by title or notes is yours to do after the fact, which means fetching more
  than you want and narrowing locally — so bound the fetch by date instead
  (`dueMin`/`dueMax`, `updatedMin`) wherever the question allows it.
- **Results are ordered by position, not by date.** "The next thing due" is
  not the first row. Sort before you answer.
- The response key is `tasks`, not `items` — unlike `LIST_TASK_LISTS`, which
  does use `items`.

## The date filters

`dueMin`/`dueMax`, `completedMin`/`completedMax`, `updatedMin` all take
RFC3339 (`2026-09-05T00:00:00Z`); Composio converts several human formats for
you. One coupling to remember: **`showCompleted` must be true if you pass
`completedMin` or `completedMax`**, or the filter matches nothing.
`showCompleted` defaults to true, `showDeleted` and `showHidden` to false.
