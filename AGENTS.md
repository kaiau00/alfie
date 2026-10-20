# Working in this repository

Notes for contributors and for coding agents working on their behalf.

## Build and test

- Apple silicon, macOS 15+, Xcode Command Line Tools. No Xcode project.
- `swift build` compiles the app. It does **not** compile `Tests/`.
- `MOE_SKIP_PG=1 ./scripts/test.sh` runs the Swift tests. Run it before you
  push: a test that does not compile only shows up there.
- `./scripts/bootstrap.sh` builds the **community edition** (its own bundle
  identifier, data folder, no updater, no cloud) and opens it from `dist/`.

## Rules that keep people's Macs safe

- **Never touch an installed official Memoe.** The community edition has
  its own identity so it cannot. Never copy a bundle into `/Applications`
  by hand, and never change the bundle identifier to the official one.
- **Nothing goes out without the person's yes.** Anything that can send,
  post or share on someone's behalf must go through the send sheet
  (`Sources/MoeConfirm`, `moe-home/hermes/hooks/`). Match on what a call
  *does*, never on a list of tool names: a list is walked past by the next
  name.
- **Moe is provider-agnostic.** It must work the same with a Claude plan, a
  ChatGPT plan, any provider's API key, or a local model. Do not add
  behaviour that only works with one provider, and do not name one vendor's
  models in user-facing text.
- **Computer use goes through cua-driver.** Prefer data, then scripting,
  then menus, then clicks.
- **The Moe home path contains a space**
  (`~/Library/Application Support/Moe`). Quote every expansion built from it.

## Tests

- A test must be able to fail: revert your fix and watch it go red.
- Measure, then assert. If the code depends on how macOS or an app behaves,
  quote the real measurement in the test, not a number you made up.
- Test a guard's side effect, not just whether it allowed or refused.

## Docs

If you change what a person sees or does, update `doc.md` in the same
change: fold it into the right section, written for someone using the app,
and add a line to its change log. `doc.md` is the source of
docs.memoe.app.

## Commits

Sign off every commit (`git commit -s`); see CONTRIBUTING.md.
