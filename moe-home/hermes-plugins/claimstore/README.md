# claimstore

A Hermes memory provider that moves the *store* out of `MEMORY.md` and into
Alfie's ledger. The two markdown files stay exactly where they are and keep
working — they become the slice of the ledger that fits in the prompt.

## Why

Hermes's built-in memory is two markdown files with no per-entry metadata: no
ids, no timestamps, no author. That is fine for one writer. It stops being fine
the moment a second one exists — another device, a sync daemon, a background
job, or the user in an editor — because there is nothing to merge *on*.

Alfie already has a store with all three, and it is already the place
conversations live: `~/.moe/ledger/*.jsonl`, one append-only JSONL file per
device, ordered causally rather than by anybody's clock
(`docs/ONE-AGENT.md` §1.5). This plugin puts memory in it.

| | built-in | with claimstore |
|---|---|---|
| store | `MEMORY.md`, `USER.md` | `~/.moe/ledger/*.jsonl` |
| entry identity | none | `sha256(target + "\n" + normalised text)[:12]` |
| deletion | rewrite the file | append a `retract` record |
| second writer | trips the drift guard, or silently loses | reconciled at every session boundary |
| conflicting readings | last writer to open the file | §3.1: newer wins within a source, escalated across sources |
| `MEMORY.md` | the store | a digest, rebuilt from the ledger |
| other devices | none | the app pushes the claims as its own; a machine running `moe-ledger` reads and writes the same claims (LEDGER-WIRE §13) |

## Install

Alfie's installer does it: `scripts/install.sh` copies this directory to
`~/.moe/hermes-plugins/claimstore/`, and `~/.moe/hermes/configure-hermes.py`
copies it on to `$HERMES_HOME/plugins/claimstore/`, adds `claimstore` to
`plugins.enabled`, and writes the `memory` block. All three are needed: the
files alone do nothing, and `plugins.enabled` alone does nothing, because
Hermes loads a memory backend only when `memory.provider` names one.

By hand:

```
cp -R claimstore ~/.hermes/plugins/claimstore
```

```yaml
# ~/.hermes/config.yaml
plugins:
  enabled: [claimstore]
memory:
  provider: claimstore
  claimstore:
    ledger_dir: ~/.moe/ledger      # anywhere; may be outside HERMES_HOME
    peers_path: ~/.moe/cloud/peers.json   # default: <ledger_dir>/../cloud/peers.json
    targets: [memory, user]
    recall_limit: 3
```

**It needs `moe-ledger` beside it.** The sealing (§1.7), the keyring file
protocol (§2.2) and the `document` rules (§13.5) are `moeledger`, the library
inside the sibling plugin, imported from `../moe-ledger` (`_sibling.py`).
Only the directory has to be there — `moe-ledger` need not be enabled, and
Hermes activates one memory provider by name, so a second registered provider
is inert. Without it, claims are written in plaintext and stay on this Mac
(the app never pushes a plaintext body, §13.3), and the log says so.

**Installing onto a machine that already has memory adopts it.** The first
projection absorbs whatever `MEMORY.md` and `USER.md` hold into the ledger
*before* it writes anything, under the memory tool's own lock. Nothing is
replaced and nothing is lost; the files come back byte-equivalent, now backed
by records. `tests/test_projection_and_drift.py` and `tests/test_provider.py`
both pin it.

## The record

The ledger's own record shape (`docs/LEDGER-WIRE.md` §1), with a claim in the
body, its text sealed (§13.4). One JSON object per line; nothing is ever
rewritten in place.

```json
{"after":[],"at":"2026-08-31T09:14:02.000Z","body":{"claim":"8f14e45fce77","enc":"aes-gcm-256.v1","key":"job","op":"assert","source":"user","target":"memory","text_enc":"<base64 nonce‖ct‖tag>"},"device":"mac-9f3c1a2b","id":"b3f0c1…","kind":"claim","prev":"a91e…","seq":41}
```

* `id` is the **record** address — sha256 over every field but itself — so
  replaying a record is a no-op.
* `body.claim` is the **claim** address, so two writers who learn the same fact
  mint the same id and converge with no merge step. This is the one number that
  must be identical in Python and in Swift; `tests/claim-conformance.json` is
  the committed vector file both sides assert against.
* `key` is the topic this claim is a *reading of*. Two claims sharing a key are
  two answers to one question, which is what §3.1's last two rules are about.
  Absent means "its own topic", so an ordinary fact can never contend.
* `text` is sealed as `enc`/`text_enc` under the `moe:memory` keyring entry —
  the same AES-GCM primitive and wire form as a turn's text (§1.7), the key
  from `<ledger dir>/thread-keys.json` (§2.2, `moeledger.vault.Keyring`,
  minted `.fileWins` by whichever of the app and this plugin needs it first —
  but see the mint guard below). `key` and `source` stay in the clear: labels,
  not facts. A `retract` carries the id and no text; a `text_enc` that is
  present but empty is malformed and the record is ignored (only a `document`
  has that form, §13.5).
* Everything after a file's last newline is not a record yet — a torn
  concurrent write is skipped on that pass and picked up on the next refresh.
* **Without the key** (a device the courier has not reached yet), a sealed
  claim is *present but unreadable*: counted, matched to its retracts by id,
  never projected and never retracted on the person's behalf
  (`ClaimStore.unreadable(target)`, `Projection.unreadable`). One claim id is
  one sentence, so any readable copy — a plaintext legacy record, say — lends
  its text to a sealed one.

**No `thread` field, deliberately.** `ConversationProjector` indexes threads by
`body["thread"]` and deletes the file of a thread with a tombstone and nothing
surviving (`ONE-AGENT.md` §13.1, finding 8). Memory is not filed under a
conversation, so it does not have to be.

**One device per Mac (LEDGER-WIRE §13.1).** The id is the app's
`<ledger dir>/device.json` (`mac-…`), for every writer; if Hermes runs before
the app ever did, the plugin mints one in exactly the app's form
(`{"createdAt": …, "id": "mac-<8 hex>"}`, Foundation's pretty print, `0600`)
so whoever is first is the author for both. Both writers append to
`<device>.jsonl` and share its `seq`/`prev` chain under one protocol:
`flock(LOCK_EX)` on `<device>.jsonl.lock`, the head re-read from the file —
the record with the highest `seq`, which closes a legacy fork rather than
re-forking it — unless the file's `(size, mtime_ns)` is what it was after
this process's own last append, one `write(2)` on an `O_APPEND` descriptor,
`fsync`, release. The app signs at push time as the device, so Python never
opens `device-identity.json`; a claim written here is signed by the app the
moment it is pushed. A writer that skips the lock forks the chain, which the
sync layer tolerates and `ClaimStore.forked_seqs()` makes visible. The
plugin's read cache is dropped when the file changed under it between its
last `refresh()` and its own append, so a record the app wrote in that window
is never hidden by the cache's own stamp.

**The mint guard (§13.2).** `moe:memory` is minted once per tenant and never
re-minted: a second mint of the same id would seal this Mac's memory under a
key a peer that holds the first cannot open, in both directions, for good. So
the plugin mints only when nothing suggests the keyring was *lost*: it waits
(logging "waiting for moe:memory to come back from a peer", claims staying
plaintext and local meanwhile) when `peers.json` names at least one
non-revoked peer **and** either a `thread-keys.json.damaged.*` sits beside the
keyring (the app set aside one it could not parse) or the keyring file is
absent altogether. The machine's hourly reseal returns the key and the next
collect installs it. With no peer nobody can deliver, so it mints rather than
wait forever; and the ordinary live tenant — keyring present, thread keys in
it, no `moe:memory` yet — mints, which is what starts memory at all.
**Migration, once.** Until this slice the plugin minted its own
`hermes-<8 hex>` id (`claimstore-device.json`, now neither read nor written).
The first run under the shared id re-asserts every claim that is *live* from
any `hermes-*.jsonl` that is not an enrolled peer's — a machine's own prefix
is `hermes-` too (`hermes-EXAMPLE01`, a file of *turns*), and the peer book at
`peers_path` is what tells them apart; if the peer book is unreadable only
files holding claims and no turns are taken, and the log says so — as new
sealed claims under the shared id, `source` and `key` preserved, `after`
naming the legacy record.

**The deletions travel too.** Each claim id whose winning state under the
legacy files is *retracted* also gets one `retract` on the shared chain (no
text — a retract seals nothing), `after` naming the legacy tombstone and
`source` preserved. Without it a fact the person deleted before this slice
existed nowhere the machine could see: the model would notice it again there,
it would be live on the machine and a question on the Mac. With it, a
restatement anywhere is causally after a tombstone both sides hold, so it is
the same question on both. A tombstone the person later overrode (the claim
is live again) is not re-issued, and one the app already wrote under the
shared id already travels.

`<ledger dir>/claimstore-migrated.json`
(`{"from": [...], "at": …, "claims": n, "retractions": n}`) stops it running
twice. The legacy file stays: same claim id, so old and new resolve as one
claim and nothing is doubled. Without a key to seal with, the migration waits
rather than writing plaintext under the shared id.

## What happens to the drift guard

`tools/memory_tool.py:_detect_external_drift` refuses `replace` and `remove`
when the file would not round-trip through the tool's parser, or when a single
entry exceeds the store's whole-file character budget. It is easy to read that
as "another writer touched this file", but it is not: it is a check on the
file's **shape**, not its **provenance**.

So this plugin does not need to defeat the guard, work around it, or patch
`memory_tool.py`. It writes files the tool could have written itself:

* `projection.is_tool_shaped()` is the literal inverse of the guard's two
  signals, and `projection.project()` **verifies its own output against it
  before writing** — the invariant is asserted, not assumed;
* the projection takes the same `.lock` file the memory tool takes, so it
  cannot interleave with a tool write;
* claims longer than the digest budget stay in the ledger and are left out of
  the file, because writing one would be the one thing that does trip the guard.

## Reconciliation

Every projection *absorbs* first, so a person editing `MEMORY.md` in an editor
is a writer rather than a desync. Writes the model makes through the built-in
`memory` tool are captured live via `on_memory_write`, so the ledger is always
a superset of the files.

Each entry in the file gets one of three answers:

| the entry's claim is… | what happens |
|---|---|
| live | nothing; it is already represented |
| retracted, and **we wrote this file** | nothing; the file is stale and the next write drops the line |
| retracted, and we did **not** write it | a record is appended, the claim stays out of the digest, and it becomes a **question** |
| never seen | an ordinary new claim |

The middle two are the whole subtlety. A claim retracted on the phone on
Tuesday is still sitting in this machine's `MEMORY.md` until the next
projection rewrites it, so "this line is not live" cannot mean "somebody wants
it back" — an earlier version read it that way and undid the deletion on every
single pass, forever. But reading it as "always stale" swallows the person who
types a deleted fact back in by hand. `claimstore-digest.json`, beside the
device id, records the claim ids this projector last wrote into each file,
which is exactly what tells the two apart. Losing that file costs a spurious
question, never a memory.

## Removals

A `memory(remove)` or `replace` retracts the **one digest entry its `old_text`
addressed**, not every live claim containing that substring. The digest is a
deliberate subset of the live set — `prefetch` exists precisely to surface what
did not fit — so a sweep reaches claims neither the person nor the model can
see: two live claims containing "Kaplan", one of them in the file, and one
`remove` took the ledger from two live claims to zero. An `old_text` matching
several digest entries retracts nothing, which is what the built-in tool itself
does. See `projection.retract_addressed`.

## Conflicts

§3.1's claim rules, applied in `store.resolve` and mirrored exactly by
`ClaimLedger.resolve` in `Sources/MoeLedger/Claims.swift`:

* the same fact learned twice is one claim, whoever learned it;
* a retraction suppresses every assert of that claim causally before it or
  concurrent with it, and only **the person's** assert causally after it
  revives;
* one source with two readings of one topic changed its mind, and the newer
  reading wins; the older stays in the ledger and is reported as `superseded`;
* two *sources* with different readings of one topic is a genuine
  disagreement: both stay in the digest and the topic is raised. Nothing is
  silently dropped, and nothing here calls a model.

### Who counts as "the person"

`user`, and `user:<surface>`. **Not `hermes:*`.**

It is tempting to read a memory-tool write as *"the user told the Mac to
remember it again"*, which is the example §3.1 itself gives. It is not what it
is. Hermes produces exactly three `write_origin` values — `assistant_tool`
(the default, and precisely the model deciding on its own initiative),
`background_review` and `side_question` — and none of them means a person
asked for anything. Accepting them meant a fact somebody deleted about
themselves could be restored by the assistant noticing it again, with nobody in
the loop. `agent_context` is no safety net either: it has one producer in
Hermes core and it is hardcoded `"primary"`.

So a restatement that is not the person does not revive **and is not
discarded**: it becomes a `PendingRevival` — *"you deleted that before, want me
to remember it again?"* — readable as `provider.pending_revivals`, with the
record in the ledger to back it. Answering yes is an ordinary `user`-sourced
assert (`ClaimLedger.confirmRevival` on the Swift side); answering no is an
ordinary retraction. Nothing is restored silently and nothing is dropped
silently. The asking itself is not built yet — §14.4.

## Documents (§13.5)

Whole files the machine must have a current copy of travel as `document`
records — latest in ledger order wins, no merge — through
`moeledger.documents`, the one module both sides use:

| `name` | here |
|---|---|
| `soul` | `~/.hermes/SOUL.md` |
| `who` | `~/.moe/CLAUDE.md` |
| `profile/<f>` | `~/.moe/memory/profile/<f>` for `identity.md people.md threads.md voice.md preferences.md .keys.json .tombstones.json .meta.json archive.md summary.md check.md consent.json` |
| `hermes/skills-disabled` | `skills.disabled` in `~/.hermes/config.yaml`, as a sorted, deduplicated, compact JSON array |

The body is `{name, bytes, enc, text_enc}` — **no hash on the wire**. The
AEAD tag already authenticates the text, and a plaintext sha beside a sealed
body would let anyone holding the record confirm a guess at the file's
contents. Each side hashes the plaintext after opening it and keeps that sha
in its own state file only.

*Writer* (at `initialize`, `on_session_end`, `shutdown`; primary sessions
only): a source whose sha256 differs from what this side last applied or
wrote (`$HERMES_HOME/claimstore-documents.json`) becomes a sealed record; a
source that disappeared becomes `bytes: 0` with an empty `text_enc`; over
256 KB is skipped and logged. *Reader* (at `initialize` and at `prefetch` whenever the ledger
changed — the app's CloudSync pulls records into the ledger dir and the
stat-based `refresh()` sees them; also in cron sessions, which write nothing):
the newest record of each name that this side has not applied or written is
written atomically (`0600`), or removed, and `skills.disabled` is put into
`config.yaml` (effective at the next gateway start, as the log says). Reader
runs before writer, so a local edit is carried, never clobbered by a record
this side already applied. When there is **no state at all** for a name — the
state file lost, or a fresh `HERMES_HOME` — and the local source differs from
the newest record, the reader cannot tell a stale copy from an evening of
edits, so it leaves the file and records the record's sha as applied; the
writer carries the local version out next. A source that is absent is applied
as always, so first boot on a machine still fills every file. The Mac writes every name; a machine writes only
`profile/*` (§13.5's "who writes" column).

## Timing

The memory block in the system prompt is a snapshot frozen at session start,
and Hermes loads it *before* memory providers initialize (`agent/agent_init.py`
calls `load_from_disk()` ahead of `initialize_all()`). A claim that arrives
from elsewhere therefore reaches the **prompt** at the next session start, not
mid-session.

This is deliberate upstream behaviour — the frozen snapshot is what keeps the
prefix cache alive for a whole session — and the plugin does not fight it. What
it does guarantee is that the **files on disk** are current from the moment the
provider initializes, so the memory tool (which re-reads under lock on every
mutation) and the next prompt build both see the newest claims.

## A save past the cap

Hermes's memory tool refuses an `add` or `replace` that would push
`MEMORY.md`/`USER.md` past its character limit, and a refused write never
reaches `on_memory_write`. Under claimstore the files are a digest, not the
store, so that refusal is taken instead (`overflow.py`, docs/DEFAULTS.md
row 39): the plugin registers a Hermes `tool_execution` middleware which,
when the tool refused **for room** (its own words, and the file really would
overflow) and the content passes the tool's injection scan, writes the claim
to the ledger, re-projects the file under the cap (newest kept, oldest out of
the digest and still recalled), and hands the model the tool's own success
shape. Any other refusal — no match, a denied approval, a batch — is Hermes's
answer unchanged. No fork change: the middleware wraps `memory` on the
sequential and concurrent agent paths, and the Claude Code brain's bridged
calls reach the same `invoke_tool`. `tests/test_memory_never_full.py`.

Rules that keep it from ever doing more than a successful write would have:

- **Only the calling session's own provider.** The middleware's `session_id`
  must be exactly the session a writing (`primary`) provider was initialized
  for. There is no fallback to "the only live provider": a cron job keeps the
  memory tool, and its refusal must not land in the person's memory through
  the chat's provider. No match, and Hermes's refusal comes back unchanged.
- **A refusal leaves the ledger as it was.** Whether the claim would go live
  (a deleted fact restated by the assistant becomes a question, not a save)
  and whether a replace's `old_text` addresses exactly one digest entry are
  decided before anything is written; a replace either retracts the old
  fact, asserts the new one and re-projects, or touches nothing.
- **A kept claim is a save.** If re-projection fails after the claim is live,
  the model is told success (and the failure is logged); the next projection
  fits the file.
- **Hermes's own success shape**, `note` included.
- **Words and arithmetic.** The tool's "no room" wording is still required,
  but room is also measured on the file with the tool's limit; a refusal
  that is "no room" by the numbers and not by the words is logged once at
  WARNING, so a Hermes rewording is visible instead of silently switching
  this off.
- Registration is idempotent **per plugin registry** (the middleware is
  looked for in that registry's chain), so a rebuilt plugin manager gets it
  again.

## Tests

They need Hermes's own imports and its 3.11 venv, so they run from a
hermes-agent checkout rather than from Alfie's `scripts/test.sh`:

```
cd <hermes-agent>
.venv/bin/python -m pytest <moe>/moe-home/hermes-plugins/claimstore/tests
```

(Both plugins' suites run together: add `<moe>/moe-home/hermes-plugins/moe-ledger/tests`.)
Every test uses temp directories; the sibling library comes off
`../moe-ledger` the way the plugin finds it.

`tests/test_conformance.py` is the one that must never be skipped: it is the
Python half of the agreement with Swift, and its Swift half is
`Tests/MoeLedgerTests/ClaimConformanceTests.swift`. Regenerate the fixture with
`tests/make_conformance.py` only when a rule changes on purpose.
`tests/test_mac_memory_records.py` is §13 on this side: sealing, the shared
key, unreadable-without-key, the migration, documents.
`tests/test_claim_log.py` holds the two-writer chain test (this plugin and a
simulated Swift writer appending to one file: no forks, no gaps).

## Not in `plugins/memory/`

Deliberately. Hermes closed the built-in memory-provider set in May 2026
(`CONTRIBUTING.md`, "Memory Providers: Ship as a Standalone Plugin"); new
backends ship as standalone plugins installed into `~/.hermes/plugins/`. This
directory is laid out to be copied there as-is.
