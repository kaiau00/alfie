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
    "hey mom", "hey mom", "hey mode", "hey mode", "hey mobile", "hey mobile",
    "hey bro", "hey bro", "hey no", "hey no", "hey joe", "hey joe", "moe", "moe",
    "hey more", "hey motion", "hey moment", "hey mona", "hey mo bile", "hey home",
    "hey though", "hey yo", "hey mo tion", "they know", "hey mow it", "hey moses",
    "hey moldy", "hey money", "hey monday", "hey most", "hey mote", "hey moth",
    "hey mole", "hey mold", "hey mona lisa", "hey mo mo", "hey noah", "hey rosa",
    "okay mom", "hey mom can you", "hey mo bye", "hey mo nah", "hey moan", "hey mow down",
    "hey mo's", "hey boat", "hey go", "hey so", "hey bow", "hey dough", "hey low", "hey no way",
]
config = load_config("hey-moe.yaml")
backend = PiperVitsBackend.from_config(config)
out = pathlib.Path("output/hey_moe")
n_train = int(sys.argv[1]) if len(sys.argv) > 1 else 6000
n_test = int(sys.argv[2]) if len(sys.argv) > 2 else 800
# `n_samples` is the END index (the generator loops start_index..n_samples).
# Resume from what is on disk: the synthesiser leaks and runs in slices.
def existing(split, first):
    return sum(1 for f in (out / split).glob("clip_??????.wav") if int(f.stem[5:]) >= first)

start = 15000 + existing("negative_train", 15000)
if start < 15000 + n_train:
    backend.synthesize_clips(phrases, out / "negative_train", 15000 + n_train, start_index=start, batch_size=50)
start = 3000 + existing("negative_test", 3000)
if start < 3000 + n_test:
    backend.synthesize_clips(phrases, out / "negative_test", 3000 + n_test, start_index=start, batch_size=50)
print("done")
