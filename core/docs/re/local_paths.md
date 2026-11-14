# NPC fleets inside the 72×72 local window (local steering and window search)

Answers open question 1 of `fleets.md`. Addresses are MAIN.EXE load-image offsets
(file offset = addr + 0x5400); `DS:n` = image `0x378B0+n`. The routines are in code segment
0x1F74 (near calls wrap at 64 KB: real target = `0x1F740 + ((ip_next − 0x1F740 + rel) & 0xFFFF)`).
Field names `f.0D` etc. are fleet record offsets (`fleets.md` §2.1). `wx, wy` = window origin
(`wx = 720·[0x706] + [0xC156]`, `wy = [0xC15A]`); "local" coordinates are `lx = x − wx`,
`ly = y − wy`, valid in 0..71. Status marks as in `fleets.md`: ✅ read in full · 🔎 partly · ❓ not decoded.

---------------------------------------------------------------------------------------------

## 1. Summary

* Inside the window a fleet never steers at a route node directly. `route_update` (0x23B68) hands
  on-window fleets to **`local_steer` 0x23A4D**, which keeps an intermediate **local target** in
  `f.08/f.0A` while `f.0D & 0x80` is set. `steer` (0x30AF5) then runs its Bresenham line toward
  `+8/+0xA` (for on-window fleets the 0x80 branch is always taken).
* The local target is produced by **`window_path` 0x2343F**: a uniform-cost search (Dijkstra with
  a sorted queue, costs 2 orthogonal / 3 diagonal) on a **72×72 grid of single tiles** copied from
  the local chip buffer, flooding **from the goal** until it touches the fleet. A cell is enterable
  when its whole 2×2 footprint is free. The fleet then walks the label gradient downhill to get the
  path, and the local target becomes **the end of the first straight run of the path, optionally
  extended by one 45° turn** (the "smooth" flag).
* The goal is the current waypoint node, or `f.dest` in "straight to destination" mode (port
  destinations that are land are first moved to a reachable free tile within 2 tiles). A goal
  outside the window is clipped to the window edge along the line fleet→goal.
* The local target is recomputed only when `0x80` is clear (new route, just entered the window),
  when the fleet stands on it, or (unsmoothed) when the fleet is blocked on three sides.
* `local_steer` returns 0 when no window path exists to the (clipped) goal; `steer` then returns
  −1, the fleet gets heading 0xFF and that tick moves with the out-of-range vector `(0, +2)·speed`
  (it drifts south). From the next tick it steers straight at whatever was left in `+8/+0xA`.

Call graph:

```
0x1A9BD per tick ── steer 0x30AF5 ── route_update 0x23B68 ── (on_local) local_steer 0x23A4D
                 │                                             ├─ pathfind 0x22C58   (route graph, fleets.md §4.2)
                 │                                             ├─ local_goal 0x237F9 ── find_free_near 0x237BF ── place_around 0x23721
                 │                                             │                                              └─ window_search 0x23225
                 │                                             ├─ window_path 0x2343F ── window_search 0x23225 ── init_grid 0x231AC
                 │                                             │                                               └─ neighbour 0x23178
                 │                                             ├─ third_edge 0x239AE
                 │                                             └─ clip_to_window 0x2389D
                 └─ (blocked on 3 sides) local_repath 0x23C0E ── window_path(smooth = 0)
send_to_port 0x330CF / send_after_fleet 0x33197 ── place_around 0x23721  (leaving a visible port)
player autopilot: 0x309C7 → find_free_near 0x237BF (clicked destination), 0x31158 → local_repath 0x23C0E
```

---------------------------------------------------------------------------------------------

## 2. Data ✅

### 2.1 Globals and buffers

| where | what |
|---|---|
| `[0x706]` u8 | third of the map the window is in (0..2) |
| `[0xC156]` u16 | window x inside the third (`wx = 720·[0x706] + [0xC156]`) |
| `[0xC15A]` u16 | window y (`wy`) |
| `[0x430]` far ptr (off `[0x430]`, seg `[0x432]`) | local chip buffer, 1 byte per tile, **row stride 96**. Tile (x,y) is at `(y − wy)·96 + (x % 720 − [0xC156])`. Filled by 0x22628 from 2×2 metatiles: 36×36 metatiles = 72×72 tiles; chips `< 0x34` are stored as 0, others as the chip. Columns 72–95 and rows ≥ 72 are not written by that fill |
| `blocked(x,y)` 0x30AA0 | 1 if any of the 4 bytes at idx, idx+1, idx+96, idx+97 is `≥ 0x34` (fleet footprint = 2×2 tiles, top-left at (x,y)) |
| `[0xC10]` u16 handle | scratch far buffer (0xE40 paragraphs = 58368 B, allocated at 0x10F72, shared with other code). Its segment (via 0x354B7) holds the **search grid**: `u16 grid[72·72]` at offset 0, index `ly·72 + lx` |
| `[0xBECC]`, `[0xBECD]` u8 | output of `neighbour` (nx, ny) |
| `[0xC1E]` handle | route graph nodes (16 B each, `fleets.md` §2.4) |

Grid values: `0x800` = sea, not yet labelled · `0x801` = land (the single tile's chip ≥ 0x34) ·
anything else = search label (cost from the goal; the goal cell is 0).

### 2.2 Tables (MAIN.EXE static data)

| DS | contents |
|---|---|
| 0xB55C | `STEP[8]` = 3 bytes `(dx, dy, cost)` per direction, direction = heading (0 N, clockwise): `(0,−1,2) (1,−1,3) (1,0,2) (1,1,3) (0,1,2) (−1,1,3) (−1,0,2) (−1,−1,3)` |
| 0xB574 | slot masks u16 `0x80, 0x40, 0x20, 0x10` |
| 0xB57C | `HEAD3[3][3]` heading from (dx,dy) ∈ {−1,0,1}², rows dy = −1,0,1: `7 0 1 / 6 8 2 / 5 4 3`; indexed as `DS:0xB580 + 3·dy + dx` |
| 0xB586 | `HDX[8]` = `0 1 1 1 0 −1 −1 −1` (dx by heading) |
| 0xB58E | `HDY[8]` = `−1 −1 0 1 1 1 0 −1` (dy by heading) |
| 0xBB80 | same 3×3 heading table used by `steer` (`DS:0xBB84 + 3·sy + sx`) |
| 0x754 / 0x75C | `move` vectors dx[8] / dy[8] (same as HDX/HDY). Index 0xFF reads DS:0x853 = **0x00** and DS:0x85B = **0x02** (bytes of an unrelated word table at 0x846..) |
| local, 0x23721 | `OFF12[12]` (dx,dy): `(0,−2) (0,2) (2,0) (−2,0) (−1,−2) (1,−2) (2,−1) (2,1) (−1,2) (1,2) (−2,−1) (−2,1)` |

### 2.3 Fleet fields involved
`+0/+2` position · `+4/+6` dest · **`+8/+0xA` local target / goal scratch** (also used as the
in/out argument of the routines below) · `+0xC` slot index (bits 0–2) and slot-valid mask
(bits 4–7) · `+0xD` flags: **0x80 local target valid**, 0x40 needs a route, 0x20 straight to dest,
0x08 last buffered node is the goal node, 0x02 reset the Bresenham error · `+0xE` Bresenham error ·
`+0x10` waypoint node ids · `+0x1A` heading · `+0x1B` mission. New-game data: `+8/+0xA = (0,0)` for
all fleets.

---------------------------------------------------------------------------------------------

## 3. Routines

### 3.1 `init_grid` 0x231AC ✅
```
for ly in 0..71: for lx in 0..71:
    grid[ly*72 + lx] = (chipbuf[ly*96 + lx] >= 0x34) ? 0x801 : 0x800
```
Words `grid[5184..]` are **not** initialised (stale data of the shared [0xC10] buffer).

### 3.2 `neighbour(d, x, y)` 0x23178 ✅  (bx = d, ax = x, dx = y; bytes)
`nx = x + STEP[d].dx; ny = y + STEP[d].dy` (u8, stored in [0xBECC]/[0xBECD]);
return `nx < 72 && ny < 72` (unsigned, so −1 = 0xFF fails).

### 3.3 `window_search(src, tgt)` 0x23225 ✅ (bx = &src point, ax = &tgt point; absolute coords)
Flood from `tgt` until a popped cell is adjacent to `src`. Returns 1 = connected, 0 = not.
```
sx = u8(src.x − wx); sy = u8(src.y − wy); tx = u8(tgt.x − wx); ty = u8(tgt.y − wy)
init_grid()
t = ty*72 + tx;  s = sy*72 + sx
if grid[t] > 0x800: return 0                  ; goal tile is land (single-tile test only)
grid[t] = 0
queue = [t]        ; circular u16 queue of 5184 entries on the stack (bp−0x28A0..bp−0x20)
if grid[s] == 0: return 1                     ; src == tgt
grid[s] = 0x800                               ; fleet's own tile forced to "sea, unlabelled"
while queue not empty:                        ; head == tail → return 0
    c = queue[head]                           ; head is advanced only after the 8 directions
    cx = c % 72; cy = c / 72; cost = grid[c]
    for d in 0..7:
        if !neighbour(d, cx, cy): continue
        if (nx, ny) == (sx, sy): return 1     ; checked before any passability test
        n = ny*72 + nx
        if grid[n] != 0x800: continue         ; land or already labelled
        if grid[n+1] == 0x801 or grid[n+72] == 0x801 or grid[n+73] == 0x801: continue
        grid[n] = cost + STEP[d].cost         ; u16, label fixed at first discovery (no relaxation)
        sorted insert of n (see below)
    head++
return 0
```
Sorted insert: starting at `tail`, shift entries one slot toward the tail while
`grid[queue[j]] > grid[n]` (strict, unsigned), walking back from `tail−1` (wrapping), then store
`n`, `tail++` (wrapping at 5184). The walk always stops at the current head entry (its cost ≤ the
new cost). Net effect: the queue is ordered by **(label, insertion order)** — a min-heap keyed on
`(label, sequence number)` pops in exactly the same order. Each cell is inserted at most once, so
the 5184-entry ring never overflows; the only bound is the window.

Quirks (port literally): the 2×2 test reads `n+1` (at lx = 71 this is the tile (0, ly+1)) and
`n+72`, `n+73` (at ly = 71 these are past the grid → stale words, effectively never 0x801).
Neighbour order N, NE, E, SE, S, SW, W, NW. No corner-cutting test for diagonals. Labels can in
principle reach 0x800/0x801 (paths ≥ ~700 cells) and are then mistaken for sea/land; impossible in
practice in a 72×72 window but falls out naturally if the grid is a `[UInt16]` with the same tests.

### 3.4 `window_path(f, goal, smooth)` 0x2343F ✅ (bx = f, ax = &goal (always `f+8`), dx = smooth)
Returns 0 (goal untouched) when the search fails, else 1 with the new local target in `*goal`.
```
if !window_search(f.xy, *goal): return 0
lx = f.x − wx; ly = f.y − wy
G   = (goal.y − wy)*72 + (goal.x − wx)
cur = ly*72 + lx
if cur == G:                                   ; fleet already on the goal
    *goal = (wx, wy)                           ; ⚠ original bug: window origin, not f.xy
    return 1
; 1. walk the labels downhill (path, ≤ 256 cells, buffer bp−0x21C)
n = 0; cx = lx; cy = ly
while cur != G and n < 256:
    best = grid[cur]; bd = 0                   ; fleet's own cell is 0x800
    for d in 0..7:
        if 0 <= cx+STEP[d].dx < 72 and 0 <= cy+STEP[d].dy < 72:
            v = grid[cur + 72*STEP[d].dy + STEP[d].dx]
            if v < best: best = v; bd = d      ; unsigned, strict → first direction wins ties
    cur += STEP[bd].dx + 72*STEP[bd].dy; path[n++] = cur
    cx += STEP[bd].dx; cy += STEP[bd].dy
; 2. first straight run
px = path[0] % 72; py = path[0] / 72
h = HEAD3[py − ly][px − lx]                    ; DS:0xB580 + 3*(py−ly) + (px−lx)
run = 0; i = 1
while i < n and path[i] == idx(px+HDX[h], py+HDY[h]):     ; idx(x,y) = y*72 + x
    px += HDX[h]; py += HDY[h]; run++; i++
; 3. optional one 45° turn
if smooth and i < n:
    h = (h+1) & 7                              ; clockwise first
    if path[i] != idx(px+HDX[h], py+HDY[h]):
        h = (h−2) & 7                          ; then counter-clockwise
        if path[i] != idx(px+HDX[h], py+HDY[h]): goto done
    loop:
        px += HDX[h]; py += HDY[h]; i++
        if run == 0 or i >= n: goto done       ; first run was a single cell → only 1 turned cell
        if path[i] == idx(px+HDX[h], py+HDY[h]): goto loop
done:
*goal = (px + wx, py + wy)
return 1
```
So the local target is always ≥ 1 cell away, lies on the computed path, and is reachable by a
straight 8-direction run (smooth = 0) or by a straight run plus a 45° leg (smooth = 1, which
`steer` follows as one Bresenham line and may therefore cut a corner).
Examples (open sea, fleet at local (10,10)): goal (40,20) → smooth 1: (40,20) (diagonal to
(20,20), then east), smooth 0: (20,20).

### 3.5 `place_around(k, p, out)` 0x23721 ✅ (ax = k 0..11, bx = &p, dx = &out)
```
*out = p + OFF12[k]                          ; no x wrap
return on_local(*out) and !blocked(*out)     ; 0x22B30, 0x30AA0 (real chip buffer, 2×2)
```
Used:
* **leaving a visible port** — `send_to_port` 0x330CF (after the quota test) and
  `send_after_fleet` 0x33197 (after the quota and "target inactive" tests):
  ```
  if f.29 & 0x10 and on_local(f):
      for k in 0..11:
          if place_around(k, f.xy, &tmp): f.xy = tmp; break
      if none: f.1B = 0; f.1C = f.26; f.27 = 5; return      ; stay in port, retry later
  ```
  (state 0x10 is cleared later in the same routine, `f.29 &= ~0x30`).
* by `find_free_near` below with `p = f.dest`.

### 3.6 `find_free_near(f, out)` 0x237BF ✅ (bx = f, ax = &out)
```
for k in 0..11:
    if place_around(k, f.dest, out) and window_search(f.xy, *out): return 1
return 0                                     ; *out is left at f.dest + OFF12[11] = dest + (−2, +1)
```

### 3.7 `local_goal(f, goal)` 0x237F9 ✅ (bx = f, ax = &goal = f+8) → returns `on_local(*goal)`
```
if f.0D & 0x20:                              ; straight to destination
    if (f.1B <= 3 or f.1B == 9) and on_local(f.dest) and blocked(f.dest):
        find_free_near(f, goal)              ; result ignored
        f.dest = *goal                       ; destination itself is moved (also on failure)
    *goal = f.dest
else:
    *goal = node(f.10[f.0C & 7]).xy          ; x & 0x7FFF
return on_local(*goal)
```
Ports are on land, so a port destination inside the window becomes the first of the 12 offsets
around the port that is free and connected to the fleet; arrival (`f.xy == f.dest`) then works
and `arrive` (0x19B48) snaps the fleet onto the port tile.

### 3.8 `third_edge(f, goal)` 0x239AE ✅ (bx = f, ax = &goal) → 1 if it set a target
```
gx = goal.x
if f.x < 720 and gx >= 1440: gx −= 2160      ; wrap-adjusted copy, used only for the tests
elif f.x >= 1440 and gx < 720: gx += 2160
if f.x % 720 == 0   and f.x > gx:  goal.x = f.x − 2; return 1   ; goal.y unchanged
if f.x % 720 == 718 and gx > f.x:  goal.x = f.x + 2; return 1
if f.y == 0    and goal.y < f.y:   goal.y = f.y − 2; return 1   ; signed: only a negative goal.y
if f.y == 1078 and goal.y > f.y:   goal.y = f.y + 2; return 1
return 0
```
The original's chip buffer and `move` work on `x % 720` of one third; this pushes a fleet standing
on a third boundary 2 tiles across it. `goal.x` may become −2 or 2160 (steer/move wrap it).

### 3.9 `clip_to_window(f, goal)` 0x2389D ✅ (bx = f, ax = &goal) → returns `on_local(*goal)`
Clips the segment f→goal to the window, x first then y. **All products are truncated to 16 bits
before the division** (`imul; cwd; idiv`), division truncates toward zero.
```
gx = goal.x; gy = goal.y
if f.x < 720 and gx >= 1440: gx −= 2160
elif f.x >= 1440 and gx < 720: gx += 2160
if gx < wx:          gy += i16((f.y−gy)*(wx−gx))    / (f.x−gx); gx = wx
elif gx >= wx + 72:  gy += i16((f.y−gy)*(wx+70−gx)) / (f.x−gx); gx = wx + 70
if gy < wy:          gx += i16((f.x−gx)*(wy−gy))    / (f.y−gy); gy = wy
elif gy >= wy + 72:  gx += i16((f.x−gx)*(wy+70−gy)) / (f.y−gy); gy = wy + 70
goal = (gx, gy)
return on_local(goal)
```
Edges are column/row 0 on the west/north and **70** (not 71) on the east/south. The divisors are
never 0 because the fleet is inside the window. `i16()` overflows when the goal is far away
(|Δy·Δx| > 32767), giving a garbage interpolated coordinate that the second clip then clamps.

### 3.10 `local_steer(f)` 0x23A4D ✅ → 1 = `+8/+0xA` holds a target to steer at, 0 = no way
```
goal = &f.08
if !(f.0D & 0x80):
    f.0D |= 0x82                             ; local target now "valid", reset Bresenham
else:
    if *goal != f.xy: return 1               ; keep heading for the current local target
    ; standing on the local target: advance the waypoint if also on it (same code as route_update)
    i = f.0C & 7
    if node(f.10[i]).xy == f.xy:             ; x & 0x7FFF, no slot-valid test
        f.0C &= ~mask[i]; f.0C = (f.0C & ~7) | ((i+1) & 3); f.0D |= 0x02
        if (f.0C & 0xF0) == 0: f.0D |= 0x40
; recompute
if f.0D & 0x40:
    if f.0D & 0x08: f.0D |= 0x20
    else: pathfind(f)                        ; 0x22C58, result ignored
if local_goal(f, goal):                      ; goal inside the window
    if window_path(f, goal, 1): return 1
if third_edge(f, goal): return 1
if !clip_to_window(f, goal): return 0
return window_path(f, goal, 1)
```
Note that `*goal` is used as scratch: after a failure it holds the last goal tried (the
waypoint/destination when it was inside the window, else the clipped edge point), and `0x80`
stays set.

### 3.11 `route_update(f)` 0x23B68 ✅ (complete)
```
i = f.0C & 7
if node(f.10[i]).xy == f.xy:                 ; no slot-valid test
    f.0C &= ~mask[i]; f.0C = (f.0C & ~7) | ((i+1)&3); f.0D |= 0x02
    if (f.0C & 0xF0) == 0: f.0D |= 0x40
if on_local(f): return local_steer(f)
f.0D &= ~0x80
if !(f.0D & 0x40): return 1
if f.0D & 0x08: f.0D |= 0x20; return 1
return pathfind(f)                           ; always 1
```

### 3.12 `local_repath(f)` 0x23C0E ✅
`return window_path(f, &f.08, smooth = 0)` — re-plans toward the **current** local target and
replaces it with the end of the first straight run (no 45° extension, no Bresenham reset). Called
by 0x1A9BD when `move` fails in directions d, d+1, d−1; the result is ignored. If `+8/+0xA` is no
longer inside the window (the window moved) the original indexes outside the grid (u8 local
coordinates); treat that as a failed search.

### 3.13 `steer(f)` 0x30AF5 ✅ (as it consumes the local target)
```
if f.xy == f.dest: return 8
if !route_update(f): return −1               ; 0xFFFF
t = (f.0D & 0x80) ? f.08/0A : (f.0D & 0x20) ? f.dest : node(f.10[f.0C & 7]).xy
adx = |f.x − t.x|; ady = |f.y − t.y|         ; no x wrap
if f.0D & 0x02: f.0E = −(adx / 2); f.0D &= ~0x02          ; adx even when y is the major axis
if ady < adx:                                 ; x-major (ties go to y-major)
    sx = sign(t.x − f.x); f.0E += ady
    if f.0E < 0: sy = 0 else: f.0E −= adx; sy = sign(t.y − f.y)
else:                                         ; y-major, also adx == ady (incl. 0,0)
    sy = sign(t.y − f.y); f.0E += adx
    if f.0E < 0: sx = 0 else: f.0E −= ady; sx = sign(t.x − f.x)
return HEAD3[sy][sx]                          ; DS:0xBB84 + 3*sy + sx; (0,0) → 8
```
For a fleet in the window `route_update` → `local_steer` always leaves `0x80` set, so `t` is the
local target. The error `f.0E` is **not** reset when a new local target is computed (only on first
entry `0x82` and on a waypoint advance), so the line to a new target starts with the old error.

### 3.14 Heading −1 in the per-tick mover 0x1A9BD ✅
`d = steer(f)`; `d == 8` → `f.29 |= 0x20`, next fleet. Otherwise (also for −1) `f.1A = u8(d)`:
* `npc_speed` 0x1A69E reads `f.1A = 0xFF`: wind angle `a = 255 − windDir` (248..255), sail factor
  read from `DS:0x714 + 8·a + class.sailType` (DS:0xED4..0xF14, game-state bytes), no rudder
  factor (a ∉ 3..5), current angle `255 − curDir` → the "with the current" branch
  (`s += min(40 − s, cstr)`). Result still in 2..40 (0 if no wind and all sail-only).
* `move(f, 0xFF, s)` uses vector `(DS:0x853, DS:0x85B) = (0, 2)`: `accY += 2·s`, i.e. the fleet
  drifts **south at double speed**; its one-tile land probe is `(x, y+2)`.
* If that move is blocked: `move(f, 0, s)` (north), then `move(f, 6, s)` (west) (`(0xFF+1)&7`,
  `(0−2)&7`), then `local_repath(f)`.

---------------------------------------------------------------------------------------------

## 4. Life cycle of the local target

| event | effect on `+8/+0xA`, `0x80` |
|---|---|
| route (re)assigned: `send_to_port`/`send_after_fleet` (`f.0C = 0x4000`), `refresh_chase` and the arrival chase update (`0x6000`/`0x4000`) | word write of `+0xC` clears `0x80` and `0x02` → recompute at the next `local_steer` |
| fleet off-window: `route_update` (off-window branch), 0x1A9BD (`!on_local` or `[0xC3A] != 0xFF`) | `0x80` cleared |
| first `local_steer` with `0x80` clear (fleet entered/re-entered the window, or new route) | `0x82` set, target recomputed (smoothed) |
| fleet stands on `+8/+0xA` | waypoint advance if on the node, then recompute (smoothed) |
| blocked on 3 sides | `local_repath`: recompute toward the same target, unsmoothed |
| recompute fails | `local_steer` = 0 → heading 0xFF for this tick; `+8` = last goal tried, `0x80` stays set → from the next tick the fleet steers **straight** at it |
| `fleet_daily` on an on-window fleet at sea (0x1A5F8) | sets `0x80` **without computing** `+8` (stale value used if the fleet just came into the window on its daily tick) |
| window moves (player crosses a 24-tile block) | nothing: `+8` may now be outside the window and is still steered at |
| `local_goal` in 0x20 mode toward a land port | `f.dest` replaced by a free tile near the port |

Notable consequences (all literal original behaviour):
1. **Window-edge bug.** A goal outside the window is clipped to column/row 0 or 70. When the fleet
   reaches that point and the goal is still outside, the clip yields the fleet's own tile, so
   `window_path` takes the `cur == G` exit and sets the target to **(wx, wy)**, the window's NW
   corner. Through local steering a fleet therefore never leaves the window on any side by
   itself; it turns toward the NW corner (where the clip again yields its own tile, `steer`
   returns 8 every tick and state `0x20` is set) until the player's movement shifts the window
   off it, or the heading-0xFF drift/blocked fallbacks push it out. (This needs the
   interpolation to be exact, i.e. `|Δx·Δy| ≤ 32767` between fleet and goal — always true for
   route waypoints.)
   Intended was surely "target = own tile". Keep it behind a flag if the remaster wants a fix.
2. Fleets the search cannot connect to their goal (2×2 footprint through a 1-tile strait, goal
   tile is land, enclosed water) alternate between a south drift tick and straight-line steering
   at the unreachable point.
3. A port destination in sight gets moved by up to (±2, ±2); a fleet leaving a visible port is
   put on the first of the 12 offsets that is free (not necessarily connected to open sea).

---------------------------------------------------------------------------------------------

## 5. How to port (Sources/PortolanCore/Fleets.swift)

Shared helpers (new, in the `Voyage` extension):
* `window() -> (wx, wy)`: **the same origin `onLocal` uses** (`(x/24 − 1)·24`, `(y/24 − 1)·24`).
  `local(x, y) = (wrap2160(x − wx) as −1080..1079, y − wy)`; absolute = `((wx + lx) mod 2160, wy + ly)`.
* `buildGrid(world) -> [UInt16]`: `72·72 + 80` words; cell = `0x801` if
  `!world.isSea(x: Double(abs x) + 0.5, y: Double(abs y) + 0.5)` else `0x800`; the 80-word tail = 0
  (stands in for the stale words read past row 71 — anything but 0x801).
* `windowSearch(src:tgt:) -> Bool` (§3.3), `windowPath(_ f:, smooth:) -> Bool` (§3.4, reads and
  writes `FleetField.localX/localY`), `placeAround(k:, from:) -> (Int, Int)?` (§3.5, uses
  `onLocal` + `blocked`), `findFreeNear(_ f:)` (§3.6), `localGoal(_ f:) -> Bool` (§3.7),
  `thirdEdge(_ f:) -> Bool` (§3.8), `clipToWindow(_ f:) -> Bool` (§3.9, use
  `Int(Int16(truncatingIfNeeded: a*b)) / c`; compute with the wrap-adjusted local coordinates),
  `localSteer(_ f:) -> Bool` (§3.10), `localRepath(_ f:)` (§3.12). A search out of an off-window
  target (local coordinate outside 0..71) returns false.
* Queue: an array with a head index and insertion that keeps `(label, sequence)` order (or a heap
  on that key). Labels are `UInt16` with wrapping add; comparisons unsigned.

Replace / change:
1. **`routeUpdate`**: after the waypoint check insert `if onLocal(fleet: f) { return localSteer(f, in: world) }`
   before `fl & ~0x80`. Drop the extra `c & slotMask[i] != 0` guard to match the original (it
   compares the slot's node even when the slot is not valid) — optional.
2. **`steer`**: `guard routeUpdate(f, in: world) else { return -1 }` instead of `_ = routeUpdate`.
   Bresenham as §3.13: reset `err = −(adx/2)`, y-major when `ady >= adx`, minor step when the
   error is `>= 0` after adding. The current code (`−max/2`, x-major on ties, `> 0`) differs. Keep
   the x-wrap of `dx` (the remaster's window can straddle x = 0; the original's cannot).
3. **`moveFleetsInSight`**: accept `d == -1`: store heading `0xFF`; compute speed with
   `angle = 255 − windDir`, sail factor `memory[0x714 + 8*angle + sailType]` (ds.bin holds the
   bytes), no rudder term, current added; `step` with `(dx, dy) = (memory[0x754 + 0xFF], memory[0x75C + 0xFF]) = (0, 2)`
   instead of `Navigation.dx[d]` (which would trap). Fallback directions `(d+1)&7`, `(d+7)&7` are
   already right for 0xFF (0 and 6). Replace the three-sides fallback `_ = routeUpdate(...)` with
   `localRepath(f)` (= `windowPath(f, smooth: false)`).
4. **`sendToPort` / `sendAfterFleet`**: add the port exit of §3.5 after the quota test (and after
   the inactive-target test in `sendAfterFleet`): if in port and on-window, move the fleet to the
   first free `OFF12` tile; none → `stayHome(f)` and return.
5. **`fleetDaily`** and **`hop`** already behave as the original (`0x80` set without computing;
   `hop` calls `routeUpdate`, which now reaches `localSteer`).
6. `routeTarget` needs no change (`0x80` → `+8/+0xA`).

Cost: one search is ≤ 5184 cells; it runs only on recompute events (a few per tick in total),
`findFreeNear` up to 12 times.

---------------------------------------------------------------------------------------------

## 6. Open questions
1. Window-edge bug (§4.1): confirm in DOSBox that a fleet whose route leaves the window turns
   toward the window's NW corner; if not, re-check the `cur == G` exit at 0x234C3.
2. Contents of the chip buffer's columns 72–95 and rows ≥ 72 (0x22628 leaves them; other fill
   routines 0x22788/0x22913 not read) — affects `blocked()` at window column/row 71 only. The port
   uses the real map there.
3. Whether DS:0x853/0x85B (the heading-0xFF move vector) and DS:0xED4..0xF14 (its sail factor) can
   change at run time (no direct writes found).
4. The player's autopilot (0x309C7 picks a free tile near the clicked point with 0x237BF and sets
   `+0xC = 0x6000`; 0x31158 calls `local_repath` when blocked) — not decoded beyond those calls.
5. Why the waypoint advance is duplicated in `local_steer` (it only fires again if two consecutive
   waypoints are the same tile).
