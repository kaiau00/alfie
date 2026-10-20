# Security policy

Memoe listens to your microphone, reads the services you connect, can
control your Mac and can send messages on your behalf. We take reports
about any of that seriously, and we would much rather hear from you than
read about it.

## Reporting a vulnerability

**Please do not open a public issue, discussion or pull request for a
security problem.**

Report it privately, in either of these ways:

- **GitHub:** use [Report a vulnerability](https://github.com/memoe-app/memoe/security/advisories/new)
  on the Security tab of this repository (private vulnerability reporting).
- **Email:** hello@moebot.app, with "Security" in the subject

Please include:

- the version of Memoe (Settings › About & Licences) and of macOS;
- what an attacker can do, and what they need first (local access, a
  malicious web page, a crafted message, a connected service);
- steps to reproduce, or a proof of concept;
- whether you have shared it with anyone else.

Do not include real personal data (yours or anyone else's) in a report.
Redact transcripts, memory files and logs before you attach them.

## What happens next

- We acknowledge your report within **3 working days**.
- We tell you whether we can reproduce it, and our plan, within **10
  working days**.
- We fix confirmed issues in a release as fast as their severity calls for,
  and every installed copy updates itself.
- We credit you in the release notes and the advisory, unless you would
  rather not be named.

This is a small project maintained by one person; these are honest
targets, not a contract. If you have not heard back, a polite nudge is
welcome.

## Supported versions

Only the **latest release** receives security fixes. Memoe updates itself,
so that is what nearly everyone runs. Builds you make from source are not
supported as releases, but a vulnerability you find in one almost certainly
exists in the release too, so please report it.

## Scope

**In scope (this repository):**

- the Memoe Mac app, including community builds from this repository;
- the gate that asks before anything is sent to another person
  (`Sources/MoeConfirm` and the hooks it installs into Hermes);
- how the app stores and passes credentials, tokens and your memory;
- the update path (Sparkle feed and signature checks);
- the send gate's own state: anything that lets the agent's shell approve
  its own sends. The gate is a guard rail, not a sandbox: the agent runs
  with your user's rights, and a determined prompt injection that reaches
  the shell is in scope;
- the scripts that build, sign and package the app;
- anything a web page, an email, a calendar invite, a message or a
  connected service can make Moe do without your yes (prompt injection
  that crosses the send gate or reaches the shell is in scope).

**Also report to us, though the code is not here:**

- **Away** and the services behind memoe.app (the relay, accounts,
  billing). These are closed source. Report through the same channels and
  we will handle them the same way. Do not test against other people's
  accounts or cloud computers; use your own.

**Report upstream instead** (and feel free to copy us):

- [Hermes Agent](https://github.com/NousResearch/hermes-agent/security),
  [cua-driver](https://github.com/trycua/cua),
  [FluidAudio](https://github.com/FluidInference/FluidAudio),
  [Sparkle](https://github.com/sparkle-project/Sparkle), and your AI
  provider, for issues in their own code that do not depend on how Memoe
  uses it.

**Out of scope:**

- the model giving a wrong or unwise answer, with no security boundary
  crossed;
- anything that needs an attacker who already has your unlocked Mac and
  your login password;
- denial of service against memoe.app, automated scanning that generates
  noise, social engineering of the maintainer, physical attacks.

## Safe harbour

If you act in good faith, stay within this policy, avoid privacy
violations and service disruption, and give us reasonable time to fix
before you publish, we will not pursue or support legal action against you
for your research.
