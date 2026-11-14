import Foundation

// Discoveries (docs/re/town.md §10): sighting ports and villages at sea (0x3070D), landing
// and searching a village (0x34651, 0x340FD), and the patrons and map makers who pay for
// reports (0x2CEA0, 0x2D3A0). Sites: DS:0x7E88 × 7 bytes; texts: COLONY.DAT.

public enum Discovery {
    public static let sites = 0x7E88, siteSize = 7
    /// Exploration bitmap of 90×45 cells of 24×24 tiles (DS:0xD74, 12 bytes a row, high bit
    /// first), with the count of cells charted ([0xF9A]) and charted since the last report ([0xF9C]).
    public static let charted = 0xD74, chartedTotal = 0xF9A, chartedNew = 0xF9C
    /// Route nodes in charted waters, one bit each (DS:0xFD2, rebuilt by 0x22A95).
    public static let chartedNodes = 0xFD2
    public static let categories = ["보물", "원주민", "희귀한 동물", "식물", "유적", "괴물", "자연", "원주민"]

    public static func site(_ i: Int) -> Int { sites + siteSize * i }
}

public struct DiscoveryInfo: Equatable {
    public let index: Int
    public let name: String
    public let description: String
    public let category: Int
    public let value: Int
}

extension World {
    public func discovery(_ i: Int) -> (name: String, description: String) {
        var m = DataSegment()
        loadDiscovery(i, into: &m)
        return (m.string(0xBEF6, max: 18), m.string(0xBEF6 + 0x13, max: 200))
    }
}

extension Voyage {
    /// New game (0x16177): fifty random sites come alive; ten others hide a relic whose
    /// treasure map (item 0x50 + k) points at them.
    mutating func seedDiscoveries(in world: World? = nil) {
        // 98 sites (0x16177); records 98 and 99 are dummies at (0,0) and (1,0).
        for i in 0..<98 { memory[Discovery.site(i) + 6] |= 0x80 }
        var n = 0
        while n < 50 {
            let i = rng(98)
            if memory[Discovery.site(i) + 6] & 0x80 != 0 {
                memory[Discovery.site(i) + 6] &= ~0x80
                n += 1
            }
        }
        var k = 0
        while k < 10 {
            let i = rng(98)
            let a = Discovery.site(i)
            if memory[a + 6] & 0x80 != 0 && memory[a + 4] < 0x5A {
                memory[a + 4] = 0x5A + k
                memory[0x8144 + 26 * (0x50 + k) + 0x18] = i
                k += 1
            }
        }
        // Charted at the start (0x160DF): cells x 4...16, y 8...17 — Europe, the Mediterranean
        // and north-west Africa — and the route nodes in them.
        for b in 0..<(12 * 45) { memory[Discovery.charted + b] = 0 }
        memory.setWord(Discovery.chartedTotal, 0)
        for cy in 8...17 { for cx in 4...16 { chartCell(cx, cy, world) } }
        memory.setWord(Discovery.chartedNew, 0)
    }

    /// The best intuition aboard: admiral and companions.
    var lookout: Int { ([captain.intuition] + officers.map { $0.stats[3] }).max() ?? 0 }

    /// After each step at sea (0x3070D): a port or a village within sight is discovered, at
    /// most one per call, and the 24×24 cell is charted.
    mutating func lookAround(in world: World) {
        let px = Int(x), py = Int(y)
        chart(cellX: px / 24, cellY: py / 24, in: world)
        let fog = event == .fog && eventAnnounced
        func seen(_ x: Int, _ y: Int) -> Bool {
            var dx = abs(x - px)
            if dx > World.width / 2 { dx = World.width - dx }
            let dy = abs(y - py)
            if dx <= 2 && dy <= 2 { return true }
            let r = sightRange                                                     // [0xC176], 0x3070D
            return !fog && dx <= r && dy <= r && rng(200) < lookout
        }
        for p in 0..<min(130, world.ports.count) {
            let a = DS.port + DS.portSize * p + 0x13
            guard memory[a] & 0x30 == 0, seen(world.ports[p].x, world.ports[p].y) else { continue }
            memory[a] |= 0x10
            note("제독, \(world.ports[p].name)항을 발견했습니다.")
            writeLog(9, p)                                                     // 0x30870
            let region = p < 100 ? memory[DS.market + DS.marketSize * p + 0x1C] : 0
            addAdventureFame(p < 100 ? 25 * region : 50)
            return
        }
        for i in 0..<100 {
            let a = Discovery.site(i)
            guard memory[a + 6] & 0xC0 == 0, seen(memory.word(a), memory.word(a + 2)) else { continue }
            memory[a + 6] |= 0x40
            note("제독, 부락을 발견했습니다.")
            addAdventureFame(50)
            return
        }
    }

    /// Marks a 24×24 cell explored and the route nodes in it usable for 항구이동.
    mutating func chart(cellX cx: Int, cellY cy: Int, in world: World) { chartCell(cx, cy, world) }

    mutating func chartCell(_ cx: Int, _ cy: Int, _ world: World?) {
        guard (0..<90).contains(cx), (0..<45).contains(cy) else { return }
        let a = Discovery.charted + cy * 12 + cx / 8, bit = 0x80 >> (cx & 7)
        guard memory[a] & bit == 0 else { return }
        memory[a] |= bit
        memory.setWord(Discovery.chartedTotal, memory.word(Discovery.chartedTotal) + 1)
        memory.setWord(Discovery.chartedNew, memory.word(Discovery.chartedNew) + 1)
        guard let g = world?.routes else { return }
        for (i, n) in g.nodes.enumerated() where n.x / 24 == cx && n.y / 24 == cy {
            memory[Discovery.chartedNodes + i / 8] |= 0x80 >> (i & 7)
        }
    }

    func nodeCharted(_ i: Int) -> Bool { memory[Discovery.chartedNodes + i / 8] & (0x80 >> (i & 7)) != 0 }

    /// 항구이동 (menu 29): sails to a port along the route graph through charted waters. The
    /// original needs a first mate who knows surveying (msg 855).
    public var canAutoSail: Bool { officer(holding: .firstMate).map { $0.skills & 0x10 != 0 } ?? false }

    @discardableResult
    public mutating func autoSail(to port: Harbor, in world: World, anyWaters: Bool = false) -> Bool {
        guard !ashore, x.isFinite, y.isFinite, y >= 0, y < Double(World.height),
              let g = world.routes, !g.nodes.isEmpty, let berth = world.berth(of: port) else { return false }
        let s = g.nearest(x: Int(world.wrapX(x)), y: Int(y)) & 0x7FFF, goal = g.nearest(x: port.x, y: port.y) & 0x7FFF
        guard g.nodes.indices.contains(s), g.nodes.indices.contains(goal) else { return false }
        var cost = [Int](repeating: Int.max, count: g.nodes.count), from = [Int](repeating: -1, count: g.nodes.count)
        var open: Set<Int> = [s]
        cost[s] = 0
        while let n = open.min(by: { cost[$0] < cost[$1] }) {
            open.remove(n)
            if n == goal { break }
            for k in 0..<4 {
                let m = g.nodes[n].next[k]
                guard g.nodes.indices.contains(m), anyWaters || m == goal || nodeCharted(m) else { continue }
                let c = cost[n] + g.nodes[n].cost[k]
                if c < cost[m] {
                    cost[m] = c
                    from[m] = n
                    open.insert(m)
                }
            }
        }
        guard cost[goal] != Int.max else { return false }
        var path: [Int] = []
        var n = goal
        while n != s && n >= 0 {
            path.append(n)
            n = from[n]
        }
        var plannedRoute = path.reversed().map { [Double(g.nodes[$0].x) + 0.5, Double(g.nodes[$0].y) + 0.5] }
        // The last stretch, often up a river, goes tile by tile.
        let last = plannedRoute.last.map { ($0[0], $0[1]) } ?? (x, y)
        guard let tail = world.seaPath(from: last, to: berth), !tail.isEmpty else { return false }
        plannedRoute += tail.map { [$0.0, $0.1] }
        guard let first = plannedRoute.first else { return false }
        // Commit only after the whole route has been found; a failed order keeps the old one.
        route = Array(plannedRoute.dropFirst())
        setCourse(x: first[0], y: first[1])
        return true
    }

    mutating func addAdventureFame(_ n: Int) {
        guard n > 0 else { return }
        fame[2] = min(50000, fame[2] + n)
        note("모험가로서의 명성이 \(n) 올랐습니다.")
    }

    /// A sighted village close enough to land at.
    public var landingSite: Int? {
        let px = Int(x), py = Int(y)
        return (0..<100).first { i in
            let a = Discovery.site(i)
            guard memory[a + 6] & 0xC0 == 0x40 else { return false }
            var dx = abs(memory.word(a) - px)
            if dx > World.width / 2 { dx = World.width - dx }
            return dx <= 2 && abs(memory.word(a + 2) - py) <= 2
        }
    }

    /// 보물탐색 (0x340FD): needs food; `7·intuition/20 + 3·luck/20 + hospitality` must beat the
    /// site's value. Natives and monsters may cost sailors on the way (msg 430).
    public mutating func searchSite(_ i: Int, bonus: Int, in world: World) -> (found: Bool, lines: [String]) {
        guard food > 0 else { return (false, ["식량이 바닥났습니다.\n수색을 그만둡시다."]) }
        if let k = ships.firstIndex(where: { $0.food > 0 }) { ships[k].food -= min(ships[k].food, 10) }
        let a = Discovery.site(i)
        let score = 7 * lookout / 20 + 3 * captain.luck / 20 + bonus
        guard score > memory[a + 5] else { return (false, ["아무것도 찾지 못했습니다."]) }
        memory[a + 6] |= 0x20
        let d = world.discovery(i)
        var lines: [String] = []
        let cat = memory[a + 6] & 7
        if cat == 1 || cat == 5, !ships.isEmpty {
            let lost = min(ships[0].crew, rng(10) + 1)
            ships[0].crew -= lost
            lines.append(Korean.particles("\(d.name)의 습격을 받았습니다.\n선원 \(lost)명이 희생되었습니다."))
        }
        lines.append(Korean.particles("\(d.name)(를) 발견했습니다."))
        if cat == 0 { soundCues.append("treasure") }                            // 0x34192: a treasure only
        lines.append(d.description)
        if memory[a + 4] != 0 && items.count < 20 {
            items.append(memory[a + 4])
            memory[a + 4] = 0
        }
        return (true, lines)
    }

    /// 환대: two barrels of food make the villagers help (+5 to the search).
    public mutating func hostVillagers() -> Bool {
        guard let k = ships.firstIndex(where: { $0.food >= 20 }) else { return false }
        ships[k].food -= 20
        return true
    }

    /// 식량약탈: food for the taking, a quarter of the time a fight; charm and luck suffer.
    public mutating func plunderVillage() -> (food: Int, fight: Bool) {
        let n = (rng(5) + 2) * 10
        if let k = ships.indices.first { ships[k].food += n * 10 }
        captain.charm = max(0, captain.charm - 2)
        captain.luck = max(0, captain.luck - 2)
        let fight = rng(4) == 0
        if fight, !ships.isEmpty { ships[0].crew -= min(ships[0].crew, rng(5) + 1) }
        return (n, fight)
    }

    // MARK: patrons and map makers (building 7)

    /// The story character living in this port, if any (DS:0x29B2, +0x14 port).
    public func resident(in port: Int) -> Int? {
        (0..<20).first { k in
            let r = DS.npc + DS.npcSize * k
            return !(10...17).contains(k) && memory[r + 0x14] == port && (0...3).contains(memory[r + 0x10])
        }
    }

    /// Skills taught at residences: map making by map makers (seamanship, knowledge and
    /// intuition 75), surveying in Naples (70/80/70), gunnery in Hamburg (leadership 75,
    /// knowledge 65, courage 80). The fee wraps at 16 bits as in the original.
    public func skillOffer(_ k: Int) -> (bit: Int, name: String, ok: Bool, fee: Int) {
        let fee = min(60000, ((5000 / (captain.charm / 5 + 1) + 200) * 100) & 0xFFFF)
        switch residentType(k) {
        case 1: return (8, "지도작성술", captain.seamanship >= 75 && captain.knowledge >= 75 && captain.intuition >= 75, fee)
        case 2: return (0x10, "측량술", captain.seamanship >= 70 && captain.knowledge >= 80 && captain.intuition >= 70, fee)
        default: return (4, "포술", captain.leadership >= 75 && captain.knowledge >= 65 && captain.courage >= 80, fee)
        }
    }

    public mutating func learnSkill(at k: Int) -> Bool {
        let o = skillOffer(k)
        guard o.ok, captain.skills & o.bit == 0, pay(o.fee) else { return false }
        captain.skills |= o.bit
        memory.setPB(heroID, 0x30, captain.skills)
        return true
    }

    public func residentType(_ k: Int) -> Int { memory[DS.npc + DS.npcSize * k + 0x10] }

    public func contracted(_ k: Int) -> Bool { memory[DS.npc + DS.npcSize * k + 0x13] & 0x10 != 0 }

    /// 계약 (msgs 480–483, 495–497): one patron and one map maker at a time; map makers want
    /// a map-making hero (skill 0x08).
    public mutating func contract(_ k: Int) -> Bool {
        let t = residentType(k)
        if t == 1 && captain.skills & 8 == 0 { return false }
        for j in 0..<20 where residentType(j) == t { memory[DS.npc + DS.npcSize * j + 0x13] &= ~0x10 }
        memory[DS.npc + DS.npcSize * k + 0x13] |= 0x10
        return true
    }

    /// 발견물보고 (0x2CEA0): every site found and not reported is paid for.
    public mutating func reportDiscoveries(to k: Int, in world: World) -> [String] {
        guard contracted(k), residentType(k) == 0 else { return [] }
        let pay = memory[DS.npc + DS.npcSize * k + 0x13] & 3
        var lines: [String] = []
        for i in 0..<100 {
            let a = Discovery.site(i)
            guard memory[a + 6] & 0x30 == 0x20 else { continue }
            let v = memory[a + 5]
            let gold = 50 * v * (5 - pay) * (v == 100 ? 4 : 1)
            earn(gold)
            fame[2] = min(50000, fame[2] + v * (v == 100 ? 15 : 8))
            memory[a + 6] |= 0x10
            lines.append(Korean.particles("\(world.discovery(i).name)(를) 발견했다니 대단하오! 사례금 금화 \(gold)닢을 드리오."))
        }
        return lines.isEmpty ? ["새로운 발견은 없었나 보군.\n기대하고 있으니 더 힘써 주시오."] : lines
    }

    /// 지리보고 (0x2D3A0): charted cells since the last report.
    public mutating func reportGeography(to k: Int) -> String {
        guard contracted(k), residentType(k) == 1 else { return "" }
        let n = memory.word(Discovery.chartedNew)
        guard n > 0 else { return "조사가 전혀 진척되지 않았군요. 더 힘써 주세요." }
        let pay = memory[DS.npc + DS.npcSize * k + 0x13] & 3
        earn(20 * n * (5 - pay))
        fame[2] = min(50000, fame[2] + 5 * n)
        memory.setWord(Discovery.chartedNew, 0)
        let paid = "수고하셨습니다. 보수로 금화 \(20 * n * (5 - pay))닢을 드립니다."      // 508
        guard memory.word(Discovery.chartedTotal) >= 3300 else { return paid }
        // 0x2D3C1: the world is complete (msg 507, GRAPH.DAT 63); every cell is marked charted.
        for row in 0..<45 {
            for k in 0..<11 { memory[0xD74 + 12 * row + k] = 0xFF }
            memory[0xD74 + 12 * row + 11] = 0xC0
        }
        return "세계지도가 마침내 완성되었군요!\n" + paid
    }

    /// The world chart is complete (3300 charted cells or more).
    public var worldCharted: Bool { memory.word(Discovery.chartedTotal) >= 3300 }

    /// 모험이야기 (0x2D02A): rumour of the first live village not yet sighted, to 5°.
    public mutating func rumour() -> String {
        guard let i = (0..<50).first(where: { memory[Discovery.site($0) + 6] & 0xC0 == 0 }) else { return "들어온 정보가 별로 없군요." }
        var x = memory.word(Discovery.site(i)), y = memory.word(Discovery.site(i) + 2)
        if rng(80) > captain.luck { x = rng(World.width); y = rng(World.height) }
        // Latitude and longitude as 0x24D58 reckons them, rounded down to 5°.
        let d = 0x280 - y, lat = abs(d) * 8 / 57
        let east = ((x + 0x7BD) % 0x870 + 0x870) % 0x870
        let lon = east > 0x438 ? (0x870 - east) / 6 : east / 6
        return "\(east > 0x438 ? "서경" : "동경")\(lon / 5 * 5)도, \(d >= 0 ? "북위" : "남위")\(lat / 5 * 5)도 부근에 부락이 있다는 풍문이 있소. 얼마나 믿을 만한지는 모르겠소."
    }
}
