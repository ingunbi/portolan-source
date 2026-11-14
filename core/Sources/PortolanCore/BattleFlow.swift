import Foundation

// Turn order, AI, the player's orders, duels and the aftermath of a sea battle
// (docs/re/battle.md §6, §9–§12).

extension Battle {
    // MARK: turns (0xFB26)

    /// Runs the other ships until the player's flagship must act, a duel needs him, or the
    /// battle is over. Each pass of ten unit slots over the four sides is one 20-minute tick.
    public mutating func advance(_ v: inout Voyage, world: World) {
        while endCode == 0 && phase == .command && active == nil {
            if v.tick >= Battle.sunset {
                endCode = 1
                break
            }
            if sideIndex >= 4 {
                sideIndex = 0
                round += 1
            }
            if round >= 10 {
                round = 0
                v.tick += 1
                continue
            }
            let s = sideIndex
            sideIndex += 1
            guard round < sides[s].count else { continue }
            let i = sides[s][round]
            guard alive(i, v) else { continue }
            if units[i].owner == 0x80 && round == 0 {
                active = i
                movesLeft = movePoints(i, v)
                moved = false
                return
            }
            aiTurn(i, &v, world: world)
            endCheck(v)
        }
        if endCode != 0 { phase = .over }
    }

    /// 0xA1B0: the battle ends when a main fleet's flagship is lost or leaves.
    mutating func endCheck(_ v: Voyage) {
        guard endCode == 0 else { return }
        for s in 0...1 {
            let f = sides[s][0]
            if !alive(f, v) {
                var code = units[f].fleet == v.playerFleet ? 5 : 4
                if units[f].flags & 0x40 != 0 { code -= 2 }
                endCode = code
                phase = .over
                return
            }
        }
    }

    /// Ends the player's turn and lets the battle go on.
    public mutating func endTurn(_ v: inout Voyage, world: World) {
        active = nil
        endCheck(v)
        advance(&v, world: world)
    }

    // MARK: the player's flagship (0xB6D3)

    /// 이동: sail to a reachable hex (msgs 767, 768). An attack may follow.
    @discardableResult
    public mutating func playerMove(to x: Int, _ y: Int, _ v: Voyage) -> Bool {
        guard phase == .command, Battle.inBounds(x, y), let i = active, !moved,
              let r = reach(i, v)[y * Battle.width + x] else { return false }
        sail(i, path: r.path, v)
        moved = true
        return true
    }

    /// 방향전환 in place, 60° either way (0xA8EF, msg 769); ends the move.
    public mutating func playerTurn(_ delta: Int) {
        guard phase == .command, let i = active, !moved else { return }
        units[i].heading = (units[i].heading + (delta > 0 ? 1 : 5)) % 6
        units[i].acc = 0
        moved = true
    }

    /// Enemies the flagship can fire at or board now.
    public func targets(_ v: Voyage) -> [Int] {
        guard let i = active else { return [] }
        return enemies(of: i).filter { alive($0, v) && (canFire(i, at: $0) || canBoard(i, $0)) }
    }

    /// Whether boarding `j` may become a duel with its admiral (msg 770).
    public func duelOffered(_ j: Int) -> Bool {
        guard let i = active, units.indices.contains(j), canBoard(i, j), !canFire(i, at: j) else { return false }
        return (0..<4).contains { units[i].side & 1 != $0 & 1 && sides[$0].first == j }
    }

    /// 공격 (0xAAB2, msg 772): fire if the broadside bears, else board; ends the turn.
    public mutating func playerAttack(_ j: Int, challenge: Bool = false, _ v: inout Voyage, world: World) {
        // A stale map click must neither attack a friendly/lost ship nor consume the turn.
        guard phase == .command, let i = active, targets(v).contains(j) else { return }
        if canFire(i, at: j) {
            fire(i, at: j, &v, world: world)
        } else if canBoard(i, j) {
            if challenge && duelOffered(j) {
                if v.rng(max(1, v.memory.pb(v.heroID, 0x23))) + crew(i, v) >= crew(j, v) {
                    startDuel(challenger: units[i].captain, against: units[j].captain, playerIsA: true, j: j, &v)
                    return
                }
                log.lines.append("적이 앞을 막았습니다.")                     // 771
            }
            board(i, j, &v)
        }
        endTurn(&v, world: world)
    }

    /// 신호 (0xB140): the flagship's 이탈 / 집결 / 공세 bits passed to every other own ship.
    public mutating func signal(flee: Bool? = nil, gather: Bool? = nil, attack: Bool? = nil) {
        guard let i = active else { return }
        var f = units[i].flags
        if let flee { f = flee ? f | 8 : f & ~8 }
        if let gather { f = gather ? f | 4 : f & ~4 }
        if let attack { f = attack ? f | 1 : f & ~1 }
        units[i].flags = f
        for k in friends(of: i) where k != i && units[k].owner == 0x80 {
            units[k].flags = (units[k].flags & 0xF0) + (f & 0x0D) + ((f & 1) << 1)
        }
    }

    /// 작전 (0xB503): one ship's policy, method and target.
    public mutating func order(_ k: Int, attack: Bool? = nil, gunnery: Bool? = nil, target: Int?? = nil) {
        guard units[k].owner == 0x80 else { return }
        if let attack { units[k].flags = attack ? units[k].flags | 3 : units[k].flags & ~3 }
        if let gunnery { units[k].flags = gunnery ? units[k].flags | 0x10 : units[k].flags & ~0x10 }
        if let target {
            units[k].target = target
            units[k].flags = target == nil ? units[k].flags & ~0x80 : units[k].flags | 0x80
        }
    }

    /// 이탈 (0xB54B, msg 776): only from an edge hex of open sea.
    public func canLeave(_ v: Voyage) -> Bool {
        guard let i = active else { return false }
        return Battle.onEdge(units[i].x, units[i].y)
    }

    public mutating func playerLeave(_ v: inout Voyage, world: World) {
        guard let i = active, canLeave(v) else { return }
        leaveMap(i)
        endTurn(&v, world: world)
    }

    static func onEdge(_ x: Int, _ y: Int) -> Bool { x == 0 || x == width - 1 || y == 0 || y == height - 1 }

    /// 0xE2F1.
    mutating func leaveMap(_ i: Int) {
        units[i].flags |= 0x40
        map[units[i].y * Battle.width + units[i].x] &= 0x1F
        clearTargets(i)
    }

    // MARK: AI (0xA213)

    mutating func aiTurn(_ i: Int, _ v: inout Voyage, world: World) {
        let own = sides[units[i].side][0]
        if !flagshipFit(own, v) { units[i].flags |= 8 }
        let reachable = reach(i, v, ai: true)
        let foes = enemies(of: i)
        // Threat (0xDA7F) and firing scores (0xDB16).
        var threat = [Int](repeating: 0, count: Battle.width * Battle.height)
        for e in foes {
            let u = units[e]
            for y in max(0, u.y - 5)...min(Battle.height - 1, u.y + 5) {
                for x in max(0, u.x - 5)...min(Battle.width - 1, u.x + 5) {
                    let d = Battle.distance(u.x, u.y, x, y)
                    guard d > 0 else { continue }
                    var t = threat[y * Battle.width + x]
                    if u.shot > 0 && d >= 2 && d <= u.range && Battle.inArc(u.x, u.y, heading: u.heading, x, y) { t += u.gunPower[d - 1] }
                    if d == 1 { t += u.melee }
                    threat[y * Battle.width + x] = t & 0xFF
                }
            }
        }
        var score: [Int: Int] = [:], firing: Set<Int> = []
        let f = units[i].flags
        if f & 3 != 0 {
            let wGun = f & 0x10 != 0 ? 2 : 1, wMelee = f & 0x10 != 0 ? 1 : 2
            for (cell, r) in reachable {
                let x = cell % Battle.width, y = cell / Battle.width
                var best = 0
                for e in foes {
                    let d = Battle.distance(x, y, units[e].x, units[e].y)
                    var s = 0
                    if canFire(i, at: e, fromX: x, y: y, heading: r.heading) { s = units[i].gunPower[d - 1] * wGun }
                    if d == 1 { s = (units[i].melee * wMelee) & 0xFF }
                    if s > 0 && s >= best {
                        best = s
                        firing.insert(cell)
                    }
                }
                score[cell] = best
            }
        }
        let here = units[i].y * Battle.width + units[i].x
        var dest = here
        switch units[i].flags & 0xF {
        case 0, 1:                                                         // 0x9FD4 분산·퇴각
            dest = reachable.keys.min { a, b in
                threat[a] != threat[b] ? threat[a] < threat[b] : reachable[a]!.path.count > reachable[b]!.path.count
            } ?? here
        case 2, 3:                                                         // 0x9D07 toward the target
            let t = units[i].target.flatMap { alive($0, v) ? $0 : nil } ?? sides[foes.isEmpty ? 0 : units[foes[0]].side][0]
            dest = approach(i, t, reachable, score, clampRange: true)
        case 4, 5:                                                         // 0x9E5E 집결·퇴각
            var bestDT = 0xFF, bestS = 0xFF, bestDU = 0
            for (cell, r) in reachable.sorted(by: { $0.key < $1.key }) {
                let dT = Battle.distance(cell % Battle.width, cell / Battle.width, units[own].x, units[own].y)
                let s = threat[cell], dU = r.path.count
                let q = (((min(dT, 10) * bestS * 10 / 100) & 0xFF) + 9) / 10 * 10 & 0xFF
                if dT < bestDT || (dT == bestDT && q > s) || (dT == bestDT && q == s && dU > bestDU) {
                    bestDT = dT; bestS = s; bestDU = dU; dest = cell
                }
            }
        case 6, 7:                                                         // 0x9E3B 집결·공격
            dest = approach(i, own, reachable, score, clampRange: false)
        default:                                                           // 0x9C21 이탈
            if Battle.onEdge(units[i].x, units[i].y) {
                leaveMap(i)
                return
            }
            let edges = reachable.keys.filter { Battle.onEdge($0 % Battle.width, $0 / Battle.width) }
            if let far = edges.max(by: { reachable[$0]!.path.count < reachable[$1]!.path.count }) {
                dest = far
            } else {
                let points = [(0, 0), (51, 0), (0, 47), (51, 47), (25, 0), (26, 0), (0, 23), (0, 24), (51, 23), (51, 24), (25, 47), (26, 47)]
                dest = reachable.keys.min { a, b in
                    let da = points.map { Battle.distance(a % Battle.width, a / Battle.width, $0.0, $0.1) }.min()!
                    let db = points.map { Battle.distance(b % Battle.width, b / Battle.width, $0.0, $0.1) }.min()!
                    return da < db
                } ?? here
            }
        }
        if dest != here, let r = reachable[dest] {
            sail(i, path: r.path, v)
        } else if let t = nearestFoe(i, foes, v) {
            // Turn in place toward the target (0xE142).
            let want = (0..<6).min { a, b in
                let pa = Battle.neighbour(units[i].x, units[i].y, a), pb = Battle.neighbour(units[i].x, units[i].y, b)
                return Battle.distance(pa.0, pa.1, units[t].x, units[t].y) < Battle.distance(pb.0, pb.1, units[t].x, units[t].y)
            } ?? units[i].heading
            if canFire(i, at: t) == false && (want == (units[i].heading + 1) % 6 || want == (units[i].heading + 5) % 6) {
                units[i].heading = want
            }
            units[i].acc = min(100, units[i].acc + turnRate(i, v))
        }
        guard units[i].flags & 3 != 0 else { return }
        attackFromHere(i, &v, world: world)
    }

    /// 0x9D07: the reachable hex closest to `t` (no closer than gun range when firing).
    func approach(_ i: Int, _ t: Int, _ reachable: [Int: (heading: Int, path: [Int])], _ score: [Int: Int], clampRange: Bool) -> Int {
        var bestDT = 0xFF, bestS = 0, bestDU = 0
        var dest = units[i].y * Battle.width + units[i].x
        for (cell, r) in reachable.sorted(by: { $0.key < $1.key }) {
            var dT = Battle.distance(cell % Battle.width, cell / Battle.width, units[t].x, units[t].y)
            if clampRange { dT = max(dT, units[i].range) }
            let dU = r.path.count, s = score[cell] ?? 0
            let q = ((((12 - min(dT, 10)) * bestS * 10 / 100) & 0xFF) + 9) / 10 * 10 & 0xFF
            if dT < bestDT || (dT == bestDT && q < s) || (dT == bestDT && q == s && dU > bestDU) {
                bestDT = dT; bestS = s; bestDU = dU; dest = cell
            }
        }
        return dest
    }

    func nearestFoe(_ i: Int, _ foes: [Int], _ v: Voyage) -> Int? {
        foes.filter { alive($0, v) }.min {
            Battle.distance(units[i].x, units[i].y, units[$0].x, units[$0].y) < Battle.distance(units[i].x, units[i].y, units[$1].x, units[$1].y)
        }
    }

    /// 0x9902: a side gives up once its flagship is down to 40% of crew or hull, or gone.
    func flagshipFit(_ f: Int, _ v: Voyage) -> Bool {
        guard alive(f, v) else { return false }
        let record = DS.ship + DS.shipSize * v.memory[slotAddress(units[f], v) + 7]
        return crew(f, v) > v.memory.word(record + 0x15) * 4 / 10 && hull(f, v) > maxHull(f, v) * 4 / 10
    }

    /// Target choice (0xE7A0) and the attack (0xE727): the assigned ship, else the first live
    /// one of the enemy main fleet, then its reinforcement.
    mutating func attackFromHere(_ i: Int, _ v: inout Voyage, world: World) {
        let snapshot = v
        let me = self
        func possible(_ j: Int) -> Bool { me.alive(j, snapshot) && (me.canFire(i, at: j) || me.canBoard(i, j)) }
        let order = (0..<4).filter { $0 & 1 != units[i].side & 1 }.sorted { ($0 >= 2 ? 1 : 0) < ($1 >= 2 ? 1 : 0) }.flatMap { sides[$0] }
        let assigned = units[i].target.flatMap { possible($0) ? $0 : nil }
        guard let j = assigned ?? order.first(where: { possible($0) }) else { return }
        // An enemy admiral may challenge the player's admiral when boarding (0xE651).
        if canBoard(i, j) && sides[units[i].side].first == i && units[j].owner == 0x80 && sides[units[j].side].first == j {
            let me = units[i].captain, him = v.heroID
            if v.rng(15) + v.memory.pb(me, 0x21) >= v.memory.pb(him, 0x21) && v.memory.pb(me, 0x23) >= v.rng(max(1, crew(j, v))) {
                log.lines.append("적 제독이 일대일 승부를 청해 왔습니다.")             // 1062
                startDuel(challenger: me, against: him, playerIsA: false, j: i, &v)
                return
            }
        }
        if units[i].flags & 0x10 != 0 {
            if canFire(i, at: j) { fire(i, at: j, &v, world: world) } else if canBoard(i, j) { board(i, j, &v) }
        } else {
            if canBoard(i, j) { board(i, j, &v) } else { fire(i, at: j, &v, world: world) }
        }
    }

    // MARK: duel (0x12694)

    /// Weapon and armour of a duellist (0x1218C): the player's equipped items, an NPC's by level.
    static func arms(_ p: Int, player: Bool, _ v: Voyage) -> (Int, Int, Int) {
        let item = { (id: Int) in 0x8144 + 26 * id }
        if player {
            var atk = 0, type = 0, def = 0
            for id in v.items where id < 120 && v.memory[item(id) + 0x19] & 0x10 != 0 {
                let cat = v.memory[item(id) + 0x19] & 0xF
                if cat < 4 { atk = v.memory[item(id) + 0x18]; type = cat }
                if cat == 6 { def += v.memory[item(id) + 0x18] }
            }
            return (atk, def, type)
        }
        let b = min(v.memory.pb(p, 0x25), 24), n = min(v.memory.pb(p, 0x24), 24)
        let weapon = [0x0F, 0x07, 0x0D, 0x0C, 0x0E, 0x0B][b == 24 ? 3 + v.memory.pb(p, 0x24) % 3 : b >> 3]
        let armour = [0x11, 0x12, 0x13, 0x13][n >> 3]
        return (v.memory[item(weapon) + 0x18], v.memory[item(armour) + 0x18], v.memory[item(weapon) + 0x19] & 0xF)
    }

    mutating func startDuel(challenger a: Int, against b: Int, playerIsA: Bool, j: Int, _ v: inout Voyage) {
        var m = v.memory.word(0xA538)
        if !playerIsA { m = 200 - m }
        duel = DuelState(a: a, b: b, meter: m, playerIsA: playerIsA,
                         weaponA: Battle.arms(a, player: playerIsA, v), weaponB: Battle.arms(b, player: !playerIsA, v))
        duelTarget = j
        phase = .duel
    }

    /// One exchange with the player's move; the other side moves by its rule (0x10FCE).
    public mutating func duelMove(_ move: Int, _ v: inout Voyage, world: World) {
        guard var d = duel else { return }
        Duel.exchange(&d, playerMove: move, &v)
        duel = d
        guard d.finished else { return }
        let playerWon = d.playerIsA ? d.meter >= 200 : d.meter <= 0
        let decided = d.meter >= 200 || d.meter <= 0
        v.memory.setWord(0xA538, d.playerIsA ? d.meter : 200 - d.meter)
        if decided {
            let enemy = d.playerIsA ? d.b : d.a
            Duel.reward(won: playerWon, enemy: enemy, &v)
            let j = duelTarget ?? -1
            if units.indices.contains(j) && (2...3).contains(units[j].side) {
                v.memory.setWord(slotAddress(units[j], v), 0)          // reinforcement flagship: crew lost either way
            } else {
                endCode = playerWon ? 6 : 7
            }
        }
        duel = nil
        phase = endCode == 0 ? .command : .over
        if endCode == 0 { endTurn(&v, world: world) }
    }
}

// MARK: - duels

public enum Duel {
    /// The other side's move (0x10FCE).
    static func aiMove(attacking: Bool, weaponType: Int, defence: Int, _ v: inout Voyage) -> Int {
        let r = v.rng(10)
        let (lo, hi): (Int, Int)
        if attacking {
            (lo, hi) = weaponType == 1 ? (6, 7) : weaponType == 2 ? (2, 7) : weaponType == 3 ? (2, 3) : (3, 6)
        } else {
            (lo, hi) = defence >= 60 ? (6, 7) : defence >= 20 ? (2, 7) : (2, 3)
        }
        return r < lo ? 0 : r > hi ? 2 : 1
    }

    /// One attack (0x12029). Turns alternate: A attacks on even turns.
    static func exchange(_ d: inout DuelState, playerMove: Int, _ v: inout Voyage) {
        let aAttacks = d.turn % 2 == 0
        let att = aAttacks ? d.a : d.b, def = aAttacks ? d.b : d.a
        let wa = aAttacks ? d.weaponA : d.weaponB, wd = aAttacks ? d.weaponB : d.weaponA
        let playerAttacks = aAttacks == d.playerIsA
        let m = playerAttacks ? playerMove : aiMove(attacking: true, weaponType: wa.2, defence: wa.1, &v)
        let dm = playerAttacks ? aiMove(attacking: false, weaponType: wd.2, defence: wd.1, &v) : playerMove
        let pa = (aAttacks ? d.histA : d.histB) & 3, pd = (aAttacks ? d.histB : d.histA) & 3
        if aAttacks {
            d.histA = (d.histA << 2 | m) & 0xFF
            d.histB = (d.histB << 2 | dm) & 0xFF
        } else {
            d.histB = (d.histB << 2 | m) & 0xFF
            d.histA = (d.histA << 2 | dm) & 0xFF
        }
        let bl = v.memory.pb(att, 0x25), sword = v.memory.pb(att, 0x21)
        let power = bl * sword / 50 + sword / 2
        let mult = (wa.0 >= 1 ? 50 : 0) + 25 * m + (wa.2 == m + 1 ? wa.0 : 0)
        var atk = (((wa.0 + power) * (4 - pa)) & 0xFFFF) >> 2
        atk = ((atk * mult) & 0xFFFF) / 100
        let ev = 5 * (2 - dm) + wd.1 + min(v.memory.pb(def, 0x25), 20)
        let raw = (100 - ev) * atk / 100
        let base = raw < 0 ? 50 : min(raw, 50)
        var dmg = base + v.rng(bl >> 1)
        let x = ((2 * dm + 5) * (4 - pd) * 2 - (wd.1 >> 1)) & 0xFFFF
        if x >= v.rng(100) { dmg = 0 }
        if aAttacks { d.meter = min(d.meter + dmg, 200) } else { d.meter -= min(dmg, d.meter) }
        d.lastDamage = dmg
        let names = ["찌른다", "벤다", "친다"], guards = ["걷어낸다", "맞받는다", "비킨다"]
        d.lastLine = "\(v.memory.person(att).name): \(names[m]) / \(v.memory.person(def).name): \(guards[dm]) → \(dmg == 0 ? "빗나감" : "\(dmg)")"
        d.turn += 1
        if d.turn >= 20 || d.meter >= 200 || d.meter <= 0 { d.finished = true }
    }

    /// Experience for the player (0x1278F, msg 1061).
    static func reward(won: Bool, enemy e: Int, _ v: inout Voyage) {
        let hero = DS.person(v.heroID)
        let ebl = v.memory.pb(e, 0x25)
        var exp = v.memory.word(hero + 0x28) + (won ? 10 : 3) * ebl, lvl = v.memory[hero + 0x25]
        let ups = Officers.levelUp(level: &lvl, exp: &exp)
        v.memory.setWord(hero + 0x28, min(0xFFFF, exp))
        v.memory[hero + 0x25] = lvl
        if ups > 0 || v.memory.pb(e, 0x21) >= v.memory[hero + 0x21] {
            v.memory[hero + 0x21] = min(100, v.memory[hero + 0x21] + v.rng(3))
            v.memory[hero + 0x20] = min(100, v.memory[hero + 0x20] + v.rng(3))
        }
    }

    /// A duel outside battle (script opcode E8): the meter after it, 100 at the start.
    public static func start(hero: Int, against p: Int, _ v: Voyage) -> DuelState {
        DuelState(a: hero, b: p, meter: 100, playerIsA: true,
                  weaponA: Battle.arms(hero, player: true, v), weaponB: Battle.arms(p, player: false, v))
    }

    public static func step(_ d: inout DuelState, move: Int, _ v: inout Voyage) {
        exchange(&d, playerMove: move, &v)
    }
}
