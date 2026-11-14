import Foundation

// Before and after a sea battle: the encounter dialog (0xF9CA), desertion (0xF58D), and the
// aftermath (0x108EE): experience, pirate fame, nation standing, spoils and captured ships.

/// What the encounter dialog offers (0xF661 when the player attacks, 0xF74A when attacked).
public struct BattleOpening: Equatable {
    /// MESSAGE.DAT lines to show, in order.
    public let lines: [Int]
    /// A merchant offers money and cargo to be let go (815); the player answers yes or no.
    public let merchantOffer: Bool
    /// The player is attacked and may fight, flee or surrender (MENU 54).
    public let defending: Bool
    /// Team strengths ([0xA61C] the player's, [0xA61E] the other's).
    public let ours: Int, theirs: Int
}

public struct BattleResult: Equatable {
    public var code: Int
    public var lines: [String] = []
    public var gold = 0
    public var item: Int?
    /// Ships of the beaten main fleet within sight, and how many may be taken (0xFE26).
    public var capturable: [Int] = []
    public var mayTake = 0
}

extension Voyage {
    func teamStrength(_ fleets: [Int]) -> Int { fleets.reduce(0) { $0 + memory.fb($1, FleetField.strength) } }

    /// 0xF9CA.
    public mutating func opening(_ e: Encounter) -> BattleOpening {
        let fa = memory.fleetOf(person: e.attacker), fd = memory.fleetOf(person: e.defender)
        for f in [fa, fd] where f < Fleets.count { memory.recomputeStrength(f) }
        let playerAttacks = e.attacker == heroID
        let other = playerAttacks ? fd : fa
        let ours = teamStrength([playerFleet]), theirs = teamStrength([other])
        let pirate = other / 10 == 6 || memory.pb(playerAttacks ? e.defender : e.attacker, 0x31) & 0xF == 6
        if playerAttacks {
            if pirate { return BattleOpening(lines: [811, 813], merchantOffer: false, defending: false, ours: ours, theirs: theirs) }
            let merchant = (1...4).contains(other % 10)
            if merchant && 3 * theirs / 2 < ours {
                return BattleOpening(lines: [812, 815], merchantOffer: true, defending: false, ours: ours, theirs: theirs)
            }
            return BattleOpening(lines: [812, 814], merchantOffer: false, defending: false, ours: ours, theirs: theirs)
        }
        let line = pirate ? 817 : memory.fb(other, FleetField.mission) == 3 ? 818 : 819
        return BattleOpening(lines: [line, 3 * ours / 2 >= theirs ? 821 : 820], merchantOffer: false, defending: true, ours: ours, theirs: theirs)
    }

    /// 도망 (0xF74A): `navLevel + luck > rand(150)` gets away (822); else the fight starts (824).
    public mutating func tryToFlee() -> Bool {
        captain.navLevel + captain.luck > rng(150)
    }

    /// 항복 (msgs 825–829). Trade goods are cut to a third (pirates) or two thirds (navies);
    /// the code keeps two thirds of the gold although the text says it is taken.
    public mutating func surrender(toPirates: Bool) -> Int {
        var mult = 2, line = 825
        if toPirates {
            mult = 0
            if gold < 1000 { gold += 1000; line = 827 } else if gold < 10000 { line = 828 } else { gold = 5000; line = 829 }
        } else {
            gold = 2 * gold / 3
        }
        for i in ships.indices {
            for k in ships[i].holds.indices { ships[i].holds[k].amount = ships[i].holds[k].amount * mult / 3 }
            ships[i].holds.removeAll { $0.amount == 0 }
        }
        return line
    }

    /// Officers whose loyalty is under 40 sail away with their ships (0xE832, msgs 787–791).
    mutating func desert() -> [String] {
        var lines: [String] = []
        var i = ships.count - 1
        while i >= 1 {
            if officers.indices.contains(i - 1), officers[i - 1].loyalty < 40 {
                let o = officers[i - 1]
                lines.append("\(o.name): 상대가 너무 강합니다. 더는 함께 싸울 수 없습니다.")
                let a = DS.person(o.person)
                memory[a + 0x2E] = 0
                memory[a + 0x2C] = 0xFF
                memory[a + 0x2D] = rng(54) + 3
                removeShip(i, keepCaptain: false)
            }
            i -= 1
        }
        return lines
    }

    /// Starts the battle proper: the ships go into the data segment, cowards leave (0xF58D).
    public mutating func beginBattle(_ e: Encounter, in world: World) -> Battle? {
        let op = opening(e)
        var lines: [String] = []
        if op.ours + 20 <= op.theirs { lines = desert() }
        exportToMemory(port: nil)
        var b = Battle(attacker: e.attacker, defender: e.defender, voyage: &self, world: world)
        b?.log.lines += lines
        if b != nil { b!.advance(&self, world: world) }
        return b
    }

    // MARK: aftermath (0x108EE)

    /// The nation of the player and the category of the beaten fleet (0xFB8E).
    func battleCategory(enemyNation n: Int) -> Int {
        let p = memory.pb(heroID, 0x31) & 0xF
        guard p < 6, items.contains(29 + p) else { return 0 }
        var c = 1
        if memory.nb(p, 0xB + n) <= 40 { c = 2 }
        if memory.nb(n, 0x12 + p) & 0x10 != 0 { c = 3 }
        if memory.nb(p, 2) == n { c = 4 }
        if memory.nb(p, 0xB + n) >= 60 { c = 5 }
        if memory.nb(p, 0x12 + n) & 0x20 != 0 { c = 6 }
        return c
    }

    /// Applies the end of the battle and reports it. Captured ships wait for `takePrizes`.
    public mutating func finishBattle(_ b: inout Battle, in world: World) -> BattleResult {
        var r = BattleResult(code: b.endCode)
        let enemySide = b.units[b.sides[0][0]].fleet == playerFleet ? 1 : 0
        let enemyAdmiral = b.admirals[enemySide] ?? 0xFF
        let enemyFleet = b.fleets[enemySide] ?? 0
        if let res = Voyage.logResult(code: r.code) { writeLog(2, enemyFleet, res) }
        // 1–2. Shot back to the holds; sunk ships go, the others' captains learn.
        for u in b.units where u.fleet == playerFleet { memory.setWord(DS.cargo + DS.cargoSize * u.slot + 6, u.shot) }
        if r.code != 5 && r.code != 7 && r.code % 2 == 0 {
            for u in b.units where u.fleet == playerFleet && memory.slotUsed(u.fleet, u.slot) {
                b.gainExp(u.captain, b.enemyHull / 5, &self)
            }
        }
        importBattleShips()
        switch r.code {
        case 1: r.lines.append("승패가 나지 않은 채 해가 저물었다.")
        case 2: r.lines.append("적 기함이 물러나 전투가 끝났다.")
        case 3: r.lines.append("아군 기함이 전장을 벗어나 전투가 막을 내렸다.")
        case 4, 6:
            let p = memory.person(enemyAdmiral)
            r.lines.append(Korean.particles("적 기함이 깃발을 내리고 항복했다. \(captain.name)(는) \(p.name)함대를 무너뜨렸다."))
        case 5, 7:
            r.lines.append(r.code == 7 ? "일기토에서 패해 기함을 잃었습니다." : "기함을 잃어 해전에서 패배했습니다.")
            gameOver = "기함을 잃었습니다."
            gameOverCode = 0x1A                                                  // 0x1067E
        case 9: r.lines.append("기함이 항복하자 적 함대도 싸움을 멈췄다.")
        default: break
        }
        guard gameOver == nil else { return r }
        if r.code == 3 || r.code == 9 { r.lines += desert() }
        // 3. Pirate fame (0x10497).
        let n = min(6, enemyFleet / 10)
        let cat = battleCategory(enemyNation: n)
        if [2, 4, 6].contains(r.code) {
            var s = r.code == 2 ? 1 : 3
            if memory.pb(heroID, 0x31) & 0xF == 6 { s *= 3 } else if (2...4).contains(cat) { s *= cat }
            let bl = enemyAdmiral < 120 ? memory.pb(enemyAdmiral, 0x25) : 0
            fame[1] = min(50000, fame[1] + 200 + ((min(bl, 30) * min(bl, 15) * s) & 0xFFFF))
        }
        // Spoils (0x10216).
        if r.code == 4 || r.code == 6 {
            r.gold = (memory.fw(enemyFleet, FleetField.funds) + 1) * 100
            earn(r.gold)
            let t = memory.fb(enemyFleet, FleetField.treasure)
            if t != 0xFF && items.count < 20 {
                items.append(t)
                r.item = t
            }
            r.capturable = capturablePrizes(from: b)
            r.mayTake = max(0, min(10 - ships.count, spareCaptains, r.capturable.count))
        }
        // 4. Nation standing (0x10693).
        if r.code % 2 == 0 || r.code == 8 { applyStanding(enemyNation: n, category: cat) }
        // 5. Beaten or broken fleets disband (0xFC50).
        for s in 0..<4 {
            guard let f = b.fleets[s], f != playerFleet, let flag = b.sides[s].first else { continue }
            memory.recomputeStrength(f)
            let a = b.admirals[s] ?? 0xFF
            let gone = !memory.slotUsed(f, b.units[flag].slot) || b.crew(flag, self) == 0 || b.hull(flag, self) == 0
            if gone || (a < 120 && memory.pb(a, 0x31) & 0x20 == 0) || r.code == 6 { disband(f) }
        }
        return r
    }

    /// Reads the player's ships back after a battle; sunk ones leave the fleet, their
    /// captains survive (0x5CDF).
    mutating func importBattleShips() {
        let fleet = DS.fleet(playerFleet)
        var sunk: [Int] = []
        for i in ships.indices where i < 10 {
            let slot = fleet + FleetField.slots + 9 * i
            if memory[slot + 8] & 0x30 != 0x10 && i > 0 {
                sunk.append(i)
                continue
            }
            // Keep slot 0 for the game-over presentation, but import its actual fatal
            // damage too. Skipping it here would export the pre-battle flagship again.
            ships[i].crew = memory.word(slot)
            ships[i].hull = memory[slot + 2]
            ships[i].maxHull = memory[slot + 3]
            ships[i].rudder = memory[slot + 4]
            ships[i].sail = memory[slot + 5]
            ships[i].shot = memory.word(DS.cargo + DS.cargoSize * i + 6)
        }
        for i in sunk.reversed() where i > 0 { removeShip(i, keepCaptain: true) }
        let h = DS.person(heroID)
        captain.battleLevel = memory[h + 0x25]
        captain.battleExp = memory.word(h + 0x28)
        captain.leadership = memory[h + 0x1C]
        captain.seamanship = memory[h + 0x1D]
        captain.knowledge = memory[h + 0x1E]
        captain.intuition = memory[h + 0x1F]
        captain.courage = memory[h + 0x20]
        captain.swordplay = memory[h + 0x21]
        for k in officers.indices {
            let a = DS.person(officers[k].person)
            officers[k].battleLevel = memory[a + 0x25]
            officers[k].stats = (0..<8).map { memory[a + 0x1C + $0] }
        }
        exportShips()
    }

    /// 0x10693: the beaten nation thinks less of the player, his own nation more (or less, if
    /// he attacked his own people — down to losing rank or nationality, msgs 568, 569).
    mutating func applyStanding(enemyNation n: Int, category c: Int) {
        let p = memory.pb(heroID, 0x31) & 0xF
        let fam = DS.family(heroID)
        let a = min(rng(5) + 3, memory.nb(p, 0xB + n))
        memory.setNB(p, 0xB + n, memory.nb(p, 0xB + n) - a)
        memory.setNB(n, 0xB + p, memory.nb(p, 0xB + n))
        let (s, w) = [2: (2, 10), 3: (3, 6), 4: (4, 3), 5: (-1, 90), 6: (-1, 60)][c] ?? (1, 30)
        func get(_ k: Int) -> Int { k < 6 ? standing[k] : memory[fam + 0x0C] }
        func set(_ k: Int, _ x: Int) { if k < 6 { standing[k] = x } else { memory[fam + 0x0C] = x } }
        if n != 6 { set(n, get(n) - min(get(n), (rng(5) + 10) * w / 30)) }
        guard p != 6 else { return }
        if n != p {
            set(p, s >= 0 ? min(200, get(p) + (rng(5) + 5) * s) : get(p) - min(get(p), rng(5) + 5))
        } else {
            set(p, get(p) - min(get(p), rng(5) + 10))
            if get(p) <= 40 {
                note("국적을 잃었습니다.")
                rank = 0
                memory.setPB(heroID, 0x31, (memory.pb(heroID, 0x31) & 0xF0) | 6)
                captain.nation = 6
            } else if rank != 0 && get(p) <= 70 {
                note("작위를 잃었습니다.")
                rank = 0
            }
        }
    }

    /// 0xFC50.
    mutating func disband(_ f: Int) {
        memory.setFB(f, FleetField.strength, 0)
        memory.setFB(f, FleetField.state, memory.fb(f, FleetField.state) & ~1)
        let a = memory.fb(f, FleetField.admiral)
        if a < 120 {
            memory.setPB(a, 0x2E, 0)
            memory.setPB(a, 0x2C, 0xFF)
            memory.setPB(a, 0x2D, rng(42))
        }
        memory.setFB(f, FleetField.admiral, 0xFF)
        // Clear the occupied/active bits, but retain the cannon type until the result
        // panel has applied its prize selection. Unlike the original modal routine, the
        // remaster disbands the fleet before that deferred UI choice is confirmed.
        for s in 0..<10 { memory[memory.slot(f, s) + 8] &= 7 }
    }

    /// Takes the chosen beaten ships into the fleet (0xFCAF): a tenth of their crew stays,
    /// morale 60, holds empty; booty of the losing fleet goes into the holds.
    public mutating func takePrizes(_ picks: [Int], from b: Battle, names: [String], in world: World) {
        guard !ships.isEmpty else { return }
        let limit = max(0, min(10 - ships.count, spareCaptains))
        guard limit > 0 else { return }
        let eligible = Set(capturablePrizes(from: b, afterDisband: true))
        var seen = Set<Int>(), taken = 0
        for (k, j) in picks.enumerated() {
            guard taken < limit else { break }
            guard eligible.contains(j), seen.insert(j).inserted else { continue }
            let u = b.units[j]
            let a = memory.slot(u.fleet, u.slot)
            let cls = memory.shipClass(u.fleet, u.slot)
            guard world.navigation.classes.indices.contains(cls) else { continue }
            var s = Ship(class: cls, in: world.navigation, crew: 0, water: 0, food: 0)
            s.name = k < names.count && !names[k].isEmpty ? names[k] : world.navigation.classes[cls].name
            s.hull = memory[a + 2]
            s.maxHull = memory[a + 3]
            s.rudder = memory[a + 4]
            s.sail = memory[a + 5]
            s.guns = min(memory[a + 6], s.gunCapacity)
            s.gunType = memory[a + 8] & 7
            s.crew = min(memory.word(a) / 10, s.crewCapacity)
            s.morale = 60
            ships.append(s)
            officers[ships.count - 2].post = nil
            // Disbanding already clears occupancy. Clear the transferred source itself,
            // so duplicate selections or a repeated confirmation cannot clone the hulk.
            for offset in 0..<9 { memory[a + offset] = 0 }
            taken += 1
        }
        if taken > 0 { exportToMemory(port: nil) }
    }

    /// The result list and its later confirmation share the same eligibility rules.
    /// A disbanded fleet keeps intact hulls only until that deferred choice is applied.
    func capturablePrizes(from b: Battle, afterDisband: Bool = false) -> [Int] {
        guard b.phase == .over, [4, 6].contains(b.endCode),
              let ownSide = (0..<min(2, b.fleets.count)).first(where: { b.fleets[$0] == playerFleet }),
              b.sides.indices.contains(ownSide), let flag = b.sides[ownSide].first,
              b.units.indices.contains(flag) else { return [] }
        let enemySide = 1 - ownSide
        guard b.fleets.indices.contains(enemySide), let enemyFleet = b.fleets[enemySide],
              (0..<Fleets.count).contains(enemyFleet), enemyFleet != playerFleet else { return [] }
        let me = b.units[flag]
        return b.units.indices.filter { j in
            let u = b.units[j]
            guard u.side == enemySide, u.fleet == enemyFleet, (0..<10).contains(u.slot),
                  memory.slotUsed(u.fleet, u.slot) || (afterDisband && !memory.fleetActive(u.fleet)) else { return false }
            let a = memory.slot(u.fleet, u.slot)
            return memory[a + 2] > 0 && memory[a + 3] > 0
                && abs(u.x - me.x) <= 6 && (-6...5).contains(u.y - me.y)
        }
    }
}
