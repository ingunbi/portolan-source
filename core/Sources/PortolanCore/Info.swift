import Foundation

// The 정보 command (MENU 26, 0x20559) and the records behind it: the logbook (0x1DC0F), the
// fleet screen (0x1CAB2), the ship screen (0x1BB79), 적하일람 (0x1C8CC), 발견물정보 (0x1CA4E),
// titles by hero (0x15FFF) and 지도확인 (0x2D4E3). docs/re/info.md.

/// One line of the logbook (16-byte entries in a 48-entry far buffer).
public struct LogEntry: Codable, Equatable {
    /// `(12·year + month)·31 + day`, the year counted from 1501.
    public let date: Int
    /// 0 arrival, 1 departure, 2 battle, 9 port sighted, 12 purchase.
    public let type: Int
    public let a: Int, b: Int, c: Int, d: Int

    public var year: Int { date / 31 / 12 + 1501 }
    public var month: Int { date / 31 % 12 + 1 }
    public var day: Int { date % 31 + 1 }
}

/// What the fleet screen prints under the ships (msgs 922–924).
public struct FleetSummary: Equatable {
    /// Rudder and sails of the slowest ship (함대선회력, 함대추진력).
    public var rudder = 0, sail = 0
    public var crew = 0, guns = 0
    /// The weakest hull, at most 100 (함대내구력).
    public var hull = 100
    public var power = 0
    /// The slowest ship, whose rudder, sails and draft the sea panel shows (0x7F00).
    public var slowest = 0
}

extension Voyage {
    public static let logSize = 48

    var logDate: Int { (12 * (year - 1501) + month) * 31 + dayOfMonth }

    /// 0x1DC0F: when the book is full the oldest line goes.
    mutating func writeLog(_ type: Int, _ a: Int, _ b: Int = 0, _ c: Int = 0, _ d: Int = 0) {
        if logbook.count >= Voyage.logSize { logbook.removeFirst(logbook.count - Voyage.logSize + 1) }
        logbook.append(LogEntry(date: logDate, type: type, a: a, b: b, c: c, d: d))
    }

    /// Leaving port (0x27392): the days the stores will last are written down.
    public mutating func logDeparture(from port: Int) {
        writeLog(1, min(water, food) / max(1, crew), port)
    }

    /// Battle results for the log (0x103F3, 0x10531, 0x10588): 0 won, 1 drawn at sunset, 2 fled.
    static func logResult(code: Int) -> Int? {
        switch code {
        case 0, 2, 4, 6: return 0
        case 1: return 1
        case 3, 9: return 2
        default: return nil
        }
    }

    /// A log line as printed (msgs 366, 367, 837, 381, 384).
    public func logText(_ e: LogEntry, messages: [String], world: World) -> String {
        func msg(_ n: Int) -> String { messages.indices.contains(n) ? messages[n] : "" }
        func fill(_ n: Int, _ args: [String]) -> String {
            var t = msg(n)
            for a in args {
                guard let r = t.range(of: "%-?[0-9]*l?[sdu]", options: .regularExpression) else { break }
                t.replaceSubrange(r, with: a)
            }
            return Korean.particles(t)
        }
        func port(_ p: Int) -> String { memory.string(DS.port + DS.portSize * p + 4, max: 14) }
        switch e.type {
        case 0: return fill(366, ["\(e.a)", port(e.b)])
        case 1: return fill(367, ["\(e.a)", port(e.b)])
        case 2:
            let f = e.a
            let kind = f >= 60 || f % 10 == 0 ? "함대" : f % 10 < 5 ? "상선" : "전함"
            let result = [", 이겼다", "했지만 해가 저물어 무승부가 되었다", "했지만 달아날 수밖에 없었다"][min(2, e.b)]
            let nation = f / 10 < 6 ? Town.nationNames[f / 10] : "해적"
            return fill(837, [nation, kind, result])
        case 9: return fill(381, [port(e.a)])
        case 12: return fill(384, [world.navigation.goods[safe: e.a]?.name ?? "", "\(e.c)", "\(e.d)"])
        default: return ""
        }
    }

    // MARK: fleet and ship screens

    /// The person in command of ship `i`.
    public func commanderStats(of i: Int) -> (navLevel: Int, seamanship: Int) {
        if i == 0 || !officers.indices.contains(i - 1) { return (captain.navLevel, captain.seamanship) }
        return (officers[i - 1].navLevel, officers[i - 1].stats[1])
    }

    /// The speed the info screens work out (0x1BA80, and the loop in 0x1CAB2): the sail table is
    /// read by class number, not sail type, and wind force is left out.
    func infoSpeed(ship i: Int, windDelta d: Int, force: Int?, in world: World) -> Int {
        let s = ships[i], c = world.navigation.classes[s.classIndex]
        var a = memory[0x714 + 8 * d + s.classIndex] * s.sail
        if let force { a = a * force / 150 }
        let crewFactor = min(100, s.sailorShare * s.crew / max(1, c.minCrew))
        a = crewFactor * a / 100 * min(150, 180 - min(180, 100 * s.load / max(1, c.capacity))) / 100
        let cap = commanderStats(of: i)
        return min(40, min(30, a + a * cap.navLevel / 10) * cap.seamanship / 75)
    }

    /// 속도 on the ship screen, in knots (msg 894).
    public func shipKnots(_ i: Int, in world: World) -> Int { (infoSpeed(ship: i, windDelta: 0, force: 4, in: world) + 1) / 2 }

    /// 전투력 of one ship (battle.md §13.2).
    func shipPower(_ s: Ship) -> Int {
        let gunners = min(300, (100 - s.sailorShare - s.watchShare) * s.crew / 100)
        let t = s.gunType
        let range = memory.word(0x828 + 2 * t), pow = memory.word(0x838 + 2 * t)
        return (2 * s.hull + min(s.guns, gunners) * (2 * range + pow) / 10 + gunners) & 0xFFFF
    }

    /// 자함대정보 (0x1CAB2) for the player's fleet.
    public func fleetSummary(in world: World) -> FleetSummary {
        var r = FleetSummary()
        var best = Int.max
        let wind = weather.windDir & 7
        for i in ships.indices {
            let s = ships[i]
            r.crew += s.crew
            r.guns += s.guns
            r.power = (r.power + shipPower(s)) & 0xFFFF
            var d = abs(wind - heading8)
            if d > 7 { d = 7 }
            let v = infoSpeed(ship: i, windDelta: d, force: nil, in: world)
            if v < best {
                best = v
                r.rudder = s.rudder
                r.sail = s.sail
                r.slowest = i
            }
            r.hull = min(r.hull, s.hull)
        }
        return r
    }

    /// 적재율 (msg 892): total load against the class capacity, in percent.
    public func loadPercent(_ i: Int, in world: World) -> Int {
        100 * ships[i].load / max(1, world.navigation.classes[ships[i].classIndex].capacity)
    }

    // MARK: 적하일람

    /// Goods aboard, totalled over the ships in first-seen order.
    public var goodsTotals: [(good: Int, amount: Int)] {
        var r: [(good: Int, amount: Int)] = []
        for s in ships {
            for h in s.holds {
                if let k = r.firstIndex(where: { $0.good == h.good }) { r[k].amount += h.amount } else { r.append((h.good, h.amount)) }
            }
        }
        return r
    }

    /// The visited port that pays most for `good` (0x1C818); Lisbon when none pays anything.
    public func bestMarket(for good: Int, in world: World) -> Int {
        var best = 0, top = 0
        for p in 0..<min(100, world.navigation.markets.count) {
            let m = markets.indices.contains(p) ? markets[p] : world.navigation.markets[p]
            let price = Trade.sellPrice(good, at: m, in: world.navigation)
            if price > top && memory[DS.port + DS.portSize * p + 0x13] & 0x40 != 0 {
                best = p
                top = price
            }
        }
        return best
    }

    /// Who gives the 적하일람 advice: the hero with 회계 (msg 848), else the bookkeeper (849 with
    /// 회계, 850 without); nil when there is no one to ask.
    public func cargoAdviser() -> (name: String?, knows: Bool)? {
        if captain.skills & 2 != 0 { return (nil, true) }
        guard let k = officer(holding: .bookkeeper) else { return nil }
        return (k.name, k.skills & 2 != 0)
    }

    // MARK: 발견물정보

    /// Sites found and not lost (`+6 & 0xE0 == 0x60`).
    public var foundSites: [Int] {
        (0..<98).filter { memory[Discovery.site($0) + 6] & 0xE0 == 0x60 }
    }

    /// 중요도 (msg 1080, MENU 34): D, C, B, A, ☆ by quarters of site +5.
    public func siteGrade(_ i: Int) -> String { ["D", "C", "B", "A", "☆"][min(4, memory[Discovery.site(i) + 5] / 25)] }

    public func siteCategory(_ i: Int) -> String {
        ["보물", "원주민", "희귀한 동물", "식물", "유적", "괴물", "자연", "원주민"][memory[Discovery.site(i) + 6] & 7]
    }

    // MARK: 시세·물가

    /// 시세·물가 (0x24C72) for one of the ten categories: the category index (msg 151) and each
    /// good of the category with the trader's asking price (nil when not on sale here) and the
    /// price he pays. The zone list is shown whatever the economy. The original prints a zone
    /// slot's price for the specialty at ten ports; the remaster shows the specialty's own.
    public func priceList(category c: Int, in world: World) -> (index: Int, rows: [(good: Int, buy: Int?, sell: Int)]) {
        let m = market(in: world), data = world.navigation
        let first = c == 0 ? 0 : memory[0x7BF + c], end = memory[0x7C0 + c]
        let lic = licensed(in: world)
        var rows: [(good: Int, buy: Int?, sell: Int)] = []
        for g in first..<max(first, end) where g < data.goods.count {
            var buy: Int?
            if let l = data.zones[m.zone].goods.first(where: { $0.good == g }) {
                buy = Trade.buyPrice(Offer(good: g, basePrice: l.price), at: m, in: data, licensed: lic)
            } else if g == m.specialty {
                buy = Trade.buyPrice(Offer(good: g, basePrice: m.specialtyPrice), at: m, in: data, licensed: lic)
            }
            rows.append((g, buy, Trade.sellPrice(g, at: m, in: data)))
        }
        return (m.prices[c] + 50, rows)
    }

    // MARK: 지도확인

    /// 지도확인 (0x2D4E3): the treasure site of the first map held, to 5°, plus 5° half the time.
    /// Costs 20,000 gold, and the purse must hold more than that (else nil).
    public mutating func checkMap() -> String? {
        guard let map = items.first(where: { (80...89).contains($0) }) else { return nil }
        let site = memory[TownDS.item(map) + 0x18]
        let a = Discovery.site(site)
        var lon = (memory.word(a) + 1981) % 2160
        let west = lon > 1080
        if west { lon = 2160 - lon }
        let latRaw = 640 - memory.word(a + 2)
        let lat = (abs(latRaw) * 8 / 57 / 5 + rng(2)) * 5
        let lonDeg = (lon / 6 / 5 + rng(2)) * 5
        guard gold > 20_000 else { return nil }
        gold -= 20_000
        return "\(latRaw >= 0 ? "북위" : "남위") \(lat)도, \(west ? "서경" : "동경") \(lonDeg)도"
    }
}

extension Town {
    /// Ottoman titles (DATA1.LZW entry 17), used when the hero is hero 5.
    public static let ottomanTitles = ["", "사족", "감찰관", "군수", "지사", "영주", "대영주", "군후", "재상", "대재상"]

    /// Title of rank `r` for hero `h` (0x15FFF loads the table by hero, not by nation).
    public static func title(rank r: Int, hero h: Int) -> String {
        (h == 5 ? ottomanTitles : titles)[max(0, min(r, 9))]
    }
}

extension Array {
    public subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension DataSegment {
    /// An entry of a near-pointer name table (DS:0x7CA categories, 0x866 nations, 0x874 skills,
    /// 0x858 roles, 0x87E abilities, 0x808 cannons).
    public func name(_ table: Int, _ i: Int) -> String { string(word(table + 2 * i), max: 24) }
}

extension World {
    /// A discovery's name, picture and description (COLONY.DAT, 0xDA-byte records).
    public func discoveryInfo(_ i: Int) -> (name: String, picture: Int, text: String) {
        let size = 0xDA
        guard i >= 0, (i + 1) * size <= colony.count else { return ("", 0, "") }
        let r = Array(colony[i * size..<(i + 1) * size])
        func text(_ a: Int, _ n: Int) -> String {
            let raw = r[a..<min(r.count, a + n)].prefix { $0 != 0 }
            return DataSegment.decodeKorean(Array(raw)) ?? ""
        }
        return (text(0, 18), Int(r[0x12]), text(0x13, size - 0x13))
    }
}

// MARK: battle 정보 (MENU 51, 0xB089)

extension Battle {
    func slotByte(_ i: Int, _ v: Voyage, _ off: Int) -> Int { v.memory[slotAddress(units[i], v) + off] }
    public func sails(_ i: Int, _ v: Voyage) -> Int { slotByte(i, v, 5) }
    public func gunType(_ i: Int, _ v: Voyage) -> Int { slotByte(i, v, 8) & 7 }
    public func shipClass(_ i: Int, _ v: Voyage) -> Int { v.memory.shipClass(units[i].fleet, units[i].slot) }
    /// The ship record's crew limit (+0x15).
    public func maxCrew(_ i: Int, _ v: Voyage) -> Int { v.memory[DS.ship + DS.shipSize * slotByte(i, v, 7) + 0x15] }
    public func isFlagship(_ i: Int) -> Bool { units[i].flags & 0x20 != 0 }
    /// Ship record +0x13 bit 0x10: a sail-only ship (sprite sets 0/1, else 2/3 with oars).
    public func sailOnly(_ i: Int, _ v: Voyage) -> Bool { v.memory[DS.ship + DS.shipSize * slotByte(i, v, 7) + 0x13] & 0x10 != 0 }

    /// The sides other than the player's that have an admiral (타함대, 0xAC8E).
    public func otherSides(_ v: Voyage) -> [Int] {
        sides.indices.filter { s in
            guard let f = fleets[s], admirals[s] != nil else { return false }
            return f != v.playerFleet && !sides[s].isEmpty
        }
    }

    /// 타함대 fleet screen values: NPC ships count 25 % lookouts and 50 % sailors (0x1CAB2).
    public func fleetSummary(side s: Int, _ v: Voyage) -> FleetSummary {
        var r = FleetSummary()
        for k in sides[s] where alive(k, v) {
            let crew = crew(k, v), guns = guns(k, v), t = gunType(k, v)
            r.crew += crew
            r.guns += guns
            r.hull = min(r.hull, hull(k, v))
            let gunners = min(300, 25 * crew / 100)
            let range = v.memory.word(0x828 + 2 * t), pow = v.memory.word(0x838 + 2 * t)
            r.power = (r.power + 2 * hull(k, v) + min(guns, gunners) * (2 * range + pow) / 10 + gunners) & 0xFFFF
            if r.rudder == 0 || rudder(k, v) < r.rudder {
                r.rudder = rudder(k, v)
                r.sail = sails(k, v)
            }
        }
        return r
    }

    /// 작전일람 (0xAEF7): 방침 and 방법 of an own ship (msgs 1022–1034).
    public func ordersText(_ i: Int, _ v: Voyage) -> String {
        if isFlagship(i) { return "기함" }
        let f = units[i].flags
        let policy = f & 8 != 0 ? "이탈" : (f & 4 != 0 ? "집결" : "분산") + " " + (f & 1 != 0 ? "공세" : "수세")
        var method = (f & 2 != 0 ? "공격" : "퇴각") + " " + (f & 0x10 != 0 ? "포격" : "돌격")
        if f & 0x80 != 0, let t = units[i].target, units.indices.contains(t) {
            method += " " + (units[t].side & 1 == units[i].side & 1 ? "원군" : "적") + " " + shipName(t, v)
        } else {
            method += " 위임"
        }
        return policy + " · " + method
    }
}
