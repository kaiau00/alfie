# Contributing to Memoe

Thank you for wanting to help. Memoe is maintained by one person, so this
page is mostly about making your time and mine count.

## Where things go

| You have… | Go to |
|---|---|
| A question about using Memoe | [docs.memoe.app](https://docs.memoe.app) |
| Something broken in the app you use every day | Tell Moe: *"report this to the Moe team."* It attaches what we need, with your yes. Or open a bug here |
| A bug you can reproduce | [A bug report](https://github.com/memoe-app/memoe/issues/new?template=bug.yml) |
| An idea or a feature request | [A feature request](https://github.com/memoe-app/memoe/issues/new?template=feature.yml), problem first |
| A security problem | **Not here.** See [SECURITY.md](SECURITY.md) |
| A problem with Away, billing or your account | hello@moebot.app (Away is not in this repository) |

Search open and closed issues before you file. If one
matches, add what is new about your case instead of "+1"; a 👍 reaction
counts the same and does not notify everyone.

## Before you write code

- **Small fixes** (typos, an obvious bug, a test, a doc line): just open
  a pull request.
- **Anything larger**: comment on the issue first and
  say how you plan to do it. That avoids you spending a weekend on
  something that conflicts with work in progress or with a decision
  already taken.
- Issues labelled [`good first issue`](https://github.com/memoe-app/memoe/labels/good%20first%20issue)
  are scoped and ready; comment that you are taking one.

The parts of Memoe that talk to our cloud (Away, sign-in, problem reports)
are not in this repository, so changes there cannot be made here.

Some areas have firm decisions behind them. Please read the linked doc
before proposing a change there:

- **Moe is provider-agnostic.** It must work the same with a Claude plan,
  a ChatGPT plan, any provider's API key or a local model. Do not add
  behaviour that only works with one provider, and do not name a vendor's
  model in user-facing text where a tier ("the cheapest model your
  provider serves") would do.
- **Nothing goes out without the person's yes.** Changes near the send
  sheet (`Sources/MoeConfirm`) get extra review. Match on what a call
  *does*, never on a list of tool names.
- **Computer use goes through cua-driver.** We do not maintain our own
  screen driver. Prefer data, then scripting, then menus, then clicks.
- **The thinking runs in Hermes.** Prefer a fix in the Hermes harness (a
  structured tool result) over a fix in prompt text, which has to be
  re-tuned for every model.

## Setting up

See the README's [Build from source](README.md#build-from-source). In short:

```sh
./scripts/bootstrap.sh     # builds the community edition into dist/ and opens it
```

The community edition has its own bundle identifier, its own data folder
and no updater, so it cannot touch an official Memoe you use. Do not copy a
bundle into `/Applications` by hand, and do not give a build the official
bundle identifier.

## Tests

```sh
MOE_SKIP_PG=1 ./scripts/test.sh   # Swift unit tests (Swift Testing)
```

Pull requests run it in CI, along with `swift build`.

What we ask of a test:

- **It must be able to fail.** Revert your fix and watch the test go red.
  If it stays green, it is not testing your fix.
- **Measure, then assert.** If the code depends on how macOS, an app or a
  service behaves, quote the real measurement in the test. Tests that use
  the same invented numbers as the code agree with themselves and prove
  nothing.
- **Test the side effect, not the verdict.** A guard that did not run and a
  guard that allowed look the same from outside.

`swift build` does not compile `Tests/`. Run `./scripts/test.sh` before you
push, or a test that does not compile will surprise you in CI.

## Pull requests

- One change per pull request. A branch that has drifted far from `main`
  should be split, not merged.
- Rebase on the latest `main` before you ask for review, and check
  `git diff --stat origin/main...HEAD` for files you did not mean to touch.
- **If you change what a person sees or does, update [`doc.md`](doc.md) in
  the same pull request**: fold the change into the right section, written
  for someone using the app, and add a line to its change log. doc.md is
  the source of docs.memoe.app and must never disagree with the app.
- Write the description for a reviewer who has not seen the issue: what,
  why, and how you know it works.
- Do not commit anything from your own Moe home, your keys, OAuth client
  files, model weights or `hermes-seed/`. They are gitignored for a reason.

### Writing for the app and the docs

Plain words, short sentences, no hype. Not "AI assistant", not metaphors.
Say what it does: *"Moe answers out loud"*, not *"a seamless voice-first
experience"*. Memoe is the app; Moe is the assistant inside it. Write
"Memoe" whole, never split.

### Using AI tools

You are welcome to use AI tools, and many of us do. You are responsible for
every line you submit: you must understand it, have run it, and be able to
explain it in review. Say in the pull request if a substantial part was
generated. Please write issue and PR descriptions in your own words.
Pull requests that look like unreviewed generated output will be closed.

## Licence and sign-off

Memoe is licensed under the [Apache License 2.0](LICENSE). By contributing,
you agree that your contribution is licensed under it too (inbound =
outbound, as section 5 of the licence says). There is no contributor
licence agreement, and we will not relicense contributions under more
restrictive terms.

Sign off every commit to certify the
[Developer Certificate of Origin](https://developercertificate.org/):

```sh
git commit -s -m "Your message"
```

That adds a `Signed-off-by: Your Name <you@example.com>` line, which says
you wrote the change or otherwise have the right to submit it under the
project's licence. Use your real name. A check on every pull request looks
for the line on each commit; `git rebase --signoff origin/main` adds it to
commits you already made.

Contributing code does not give you rights to the Memoe name or logo; see
[TRADEMARK.md](TRADEMARK.md).

## Code of conduct

Everyone taking part is expected to follow the
[Code of Conduct](CODE_OF_CONDUCT.md). Report problems to
hello@moebot.app.
