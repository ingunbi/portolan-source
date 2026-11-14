import Foundation
import PortolanCore

// The game's rules as a process of its own: one JSON object per line in, one per line out. The
// Android app starts it (it ships as a native library) and draws what it reports, so the Swift
// rules (PortolanCore) run unchanged there.

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
guard let assetsPath = args.first else {
    FileHandle.standardError.write(Data("usage: PortolanEngine <assets>\n".utf8))
    exit(2)
}

func reply(_ object: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) { print(s) }
}

let world: World
do { world = try World(assets: URL(fileURLWithPath: assetsPath)) }
catch { reply(["ok": false, "error": "assets: \(error)"]); exit(1) }

/// MESSAGE.DAT lines (assets/text.json).
let messages: [String] = {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: assetsPath).appendingPathComponent("text.json")),
          let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let m = j["message"] as? [String] else { return [] }
    return m
}()
func message(_ n: Int) -> String { messages.indices.contains(n) ? messages[n] : "" }

/// MENU.DAT items (assets/text.json "menus").
let menus: [[String]] = {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: assetsPath).appendingPathComponent("text.json")),
          let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let m = j["menus"] as? [[String]] else { return [] }
    return m
}()

/// ITEM.MES: one description per item id (assets/text.json "items").
let itemTexts: [String] = {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: assetsPath).appendingPathComponent("text.json")),
          let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let m = j["items"] as? [String] else { return [] }
    return m
}()

/// `%s` / `%d` filled in order, as the Mac app does.
func fill(_ n: Int, _ args: String...) -> String {
    var t = message(n)
    for a in args {
        guard let r = t.range(of: "%-?[0-9]*l?[sdu]", options: .regularExpression) else { break }
        t.replaceSubrange(r, with: a)
    }
    return Korean.particles(t)
}

var voyage: Voyage?
/// The day last seen at sea, for the daily scripts.
var lastDay = -1
var battle: Battle?
var result: BattleResult?
var encounterOpening: BattleOpening?

let nations = ["포르투갈", "에스파니아", "오스만 투르크", "잉글랜드", "이탈리아", "네덜란드", "해적"]

func seaState(_ voyageIn: Voyage) -> [String: Any] {
    var v = voyageIn
    var o: [String: Any] = [
        "ok": true,
        "year": v.year, "month": v.month, "day": v.dayOfMonth, "tick": v.tick,
        "gold": v.gold, "x": v.x, "y": v.y, "heading8": v.heading8, "speedUnits": v.speedUnits, "sail": v.sail,
        "anchored": v.anchored,
        "ashore": v.ashore, "landable": v.ashore || v.landingSite != nil,
        "daysAtSea": v.daysAtSea, "water": v.water, "food": v.food, "crew": v.crew,
        "weather": ["windDir": v.weather.windDir, "windStrength": v.weather.windStrength,
                    "currentDir": v.weather.currentDir, "currentStrength": v.weather.currentStrength],
        "ships": v.ships.map { ["name": $0.name, "crew": $0.crew, "hull": $0.hull, "class": $0.classIndex, "shot": $0.shot, "guns": $0.guns] as [String: Any] },
        "captain": v.captain.name,
        "gameOver": v.gameOver ?? "",
    ]
    // Fleets in sight, to draw and to talk to.
    let m = v.memory
    let close = Set(v.fleetsNearby())
    o["fleets"] = v.fleetsInSight().map { f -> [String: Any] in
        let p = m.fleetAt(f)
        let adm = m.fb(f, FleetField.admiral)
        return ["id": f, "x": p.x, "y": p.y, "heading": m.fb(f, FleetField.heading), "nation": min(6, f / 10),
                "admiral": adm < 120 ? m.person(adm).name : "함대", "class": m.shipClass(f, 0), "near": close.contains(f)]
    }
    if let e = v.pendingBattle {
        let other = e.attacker == v.heroID ? e.defender : e.attacker
        var op = encounterOpening ?? v.opening(e)
        encounterOpening = op
        let them = m.person(other)
        let heroName = m.person(v.heroID).name
        let fleet = m.fleetOf(person: other)
        op = encounterOpening!
        o["encounter"] = [
            "enemy": them.name, "nation": nations[min(6, fleet / 10)], "ours": op.ours, "theirs": op.theirs,
            "defending": op.defending, "merchantOffer": op.merchantOffer,
            "lines": op.lines.map { fill($0, them.name, heroName) }, "face": m.word(DS.person(other) + 0x1A), "person": other,
        ] as [String: Any]
    }
    return o
}

func battleState(_ b: Battle, _ v: Voyage) -> [String: Any] {
    var units: [[String: Any]] = []
    for (k, u) in b.units.enumerated() {
        let alive = b.alive(k, v)
        units.append([
            "k": k, "x": u.x, "y": u.y, "heading": u.heading, "side": u.side, "owner": u.owner, "flags": u.flags,
            "hull": b.hull(k, v), "maxHull": b.maxHull(k, v), "crew": b.crew(k, v), "maxCrew": b.maxCrew(k, v),
            "rudder": b.rudder(k, v), "sails": b.sails(k, v), "shot": u.shot, "guns": b.guns(k, v),
            "name": b.shipName(k, v), "alive": alive, "flagship": b.isFlagship(k), "sailOnly": b.sailOnly(k, v),
            "player": u.fleet == v.playerFleet, "target": u.target ?? -1, "range": u.range,
        ])
    }
    var o: [String: Any] = [
        "ok": true, "units": units,
        "map": b.map.map { $0 & 0xFF },
        "width": Battle.width, "height": Battle.height,
        "windDir": b.windDir, "windStrength": b.windStrength,
        "tick": v.tick, "active": b.active ?? -1, "moved": b.moved, "movesLeft": b.movesLeft,
        "phase": "\(b.phase)", "endCode": b.endCode,
        "log": Array(b.log.lines.suffix(8)),
        "sides": b.sides,
        "canLeave": b.canLeave(v),
    ]
    if let s = b.lastStrike { o["strike"] = ["attacker": s.attacker, "target": s.target, "boarding": s.boarding, "serial": s.serial] as [String: Any] }
    if let a = b.active, b.phase == .command {
        if !b.moved {
            let reach = b.reach(a, v)
            o["reach"] = reach.map { ["cell": $0.key, "heading": $0.value.heading, "path": $0.value.path] as [String: Any] }
        }
        o["targets"] = b.targets(v)
        o["duelOffered"] = b.targets(v).filter { b.duelOffered($0) }
        o["boardable"] = b.targets(v).filter { b.canBoard(a, $0) }
    }
    if let d = b.duel {
        o["duel"] = ["a": d.a, "b": d.b, "meter": d.meter, "turn": d.turn, "playerIsA": d.playerIsA, "line": d.lastLine,
                     "finished": d.finished, "damage": d.lastDamage,
                     "nameA": v.memory.person(d.a).name, "nameB": v.memory.person(d.b).name] as [String: Any]
    }
    return o
}

/// After a command: a battle that has ended gets its result worked out once.
func settleBattle() {
    guard var b = battle, b.phase == .over, result == nil, var v = voyage else { return }
    result = v.finishBattle(&b, in: world)
    battle = b
    voyage = v
}

func fullBattleReply() -> [String: Any] {
    settleBattle()
    guard let b = battle, let v = voyage else { return ["ok": false, "error": "no battle"] }
    var o = battleState(b, v)
    if let r = result {
        o["result"] = ["code": r.code, "lines": r.lines, "gold": r.gold, "item": r.item ?? -1,
                       "capturable": r.capturable, "mayTake": r.mayTake,
                       "capturableNames": r.capturable.map { b.shipName($0, v) }] as [String: Any]
    }
    return o
}

reply(["ok": true, "ready": true, "ports": world.ports.count])
while let line = readLine() {
    guard let data = line.data(using: .utf8), let cmd = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let name = cmd["cmd"] as? String else { reply(["ok": false, "error": "bad command"]); continue }
    func int(_ k: String) -> Int? { (cmd[k] as? NSNumber)?.intValue }
    func dbl(_ k: String) -> Double? { (cmd[k] as? NSNumber)?.doubleValue }
    switch name {
    case "new":
        // A new game for hero 0...5 in the home port (0x1626B): the story's scenes bring the ship and the purse.
        let h = int("hero") ?? 0
        var v: Voyage
        if int("shortcut") == 1 { v = Voyage.joanAfterPrologue(in: world) }          // Joan after her prologue (tests)
        else {
            v = Voyage.newGame(in: world, hero: h, given: cmd["given"] as? String, family: cmd["family"] as? String,
                               seed: UInt32(truncatingIfNeeded: int("seed") ?? 1))
        }
        v.rng = GameRandom(seed: UInt32(truncatingIfNeeded: int("seed") ?? 1))
        voyage = v; battle = nil; result = nil; encounterOpening = nil
        script = nil; sceneBuilding = -1; sduel = nil; pending = nil; dockedPort = nil; openBuilding = -1
        var o = seaState(v)
        o["port"] = v.townPort; o["wallet"] = walletInfo(v)
        reply(o)
    case "enter_sea":
        // The app's own purse and stores come along: gold, crew, supplies, shot and guns.
        guard var v = voyage else { reply(["ok": false, "error": "no game"]); break }
        applyWallet(&v, cmd)
        if let x = dbl("x"), let y = dbl("y") { v.x = x; v.y = y }
        if let y = int("year") { v.year = y }
        if let m = int("month") { v.month = m }
        if let d = int("day") { v.dayOfMonth = d }
        if let t = int("tick") { v.tick = t }
        if let d = int("daysAtSea") { v.daysAtSea = d }
        if let p = dockedPort { v.logDeparture(from: p); v.leaveTown() }
        dockedPort = nil; openBuilding = -1; pending = nil
        lastDay = v.day
        v.sail = 0; v.anchored = false
        v.exportToMemory(port: nil)
        voyage = v
        reply(seaState(v))
    case "tick":
        guard var v = voyage else { reply(["ok": false, "error": "no game"]); break }
        if v.pendingBattle == nil, battle == nil, script == nil {
            if let h = int("stick"), h >= 0 {
                v.steer(toward: h & 7)
                if v.sail == 0 { v.setSail(1) }
            } else if cmd["course"] != nil, let c = cmd["course"] as? [NSNumber], c.count == 2 {
                if v.setSeaCourse(x: c[0].doubleValue, y: c[1].doubleValue, in: world), v.sail == 0 { v.setSail(1) }
            } else if v.waypoint == nil {
                v.sail = 0
            }
            // The app's frames are slower than the Mac's: split the time into 1/60 s steps so the fleet never jumps
            // past the arrival radius of its waypoint in one call (a step is a tile or two).
            var left = min(0.25, max(0, dbl("dt") ?? 0.016))
            repeat {
                let step = min(left, 1.0 / 60)
                v.tick(step, in: world)
                left -= step
            } while left > 1e-9 && v.pendingBattle == nil && v.gameOver == nil
        }
        voyage = v
        var o = seaState(v)
        if battle == nil, script == nil {
            // What happened on the way: a sea alarm (three text pages), the day's scripts of the hero's story,
            // the notice line, the incident in progress and the sound cues.
            if let t = v.seaAlarms.first {
                v.seaAlarms.removeFirst()
                o["alarm"] = [message(1176), message(510 + 2 * t), message(511 + 2 * t)]
            }
            if v.day != lastDay {
                lastDay = v.day
                var s = ScriptSession(key1: ScriptKey.atSea, key2: v.daysAtSea, port: nil, contexts: [.hero])
                s.advance(&v, in: world)
                if !s.done { script = s; sceneBuilding = -1; afterScene = nil; sduel = nil; o["scene"] = sceneJSON(s, v) }
            }
            if let last = v.log.last { o["notice"] = last; v.log.removeAll() }
            if !v.soundCues.isEmpty { o["sounds"] = v.soundCues; v.soundCues.removeAll() }
            voyage = v
            o["gold"] = v.gold; o["crew"] = v.crew; o["water"] = v.water; o["food"] = v.food
        }
        if let e = v.event, v.eventAnnounced { o["event"] = e.rawValue }
        reply(o)
    case "state":
        if let v = voyage { reply(seaState(v)) } else { reply(["ok": false, "error": "no game"]) }
    case "attack_fleet":
        guard var v = voyage, let f = int("fleet") else { reply(["ok": false, "error": "no game"]); break }
        if !(15..<60).contains(v.tick) { var o = seaState(v); o["note"] = message(781); reply(o); break }   // the night
        _ = v.attack(f)
        voyage = v; encounterOpening = nil
        reply(seaState(v))
    case "flee":
        guard var v = voyage else { break }
        let ok = v.tryToFlee()
        if ok { v.pendingBattle = nil; encounterOpening = nil }
        voyage = v
        var o = seaState(v); o["fled"] = ok; o["note"] = ok ? message(822) : message(824); reply(o)
    case "surrender":
        guard var v = voyage, let e = v.pendingBattle else { break }
        let pirate = v.memory.fleetOf(person: e.attacker) / 10 == 6
        let line = v.surrender(toPirates: pirate)
        let f = v.memory.fleetOf(person: e.attacker)
        if f < Fleets.count { v.sendToPort(f, mission: 0, port: v.memory.fb(f, FleetField.home)) }
        v.pendingBattle = nil; encounterOpening = nil
        voyage = v
        var o = seaState(v); o["note"] = message(line); reply(o)
    case "battle_begin":
        // The battle-start scripts (event 0xA1) may take over or call the battle off.
        guard var v = voyage, let e = v.pendingBattle else { reply(["ok": false, "error": "no encounter"]); break }
        let enemy = e.attacker == v.heroID ? e.defender : e.attacker
        for ctx in [ScriptContext.hero, .shared] { v.memory.setWord(ctx.base + 0xA + 2 * 60, enemy) }
        voyage = v
        reply(runScene(key1: ScriptKey.battleStart, key2: enemy, atSea: true, contexts: [.hero, .shared]) { leave in
            guard var v = voyage else { return ["ok": false] }
            encounterOpening = nil
            if leave { v.pendingBattle = nil; voyage = v; return seaState(v) }
            battle = v.beginBattle(e, in: world); result = nil
            if battle == nil { v.pendingBattle = nil }
            voyage = v
            return battle == nil ? seaState(v) : fullBattleReply()
        })
    case "battle_accept_offer":
        guard var v = voyage, let e = v.pendingBattle else { break }
        v.exportToMemory(port: nil)
        if var b = Battle(attacker: e.attacker, defender: e.defender, voyage: &v, world: world) { b.endCode = 2; b.phase = .over; battle = b }
        voyage = v; result = nil; encounterOpening = nil
        reply(fullBattleReply())
    case "battle_state":
        reply(fullBattleReply())
    case "battle_move":
        guard var b = battle, let v = voyage, b.phase == .command, let x = int("x"), let y = int("y") else { reply(["ok": false, "error": "no battle"]); break }
        _ = b.playerMove(to: x, y, v)
        battle = b; reply(fullBattleReply())
    case "battle_turn":
        guard var b = battle, b.phase == .command else { break }
        b.playerTurn(int("d") ?? 0)
        battle = b; reply(fullBattleReply())
    case "battle_attack":
        guard var b = battle, var v = voyage, b.phase == .command, let j = int("target") else { break }
        b.playerAttack(j, challenge: (cmd["challenge"] as? Bool) ?? false, &v, world: world)
        battle = b; voyage = v; reply(fullBattleReply())
    case "battle_pass":
        guard var b = battle, var v = voyage, b.phase == .command else { break }
        b.endTurn(&v, world: world)
        battle = b; voyage = v; reply(fullBattleReply())
    case "battle_leave":
        guard var b = battle, var v = voyage, b.phase == .command else { break }
        b.playerLeave(&v, world: world)
        battle = b; voyage = v; reply(fullBattleReply())
    case "battle_signal":
        guard var b = battle, b.phase == .command else { break }
        b.signal(gather: cmd["gather"] as? Bool, attack: cmd["attack"] as? Bool)
        battle = b; reply(fullBattleReply())
    case "battle_order":
        guard var b = battle, b.phase == .command, let k = int("unit") else { break }
        let target: Int?? = cmd["target"] == nil ? nil : (int("target").map { $0 < 0 ? .some(nil) : .some($0) } ?? nil)
        b.order(k, attack: cmd["attack"] as? Bool, gunnery: cmd["gunnery"] as? Bool, target: target)
        battle = b; reply(fullBattleReply())
    case "duel_move":
        guard var b = battle, var v = voyage, b.phase == .duel, let m = int("move") else { break }
        b.duelMove(m, &v, world: world)
        battle = b; voyage = v; reply(fullBattleReply())
    case "battle_close":
        guard var v = voyage, let b = battle, let r = result else { reply(["ok": false, "error": "no result"]); break }
        let picks = (cmd["picks"] as? [NSNumber])?.map { $0.intValue } ?? []
        let selected = Array(Set(picks).intersection(r.capturable)).sorted().prefix(max(0, r.mayTake))
        if !selected.isEmpty { v.takePrizes(Array(selected), from: b, names: [], in: world) }
        let enemy = b.admirals[b.units[b.sides[0][0]].fleet == v.playerFleet ? 1 : 0] ?? 0xFF
        v.pendingBattle = nil
        battle = nil; result = nil; encounterOpening = nil
        voyage = v
        reply(runScene(key1: ScriptKey.battleEnd, key2: enemy, atSea: true, contexts: [.shared, .hero]) { _ in seaState(voyage!) })
    case "debug_encounter":
        // Starts a battle with the nearest sighted fleet (testing aid).
        guard var v = voyage else { break }
        let near = v.fleetsNearby()
        let f = int("fleet") ?? near.first ?? 1
        let p = v.memory.fleetAt(f)
        v.x = Double(p.x) + 0.5; v.y = Double(p.y) + 0.5; v.tick = 20
        v.pendingBattle = Encounter(attacker: v.heroID, defender: v.memory.fb(f, FleetField.admiral))
        voyage = v; encounterOpening = nil
        reply(seaState(v))
    case "save":
        // The whole voyage (ships, items, bank, markets, the fleets of the world) into a file.
        guard let v = voyage, let path = cmd["path"] as? String else { reply(["ok": false, "error": "no game"]); break }
        do { try SaveGame.write(v, to: URL(fileURLWithPath: path)); reply(["ok": true]) }
        catch { reply(["ok": false, "error": "\(error)"]) }
    case "load":
        guard let path = cmd["path"] as? String else { reply(["ok": false, "error": "no path"]); break }
        do {
            var v = try SaveGame.read(from: URL(fileURLWithPath: path))
            v.afterLoad()
            voyage = v; battle = nil; result = nil; encounterOpening = nil; pending = nil; dockedPort = nil; openBuilding = -1
            script = nil; sceneBuilding = -1; sduel = nil
            reply(seaState(v))
        } catch { reply(["ok": false, "error": "\(error)"]) }
    case "quit":
        exit(0)
    default:
        if let r = newGameCommand(name, cmd) ?? townWalkCommand(name, cmd) ?? townCommand(name, cmd) ?? yardCommand(name, cmd) ?? sceneCommand(name, cmd) ?? tradeCommand(name, cmd) ?? harborCommand(name, cmd) ?? gamblingCommand(name, cmd) ?? fleetCommand(name, cmd) ?? shoreCommand(name, cmd) { reply(r) } else { reply(["ok": false, "error": "unknown command \(name)"]) }
    }
}
