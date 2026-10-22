<p align="center">
  <img alt="Alfie" src="Resources/icon-preview.png" width="160">
</p>

<h1 align="center">Alfie</h1>

<h3 align="center">A voice assistant that lives in your Mac's notch, with a butler's manners.</h3>

<p align="center">
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-D9A84E"></a>
  <img alt="macOS 15+ on Apple silicon" src="https://img.shields.io/badge/macOS-15%2B%20%C2%B7%20Apple%20silicon-111?logo=apple&logoColor=white">
</p>

> **Alfie is a fork of [Memoe](https://github.com/memoe-app/memoe)** and is
> not affiliated with or endorsed by Memoe or its authors. Memoe and Moe are
> their trademarks; see [TRADEMARK.md](TRADEMARK.md).

## What Alfie does

Say **"Hey Alfie"** (or hold the right **Option ⌥** key) from any app, ask for
something, and Alfie answers out loud like a polite English butler: *"Very
good, sir. Nothing on your calendar until three."*

- **Talks and listens.** It answers out loud, and you can interrupt it.
- **Does things on your Mac.** It opens apps, reads your calendar, finds
  files and works in your own Chrome.
- **Remembers you.** A short list of facts about you that you can read and
  edit.
- **Asks before anything goes out.** An email or message is shown to you in
  full first. Nothing is sent until you press **Send**.
- **Takes meeting notes**, on your Mac, only when you start it.
- **Uses an account you already have** to think: a Claude or ChatGPT plan,
  or an API key.

---

## Install Alfie (about 15 minutes)

### What you need

- A Mac with an **Apple chip** (M1, M2, M3 or later). To check: Apple menu
   › **About This Mac**, and look for "Chip: Apple M…".
- **macOS 15 (Sequoia) or later.** Same window, look for "macOS".
- About **3 GB** of free space.
- A **Claude** or **ChatGPT** account (the paid plan you may already have),
  or an API key from an AI company.

### Step 1: Open Terminal

Press **⌘ Space**, type **Terminal**, and press **Return**. A window with a
text prompt opens. You will paste a few commands into it: paste with
**⌘ V**, then press **Return** to run.

### Step 2: Install Apple's developer tools

Paste this and press Return:

```bash
xcode-select --install
```

A pop-up appears. Click **Install**, agree, and wait for it to finish (5 to
15 minutes). If Terminal says the tools are *already installed*, you can go
straight to Step 3.

### Step 3: Download and build Alfie

Paste this whole line and press Return:

```bash
mkdir -p ~/Developer && cd ~/Developer && git clone https://github.com/kaiau00/alfie.git && cd alfie && ./scripts/bootstrap.sh
```

This downloads Alfie into a **Developer** folder in your home folder and
builds it. It takes a few minutes and prints a lot of text; that is normal.
When it finishes, **Alfie opens by itself.**

> **Why not the Desktop?** If your Desktop or Documents folder syncs to
> iCloud, building Alfie there fails with a "signature" error. The command
> above uses `~/Developer`, which iCloud does not touch.

### Step 4: Put Alfie in Applications

Paste this so Alfie lives in your Applications folder like any other app:

```bash
ditto ~/Developer/alfie/dist/Alfie.app /Applications/Alfie.app && open /Applications/Alfie.app
```

From now on, open Alfie from Launchpad, Spotlight or the Applications
folder. It shows up as a small icon in the menu bar at the top of the
screen.

---

## First-time setup

The first time Alfie opens, a short welcome walks you through it. Every
screen can be skipped and changed later.

1. **Microphone.** Click **Turn on the microphone** and allow it. Your voice
   is turned into text on your Mac and is not sent anywhere.
2. **Something to think with.** Pick **Sign in with Claude** or **Sign in
   with ChatGPT** and finish in your web browser. Or paste an API key.
3. **Say hello.** Hold the right **Option ⌥** key, say *"what can you do?"*,
   and let go. Alfie answers. Allow **Accessibility** (so the key works in
   every app) and **Screen Recording** (so Alfie can see your screen when you
   ask) when it asks.
4. The rest (meeting notes, what Alfie may learn from, connections) is up to
   you. Skipping is fine.

The first answers can be slow while Alfie downloads its speech and voice
models (about 900 MB, once).

### Make it yours (optional)

Open Alfie's **Settings** from its menu-bar icon.

- **"Hey Alfie".** Settings › **Voice** › turn on **Or just say "Hey
  Alfie"**, then click **Teach…** beside **Teach Alfie how you say it**: you
  say "Hey Alfie" and a few look-alikes for about two minutes, and Alfie tunes
  itself to your voice and room.
- **A butler's voice.** Settings › **Voice**: try **George**, the deepest
  British voice. If a voice sometimes slurs words, try another; the American
  voices are the clearest.
- **What it calls you.** Alfie says "sir" by default. Just tell it: *"call me
  Sam"*, and it remembers.
- **Work in your own Chrome.** Connections › **Alfie in your Chrome** ›
  **Set up**, then in Chrome's Extensions page turn on **Developer mode**,
  click **Load unpacked** and pick the folder Alfie shows you. Alfie then
  opens web pages in your Chrome, in a tab group called *Alfie*.
- **A quicker reply.** Settings › Voice › More › **Say "Certainly" as soon as
  I ask**, so you hear something the moment you finish speaking.

## Everyday use

| To… | Do this |
|---|---|
| Ask something | Say **"Hey Alfie"**, or hold right **⌥** and talk |
| Start or stop with the keyboard | **⌃ ⌥ Space** |
| Stop Alfie talking | Double-tap right **⌥**, or just start talking |
| Type instead | Hover over the notch to open the panel, then type in the box at the bottom |

## Updating Alfie

Alfie does not update itself. To get the latest version, open Terminal,
quit Alfie from its menu-bar icon, and paste:

```bash
cd ~/Developer/alfie && git pull && ./scripts/bootstrap.sh && ditto dist/Alfie.app /Applications/Alfie.app
```

Your settings, memory and notes are kept.

## If something goes wrong

- **"command not found: git" or a pop-up about developer tools.** Step 2
  did not finish. Run `xcode-select --install` again and wait for it.
- **The build fails with "resource fork, Finder information" or a
  signature error.** Alfie was downloaded into a folder iCloud syncs. Use
  the Step 3 command, which puts it in `~/Developer`.
- **Alfie doesn't hear me.** System Settings › Privacy & Security ›
  **Microphone** and **Accessibility**: make sure Alfie is switched on. If it
  already is, switch it off and on again.
- **"Hey Alfie" misses me, or wakes up on its own.** Settings › Voice ›
  **Teach…** (or **Teach again…**), and say the lines it shows.
- **Alfie talks over itself or keeps stopping mid-sentence.** Its own voice
  is reaching the microphone. Use headphones, or lower the volume.
- **Answers are slow.** A Claude or ChatGPT plan is usually fastest. On a
  Mac with 8 GB of memory, quitting apps you are not using helps a lot.
- **Something else.** [Ask in Discussions](https://github.com/kaiau00/alfie/discussions)
  or [report a bug](https://github.com/kaiau00/alfie/issues/new/choose).

The full guide to every screen and setting is [doc.md](doc.md).

---

## For developers

- Build: `./scripts/bootstrap.sh` (community edition: bundle id
  `io.github.kaiau00.alfie`, home `~/Library/Application Support/Alfie`, no
  updater, no cloud). Swift tests: `MOE_SKIP_PG=1 ./scripts/test.sh` (needs
  full Xcode). See [CONTRIBUTING.md](CONTRIBUTING.md).
- Alfie's brain is [Hermes Agent](https://github.com/NousResearch/hermes-agent),
  installed into `~/.hermes` on first launch and shared with any other Hermes
  on the Mac.
- The "Hey Alfie" model and how to retrain it: `scripts/wakeword/`
  (`hey-alfie.yaml`, `pipeline.sh`).
- Differences from Memoe: own name, icon, bundle id and data folder; no
  update feed or hosted cloud; "Hey Alfie" wake word; a butler's manner by
  default; web work in your own Chrome first; machine names spoken as words.
  The commit history has the details.

## Licence

Apache License 2.0, the same as Memoe. See [LICENSE](LICENSE), [NOTICE](NOTICE)
and [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
