<p align="center">
  <img alt="Alfie" src="Resources/icon-preview.png" width="160">
</p>

<h1 align="center">Alfie</h1>

<h3 align="center">A voice assistant that lives in your Mac's notch. Talk from any app, and it talks back.</h3>

<p align="center">
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-D9A84E"></a>
  <img alt="macOS 15+ on Apple silicon" src="https://img.shields.io/badge/macOS-15%2B%20%C2%B7%20Apple%20silicon-111?logo=apple&logoColor=white">
</p>

> **Alfie is a fork of [Memoe](https://github.com/memoe-app/memoe)** and is
> not affiliated with or endorsed by Memoe or its authors. Memoe and Moe are
> their trademarks; see [TRADEMARK.md](TRADEMARK.md).

## What it does

- **Lives in the notch, not a window.** Hold right ⌥ in whatever app you are
  in, or use the hotkey, and talk. Alfie answers out loud and on a small panel
  under the notch, and you can interrupt it at any time.
- **Does the work on your Mac.** It opens apps, uses their menus, fills in
  fields and uses its own browser for the web.
- **Remembers you.** A short list of plain facts about you that Alfie reads
  before every answer. You can read, correct or delete every line.
- **Asks before anything goes out.** Before an email or message goes to
  someone, a sheet shows where it is going and the whole text. Nothing is sent
  until you press **Send**.
- **Takes meeting notes.** It records both sides of a call, transcribes it on
  your Mac and writes the notes. Recording never starts without you.
- **Brings your own brain.** Alfie thinks with an account you already have: a
  Claude or ChatGPT plan, an API key, or a local model (Ollama, LM Studio).

## Install (build from source)

You need a Mac with Apple silicon, macOS 15 or later, and Apple's Command Line
Tools (`xcode-select --install`). Xcode itself is not needed.

```sh
git clone https://github.com/kaiau00/alfie.git
cd alfie
./scripts/bootstrap.sh
```

That builds `dist/Alfie.app` and opens it. Drag it into Applications if you
want it there. The first build takes several minutes. The first launch
downloads the speech and voice models (add `--models` to bundle them into the
build instead), and the setup guide walks you through connecting a brain and
granting microphone and accessibility permissions.

Alfie is built and signed on your own Mac, so macOS does not show the
"unidentified developer" warning for your own build.

## Where Alfie keeps things

- Settings and data: `~/Library/Application Support/Alfie`
- Its brain (Hermes): `~/.hermes`, shared with any other Hermes install on the Mac

Alfie has no updater. To update, pull and build again:

```sh
git pull && ./scripts/bootstrap.sh
```

## Differences from Memoe

- Own name, icon, bundle identifier (`io.github.kaiau00.alfie`) and data folder.
- No update feed and no hosted cloud: Away mode, cloud sign-in and cloud voice
  are off.
- The wake word is being retrained for "Hey Alfie". Until that lands, use the
  hotkey or hold right ⌥ to talk.

## Licence

Apache License 2.0, the same as Memoe. See [LICENSE](LICENSE), [NOTICE](NOTICE)
and [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES). Files changed from Memoe are
listed in this repository's git history.
