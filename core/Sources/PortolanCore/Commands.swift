import Foundation

// The player's fleet commands (docs/re/commands.md): 편성 (menu 27), 지휘 (menu 28), 항해
// (menu 29), landing on a coast (menu 36), items at sea (0x293F1) and the harbour office
// (building 3: departure check, unloading, the dock in the capitals, naming a supply port).
// The remaster keeps the flagship first and officer i−1 in command of ship i.

/// Barrels of a store or a trade good, as the cargo screens move them.
public enum CargoKind: Hashable {
    case water, food, lumber, shot, good(Int)
}

/// A ship left in a capital's dock (dock slots 10–39, five per capital, 0x27E2A).
public struct DockedShip: Codable {
    public let port: Int
    public var ship: Ship
}

/// The crew pool of 승무원편성 (0x1E8E7): sailors taken off ships, with their morale.
public struct CrewPool: Equatable {
    public var sailors = 0
    public var morale = 0
    public init() {}
}

extension Voyage {
    // MARK: 편성

    /// 선장변경 (0x1E2AE): `person` takes ship `i`. The hero moves his flag with him; two
    /// captains swap ships; a navigator who takes a ship gives up his post.
    @discardableResult
    public mutating func changeCaptain(ship i: Int, to person: Int) -> Bool {
        guard ships.indices.contains(i) else { return false }
        if person == heroID {
            guard i > 0 else { return true }
            ships.swapAt(0, i)                                    // the old flagship goes to the old captain
            return true
        }
        guard let k = officers.firstIndex(where: { $0.person == person }), i > 0 else { return false }
        let slot = i - 1
        guard slot != k else { return true }
        officers.swapAt(slot, k)
        officers[slot].post = nil
        if k >= ships.count - 1 { officers[k].post = nil }
        return true
    }

    /// 승무원편성 (0x1E789): ship `i` gets `n` sailors from its own crew and the pool; morale is
    /// averaged by headcount.
    public mutating func setCrew(ship i: Int, to n: Int, pool: inout CrewPool) -> Bool {
        let old = ships[i].crew, om = ships[i].morale
        guard n >= 0, n <= min(old + pool.sailors, ships[i].crewCapacity) else { return false }
        let left = pool.sailors - n + old
        ships[i].crew = n
        ships[i].morale = n == 0 ? 0 : old < n ? (om * old + pool.morale * (n - old)) / n : om
        pool.morale = left == 0 ? 0 : old < n ? pool.morale : (pool.morale * pool.sailors + om * (old - n)) / left
        pool.sailors = left
        return true
    }

    /// 승무원비율 (0x1EBFF): sailing (운항) and watch (파수) shares in percent; the rest are
    /// the deck crew (갑판) who fight.
    @discardableResult
    public mutating func setShares(ship i: Int, sail: Int, watch: Int) -> Bool {
        guard ships.indices.contains(i), (0...100).contains(sail), (0...100).contains(watch), sail + watch <= 100 else { return false }
        ships[i].sailorShare = sail
        ships[i].watchShare = watch
        return true
    }

    /// 승무원비율 buttons (0x1EBCC): row 0 운항, 1 파수, 2 갑판. Raising a row takes the point
    /// from the next row in the circle 운항 → 파수 → 갑판 → 운항, else from the one after.
    public mutating func nudgeShare(ship i: Int, row: Int, up: Bool) {
        guard ships.indices.contains(i) else { return }
        var c8 = ships[i].watchShare, c9 = ships[i].sailorShare
        var deck = 100 - c8 - c9
        func turn(_ t0: inout Int, _ t1: inout Int, _ t2: inout Int) {
            if up {
                guard t0 < 100 else { return }
                t0 += 1
                if t1 > 0 { t1 -= 1 } else { t2 -= 1 }
            } else {
                guard t0 > 0 else { return }
                t0 -= 1
                t1 += 1
            }
        }
        switch row {
        case 0: turn(&c9, &c8, &deck)
        case 1: turn(&c8, &deck, &c9)
        default: turn(&deck, &c9, &c8)
        }
        ships[i].watchShare = c8
        ships[i].sailorShare = c9
    }

    /// 함선처분 (0x1EE54): the ship, her crew and cargo are given up for nothing. Not the
    /// flagship (msg 233), not the only ship (msg 217).
    @discardableResult
    public mutating func scuttle(_ i: Int) -> Bool {
        guard ships.count > 1, i > 0, ships.indices.contains(i) else { return false }
        removeShip(i, keepCaptain: true)
        return true
    }

    public func amount(_ k: CargoKind, ship i: Int) -> Int {
        let s = ships[i]
        switch k {
        case .water: return s.water / 10
        case .food: return s.food / 10
        case .lumber: return s.lumber
        case .shot: return s.shot
        case .good(let g): return s.holds.first { $0.good == g }?.amount ?? 0
        }
    }

    /// 적하편성 (0x1F2EB): barrels from ship `a` to ship `b` within `b`'s free space. Water and
    /// food are counted in whole barrels on the way, so the tenths of both ships are lost (0x1F1FF).
    @discardableResult
    public mutating func moveCargo(_ k: CargoKind, from a: Int, to b: Int, amount n: Int) -> Bool {
        guard a != b, ships.indices.contains(a), ships.indices.contains(b), n > 0, n <= amount(k, ship: a), n <= ships[b].freeCargo else { return false }
        switch k {
        case .water:
            ships[a].water = (ships[a].water / 10 - n) * 10
            ships[b].water = (ships[b].water / 10 + n) * 10
        case .food:
            ships[a].food = (ships[a].food / 10 - n) * 10
            ships[b].food = (ships[b].food / 10 + n) * 10
        case .lumber:
            ships[a].lumber -= n
            ships[b].lumber += n
        case .shot:
            ships[a].shot -= n
            ships[b].shot += n
        case .good(let g):
            if !ships[b].holds.contains(where: { $0.good == g }) && ships[b].holds.count >= Trade.holds { return false }
            guard let ka = ships[a].holds.firstIndex(where: { $0.good == g }) else { return false }
            ships[a].holds[ka].amount -= n
            if ships[a].holds[ka].amount == 0 { ships[a].holds.remove(at: ka) }
            if let kb = ships[b].holds.firstIndex(where: { $0.good == g }) { ships[b].holds[kb].amount += n } else { ships[b].holds.append(CargoLot(good: g, amount: n)) }
        }
        return true
    }

    // MARK: 지휘

    /// 감시 (0x1F84F): what the lookout makes of a fleet. Pirates fly a false flag, and an
    /// officer who knows enough may see through it (msg 766, `rand(90) < knowledge`).
    public mutating func inspect(_ f: Int, in world: World) -> [String] {
        let adm = memory.fb(f, FleetField.admiral)
        guard adm < 120 else { return ["눈에 띄는 군함이 없습니다."] }
        let p = memory.person(adm)
        var flag = memory.pb(adm, 0x31) & 0xF
        if flag == 6 { flag = adm % 6 }
        let kind = f % 10 == 0 ? "함대" : f % 10 < 5 ? "상선대" : "전함대"
        let heading = ["북", "북동", "동", "남동", "남", "남서", "서", "북서"][memory.fb(f, FleetField.heading) & 7]
        let names = (0..<10).filter { memory.slotUsed(f, $0) }.map { s -> String in
            let c = memory.shipClass(f, s)
            return c < world.navigation.classes.count ? world.navigation.classes[c].name : "배"
        }
        var lines = [p.name, "\(Town.nationNames[min(5, flag)]) \(kind)",
                     "속도:\(npcSpeed(f, heading: memory.fb(f, FleetField.heading) & 7, in: world) / 2)knot  침로:\(heading)",
                     names.joined(separator: ", ")]
        if f / 10 == 6 && f != 60 {
            let k = officers.map { $0.stats[2] }.max() ?? 0
            if rng(90) < k { lines.append(Korean.particles("저 함대는 \(names.first ?? "배")(를) 갖췄는데, 해적 같아 보입니다.")) }
        }
        return lines
    }

    /// 대열변경 (0x1FF1B): the order of the ships behind the flagship, captains moving with them.
    @discardableResult
    public mutating func reorderShips(_ order: [Int]) -> Bool {
        guard order.sorted() == Array(1..<ships.count) else { return false }
        let oldShips = ships, oldCaptains = Array(officers.prefix(ships.count - 1))
        for (k, i) in order.enumerated() {
            ships[k + 1] = oldShips[i]
            officers[k] = oldCaptains[i - 1]
        }
        return true
    }

    /// 급여설정 (0x202C9): pay can only rise, up to 2000, and only for officers under 80
    /// loyalty; each 5 gold of raise buys a point of loyalty.
    public mutating func raisePay(officer k: Int, to v: Int) -> String {
        guard officers.indices.contains(k) else { return "" }
        if officers[k].loyalty >= 80 { return "그런 걱정은 하지 않으셔도 됩니다." }       // 220
        guard v >= officers[k].salary else { return "그 금액으로는 어림도 없소." }       // 224
        let pay = min(2000, v)
        officers[k].loyalty = min(100, officers[k].loyalty + (pay - officers[k].salary) / 5)
        officers[k].salary = pay / 10 * 10
        return "감사합니다."                                                                // 223
    }

    // MARK: 항해

    /// Sight range for discoveries (`[0xC176]`): the best watch of any ship, at most 12 tiles,
    /// doubled with a telescope.
    public var sightRange: Int {
        let watch = ships.map { $0.crew * $0.watchShare / 100 }.max() ?? 0
        return max(2, min(12, watch) * (items.contains(24) ? 2 : 1))
    }

    /// Land next to the fleet where a party can go ashore (menu 36), if any.
    public func coastTile(in world: World) -> (Int, Int)? {
        let px = Int(x), py = Int(y)
        for (dx, dy) in [(0, -1), (1, -1), (2, 0), (2, 1), (1, 2), (0, 2), (-1, 1), (-1, 0)] {
            let tx = px + dx, ty = py + dy
            if !world.isSea(x: Double(tx) + 0.5, y: Double(ty) + 0.5) { return (tx, ty) }
        }
        return nil
    }

    /// The site on a landing tile, if any (0x343DD).
    func site(at t: (Int, Int)) -> Int? {
        (0..<98).first { i in
            let a = Discovery.site(i)
            let sx = memory.word(a), sy = memory.word(a + 2)
            return (sx...sx + 1).contains(t.0) && (sy...sy + 1).contains(t.1)
        }
    }

    /// 응급수리 (0x33B47): each barrel of lumber mends five points of hull, rudder or sails.
    @discardableResult
    public mutating func emergencyRepair(ship i: Int, part: Int, lumber n: Int, in world: World) -> String {
        let c = world.navigation.classes[ships[i].classIndex]
        if ships[i].hull == ships[i].maxHull && ships[i].rudder == c.rudder && ships[i].sail == c.sail { return "이 배는 손상된 곳이 없습니다." }
        let total = ships.reduce(0) { $0 + $1.lumber }
        guard total > 0 else { return "자재가 없습니다." }
        let need = [ships[i].maxHull - ships[i].hull, c.rudder - ships[i].rudder, c.sail - ships[i].sail][part]
        guard need > 0 else { return "수리할 곳이 없습니다." }
        let use = min(n, total, (need + 4) / 5)
        var left = use
        for k in ships.indices where left > 0 {
            let t = min(left, ships[k].lumber)
            ships[k].lumber -= t
            left -= t
        }
        switch part {
        case 0: ships[i].hull = min(ships[i].maxHull, ships[i].hull + 5 * use)
        case 1: ships[i].rudder = min(c.rudder, ships[i].rudder + 5 * use)
        default: ships[i].sail = min(c.sail, ships[i].sail + 5 * use)
        }
        return "수리를 마쳤습니다."
    }

    /// 탐색 ashore (0x33ED0): a relic on its site when the map is held, else water by the
    /// hero's luck. Returns the lines and the barrels of water that can be taken on.
    public mutating func searchCoast(at t: (Int, Int), water found: Bool, in world: World) -> (lines: [String], water: Bool) {
        if let i = site(at: t) {
            let a = Discovery.site(i)
            if memory[a + 6] & 0xF0 == 0xA0 {
                let relic = memory[a + 4]
                if let k = items.firstIndex(of: (relic - 10) & 0xFF) { items[k] = relic }
                memory[a + 6] |= 0x10
                return ([Korean.particles("\(itemName(relic))(를) 발견했습니다.")], false)
            }
        }
        guard found else { return (["물을 찾지 못했습니다."], false) }
        return (["마실 수 있는 물을 찾았습니다."], true)
    }

    /// Water found ashore is free; old stock is rounded down to whole barrels (0x33D4E).
    @discardableResult
    public mutating func takeWater(ship i: Int, barrels n: Int) -> Bool {
        guard n > 0, n <= ships[i].freeCargo else { return false }
        ships[i].water = (ships[i].water / 10 + n) * 10
        return true
    }

    /// Items at sea (0x2939A).
    public mutating func useItem(_ id: Int) -> [String] {
        guard items.contains(id) else { return [] }
        switch id {
        case 20, 21, 22:                                                  // 사분의, 육분의, 경위의
            let p = [20: 5, 21: 2, 22: 1][id]!
            var err = 0
            var lines: [String] = []
            if captain.skills & 0x10 == 0 && !officers.contains(where: { $0.skills & 0x10 != 0 }) {
                lines.append("어쩔 수 없군요.\n서툴지만 제가 측량해 보겠습니다.")
                err = rng(100) + 1
            }
            let lat = 640 - Int(y)
            let latDeg = abs(lat) * 8 / (57 * p) * p
            var lon = (Int(x) + 1981) % 2160
            let west = lon > 1080
            if west { lon = 2160 - lon }
            let lonDeg = lon / (6 * p) * p
            lines.append("\(lat >= 0 ? "북위" : "남위") \(latDeg + err)도, \(west ? "서경" : "동경") \(lonDeg + err)도")
            return lines
        case 23: return ["\(tick / 3)시" + (tick % 3 != 0 ? " \((tick % 3) * 2)0분" : "")]
        case 24: return ["먼 곳이 보인다."]
        case 25: return ["야옹∼"]
        case 41:
            items.removeAll { $0 == 41 }
            if epidemic { epidemic = false; return ["쥐들을 퇴치했습니다."] }
            return ["쥐는 없습니다."]
        case 42:
            items.removeAll { $0 == 42 }
            var line = "아무 일도 일어나지 않았습니다."
            if event == .storm { event = nil; line = "폭풍우가 가라앉았습니다." }
            stormShelter = rng(6) + 10
            return [line]
        case 43:
            items.removeAll { $0 == 43 }
            if scurvy { scurvy = false; return ["괴혈병이 나았습니다."] }
            return ["맛있다."]
        default:
            return ["이 아이템은 여기서 쓸 수 없습니다."]
        }
    }

    // MARK: harbour office

    /// 출항 check (0x27176): every ship needs sailors at the sails, and the stores must last.
    public func departureCheck() -> (line: String, ok: Bool) {
        if ships.contains(where: { $0.crew * $0.sailorShare / 100 == 0 }) { return ("이 상태로는 움직일 수 없습니다.", false) }
        let days = min(water, food) / max(1, crew)
        if days == 0 { return ("이대로는 굶어 죽고 맙니다.", false) }
        if days > 180 { return ("식량은 6개월 치가 넘습니다.\n출항할까요?", true) }
        return ("식량은 약 \(days)일 치입니다.\n출항할까요?", true)
    }

    /// 보급 unloading (0x2758D): barrels put ashore, no refund. Goods left in the 적하편성 pool
    /// are lost the same way (0x1F5EF).
    @discardableResult
    public mutating func unload(_ k: CargoKind, ship i: Int, barrels n: Int) -> Bool {
        guard ships.indices.contains(i), n > 0, n <= amount(k, ship: i) else { return false }
        switch k {
        case .water: ships[i].water -= 10 * n
        case .food: ships[i].food -= 10 * n
        case .lumber: ships[i].lumber -= n
        case .shot: ships[i].shot -= n
        case .good(let g):
            guard let h = ships[i].holds.firstIndex(where: { $0.good == g }) else { return false }
            ships[i].holds[h].amount -= n
            if ships[i].holds[h].amount == 0 { ships[i].holds.remove(at: h) }
        }
        return true
    }

    /// Party ashore on open coast (menu 36 entry, 0x344DE): the fleet stops, and the water roll
    /// is made once per entry from the hero's luck.
    public mutating func landOnCoast(at t: (Int, Int)) -> Bool {
        ashore = false
        anchored = true
        waypoint = nil
        route = []
        landedAt = [t.0, t.1]
        return captain.luck > rng(100)
    }

    /// 대기 (0x345E3): the party stays ashore while the days go by.
    public mutating func waitAshore() {
        ashore = true
        anchored = true
    }

    /// 출항 from the coast (0x33858).
    public mutating func leaveCoast() {
        ashore = false
        anchored = false
        landedAt = nil
        if sail == 0 { sail = Voyage.maxSail }
    }

    /// The six capitals have a dock (0x1ADEC).
    public func hasDock(_ port: Int) -> Bool { (0..<6).contains { memory.nb($0, 0xA) == port } }
    public func docked(at port: Int) -> [DockedShip] { dock.filter { $0.port == port } }

    /// 보관 (0x27A4D): up to five ships per capital; the crew is dismissed.
    public mutating func storeShip(_ i: Int, at port: Int) -> String {
        guard hasDock(port), i > 0, ships.indices.contains(i) else { return "기함밖에 없습니다." }
        guard docked(at: port).count < 5 else { return "도크에 빈자리가 없습니다." }
        var s = ships[i]
        s.crew = 0
        s.morale = 0
        dock.append(DockedShip(port: port, ship: s))
        removeShip(i, keepCaptain: true)
        return "그럼, 맡아 두겠습니다."
    }

    /// 배비 (0x27B8C): a stored ship comes out empty and needs a free companion as captain.
    public mutating func bringOut(_ k: Int, at port: Int) -> String {
        let here = dock.indices.filter { dock[$0].port == port }
        guard here.indices.contains(k) else { return "맡겨 둔 배가 없습니다." }
        guard ships.count < Shipyard.maxShips, spareCaptains > 0 else { return "선장을 맡길 사람이 없습니다." }
        ships.append(dock.remove(at: here[k]).ship)
        officers[ships.count - 2].post = nil
        return "예항해 두겠습니다."
    }

    /// 교환 (0x27CCE): fleet ship `i` and stored ship `k` change places; the crew moves over as
    /// far as the berths allow.
    public mutating func exchangeShip(_ i: Int, with k: Int, at port: Int) -> String {
        let here = dock.indices.filter { dock[$0].port == port }
        guard ships.indices.contains(i), here.indices.contains(k) else { return "맡겨 둔 배가 없습니다." }
        var out = dock[here[k]].ship
        var into = ships[i]
        out.crew = min(into.crew, out.crewCapacity)
        out.morale = into.morale
        into.crew = 0
        into.morale = 0
        ships[i] = out
        dock[here[k]].ship = into
        return "교체해 두겠습니다."
    }

    /// Companions with loyalty under 30 on less than 190 gold may want to stay ashore (0x280A3).
    public mutating func desertersAtHarbour() -> [Int] {
        officers.indices.filter { k in
            k >= ships.count - 1 && officers[k].loyalty < 30 && officers[k].salary < 190
                && rng(4 - (memory.pb(officers[k].person, 0x2F) & 3)) == 0
        }
    }

    /// Keeping a would-be deserter costs ten gold more a month and resets loyalty to 30 (msg 801).
    public mutating func keepOfficer(_ k: Int) {
        officers[k].salary += 10
        officers[k].loyalty = 30
    }

    /// 명명 (0x27F59): a supply port's name, up to 7 characters, unique.
    public mutating func renamePort(_ p: Int, to name: String, in world: World) -> String {
        guard p >= 100, !name.isEmpty else { return "" }
        let taken = (0..<130).contains { $0 != p && memory.string(DS.port + DS.portSize * $0 + 4, max: 14) == name }
        if taken { return "이미 같은 이름의 항구가 있소. 다른 이름을 지어 주시오." }
        memory.setString(DS.port + DS.portSize * p + 4, String(name.prefix(7)), max: 14)
        return "\(name), 좋은 이름이오. 고맙소."
    }
}

extension Voyage {
    /// The harbour master's rumour on entering (0x280A3 step 3): with a promotion due or a
    /// summons (`[0xCEE]` bits 0–1, SNR0 F16/F17), no commission running (bit 2) and `[0xCEA]`
    /// clear, in a port of the hero's own nation, the ruler is said to be looking for the hero
    /// (msgs 409, 410 + nation, 416). The summons bit is set so the palace lets the hero in.
    public mutating func harbourRumour(port p: Int, in world: World) -> String? {
        let f = memory[0xCEE]
        guard p < 100, f & 3 != 0, f & 4 == 0, memory[0xCEA] == 0 else { return nil }
        let n = market(in: world).nation
        guard n < 6, n == captain.nation else { return nil }
        memory[0xCEE] |= 2
        let rulers = ["포르투갈의 마누엘왕이 ", "에스파니아의 카를로스왕이 ", "오스만제국의 슐레이만 대제가 ",
                      "대영 왕국의 헨리８세가 ", "이탈리아의 총독이 ", "네덜란드의 총독이 "]
        return "그러고 보니 " + rulers[n] + "당신을 찾는다는 소문을 들었소."
    }
}
