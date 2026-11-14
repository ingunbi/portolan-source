import Foundation

// How fleets in sight find their way through the 72×72-tile window around the player
// (docs/re/local_paths.md): a flood fill from the goal (0x23225), a local target at the end of
// the first straight run (0x2343F), goals clipped to the window (0x2389D), ports' doors
// (0x23721, 0x237BF) and the steering that consumes it (0x23A4D, 0x30AF5).

/// Blank search grids by window position (a few dozen are enough for a voyage).
final class GridCache: @unchecked Sendable {
    static let shared = GridCache()
    var grids: [Int: [Int]] = [:]
    private var order: [Int] = []

    func store(_ key: Int, _ g: [Int]) {
        grids[key] = g
        order.append(key)
        if order.count > 64 { grids[order.removeFirst()] = nil }
    }
}

/// Min-heap of (label, sequence, cell).
struct Heap {
    var items: [(Int, Int, Int)] = []

    mutating func push(_ label: Int, _ seq: Int, _ cell: Int) {
        items.append((label, seq, cell))
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            guard (items[i].0, items[i].1) < (items[p].0, items[p].1) else { break }
            items.swapAt(i, p)
            i = p
        }
    }

    mutating func pop() -> Int? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && (items[l].0, items[l].1) < (items[m].0, items[m].1) { m = l }
                if r < items.count && (items[r].0, items[r].1) < (items[m].0, items[m].1) { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
        }
        return top.2
    }
}

extension Voyage {
    /// Window origin: the 3×3 blocks of 24 tiles around the player's block.
    var window: (x: Int, y: Int) { ((Int(x) / 24 - 1) * 24, (Int(y) / 24 - 1) * 24) }

    static let step8: [(dx: Int, dy: Int, cost: Int)] = [(0, -1, 2), (1, -1, 3), (1, 0, 2), (1, 1, 3), (0, 1, 2), (-1, 1, 3), (-1, 0, 2), (-1, -1, 3)]
    static let offsets12 = [(0, -2), (0, 2), (2, 0), (-2, 0), (-1, -2), (1, -2), (2, -1), (2, 1), (-1, 2), (1, 2), (-2, -1), (-2, 1)]

    /// Window-local coordinates of an absolute tile, x wrapped.
    func local(_ x: Int, _ y: Int) -> (Int, Int) {
        var lx = x - window.x
        if lx < -World.width / 2 { lx += World.width }
        if lx > World.width / 2 { lx -= World.width }
        return (lx, y - window.y)
    }

    /// The search grid (0x231AC): 0x800 sea, 0x801 land, else a label. Land never changes,
    /// so the blank grid of each window position is kept.
    func initGrid(_ world: World) -> [Int] {
        let w = window
        let key = w.y * World.width + ((w.x % World.width) + World.width) % World.width
        if let g = GridCache.shared.grids[key] { return g }
        var g = [Int](repeating: 0x800, count: 72 * 72 + 80)
        for ly in 0..<72 {
            for lx in 0..<72 where !world.isSea(x: Double(w.x + lx) + 0.5, y: Double(w.y + ly) + 0.5) {
                g[ly * 72 + lx] = 0x801
            }
        }
        GridCache.shared.store(key, g)
        return g
    }

    /// Flood from `tgt` until a cell next to `src` is reached (0x23225); the grid holds the costs.
    func windowSearch(from src: (Int, Int), to tgt: (Int, Int), _ world: World) -> [Int]? {
        let (sx, sy) = local(src.0, src.1), (tx, ty) = local(tgt.0, tgt.1)
        guard (0..<72).contains(tx), (0..<72).contains(ty), (0..<72).contains(sx), (0..<72).contains(sy) else { return nil }
        var grid = initGrid(world)
        let t = ty * 72 + tx, s = sy * 72 + sx
        guard grid[t] <= 0x800 else { return nil }
        grid[t] = 0
        if grid[s] == 0 { return grid }
        grid[s] = 0x800
        // Popped in (label, insertion order), as the original's sorted ring: a binary heap.
        var heap = Heap()
        heap.push(0, 0, t)
        var seq = 1
        while let c = heap.pop() {
            let cx = c % 72, cy = c / 72
            for d in 0..<8 {
                let nx = cx + Self.step8[d].dx, ny = cy + Self.step8[d].dy
                guard (0..<72).contains(nx), (0..<72).contains(ny) else { continue }
                if nx == sx && ny == sy { return grid }
                let n = ny * 72 + nx
                guard grid[n] == 0x800, grid[n + 1] != 0x801, grid[n + 72] != 0x801, grid[n + 73] != 0x801 else { continue }
                grid[n] = grid[c] + Self.step8[d].cost
                heap.push(grid[n], seq, n)
                seq += 1
            }
        }
        return nil
    }

    /// 0x2343F: the new local target, at the end of the first straight run of the downhill
    /// path (plus one 45° leg when `smooth`). Nil when the search fails.
    func windowPath(_ f: Int, goal: (Int, Int), smooth: Bool, _ world: World) -> (Int, Int)? {
        let p = memory.fleetAt(f)
        guard let grid = windowSearch(from: (p.x, p.y), to: goal, world) else { return nil }
        let (lx, ly) = local(p.x, p.y), (gx, gy) = local(goal.0, goal.1)
        let G = gy * 72 + gx
        var cur = ly * 72 + lx
        if cur == G { return window }                           // original bug: the window origin
        var path: [Int] = []
        var cx = lx, cy = ly
        while cur != G && path.count < 256 {
            var best = grid[cur], bd = 0
            for d in 0..<8 {
                let nx = cx + Self.step8[d].dx, ny = cy + Self.step8[d].dy
                guard (0..<72).contains(nx), (0..<72).contains(ny) else { continue }
                let v = grid[ny * 72 + nx]
                if v < best { best = v; bd = d }
            }
            cx += Self.step8[bd].dx
            cy += Self.step8[bd].dy
            cur = cy * 72 + cx
            path.append(cur)
        }
        guard !path.isEmpty else { return nil }
        func idx(_ x: Int, _ y: Int) -> Int { y * 72 + x }
        var px = path[0] % 72, py = path[0] / 72
        var h = Fleets.headings[py - ly + 1][px - lx + 1]
        var run = 0, i = 1
        while i < path.count && h < 8 && path[i] == idx(px + Navigation.dx[h], py + Navigation.dy[h]) {
            px += Navigation.dx[h]; py += Navigation.dy[h]; run += 1; i += 1
        }
        if smooth && i < path.count && h < 8 {
            h = (h + 1) & 7
            var ok = path[i] == idx(px + Navigation.dx[h], py + Navigation.dy[h])
            if !ok {
                h = (h + 6) & 7
                ok = path[i] == idx(px + Navigation.dx[h], py + Navigation.dy[h])
            }
            while ok {
                px += Navigation.dx[h]; py += Navigation.dy[h]; i += 1
                if run == 0 || i >= path.count { break }
                ok = path[i] == idx(px + Navigation.dx[h], py + Navigation.dy[h])
            }
        }
        return (window.x + px, window.y + py)
    }

    /// 0x23721: offset `k` of the twelve around `p`, if it is free sea in the window.
    func placeAround(_ k: Int, _ p: (Int, Int), _ world: World) -> (Int, Int)? {
        let o = Self.offsets12[k]
        let q = (p.0 + o.0, p.1 + o.1)
        return onLocal(q.0, q.1) && !blocked(q.0, q.1, in: world) ? q : nil
    }

    /// 0x23A4D: keeps the local target, or computes a new one. False when there is no way.
    mutating func localSteer(_ f: Int, in world: World) -> Bool {
        var fl = memory.fb(f, FleetField.routeFlags)
        let p = memory.fleetAt(f)
        let target = (memory.fw(f, FleetField.localX), memory.fw(f, FleetField.localY))
        if fl & 0x80 == 0 {
            fl |= 0x82
            memory.setFB(f, FleetField.routeFlags, fl)
        } else {
            if target != (p.x, p.y) { return true }
            advanceWaypoint(f, world)
            fl = memory.fb(f, FleetField.routeFlags)
        }
        if fl & 0x40 != 0 {
            if fl & 8 != 0 { memory.setFB(f, FleetField.routeFlags, fl | 0x20) } else if let g = world.routes { _ = pathfind(f, g) }
        }
        // Goal: the waypoint, or the destination (a port moves to a free tile by its door, 0x237F9).
        var goal: (Int, Int)
        fl = memory.fb(f, FleetField.routeFlags)
        if fl & 0x20 != 0 {
            var dest = (memory.fw(f, FleetField.destX), memory.fw(f, FleetField.destY))
            let m = memory.fb(f, FleetField.mission)
            if (m <= 3 || m == 9) && onLocal(dest.0, dest.1) && blocked(dest.0, dest.1, in: world) {
                var found = (dest.0 - 2, dest.1 + 1)
                for k in 0..<12 {
                    if let q = placeAround(k, dest, world), windowSearch(from: (p.x, p.y), to: q, world) != nil { found = q; break }
                }
                dest = found
                memory.setFW(f, FleetField.destX, dest.0)
                memory.setFW(f, FleetField.destY, dest.1)
            }
            goal = dest
        } else {
            let t = routeTarget(f, ignoringLocal: true, in: world)
            goal = (t.x, t.y)
        }
        if onLocal(goal.0, goal.1), let t = windowPath(f, goal: goal, smooth: true, world) {
            setLocalTarget(f, t)
            return true
        }
        // Clip the line to the goal at the window edge (0x2389D, 16-bit products).
        let w = window
        var gx = goal.0, gy = goal.1
        let fx = p.x, fy = p.y
        if gx - fx > World.width / 2 { gx -= World.width } else if fx - gx > World.width / 2 { gx += World.width }
        func i16(_ v: Int) -> Int { Int(Int16(truncatingIfNeeded: v)) }
        if gx < w.x, fx != gx { gy += i16((fy - gy) * (w.x - gx)) / (fx - gx); gx = w.x } else if gx >= w.x + 72, fx != gx { gy += i16((fy - gy) * (w.x + 70 - gx)) / (fx - gx); gx = w.x + 70 }
        if gy < w.y, fy != gy { gx += i16((fx - gx) * (w.y - gy)) / (fy - gy); gy = w.y } else if gy >= w.y + 72, fy != gy { gx += i16((fx - gx) * (w.y + 70 - gy)) / (fy - gy); gy = w.y + 70 }
        setLocalTarget(f, (gx, gy))
        guard onLocal(gx, gy), let t = windowPath(f, goal: (gx, gy), smooth: true, world) else { return false }
        setLocalTarget(f, t)
        return true
    }

    mutating func setLocalTarget(_ f: Int, _ t: (Int, Int)) {
        memory.setFW(f, FleetField.localX, (t.0 % World.width + World.width) % World.width)
        memory.setFW(f, FleetField.localY, max(0, min(World.height - 1, t.1)))
    }

    /// Drops the waypoint the fleet stands on (shared by 0x23B68 and 0x23A4D).
    mutating func advanceWaypoint(_ f: Int, _ world: World) {
        guard let g = world.routes else { return }
        var c = memory.fb(f, FleetField.route)
        let i = c & 7
        let node = memory.fw(f, FleetField.waypoints + 2 * (i & 3)) & 0x7FFF
        let p = memory.fleetAt(f)
        guard g.nodes.indices.contains(node), g.nodes[node].x == p.x, g.nodes[node].y == p.y else { return }
        c &= ~Fleets.slotMask[i & 3]
        c = (c & ~7) | ((i + 1) & 3)
        memory.setFB(f, FleetField.route, c)
        var fl = memory.fb(f, FleetField.routeFlags) | 2
        if c & 0xF0 == 0 { fl |= 0x40 }
        memory.setFB(f, FleetField.routeFlags, fl)
    }

    /// 0x23C0E: aim again at the current local target, first straight run only.
    mutating func localRepath(_ f: Int, in world: World) {
        let t = (memory.fw(f, FleetField.localX), memory.fw(f, FleetField.localY))
        guard onLocal(t.0, t.1), let n = windowPath(f, goal: t, smooth: false, world) else { return }
        setLocalTarget(f, n)
    }

    /// Leaving a port in sight (0x330CF, 0x33197): the fleet takes the first free tile of the
    /// twelve around it; with none it stays in port and tries again later.
    mutating func leavePortInSight(_ f: Int, in world: World) -> Bool {
        guard memory.fleetInPort(f), onLocal(fleet: f) else { return true }
        let p = memory.fleetAt(f)
        for k in 0..<12 {
            if let q = placeAround(k, (p.x, p.y), world) {
                memory.setFW(f, FleetField.x, q.0)
                memory.setFW(f, FleetField.y, q.1)
                return true
            }
        }
        memory.setFB(f, FleetField.mission, 0)
        memory.setFB(f, FleetField.target, memory.fb(f, FleetField.home))
        memory.setFB(f, FleetField.stay, 5)
        return false
    }
}
