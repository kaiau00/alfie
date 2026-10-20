#!/bin/sh
"""":
# Re-exec under the training venv, found relative to this file rather than
# written into the shebang. The shebang used to be an absolute path into the
# scratchpad that made it, so a rebuilt environment inherited a shim pointing
# at a deleted interpreter — and the trainer reports that as
# "[Errno 2] No such file or directory: .../bin/espeak-ng", which reads as a
# missing shim rather than a missing python. sh runs the exec below; python
# sees the whole thing as a docstring and ignores it.
exec "$(dirname "$0")/../venv/bin/python" "$0" "$@"
"""
"""A stand-in for the espeak-ng CLI, enough for livekit-wakeword's
`espeak-ng --ipa -q -v <voice> <text>`: the same IPA string the real CLI
prints, from the library that espeakng-loader bundles (no Homebrew here)."""
import ctypes, sys
import espeakng_loader

args = sys.argv[1:]
voice = "en-us"
text_parts = []
i = 0
while i < len(args):
    a = args[i]
    if a == "-v":
        voice = args[i + 1]; i += 2; continue
    if a in ("--ipa", "-q", "-x", "--stdout"):
        i += 1; continue
    if a.startswith("--ipa="):
        i += 1; continue
    text_parts.append(a); i += 1
text = " ".join(text_parts)
if not text:
    text = sys.stdin.read()

lib = ctypes.cdll.LoadLibrary(espeakng_loader.get_library_path())
import os
# Beside this file, not an absolute path written when it was made. The
# library's own default points inside the machine that built the wheel
# ("/Users/runner/work/..."), so if this is wrong espeak-ng exits 1 and the
# trainer only says "Skipping 50 clips" — it keeps going, keeps reporting
# progress, and writes nothing.
data = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "espeak-home"))
if not os.path.isdir(data):
    sys.exit(f"espeak: no data directory at {data}")
os.environ.setdefault("ESPEAK_DATA_PATH", data)
AUDIO_OUTPUT_SYNCHRONOUS = 0x02
lib.espeak_Initialize.restype = ctypes.c_int
if lib.espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, data.encode(), 0) < 0:
    sys.exit("espeak_Initialize failed")
lib.espeak_SetVoiceByName.argtypes = [ctypes.c_char_p]
if lib.espeak_SetVoiceByName(voice.encode()) != 0:
    sys.exit(f"espeak: voice {voice} not found")
lib.espeak_TextToPhonemes.restype = ctypes.c_char_p
lib.espeak_TextToPhonemes.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_int, ctypes.c_int]

espeakCHARS_UTF8 = 1
espeakPHONEMES_IPA = 0x02
buf = ctypes.create_string_buffer(text.encode("utf-8"))
ptr = ctypes.c_void_p(ctypes.addressof(buf))
clauses = []
while ptr.value:
    out = lib.espeak_TextToPhonemes(ctypes.byref(ptr), espeakCHARS_UTF8, espeakPHONEMES_IPA)
    if out is None:
        break
    s = out.decode("utf-8").strip()
    if s:
        clauses.append(s)
sys.stdout.write("\n".join(clauses) + "\n")
