# Security

Alfie listens to your microphone, reads the services you connect, can
drive your Mac and can send messages on your behalf (always after you say
yes). A flaw in any of that matters, so thank you for reporting one.

## Reporting a vulnerability

**Please do not open a public issue, discussion or pull request for a
security problem.** Report it privately instead:

- **GitHub:** use [Report a vulnerability](https://github.com/kaiau00/alfie/security/advisories/new)
  on this repository.

Include what you found, how to reproduce it, the version of Alfie
(Settings › About & Licences) and of macOS, and what an attacker could do
with it. You will get a reply as soon as the maintainer can; this is a
personal project maintained by one person, so please allow some time.

## What is in scope

- the Alfie Mac app and everything in this repository, including the
  helper scripts in `moe-home/`.

Out of scope here, and best reported to their own projects:

- [Hermes Agent](https://github.com/NousResearch/hermes-agent/security),
  which Alfie runs as its brain;
- [cua-driver](https://github.com/trycua/cua), which drives the screen;
- a problem that is also in Memoe, which you can report to
  [Memoe](https://github.com/memoe-app/memoe/security) as well.
