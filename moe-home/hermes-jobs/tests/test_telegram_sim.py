"""A randomized walk of `telegram.py items` over many looks (the fourth
review's simulation, 2026-09-25): Telegram's real id schemes (one shared
counter for private chats and basic groups, one per supergroup/channel),
pinned chats first, messages landing mid-walk, the state through JSON every
look, and a Mac clock ahead of Telegram's. Every message in a conversation
must come out, eventually; none may be lost. (A chat forgotten by the
pruning of `d` may be read twice — the engine keeps one copy by id.)
"""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "telegram_under_sim", os.path.join(HERE, "..", "..", "connectors", "telegram.py"))
import json, random, sys
from datetime import datetime, timezone
from types import SimpleNamespace as NS
tg = None


def dt(s): return datetime.fromtimestamp(int(s), timezone.utc)

class Msg:
    def __init__(s, id, date):
        s.id=id; s.date=dt(date); s.message="m%d"%id; s.text=s.message
        s.sender_id=7; s.out=False; s.sender=None; s.mentioned=False

class Chat:
    def __init__(s, cid, kind, pinned):
        s.id=cid; s.kind=kind; s.pinned=pinned; s.msgs=[]; s.next=1

class Fake:
    def __init__(s, rng, n, skew=0):
        s.rng=rng; s.gid=1000; s.chats=[]; s.clock=10_000.0; s.skew=skew
        for i in range(n):
            kind=rng.choice(["user","user","basic","super","channel"])
            c=Chat(i+1 if kind!="channel" else -(i+1), kind, rng.random()<0.05)
            s.chats.append(c)
            s.post(c, date=1000+rng.random()*5000)   # history before first look
        s.during=[]
    def post(s, c, date=None):
        if c.kind in ("super","channel"): mid=c.next; c.next+=1
        else: mid=s.gid; s.gid+=1
        c.msgs.append(Msg(mid, s.clock if date is None else date))
    def order(s):
        live=[c for c in s.chats if c.msgs]
        live.sort(key=lambda c:(not c.pinned, -c.msgs[-1].date.timestamp(), -c.msgs[-1].id))
        return live
    def iter_dialogs(s, limit):
        for c in s.order()[:limit]:
            # a message may land mid-walk (after `now` was taken)
            if s.during and s.rng.random()<0.1:
                s.clock+=s.rng.random(); s.post(s.rng.choice(s.during))
            top=c.msgs[-1] if c.msgs else None
            yield NS(id=c.id, name="c%d"%c.id, date=top.date if top else None, message=top,
                     is_channel=c.kind in("super","channel"), is_group=c.kind in("basic","super"),
                     pinned=c.pinned)
    def iter_messages(s, cid, limit, reverse, min_id=0, offset_date=None):
        c=[x for x in s.chats if x.id==cid][0]
        ms=sorted(c.msgs, key=lambda m:m.id)
        if offset_date is not None: ms=[m for m in ms if m.date>offset_date]
        ms=[m for m in ms if m.id>min_id]
        return iter(ms[:limit])

def run(seed, n=60, looks=60, drain=80, skew=0, keep=None, raw=None, maxd=None, per=None):
    rng=random.Random(seed)
    if keep: tg.ITEMS_KEEP_CHATS=keep
    if raw: tg.ITEMS_MAX_RAW_DIALOGS=raw
    if maxd: tg.ITEMS_MAX_DIALOGS=maxd
    if per: tg.ITEMS_MAX_PER_DIALOG=per
    f=Fake(rng,n)
    state=None; seen={}
    nonbroad=[c for c in f.chats if c.kind!="channel"]
    def look(active):
        nonlocal state
        now=f.clock+skew
        if state is None:
            state={"t":now,"d":{},"more":[]}; return
        f.during=f.chats if active else []
        items,new=tg.items_from(f, state, None, now)
        f.during=[]
        for it in items: seen[it["id"]]=seen.get(it["id"],0)+1
        state=json.loads(json.dumps(new, sort_keys=True))
    look(False); f.clock+=5
    for L in range(looks):
        for _ in range(rng.choice([0,1,3,20,200])):
            f.clock+=rng.random()*3; c=rng.choice(f.chats); f.post(c)
        f.clock+=rng.random()*60
        look(True)
    before=-1
    for _ in range(drain):
        f.clock+=60; look(False)
        if not state["more"] and len(seen)==before: break
        before=len(seen)
    first=1000+5000  # anything posted by sim after first look
    miss=[];dup=[]
    for c in nonbroad:
        for m in c.msgs:
            k="telegram/%s/%s"%(c.id,m.id)
            if m.date.timestamp()>=6000.5 and k not in seen: miss.append(k)
    dup=[k for k,v in seen.items() if v>1]
    return miss,dup,state



def fresh_tg():
    mod = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(mod)
    return mod


class TelegramWalkSimulation(unittest.TestCase):
    CONFIGS = {"default": dict(), "tight": dict(maxd=3, per=4, n=30),
               "many chats": dict(maxd=3, per=4, n=80), "clock ahead": dict(skew=10)}

    def test_nothing_is_lost(self):
        global tg
        for name, cfg in self.CONFIGS.items():
            for seed in range(8):
                tg = fresh_tg()
                miss, dup, st = run(seed, looks=25, drain=3000, **cfg)
                self.assertEqual(miss, [], "%s seed %d" % (name, seed))
                self.assertEqual(st["more"], [], "%s seed %d" % (name, seed))

    def test_nothing_is_read_twice_while_chats_are_remembered(self):
        global tg
        for seed in range(8):
            tg = fresh_tg()
            miss, dup, st = run(seed, looks=25, drain=3000, maxd=3, per=4, n=30)
            self.assertEqual(dup, [], "seed %d" % seed)


if __name__ == "__main__":
    unittest.main()
