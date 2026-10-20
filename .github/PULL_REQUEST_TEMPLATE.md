<!--
Thanks for the pull request. Keep it to one change. If it fixes an issue,
say "Fixes #123" below. Accepted changes land through the private
repository and reach main in the next sync (see CONTRIBUTING.md,
"How a pull request lands"); we close the issue then.
Security fix? Please report privately first (SECURITY.md) and coordinate.
-->

## What and why

<!-- What does this change, and why? Write it for a reviewer who has not read the issue. -->

Fixes #

## What a person will notice

<!-- In plain words, from the point of view of someone using Memoe. "Nothing" is a fine answer for internal changes. -->

## How I know it works

<!-- Commands you ran, what you saw. For UI, a screenshot or a short recording. -->

- [ ] `MOE_SKIP_PG=1 ./scripts/test.sh` passes
- [ ] I reverted the fix and watched the new or changed test fail
- [ ] I tried it in a community build (`./scripts/bootstrap.sh`)

## Checklist

- [ ] One change; rebased on the latest `main`; `git diff --stat origin/main...HEAD` shows only files I meant to touch
- [ ] `doc.md` updated in this pull request if anything a person sees or does changed (folded into its section, plus a change-log line)
- [ ] Works the same with a Claude plan, a ChatGPT plan, an API key and a local model, or I explained why it does not need to
- [ ] Nothing new can send, post or share on someone's behalf without the send sheet
- [ ] No personal data, keys, OAuth client files, model weights or `hermes-seed/` committed
- [ ] Commits signed off (`git commit -s`)

## Notes for the reviewer

<!-- Anything you are unsure about, trade-offs, follow-ups. Mention if a substantial part was written with an AI tool. -->
