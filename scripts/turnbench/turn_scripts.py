#!/usr/bin/env python3
"""The turn corpus's script: what each voice says, as a render plan.

    python3 turn_scripts.py [--voices inworld-voices.json] [--holdout holdout.json] > plan.json

No network and no key. The plan is rendered by ~/moe-wake-data/turn_corpus.py
(the one script allowed to call Inworld) and mixed by mix.py.

Voices are split the way the wake-word run split them, whole voices at a time:
  test  the 32 voices wake v6 held out (~/moe-wake-v6work/holdout.json) — the
        only voices the reported numbers come from;
  dev   12 English voices from the rest, for choosing thresholds, so a fitted
        setting is never chosen on the voices it is scored on;
  train everything else: nothing here renders it.

Each line is one of:
  single      a whole request, no pause                    (endpoint latency floor)
  pause       a complete clause, a pause, then more         (the cut-off the owner hits)
  filler      "um," / "uh," then a pause, then the rest
  and         "and…" then a pause, then the rest            (continuing intonation)
  correction  "no wait, I mean…"                             (FDB v3's hardest case)
  short       "yes", "no", "sure" — a whole turn            (review M3: a lone yes in noise)
  stop        "stop", "wait" — said over Alfie's reply
  interrupt   a real new request said over the reply (two or more words)
  backchannel "mm-hm", "yeah" over the reply — must NOT stop it
and Alfie's own replies, spoken by Alfie's Inworld voices (Clive, Ashley), which
mix.py plays back into the microphone as simulated echo and as the reply a
barge-in lands on.

Pauses are Inworld `<break time="…ms"/>` tags (continuous prosody across the
pause, which splicing does not keep). The tag's length is only the request:
mix.py reads the pause actually rendered back from the word timestamps.
"""
import argparse
import json
import pathlib
import random

HOME = pathlib.Path.home()
MODEL = "inworld-tts-2-flash"
PAUSES_MS = [500, 1000, 1500, 2500]

SINGLE = [
    "What's on my calendar tomorrow morning?",
    "How long will it take to drive to the airport right now?",
    "Remind me to take the chicken out of the freezer at five.",
    "What's the weather going to be like this weekend?",
    "Read me the last message from Sarah.",
    "Turn the volume down a little.",
    "Who won the game last night?",
    "Add a meeting with Priya on Thursday at two.",
    "How many ounces are in a cup?",
    "Find the receipt from the hardware store last week.",
]
PAUSE = [
    "Move my three o'clock to Friday,{P} and tell Sarah I'll be running late.",
    "Add milk and eggs to the shopping list,{P} and bread if we're out.",
    "Can you check the weather for Saturday{P} and see if it's going to rain?",
    "Text Dan that I'm on my way.{P} I'll be there in about twenty minutes.",
    "What time does the pharmacy close today?{P} The one on Main Street.",
    "I need to email the landlord about the heater.{P} It stopped working again last night.",
    "Look up a good Italian place near the office{P} that takes reservations for six.",
    "Put the dentist on my calendar for Tuesday.{P} Make it after lunch.",
]
FILLER = [
    "Can you find me, um,{P} a flight to Denver next Thursday?",
    "Remind me to, uh,{P} call the plumber in the morning.",
    "What was the name of that, hmm,{P} that podcast Rachel mentioned?",
    "Play something, um,{P} something relaxing for dinner.",
    "Schedule a call with, uh,{P} with the design team for Monday.",
]
AND = [
    "Book the table for seven, and…{P} ask if they have outdoor seating.",
    "Turn off the lights in the kitchen, and…{P} lock the front door.",
    "Tell mom I got the package, and…{P} that I'll call her this weekend.",
    "Summarise my unread emails, and then…{P} draft a reply to the one from Alex.",
]
CORRECTION = [
    "Send the file to John,{P} no wait, I mean send it to Jane.",
    "Put it on Tuesday,{P} sorry, Wednesday, at noon.",
    "Call Mike,{P} actually no, text him instead.",
]
SHORT = ["Yes.", "No.", "Sure.", "Yeah, go ahead.", "Nope.", "Okay, do it.", "That's right.", "Not yet."]
STOP = ["Stop.", "Wait.", "Hold on.", "No, stop.", "Alfie, stop.", "Stop, stop."]
INTERRUPT = [
    "Wait, actually, make it Tuesday instead.",
    "No no, I meant the other one.",
    "Hang on, can you repeat the address?",
    "Sorry, what was the second one?",
    "Actually, skip that, what about tomorrow?",
    "Hold on, that's not what I asked.",
]
BACKCHANNEL = ["Mm-hm.", "Yeah.", "Okay.", "Uh-huh.", "Right.", "Mhm.", "Yep.", "Sure."]

REPLIES = [
    "You have three things tomorrow. At nine there's the team stand-up, at eleven thirty a call with "
    "the accountant about the quarterly numbers, and at four you're picking up the kids from swimming. "
    "The afternoon is otherwise clear, so if you want to move the accountant, two o'clock is open.",
    "It'll be mostly sunny on Saturday with a high of seventy-two, and a light breeze in the afternoon. "
    "Sunday looks cooler and cloudier, around sixty-four, and there's a chance of showers after about "
    "three. If you're planning to be outside, Saturday is the better day.",
    "You have four unread emails. Alex sent the revised budget and wants your sign-off by Friday. "
    "The school says pickup is early on Wednesday. Your airline confirmed the seat change, and there's "
    "a newsletter from the running club you can probably skip.",
    "The fastest way is to take the highway north for about twelve miles, then exit at Park Avenue. "
    "Traffic is light right now, so it should take around twenty-five minutes. There's a slowdown near "
    "the bridge, but it's clearing, and parking is easiest on the second level.",
    "Sure. For the sauce you'll need two cans of crushed tomatoes, one onion, three cloves of garlic, "
    "olive oil, and a handful of basil. Soften the onion first, then add the garlic for a minute, then "
    "the tomatoes, and let it simmer for about twenty minutes before you season it.",
    "I found three Italian places near the office that take bookings for six. Lucca has a table at seven "
    "thirty, Nonna's has one at eight, and the place on Fifth can do six forty-five but only on the patio. "
    "Lucca has the best reviews of the three, and it's a short walk.",
]
MOE_VOICES = ["Clive", "Ashley"]


def pick(rng, pool, n):
    return rng.sample(pool, min(n, len(pool)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--voices", default=str(HOME / "moe-wake-data/inworld-voices.json"))
    ap.add_argument("--holdout", default=str(HOME / "moe-wake-v6work/holdout.json"))
    ap.add_argument("--dev", type=int, default=12)
    a = ap.parse_args()

    voices = json.loads(pathlib.Path(a.voices).read_text())
    held = set(json.loads(pathlib.Path(a.holdout).read_text())["voices"])
    by_id = {v["voiceId"]: v for v in voices}
    missing = held - set(by_id)
    if missing:
        raise SystemExit(f"held-out voices not in the catalogue: {sorted(missing)}")
    rng = random.Random(20260923)
    english_rest = sorted(v["voiceId"] for v in voices
                          if v["voiceId"] not in held and v["voiceId"] not in MOE_VOICES
                          and "en" in (v.get("languages") or []))
    dev = sorted(rng.sample(english_rest, a.dev))
    split = {**{v: "test" for v in held}, **{v: "dev" for v in dev}}

    rows = []

    def add(voice, cat, i, text):
        r = random.Random(f"{voice}-{cat}-{i}")
        rows.append({
            "id": f"{split.get(voice, 'moe')}-{voice}-{cat}-{i:02d}", "voice": voice,
            "split": split.get(voice, "moe"), "category": cat, "text": text, "model": MODEL,
            "temperature": round(r.uniform(0.8, 1.1), 2), "rate": round(r.uniform(0.9, 1.15), 2),
        })

    for voice in sorted(split):
        r = random.Random(voice)
        n = 0
        for t in pick(r, SINGLE, 3):
            add(voice, "single", n, t); n += 1
        paused = [("pause", t) for t in pick(r, PAUSE, 3)] + [("filler", t) for t in pick(r, FILLER, 2)] \
            + [("and", t) for t in pick(r, AND, 1)] + [("correction", t) for t in pick(r, CORRECTION, 1)]
        for k, (cat, t) in enumerate(paused):
            ms = PAUSES_MS[(k + len(voice)) % len(PAUSES_MS)]
            add(voice, cat, n, t.replace("{P}", f' <break time="{ms}ms"/>')); n += 1
        for cat, pool in (("short", SHORT), ("stop", STOP), ("interrupt", INTERRUPT), ("backchannel", BACKCHANNEL)):
            for t in pick(r, pool, 2):
                add(voice, cat, n, t); n += 1
    for voice in MOE_VOICES:
        for i, t in enumerate(REPLIES):
            add(voice, "reply", i, t)
    print(json.dumps(rows, indent=1))
    chars = sum(len(r["text"]) for r in rows)
    import sys
    counts = {}
    for r in rows:
        counts[(r["split"], r["category"])] = counts.get((r["split"], r["category"]), 0) + 1
    print(f"{len(rows)} lines, {chars} characters; {len(held)} test voices, {len(dev)} dev voices", file=sys.stderr)
    print(" ".join(f"{s}/{c}:{n}" for (s, c), n in sorted(counts.items())), file=sys.stderr)


if __name__ == "__main__":
    main()
