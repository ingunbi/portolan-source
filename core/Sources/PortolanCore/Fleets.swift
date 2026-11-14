import Foundation

// The 70 fleets of the world (DS:0x2DB2, 133 bytes each), run on the data segment as the
// original does (docs/re/fleets.md): a daily step per fleet (0x1A5F8) along the route graph
// (DATA1[4]), tick-by-tick sailing near the player (0x1A9BD), missions and port visits
// (0x33818), and encounters (0x1A454, 0x1A565, 0x1A183).

/// Route graph nodes: x, y (bit 15 = charted), up to four links with costs.
public struct RouteGraph {
    public struct Node {
        public let x: Int, y: Int
        public let next: [Int]
        public let cost: [Int]
    }
    public let nodes: [Node]

    public init(data d: [UInt8], count: Int = 622) {
        func w(_ a: Int) -> Int { Int(d[a]) | Int(d[a + 1]) << 8 }
        nodes = (0..<min(count + 2, d.count / 16)).map { i in
            let a = 16 * i
            return Node(x: w(a) & 0x7FFF, y: w(a + 2), next: (0..<4).map { w(a + 4 + 2 * $0) }, cost: (0..<4).map { Int(d[a + 12 + $0]) })
        }
    }

    /// Nearest node (0x22B79): scans 622 down to 0, ties keep the higher index; bit 15 marks
    /// an exact hit.
    public func nearest(x: Int, y: Int) -> Int {
        var best = 0, bestD = Int.max
        for i in stride(from: min(622, nodes.count - 1), through: 0, by: -1) {
            var dx = abs(nodes[i].x - x)
            if dx > 1080 { dx = 2160 - dx }
            let dy = nodes[i].y - y
            let d = dx * dx + dy * dy
            if d < bestD {
                bestD = d
                best = i
            }
        }
        return bestD == 0 ? best | 0x8000 : best
    }
}

/// Fleet record fields (fleets.md §2.1).
public enum FleetField {
    public static let x = 0, y = 2, destX = 4, destY = 6, localX = 8, localY = 0xA, route = 0xC, routeFlags = 0xD
    public static let error = 0xE, waypoints = 0x10, accX = 0x18, accY = 0x19, heading = 0x1A, mission = 0x1B
    public static let target = 0x1C, treasure = 0x1D, good = 0x21, amount = 0x22, funds = 0x24, home = 0x26
    public static let stay = 0x27, strength = 0x28, state = 0x29, admiral = 0x2A, slots = 0x2B
}

/// A battle the world wants to start: attacker and defender admirals (0x10C96).
public struct Encounter: Codable, Equatable {
    public let attacker: Int
    public let defender: Int
    public init(attacker: Int, defender: Int) {
        self.attacker = attacker
        self.defender = defender
    }
}

extension DataSegment {
    public func fb(_ f: Int, _ o: Int) -> Int { self[DS.fleet(f) + o] }
    mutating func setFB(_ f: Int, _ o: Int, _ v: Int) { self[DS.fleet(f) + o] = v }
    public func fw(_ f: Int, _ o: Int) -> Int { word(DS.fleet(f) + o) }
    mutating func setFW(_ f: Int, _ o: Int, _ v: Int) { setWord(DS.fleet(f) + o, v) }
    public func pb(_ p: Int, _ o: Int) -> Int { self[DS.person(p) + o] }
    mutating func setPB(_ p: Int, _ o: Int, _ v: Int) { self[DS.person(p) + o] = v }
    func nb(_ n: Int, _ o: Int) -> Int { self[0x1106 + 32 * n + o] }
    mutating func setNB(_ n: Int, _ o: Int, _ v: Int) { self[0x1106 + 32 * n + o] = v }

    /// Ship slot `s` of fleet `f`.
    public func slot(_ f: Int, _ s: Int) -> Int { DS.fleet(f) + FleetField.slots + 9 * s }
    public func slotUsed(_ f: Int, _ s: Int) -> Bool { self[slot(f, s) + 8] & 0x30 == 0x10 }
    public func shipClass(_ f: Int, _ s: Int) -> Int { self[DS.ship + DS.shipSize * self[slot(f, s) + 7] + 0x12] }

    public func fleetActive(_ f: Int) -> Bool { fb(f, FleetField.state) & 1 != 0 }
    public func fleetInPort(_ f: Int) -> Bool { fb(f, FleetField.state) & 0x10 != 0 }
    public func fleetAt(_ f: Int) -> (x: Int, y: Int) { (fw(f, FleetField.x), fw(f, FleetField.y)) }
    public func fleetOf(person p: Int) -> Int { pb(p, 0x2C) }

    /// Port record position.
    func portXY(_ p: Int) -> (Int, Int) { (word(DS.port + DS.portSize * p), word(DS.port + DS.portSize * p + 2)) }

    /// Strength (0x17C7D): `(Σ hull + 4) / 5`; a fleet without hulls is no longer active.
    mutating func recomputeStrength(_ f: Int) {
        let sum = (0..<10).filter { slotUsed(f, $0) }.reduce(0) { $0 + self[slot(f, $1) + 2] }
        setFB(f, FleetField.strength, min(255, (sum + 4) / 5))
        if sum == 0 { setFB(f, FleetField.state, fb(f, FleetField.state) & ~1) }
    }
}

public enum Fleets {
    public static let count = 70
    static let slotMask = [0x80, 0x40, 0x20, 0x10]
    /// Heading toward (sx, sy) ∈ {−1, 0, 1}² (DS:0xBB80); 8 = stay.
    static let headings = [[7, 0, 1], [6, 8, 2], [5, 4, 3]]
}

extension Voyage {
    public var playerFleet: Int { memory.pb(heroID, 0x2C) }

    /// 72×72 tiles kept around the player: the 3×3 blocks of 24 tiles centred on his block.
    func onLocal(_ x: Int, _ y: Int) -> Bool {
        let wx = (Int(self.x) / 24 - 1) * 24, wy = (Int(self.y) / 24 - 1) * 24
        var dx = x - wx
        if dx < 0 { dx += World.width }
        if dx >= World.width { dx -= World.width }
        return (0..<72).contains(dx) && (0..<72).contains(y - wy)
    }

    func onLocal(fleet f: Int) -> Bool { let p = memory.fleetAt(f); return onLocal(p.x, p.y) }

    /// Land test of the fleets (0x30AA0): any land in the 2×2 tiles at (x, y).
    func blocked(_ x: Int, _ y: Int, in world: World) -> Bool {
        for dy in 0...1 { for dx in 0...1 where !world.isSea(x: Double(x + dx) + 0.5, y: Double(y + dy) + 0.5) { return true } }
        return false
    }

    // MARK: daily step

    /// The fleets due at this tick of the day (fleet k at tick k), and every tick the fleets
    /// in sight move. `atSea` is false while the player lies in port.
    mutating func runFleets(fromTick t0: Int, toTick t1: Int, atSea: Bool, in world: World) {
        guard world.routes != nil else { return }
        memory.setFW(playerFleet, FleetField.x, Int(x))
        memory.setFW(playerFleet, FleetField.y, Int(y))
        for k in t0..<t1 where k < Fleets.count { fleetDaily(k, atSea: atSea, in: world) }
    }

    /// 0x1A5F8.
    mutating func fleetDaily(_ f: Int, atSea: Bool, in world: World) {
        guard memory.fleetActive(f) else { return }
        if atSea && onLocal(fleet: f) {
            memory.setFB(f, FleetField.routeFlags, memory.fb(f, FleetField.routeFlags) | 0x80)
            return
        }
        guard f != playerFleet else { return }
        refreshChase(f)
        chooseMission(f, in: world)
        if let p = encounterDaily(f) {
            if !onLocal(fleet: memory.fleetOf(person: p)) { npcFight(f, p, in: world) }
            return
        }
        if memory.fleetInPort(f) {
            portHandler(f, in: world)
            if memory.fleetInPort(f) { return }
        }
        if routeUpdate(f, in: world) { hop(f, to: routeTarget(f, in: world), in: world) }
    }

    /// Follow the hunted fleet (0x1A0B3).
    mutating func refreshChase(_ f: Int) {
        let m = memory.fb(f, FleetField.mission)
        guard (5...8).contains(m) || m == 10 else { return }
        let p = memory.fb(f, FleetField.target)
        let target = memory.fleetOf(person: p)
        guard p < 120, memory.pb(p, 0x31) & 0x20 != 0, target < Fleets.count else {
            sendToPort(f, mission: 0, port: memory.fb(f, FleetField.home))
            return
        }
        if onLocal(fleet: f) || rng(4) == 0 {
            let t = memory.fleetAt(target)
            memory.setFW(f, FleetField.destX, t.x)
            memory.setFW(f, FleetField.destY, t.y)
            memory.setFW(f, FleetField.route, onLocal(fleet: f) ? 0x6000 : 0x4000)
        }
    }

    // MARK: routes

    /// 0x23B68: drop the waypoint just reached; in sight, steer through the window (0x23A4D);
    /// out of sight, plan again when the buffer runs dry.
    mutating func routeUpdate(_ f: Int, in world: World) -> Bool {
        guard let g = world.routes else { return false }
        advanceWaypoint(f, world)
        if onLocal(fleet: f) { return localSteer(f, in: world) }
        var fl = memory.fb(f, FleetField.routeFlags) & ~0x80
        memory.setFB(f, FleetField.routeFlags, fl)
        guard fl & 0x40 != 0 else { return true }
        if fl & 8 != 0 {
            fl |= 0x20
            memory.setFB(f, FleetField.routeFlags, fl)
            return true
        }
        return pathfind(f, g)
    }

    /// Breadth-first search back from the goal node, buffering up to four waypoints (0x22C58).
    mutating func pathfind(_ f: Int, _ g: RouteGraph) -> Bool {
        let p = memory.fleetAt(f)
        let s0 = g.nearest(x: p.x, y: p.y), g0 = g.nearest(x: memory.fw(f, FleetField.destX), y: memory.fw(f, FleetField.destY))
        let S = s0 & 0x7FFF, G = g0 & 0x7FFF
        if s0 & 0x8000 != 0 && S == G {
            memory.setFB(f, FleetField.routeFlags, memory.fb(f, FleetField.routeFlags) | 0x28)
            return true
        }
        struct Entry { var mask: Int; let node: Int; var cost: Int }
        var queue = [Entry(mask: 0, node: G, cost: 0)]
        var order = [Int](repeating: -1, count: g.nodes.count)
        order[G] = 0
        var head = 0, found = false
        while head < queue.count && queue[head].node != S && !found {
            let e = head
            head += 1
            let node = g.nodes[queue[e].node]
            for k in 0..<4 {
                let bit = 8 >> k
                let nb = node.next[k]
                if queue[e].mask & bit != 0 || nb == 0xFFFF || nb >= g.nodes.count { continue }
                let c = node.cost[k] + queue[e].cost
                queue[e].mask |= bit
                let j = g.nodes[nb].next.firstIndex(of: queue[e].node) ?? 0
                let back = 8 >> j
                if order[nb] < 0 {
                    order[nb] = queue.count
                    queue.append(Entry(mask: back, node: nb, cost: c))
                    if nb == S { found = true }
                } else {
                    queue[order[nb]].mask |= back
                    queue[order[nb]].cost = min(queue[order[nb]].cost, c)
                }
            }
        }
        var path = s0 & 0x8000 != 0 ? [Int]() : [S]
        var cur = S
        while cur != G && path.count < 4 && order[cur] >= 0 {
            let e = queue[order[cur]]
            let node = g.nodes[cur]
            guard let k = (0..<4).first(where: { k in
                let nb = node.next[k]
                return e.mask & (8 >> k) != 0 && nb < g.nodes.count && order[nb] >= 0 && node.cost[k] + queue[order[nb]].cost == e.cost
            }) else { break }
            cur = node.next[k]
            path.append(cur)
        }
        var c = memory.fb(f, FleetField.route)
        var slot = c & 7
        for _ in 0..<4 where c & Fleets.slotMask[slot & 3] != 0 { slot = (slot + 1) & 3 }
        var fl = memory.fb(f, FleetField.routeFlags)
        for n in path {
            if c & 0xF0 == 0xF0 { break }
            c |= Fleets.slotMask[slot & 3]
            memory.setFW(f, FleetField.waypoints + 2 * (slot & 3), n)
            if n == G {
                fl |= 8
                break
            }
            slot = (slot + 1) & 3
        }
        memory.setFB(f, FleetField.route, c)
        memory.setFB(f, FleetField.routeFlags, fl & ~0x40)
        return true
    }

    /// 0x19AA5: the local target, the destination, or the current waypoint.
    func routeTarget(_ f: Int, ignoringLocal: Bool = false, in world: World) -> (x: Int, y: Int) {
        let fl = memory.fb(f, FleetField.routeFlags)
        if fl & 0x80 != 0 && !ignoringLocal { return (memory.fw(f, FleetField.localX), memory.fw(f, FleetField.localY)) }
        if fl & 0x20 != 0 { return (memory.fw(f, FleetField.destX), memory.fw(f, FleetField.destY)) }
        let node = memory.fw(f, FleetField.waypoints + 2 * (memory.fb(f, FleetField.route) & 3)) & 0x7FFF
        guard let g = world.routes, g.nodes.indices.contains(node) else {
            return (memory.fw(f, FleetField.destX), memory.fw(f, FleetField.destY))
        }
        return (g.nodes[node].x, g.nodes[node].y)
    }

    /// Off-screen movement (0x19BBB): one waypoint a day.
    mutating func hop(_ f: Int, to pt: (x: Int, y: Int), in world: World) {
        if !onLocal(pt.x, pt.y) {
            memory.setFW(f, FleetField.x, (pt.x % World.width + World.width) % World.width)
            memory.setFW(f, FleetField.y, max(0, min(World.height - 1, pt.y)))
        } else if !onLocal(fleet: f), !blocked(pt.x, pt.y, in: world) {
            memory.setFW(f, FleetField.x, pt.x)
            memory.setFW(f, FleetField.y, pt.y)
        }
        reachedDestination(f, in: world)
        if onLocal(fleet: f) { _ = routeUpdate(f, in: world) }
    }

    /// What a fleet does on reaching its destination (end of 0x19BBB / 0x1A9BD).
    mutating func reachedDestination(_ f: Int, in world: World) {
        let p = memory.fleetAt(f)
        guard p.x == memory.fw(f, FleetField.destX), p.y == memory.fw(f, FleetField.destY) else { return }
        let m = memory.fb(f, FleetField.mission)
        if m == 4 {
            if rng(10) == 0 { sendToPort(f, mission: 0, port: memory.fb(f, FleetField.home)) }
        } else if (5...8).contains(m) || m == 10 {
            let t = memory.fleetOf(person: memory.fb(f, FleetField.target))
            if t < Fleets.count {
                let tp = memory.fleetAt(t)
                memory.setFW(f, FleetField.destX, tp.x)
                memory.setFW(f, FleetField.destY, tp.y)
            }
            memory.setFW(f, FleetField.route, onLocal(fleet: f) ? 0x6000 : 0x4000)
            memory.setFB(f, FleetField.state, memory.fb(f, FleetField.state) & ~0x30)
        } else {
            arrive(f, in: world)
        }
    }

    /// 0x19B48.
    mutating func arrive(_ f: Int, in world: World) {
        memory.setFB(f, FleetField.state, memory.fb(f, FleetField.state) | 0x30)
        let m = memory.fb(f, FleetField.mission)
        if [0, 1, 2, 9].contains(m) {
            let p = memory.portXY(memory.fb(f, FleetField.target))
            memory.setFW(f, FleetField.x, p.0)
            memory.setFW(f, FleetField.y, p.1)
        } else if m == 3 {
            memory.setFB(f, FleetField.state, memory.fb(f, FleetField.state) & ~0x10)
        } else if (5...8).contains(m) || m == 10 {
            let t = memory.fleetOf(person: memory.fb(f, FleetField.target))
            if t < Fleets.count {
                let tp = memory.fleetAt(t)
                memory.setFW(f, FleetField.x, tp.x)
                memory.setFW(f, FleetField.y, tp.y)
            }
        }
        memory.setFB(f, FleetField.stay, rng(8) + 8)
        portHandler(f, in: world)
    }

    // MARK: missions

    /// 0x330CF. `mission` 0xFF keeps the current one.
    public mutating func sendToPort(_ f: Int, mission m: Int, port: Int) {
        let p = memory.portXY(port)
        if m == 0 {
            memory.setFW(f, FleetField.destX, p.0)
            memory.setFW(f, FleetField.destY, p.1)
        }
        if memory.fb(f, FleetField.state) & 0x40 == 0 && siblingQuota(f) && m != 0 {
            stayHome(f)
            return
        }
        if m != 0xFF { memory.setFB(f, FleetField.mission, m) }
        memory.setFB(f, FleetField.target, port)
        memory.setFW(f, FleetField.destX, p.0)
        memory.setFW(f, FleetField.destY, p.1)
        memory.setFW(f, FleetField.route, 0x4000)
        memory.setFB(f, FleetField.state, memory.fb(f, FleetField.state) & ~0x30)
    }

    private mutating func stayHome(_ f: Int) {
        memory.setFB(f, FleetField.mission, 0)
        memory.setFB(f, FleetField.target, memory.fb(f, FleetField.home))
        memory.setFB(f, FleetField.stay, 5)
    }

    /// 0x33197.
    mutating func sendAfterFleet(_ f: Int, mission m: Int, fleet t: Int) {
        if memory.fb(f, FleetField.state) & 0x40 == 0 && siblingQuota(f) {
            stayHome(f)
            return
        }
        guard t < Fleets.count, memory.fleetActive(t) else {
            sendToPort(f, mission: 0, port: memory.fb(f, FleetField.home))
            return
        }
        memory.setFB(f, FleetField.mission, m)
        memory.setFB(f, FleetField.target, memory.fb(t, FleetField.admiral))
        let p = memory.fleetAt(t)
        memory.setFW(f, FleetField.destX, p.x)
        memory.setFW(f, FleetField.destY, p.y)
        memory.setFW(f, FleetField.route, 0x4000)
        memory.setFB(f, FleetField.state, memory.fb(f, FleetField.state) & ~0x30)
    }

    /// 0x32FFC: per nation at most two merchant fleets and one of each navy squadron are out.
    func siblingQuota(_ f: Int) -> Bool {
        let g = f / 10 * 10, k = f % 10
        let out = { (i: Int) in memory.fleetActive(g + i) && !memory.fleetInPort(g + i) }
        if (1...4).contains(k) { return (1...4).filter(out).count >= 2 }
        if k <= 6 { return (5...6).contains(where: out) }
        return (7...9).contains(where: out)
    }

    /// 0x333D6: missions by the nation's policy, from the capital only.
    func nextMission(_ f: Int) -> Int {
        let n = min(6, f / 10), k = f % 10
        guard memory.fb(f, FleetField.target) == memory.nb(n, 0xA) else { return 0 }
        let policy = min(8, memory.nb(n, 3))
        if (1...4).contains(k) { return [1, 1, 2, 1, 1, 1, 1, 6, 6][policy] }
        if (5...6).contains(k) { return [9, 9, 9, 6, 5, 5, 5, 9, 4][policy] }
        return [8, 8, 8, 6, 6, 6, 6, 6, 6][policy]
    }

    /// 0x332B9.
    mutating func depart(_ f: Int) {
        let n = min(6, f / 10)
        let m = memory.fb(f, FleetField.mission)
        var zone = memory.nb(n, 2)
        if zone == 7 { zone = memory.pb(heroID, 0x31) & 0xF }
        switch m {
        case 0, 9: sendToPort(f, mission: m, port: memory.fb(f, FleetField.home))
        case 1, 2: sendToPort(f, mission: m, port: memory.nb(n, 4))
        case 3, 7: break
        case 4: sendAfterFleet(f, mission: 4, fleet: playerFleet)
        case 5, 6:
            switch memory.nb(n, 3) {
            case 3, 7: sendAfterFleet(f, mission: m, fleet: playerFleet)
            case 4, 8: sendAfterFleet(f, mission: m, fleet: 10 * min(6, zone) + (rank > 2 ? rng(5) : rng(4) + 1))
            case 5: sendAfterFleet(f, mission: m, fleet: 10 * min(6, zone) + 5 + rng(2))
            case 6: sendAfterFleet(f, mission: m, fleet: 61 + rng(9))
            default: sendToPort(f, mission: 0, port: memory.fb(f, FleetField.home))
            }
        case 8: sendAfterFleet(f, mission: 8, fleet: 10 * n + 1 + rng(4))
        default: sendToPort(f, mission: 0, port: memory.fb(f, FleetField.home))
        }
    }

    /// Navies and pirates change their minds at sea (0x19E80).
    mutating func chooseMission(_ f: Int, in world: World) {
        guard memory.fb(f, FleetField.state) & 0x40 == 0 else { return }
        let k = f % 10
        guard f > 60 || k >= 5 else { return }
        let adm = memory.fb(f, FleetField.admiral)
        let traits = adm < 120 ? memory.pb(adm, 0x2F) : 0
        let m = memory.fb(f, FleetField.mission)
        if (4...6).contains(m) {
            let hunted = m == 4 ? playerFleet : memory.fleetOf(person: memory.fb(f, FleetField.target))
            let odds = k <= 6 ? (traits & 0x20 != 0 ? 30 : 15) : (traits & 0x20 != 0 ? 60 : 30)
            if (hunted < Fleets.count && memory.fb(hunted, FleetField.stay) != 0) || rng(odds) == 0 {
                sendToPort(f, mission: 0, port: memory.fb(f, FleetField.home))
                return
            }
        }
        if (8...9).contains(m) && tick % 12 == 0 {
            for i in 0..<Fleets.count where i != f && memory.fleetActive(i) {
                let mi = memory.fb(i, FleetField.mission)
                guard (5...7).contains(mi) else { continue }
                let victim = memory.fleetOf(person: memory.fb(i, FleetField.target))
                if victim / 10 == f / 10 && rng(traits & 0x80 != 0 ? 2 : 1) == 0 {
                    sendAfterFleet(f, mission: k > 6 ? 6 : 5, fleet: i)
                }
            }
        }
        if f > 60 && memory.fb(f, FleetField.mission) == 4 && onLocal(fleet: f) && rng(traits & 0x80 != 0 ? 3 : 2) == 0 {
            let victims = (0..<60).filter { i in
                memory.fleetActive(i) && ((1...4).contains(i % 10) || (i == playerFleet && rank > 0))
            }
            if !victims.isEmpty { sendAfterFleet(f, mission: 5, fleet: victims[rng(victims.count)]) }
        }
    }

    /// In-port business (0x33818): sell and repair at home, invest or trade abroad.
    mutating func portHandler(_ f: Int, in world: World) {
        memory[0xC164] = f / 10
        let m = memory.fb(f, FleetField.mission)
        guard m <= 2 else { return }
        let stay = memory.fb(f, FleetField.stay)
        if stay > 0 {
            memory.setFB(f, FleetField.stay, stay - 1)
            if stay - 1 != 0 { return }
        }
        let port = memory.fb(f, FleetField.target)
        let n = min(6, f / 10)
        switch m {
        case 0:                                                             // 0x3345D
            if memory.fb(f, FleetField.good) != 0xFF && port < markets.count {
                let cat = world.navigation.goods.indices.contains(memory.fb(f, FleetField.good))
                    ? world.navigation.goods[memory.fb(f, FleetField.good)].category : -1
                for i in markets[port].prices.indices {
                    markets[port].prices[i] -= min(markets[port].prices[i], rng(3) + (cat == i ? 2 : 0))
                }
            }
            for s in 0..<10 where memory.slotUsed(f, s) { memory[memory.slot(f, s) + 2] = memory[memory.slot(f, s) + 3] }
            for s in 0..<4 {
                if rng(2 * (s + 1)) != 0 { break }
                if memory.fb(f, FleetField.treasure + s) == 0xFF { memory.setFB(f, FleetField.treasure + s, rng(20) + 50) }
            }
            memory.recomputeStrength(f)
            memory.setFW(f, FleetField.funds, rng(3) + memory.word(0x1106 + 32 * n) / 10 + 1)
            memory.setFB(f, FleetField.good, 0xFF)
            memory.setFW(f, FleetField.amount, 0)
            memory.setFB(f, FleetField.mission, nextMission(f))
            depart(f)
        case 1:                                                             // 0x33568
            let funds = memory.fw(f, FleetField.funds)
            if funds >= 2 && port < markets.count && port != memory.nb(n, 0xA) && n < 6 {
                let mk = DS.market + DS.marketSize * port
                let amount = (funds / 2) * 100
                let ecoInv = memory.word(mk + 2), indInv = memory.word(mk + 6)
                let intoEconomy = (markets[port].economy <= markets[port].industry && ecoInv < 50000) || indInv >= 50000
                if intoEconomy { memory.setWord(mk + 2, min(50000, ecoInv + amount)) } else { memory.setWord(mk + 6, min(50000, indInv + amount)) }
                let left = funds - funds / 2
                memory.setFW(f, FleetField.funds, left)
                let inc = min(100 - markets[port].support[n], 6 * left / 10)
                markets[port].support[n] += inc
                var take = min(inc, (0..<6).filter { $0 != n }.reduce(0) { $0 + markets[port].support[$1] })
                var i = 0
                while take > 0 {
                    if i != n && markets[port].support[i] > 0 {
                        markets[port].support[i] -= 1
                        take -= 1
                    }
                    i = (i + 1) % 6
                }
            }
            sendToPort(f, mission: 0, port: memory.fb(f, FleetField.home))
        default:                                                            // 0x336E4
            if port < markets.count && port != memory.nb(n, 0xA) {
                let r = rng(16) + 10
                let zone = world.navigation.zones[markets[port].zone]
                let cat = world.navigation.goods[r].category
                let price = zone.sellPrices[r] * (markets[port].prices[cat] + 50) / 100
                let funds = memory.fw(f, FleetField.funds)
                if price > 0 && 100 * funds >= price {
                    let q = min(1000, 100 * funds / price)
                    markets[port].prices[cat] += min(100 - markets[port].prices[cat], rng(3) + 3)
                    memory.setFW(f, FleetField.funds, funds - q * price / 100)
                    memory.setFB(f, FleetField.good, r)
                    memory.setFW(f, FleetField.amount, q)
                }
            }
            sendToPort(f, mission: 0, port: memory.fb(f, FleetField.home))
        }
    }

    // MARK: encounters

    /// Off-screen meetings in the same 24×24 block (0x1A454).
    mutating func encounterDaily(_ f: Int) -> Int? {
        let m = memory.fb(f, FleetField.mission)
        guard (4...7).contains(m) else { return nil }
        let p = memory.fleetAt(f)
        let block = p.x / 24 + 90 * (p.y / 24)
        if m == 4 {
            for g in 0..<60 where g != f && memory.fleetActive(g) && memory.fb(g, FleetField.state) & 0x50 == 0 {
                let q = memory.fleetAt(g)
                if q.x / 24 + 90 * (q.y / 24) == block && memory.fb(g, FleetField.strength) < memory.fb(f, FleetField.strength) {
                    memory.setFB(f, FleetField.mission, 5)
                    return memory.fb(g, FleetField.admiral)
                }
            }
            return nil
        }
        let hunted = memory.fleetOf(person: memory.fb(f, FleetField.target))
        guard hunted < Fleets.count, memory.fleetActive(hunted) else {
            sendToPort(f, mission: 0, port: memory.fb(f, FleetField.home))
            return nil
        }
        guard memory.fb(hunted, FleetField.state) & 0x50 == 0 else { return nil }
        let q = memory.fleetAt(hunted)
        return q.x / 24 + 90 * (q.y / 24) == block ? memory.fb(f, FleetField.target) : nil
    }

    /// Meetings in sight: the same tile (0x1A565).
    mutating func encounterLocal(_ f: Int) -> Int? {
        let m = memory.fb(f, FleetField.mission)
        let p = memory.fleetAt(f)
        if m == 4 {
            let me = memory.fleetAt(playerFleet)
            guard p == me else { return nil }
            memory.setFB(f, FleetField.mission, 5)
            return heroID
        }
        guard (5...7).contains(m) else { return nil }
        let hunted = memory.fleetOf(person: memory.fb(f, FleetField.target))
        guard hunted < Fleets.count, memory.fleetActive(hunted) else {
            sendToPort(f, mission: 0, port: memory.fb(f, FleetField.home))
            return nil
        }
        guard memory.fb(hunted, FleetField.state) & 0x50 == 0 else { return nil }
        return memory.fleetAt(hunted) == p ? memory.fb(f, FleetField.target) : nil
    }

    /// 0x1A183: fights by daylight only. A hunter in sight of the player starts a sea battle;
    /// fleets out of sight fight it out by strength.
    mutating func npcFight(_ f: Int, _ p: Int, in world: World) {
        guard (18..<54).contains(tick) else { return }
        let target = memory.fleetOf(person: p)
        guard target < Fleets.count else { return }
        let atk = memory.fb(f, FleetField.strength) / 10, def = memory.fb(target, FleetField.strength) / 10
        if onLocal(fleet: f) {
            if p == heroID {
                if memory.fb(f, FleetField.state) & 0x40 == 0 && rank == 0 {
                    sendToPort(f, mission: 0, port: memory.fb(f, FleetField.home))
                    return
                }
                if pendingBattle == nil { pendingBattle = Encounter(attacker: memory.fb(f, FleetField.admiral), defender: p) }
                return
            }
        } else {
            if p == heroID { return }
            if rng(150) < memory.pb(p, 0x1D) {
                if memory.fb(f, FleetField.mission) != 7 { sendToPort(f, mission: 0, port: memory.fb(f, FleetField.home)) }
                return
            }
        }
        if memory.fb(f, FleetField.mission) != 7 { sendToPort(f, mission: 0, port: memory.fb(f, FleetField.home)) }
        let ts = memory.fb(target, FleetField.state)
        guard ts & 0x40 == 0, ts & 1 != 0, ts & 0x10 == 0 else { return }
        var pool = atk
        for s in stride(from: 9, through: 0, by: -1) where memory.slotUsed(target, s) {
            let a = memory.slot(target, s)
            if memory[a + 2] <= pool {
                pool -= memory[a + 2]
                memory[a + 2] = 0
                memory[a + 8] = 0
                let q = memory.fw(target, FleetField.amount) / 5
                memory.setFW(target, FleetField.amount, memory.fw(target, FleetField.amount) - q)
                memory.setFW(f, FleetField.amount, memory.fw(f, FleetField.amount) + min(1000 - memory.fw(f, FleetField.amount), q))
                memory.setFB(f, FleetField.good, memory.fb(target, FleetField.good))
                let gq = memory.fw(target, FleetField.funds) / 5
                memory.setFW(target, FleetField.funds, memory.fw(target, FleetField.funds) - gq)
                memory.setFW(f, FleetField.funds, memory.fw(f, FleetField.funds) + min(60000 - memory.fw(f, FleetField.funds), gq))
            } else {
                memory[a + 2] -= pool
                break
            }
        }
        memory.recomputeStrength(target)
        if !memory.fleetActive(target) {
            fleetDestroyed(target)
            sendToPort(f, mission: 0, port: memory.fb(f, FleetField.home))
        }
        pool = def
        for s in stride(from: 9, through: 0, by: -1) where memory.slotUsed(f, s) {
            let a = memory.slot(f, s)
            if memory[a + 2] <= pool {
                pool -= memory[a + 2]
                memory[a + 2] = 0
                memory[a + 8] = 0
            } else {
                memory[a + 2] -= pool
                break
            }
        }
        memory.recomputeStrength(f)
        if !memory.fleetActive(f) { fleetDestroyed(f) }
        // Relations, with the attacker's nation read from a stale global as the original does.
        let a = memory[0xC164], b = target / 10
        if a < 6 && b < 7 {
            let r = memory.nb(a, 0xB + b)
            memory.setNB(a, 0xB + b, r - min(r, rng(2) + 2))
        }
        if b < 6 && a < 7 {
            let r = memory.nb(b, 0xB + a)
            memory.setNB(b, 0xB + a, a < 6 ? memory.nb(a, 0xB + b) : r - min(r, rng(2) + 2))
        }
    }

    /// 0x1A135: the fleet is gone; its admiral goes ashore or out of the story.
    mutating func fleetDestroyed(_ t: Int) {
        memory.setFB(t, FleetField.state, memory.fb(t, FleetField.state) & ~1)
        let adm = memory.fb(t, FleetField.admiral)
        if adm < 120 {
            memory.setPB(adm, 0x2E, 0)
            memory.setPB(adm, 0x2C, 0xFF)
            if memory.pb(adm, 0x1B) & 0xC0 == 0 && rng(10) != 0 {
                memory.setPB(adm, 0x2D, rng(42))
            } else {
                memory.setPB(adm, 0x2D, 0xFF)
                memory.setPB(adm, 0x31, memory.pb(adm, 0x31) & ~0x20)
            }
        }
        memory.setFB(t, FleetField.admiral, 0xFF)
    }

    // MARK: sailing in sight

    /// Every tick at sea (0x1A9BD): fleets in port count down at midnight, fleets in sight sail.
    mutating func moveFleetsInSight(in world: World) {
        guard world.routes != nil else { return }
        for f in 0..<Fleets.count where f != playerFleet && memory.fleetActive(f) {
            if memory.fleetInPort(f) {
                if tick == 0 { portHandler(f, in: world) }
                if memory.fleetInPort(f) { continue }
            }
            var p = memory.fleetAt(f)
            if blocked(p.x, p.y, in: world) {
                // Just out of port, still on the port tile: step to the first free tile of the
                // twelve around it (0x23721), else wait.
                var free: (Int, Int)?
                for k in 0..<12 where free == nil { free = placeAround(k, (p.x, p.y), world) }
                guard onLocal(p.x, p.y), let q = free else { continue }
                memory.setFW(f, FleetField.x, q.0)
                memory.setFW(f, FleetField.y, q.1)
                p = memory.fleetAt(f)
            }
            guard onLocal(p.x, p.y) else {
                memory.setFB(f, FleetField.routeFlags, memory.fb(f, FleetField.routeFlags) & ~0x80)
                continue
            }
            if let who = encounterLocal(f) {
                npcFight(f, who, in: world)
                continue
            }
            if memory.fb(f, FleetField.mission) != 4 { reachedDestination(f, in: world) }
            let d = steer(f, in: world)
            if d == 8 {
                memory.setFB(f, FleetField.state, memory.fb(f, FleetField.state) | 0x20)
                continue
            }
            // No way through the window: heading 0xFF, whose move vector reads (0, 2) — the fleet
            // drifts south (0x1A9BD with DS:0x853/0x85B).
            memory.setFB(f, FleetField.heading, d & 0xFF)
            let s = npcSpeed(f, heading: d < 0 ? 4 : d, in: world)
            let tries = d < 0 ? [-1, 0, 6] : [d, (d + 1) & 7, (d + 7) & 7]
            if tries.allSatisfy({ step(f, $0, s, in: world) }) { localRepath(f, in: world) }
        }
    }

    /// Line steering toward the target (0x30AF5): Bresenham on the major axis, ties to y.
    /// 8 = arrived, −1 = no way through the window.
    mutating func steer(_ f: Int, in world: World) -> Int {
        let p = memory.fleetAt(f)
        if p.x == memory.fw(f, FleetField.destX) && p.y == memory.fw(f, FleetField.destY) { return 8 }
        guard routeUpdate(f, in: world) else { return -1 }
        let t = routeTarget(f, in: world)
        let adx = abs(p.x - t.x), ady = abs(p.y - t.y)
        var err = Int(Int16(truncatingIfNeeded: memory.fw(f, FleetField.error)))
        if memory.fb(f, FleetField.routeFlags) & 2 != 0 {
            err = -(adx / 2)
            memory.setFB(f, FleetField.routeFlags, memory.fb(f, FleetField.routeFlags) & ~2)
        }
        var sx = 0, sy = 0
        if ady < adx {
            sx = (t.x - p.x).signum()
            err += ady
            if err >= 0 { err -= adx; sy = (t.y - p.y).signum() }
        } else {
            sy = (t.y - p.y).signum()
            err += adx
            if err >= 0 { err -= ady; sx = (t.x - p.x).signum() }
        }
        memory.setFW(f, FleetField.error, err & 0xFFFF)
        return Fleets.headings[sy + 1][sx + 1]
    }

    /// The speed of a fleet in sight (0x1A69E): wind and the admiral's seamanship, no crew or load.
    func npcSpeed(_ f: Int, heading d: Int, in world: World) -> Int {
        let adm = memory.fb(f, FleetField.admiral)
        let nav = adm < 120 ? memory.pb(adm, 0x24) : 1, sea = adm < 120 ? memory.pb(adm, 0x1D) : 50
        let angle = abs(weather.windDir - d)
        var slowest = 200, oars = false
        for s in 0..<10 where memory.slotUsed(f, s) {
            let c = memory.shipClass(f, s)
            guard world.navigation.classes.indices.contains(c) else { continue }
            let cls = world.navigation.classes[c]
            if cls.oars { oars = true }
            let a = world.navigation.sailTable[angle][cls.sailType] * memory[memory.slot(f, s) + 5] * weather.windStrength / 150
            var v = min(40, min(30, a + a * nav / 10) * sea / 75)
            if (3...5).contains(angle) { v = v * memory[memory.slot(f, s) + 4] / 100 }
            slowest = min(slowest, v)
        }
        if weather.windStrength == 0 && !oars { return 0 }
        var s = max(2, slowest == 200 ? 2 : slowest)
        let ca = abs(weather.currentDir - d)
        if [0, 1, 7].contains(ca) { s += min(40 - s, weather.currentStrength) }
        if (3...5).contains(ca) { s -= min(s - 1, weather.currentStrength) }
        return s
    }

    /// 0x1A834: accumulate 1/60 tiles; a blocked step returns true.
    mutating func step(_ f: Int, _ d: Int, _ s: Int, in world: World) -> Bool {
        let vx = d < 0 ? 0 : Navigation.dx[d], vy = d < 0 ? 2 : Navigation.dy[d]
        var ax = Int(Int8(truncatingIfNeeded: memory.fb(f, FleetField.accX))) + vx * s
        var ay = Int(Int8(truncatingIfNeeded: memory.fb(f, FleetField.accY))) + vy * s
        var mx = 0, my = 0
        if abs(ax) >= 60 { mx = ax.signum(); ax -= 60 * mx }
        if abs(ay) >= 60 { my = ay.signum(); ay -= 60 * my }
        let p = memory.fleetAt(f)
        if mx != 0 || my != 0 {
            let nx = (p.x + mx + World.width) % World.width, ny = max(0, min(World.height - 1, p.y + my))
            if onLocal(nx, ny) && blocked(nx, ny, in: world) {
                memory.setFB(f, FleetField.accX, max(-59, min(59, ax + 60 * mx)) & 0xFF)
                memory.setFB(f, FleetField.accY, max(-59, min(59, ay + 60 * my)) & 0xFF)
                return true
            }
            memory.setFW(f, FleetField.x, nx)
            memory.setFW(f, FleetField.y, ny)
        }
        memory.setFB(f, FleetField.accX, ax & 0xFF)
        memory.setFB(f, FleetField.accY, ay & 0xFF)
        return false
    }

    // MARK: the player's side

    /// Fleets the player can hail or attack: within two tiles, at sea (0x12CF9).
    public func fleetsNearby() -> [Int] {
        (0..<Fleets.count).filter { f in
            guard f != playerFleet, memory.fleetActive(f), !memory.fleetInPort(f), event != .fog else { return false }
            let p = memory.fleetAt(f)
            return abs(p.x - Int(x)) <= 2 && abs(p.y - Int(y)) <= 2
        }
    }

    /// Fleets drawn on the map: active, at sea, in the window around the player, not in fog.
    public func fleetsInSight() -> [Int] {
        guard event != .fog || !eventAnnounced else { return [] }
        return (0..<Fleets.count).filter { f in
            f != playerFleet && memory.fleetActive(f) && !memory.fleetInPort(f) && onLocal(fleet: f)
        }
    }

    /// The hail reply (0x1FABD, messages 152–161, 216) and whether the fleet attacks.
    public mutating func hail(_ f: Int) -> (line: Int, attacks: Bool) {
        let m = memory.fb(f, FleetField.mission)
        let huntsMe = (5...7).contains(m) && memory.fb(f, FleetField.target) == heroID
        switch m {
        case 3: return (155, true)
        case 4: return (156, true)
        case 5, 6, 7: return huntsMe ? (161, true) : (157, false)
        case 0...10: return ([152, 153, 154, 155, 156, 157, 157, 157, 158, 159, 160][m], false)
        default: return (216, false)
        }
    }

    /// The player's "전투" order (0x10D39): daylight only, 05:00–19:40.
    public mutating func attack(_ f: Int) -> Bool {
        guard (15..<60).contains(tick), fleetsNearby().contains(f) else { return false }
        pendingBattle = Encounter(attacker: heroID, defender: memory.fb(f, FleetField.admiral))
        return true
    }
}
