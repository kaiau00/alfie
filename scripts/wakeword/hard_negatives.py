"""Extra adversarial negatives for the phrase's phonetic neighbours — the
ones the second head still fired on — through the trainer's own Piper
backend, as extra negative_train/test originals (the augmenter picks up
any clip_NNNNNN.wav). Usage: hard_negatives.py"""
import os, pathlib, sys
W = pathlib.Path("/path/to/wake")
os.chdir(W / "train")
from livekit.wakeword.config import load_config
from livekit.wakeword.data.tts.piper_backend import PiperVitsBackend

phrases = [
    "hey alpha", "hey alpha", "hey elfie", "hey elfie", "hey ollie", "hey ollie",
    "hey allie", "hey allie", "hey albie", "hey albie", "alfie", "alfie",
    "hey alfred", "hey selfie", "hey taffy", "hey daffy", "hey half", "hey calf",
    "hey ralphie", "hey archie", "hey also", "hey after", "hey alvin", "hey elsie",
    "hey olivia", "hey al", "hey ali", "hey alley", "hey valley", "hey jeffy",
    "hey goofy", "hey toffee", "hey coffee", "hey office", "hey all fee",
    "hey elf", "hey alps", "hey alpha team", "okay alfie", "say alfie", "hey effie",
    "hey olfie", "hey ellie", "hey harvey", "hey laffy", "hey alfa romeo",
]
config = load_config("hey-alfie.yaml")
backend = PiperVitsBackend.from_config(config)
out = pathlib.Path("output/hey_alfie")
n_train = int(sys.argv[1]) if len(sys.argv) > 1 else 4000
n_test = int(sys.argv[2]) if len(sys.argv) > 2 else 500
# `n_samples` is the END index (the generator loops start_index..n_samples).
# Resume from what is on disk: the synthesiser leaks and runs in slices.
def existing(split, first):
    return sum(1 for f in (out / split).glob("clip_??????.wav") if int(f.stem[5:]) >= first)

start = 10000 + existing("negative_train", 10000)
if start < 10000 + n_train:
    backend.synthesize_clips(phrases, out / "negative_train", 10000 + n_train, start_index=start, batch_size=25)
start = 1800 + existing("negative_test", 1800)
if start < 1800 + n_test:
    backend.synthesize_clips(phrases, out / "negative_test", 1800 + n_test, start_index=start, batch_size=25)
print("done")
