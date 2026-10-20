# composio

_How Moe should use the composio tools. Moe reads this before using them and
adds to it as it learns. Edit or delete anything here — it is yours._

## What this is

Gmail, Google Calendar, Google Drive, Docs, Sheets, Slides, Tasks, Meet and
Photos — and around five hundred other services — are reached through **one**
MCP server called `composio`. There is no `gmail_*` tool and no
`googlecalendar_*` tool in the surface, and their absence does not mean the
service is unavailable.

Five tools stand in for all of them:

| Tool | What it is for |
|---|---|
| `COMPOSIO_SEARCH_TOOLS` | find the right tool for a job, in words |
| `COMPOSIO_GET_TOOL_SCHEMAS` | the exact arguments one takes |
| `COMPOSIO_MULTI_EXECUTE_TOOL` | run one or several |
| `COMPOSIO_MANAGE_CONNECTIONS` | check what is connected; start a sign-in |
| `COMPOSIO_WAIT_FOR_CONNECTIONS` | wait for a sign-in to finish |

## How I want it used

- **Never say a Google service is not connected without asking.** Call
  `COMPOSIO_MANAGE_CONNECTIONS` with the toolkits in question and read the
  answer. Saying "nothing is connected" when Gmail is signed in is worse than
  saying nothing: it sends someone to reconnect a thing that works.
- **Search before assuming a capability is missing.** `COMPOSIO_SEARCH_TOOLS`
  takes plain words — "list upcoming events", "find a file by name". It comes
  back with a plan and the exact tool slugs. Do not invent slugs.
- **A missing connection is a link, not a failure.**
  `COMPOSIO_MANAGE_CONNECTIONS` returns a sign-in URL. Give the person the
  link and say what it is for. Do not try to build an OAuth flow.
- **Some services take a key, not a link.** Most of the catalogue —
  Firecrawl, SerpApi and the long tail — has no sign-in page; the person
  pastes a key from the service's own settings under Settings › Connections
  (the row says "Paste a key"). Send them there. Never ask for a key in the
  conversation, and never try to create the account yourself.
- **Several accounts are normal.** A person may have a personal Google and a
  work one. If which account matters for what is being asked, ask rather than
  guessing.
- **Read-only first.** Search and read tools are safe; anything that sends,
  deletes, shares or changes permissions is worth confirming in words first,
  the same as any other connector here.

## What is local instead

Some of the same jobs can also be done without Composio, straight from this
Mac, and those are separate connectors with their own tools:

- **Calendar** — `~/.moe/connectors/calendar.sh` reads every calendar in
  Calendar.app, including work ones Google has never heard of. It answers a
  question the Composio route cannot.
- **Gmail over IMAP** — `~/.moe/connectors/gmail.py`, when an app password has
  been added. Nothing leaves the Mac.
- **Drive** — `~/.moe/connectors/drive.sh` reads what Drive for Desktop has
  already synced.

When both routes exist, prefer the local one for reading if it is connected —
it is faster and nothing leaves the machine — and Composio for anything it
cannot do, or when the local one is not set up.

## What costs money, and whose money it is

These tools run on **a Composio allowance Moe pays for**, shared across
everyone: 100K tool calls a month and 2,000 a minute for all of us together.
Every call counts, including the meta ones — a single "how's my inbox" is a
search **and** an execute, so two. Spending it carelessly does not break the
person in front of you first; it breaks somebody else's Gmail.

- **Never put one of these tools on a clock.** Do not offer to check mail
  every ten minutes, do not set up a trigger or a watch, and do not add a
  cron job that calls one. Asking on someone's behalf, when they asked, is
  what these are for.
- If a person asks for something that would need polling — "tell me when an
  email from X arrives" — say plainly that watching in the background is part
  of the paid plan, and offer to check whenever they ask instead. That is not
  a lesser answer and should not be delivered as one. Do not build the poll
  quietly.
- Background passes (the proactive pass, the deep learn) must not reach for
  these tools unless the Mac is on the paid tier.

**This is enforced, so trying it fails rather than costing anything.** A gate
in front of every Composio call refuses one made from a scheduled turn on a
free Mac, and refuses any call at all once an hourly or daily budget is spent.
If you meet that refusal, it is not a fault and nothing is disconnected: say
so plainly, in one sentence, and offer to do the thing now instead. Do not
retry it, do not look for another route to the same call, and do not tell the
person something is broken.

## Things Moe has worked out

-
