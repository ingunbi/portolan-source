#!/usr/bin/env python3
"""MAIN.EXE sound effects (FMDRV.COM effect channel, INT 66h AH 5/6/7) - decoder and OPL2 renderer.

usage:
  sfx.py voices              the 8 effect voices DS:0xB48..0xBE2, decoded (music.md §5.2 format)
  sfx.py list                every effect: voice, note, timing script, trigger sites
  sfx.py check               render all in memory, print length / level / pitch facts; exit 1 on a
                             silent or implausible effect
  sfx.py render [NAME ...]   -> assets/sfx/<name>.wav (16-bit mono 44.1 kHz) + assets/sfx/index.json

Run with a Python that has numpy + scipy (`python3 -I tools/sfx.py render`); `voices` and `list`
need neither.  Spec: docs/re/sfx.md.

The game drives one OPL2 channel (driver struct 4 = OPL channel 4, operator slots 9/12) through
four MAIN.EXE wrappers: 0x95BE(bx = DS voice) = AH 5 AL 0, 0x965A(al = note) = AH 6 AL 0 (only with
option bit [0xC30] & 8), 0x96DE = AH 5 null voice (mute) + AH 7 on both effect channels, and the
countdown wait 0x5958(ticks) (FMDRV timer 1, 60.31 Hz).  This script replays those calls against
tools/mml.py's driver model (same note, voice and software-LFO code as the music) and renders the
register log with mml.Synth, with two changes that matter for effects (FxSynth below):
  - the self-feedback modulator is iterated sample by sample at the chip rate (49716 Hz) instead of
    the steady-state table, so FB 6/7 voices come out as noise as on the chip;
  - an operator with DR 0, SL 0 and EGT 0 leaves the decay phase at once and falls at RR while the
    key is held (as the chip does); mml.Synth keeps it at full level.
"""
import json, math, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAIN = ROOT + "/original/GAME/MAIN.EXE"
OUT = ROOT + "/assets/sfx"
MUSIC_INDEX = ROOT + "/assets/music/index.json"
DS = 0x378B0                          # DS:0 in the MAIN.EXE load image
TIMER_HZ = mml.TIMER_HZ               # 291.304 Hz driver interrupt
WAIT_HZ = TIMER_HZ * 0x35 / 256       # 60.31 Hz countdown timers ([0x122]/[0x123] += 0x35)
LFO_HZ = TIMER_HZ * 0x36 / 256        # 61.44 Hz software LFO ([0x120] += 0x36)
CHIP_SR = 49716                       # OPL2 sample rate (14.31818 MHz / 288)
OUT_SR = 44100                        # 49716 * 1225 / 1381
RING_MAX = 6.0                        # seconds emulated for a note the game leaves keyed on
FX_CH = 4                             # MAIN.EXE only ever uses effect channel AL = 0 = OPL ch 4

# ------------------------------------------------------------------ data

VOICES = {                            # DS offset -> what uses it (all 8 records, 22 bytes apart)
    0xB48: "duel: miss",
    0xB5E: "duel: hit",
    0xB74: "naval battle: cannon (shot fired, shell lands)",
    0xB8A: "naval battle: boarding melee",
    0xBA0: "village search: treasure found",
    0xBB6: "port arrival: sailing level up",
    0xBCC: "sea event alarm",
    0xBE2: "storm (wind, held for the whole storm)",
}

# Effect scripts, in the game's own calls:
#   ("voice", ds)  0x95BE  AH 5: silence ch 4, load the voice, volume 0, LFO armed
#   ("note", n)    0x965A  AH 6: key on note n (n + voice transpose, pitch as music.md §5.1)
#   ("wait", k)    0x5958  k ticks of the 60.31 Hz countdown
#   ("mute",)      0x96DE  AH 5 null voice (silence, TL 0x3F, struct reset) + AH 7 ch 0/1
#   ("ring",)      the game leaves the note keyed on: render until it has decayed
#   ("loop",)      the game holds the note until the storm ends: render intro + one LFO cycle
EFFECTS = [
    dict(name="cannon", script=[("voice", 0xB74), ("note", 0x24), ("ring",)],
         moment="naval battle volley: shot leaves the ship, and again when it lands",
         sites=[("0xC636", "0xC583 cannonball flight (start), every volley 0xCAFB with attacker or target in view"),
                ("0xCB72", "0xCAFB volley, target cell in view: burst / water spout animation")],
         note="not muted; the next effect or the second shot cuts it"),
    dict(name="boarding", script=[("voice", 0xB8A), ("note", 0x30), ("wait", 48), ("mute",)],
         moment="naval battle boarding melee (sabre clash animation)",
         sites=[("0xCFF2", "0xCEF6 boarding animation, every boarding 0xE6F5; muted at 0xD0D9")],
         note="48 = 3 passes x 8 frames x 2 ticks with both cells in view; 16 ticks less per pass "
              "whose cell is out of view (0 when none is visible)"),
    dict(name="duel_hit", script=[("voice", 0xB5E), ("note", 0x30), ("ring",)],
         moment="duel exchange that hits (step 3 of 4)",
         sites=[("0x11FF1", "0x11E80 duel exchange, step 3, hit")],
         note="not muted"),
    dict(name="duel_miss", script=[("voice", 0xB48), ("note", 0x30), ("ring",)],
         moment="duel exchange without a hit - miss, parry or dodge (step 3 of 6)",
         sites=[("0x11FF7", "0x11E80 duel exchange, step 3, no hit")],
         note="not muted"),
    dict(name="level_up", script=[("voice", 0xBB6), ("note", 0x3C), ("wait", 20), ("mute",)],
         moment="sailing level up announced on port arrival (admiral or a mate)",
         sites=[("0x1B6B0", "0x1B5E8 level-up message (msg 1077/1078), called by port arrival 0x1B6EE")],
         note="after the stat-gain messages, before the wait for a key"),
    dict(name="treasure", script=[("voice", 0xBA0), ("note", 0x3C), ("ring",)],
         moment="village 보물탐색 finds a treasure (category 0) - with the find picture",
         sites=[("0x34192", "0x340FD village search, find of category 0 (보물) only")],
         note="not muted; other find categories (natives, animals, plants, ruins, monsters, nature) are silent"),
    dict(name="sea_event", script=[("voice", 0xBCC), ("note", 0x30), ("wait", 30), ("mute",), ("wait", 20),
                                   ("voice", 0xBCC), ("note", 0x30), ("wait", 30), ("mute",)],
         moment="sea event (monster / ghost ship / whirlpool ...) before 'Admiral, look at the sea!'",
         sites=[("0x30615", "0x305DE sea event presentation, first blast"),
                ("0x3063A", "0x305DE, second blast")],
         note="sea_events.md §4"),
    dict(name="storm", script=[("voice", 0xBE2), ("note", 0x30), ("loop",)],
         moment="storm: starts with the storm, loops until it ends (port arrival, storm end, holy oil, BGM off)",
         sites=[("0x1941B", "0x193F4 storm begins"),
                ("0x84DE", "0x837D sea screen rebuilt (after battle, load, info screens, leaving port) while [0xC3F]&15 == 1"),
                ("0x165D6", "0x16588 after loading a game in a storm"),
                ("0x20DC0", "0x20D83 environment: BGM switched on during a storm")],
         note="stopped by 0x96DE at 0x1980E (storm over), 0x1B70E (port arrival), 0x29152 (holy oil), "
              "0x20DDA (BGM off), 0x165C8 (load), 0x17041 (game end); any other effect replaces it"),
]


def load_ds(path=MAIN):
    """DS segment bytes of the MAIN.EXE load image (no capstone needed)."""
    b = open(path, "rb").read()
    lastp, pages, _, hdrp = struct.unpack_from("<4H", b, 2)
    size = (pages - 1) * 512 + (lastp or 512)
    return b[hdrp * 16:size][DS:]


def voice_fields(r):
    """Decoded 22-byte voice record (music.md §5.2)."""
    ops = []
    for i in range(2):
        r20, r40, r60, r80, re0 = r[0 + i], r[5 + i], r[7 + i], r[9 + i], r[3 + i]
        ops.append(dict(am=r20 >> 7, vib=r20 >> 6 & 1, egt=r20 >> 5 & 1, ksr=r20 >> 4 & 1,
                        mult=mml.MULT[r20 & 15], ksl=r40 >> 6, tl=r40 & 63, ar=r60 >> 4, dr=r60 & 15,
                        sl=r80 >> 4, rr=r80 & 15, wave=re0 & 3))
    return dict(mod=ops[0], car=ops[1], fb=r[2] >> 1 & 7, additive=r[2] & 1, transpose=mml.s8(r[11]),
                lfo=dict(on=r[21], speed=r[12] | r[13] << 8, wave=["saw", "square", "triangle", "s&h", "ramp"][r[14]]
                         if r[14] < 5 else r[14], pitch=mml.s8(r[15]), range=r[16] & 15, amp=mml.s8(r[17]),
                         sens=(r[18] & 15, r[19] & 15), delay=r[20]))


def op_str(o):
    return (f"x{o['mult']:g} TL{o['tl']:2d} KSL{o['ksl']} AR{o['ar']:2d} DR{o['dr']:2d} SL{o['sl']:2d} RR{o['rr']:2d} "
            f"EGT{o['egt']} KSR{o['ksr']} AM{o['am']} VIB{o['vib']} W{o['wave']}")


RANGE_TXT = ["4c", "6c", "10c", "14c", "20c", "40c", "1st", "2st", "4st", "5st", "7st", "8st", "9st", "12st", "14st", "18st"]


def voice_text(ds, p):
    r = ds[p:p + 22]
    f = voice_fields(r)
    l = f["lfo"]
    return (f"DS:0x{p:03X}  {r.hex(' ')}\n"
            f"   mod {op_str(f['mod'])}\n   car {op_str(f['car'])}\n"
            f"   FB {f['fb']} {'additive' if f['additive'] else 'FM'}  transpose {f['transpose']:+d}  "
            f"LFO {'on' if l['on'] else 'off'}: {l['wave']} speed {l['speed']} pitch {l['pitch']:+d}/127 x "
            f"{RANGE_TXT[l['range']]} amp {l['amp']:+d}/127 sens {l['sens']} delay {l['delay']}\n"
            f"   use: {VOICES.get(p, '?')}")


# ------------------------------------------------------------------ driver model

class FxDriver(mml.Driver):
    """FMDRV with only effect channel 0 (struct 4, OPL ch 4) in use; no song playing."""

    def __init__(self, ds):
        self.d = ds
        self.loop_flag = False
        self.log = []; self.t = 0.0; self.notes = []; self.tempos = []
        self.tempo = 0; self.inc = 0; self.acc = 0; self.lacc = 0; self.tacc = 0
        self.gcount = 0; self.rand = 0x037D; self.bd = 0; self.ticks = 0; self.active = False
        self.regs = [0] * 256
        self.n = 0                    # PIT interrupts so far
        self.timer = 0                # FMDRV countdown timer 1 ([0x126])
        self.lfo_trace = []           # (time, lval, ldir) after every LFO tick
        self.w(0x01, 0x20); self.w(0x08, 0x40); self.w(0xBD, 0x00)    # 0x12CF
        self.fx = mml.Chan(FX_CH)
        self.fx.reset(); self.silence(self.fx)                          # 0x12E1
        self.chans = [self.fx]        # the LFO tick 0x120E walks channels 0-5; 0-3 are idle here

    def interrupt(self):              # one INT 08h (0x1DE)
        self.t = self.n / TIMER_HZ
        self.lacc += 0x36
        lfo = self.lacc > 0xFF
        self.lacc &= 0xFF
        self.tacc += 0x35
        if self.tacc > 0xFF:
            self.tacc &= 0xFF
            if self.timer:
                self.timer -= 1
        if lfo:
            self.lfo_tick()
            c = self.fx
            self.lfo_trace.append((self.t, c.lval, c.ldir))
        self.n += 1

    def now(self):
        self.t = self.n / TIMER_HZ

    # INT 66h effect API (0x3AF / 0x3F1 / 0x40C)
    def api_voice(self, p):           # AH 5
        c = self.fx
        self.now()
        self.silence(c)
        if not p:
            c.reset()                 # 0x8C2 (clears the voice pointer: LFO stops)
            self.w(0x40 + c.op, 0x3F); self.w(0x43 + c.op, 0x3F)
            c.ksl = [0x3F, 0x3F]
            return
        c.vol = 0
        c.flags |= 8
        self.load_voice(c, p)

    def api_note(self, n):            # AH 6
        if n > 0x5F:
            return
        c = self.fx
        self.now()
        c.flags &= 0x9D
        self.note(c, n)
        c.flags &= 0xDD

    def api_off(self):                # AH 7
        self.now()
        self.key_off(self.fx)

    def run(self, script):
        """Play a script; returns dict(total, loopStart, loopEnd, marks)."""
        info = dict(loopStart=None, loopEnd=None, marks=[])
        for ev in script:
            op = ev[0]
            if op == "voice":
                self.api_voice(ev[1])
            elif op == "note":
                self.api_note(ev[1])
                info["marks"].append(("on", self.t))
            elif op == "mute":
                self.api_voice(0)
                self.api_off()
                info["marks"].append(("mute", self.t))
            elif op == "wait":
                self.timer = ev[1]
                while self.timer:
                    self.interrupt()
                self.now()
            elif op == "ring":
                end = self.n + int(RING_MAX * TIMER_HZ)
                while self.n < end:
                    self.interrupt()
            elif op == "loop":
                # one full cycle of the voice's software LFO (the only thing that changes while the
                # note is held), starting at the first LFO tick 1.2 s after key on (attack done)
                t0 = self.t
                tr = self.lfo_trace
                i0 = None
                while True:
                    self.interrupt()
                    if i0 is None:
                        if len(tr) >= 2 and tr[-2][0] >= t0 + 1.2:
                            i0 = len(tr) - 2
                    elif len(tr) - 2 > i0 and tr[-2][1:] == tr[i0][1:] and tr[-1][1:] == tr[i0 + 1][1:]:
                        info["loopStart"], info["loopEnd"] = tr[i0][0], tr[-2][0]
                        break
                    if self.t > 120:
                        raise RuntimeError("LFO does not cycle")
                for _ in range(int(0.3 * TIMER_HZ)):
                    self.interrupt()
        if script[-1][0] == "mute":
            for _ in range(int(0.05 * TIMER_HZ)):     # 50 ms of silence after the cut
                self.interrupt()
        self.now()
        info["total"] = self.t
        return info


# ------------------------------------------------------------------ synthesis

class FxSynth(mml.Synth):
    def envelope(self, n, att0, ar, dr, sl, rr, egt, t_off):
        np = self.np
        att = super().envelope(n, att0, ar, dr, sl, rr, egt, t_off)
        if dr == 0 and sl == 0 and not egt and rr and ar:
            # chip: decay ends at once (attenuation already at SL 0), EGT 0 -> falls at RR while held
            sr = self.sr
            ta = mml.rate_time(ar, mml.ATTACK_MS)
            t_att = 0.0 if ta == 0.0 or att0 <= 0.1875 else math.log(max(att0, 0.1875) / 0.1875) / (math.log(96 / 0.1875) / ta)
            i0 = int(math.ceil(t_att * sr))
            stop = n if t_off is None else min(n, t_off)
            if i0 < stop:
                tr = mml.rate_time(rr, mml.DECAY_MS)
                t = (np.arange(i0, n) - i0) / sr
                fall = np.minimum(96.0, t * 96.0 / tr)
                att[i0:stop] = fall[:stop - i0]
                if t_off is not None and t_off < n:
                    base = att[t_off - 1] if t_off > i0 else att[t_off]
                    att[t_off:] = np.minimum(96.0, base + (np.arange(n - t_off) / sr) * 96.0 / tr)
        return att

    def feedback_op(self, pm, am, w, fb):
        """Self-modulating operator, iterated per chip sample:
        phase += (y[n-1] + y[n-2]) * 2^(FB-7) cycles, y = level * wave."""
        np = self.np
        k = 2.0 ** (fb - 7)
        n = len(pm)
        out = np.empty(n)
        y1 = y2 = 0.0
        sin, tau = math.sin, 2 * math.pi
        pml, aml = pm.tolist(), am.tolist()
        for i in range(n):
            th = pml[i] + k * (y1 + y2)
            s = sin(tau * th)
            if w:
                if w == 1:
                    s = s if s > 0 else 0.0
                elif w == 2:
                    s = abs(s)
                else:
                    s = abs(s) if (th % 0.5) < 0.25 else 0.0
            y = aml[i] * s
            out[i] = y
            y2 = y1; y1 = y
        return out

    def segment(self, out, s, total, att0):
        """mml.Synth.segment with the per-sample feedback operator."""
        np = self.np
        sr = self.sr
        i0 = int(round(s["t0"] * sr))
        m1, m2 = s["r20"]
        rr = [s["r80"][0] & 15, s["r80"][1] & 15]
        fnum, block = s["fn0"]
        end = total if s["cut"] is None else s["cut"]
        if s["off"] is not None:
            rel = max(self.release_len(mml.eff_rate(r, m & 0x10, fnum, block)) for r, m in zip(rr, (m1, m2)))
            end = min(end, s["off"] + rel + 0.01)
        end = min(end, total)
        s["end"] = end
        n = int(round(end * sr)) - i0
        if n <= 0:
            return [96.0, 96.0]
        n = min(n, len(out) - i0)
        f = self.piecewise(n, i0, [(t, mml.note_hz(fn, bl)) for t, fn, bl in s["freq"]], sr)
        tg = (i0 + np.arange(n)) / sr
        bd = s["bd"]
        vib_cents = 14.0 if bd & 0x40 else 7.0
        trem_db = 4.8 if bd & 0x80 else 1.0
        tri = lambda hz: 2 * np.abs(((tg * hz) % 1.0) - 0.5)
        ops = []
        t_off = None if s["off"] is None else int(round(s["off"] * sr)) - i0
        atts = []
        for i, (r20, r60, r80) in enumerate(zip(s["r20"], s["r60"], s["r80"])):
            ff = f
            if r20 & 0x40:
                ff = f * 2 ** ((tri(6.07) * 2 - 1) * vib_cents / 1200)
            ph = np.cumsum(ff) / sr * mml.MULT[r20 & 15]
            ar = mml.eff_rate(r60 >> 4, r20 & 0x10, fnum, block)
            dr = mml.eff_rate(r60 & 15, r20 & 0x10, fnum, block)
            rrr = mml.eff_rate(r80 & 15, r20 & 0x10, fnum, block)
            env = self.envelope(n, att0[i], ar, dr, r80 >> 4, rrr, r20 & 0x20, t_off)
            atts.append(env[-1])
            tl = self.piecewise(n, i0, s["tl"][i], sr)
            att = env + 0.75 * tl
            if s["ksl"][i]:
                att = att + self.piecewise(n, i0, [(t, mml.ksl_db(s["ksl"][i], fn, bl)) for t, fn, bl in s["freq"]], sr)
            if r20 & 0x80:
                att = att + trem_db * tri(3.7)
            amp = np.where(att >= 96, 0.0, 10 ** (-att / 20))
            ops.append((ph, amp))
        (pm, am), (pc, ac) = ops
        fbk = (s["c0"] >> 1) & 7
        wm, wc = s["we"]
        ym = self.feedback_op(pm, am, wm, fbk) if fbk else am * self.wave(wm, pm)
        if s["c0"] & 1:
            y = ym + ac * self.wave(wc, pc)
        else:
            y = ac * self.wave(wc, pc + 4.0 * ym)
        k = min(n, int(0.001 * sr))
        if k > 1:
            y[:k] *= 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, k))
        k = min(n, int(0.003 * sr))
        if k > 1 and s["cut"] is not None and s["cut"] <= end + 1e-9:
            y[-k:] *= 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, k))
        out[i0:i0 + n] += y
        return atts


def bank_gain():
    """The music bank's gain, so effects and songs keep the original FM mix level."""
    try:
        return json.load(open(MUSIC_INDEX))["gain"]
    except (OSError, KeyError, ValueError):
        return 0.516491


def render_effect(ds, e):
    """-> (samples at 44.1 kHz, info)."""
    import numpy as np
    from scipy.signal import resample_poly
    drv = FxDriver(ds)
    info = drv.run(e["script"])
    syn = FxSynth(CHIP_SR)
    y = syn.render(drv.log, info["total"])
    y = resample_poly(y, 1225, 1381)
    sr = OUT_SR
    pk = float(np.max(np.abs(y))) or 1.0
    ls, le = info["loopStart"], info["loopEnd"]
    if ls is not None:
        # seamless loop [ls, le): the last X before le crossfades into the X before ls
        s, e_ = int(round(ls * sr)), int(round(le * sr))
        X = int(0.08 * sr)
        a = np.linspace(0, np.pi / 2, X)
        y[e_ - X:e_] = y[e_ - X:e_] * np.cos(a) + y[s - X:s] * np.sin(a)
        y = y[:e_]
        info["loopStart"], info["loopEnd"] = round(s / sr, 6), round(e_ / sr, 6)
        info["loopSamples"] = (s, e_)
    elif e["script"][-1][0] == "ring":
        # cut where it has decayed below -60 dB of its peak (20 ms fade)
        env = np.maximum.accumulate(np.abs(y[::-1]))[::-1]
        live = np.nonzero(env > pk * 10 ** (-60 / 20))[0]
        stop = min(len(y), (live[-1] + 1) if len(live) else len(y))
        y = y[:stop]
        k = min(len(y), int(0.02 * sr))
        y[-k:] *= np.linspace(1, 0, k)
    return y, dict(info, raw_peak=pk, notes=[(t, nid, fn, bl) for t, _, nid, fn, bl, _ in drv.notes],
                   lfo_ticks=len(drv.lfo_trace))


def script_text(script):
    out = []
    for ev in script:
        if ev[0] == "voice": out.append(f"voice DS:0x{ev[1]:03X}")
        elif ev[0] == "note": out.append(f"note 0x{ev[1]:02X}")
        elif ev[0] == "wait": out.append(f"wait {ev[1]} ({ev[1] / WAIT_HZ:.3f} s)")
        else: out.append(ev[0])
    return ", ".join(out)


def effect_entry(e, ds, info=None, fname=None):
    v = e["script"][0][1]
    n = next(x[1] for x in e["script"] if x[0] == "note")
    tr = mml.s8(ds[v + 11])
    nid = n + tr
    fn, bl = mml.FNUM[nid % 12], min(7, nid // 12)
    d = dict(name=e["name"], file=fname, moment=e["moment"],
             voice=f"DS:0x{v:03X}", note=n, pitchHz=round(mml.note_hz(fn, bl), 1),
             script=script_text(e["script"]),
             sites=[dict(addr=a, what=w) for a, w in e["sites"]], remark=e["note"])
    if info:
        d["duration"] = round(info["len"], 3)
        d["loopStart"] = info["loopStart"]
        d["loopEnd"] = info["loopEnd"]
    return d


def cmd_render(names, check_only=False):
    import numpy as np
    ds = load_ds()
    sel = [e for e in EFFECTS if not names or e["name"] in names]
    gain = bank_gain()
    ok = True
    entries = {}
    if not check_only:
        os.makedirs(OUT, exist_ok=True)
    for e in sel:
        y, info = render_effect(ds, e)
        y = mml.soft_clip(y * gain)
        info["len"] = len(y) / OUT_SR
        pk = float(np.max(np.abs(y)))
        rms = float(np.sqrt(np.mean(y ** 2)))
        # active span: 10 ms frames within 40 dB of the loudest frame
        fr = int(0.01 * OUT_SR)
        m = len(y) // fr
        frms = np.sqrt(np.mean(y[:m * fr].reshape(m, fr) ** 2, axis=1)) if m else np.zeros(1)
        act = np.nonzero(frms > frms.max() * 0.01)[0]
        span = (act[-1] - act[0] + 1) * 0.01 if len(act) else 0.0
        spec = np.abs(np.fft.rfft(y * np.hanning(len(y))))
        fq = np.fft.rfftfreq(len(y), 1 / OUT_SR)
        cent = float(np.sum(fq * spec) / max(1e-12, np.sum(spec)))
        dc = float(np.mean(y))
        bad = []
        if pk < 0.05: bad.append("silent")
        if not 0.1 <= info["len"] <= 30: bad.append("length")
        if abs(dc) > 0.02: bad.append("dc")
        if pk > 0.99: bad.append("clips")
        loop = f" loop {info['loopStart']:.3f}-{info['loopEnd']:.3f}s" if info["loopStart"] is not None else ""
        hz = [mml.note_hz(fn, bl) for _, _, fn, bl in info["notes"]]
        print(f"{e['name']:10s} {info['len']:6.3f}s{loop} peak {20 * math.log10(max(pk, 1e-9)):6.1f} dBFS "
              f"rms {20 * math.log10(max(rms, 1e-9)):6.1f} dBFS active {span:5.2f}s centroid {cent:6.0f} Hz "
              f"key {', '.join(f'{h:.0f}' for h in hz)} Hz lfo ticks {info['lfo_ticks']}"
              + (("  PROBLEM: " + ", ".join(bad)) if bad else ""), flush=True)
        ok &= not bad
        fname = f"{e['name']}.wav"
        if not check_only:
            mml.write_wav(f"{OUT}/{fname}", y, OUT_SR)
        entries[e["name"]] = effect_entry(e, ds, info, fname)
        if info["loopStart"] is not None:
            # the loop body alone: seamless with AVAudioPlayer.numberOfLoops = -1
            a, b = info["loopSamples"]
            lname = f"{e['name']}_loop.wav"
            if not check_only:
                mml.write_wav(f"{OUT}/{lname}", y[a:b], OUT_SR)
            entries[e["name"]]["loopFile"] = lname
    if not check_only:
        path = OUT + "/index.json"
        old = {}
        if os.path.exists(path):
            for x in json.load(open(path)).get("effects", []):
                old[x["name"]] = x
        old.update(entries)
        order = [e["name"] for e in EFFECTS if e["name"] in old]
        with open(path, "w") as f:
            f.write('{"source": "MAIN.EXE effect voices DS:0xB48-0xBF7 via tools/sfx.py (docs/re/sfx.md)",\n'
                    f' "sampleRate": {OUT_SR}, "gain": {gain:.6f},\n'
                    ' "channel": "one effect channel: a new effect cuts the previous one; mute (0x96DE) stops it",\n'
                    ' "option": "played only with option bit [0xC30] & 8 (sound effects, default on, no UI)",\n'
                    ' "effects": [\n')
            f.write(",\n".join("  " + json.dumps(old[k], ensure_ascii=False) for k in order))
            f.write("\n ]\n}\n")
    print("OK" if ok else "PROBLEMS")
    return ok


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "voices":
        ds = load_ds()
        for p in sorted(VOICES):
            print(voice_text(ds, p))
    elif cmd == "list":
        ds = load_ds()
        for e in EFFECTS:
            d = effect_entry(e, ds)
            print(f"{d['name']:10s} {d['voice']} note 0x{d['note']:02X} ({d['pitchHz']} Hz)  {d['script']}")
            print(f"           {d['moment']}")
            for s in d["sites"]:
                print(f"           {s['addr']:>8s}  {s['what']}")
            print(f"           ({d['remark']})")
    elif cmd == "check":
        sys.exit(0 if cmd_render(args, check_only=True) else 1)
    elif cmd == "render":
        sys.exit(0 if cmd_render(args) else 1)
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
