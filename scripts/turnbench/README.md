# scripts/turnbench — the turn-taking bench

Two benches share this folder:

- **eot-bench** (LiveKit's 400 real English turns): `eot_prep.py` unpacks it,
  `Moe --turn-bench <dir> <tapes.json>` records tapes, `Moe --turn-replay`
  sweeps the endpoint policy over them. Capture only.
- **The noisy conversation corpus** (this README): synthetic turns and
  barge-ins in Inworld voices, mixed with room noise and Moe's own voice as
  echo at clean / 20 / 10 / 5 / 0 dB, scored by `Moe --turn-bench --corpus`.
  It is Tier 1 of `~/moe-voice-notes/research-eval-harness.md`.

Nothing here uses the microphone or plays a sound.

## Building the corpus

The corpus lives outside the repo, in `~/moe-voice-data/`:

```
~/moe-voice-data/
  venv/                    numpy + soundfile (python3 -m venv venv; venv/bin/pip install numpy soundfile)
  noise/                   fetch_noise.py's output + sources.json
  turn-corpus/plan.json    turn_scripts.py's output
  turn-corpus/raw/         the Inworld renders: <id>.wav + <id>.json (word timings), ledger.json
  turn-corpus/test/        mix.py's output: wav/, manifest.json, tapes.json, results.json
  turn-corpus/dev/         the same for the dev voices
```

1. **Noise.** `venv/bin/python scripts/turnbench/fetch_noise.py` — DEMAND
   (kitchen, living room, washing machine, office, cafeteria; channel 1),
   OpenSLR SLR28 (point-source noises and real room impulse responses),
   MUSAN's noise (per-file licence read from MUSAN's own LICENSE; NC, ND or
   unmarked is skipped), and one-minute beds of other people talking strung
   from LibriSpeech dev-clean. Commercial use allowed only: **never WHAM! or
   ESC-50** (CC BY-NC). The MUSAN mirror has no music, so there is no music
   bed yet. Resumable, downloads side by side (zenodo alone ran ~0.2 MB/s).
2. **The script.** `python3 scripts/turnbench/turn_scripts.py > plan.json` —
   no network, no key. Voices are split whole, as the wake-word run split them:
   **test** = the 32 voices wake v6 held out (`~/moe-wake-v6work/holdout.json`),
   **dev** = 12 English voices from the rest (for choosing thresholds),
   train = everything else, not rendered. Line kinds: `single`, `pause`,
   `filler`, `and`, `correction`, `short` (turns); `stop`, `interrupt`,
   `backchannel` (said over a reply); plus Moe's replies in its own Inworld
   voices, Clive and Ashley. Pauses are `<break time="…ms"/>` of 0.5, 1.0,
   1.5 and 2.5 s.
3. **Render.** `python3 ~/moe-wake-data/turn_corpus.py plan.json raw` — the
   only script that talks to Inworld, and it lives in `~/moe-wake-data/`
   because that is the one place allowed to read `~/.moe-inworld-key`. It
   calls api.inworld.ai only, never prints the key, asks for WORD
   timestamps, keeps a character ledger and refuses to pass `--budget`
   (default 60,000). v1 cost 39,629 characters on `inworld-tts-2-flash`.
   Resumable.
4. **Mix.** `venv/bin/python scripts/turnbench/mix.py raw ../noise test --split test`
   (and `--split dev`). Every base scenario is mixed at each SNR with the same
   noise segment, room and level, so the SNR is the only difference between its
   copies. Details in the docstring; the choices that matter:
   - SNR over the person's speech-active samples (inside word spans), DNS-style.
   - Their level drawn from −32 to −20 dBFS; half the scenarios in a real room
     (an SLR28 RIR aligned on its direct path, so word times still hold).
   - Echo: Moe's reply played back into the microphone 30 ms late at none,
     −25 or −15 dB against the person — the residual after the canceller
     (VPIO cannot run offline). −25 is a guess at a working canceller; the
     owner's `EchoTest.leakDb` should replace it (Tier 2).
   - "clean" is −80 dBFS dither, never digital zero.

### What the truth is

From Inworld's word timestamps, never from Moe. For a **turn**: every
word, the pauses the person went on after (gaps ≥ 0.2 s between words),
and the true end (the last word's end). The rendered break tags were
checked against the audio envelope: the silence begins where the last
word's timestamp ends. For a **reply**: when Moe is audible, its words
and sentence ends (the playhead the echo check reads), and the
interjection's first and last word.

## Running the bench

```
Moe --turn-bench --corpus ~/moe-voice-data/turn-corpus/test
    [--snr clean,20] [--kind turn|reply] [--category pause] [--limit n]
    [--set key=value]… [--before] [--brain s] [--label "text"]
    [--tapes file] [--out file] [--rerecord]
```

(Build with `swift build -c release --product Moe`, run `.build/release/Moe`.)

The first run records a tape for every scenario — each file through the real
pipeline (Silero + the noise-floor gate in `AudioPipeline`, Parakeet's
streaming recogniser), faster than real time, with Smart Turn asked
everywhere the engine would ask it (trimmed as `askTurnModel` trims) — and
saves them to `tapes.json`, resumably. Later runs reuse the tapes and only
replay, which takes seconds, so `--set` can be swept freely. `--rerecord`
after changing anything in the pipeline (a denoiser, a new Smart Turn).

The tapes then go through the real `VoiceMachine`:

- a **turn** through `PolicyReplay` (Moe listening; the capture half);
- a **reply** through `BargeReplay` (Moe talking): the machine is brought to
  `.speaking` with conversation mode and barge-in on, and the engine's host
  is emulated — word reports, the pre-pause judge (`BargeInJudge`: stop words
  and the name, the echo check against the sentence at the playhead, loudness
  against the session's reference), timers in virtual time.

The tuning under test is main's conversation mode: barge-in on, the fitted
evidence endpoint (`--before` for the old one). `--set` takes any field
`--turn-replay` takes, plus `bargeInHoldSeconds`, `interruptionWords`,
`interruptionWordsWhileSpeaking`.

### What it reports

Overall, per SNR, per category and (replies) per echo level:

| metric | definition |
|---|---|
| **cut-off** | of the pauses the person went on after, the share where the reply would have become audible before Moe could know they had (eot-bench's cut-off, commit reading) — with a Wilson 95% interval |
| **p50 / p90 ms** | true end of the turn → reply audible, instant brain (the pipeline's number) |
| **missed** (turns) | never decided before the file ran out |
| **ceiling** | ended by a clock that waited out a "not finished" |
| **false / 10 min** | reply paused or stopped with no real interruption (noise, echo, another voice, a backchannel), per 10 min of Moe audio that had none |
| **falseDuck / 10 min** | the same for the duck (cheap; reported, not gated) |
| **missed** (replies) | a stop word or real interruption and the reply not paused within 2 s of its first word |
| **stop p50 / p90** | its first word → the pause. **duck p50**: → the duck |
| **bc stops** | backchannels ("mm-hm", "yeah") that paused the reply |

Scoring is `CorpusScore` (MoeVoice); `CorpusScoreTests` pins every
definition to a hand-built case with its answer worked out in the comment.

### Approximations, said out loud

- **The recogniser over a reply is recorded live.** The engine's recogniser
  is off while Moe talks and is switched on, reset, with 0.5 s of pre-roll at
  an onset. So a reply scenario is recorded with `BargeReplay.Session`
  driving the real pipeline's recogniser as the engine would, under the
  tuning being recorded (the shipped one by default); the replay of that tape
  under the same tuning must land on the same pauses, and the bench prints
  that self-check. Replaying it under *another* `--set` is Tier 0: that
  tuning might have switched the recogniser differently. Confirm a winner
  live (`--rerecord --kind reply --set …`).
  The first version recorded the recogniser running throughout and
  re-based the word count at each onset. That was wrong: Parakeet's
  streaming transcript is a sliding window ("…ound three italian places
  near…"), so over a long reply the count stopped rising and a real "stop"
  went uncounted — 89% of real interruptions "missed". Kept only as
  `continuousAsr` for hand-written tapes.
- **Turn tapes do not depend on how busy the Mac is.** Events are stamped
  with audio time, and the recogniser and VAD run inside the pipeline's own
  ingest, so the same file gives the same tape: 30 of 30 tapes recorded at
  load ~175 and again at load ~300 were identical, event for event and probe
  for probe. Smart Turn's answer time in the replay is a fixed 60 ms
  (`--inference-ms`), not the measured one, for the same reason.
- **A fixed timeline.** The echo carries on in the file after a duck or a
  pause, so scoring stops at the first pause. The duck's −14 dB is not
  applied to the echo either (the echo is louder than it would be: errs
  towards false stops).
- **Echo is a simulation** of the canceller's residual (level and 30 ms
  delay), not VPIO. Tier 2 (a real room, needs the owner) checks it.
- **Synthetic voices.** TTS has strong turn-hold cues and weak turn-yield
  cues; the numbers rank settings, their absolute values are not believed
  until checked on real speech (research-eval-harness.md §4.2).
- **No owner enrolment**: the owner-voice score is absent, as on a fresh
  install (the owner gate is shadow by default anyway).
- **No music bed**, and the other-talker bed is read speech (LibriSpeech).
