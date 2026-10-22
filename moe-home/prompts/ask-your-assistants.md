# Getting your history out of Claude and ChatGPT

Alfie can read your Mac, but it can't see the years of conversations you've had
inside claude.ai or ChatGPT — those live on their servers, in their memory, and
there's no API that hands them over on a subscription.

So ask them directly. Paste the prompt below into **claude.ai** and into
**ChatGPT** (each in a *new* chat, on the account you actually use). Copy what
each one gives you back and save it:

```
~/moe/scripts/import-assistant-dump.sh claude     # then paste, then Ctrl-D
~/moe/scripts/import-assistant-dump.sh chatgpt
```

They land in `~/.moe/memory/`, which Alfie reads on every conversation. Then
run `~/.moe/hermes/migrate-memory.py` so Hermes's own USER.md and MEMORY.md
pick them up too.

**Turn memory on first.** ChatGPT: Settings › Personalization › Memory.
Claude: Settings › Capabilities › Memory. Without it, they only see the current
chat and you'll get a thin answer.

---

## The prompt

Copy everything between the lines.

---

I'm building a personal assistant that runs on my own machine, and I want to
give it everything you already know about me so it doesn't start from zero.

Go through everything you remember about me — your memory, our past
conversations, anything saved about me in this account. Then write me a single
document I can hand to another assistant.

Cover, in this order:

1. **Who I am.** Work, what I'm building, family, where I live, the shape of my
   week.
2. **The people in my life** you've heard about, by name, and what each one is
   to me.
3. **What I'm working on.** Every project or thread you know about, its current
   state as best you can tell, and anything I said I'd do that I may not have
   done.
4. **How I think.** What I optimise for, what I avoid, how I make decisions,
   the arguments I keep coming back to, positions I hold strongly.
5. **How I communicate.** My register, how long my messages run, my humour,
   words and phrases I actually use, how I talk when I'm stressed versus
   relaxed.
6. **What I keep asking you about.** Recurring topics, questions I circle, the
   kind of help I reach for most.
7. **What you've noticed that I might not have said outright** — patterns,
   contradictions, things I seem to care about more than I admit.
8. **What you don't know about me.** The obvious gaps.

Rules:

- Be specific and concrete. "Weighs equity against control and usually picks
  control" beats "thoughtful about business decisions."
- Write it for another assistant to read, not for me to feel good about. Don't
  flatter me. If something is unflattering but useful, include it.
- Say where each thing comes from — a saved memory, or a conversation, and
  roughly when. If you're inferring, say you're inferring.
- Don't include passwords, codes, card or account numbers, or anything medical.
- If your memory of me is thin, say so plainly rather than inventing a
  personality. A short honest answer is more useful than a long invented one.
- Plain markdown. No preamble, no "here's what I found" — just the document.

---

## After you paste it back

Read it before you import it. These systems will state guesses as facts, and
anything wrong in here gets baked into your soul file and then quietly repeated
back to you for months. Delete what's wrong.
