#!/usr/bin/env python3
"""D2.MML song bank (KOEI "OPL-II Sound Driver" FMDRV.COM v3.12) - decoder and OPL2 renderer.

usage:
  mml.py list N              static bytecode listing of song N (1..22), every channel
  mml.py voices              the 22-byte voice records referenced by the songs
  mml.py check               decode + emulate every song, report loops, durations, pitch sanity
  mml.py render [N ...]      render songs -> assets/music/songNN.m4a + index.json
         [--wav DIR]         keep the 16-bit WAVs in DIR (default: a temp dir, deleted)
         [--rate HZ]         output sample rate (default 44100)
         [--fade S]          fade length after the loop end (default 8)

Format, opcodes and driver internals: docs/re/music.md.

The sequencer below is a tick-exact re-implementation of the driver's interrupt handler
(PIT 291.3 Hz -> tempo ticks and 61.4 Hz LFO ticks) and produces the stream of OPL2 register
writes the driver would send.  The renderer turns that register log into audio with a small
2-operator FM model (numpy).  Parsing/emulation is pure Python; only `render` needs numpy.
"""
import json, math, os, shutil, struct, subprocess, sys, tempfile, wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BANK = ROOT + "/original/GAME/D2.MML"
OUT = ROOT + "/assets/music"

# ------------------------------------------------------------------ driver constants (FMDRV.COM)

TIMER_HZ = 1193181.8 / 4096          # PIT channel 0 divisor 0x1000 (0x131C)
OPL_HZ = 14318180 / 288              # YM3812 sample rate, fnum -> Hz
FNUM = [0x157, 0x16B, 0x181, 0x198, 0x1B0, 0x1CA, 0x1E5, 0x202, 0x220, 0x241, 0x263, 0x287]  # 0x63C
SEMI = [0x0000, 0x079C, 0x0FAD, 0x1838, 0x2145, 0x2ADC, 0x3505, 0x3FC8, 0x4B2F, 0x5744,
        0x6411, 0x71A1, 0x7FFF]                                     # 0x602: (2^(n/12)-1)*0x7FFF
LFO_DEPTH = [0x004C, 0x0072, 0x00BE, 0x010A, 0x017D, 0x02FE, 0x079C, 0x0FAD, 0x2145, 0x2ADC,
             0x3FC8, 0x4B2F, 0x5744, 0x7FFF, 0x9F58, 0xEA08]        # 0x61C
OPOFF = [0, 1, 2, 8, 9, 10]          # operator slot of channel n (channel struct +0x27)
MUSIC_CH = 4                         # melodic channels per song (OPL ch 0-3); 5th = rhythm

# what plays each song (MAIN.EXE play routine 0x94C6 maps a game index through DS:0x9608)
SCENES = {
    1: "port: East Asia and Southeast Asia (trade zones 11-12)",
    2: "at sea: Joan / Joao Franco (hero 0); also his theme in events",
    3: "at sea: Catalina Erantzo (hero 1); also her theme in events",
    4: "at sea: Otto Baltes (hero 2)",
    5: "at sea: Al Vezas (hero 5)",
    6: "at sea: Pietro Conti (hero 4)",
    7: "at sea: Ernst von Bohr (hero 3)",
    8: "port: Ottoman / Middle East (trade zones 4, 9)",
    9: "port: Africa and the New World (trade zones 3, 5-8)",
    10: "port: India (trade zone 10)",
    11: "port: Europe (trade zones 0-2: Iberia, northern Europe, Mediterranean)",
    12: "naval battle won - fanfare, played once (loop off)",
    13: "supply port (ports 100+)",
    14: "naval battle",
    15: "after a won naval battle (enemy flagship sunk / surrendered), follows song 12",
    16: "palace (audience with the king)",
    17: "game over (lost battle, shipwreck, no crew, retirement); also scenario events",
    18: "game start-up (new game / continue) and story events (scenario bgm 3)",
    19: "ending (END.EXE keeps its own copy of this song)",
    20: "tavern; scenario scripts return to it after events",
    21: "opening / title (OPEN.EXE keeps its own copy of this song)",
    22: "ending staff roll (END.EXE keeps its own copy of this song)",
}


# MAIN.EXE play-music index (argument of 0x94C6, scenario opcode `bgm`) -> D2 song, table DS:0x9608
GAME_INDEX = {song: idx for idx, song in enumerate(
    [21, 19, 22, 18, 2, 3, 4, 7, 6, 5, 11, 9, 8, 10, 1, 13, 14, 15, 16, 20, 17, 12])}
NO_LOOP = {12}                       # index 0x15: MAIN.EXE calls API 4 (loop off) after starting it


def s8(x):
    return x - 256 if x & 0x80 else x


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def tdiv(a, b):
    """x86 IDIV: truncate toward zero."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def load(path=BANK):
    return open(path, "rb").read()


def song_table(d):
    """song n (1-based) -> [ch0, ch1, ch2, ch3, rhythm] absolute offsets or None.
    The table is 10-byte entries; each u16 is relative to the start of its own entry."""
    # The driver has no song count; the table simply stops where the voice records begin.
    # Stop at the first entry whose pointers cannot be channel data.
    songs = {}
    lowest = len(d)
    e = 0
    while e + 10 <= lowest:
        w = struct.unpack_from("<5H", d, e)
        ptrs = [(x + e) & 0xFFFF if x else None for x in w]
        if not w[0] or any(p is not None and not e + 10 <= p < len(d) for p in ptrs):
            break
        songs[e // 10 + 1] = ptrs
        lowest = min([lowest] + [p for p in ptrs if p])
        e += 10
    return songs


def table_end(d):
    return 10 * len(song_table(d))


# ------------------------------------------------------------------ voice record (22 bytes)

def voice_str(d, p):
    """0-10: OPL regs 20,23,C0,E0,E3,40,43,60,63,80,83; 11 transpose; 12-21 software LFO."""
    r = d[p:p + 22]
    return (f"@{p:04x} regs " + " ".join(f"{b:02x}" for b in r[:11]) +
            f" | tr {s8(r[11]):+d} lfo spd {r[12] | r[13] << 8} wave {r[14]} pitch {s8(r[15])}/{r[16] & 15}"
            f" amp {s8(r[17])} ({r[18] & 15},{r[19] & 15}) delay {r[20]} on {r[21]}")


# ------------------------------------------------------------------ static decoder

MEL_ARGS = {0xEE: 1, 0xEF: 1, 0xF0: 1, 0xF1: 1, 0xF2: 1, 0xF3: 1, 0xF4: 2, 0xF5: 2, 0xF6: 2,
            0xF7: 2, 0xF8: 0, 0xF9: 0, 0xFA: 0, 0xFB: 0, 0xFC: 0, 0xFD: 0, 0xFE: 0, 0xFF: 0}
NAMES = ["c", "c+", "d", "d+", "e", "f", "f+", "g", "g+", "a", "a+", "b"]


def note_name(n):
    return f"o{n // 12}{NAMES[n % 12]}"


def decode(d, p):
    """Linear decode of one melodic channel from p up to and including its FF.
    Returns [(pos, size, text)], end position (after FF)."""
    out = []
    gate = 0x2D
    while True:
        b = d[p]
        if b <= 0x5F:
            gate = d[p + 2]
            out.append((p, 3, f"{note_name(b)} len {d[p + 1]} gate {gate}" if gate
                        else f"rest len {d[p + 1]} ({note_name(b)})"))
            p += 3
            continue
        if b <= 0xBF:
            out.append((p, 1, note_name(b - 0x60) if gate else "rest"))
            p += 1
            continue
        if b <= 0xCF:
            out.append((p, 1, f"nop {b:02x}"))
            p += 1
            continue
        if b <= 0xDF:
            out.append((p, 1, "repeat [" if b == 0xD0 else f"] x{(b & 15) + 1}"))
            p += 1
            continue
        if b <= 0xED:
            out.append((p, 2, f"ignored {b:02x} {d[p + 1]:02x}"))
            p += 2
            continue
        n = MEL_ARGS[b]
        a = d[p + 1:p + 1 + n]
        if b == 0xEE: t = f"AM depth {a[0] & 1}"
        elif b == 0xEF: t = f"VIB depth {a[0] & 1}"
        elif b == 0xF0: t = f"vol(att) {a[0] & 0x7F}"
        elif b == 0xF1: t = f"tempo(timerB) {a[0]} -> {(78125 // (18 * (256 - a[0]))) & 0xFF}"
        elif b == 0xF2: t = f"tempo {a[0]}"
        elif b == 0xF4: t = f"voice @{(p + struct.unpack_from('<H', d, p + 1)[0]) & 0xFFFF:04x}"
        elif b == 0xF6: t = f"slide {s8(a[0]):+d} semis over {a[1] or 256} ticks"
        elif b == 0xF7: t = f"slide {s8(a[0]):+d} semis over {a[1] + 1} lfo ticks"
        elif b == 0xF8: t = "lfo on"
        elif b == 0xF9: t = "lfo off"
        elif b == 0xFD: t = "break on last repeat"
        elif b == 0xFE: t = "loop point"
        elif b == 0xFF: t = "end"
        else: t = f"ignored {b:02x} " + " ".join(f"{x:02x}" for x in a)
        out.append((p, 1 + n, t))
        p += 1 + n
        if b == 0xFF:
            return out, p


# ------------------------------------------------------------------ driver emulation

class Chan:
    """Melodic channel struct (0x4A4 + 0x2E*i).  Field names follow the struct offsets."""

    def __init__(self, idx):
        self.ch = idx                 # +0x26 OPL channel
        self.op = OPOFF[idx]          # +0x27 operator slot
        self.ksl = [0x3F, 0x3F]       # +0x28/29 shadow of regs 40/43
        self.a0 = 0                   # +0x2A shadow A0
        self.b0 = 0                   # +0x2B shadow B0
        self.ext_att = 0              # +0x2C (API 0x80)
        self.ext_tr = 0               # +0x2D (API 0x81)
        self.reset()

    def reset(self):                  # 0x8C2
        self.ptr = 0; self.loop = 0; self.vol = 0; self.cnt = 1; self.gcnt = 0
        self.flags = 1; self.last = 0xFF; self.L = 0x30; self.G = 0x2D
        self.rcnt = 0; self.rstart = 0; self.rexit = 0
        self.freq = 0; self.tl = [0, 0]; self.am = [0, 0]; self.voice = 0
        self.transpose = 0; self.lf = 0; self.speed = 0; self.depth = 0
        self.lcnt = 0; self.ldir = 1; self.lval = 0
        # bookkeeping for the analyser (not in the driver)
        self.t_start = None; self.t_loop = None; self.t_end = None; self.passes = 0


class Driver:
    def __init__(self, data, song, loop=True):
        self.d = data
        self.loop_flag = loop
        self.log = []                 # (time, reg, val)
        self.t = 0.0
        self.notes = []               # (time, ch, note, fnum, block)
        self.tempos = []              # (time, tempo)
        self.tempo = 0; self.inc = 0; self.acc = 0; self.lacc = 0
        self.gcount = 0               # 0x5E6 free running LFO-tick counter
        self.rand = 0x037D            # 0x5E8
        self.bd = 0                   # 0x600
        self.ticks = 0                # 0x5EA
        self.active = True
        self.chans = [Chan(i) for i in range(MUSIC_CH)]
        self.regs = [0] * 256
        # 0x12CF: chip init at install time
        self.w(0x01, 0x20); self.w(0x08, 0x40); self.w(0xBD, 0x00)
        for c in self.chans:
            self.silence(c)
        ptrs = song_table(data)[song]
        if ptrs[4]:
            raise NotImplementedError("rhythm channel not supported (unused in D2.MML)")
        for c, p in zip(self.chans, ptrs):        # 0x2B0
            c.reset()
            c.ptr = c.loop = p or 0
        self.w(0xBD, 0)
        self.set_tempo(0x78)

    # -- chip access
    def w(self, reg, val):
        self.regs[reg] = val
        self.log.append((self.t, reg, val))

    # -- low level routines
    def write_tl(self, c, i, t):      # 0x7B6
        level = (~t) & 0x3F
        red = (level * c.am[i]) // 0x7F
        level = max(0, level - (red & 0xFF))
        v = ((~level) & 0x3F) | (c.ksl[i] & 0xC0)
        if v != c.ksl[i]:
            c.ksl[i] = v
            self.w(0x40 + c.op + 3 * i, v)

    def write_freq(self, c, f):       # 0x7E6
        lo, hi = f & 0xFF, (f >> 8) & 0xDF
        if (c.a0 | (c.b0 & 0xDF) << 8) == (lo | hi << 8):
            return
        c.a0 = lo
        self.w(0xA0 + c.ch, lo)
        c.b0 = (c.b0 & 0x20) | hi
        self.w(0xB0 + c.ch, c.b0)

    def key_on(self, c):              # 0x68C
        if c.ext_att & 0x80:
            return
        c.b0 |= 0x20
        self.w(0xB0 + c.ch, c.b0)
        c.flags |= 0xC0
        c.lf |= 3

    def key_off(self, c):             # 0x6AE
        c.b0 &= 0xDF
        self.w(0xB0 + c.ch, c.b0)
        c.flags &= 0x5F
        c.lf &= 0xBF

    def silence(self, c):             # 0x6CA
        c.a0 = c.b0 = 0
        self.w(0xA0 + c.ch, 0); self.w(0xB0 + c.ch, 0)
        self.w(0x80 + c.op, 0x0F); self.w(0x83 + c.op, 0x0F)
        self.w(0x40 + c.op, 0x3F); self.w(0x43 + c.op, 0x3F)
        c.ksl = [0x3F, 0x3F]
        c.flags &= 0x1F
        c.lf &= 0xBF

    def apply_vol(self, c, vol):      # 0x989
        a = min(0x7F, vol + (c.ext_att & 0x7F)) >> 1
        if not c.voice:
            return
        v = self.d[c.voice:c.voice + 22]
        dh = v[2] | 2
        for i in range(2):
            t = v[5 + i] & 0x3F
            if dh & 1:
                t = min(0x3F, t + a)
            dh >>= 1
            c.tl[i] = t
            self.write_tl(c, i, t)

    def reset_vol(self, c):           # 0x9E6
        c.am = [0, 0]
        self.apply_vol(c, c.vol)

    def set_tempo(self, t):           # 0x817
        if not t:
            return
        self.tempo = t
        self.inc = (t * 18000 // 100) & 0xFFFF
        self.acc = 0
        self.tempos.append((self.t, t))

    def load_voice(self, c, p):       # 0xA17 / 0xA1E
        d = self.d
        c.voice = p
        self.silence(c)
        v = d[p:p + 22]
        regs = [0x20 + c.op, 0x23 + c.op, 0xC0 + c.ch, 0xE0 + c.op, 0xE3 + c.op, 0x40 + c.op,
                0x43 + c.op, 0x60 + c.op, 0x63 + c.op, 0x80 + c.op, 0x83 + c.op]
        for r, x in zip(regs, v):    # 0x75A
            self.w(r, x)
        c.ksl = [v[5], v[6]]
        c.transpose = s8(v[11])
        c.lf &= 0x7F
        c.flags &= 0xFB
        if v[21]:
            c.flags |= 4
            if c.flags & 8:
                c.lf |= 0x80
                c.lcnt = 0; c.lval = 0; c.ldir = 1
        self.reset_vol(c)

    def slide_cmd(self, c, s, n):     # 0xAAE
        c.speed = 0x8000 // n
        c.lf &= 0xFB
        if s & 0x80:
            s = (-s) & 0xFF
            c.lf |= 4
        if s > 12:
            s = 0
        c.depth = SEMI[s]
        c.lcnt = 0; c.lval = 0; c.ldir = 1
        c.flags |= 2
        self.write_freq(c, c.freq)    # 0xB18
        self.reset_vol(c)

    # -- note (0xC31)
    def note(self, c, note):
        if c.G == 0:
            c.last = 0xFF
            if c.flags & 0x80:
                self.key_off(c)
        else:
            n = note + c.transpose + s8(c.ext_tr)
            q, r = tdiv(n, 12), n - 12 * tdiv(n, 12)
            if 0 <= n <= 0xFF:
                block, semi, nid = q, r, n
                if q > 7:
                    block, nid = 7, r + 0x54
            else:
                block, semi = 0, (r + 12 if r else 0)
                nid = semi
            if c.flags & 0x20 and nid == c.last:
                pass                                   # tie into the same note
            else:
                legato = bool(c.flags & 0x20)
                if not legato and c.flags & 0x80:
                    self.key_off(c)
                c.last = nid
                f = FNUM[semi] | block << 10
                self.write_freq(c, f)
                c.freq = f
                self.notes.append((self.t, c.ch, nid, FNUM[semi], block, legato))
                if not legato:
                    self.key_on(c)
                c.lf &= 0xBF
            if c.flags & 2:
                c.lf |= 0x40
        c.cnt = c.L
        c.gcnt = c.G
        c.flags &= 0xDD
        if c.G > c.L:
            c.flags |= 0x20

    # -- command parser (0xBF1)
    def parse(self, c):
        d = self.d
        p = c.ptr
        if c.t_start is None:
            c.t_start = self.t
        while p:
            b = d[p]; p += 1
            if b <= 0x5F:
                c.L, c.G = d[p], d[p + 1]
                p += 2
                c.ptr = p
                self.note(c, b)
                return p
            if b <= 0xBF:
                c.ptr = p
                self.note(c, b - 0x60)
                return p
            if b <= 0xCF:
                continue
            if b <= 0xDF:                              # 0x951 repeat
                n = b & 15
                if n == 0:
                    if c.rstart == 0:
                        c.rstart = p
                    continue
                if c.rstart == 0:
                    continue
                if c.rcnt == 0:
                    c.rcnt = n + 1
                    c.rexit = p
                c.rcnt = (c.rcnt - 1) & 0xFF
                if c.rcnt:
                    p = c.rstart
                else:
                    c.rstart = 0
                continue
            if b <= 0xED:
                p += 1
                continue
            if b == 0xEE:
                self.bd = (self.bd & 0x7F) | (d[p] & 1) << 7; p += 1
                self.w(0xBD, self.bd)
            elif b == 0xEF:
                self.bd = (self.bd & 0xBF) | (d[p] & 1) << 6; p += 1
                self.w(0xBD, self.bd)
            elif b == 0xF0:
                c.vol = d[p] & 0x7F; p += 1
                self.apply_vol(c, c.vol)
            elif b == 0xF1:
                self.set_tempo((78125 // (18 * (256 - d[p]))) & 0xFF); p += 1
            elif b == 0xF2:
                self.set_tempo(d[p]); p += 1
            elif b in (0xF3,):
                p += 1
            elif b == 0xF5:
                p += 2
            elif b == 0xF4:
                vp = (struct.unpack_from("<H", d, p)[0] + p - 1) & 0xFFFF
                p += 2
                self.load_voice(c, vp)
            elif b == 0xF6:
                s, n = d[p], d[p + 1] or 256; p += 2
                cx = (self.tempo or 1) << 4
                ax = max(1, (n * 1250) // cx)
                self.slide_cmd(c, s, ax)
            elif b == 0xF7:
                s, n = d[p], d[p + 1] + 1; p += 2
                self.slide_cmd(c, s, n)
            elif b == 0xF8:
                if not c.lf & 0x80:
                    c.flags |= 8
                    if c.flags & 4:
                        c.lf |= 0x83
            elif b == 0xF9:
                if c.lf & 0x80:
                    c.flags &= 0xF7
                    c.lf &= 0x7F
                    if c.flags & 0xC0:
                        self.write_freq(c, c.freq)
                        self.reset_vol(c)
            elif b == 0xFD:
                if c.rcnt == 1:
                    c.rcnt = 0; c.rstart = 0
                    p = c.rexit
            elif b == 0xFE:
                c.loop = p
                if c.t_loop is None:
                    c.t_loop = self.t
            elif b == 0xFF:
                self.key_off(c)
                if c.t_end is None:
                    c.t_end = self.t
                c.passes += 1
                p = 0
                if self.loop_flag and not c.flags & 1:
                    self.ticks = 0
                    c.L, c.G, c.cnt, c.gcnt, c.rcnt, c.rstart = 0x30, 0x2D, 1, 0, 0, 0
                    p = c.loop
        c.ptr = 0
        return 0

    def chan_tick(self, c):           # 0xBCD
        if not c.ptr:
            return
        c.cnt = (c.cnt - 1) & 0xFF
        if c.cnt == 0:
            c.ptr = self.parse(c)
            c.flags &= 0xFE
        elif c.gcnt:
            c.gcnt -= 1
            if c.gcnt == 0:
                self.key_off(c)

    def seq_tick(self):               # 0xCD8
        if not self.active:
            return
        for c in self.chans:
            self.chan_tick(c)
        self.ticks += 1
        if not any(c.ptr for c in self.chans):
            self.active = False
            self.inc = 0

    # -- LFO / slide (0x120E, 61.4 Hz)
    def wave_value(self, c, v):       # 0x107E
        wt = self.d[c.voice + 14]
        if wt > 4:
            wt = 0
        if wt == 0:                   # saw 0xFE7
            ax, cf = self.step(c)
            if cf:
                c.lval = s16(-c.lval)
        elif wt == 1:                 # square 0x1029
            cx = 0x7FFF // c.speed
            ax = 0x7FFF if (c.lcnt // cx) % 2 == 0 else -0x8000
            c.lval = ax
        elif wt == 2:                 # triangle 0xFF0
            a = s16(((c.speed << 1) & 0xFFFF) * c.ldir)
            old = c.lval
            c.lval = s16(c.lval + a)
            if (old ^ c.lval) < 0 and (c.ldir ^ c.lval) < 0:
                c.lval = s16(c.lval - a)
                c.ldir = -c.ldir
            ax = c.lval
        elif wt == 3:                 # sample & hold 0x104A
            cx = (0x7FFF // c.speed) | 1
            ax = self.rand
            if tdiv(s16(c.lcnt), cx) * cx == s16(c.lcnt):
                self.rand = (self.rand * 0x383) % 0x7FFF
                ax = self.rand
        else:                         # one-shot ramp 0x1014
            ax = self.ramp(c)
        if ax == -0x8000:
            ax = -0x7FFF
        return ax

    def step(self, c):                # 0xFCE
        a = s16(c.speed * c.ldir)
        old = c.lval
        c.lval = s16(c.lval + a)
        if (old ^ c.lval) < 0:
            c.lval = s16(c.lval - a)
            return c.lval, True
        return c.lval, False

    def ramp(self, c):                # 0x1014
        if c.lval == 0x7FFF:
            return 0x7FFF
        ax, cf = self.step(c)
        if cf:
            c.lval = 0x7FFF
        return c.lval

    def pitch(self, c, cx):           # 0x10A5
        fn, blk = c.freq & 0x3FF, c.freq & 0x1C00
        if cx >= 0:
            ax = (fn * cx) // 0x7FFF
            ax = (ax * c.depth) // 0x7FFF
            ax += fn
            while ax > 0x3FF:
                if blk >= 0x1C00:
                    blk, ax = 0x1C00, 0x3FF
                    break
                blk += 0x400
                ax >>= 1
        else:
            r = (-cx * c.depth) // 0x7FFF
            ax = (fn * 0x7FFF) // (r + 0x7FFF)
        f = (ax & 0xFFFF) | blk
        self.write_freq(c, f)
        return f

    def lfo_tick(self):
        for c in self.chans:
            if c.lf & 0x40:                            # pitch slide
                v = self.ramp(c)
                if c.lf & 4:
                    v = -v
                f = self.pitch(c, v)
                if c.lval == 0x7FFF:
                    c.freq = f
                    c.lf &= 0xBF
            elif c.voice:
                self.lfo_step(c)
        self.gcount = (self.gcount + 1) & 0xFFFF

    def lfo_step(self, c):            # 0x1178
        v = self.d[c.voice:c.voice + 22]
        if not c.lf & 0x80:
            c.lcnt = (c.lcnt + 1) & 0xFFFF
            return
        if c.flags & 0xC0:
            c.depth = LFO_DEPTH[v[16] & 15]
            c.speed = v[12] | v[13] << 8
            if c.speed == 0:
                c.lf |= 3
                c.lcnt = (c.lcnt + 1) & 0xFFFF
                return
        else:
            c.lf |= 3
            c.lcnt = (c.lcnt + 1) & 0xFFFF
            return
        st = c.lf & 3
        if st == 0:
            c.lcnt = (c.lcnt + 1) & 0xFFFF
            return
        if st == 1:
            c.lcnt = (c.lcnt - 1) & 0xFFFF
            if c.lcnt:
                return
            c.lcnt = 0; c.lval = 0; c.ldir = 1
        elif st == 3:
            c.lf = (c.lf & 0xFC) | 1
            dl = v[20]
            if dl == 0 and v[14] != 4:
                c.lcnt = self.gcount
            elif dl > 1:
                c.lcnt = (((dl - 1) * 4) + 1) & 0xFFFF
                return
            else:
                c.lcnt = 0; c.lval = 0; c.ldir = 1
        c.lf = (c.lf & 0xFC) | 2
        val = self.wave_value(c, v)
        # pitch 0x1098
        cx = tdiv(val * s8(v[15]), 0x7F)
        self.pitch(c, cx)
        # amplitude 0x110D
        wt = v[14]
        if wt == 4:
            ax = (val << 1) & 0xFFFF
        elif wt == 1:
            ax = 0xFFFF if val < 0 else 0
        elif wt == 2:
            ax = abs(val) & 0xFFFF
        else:
            ax = val & 0xFFFF
        dd = s8(v[17])
        if dd < 0:
            ax ^= 0xFFFF
        m = (ax * (abs(dd) & 0x7F)) // 0xFFFE
        for i in range(2):
            c.am[i] = ((m * (v[18 + i] & 15)) // 15) & 0xFF
            self.write_tl(c, i, c.tl[i])
        c.lcnt = (c.lcnt + 1) & 0xFFFF

    # -- interrupt loop
    def run(self, until=None, max_seconds=900.0):
        """Run until every channel has finished its first pass (or `until` seconds)."""
        n = 0
        while True:
            self.t = n / TIMER_HZ
            if until is not None and self.t >= until:
                break
            if until is None and (all(c.t_end is not None for c in self.chans if c.loop)
                                  or not self.active):
                break
            if self.t > max_seconds:
                raise RuntimeError("song does not end")
            self.acc += self.inc
            if self.acc > 0xFFFF:
                self.acc &= 0xFFFF
                self.seq_tick()
            self.lacc += 0x36
            if self.lacc > 0xFF:
                self.lacc &= 0xFF
                self.lfo_tick()
            n += 1
        return self


# ------------------------------------------------------------------ analysis

def analyse(d, song):
    """Emulate one pass; returns dict with loop info and stats."""
    drv = Driver(d, song, loop=True).run()
    used = [c for c in drv.chans if c.loop]
    ends = [c.t_end for c in used]
    # FF jumps back to the last FE, or to the channel start when there is none
    loops = [c.t_start if c.t_loop is None else c.t_loop for c in used]
    return dict(song=song, drv=drv, channels=len(used), end=max(ends), loop=max(loops),
                ends=ends, loops=loops, marker=any(c.t_loop is not None for c in used),
                tempos=[t for k, (_, t) in enumerate(drv.tempos[1:]) if k == 0 or drv.tempos[k][1] != t])


def note_hz(fnum, block):
    return fnum * OPL_HZ / (1 << (20 - block))


# ------------------------------------------------------------------ synthesis (numpy)

MULT = [0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 12, 12, 15, 15]
ATTACK_MS = [math.inf] + [2826.24 / 2 ** (r - 1) for r in range(1, 15)] + [0.0]
DECAY_MS = [math.inf] + [39280.64 / 2 ** (r - 1) for r in range(1, 16)]


KSLROM = [0x00, 0x20, 0x28, 0x2D, 0x30, 0x33, 0x35, 0x37, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40]


def ksl_db(bits, fnum, block):
    """key scale level attenuation (YM3812: 0, 3, 1.5, 6 dB/oct for bits 0..3)."""
    if not bits:
        return 0.0
    k = max(0, KSLROM[fnum >> 6] * 4 - (8 - block) * 32)     # 0.1875 dB units
    return (k >> {1: 1, 2: 2, 3: 0}[bits]) * 0.1875


def eff_rate(r, ksr, fnum, block):
    if r == 0:
        return 0
    k = block * 2 + ((fnum >> 8) & 1)      # NTS=1 (reg 08 = 0x40)
    return min(63, 4 * r + (k if ksr else k >> 2))


def rate_time(rate, table):
    """seconds for a full 96 dB sweep at an effective rate (0..63)."""
    if rate == 0:
        return math.inf
    q, f = divmod(rate, 4)
    q = min(q, 15)
    if table is ATTACK_MS and rate >= 60:
        return 0.0
    return table[q] / 1000.0 * 4.0 / (4 + f)


def dc_block(x, sr, fc=12.0):
    """AC coupling of the sound card output: one-pole high-pass."""
    import numpy as np
    r = 1 - 2 * math.pi * fc / sr
    try:
        from scipy.signal import lfilter
        return lfilter([1, -1], [1, -r], x)
    except ImportError:                       # numpy only: block-wise recursion
        y = np.empty_like(x)
        prev_x = prev_y = 0.0
        B = 4096
        k = r ** np.arange(1, B + 1)
        for i in range(0, len(x), B):
            seg = x[i:i + B]
            dx = np.diff(np.concatenate(([prev_x], seg)))
            n = len(seg)
            # y[j] = sum_{m<=j} r^(j-m) dx[m] + r^(j+1) prev_y
            y[i:i + n] = np.cumsum(dx / k[:n]) * k[:n] + prev_y * k[:n]
            prev_x, prev_y = seg[-1], y[i + n - 1]
        return y


class Synth:
    fbtab = {}                        # (wave, fb) -> feedback shape table, shared

    def __init__(self, sr):
        import numpy as np
        self.np = np
        self.sr = sr

    def wave(self, w, ph):
        np = self.np
        s = np.sin(2 * np.pi * ph)
        if w == 0:
            return s
        if w == 1:
            return np.maximum(s, 0)
        if w == 2:
            return np.abs(s)
        q = (ph % 0.5) < 0.25
        return np.where(q, np.abs(s), 0.0)

    def feedback_table(self, w, fb):
        """Steady-state single-cycle shapes of a self-modulating operator,
        rows = effective feedback g in [0, 2] (64 steps), 256 phase points.
        OPL: phase += (y[n-1] + y[n-2]) * 2^(fb-7) cycles; with y = a*yhat: g = a*2^(fb-6)."""
        key = (w, fb)
        if key in self.fbtab:
            return self.fbtab[key]
        np = self.np
        G, P = 64, 256
        g = np.linspace(0, 2.0, G)
        y1 = np.zeros(G); y2 = np.zeros(G)
        out = np.zeros((G, P))
        cyc = 24
        for n in range(P * cyc):
            th = (n % P) / P + 0.5 * g * (y1 + y2)
            y = self.wave(w, th)
            y2, y1 = y1, y
            if n >= P * (cyc - 1):
                out[:, n % P] = y
        self.fbtab[key] = out
        return out

    def envelope(self, n, att0, ar, dr, sl, rr, egt, t_off):
        """attenuation in dB for n samples; t_off = key-off sample index or None."""
        np = self.np
        sr = self.sr
        t = np.arange(n) / sr
        ta = rate_time(ar, ATTACK_MS)
        td = rate_time(dr, DECAY_MS)
        tr = rate_time(rr, DECAY_MS)
        sl_db = 93.0 if sl == 15 else sl * 3.0
        att = np.empty(n)
        # attack
        if ar == 0:
            att[:] = att0
            t_att = math.inf
        elif ta == 0.0 or att0 <= 0.1875:
            t_att = 0.0
        else:
            k = math.log(96 / 0.1875) / ta
            t_att = math.log(max(att0, 0.1875) / 0.1875) / k
            m = t < t_att
            att[m] = att0 * np.exp(-k * t[m])
        if t_att < math.inf:
            m = t >= t_att
            tt = t[m] - t_att
            rd = 96.0 / td if td < math.inf else 0.0
            rrr = 96.0 / tr if tr < math.inf else 0.0
            a = tt * rd
            if rd > 0:
                t_sl = sl_db / rd
                after = tt >= t_sl
                if egt:
                    a = np.where(after, sl_db, a)
                else:
                    a = np.where(after, sl_db + (tt - t_sl) * rrr, a)
            att[m] = a
        np.minimum(att, 96.0, out=att)
        if t_off is not None and t_off < n:
            base = att[t_off]
            rrr = 96.0 / tr if tr < math.inf else 0.0
            att[t_off:] = np.minimum(96.0, base + (t[t_off:] - t[t_off]) * rrr)
        return att

    def release_len(self, rr):
        tr = rate_time(rr, DECAY_MS)
        return min(tr, 6.0)

    def render(self, log, total):
        """log: (time, reg, val) sorted; total: seconds."""
        np = self.np
        sr = self.sr
        N = int(total * sr) + 1
        out = np.zeros(N)
        regs = [0] * 256
        segs = {ch: [] for ch in range(9)}
        cur = {}
        for t, r, v in log:
            old = regs[r]
            regs[r] = v
            ch = None
            if 0xA0 <= r <= 0xA8 or 0xB0 <= r <= 0xB8:
                ch = r & 0x0F
                s = cur.get(ch)
                fnum = regs[0xA0 + ch] | (regs[0xB0 + ch] & 3) << 8
                block = (regs[0xB0 + ch] >> 2) & 7
                on = r >= 0xB0 and v & 0x20 and not old & 0x20
                off = r >= 0xB0 and not v & 0x20 and old & 0x20
                if on:
                    if s:
                        s["cut"] = t
                    op = OPOFF[ch]
                    s = dict(t0=t, ch=ch, off=None, cut=None, freq=[(t, fnum, block)],
                             tl=[[(t, regs[0x40 + op] & 0x3F)], [(t, regs[0x43 + op] & 0x3F)]],
                             r20=(regs[0x20 + op], regs[0x23 + op]),
                             r60=(regs[0x60 + op], regs[0x63 + op]),
                             r80=(regs[0x80 + op], regs[0x83 + op]),
                             we=(regs[0xE0 + op] & 3, regs[0xE3 + op] & 3),
                             ksl=(regs[0x40 + op] >> 6, regs[0x43 + op] >> 6),
                             c0=regs[0xC0 + ch], bd=regs[0xBD], fn0=(fnum, block))
                    cur[ch] = s
                    segs[ch].append(s)
                elif s:
                    if off and s["off"] is None:
                        s["off"] = t
                    if s["freq"][-1][1:] != (fnum, block):
                        s["freq"].append((t, fnum, block))
            elif 0x40 <= r <= 0x55 or 0x60 <= r <= 0x95 or 0x20 <= r <= 0x35 or 0xE0 <= r <= 0xF5:
                slot = r & 0x1F
                if slot in (0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13):
                    ch = [0, 1, 2, 0, 1, 2, None, None, 3, 4, 5, 3, 4, 5][slot]
                    i = 1 if slot in (3, 4, 5, 11, 12, 13) else 0
                    s = cur.get(ch)
                    if s and (0x40 <= r <= 0x55):
                        s["tl"][i].append((t, v & 0x3F))
                    elif s and s["cut"] is None and s["off"] is not None:
                        s["cut"] = t       # voice reload while releasing
            elif 0xC0 <= r <= 0xC8:
                s = cur.get(r & 0xF)
                if s and s["cut"] is None and s["off"] is not None:
                    s["cut"] = t
        for ch in range(9):
            prev_att = [96.0, 96.0]
            prev_end = None
            for s in segs[ch]:
                prev_att = self.segment(out, s, total, prev_att if prev_end and prev_end >= s["t0"] else [96.0, 96.0])
                prev_end = s.get("end")
        return dc_block(out, sr)

    def piecewise(self, n, i0, pts, sr):
        """pts: [(time, value)] -> array of length n starting at sample i0 (hold)."""
        np = self.np
        a = np.empty(n)
        idx = [max(0, min(n, int(round(t * sr)) - i0)) for t, _ in pts]
        for k, (j, (_, v)) in enumerate(zip(idx, pts)):
            e = idx[k + 1] if k + 1 < len(pts) else n
            a[j:e] = v
        return a

    def segment(self, out, s, total, att0):
        np = self.np
        sr = self.sr
        i0 = int(round(s["t0"] * sr))
        m1, m2 = s["r20"]
        rr = [s["r80"][0] & 15, s["r80"][1] & 15]
        fnum, block = s["fn0"]
        # end of the segment
        end = total if s["cut"] is None else s["cut"]
        if s["off"] is not None:
            rel = max(self.release_len(eff_rate(r, m & 0x10, fnum, block))
                      for r, m in zip(rr, (m1, m2)))
            end = min(end, s["off"] + rel + 0.01)
        end = min(end, total)
        s["end"] = end
        n = int(round(end * sr)) - i0
        if n <= 0:
            return [96.0, 96.0]
        n = min(n, len(out) - i0)
        # frequency
        f = self.piecewise(n, i0, [(t, note_hz(fn, bl)) for t, fn, bl in s["freq"]], sr)
        tg = (i0 + np.arange(n)) / sr
        bd = s["bd"]
        vib_cents = 14.0 if bd & 0x40 else 7.0
        trem_db = 4.8 if bd & 0x80 else 1.0
        tri = lambda hz: 2 * np.abs(((tg * hz) % 1.0) - 0.5)   # 0..1
        ops = []
        t_off = None if s["off"] is None else int(round(s["off"] * sr)) - i0
        atts = []
        for i, (r20, r60, r80) in enumerate(zip(s["r20"], s["r60"], s["r80"])):
            ff = f
            if r20 & 0x40:
                ff = f * 2 ** ((tri(6.07) * 2 - 1) * vib_cents / 1200)
            ph = np.cumsum(ff) / sr * MULT[r20 & 15]
            ar = eff_rate(r60 >> 4, r20 & 0x10, fnum, block)
            dr = eff_rate(r60 & 15, r20 & 0x10, fnum, block)
            rrr = eff_rate(r80 & 15, r20 & 0x10, fnum, block)
            env = self.envelope(n, att0[i], ar, dr, r80 >> 4, rrr, r20 & 0x20, t_off)
            atts.append(env[-1])
            tl = self.piecewise(n, i0, s["tl"][i], sr)
            att = env + 0.75 * tl
            if s["ksl"][i]:
                att = att + self.piecewise(n, i0, [(t, ksl_db(s["ksl"][i], fn, bl))
                                                   for t, fn, bl in s["freq"]], sr)
            if r20 & 0x80:
                att = att + trem_db * tri(3.7)
            amp = np.where(att >= 96, 0.0, 10 ** (-att / 20))
            ops.append((ph, amp))
        (pm, am), (pc, ac) = ops
        fbk = (s["c0"] >> 1) & 7
        wm, wc = s["we"]
        if fbk:
            tab = self.feedback_table(wm, fbk)
            g = am * 2.0 ** (fbk - 6)
            gi = np.clip(np.rint(g / 2.0 * 63), 0, 63).astype(np.int64)
            pi = (np.floor(pm * 256) % 256).astype(np.int64)
            ym = am * tab[gi, pi]
        else:
            ym = am * self.wave(wm, pm)
        if s["c0"] & 1:
            y = ym + ac * self.wave(wc, pc)
        else:
            y = ac * self.wave(wc, pc + 4.0 * ym)
        # short ramps where the chip would click (phase reset at key-on, cut of a sounding note)
        k = min(n, int(0.001 * sr))
        if k > 1:
            y[:k] *= 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, k))
        k = min(n, int(0.003 * sr))
        if k > 1 and s["cut"] is not None and s["cut"] <= end + 1e-9:
            y[-k:] *= 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, k))
        out[i0:i0 + n] += y
        return atts


# ------------------------------------------------------------------ rendering front end

def render_song(d, song, sr=44100, fade=8.0, synth=None):
    """returns (samples float array, info dict)."""
    a = analyse(d, song)
    loops = song not in NO_LOOP
    if loops:
        total = a["end"] + fade
        drv = Driver(d, song, loop=True).run(until=total)
    else:
        drv = Driver(d, song, loop=False).run()
        total = a["end"] + 3.0
    syn = (synth or Synth)(sr)
    y = syn.render(drv.log, total)
    import numpy as np
    if loops:
        n0 = int(a["end"] * sr)
        fl = len(y) - n0
        y[n0:] *= np.linspace(1, 0, fl) ** 2
    info = dict(number=song, duration=round(total, 3),
                loopStart=round(a["loop"], 3) if loops else None,
                loopEnd=round(a["end"], 3) if loops else None,
                channels=a["channels"], tempo=a["tempos"], gameIndex=GAME_INDEX.get(song),
                scene=SCENES.get(song, "?"))
    return y, info


def soft_clip(y, knee=0.7, ceil=0.98):
    import numpy as np
    a = np.abs(y)
    over = a > knee
    a[over] = knee + (ceil - knee) * np.tanh((a[over] - knee) / (ceil - knee))
    return np.sign(y) * a


def write_wav(path, y, sr):
    import numpy as np
    pcm = np.clip(np.rint(y * 32767), -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(sr)
        f.writeframes(pcm.tobytes())


def cmd_render(args):
    import numpy as np
    sr, fade, keep, synth = 44100, 8.0, None, None
    songs = []
    it = iter(args)
    for a in it:
        if a == "--rate": sr = int(next(it))
        elif a == "--fade": fade = float(next(it))
        elif a == "--wav": keep = next(it)
        elif a == "--chip":
            # sfx.py's chip-accurate operator: per-sample feedback (FB 6-7 sound as noise) and the
            # DR 0 / SL 0 / EGT 0 envelope falling while held (docs/re/sfx.md, open question 2).
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import sfx
            synth = sfx.FxSynth
        else: songs.append(int(a))
    d = load()
    songs = songs or sorted(song_table(d))
    tmp = keep or tempfile.mkdtemp(prefix="mml")
    os.makedirs(tmp, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    infos, peaks = {}, {}
    for s in songs:
        y, info = render_song(d, s, sr, fade, synth)
        np.save(f"{tmp}/song{s:02d}.npy", y.astype(np.float32))
        peaks[s] = float(np.percentile(np.abs(y), 99.9))
        infos[s] = info
        print(f"song {s:2d}: {info['duration']:7.2f}s loop {info['loopStart']} p99.9 {peaks[s]:.2f}", flush=True)
    # one gain for the whole bank (keeps the relative loudness of the songs); the rare
    # transients above 0.7 go through a soft knee instead of setting the gain
    gain = 0.75 / max(peaks.values())
    index_path = OUT + "/index.json"
    index = {}
    if os.path.exists(index_path):
        old = json.load(open(index_path))
        for e in old["songs"]:
            index[e["number"]] = e
        if set(songs) != set(song_table(d)) and "gain" in old:
            gain = old["gain"]                # partial re-render: keep the bank's level
    for s in songs:
        y = soft_clip(np.load(f"{tmp}/song{s:02d}.npy") * gain)
        wav = f"{tmp}/song{s:02d}.wav"
        write_wav(wav, y, sr)
        os.remove(f"{tmp}/song{s:02d}.npy")
        m4a = f"{OUT}/song{s:02d}.m4a"
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "128000", wav, m4a], check=True)
        if not keep:
            os.remove(wav)
        index[s] = dict(infos[s], file=f"song{s:02d}.m4a")
    with open(index_path, "w") as f:           # one song per line
        f.write('{"source": "original/GAME/D2.MML via tools/mml.py (docs/re/music.md)",\n'
                f' "sampleRate": {sr}, "gain": {gain:.6f},\n "songs": [\n')
        f.write(",\n".join("  " + json.dumps(index[k], ensure_ascii=False) for k in sorted(index)))
        f.write("\n ]\n}\n")
    if not keep:
        shutil.rmtree(tmp, ignore_errors=True)


def cmd_check():
    d = load()
    tab = song_table(d)
    ok = True
    voices = set()
    # static decode: every channel must end on FF exactly where the next stream starts
    starts = sorted(p for v in tab.values() for p in v if p)
    for s, ptrs in tab.items():
        for i, p in enumerate(ptrs):
            if not p:
                continue
            lst, end = decode(d, p)
            nxt = next((x for x in starts if x > p), len(d))
            if end != nxt:
                print(f"song {s} ch {i}: stream ends at {end:#x}, next stream at {nxt:#x}")
                ok = False
            for pos, n, t in lst:
                if t.startswith("voice @"):
                    voices.add(int(t[7:], 16))
    vt = table_end(d)
    bad = [v for v in voices if (v - vt) % 22 or not vt <= v < starts[0]]
    print(f"{len(tab)} songs, voice table {vt:#x}..{starts[0]:#x} ({(starts[0] - vt) // 22} records), "
          f"{len(voices)} referenced, misaligned: {bad}")
    ok &= not bad
    for s in sorted(tab):
        a = analyse(d, s)
        drv = a["drv"]
        hz = [note_hz(f, b) for _, _, _, f, b, _ in drv.notes]
        cents = [1200 * math.log2(note_hz(f, b) / (440 * 2 ** ((n + 12 - 69) / 12)))
                 for _, _, n, f, b, _ in drv.notes]
        same = len({round(x, 3) for x in a["ends"]}) == 1
        lp = a["loops"]
        lsame = len({round(x, 3) for x in lp}) == 1
        loop = f"{a['loop']:.2f}s" + ("" if a["marker"] else " (start)")
        print(f"song {s:2d}: ch {a['channels']} tempo {a['tempos']} end {a['end']:6.2f}s loop {loop} "
              f"notes {len(hz)} range {min(hz):.0f}-{max(hz):.0f} Hz dev {min(cents):+.0f}..{max(cents):+.0f}c"
              + ("" if same else "  END MISMATCH " + str([round(x, 2) for x in a["ends"]]))
              + ("" if lsame else "  LOOP MISMATCH " + str([round(x, 2) for x in lp])))
        ok &= same and lsame
        # second pass must replay the loop body note for note at the same relative times
        if s not in NO_LOOP:
            ln = a["end"] - a["loop"]
            drv2 = Driver(d, s).run(until=a["end"] + ln + 0.5)
            p1 = [(round(t - a["loop"], 2), ch, n) for t, ch, n, *_ in drv2.notes if a["loop"] <= t < a["end"] - 0.01]
            p2 = [(round(t - a["end"], 2), ch, n) for t, ch, n, *_ in drv2.notes if a["end"] <= t < a["end"] + ln - 0.01]
            bad = sum(1 for x, y in zip(p1, p2) if x[1:] != y[1:] or abs(x[0] - y[0]) > 0.011)
            if bad or len(p1) != len(p2):
                print(f"   loop replay differs: {len(p1)} vs {len(p2)} notes, {bad} mismatched")
                ok = False
    print("OK" if ok else "PROBLEMS")
    return ok


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    cmd, args = sys.argv[1], sys.argv[2:]
    d = load()
    if cmd == "list":
        s = int(args[0])
        for i, p in enumerate(song_table(d)[s]):
            if not p:
                continue
            print(f"--- song {s} channel {i} @{p:04x}")
            lst, end = decode(d, p)
            for pos, n, t in lst:
                print(f"{pos:04x}  {d[pos:pos + n].hex(' '):<9} {t}")
    elif cmd == "voices":
        seen = set()
        for s, ptrs in song_table(d).items():
            for p in ptrs:
                if p:
                    for pos, n, t in decode(d, p)[0]:
                        if t.startswith("voice @"):
                            seen.add(int(t[7:], 16))
        for v in sorted(seen):
            print(voice_str(d, v))
    elif cmd == "check":
        sys.exit(0 if cmd_check() else 1)
    elif cmd == "render":
        cmd_render(args)
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
