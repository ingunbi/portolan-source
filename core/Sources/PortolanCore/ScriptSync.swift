import Foundation

// Keeps the data segment the scripts see in step with the voyage model. Before a script runs,
// `exportToMemory` writes the player's side of the original records (gold, family, items,
// officers, the hero, ships and cargo, date, ports); `importFromMemory` reads back what a
// script may have changed. Records the remaster does not model (other persons, story NPCs,
// tavern girls, port flags) live only in the data segment.

extension DataSegment {
    public init() { bytes = [UInt8](repeating: 0, count: 0x10000) }

    /// A person record as the hiring rules read it.
    public func person(_ p: Int) -> Person {
        let a = DS.person(p)
        return Person(name: (string(a, max: 13) + " " + string(a + 0x0D, max: 13)).trimmingCharacters(in: .whitespaces),
                      stats: (0..<8).map { self[a + 0x1C + $0] }, navLevel: self[a + 0x24], battleLevel: self[a + 0x25],
                      navExp: word(a + 0x26), battleExp: word(a + 0x28), loyalty: self[a + 0x2B],
                      employer: self[a + 0x2C], port: self[a + 0x2D], status: self[a + 0x2E],
                      generic: self[a + 0x1B] & 0xC0 != 0, casual: self[a + 0x2F] & 8 != 0, skills: self[a + 0x30],
                      nation: self[a + 0x31] & 0xF)
    }
}

extension Voyage {
    public var heroID: Int { memory[DS.heroID] }

    /// Writes the voyage into the data segment. `port` is the port the fleet lies in, if any.
    public mutating func exportToMemory(port: Int?) {
        var m = memory
        let hero = heroID
        m.setDword(DS.gold, gold)
        let fam = DS.family(hero)
        for k in 0..<3 { m.setWord(fam + 2 * k, fame[k]) }
        for k in 0..<6 { m[fam + 6 + k] = standing[k] }
        m[fam + 0x0D] = rank
        m[DS.daysAtSea] = min(255, daysAtSea)
        m[DS.waterRation] = waterRation
        m[DS.foodRation] = foodRation
        for k in 0..<20 { m[DS.items + k] = k < items.count ? items[k] : 0xFF }
        m[DS.date] = year - 1501
        m[DS.date + 1] = month
        m[DS.date + 2] = dayOfMonth
        m[DS.date + 3] = tick
        m[DS.currentPort] = port ?? 0xFF

        let h = DS.person(hero)
        for (k, s) in captain.stats.enumerated() { m[h + 0x1C + k] = s }
        m[h + 0x24] = captain.navLevel
        m[h + 0x25] = captain.battleLevel
        m.setWord(h + 0x26, captain.navExp)
        m.setWord(h + 0x28, captain.battleExp)
        m[h + 0x2D] = port ?? 0xFF
        let fleetNo = m[h + 0x2C]

        for k in 0..<30 {
            m[DS.officers + k] = 0xFF
            m[DS.salaries + k] = 0
        }
        for (k, o) in officers.enumerated() where k < 30 {
            m[DS.officers + k] = o.person
            m[DS.salaries + k] = o.salary / 10
            let a = DS.person(o.person)
            for (j, s) in o.stats.enumerated() { m[a + 0x1C + j] = s }
            m[a + 0x24] = o.navLevel
            m[a + 0x25] = o.battleLevel
            m.setWord(a + 0x26, o.navExp)
            m[a + 0x2B] = o.loyalty
            m[a + 0x2C] = fleetNo
            m[a + 0x2D] = port ?? 0xFF
            m[a + 0x2E] = k < ships.count - 1 ? 2 : o.post.map { $0.rawValue + 3 } ?? 6
        }

        for i in markets.indices where i < 100 {
            for n in 0..<6 { m[DS.market + DS.marketSize * i + 8 + n] = markets[i].support[n] }
            let p = DS.port + DS.portSize * i + 0x13
            m[p] = (m[p] & 0xF8) | markets[i].nation
        }

        let fleet = DS.fleet(fleetNo)
        m.setWord(0xC6DA, fleet)
        m.setWord(fleet, Int(x))
        m.setWord(fleet + 2, Int(y))
        memory = m
        exportShips()
    }

    /// Ship slots, ship records 0..9 and cargo records 0..9 of the player's fleet.
    mutating func exportShips() {
        var m = memory
        let fleet = m.word(0xC6DA)
        for i in 0..<10 {
            let slot = fleet + 0x2B + 9 * i
            guard i < ships.count else {
                m[slot + 8] = 0
                continue
            }
            let s = ships[i]
            m.setWord(slot, s.crew)
            m[slot + 2] = s.hull
            m[slot + 3] = s.maxHull
            m[slot + 4] = s.rudder
            m[slot + 5] = s.sail
            m[slot + 6] = s.guns
            m[slot + 7] = i
            m[slot + 8] = 0x10 | s.gunType
            let r = DS.ship + DS.shipSize * i
            m.setString(r, s.name, max: 14)
            m[r + 0x12] = s.classIndex
            m[r + 0x13] = (m[r + 0x13] & 0xF8) | s.material
            m[r + 0x14] = s.gunCapacity
            m.setWord(r + 0x15, s.crewCapacity)
            m.setWord(r + 0x17, s.cargoCapacity)
            let c = DS.cargo + DS.cargoSize * i
            m.setWord(c, s.water)
            m.setWord(c + 2, s.food)
            m.setWord(c + 4, s.lumber)
            m.setWord(c + 6, s.shot)
            m[c + 8] = s.watchShare
            m[c + 9] = s.sailorShare
            for k in 0..<5 {
                m.setWord(c + 0xC + 2 * k, k < s.holds.count ? s.holds[k].amount : 0)
                m[c + 0x16 + k] = k < s.holds.count ? s.holds[k].good : 0xFF
            }
            m[c + 0x1B] = i == 0 ? heroID : i - 1 < officers.count ? officers[i - 1].person : 0xFF
            m[c + 0x1C] = s.morale
            m[c + 0x1D] = s.figurehead
        }
        memory = m
    }

    /// Reads back what a script may change.
    public mutating func importFromMemory(in world: World) {
        let m = memory
        let hero = heroID
        gold = m.dword(DS.gold)
        let fam = DS.family(hero)
        fame = (0..<3).map { m.word(fam + 2 * $0) }
        standing = (0..<6).map { m[fam + 6 + $0] }
        rank = m[fam + 0x0D]
        waterRation = min(100, m[DS.waterRation])
        foodRation = min(100, m[DS.foodRation])
        items = (0..<20).map { m[DS.items + $0] }.filter { $0 != 0xFF }

        let h = m.person(hero)
        captain.name = h.name
        captain.leadership = h.stats[0]
        captain.seamanship = h.stats[1]
        captain.knowledge = h.stats[2]
        captain.intuition = h.stats[3]
        captain.courage = h.stats[4]
        captain.swordplay = h.stats[5]
        captain.charm = h.stats[6]
        captain.luck = h.stats[7]
        captain.navLevel = h.navLevel
        captain.battleLevel = h.battleLevel
        captain.navExp = h.navExp
        captain.battleExp = h.battleExp
        captain.face = m.word(DS.person(hero) + 0x1A) & 0x3FFF
        captain.nation = h.nation                      // Catalina turns pirate (6) in her prologue
        captain.skills = h.skills

        var list: [Officer] = []
        for k in 0..<30 where m[DS.officers + k] != 0xFF {
            let p = m[DS.officers + k]
            let rec = m.person(p)
            var o = officers.first { $0.person == p }
                ?? Officer(person: p, name: rec.name, stats: rec.stats, navLevel: rec.navLevel, battleLevel: rec.battleLevel,
                           navExp: rec.navExp, salary: m[DS.salaries + k] * 10, loyalty: rec.loyalty,
                           generic: rec.generic, skills: rec.skills)
            o.name = rec.name
            o.stats = rec.stats
            o.navLevel = rec.navLevel
            o.battleLevel = rec.battleLevel
            o.loyalty = rec.loyalty
            o.skills = rec.skills
            o.post = (3...5).contains(rec.status) ? OfficerPost(rawValue: rec.status - 3) : nil
            list.append(o)
        }
        officers = list

        for i in markets.indices where i < 100 {
            for n in 0..<6 { markets[i].support[n] = m[DS.market + DS.marketSize * i + 8 + n] }
            markets[i].nation = m[DS.port + DS.portSize * i + 0x13] & 7
        }

        let fleet = m.word(0xC6DA)
        var kept: [Ship] = []
        for i in ships.indices where i < 10 {
            let slot = fleet + 0x2B + 9 * i
            guard m[slot + 8] & 0x30 == 0x10 else { continue }
            var s = ships[i]
            s.crew = m.word(slot)
            s.hull = m[slot + 2]
            s.maxHull = m[slot + 3]
            s.rudder = m[slot + 4]
            s.sail = m[slot + 5]
            s.guns = m[slot + 6]
            s.gunType = m[slot + 8] & 7
            let r = DS.ship + DS.shipSize * i
            s.name = m.string(r, max: 14)
            let c = DS.cargo + DS.cargoSize * i
            s.water = m.word(c)
            s.food = m.word(c + 2)
            s.lumber = m.word(c + 4)
            s.shot = m.word(c + 6)
            s.holds = (0..<5).compactMap { k in
                m[c + 0x16 + k] == 0xFF || m.word(c + 0xC + 2 * k) == 0 ? nil : CargoLot(good: m[c + 0x16 + k], amount: m.word(c + 0xC + 2 * k))
            }
            s.morale = m[c + 0x1C]
            s.figurehead = m[c + 0x1D]
            kept.append(s)
        }
        ships = kept
    }

    /// F9: a ship ordered by the story (0x31C64). It waits at this port, finished, for `FA`.
    mutating func scriptOrderShip(class c: Int, in world: World) {
        let port = memory[DS.currentPort] < 100 ? memory[DS.currentPort] : marketIndex
        var s = Ship.built(class: c, named: world.navigation.classes[c].name, in: world.navigation)
        s.morale = 100
        orders.append(ShipOrder(port: port, ship: s, daysLeft: 0))
    }

    /// FA: the story hands the ship over and names it (0x31DAC); its captain is the admiral
    /// when it is the first ship.
    mutating func scriptDeliverShip(named name: String, in world: World) {
        guard let k = orders.firstIndex(where: { $0.daysLeft == 0 }) else { return }
        var s = orders.remove(at: k).ship
        s.name = name.replacingOccurrences(of: "『", with: "").replacingOccurrences(of: "』", with: "")
        ships.append(s)
        exportShips()
    }
}
