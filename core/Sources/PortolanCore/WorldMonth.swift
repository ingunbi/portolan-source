import Foundation

// The world's monthly turn (docs/re/fleets.md §7): nation power from the ports (0x17464),
// enemies, policies and targets (0x179A0), rebuilt and relaunched fleets (0x184AC), persons
// moving between taverns (0x184D2) and rivals keeping ahead of the player (0x1863C, 0x186DF).
// Relations (0x17BD1, docs/re/war.md): only friendly pairs warm up; the port-taking branch
// can never run in the original (it compares the whole state byte), and is left out.

extension Voyage {
    /// Nation record +0 (power), read and written as the original keeps it.
    func power(_ n: Int) -> Int { n < 7 ? memory.word(0x1106 + 32 * n) : 0 }

    mutating func worldMonth(in world: World) {
        nationPower()
        for n in 0..<7 { chooseEnemy(n) }
        for n in 0..<7 { choosePolicy(n) }
        relationsMonth()
        rebuildFleets(in: world)
        relaunchFleets(in: world)
        movePersons()
        keepRivalsAhead()
        upgradeRivals(in: world)
    }

    /// 0x17464: economy and industry of each nation's ports by region, weighted.
    mutating func nationPower() {
        var eco = [[Int]](repeating: [Int](repeating: 0, count: 8), count: 7)
        var ind = eco
        for p in 0..<min(100, markets.count) {
            let n = min(6, markets[p].nation), r = min(7, memory[DS.market + DS.marketSize * p + 0x1C])
            ind[n][r] += markets[p].industry
            eco[n][r] += markets[p].economy * (developing.contains(p) ? 2 : 1)
        }
        let w = [4, 3, 3, 2, 3, 1, 1, 1]
        var total = 0
        for n in 0..<6 {
            var p = eco[n][0] / w[0]
            for r in 4...7 { if ind[n][r] >= 300 { p += eco[n][r] / w[r] } else { break } }
            for r in 1...2 where ind[n][r] >= 300 { p += eco[n][r] / w[r] }
            if (ind[n][2] >= 300 || ind[n][4] >= 300) && ind[n][3] >= 300 { p += eco[n][3] / w[3] }
            memory.setWord(0x1106 + 32 * n, min(0xFFFF, p))
            total += p
        }
        memory.setWord(0x1106 + 32 * 6, total / 6)
    }

    /// 0x175FD: the nation that looks weakest to it, or the player when he is hated enough.
    mutating func chooseEnemy(_ n: Int) {
        let fam = DS.family(heroID)
        if n == 6 {
            let m = (0..<6).max { (100 - memory.nb(6, 0xB + $0)) * power($0) < (100 - memory.nb(6, 0xB + $1)) * power($1) } ?? 0
            memory.setNB(6, 2, rng(50) + 100 < abs(200 - memory[fam + 0x0C]) ? 7 : m)
            return
        }
        let m = (0..<7).filter { $0 != n }.min { memory.nb(n, 0xB + $0) * power($0) / 100 < memory.nb(n, 0xB + $1) * power($1) / 100 } ?? 6
        let st = standing[n]
        memory.setNB(n, 2, rng(max(1, 180 - memory.nb(n, 9))) + 100 < abs(200 - st) ? 7 : m)
    }

    /// 0x17766 and 0x178BF: what the nation's fleets do this month, and where.
    mutating func choosePolicy(_ n: Int) {
        let enemy = memory.nb(n, 2)
        if n == 6 {
            memory.setNB(6, 3, enemy == 7 ? 7 : 8)
        } else {
            let r = rng(power(enemy) >= power(n) ? 120 : 90)
            memory.setNB(n, 3, memory.nb(n, 9) > r ? (power(enemy) > power(n) ? 4 : 5) : rng(3))
        }
        // Target port (DS:0xAC58 predicates): free ports for trade and investment, own ports,
        // the far east, or ports of the player's nation or of the enemy.
        let policy = memory.nb(n, 3)
        let capitals = Set((0..<7).map { memory.nb($0, 0xA) })
        let nations = markets.map(\.nation)
        let mine = memory.pb(heroID, 0x31) & 0xF
        let pick: (Int) -> Bool
        switch policy {
        case 0, 1: pick = { nations[$0] == 6 }
        case 2: pick = { nations[$0] == n && !capitals.contains($0) }
        case 6: pick = { (75...92).contains($0) }
        case 3, 7: pick = { nations[$0] == mine && !capitals.contains($0) }
        default: pick = { nations[$0] == min(6, enemy) && !capitals.contains($0) }
        }
        for p in 0..<min(100, markets.count) where pick(p) && rng(5) == 0 {
            memory.setNB(n, 4, p)
            return
        }
    }

    /// War-state table DS:0xAC74 (12 per relation band, 3 per power class, one per flag
    /// column); bands past the end read on into DS:0xAC98 as the original does.
    static let warTable = [0, 3, 0, 1, 3, 5, 0, 3, 1, 1, 3, 5, 6, 4, 9, 1, 3, 10, 6, 7, 9, 0, 3, 10,
                           6, 4, 2, 6, 3, 1, 6, 7, 8, 6, 7, 8, 0x78, 5, 0x89, 7, 0x99, 8, 0x78, 7, 0x89, 7, 0x99, 9]

    /// 0x17BD1 → 0x179AD, 0x17B46: each pair's state from power and relation; state 1 (no
    /// alliance or blockade flags) raises relations by 3–7 both ways.
    mutating func relationsMonth() {
        for a in 0..<6 {
            for b in 0..<6 {
                if a == b {
                    memory.setNB(a, 0x12 + a, 0)
                    continue
                }
                let pa = Int(Int16(truncatingIfNeeded: power(a))), pb = Int(Int16(truncatingIfNeeded: power(b)))
                let pc = pa / 2 > pb ? 0 : pb / 2 > pa ? 1 : pb < pa ? 2 : 3
                let f = memory.nb(a, 0x12 + b), r = memory.nb(a, 0xB + b)
                let fc = f & 0x20 != 0 ? 0 : f & 0x10 != 0 ? 1 : 2
                let i = min(Self.warTable.count - 1, 12 * ((r + 9) / 40) + 3 * pc + fc)
                var v = Self.warTable[i]
                switch v {
                case 7: v = rng(100) >= r ? 0 : 3
                case 8: v = rng(100) <= r ? 0 : 2
                case 9: v = rng(20) + 30 <= r ? 0 : 2
                case 10: v = rng(10) + 30 > r ? 2 : 0
                default: break
                }
                memory.setNB(a, 0x12 + b, (f & 0xF0) | (v & 0xF))
                if memory.nb(a, 0x12 + b) == 1 {
                    let x = (memory.nb(b, 0xB + a) + rng(5) + 3) & 0xFF
                    memory.setNB(b, 0xB + a, x)
                    memory.setNB(a, 0xB + b, x)
                }
            }
        }
    }

    /// A blockade keeps the player's people out of a port by day: guards stand by the harbour
    /// door, so only the harbour office can be reached (0x8993, msg 622).
    public func blockaded(port p: Int) -> Bool {
        guard p < markets.count, (12..<60).contains(tick) else { return false }
        let n = markets[p].nation, mine = memory.pb(heroID, 0x31) & 0xF
        return n < 6 && mine < 7 && memory.nb(n, 0x12 + mine) & 0x10 != 0
    }

    /// 0x17CC3, 0x17DB7, 0x17EAC: empty fleets of each nation get new ships by its power.
    mutating func rebuildFleets(in world: World) {
        for n in 0..<7 {
            let tier = min(power(n) / 500, 2)
            refill(fleets: (1...4).map { 10 * n + $0 }, ships: power(n) / 50 + 5, table: 0xAC98, base: 0, heavy: false, tier: tier, n: n, world)
            refill(fleets: [10 * n + 5, 10 * n + 6], ships: power(n) / 75 + 5, table: 0xACC2, base: 8, heavy: true, tier: tier, n: n, world)
            refill(fleets: [10 * n + 7, 10 * n + 8, 10 * n + 9], ships: 30, table: 0xACEC, base: 0, heavy: true, tier: tier, n: n, world)
        }
    }

    private mutating func refill(fleets: [Int], ships total: Int, table: Int, base: Int, heavy: Bool, tier: Int, n: Int, _ world: World) {
        var left = total
        for f in fleets where f < Fleets.count && f != playerFleet {
            guard !memory.fleetActive(f), !memory.slotUsed(f, 0) else { continue }
            let count = min(10, left)
            left -= count
            for s in 0..<count {
                let w = memory.word(table + 2 * (3 * n + tier))
                let cls = min(24, ((w >> (4 * rng(3))) & 0xF) + base)
                let tpl = DS.ship + DS.shipSize * (40 + cls)
                let a = memory.slot(f, s)
                let c = world.navigation.classes[cls]
                memory.setWord(a, memory.word(tpl + 0x15))
                memory[a + 2] = c.hull
                memory[a + 3] = c.hull
                memory[a + 4] = c.rudder
                memory[a + 5] = c.sail
                memory[a + 6] = memory[tpl + 0x14]
                memory[a + 7] = 40 + cls
                memory[a + 8] = 0x10 | (4 + rng(3) - (heavy ? 3 : 0))
            }
        }
    }

    /// 0x18362: fleets with ships but no admiral sail again from their capital.
    mutating func relaunchFleets(in world: World) {
        for f in 0..<Fleets.count where f % 10 != 0 && f != playerFleet && !memory.fleetActive(f) {
            let ships = (0..<10).filter { memory.slotUsed(f, $0) }.count
            guard ships >= rng(2) + 4 else { continue }
            let n = f / 10
            var adm: Int?
            if rng(2) == 0 {
                adm = (6..<120).first { p in
                    let r = memory.person(p)
                    return memory.pb(p, 0x31) & 0x20 != 0 && memory.pb(p, 0x31) & 0x10 == 0 && r.employer == 0xFF
                        && (f < 60 ? memory.pb(p, 0x31) & 0xF == n : memory.pb(p, 0x2F) & 3 >= 2)
                }
            }
            if adm == nil { adm = generatePerson(nation: f < 60 ? n : rng(6), type: f < 60 ? rng(2) : 2) }
            guard let a = adm else { continue }
            memory.setPB(a, 0x2C, f)
            memory.setPB(a, 0x2D, 0xFF)
            memory.setPB(a, 0x2E, 1)
            let capital = memory.nb(min(6, n), 0xA)
            let at = memory.portXY(capital)
            memory.setFW(f, FleetField.x, at.0)
            memory.setFW(f, FleetField.y, at.1)
            memory.setFB(f, FleetField.admiral, a)
            memory.setFB(f, FleetField.home, capital)
            memory.setFW(f, FleetField.funds, rng(3) + power(min(6, n)) / 10 + 1)
            memory.setFB(f, FleetField.good, 0xFF)
            memory.setFW(f, FleetField.amount, 0)
            for k in 0..<4 { memory.setFB(f, FleetField.treasure + k, 0xFF) }
            memory.setFB(f, FleetField.stay, rng(10) + 5)
            memory.setFB(f, FleetField.state, 0x31)
            memory.recomputeStrength(f)
            sendToPort(f, mission: 0, port: capital)
            memory.setFB(f, FleetField.state, memory.fb(f, FleetField.state) | 0x31)
        }
    }

    /// 0x17F8B: a new face for an empty person slot, named from NAME.TBL.
    mutating func generatePerson(nation n: Int, type: Int) -> Int? {
        guard let p = (6..<120).first(where: { memory.pb($0, 0x31) & 0x20 == 0 && memory.pb($0, 0x2C) == 0xFF && memory.pb($0, 0x2E) == 0 }) else {
            return nil
        }
        let a = DS.person(p)
        let names = DataSegment.names
        if names.count >= 6 * 32 {
            memory.setString(a, names[n * 32 + rng(16)], max: 13)
            memory.setString(a + 0x0D, names[n * 32 + 16 + rng(16)], max: 13)
        }
        memory.setWord(a + 0x1A, rng(0x3FFF) | 0xC000)
        for k in 0..<8 { memory[a + 0x1C + k] = rng(35) + 60 }
        memory[a + 0x24] = min(100, max(rng(5) + 8, memory[a + 0x24] + rng(4) + 2))
        memory[a + 0x25] = min(100, max(rng(5) + 8, memory[a + 0x25] + rng(4) + 2))
        memory.setWord(a + 0x26, 0)
        memory.setWord(a + 0x28, 0)
        memory[a + 0x2A] = rng(16) + 20
        memory[a + 0x2C] = 0xFF
        memory[a + 0x2D] = 0xFF
        memory[a + 0x2E] = 0
        memory[a + 0x2F] = rng(16) << 4 | type
        memory[a + 0x30] = rng(16)
        memory[a + 0x31] = n | 0x20
        return p
    }

    /// 0x184D2: navigators drift between taverns; empty slots fill with new faces.
    mutating func movePersons() {
        for p in 6..<120 {
            let a = DS.person(p)
            if memory[a + 0x31] & 0x20 != 0 {
                guard memory[a + 0x2C] == 0xFF, memory[a + 0x2D] < 100, rng(3) == 0 else { continue }
                memory[a + 0x2D] = max(0, min(96, memory[a + 0x2D] + rng(5) - 2))
            } else if memory[a + 0x2C] == 0xFF && memory[a + 0x2E] == 0 && rng(3) == 0 {
                if let q = generatePerson(nation: rng(6), type: rng(3)), q == p { memory[a + 0x2D] = rng(42) }
            }
        }
    }

    /// 0x1863C: the other heroes stay a level or two ahead of the player.
    mutating func keepRivalsAhead() {
        let me = DS.person(heroID)
        for h in 0..<6 where h != heroID {
            let a = DS.person(h)
            if memory[me + 0x24] > memory[a + 0x24] {
                let d = memory[me + 0x24] - memory[a + 0x24] + rng(2) + 1
                memory[a + 0x24] = min(100, memory[a + 0x24] + d)
                for _ in 0..<d {
                    memory[a + 0x1C] = min(100, memory[a + 0x1C] + rng(3))
                    for s in 1...3 { memory[a + 0x1C + s] = min(100, memory[a + 0x1C + s] + rng(5)) }
                }
            }
            if memory[me + 0x25] > memory[a + 0x25] {
                let d = (memory[me + 0x25] - memory[a + 0x25]) / 2 + rng(2) + 1
                memory[a + 0x25] = min(100, memory[a + 0x25] + d)
                for _ in 0..<d {
                    memory[a + 0x20] = min(100, memory[a + 0x20] + rng(5))
                    memory[a + 0x21] = min(100, memory[a + 0x21] + rng(5))
                }
            }
        }
    }

    /// 0x186DF: rival heroes and growing admirals get a better ship each month.
    mutating func upgradeRivals(in world: World) {
        memory.recomputeStrength(playerFleet)
        for f in 0..<Fleets.count where f != playerFleet {
            let a = memory.fb(f, FleetField.admiral)
            let hero = f % 10 == 0 && f < 60
            guard hero || (a < 120 && memory.pb(a, 0x2F) & 4 != 0 && memory.pb(a, 0x31) & 0x20 != 0 && memory.pb(a, 0x2E) == 1 && (f % 10 >= 5 || f > 60)) else { continue }
            guard memory.fb(f, FleetField.strength) < memory.fb(playerFleet, FleetField.strength) || rng(3) == 0 else { continue }
            let type = hero ? [0, 1, 0, 2, 0, 3][min(5, f / 10)] : (f % 10 <= 6 ? 1 : 2)
            let cls = min(24, ((memory[0xAD16 + type] >> (4 * min(1, rank / 5))) & 0xF) + 9)
            let slot = (0..<10).first { !memory.slotUsed(f, $0) }
                ?? (0..<10).min { memory[memory.slot(f, $0) + 7] < memory[memory.slot(f, $1) + 7] } ?? 0
            let tpl = DS.ship + DS.shipSize * (40 + cls)
            let s = memory.slot(f, slot)
            let c = world.navigation.classes[cls]
            memory.setWord(s, memory.word(tpl + 0x15))
            memory[s + 2] = c.hull
            memory[s + 3] = c.hull
            memory[s + 4] = c.rudder
            memory[s + 5] = c.sail
            memory[s + 6] = memory[tpl + 0x14]
            memory[s + 7] = 40 + cls
            memory[s + 8] = 0x10 | (1 + rng(3))
            memory.recomputeStrength(f)
            if hero && memory.fleetActive(f) == false && a < 120 && memory.pb(a, 0x31) & 0x20 != 0 { continue }
        }
    }
}

extension DataSegment {
    /// NAME.TBL: 13-byte names, 16 given then 16 family names for each of six nationalities.
    nonisolated(unsafe) static var names: [String] = []

    static func loadNames(_ d: [UInt8]) {
        var seg = DataSegment()
        names = (0..<(d.count / 13)).map { i in
            for k in 0..<13 { seg[k] = Int(d[i * 13 + k]) }
            return seg.string(0, max: 13)
        }
    }
}
