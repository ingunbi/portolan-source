import Foundation
import PortolanCore

// The fleet's commands (편성·지휘: captains, crew, shares, scuttling, cargo, formation, pay, items,
// the fleets in sight) and the 정보 screens (ships, persons, the hero, the cargo). Rules:
// Commands.swift, Info.swift, Items.swift. docs/re/commands.md, info.md.

/// Sailors taken off their ships and not yet placed (승무원편성).
var crewPool = CrewPool()

private func name(of person: Int, in v: Voyage) -> String {
    person == v.heroID ? v.captain.name : v.officers.first { $0.person == person }?.name ?? "—"
}

private func captainName(_ v: Voyage, _ i: Int) -> String {
    i == 0 ? v.captain.name : v.officers.indices.contains(i - 1) ? v.officers[i - 1].name : "—"
}

func shipJSON(_ v: Voyage, _ i: Int) -> [String: Any] {
    let s = v.ships[i]
    let c = world.navigation.classes[s.classIndex]
    let sail = s.crew * s.sailorShare / 100, watch = s.crew * s.watchShare / 100
    return [
        "index": i, "name": s.name, "class": s.classIndex, "className": c.name, "figurehead": s.figurehead,
        "captain": captainName(v, i), "flagship": i == 0, "scuttleAsk": fill(234, s.name),
        "hull": s.hull, "maxHull": s.maxHull, "rudder": s.rudder, "maxRudder": c.rudder, "sail": s.sail, "maxSail": c.sail,
        "crew": s.crew, "crewCap": s.crewCapacity, "morale": s.morale,
        "cargoLoad": s.cargoLoad, "cargoCap": s.cargoCapacity, "load": s.load, "capacity": c.capacity, "free": s.freeCargo,
        "loadPercent": v.loadPercent(i, in: world), "knots": v.shipKnots(i, in: world), "minCrew": c.minCrew,
        "water": s.water / 10, "food": s.food / 10, "lumber": s.lumber, "shot": s.shot,
        "guns": s.guns, "gunCap": s.gunCapacity, "gunName": v.memory.name(0x808, s.gunType), "gunType": s.gunType,
        "sailors": sail, "watch": watch, "deck": s.crew - sail - watch,
        "sailorShare": s.sailorShare, "watchShare": s.watchShare, "deckShare": 100 - s.sailorShare - s.watchShare,
        "holds": s.holds.map { ["good": $0.good, "name": world.navigation.goods[$0.good].name, "amount": $0.amount] as [String: Any] },
    ]
}

/// One person's sheet: the hero (k < 0) or companion k.
func personJSON(_ v: Voyage, _ k: Int) -> [String: Any] {
    let m = v.memory
    let p = k < 0 ? v.heroID : v.officers[k].person
    let r = DS.person(p)
    let stats = k < 0 ? Array(v.captain.stats.prefix(7)) : Array(v.officers[k].stats.prefix(7))
    let skills = k < 0 ? v.captain.skills : v.officers[k].skills
    let nation = k < 0 ? v.captain.nation : m[r + 0x31] & 0xF
    let ship = k < 0 ? 0 : k < v.ships.count - 1 ? k + 1 : -1
    let role = k < 0 ? "제독" : k < v.ships.count - 1 ? "선장" : v.officers[k].post?.name ?? "항해사"
    var o: [String: Any] = [
        "k": k, "person": p, "name": k < 0 ? v.captain.name : v.officers[k].name, "face": m.word(r + 0x1A), "nation": min(6, nation),
        "age": m[r + 0x2A], "role": role, "ship": ship >= 0 && v.ships.indices.contains(ship) ? v.ships[ship].name : "",
        "stats": stats, "statNames": (0..<7).map { m.name(0x87E, $0) },
        "navLevel": k < 0 ? v.captain.navLevel : v.officers[k].navLevel,
        "navExp": k < 0 ? v.captain.navExp : v.officers[k].navExp,
        "battleLevel": k < 0 ? v.captain.battleLevel : v.officers[k].battleLevel,
        "battleExp": k < 0 ? v.captain.battleExp : m.word(r + 0x28),
        "nationName": m.name(0x866, min(6, nation)),
        "skills": (0..<5).map { ["name": m.name(0x874, $0), "has": skills & (0x10 >> $0) != 0] as [String: Any] },
    ]
    if k < 0 { o["title"] = v.rank > 0 ? Town.title(rank: v.rank, hero: v.heroID) : "없음" }
    else { o["salary"] = v.officers[k].salary; o["loyalty"] = v.officers[k].loyalty }
    return o
}

func fleetState() -> [String: Any] {
    guard let v = voyage else { return [:] }
    var o: [String: Any] = [:]
    o["ships"] = v.ships.indices.map { shipJSON(v, $0) }
    o["pool"] = crewPool.sailors
    o["leaveText"] = message(231)
    o["officers"] = v.officers.enumerated().map { (k, of) -> [String: Any] in
        ["k": k, "person": of.person, "name": of.name, "loyalty": of.loyalty, "salary": of.salary]
    }
    o["people"] = [["person": v.heroID, "name": v.captain.name] as [String: Any]]
        + v.officers.map { ["person": $0.person, "name": $0.name] as [String: Any] }
    o["items"] = v.items.map { id -> [String: Any] in
        let it = v.item(id)
        return ["id": id, "name": it.name, "equipped": it.equipped, "slot": it.slot ?? -1, "type": it.type,
                "text": itemTexts.indices.contains(id) ? itemTexts[id] : ""]
    }
    let sum = v.fleetSummary(in: world)
    o["summary"] = ["rudder": sum.rudder, "sail": sum.sail, "hull": sum.hull, "crew": sum.crew, "guns": sum.guns, "power": sum.power]
    o["sight"] = v.fleetsInSight().map { f -> [String: Any] in
        let adm = v.memory.fb(f, FleetField.admiral)
        return ["id": f, "nation": min(6, f / 10), "name": adm < 120 ? v.memory.person(adm).name : "함대"]
    }
    o["noShips"] = message(217)
    o["noSight"] = message(215)
    return o
}

func infoState() -> [String: Any] {
    guard let v = voyage else { return [:] }
    var o = fleetState()
    o["people"] = (-1..<v.officers.count).map { personJSON(v, $0) }
    o["hero"] = [
        "gold": v.gold % 10000, "bars": v.gold / 10000,
        "fame": (0..<3).map { ["name": menus.indices.contains(42) && menus[42].indices.contains($0) ? menus[42][$0] : "", "value": v.fame[$0]] as [String: Any] },
        "standing": (0..<6).map { ["nation": v.memory.name(0x866, $0), "value": abs(v.standing[$0] - 100), "against": v.standing[$0] < 100] as [String: Any] },
    ] as [String: Any]
    o["cargo"] = v.goodsTotals.map { ["good": $0.good, "name": world.navigation.goods[$0.good].name, "amount": $0.amount] as [String: Any] }
    o["family"] = v.memory.string(DS.person(v.heroID) + 0x0D, max: 13)
    o["empty"] = message(918)
    o["sites"] = v.foundSites.map { i -> [String: Any] in
        let d = world.discoveryInfo(i)
        return ["id": i, "name": d.name, "picture": d.picture, "text": d.text, "category": v.siteCategory(i), "grade": v.siteGrade(i)]
    }
    o["charted"] = v.memory.word(Discovery.chartedTotal)
    o["chart"] = chartRows(v)
    o["fleetCell"] = [50 + ((Int(v.x) + 720) % 2160 - 12) / 4, 50 + (Int(v.y) - 12) / 4]
    o["log"] = v.logbook.map { e -> [String: Any] in
        ["date": String(format: "%4d/%2d/%2d", e.year, e.month, e.day), "text": v.logText(e, messages: messages, world: world)]
    }
    o["logPrev"] = message(1147); o["logNext"] = message(1148)
    o["buildingNames"] = menus.indices.contains(58) ? menus[58] : []
    o["port"] = dockedPort ?? -1
    o["noCargo"] = "실려 있는 교역품이 없습니다."
    return o
}

/// The explored cells of the chart, one row of 90 columns each ('1' explored), DS:0xD74.
func chartRows(_ v: Voyage) -> [String] {
    let m = v.memory
    return (0..<45).map { row in
        String((0..<90).map { col in m[0xD74 + 12 * row + col / 8] & (0x80 >> (col & 7)) != 0 ? "1" : "0" })
    }
}

/// Four 24×24-tile cells at the chart cell (col, row), as 0x1D251 draws them: 48 rows of 48 columns,
/// '1' land and '0' sea; with `fog` the cells not explored are all sea. `mark` is the site in tiles from the corner.
func chartZoom(col: Int, row: Int, fog: Bool, site: (x: Int, y: Int)?) -> [String: Any] {
    let m = voyage!.memory
    func explored(_ c: Int, _ r: Int) -> Bool {
        guard (0..<45).contains(r) else { return false }
        let cc = ((c % 90) + 90) % 90
        return m[0xD74 + 12 * r + cc / 8] & (0x80 >> (cc & 7)) != 0
    }
    var rows: [String] = []
    for dy in 0..<2 {
        for ty in 0..<24 {
            var line = ""
            for dx in 0..<2 {
                let c = (col + dx) % 90, r = row + dy
                let open = !fog || explored(c, r)
                for tx in 0..<24 {
                    let x = c * 24 + tx, y = r * 24 + ty
                    line += !open || world.isSea(x: Double(x) + 0.5, y: Double(y) + 0.5) ? "0" : "1"
                }
            }
            rows.append(line)
        }
    }
    var o: [String: Any] = ["col": col, "row": row, "grid": rows]
    if let s = site { o["mark"] = [((s.x - col * 24) % 2160 + 2160) % 2160, s.y - row * 24] }
    return o
}

/// The treasure map of item `id` (0x1D6EF): the four cells around its site, without fog, and the site.
func treasureZoom(_ id: Int) -> [String: Any] {
    let m = voyage!.memory
    let a = Discovery.site(m[TownDS.item(id) + 0x18])
    let x = m.word(a), y = m.word(a + 2)
    let col = x % 24 < 12 ? (x / 24 + 89) % 90 : x / 24
    let row = y % 24 < 12 && y / 24 != 0 ? y / 24 - 1 : y / 24
    return chartZoom(col: col, row: row, fog: false, site: (x, y))
}

func fleetReply(_ extra: [String: Any] = [:]) -> [String: Any] {
    var o = townReply(["ok": true, "fleet": fleetState()])
    for (k, x) in extra { o[k] = x }
    return o
}

func fleetCommand(_ name: String, _ cmd: [String: Any]) -> [String: Any]? {
    func int(_ k: String) -> Int? { (cmd[k] as? NSNumber)?.intValue }
    guard name.hasPrefix("fleet_") || name.hasPrefix("info_"), voyage != nil else { return nil }
    switch name {
    case "fleet_state":
        return fleetReply()
    case "info_state":
        var o = townReply(["ok": true, "info": infoState()])
        o["fleet"] = fleetState()
        return o
    case "info_chart":
        guard let col = int("col"), let row = int("row") else { return fleetReply() }
        return fleetReply(["zoom": chartZoom(col: col, row: row, fog: true, site: nil)])
    case "info_advise":
        // 적하일람: who tells where a good sells best (msgs 848–850).
        guard let g = int("good"), world.navigation.goods.indices.contains(g), let v = voyage else { return fleetReply() }
        let name = world.navigation.goods[g].name
        let p = v.bestMarket(for: g, in: world)
        let m = v.memory.string(DS.port + DS.portSize * p + 4, max: 14)
        let port = m.isEmpty ? (world.ports.first(where: { $0.id == p })?.name ?? "") : m
        guard let who = v.cargoAdviser() else { return fleetReply(["note": ""]) }
        if who.name == nil { return fleetReply(["note": fill(848, name, port)]) }
        return fleetReply(["note": "\(who.name!): " + (who.knows ? fill(849, name, port) : fill(850, name))])
    case "fleet_open":
        crewPool = CrewPool()
        return fleetReply()
    case "fleet_close":
        crewPool = CrewPool()                       // sailors still in the pool are let go (231)
        return fleetReply()
    case "fleet_captain":
        guard let i = int("ship"), let p = int("person") else { return fleetReply() }
        let ok = act { $0.changeCaptain(ship: i, to: p) }
        let v = voyage!
        return fleetReply(ok ? ["note": Korean.particles("\(captainName(v, p == v.heroID ? 0 : i))(가) 선장이 되었습니다.")] : [:])
    case "fleet_crew":
        guard let i = int("ship"), let n = int("crew"), voyage!.ships.indices.contains(i) else { return fleetReply() }
        var p = crewPool
        let s = voyage!.ships[i]
        let target = max(0, min(n, s.crew + p.sailors, s.crewCapacity))
        if act({ $0.setCrew(ship: i, to: target, pool: &p) }) { crewPool = p }
        return fleetReply()
    case "fleet_share":
        guard let i = int("ship"), let r = int("row") else { return fleetReply() }
        act { $0.nudgeShare(ship: i, row: r, up: (cmd["up"] as? Bool) ?? true) }
        return fleetReply()
    case "fleet_scuttle":
        guard let i = int("ship") else { return fleetReply() }
        if i == 0 { return fleetReply(["note": message(233)]) }
        act { _ = $0.scuttle(i) }
        return fleetReply()
    case "fleet_cargo":
        // kind: 0 water, 1 food, 2 lumber, 3 shot, 4+n the good n; to == ship count throws it overboard.
        guard let from = int("from"), let to = int("to"), let kind = int("kind"), let n = int("amount"), n > 0 else { return fleetReply() }
        let k: CargoKind = kind == 0 ? .water : kind == 1 ? .food : kind == 2 ? .lumber : kind == 3 ? .shot : .good(kind - 4)
        let ok = to >= voyage!.ships.count ? act { $0.unload(k, ship: from, barrels: n) } : act { $0.moveCargo(k, from: from, to: to, amount: n) }
        return fleetReply(ok ? [:] : ["note": message(211)])
    case "fleet_order":
        guard let order = (cmd["order"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }) else { return fleetReply() }
        act { _ = $0.reorderShips(order) }
        return fleetReply()
    case "fleet_pay":
        guard let k = int("officer"), let to = int("to") else { return fleetReply() }
        return fleetReply(["note": act { $0.raisePay(officer: k, to: to) }])
    case "fleet_equip":
        guard let id = int("id") else { return fleetReply() }
        return fleetReply(["note": render(act { $0.toggleEquip(id) }).joined(separator: "\n")])
    case "fleet_use":
        guard let id = int("id") else { return fleetReply() }
        let it = voyage!.item(id)
        if (80...89).contains(id) { return fleetReply(["zoom": treasureZoom(id)]) }
        return fleetReply(["note": (it.slot != nil ? [message(1098)] : act { $0.useItem(id) }).joined(separator: "\n")])
    case "fleet_inspect":
        guard let f = int("fleet") else { return fleetReply() }
        return fleetReply(["note": act { $0.inspect(f, in: world) }.joined(separator: "\n")])
    default: return nil
    }
}
