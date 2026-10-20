# Training "Hey Moe"

How `Resources/WakeWord/hey-moe.onnx` (+ `hey-moe.json`) was made, and how to
make it again. Design and findings: VOICE-PLAN.md §4.1 and the Phase 4 status
in §8. Pipeline: [livekit-wakeword](https://github.com/livekit/livekit-wakeword)
0.2.1 (Apache-2.0), run on a Mac with no Homebrew.

These scripts were written for one working directory (`W` at the top of each,
a session scratchpad) — set that one variable to wherever you unpack this and
they work unchanged. Layout under `W`:

```
venv/                 python3.12 venv: pip install "livekit-wakeword[train,export,eval]==0.2.1" espeakng-loader
bin/espeak-ng         espeak-ng-shim.py, chmod +x — the trainer shells out to `espeak-ng --ipa`
espeak-home/          copy of venv/.../espeakng_loader/espeak-ng-data with a self-symlink `espeak-ng-data -> .`
ca-bundle.pem         certifi + `security find-certificate -a -p` of the keychains (huggingface.co is TLS-intercepted here)
~/nltk_data/corpora/  cmudict, fetched with curl — `nltk.download` cannot get it
                      through the interception and reports "Security Violation",
                      which is what it says when it receives the proxy's page
                      instead of a zip. `generate` needs it for grapheme-to-
                      phoneme and dies on the first clip without it:
                      curl -sSL -o cmudict.zip https://raw.githubusercontent.com/nltk/nltk_data/gh-pages/packages/corpora/cmudict.zip && unzip -o cmudict.zip
train/hey-moe.yaml    the config; train/run.sh runs a stage with the shim and the CA bundle on the environment
train/data/           setup output: piper checkpoint, RIRs, MUSAN noise, LibriSpeech WAVs (flac2wav.py)
train/output/hey_moe  the clips, features, checkpoints, metrics, ONNX
bench/                held-out sets: LibriSpeech dev-clean (FLAC), positive/ and confusable/ from `say` (make_clips.sh)
```

Stages, in order (`run.sh <stage>`; `detach.sh <stage>` runs it in its own
session; `supervise.py <stage> <slice-seconds>` restarts a resumable stage every
slice because the Piper synthesiser leaks ~1 GB per thousand clips):

1. `setup --skip-acav` — Piper checkpoint, validation features, RIRs, MUSAN.
   No ACAV100M (CC-BY-NC-SA; see VOICE-PLAN.md §10).
2. `flac2wav.py` LibriSpeech test-clean, test-other, dev-other into
   `train/data/librispeech-*` (the `background_paths` in the yaml). dev-clean
   is never trained on: it is the false-accept bench.
3. `python patch_augment.py` — patches the venv's augment.py: negatives
   end-aligned half the time, noise mixed after alignment. Without it the head
   learns "silence, then speech begins" (head v1).
4. `supervise.py generate 420` — positives, adversarial negatives, background
   crops. Then `onset_negatives.py` (LibriSpeech utterance starts as
   negatives) and `supervise.py py 300 hard_negatives.py` (Piper clips of the
   phonetic neighbours).
5. `augment` — two rounds of RIR/EQ/noise, then feature extraction.
6. `train`, `export` — ~45 min for 100k steps on an M3.
7. Bench: `Moe --wake-bench Resources/WakeWord bench/positive bench/confusable`
   and the same over `bench/LibriSpeech/dev-clean`, both with
   `MOE_WAKE_TRACE=1` into trace files; `sweep_policy.py <traces>
   --hours-negative H` replays the runtime policy for a grid of threshold /
   run length / strong threshold.
8. `install_head.py <hits> <strong> <threshold>` copies the ONNX into
   `Resources/WakeWord` and writes the sidecar the app reads.

`ref_scores.py` and `stage_timing.py` check the Swift port (`Moe --wake-score`,
`--wake-slide`) against LiveKit's reference runtime on their own fixture.

## v6 (2026-09-23): Inworld voices, AMI, on a Fly machine

v6 was trained on a temporary Fly performance-16x (32 GB, CPU only), about
7 h and ≈ $5, and the machine was torn down afterwards. What changed from
v5, with the reason for each in `research-wakeword.md`:

- **Inworld TTS clips from 282 voices** (`~/moe-wake-data`, `gen_clips.py`).
  `prep_inworld.py` splits them **by voice** and holds out 32 voices,
  stratified by accent or language. Those voices form the bench and never
  reach training. It also trims the training half. `fold_inworld.py` adds
  what is left:
  - positives ×2, and the short ones get speech after them;
  - near misses ×2;
  - the same voices' ordinary sentences, as 1.9 s negative windows ×2.
- **The owner's recordings** go in through `real_clips.py` (`WAKE_REC`,
  `WAKE_W`), repeated to ≈ 20% of positive_train (`WAKE_REAL_TIMES=130`).
  The held-out third is the same as v5's.
- **AMI meetings** (ES20xx, CC-BY 4.0; `ami_negatives.py`) are added to
  `background_paths`. They are the background class and also the babble
  mixed under every class. ES2004 and ES2011 are left out.
- **Every class gets the same processing:**
  - `codec_pass.py` gives 30% of the originals an MP3/Opus round-trip;
  - `patch_augment2.py` adds a low-pass filter, a level change, and SNR
    from −5 to 30 dB.

**On a Fly machine** (`fly/`):

- The build context is this directory:
  `flyctl machine run . --dockerfile fly/Dockerfile --vm-size performance-16x --volume wake_data:/data --restart on-failure`.
- `fly/run_all.sh` is the job. It runs as the machine's CMD, with a marker
  per stage, and waits for `extra.tgz` (Inworld clips + recordings), which
  you upload with `flyctl ssh sftp put`. Build that tarball with
  `COPYFILE_DISABLE=1 tar`: macOS tar adds `._*` files, and the fold choked
  on them.
- `WORKDIR` must not be under the volume mount. The mount is empty at boot,
  so every process fails to spawn.

**Benching:**

- `bench_head.sh <head> <set> <dirs…>` writes one trace per set.
- `compare_heads.py v5 v6 [--best] [--at thr:hits:strong …]` replays the
  runtime policy over them. It reports:
  - recall on the owner, held-out and all 65;
  - recall on the Inworld held-out voices;
  - false fires on near misses;
  - false accepts per hour on dev-clean and on AMI test meetings
    (`get_ami_bench.sh`).
- v6's scores are compressed, with a ceiling near 0.85, so it is compared
  with v5 at equal false-accept budgets, never at one threshold.
