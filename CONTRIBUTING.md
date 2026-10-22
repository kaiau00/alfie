# Contributing to Alfie

Thank you for wanting to help. Alfie is a personal fork of
[Memoe](https://github.com/memoe-app/memoe), maintained by one person.

## Where things go

| You have… | Go to |
|---|---|
| A question about using Alfie | [doc.md](doc.md), then [Discussions](https://github.com/kaiau00/alfie/discussions) |
| A bug you can reproduce | [A bug report](https://github.com/kaiau00/alfie/issues/new?template=bug.yml) |
| An idea or a feature request | [A feature request](https://github.com/kaiau00/alfie/issues/new?template=feature.yml), problem first |
| A security problem | **Not here.** See [SECURITY.md](SECURITY.md) |

Search open and closed issues before you file.

## Firm rules

These come from Memoe and still hold:

- **Provider-agnostic.** Alfie must work the same with a Claude plan, a
  ChatGPT plan, any provider's API key or a local model.
- **Nothing goes out without the person's yes.** Changes near the send
  sheet (`Sources/MoeConfirm`, `moe-home/hermes/hooks/`) get extra review.
  Match on what a call *does*, never on a list of tool names.
- **Computer use goes through cua-driver.** Prefer data, then scripting,
  then menus, then clicks.
- **Never touch an installed Memoe.** Alfie has its own bundle identifier,
  data folder and no updater; keep it that way.

## Setting up

```sh
./scripts/bootstrap.sh     # builds dist/Alfie.app and opens it
```

On a Mac whose Desktop or Documents syncs to iCloud, keep `dist/` out of
the synced folder (a symlink to `~/Library/Developer/Alfie/dist` works):
codesign rejects iCloud's file tags.

## Tests

```sh
MOE_SKIP_PG=1 ./scripts/test.sh   # Swift unit tests (needs full Xcode's Swift Testing)
```

- **A test must be able to fail.** Revert your fix and watch it go red.
- **Measure, then assert.** Quote real measurements, not invented numbers.
- **Test the side effect, not the verdict.**

## Pull requests

- One change per pull request.
- **If you change what a person sees or does, update [`doc.md`](doc.md)**
  in the same pull request and add a line to its change log.
- Do not commit anything from your own Alfie home, your keys, OAuth client
  files, model weights or `hermes-seed/`.

## Licence and sign-off

Alfie is licensed under the [Apache License 2.0](LICENSE), like Memoe. By
contributing, you agree your contribution is licensed under it too. Sign
off every commit to certify the
[Developer Certificate of Origin](https://developercertificate.org/):

```sh
git commit -s -m "Your message"
```

Contributing code does not give you rights to the Memoe name or logo; see
[TRADEMARK.md](TRADEMARK.md).

## Code of conduct

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
