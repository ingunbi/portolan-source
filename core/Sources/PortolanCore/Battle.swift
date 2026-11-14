import Foundation

// Sea battles (docs/re/battle.md). The battle works on the fleet records in the data segment:
// damage goes straight into the ship slots. 52×48 hex map, one action per ship per 20-minute
// tick (0xFB26), sunset at tick 63. The player's flagship takes orders; every other ship is
// run by the AI (0xA213).

/// One attack to animate: a volley (ball, burst, spout) or a boarding (sabres).
public struct BattleStrike: Codable, Equatable {
    public let attacker: Int
    public let target: Int
    public let boarding: Bool
    public let serial: Int
}

public struct BattleUnit: Codable, Equatable {
    public let side: Int
    public let fleet: Int
    public let slot: Int
    public let captain: Int
    public var x: Int
    public var y: Int
    public var heading: Int
    /// Turn accumulator 0...100 (+0xB).
    public var acc = 0
    /// +0xC: 1 공세, 2 공격, 4 집결, 8 이탈, 0x10 포격중심, 0x20 flagship, 0x40 left, 0x80 has target.
    public var flags: Int
    /// +0xD owner bits: 0x80 the player's own, 0xC0 his ally, 0x40 enemy reinforcement, 0 enemy main.
    public let owner: Int
    public var shot: Int
    public let gunPower: [Int]
    public let range: Int
    public let melee: Int
    public let share: Int
    public var target: Int?
}

public enum BattlePhase: Codable, Equatable {
    /// The player's flagship waits for orders.
    case command
    /// A duel: `attacking` is true when the player picks an attack move.
    case duel
    case over
}

public struct BattleLog: Codable, Equatable {
    public var lines: [String] = []
}

public struct DuelState: Codable, Equatable {
    /// Duellists: A challenged, B was challenged.
    public let a: Int, b: Int
    public var meter: Int
    public var turn = 0
    public var histA = 1, histB = 1
    public var playerIsA: Bool
    /// Weapon id, armour value, weapon type, attack value for A and B (0x1218C).
    public let weaponA: (Int, Int, Int), weaponB: (Int, Int, Int)
    public var lastLine = ""
    public var finished = false
    /// Points the last blow took (0 = parried), for the hit frames; not saved.
    public var lastDamage = 0

    enum Keys: String, CodingKey { case a, b, meter, turn, histA, histB, playerIsA, wa, wb, lastLine, finished }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        a = try c.decode(Int.self, forKey: .a)
        b = try c.decode(Int.self, forKey: .b)
        meter = try c.decode(Int.self, forKey: .meter)
        turn = try c.decode(Int.self, forKey: .turn)
        histA = try c.decode(Int.self, forKey: .histA)
        histB = try c.decode(Int.self, forKey: .histB)
        playerIsA = try c.decode(Bool.self, forKey: .playerIsA)
        let wa = try c.decode([Int].self, forKey: .wa), wb = try c.decode([Int].self, forKey: .wb)
        weaponA = (wa[0], wa[1], wa[2])
        weaponB = (wb[0], wb[1], wb[2])
        lastLine = try c.decode(String.self, forKey: .lastLine)
        finished = try c.decode(Bool.self, forKey: .finished)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(a, forKey: .a); try c.encode(b, forKey: .b); try c.encode(meter, forKey: .meter)
        try c.encode(turn, forKey: .turn); try c.encode(histA, forKey: .histA); try c.encode(histB, forKey: .histB)
        try c.encode(playerIsA, forKey: .playerIsA)
        try c.encode([weaponA.0, weaponA.1, weaponA.2], forKey: .wa)
        try c.encode([weaponB.0, weaponB.1, weaponB.2], forKey: .wb)
        try c.encode(lastLine, forKey: .lastLine); try c.encode(finished, forKey: .finished)
    }
    init(a: Int, b: Int, meter: Int, playerIsA: Bool, weaponA: (Int, Int, Int), weaponB: (Int, Int, Int)) {
        self.a = a; self.b = b; self.meter = meter; self.playerIsA = playerIsA
        self.weaponA = weaponA; self.weaponB = weaponB
    }
    public static func == (l: DuelState, r: DuelState) -> Bool { l.a == r.a && l.b == r.b && l.meter == r.meter && l.turn == r.turn }
}

public struct Battle: Codable {
    public static let width = 52, height = 48
    public static let sunset = 63

    /// Map cells (0x9722): 0x80 blocked, 0x40 / 0x20 occupied by the odd / even team.
    public var map: [Int]
    public var units: [BattleUnit]
    /// Units of each side in list order (flagship first); side 0 attacker, 1 defender, 2 and 3 their allies.
    public var sides: [[Int]]
    public var admirals: [Int?]
    public var fleets: [Int?]
    public let windDir: Int, windStrength: Int
    /// Step-cost factor by direction relative to the wind (DS:0xA500).
    public let windCost: [Int]
    public var endCode = 0
    public var phase = BattlePhase.command
    /// Turn iterator: unit index within the sides, then side.
    var round = 0, sideIndex = 0
    public var duel: DuelState?
    var duelTarget: Int?
    public var log = BattleLog()
    /// The latest volley or boarding, for the burst and sabre animations (0xCAFB, 0xCEF6).
    public var lastStrike: BattleStrike?
    /// Σ maxHull of the enemy (0xF279), for the end-of-battle experience.
    let enemyHull: Int
    public let playerAttacked: Bool
    /// The player's flagship and what it may still do this turn.
    public var active: Int?
    public var movesLeft = 0
    public var moved = false

    // MARK: geometry

    static let neighbours: [(Int, Int, Int)] = [(0, -1, -1), (1, -1, 0), (1, 0, 1), (0, 1, 1), (-1, 0, 1), (-1, -1, 0)]

    public static func neighbour(_ x: Int, _ y: Int, _ d: Int) -> (Int, Int) {
        let n = neighbours[((d % 6) + 6) % 6]
        return (x + n.0, y + (x & 1 == 0 ? n.1 : n.2))
    }

    /// Hex distance (0xD250).
    public static func distance(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> Int {
        let ax = abs(x1 - x2), av = abs((2 * y1 + (x1 & 1)) - (2 * y2 + (x2 & 1)))
        return av < ax ? ax : (av + ax) / 2
    }

    static func inBounds(_ x: Int, _ y: Int) -> Bool { (0..<width).contains(x) && (0..<height).contains(y) }
    func cell(_ x: Int, _ y: Int) -> Int { map[y * Battle.width + x] }
    func free(_ x: Int, _ y: Int) -> Bool { Battle.inBounds(x, y) && cell(x, y) & 0xE0 == 0 }

    /// Broadside arc (0xD500).
    static func inArc(_ x1: Int, _ y1: Int, heading h: Int, _ x2: Int, _ y2: Int) -> Bool {
        let v1 = 2 * y1 + (x1 & 1), v2 = 2 * y2 + (x2 & 1)
        let ax = abs(x1 - x2), av = abs(v1 - v2)
        switch h % 3 {
        case 0: return av <= ax
        case 1: return av >= ax && ((x2 <= x1 && v2 <= v1) || (x2 >= x1 && v2 >= v1))
        default: return av >= ax && ((x2 <= x1 && v2 >= v1) || (x2 >= x1 && v2 <= v1))
        }
    }

    // MARK: setup (0xF53C)

    /// Sets up the battle between the fleets of `attacker` and `defender` (admirals), with
    /// reinforcements from navy squadrons within two tiles (0x10B78).
    public init?(attacker a: Int, defender d: Int, voyage v: inout Voyage, world: World) {
        let m = v.memory
        let fa = m.fleetOf(person: a), fd = m.fleetOf(person: d)
        guard fa < Fleets.count, fd < Fleets.count else { return nil }
        var adm: [Int?] = [a, d, nil, nil]
        var fl: [Int?] = [fa, fd, nil, nil]
        if m.pb(v.heroID, 0x31) & 0xF != 6 {
            for f in v.fleetsNearby() where f % 10 >= 5 {
                let c = m.fb(f, FleetField.admiral)
                guard c != a, c != d else { continue }
                if adm[3] == nil && f / 10 == fd / 10 {
                    adm[3] = c; fl[3] = f
                    v.note(Korean.particles("\(m.person(c).name)(가) 수비 측 지원군으로 전투에 합류했습니다."))
                } else if adm[2] == nil && f / 10 == fa / 10 {
                    adm[2] = c; fl[2] = f
                    v.note(Korean.particles("\(m.person(c).name)(가) 공격 측 지원군으로 전투에 합류했습니다."))
                }
            }
        }
        admirals = adm
        fleets = fl
        playerAttacked = a == v.heroID
        let player = v.playerFleet
        let playerTeam = fa == player ? 0 : 1
        v.memory[0xC67A] = 0
        // Wind (0xED0F): its own, fixed for the battle.
        windStrength = v.rng(8) + 1
        windDir = v.rng(8) * 5 / 7
        var w = [Int](repeating: 0, count: 6)
        for k in 0..<6 { w[(windDir + k) % 6] = [1, 2, 3, 4, 3, 2][k] }
        windCost = w
        map = Battle.buildMap(around: m.fleetAt(fd), world: world, rng: &v.rng)

        var all: [BattleUnit] = []
        var lists: [[Int]] = [[], [], [], []]
        var eh = 0
        for s in 0..<4 {
            guard let f = fl[s], let admiral = adm[s] else { continue }
            let onTeam = s & 1 == playerTeam
            let owner = onTeam ? (f == player ? 0x80 : 0xC0) : (s >= 2 ? 0x40 : 0)
            var first = true
            var made: [BattleUnit] = []
            for slot in 0..<10 where v.memory.slotUsed(f, slot) {
                let u = Battle.makeUnit(side: s, fleet: f, slot: slot, admiral: admiral, owner: owner, first: &first, voyage: &v, world: world)
                made.append(u)
                if !onTeam { eh += v.memory[v.memory.slot(f, slot) + 3] }
            }
            guard !made.isEmpty else { continue }
            // Flagship: the slot the player commands, or the biggest hull (0xEE2C).
            let flag = f == player
                ? made.firstIndex { $0.captain == v.heroID } ?? 0
                : made.indices.max { v.memory[v.memory.slot(f, made[$0].slot) + 3] < v.memory[v.memory.slot(f, made[$1].slot) + 3] || ($0 > $1 && v.memory[v.memory.slot(f, made[$0].slot) + 3] == v.memory[v.memory.slot(f, made[$1].slot) + 3]) } ?? 0
            var ordered = [made[flag]] + made.enumerated().filter { $0.offset != flag }.map(\.element)
            ordered[0].flags = 0x22
            for u in ordered {
                lists[s].append(all.count)
                all.append(u)
            }
        }
        units = all
        sides = lists
        enemyHull = eh
        guard !sides[0].isEmpty, !sides[1].isEmpty else { return nil }
        // Headings and starting places (0xF443).
        let dpos = m.fleetAt(fd)
        for s in 0..<4 where !sides[s].isEmpty {
            let f = fl[s]!
            let pos = m.fleetAt(f)
            let heading = (5 * m.fb(f, FleetField.heading)) / 7 % 6
            let ax = max(0, min(4, pos.x - dpos.x + 2)), ay = max(0, min(4, pos.y - dpos.y + 2))
            let anchor = (10 + 8 * ax, 8 * (ay + 1))
            for (k, u) in sides[s].enumerated() {
                var p = anchor
                if k > 0 { p = (units[sides[s][0]].x, units[sides[s][0]].y) }
                var tries = 0
                var spot = k == 0 ? p : (p.0 + v.rng(8) - 4, p.1 + v.rng(8) - 4)
                while !free(spot.0, spot.1) && tries < 500 {
                    spot = k == 0 ? (p.0 + v.rng(16) - 8, p.1 + v.rng(16) - 8) : (p.0 + v.rng(8) - 4, p.1 + v.rng(8) - 4)
                    tries += 1
                }
                units[u].x = spot.0
                units[u].y = spot.1
                units[u].heading = heading
                map[spot.1 * Battle.width + spot.0] |= 0x20 << (s & 1)
            }
        }
        v.memory.setWord(0xA538, 100)
        active = nil
    }

    static func makeUnit(side s: Int, fleet f: Int, slot: Int, admiral: Int, owner: Int, first: inout Bool,
                         voyage v: inout Voyage, world: World) -> BattleUnit {
        let m = v.memory
        let a = m.slot(f, slot)
        let player = f == v.playerFleet
        let captain = player ? m[DS.cargo + DS.cargoSize * slot + 0x1B] : admiral
        let record = DS.ship + DS.shipSize * m[a + 7]
        let cls = m[record + 0x12]
        let sailOnly = m[record + 0x13] & 0x10 != 0
        let k = f % 10
        var shot: Int, mult: Int
        if player {
            shot = m.word(DS.cargo + DS.cargoSize * slot + 6)
            mult = 3
        } else {
            let g = (world.navigation.classes.indices.contains(cls) ? world.navigation.classes[cls].maxGuns : 10) / 5
            shot = (k == 0 || k >= 5) && sailOnly ? g : 0
            shot += v.rng(g)
            mult = first ? 3 : 2
            first = false
        }
        let t = m[a + 8] & 7
        let range = t == 0 ? 0 : world.navigation.cannons[t - 1].range
        let power = t == 0 ? 0 : world.navigation.cannons[t - 1].stat3
        let table = [2: 10, 3: 9, 4: 8, 5: 7]
        let guns = (1...5).map { d in d >= 2 && d <= range ? (table[d]! * power) & 0xFF : 0 }
        let bl = m.pb(captain, 0x25), sword = m.pb(captain, 0x21)
        let melee = (((bl * sword / 100 + sword / 2) * mult) / 3) & 0xFF
        let share = player ? max(0, 100 - m[DS.cargo + DS.cargoSize * slot + 8] - m[DS.cargo + DS.cargoSize * slot + 9]) : (sailOnly ? 25 : 50)
        var flags = v.rng(50) <= m.pb(captain, 0x20) ? 3 : 2
        if shot > 0 && sailOnly { flags |= 0x10 }
        if (1...4).contains(k) && f / 10 < 6 { flags |= 8 }
        return BattleUnit(side: s, fleet: f, slot: slot, captain: captain, x: 0, y: 0, heading: 0, flags: flags,
                          owner: owner, shot: shot, gunPower: guns, range: range, melee: melee, share: share)
    }

    /// The sea around the defender (0xEAF0): 6×6 world tiles, 8 hexes each, coasts worn away.
    static func buildMap(around c: (x: Int, y: Int), world: World, rng: inout GameRandom) -> [Int] {
        var land = [[Bool]](repeating: [Bool](repeating: false, count: 6), count: 6)
        for r in 0..<6 {
            for col in 0..<6 {
                land[r][col] = !world.isSea(x: Double(c.x - 2 + col) + 0.5, y: Double(c.y - 2 + r) + 0.5)
            }
        }
        var map = [Int](repeating: 1, count: width * height)
        for y in 0..<height {
            for x in 2..<50 { map[y * width + x] = land[y / 8][(x - 2) / 8] ? 0x84 : 1 }
        }
        for r in 0..<6 {
            for col in 0..<6 where !land[r][col] {
                for y in max(0, 8 * r - 4)..<min(48, 8 * r + 12) {
                    for x in (max(0, 8 * col - 4) + 2)..<(min(48, 8 * col + 12) + 2) {
                        let jr = min(5, y >> 3), jc = min(5, x >> 3)
                        map[y * width + x] = land[jr][jc] && rng(2) != 0 ? 0 : 1
                    }
                }
            }
        }
        for y in 0..<height {
            map[y * width] = map[y * width + 2]; map[y * width + 1] = map[y * width + 2]
            map[y * width + 50] = map[y * width + 49]; map[y * width + 51] = map[y * width + 49]
        }
        return coasts(map)
    }

    /// Coast chips (0xE8C2): a land cell takes 0x85..0x8C by which of its eight square
    /// neighbours are sea (bit set: 0x80 NW, 0x40 N, 0x20 NE, 0x10 W, 0x08 E, 0x04 SW, 0x02 S,
    /// 0x01 SE; clamped at the edge). Other patterns stay plain land 0x84.
    static let coastCells: [Int: Int] = {
        var t: [Int: Int] = [:]
        let table: [(Int, [Int])] = [(0x85, [0xD0, 0xD4, 0xF0, 0xF4]), (0x86, [0x40, 0x60, 0xC0, 0xE0]),
                                     (0x87, [0x68, 0x69, 0xE8, 0xE9]), (0x88, [0x10, 0x14, 0x80, 0x90, 0x94]),
                                     (0x89, [0x08, 0x09, 0x20, 0x28, 0x29]), (0x8A, [0x16, 0x17, 0x96, 0x97]),
                                     (0x8B, [0x01, 0x02, 0x03, 0x04, 0x06, 0x07]), (0x8C, [0x0B, 0x0F, 0x2B, 0x2F])]
        for (cell, masks) in table { for m in masks { t[m] = cell } }
        return t
    }()

    static func coasts(_ map: [Int]) -> [Int] {
        var out = map
        let around = [(-1, -1, 0x80), (0, -1, 0x40), (1, -1, 0x20), (-1, 0, 0x10), (1, 0, 0x08), (-1, 1, 0x04), (0, 1, 0x02), (1, 1, 0x01)]
        for y in 0..<height {
            for x in 0..<width where map[y * width + x] == 0x84 {
                var mask = 0
                for (dx, dy, bit) in around {
                    let nx = max(0, min(width - 1, x + dx)), ny = max(0, min(height - 1, y + dy))
                    if map[ny * width + nx] & 0x80 == 0 { mask |= bit }
                }
                if let c = coastCells[mask] { out[y * width + x] = c }
            }
        }
        return out
    }

    // MARK: unit state

    func slotAddress(_ u: BattleUnit, _ v: Voyage) -> Int { v.memory.slot(u.fleet, u.slot) }
    public func crew(_ i: Int, _ v: Voyage) -> Int { v.memory.word(slotAddress(units[i], v)) }
    public func hull(_ i: Int, _ v: Voyage) -> Int { v.memory[slotAddress(units[i], v) + 2] }
    public func maxHull(_ i: Int, _ v: Voyage) -> Int { v.memory[slotAddress(units[i], v) + 3] }
    public func rudder(_ i: Int, _ v: Voyage) -> Int { v.memory[slotAddress(units[i], v) + 4] }
    func sail(_ i: Int, _ v: Voyage) -> Int { v.memory[slotAddress(units[i], v) + 5] }
    public func guns(_ i: Int, _ v: Voyage) -> Int { v.memory[slotAddress(units[i], v) + 6] }

    /// 0xD232.
    public func alive(_ i: Int, _ v: Voyage) -> Bool { crew(i, v) != 0 && hull(i, v) != 0 && units[i].flags & 0x40 == 0 }

    func enemies(of i: Int) -> [Int] {
        let team = units[i].side & 1
        return (0..<4).filter { $0 & 1 != team }.flatMap { sides[$0] }
    }
    func friends(of i: Int) -> [Int] {
        let team = units[i].side & 1
        return (0..<4).filter { $0 & 1 == team }.flatMap { sides[$0] }
    }

    /// Officer max (0xD12F): on the player's own ship the best of admiral, first mate and chief navigator.
    func stat(_ i: Int, _ off: Int, _ v: Voyage) -> Int {
        let c = units[i].captain
        var best = v.memory.pb(c, off)
        if c == v.heroID {
            for o in v.officers where o.post == .firstMate || o.post == .chiefNavigator {
                best = max(best, v.memory.pb(o.person, off))
            }
        }
        return best
    }

    func hasGunnery(_ i: Int, _ v: Voyage) -> Bool {
        let c = units[i].captain
        if v.memory.pb(c, 0x30) & 4 != 0 { return true }
        guard c == v.heroID else { return false }
        return v.officers.contains { ($0.post == .firstMate || $0.post == .chiefNavigator) && v.memory.pb($0.person, 0x30) & 4 != 0 }
    }

    /// Movement points (0xD48D) and turn rate (0xD440) from the captain's raw seamanship and level.
    func movePoints(_ i: Int, _ v: Voyage) -> Int {
        let sea = v.memory.pb(units[i].captain, 0x1D), nav = v.memory.pb(units[i].captain, 0x24)
        let s = (sail(i, v) * windStrength * 8 / 150 + 20) * sea / 100
        return max(10, min(25, s + s * nav / 15))
    }

    func turnRate(_ i: Int, _ v: Voyage) -> Int {
        let sea = v.memory.pb(units[i].captain, 0x1D), nav = v.memory.pb(units[i].captain, 0x24)
        let r = rudder(i, v) * sea / 200
        return min(100, r + r * nav / 15)
    }

    /// Step cost (0xD3F1).
    func stepCost(_ i: Int, newDir nd: Int, heading h: Int, _ v: Voyage) -> Int {
        nd == h ? sail(i, v) * windCost[nd] / 100 + 5 : (windCost[nd] >= 3 ? 10 - 5 * rudder(i, v) / 100 : 5)
    }

    public func canFire(_ i: Int, at j: Int, fromX x: Int? = nil, y: Int? = nil, heading h: Int? = nil) -> Bool {
        let u = units[i], t = units[j]
        let ux = x ?? u.x, uy = y ?? u.y
        let d = Battle.distance(ux, uy, t.x, t.y)
        return u.shot > 0 && d >= 2 && d <= u.range && Battle.inArc(ux, uy, heading: h ?? u.heading, t.x, t.y)
    }

    public func canBoard(_ i: Int, _ j: Int) -> Bool { Battle.distance(units[i].x, units[i].y, units[j].x, units[j].y) == 1 }

    // MARK: reach

    public struct Reach {
        public var cells: [Int: (heading: Int, path: [Int])] = [:]
    }

    /// Hexes the unit can reach this turn (0xD813 for the player, 0xDC39 for the AI): up to ten
    /// steps ahead or 60° to either side; a turn needs the accumulator at 50 or more.
    public func reach(_ i: Int, _ v: Voyage, ai: Bool = false) -> [Int: (heading: Int, path: [Int])] {
        let u = units[i]
        let rate = turnRate(i, v)
        var best: [Int: (heading: Int, path: [Int], mp: Int)] = [:]
        best[u.y * Battle.width + u.x] = (u.heading, [], Int.max)
        func walk(_ x: Int, _ y: Int, _ h: Int, _ mp: Int, _ acc: Int, _ path: [Int]) {
            guard path.count < 10 else { return }
            let acc2 = min(100, acc + rate)
            for nd in [h, (h + 5) % 6, (h + 1) % 6] {
                if nd != h && acc2 < 50 { continue }
                let q = Battle.neighbour(x, y, nd)
                guard free(q.0, q.1) else { continue }
                let c = stepCost(i, newDir: nd, heading: h, v)
                guard c <= mp else { continue }
                // The AI marks the hex it steps from (0xDC39), so its last step is never taken.
                let key = ai ? y * Battle.width + x : q.1 * Battle.width + q.0
                let p2 = path + [nd]
                let mark = ai ? Array(path) : p2
                let markHeading = ai ? h : nd
                if let b = best[key], b.mp >= mp - c, !(b.path.count > mark.count) { } else {
                    best[key] = (markHeading, mark, mp - c)
                }
                walk(q.0, q.1, nd, mp - c, nd == h ? acc2 : 0, p2)
            }
        }
        walk(u.x, u.y, u.heading, movePoints(i, v), u.acc, [])
        return best.mapValues { ($0.heading, $0.path) }
    }

    /// Sails along `path` (0xA129), keeping the occupancy bits.
    mutating func sail(_ i: Int, path: [Int], _ v: Voyage) {
        let rate = turnRate(i, v)
        for nd in path {
            let u = units[i]
            let q = Battle.neighbour(u.x, u.y, nd)
            guard free(q.0, q.1) else { break }
            let bit = 0x20 << (u.side & 1)
            map[u.y * Battle.width + u.x] &= ~bit
            map[q.1 * Battle.width + q.0] |= bit
            let acc2 = min(100, u.acc + rate)
            units[i].acc = nd == u.heading ? acc2 : 0
            units[i].heading = nd
            units[i].x = q.0
            units[i].y = q.1
        }
    }

    // MARK: combat

    /// One volley (0xD6D3, 0xE428). Every volley hits.
    mutating func fire(_ i: Int, at j: Int, _ v: inout Voyage, world: World) {
        lastStrike = BattleStrike(attacker: i, target: j, boarding: false, serial: (lastStrike?.serial ?? 0) + 1)
        let u = units[i]
        let d = Battle.distance(u.x, u.y, units[j].x, units[j].y)
        let lead = stat(i, 0x1C, v), bl = stat(i, 0x25, v)
        let f = lead * bl / 100 + lead / 2
        let gunners = u.share * crew(i, v) / 100
        let n = min(guns(i, v) / 2, gunners / 2)
        let p = u.gunPower[max(0, min(4, d - 1))] * n / 10
        var dmg = hasGunnery(i, v) ? (p + 19) / 20 : (p + 39) / 40
        dmg = dmg * f / 100
        dmg = dmg * (50 + v.rng(stat(i, 0x21, v) / 2)) / 100
        dmg = max(1, min(dmg, 50 + v.rng(v.memory.pb(u.captain, 0x25) / 2)))
        var crit = 0
        if dmg >= 10 || v.rng(5) == 0 { crit = [1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 3, 3, 5, 5, 6, 6, 7][v.rng(19)] }
        if dmg >= 20 { crit = [3, 3, 5, 5, 6, 6, 7][v.rng(7)] }
        if dmg >= 40 { crit = 7 }
        let a = slotAddress(units[j], v)
        v.memory[a + 2] -= min(v.memory[a + 2], dmg)
        v.memory[a + 2] = min(v.memory[a + 2], v.memory[a + 3])
        v.memory.setWord(a, v.memory.word(a) - min(v.memory.word(a), v.rng(3) + dmg / 2))
        let cls = v.memory.shipClass(units[j].fleet, units[j].slot)
        if crit & 1 != 0, world.navigation.classes.indices.contains(cls) {
            v.memory[a + 3] = max(world.navigation.classes[cls].hull / 4, v.memory[a + 3] - 1)
        }
        if crit & 2 != 0 { v.memory[a + 5] -= min(v.memory[a + 5], v.rng(3) + dmg / 2) }
        if crit & 4 != 0 { v.memory[a + 4] -= min(v.memory[a + 4], v.rng(3) + dmg / 2) }
        log.lines.append("\(shipName(i, v))의 포격: \(shipName(j, v))에 \(dmg)의 피해")
        afterHit(i, j, &v)
        units[i].shot -= min(1, units[i].shot)
    }

    /// Sinking, derelicts and experience after a hit (0xE36E, 0xE3B0, 0xE30B).
    mutating func afterHit(_ i: Int, _ j: Int, _ v: inout Voyage) {
        let a = slotAddress(units[j], v)
        let own = units[i].owner == 0x80
        if v.memory[a + 2] == 0 {
            if own { gainExp(units[i].captain, 10 * v.memory[a + 3], &v) }
            log.lines.append(Korean.particles("\(shipName(j, v))(가) 침몰했습니다."))
            map[units[j].y * Battle.width + units[j].x] &= 0x1F
            v.memory[a + 8] = 0
            clearTargets(j)
        } else if v.memory.word(a) == 0 {
            if own { gainExp(units[i].captain, 10 * v.memory[a + 3], &v) }
            log.lines.append("\(shipName(j, v))의 선원이 전멸했습니다.")
            map[units[j].y * Battle.width + units[j].x] = (map[units[j].y * Battle.width + units[j].x] & 0x1F) | 0x80
            clearTargets(j)
        } else if own {
            gainExp(units[i].captain, 10, &v)
        }
    }

    mutating func clearTargets(_ j: Int) {
        for k in units.indices where units[k].target == j {
            units[k].target = nil
            units[k].flags &= ~0x80
        }
    }

    /// Melee strength for one exchange (0xD656), 1...50.
    func meleeBlow(_ i: Int, _ v: inout Voyage) -> Int {
        let u = units[i]
        let men = (crew(i, v) + v.rng(10)) * u.share / 100
        let x = (u.melee * men / 100) * (50 + v.rng(stat(i, 0x21, v) / 2)) & 0xFFFF
        return max(1, min(50, x / 100))
    }

    /// Boarding (0xE612): both crews bleed; hulls hold.
    mutating func board(_ i: Int, _ j: Int, _ v: inout Voyage) {
        lastStrike = BattleStrike(attacker: i, target: j, boarding: true, serial: (lastStrike?.serial ?? 0) + 1)
        let ta = slotAddress(units[j], v), aa = slotAddress(units[i], v)
        let hit = meleeBlow(i, &v)
        v.memory.setWord(ta, v.memory.word(ta) - min(v.memory.word(ta), hit))
        let back = meleeBlow(j, &v)
        v.memory.setWord(aa, v.memory.word(aa) - min(v.memory.word(aa), back))
        log.lines.append(Korean.particles("\(shipName(i, v))(가) \(shipName(j, v))에 백병전: 적 \(hit)명, 아군 \(back)명 쓰러짐"))
        if v.memory.word(ta) == 0 {
            if units[i].owner == 0x80 { gainExp(units[i].captain, 10 * v.memory[ta + 3], &v) }
            map[units[j].y * Battle.width + units[j].x] = (map[units[j].y * Battle.width + units[j].x] & 0x1F) | 0x80
            clearTargets(j)
        } else if units[i].owner == 0x80 {
            gainExp(units[i].captain, 10, &v)
        }
    }

    /// Battle experience (0xE30B → 0x1B570).
    func gainExp(_ p: Int, _ amount: Int, _ v: inout Voyage) {
        guard p < 120 else { return }
        let a = DS.person(p)
        var exp = v.memory.word(a + 0x28) + amount, lvl = v.memory[a + 0x25]
        let ups = Officers.levelUp(level: &lvl, exp: &exp)
        v.memory.setWord(a + 0x28, min(0xFFFF, exp))
        v.memory[a + 0x25] = lvl
        guard ups > 0 else { return }
        for s in 0..<4 { v.memory[a + 0x1C + s] += min(v.rng(3), 100 - v.memory[a + 0x1C + s]) }
        for _ in 0..<ups {
            v.memory[a + 0x20] = min(100, v.memory[a + 0x20] + v.rng(3))
            v.memory[a + 0x21] = min(100, v.memory[a + 0x21] + v.rng(2))
        }
    }

    public func shipName(_ i: Int, _ v: Voyage) -> String {
        let u = units[i]
        if u.fleet == v.playerFleet { return v.memory.string(DS.ship + DS.shipSize * u.slot, max: 14) }
        let cls = v.memory.shipClass(u.fleet, u.slot)
        return "\(v.memory.person(u.captain).name)의 \(cls < 25 ? Battle.classNames[cls] : "배")"
    }

    static let classNames = ["발사", "한자 콕", "다우", "버스", "타렛테", "카라벨 라티나", "카라벨 레돈다", "브리간틴", "나오", "카락",
                             "갤리온", "지벡", "피네스", "슬루프", "프리게이트", "바그", "쉽", "정크", "경갤리", "플랜더스 갤리",
                             "베네치안 갤리", "라레아르", "철갑선", "안택선", "관선"]
}
