import Foundation
import PortolanCore

// Sea commands that were missing in the app: going ashore (상륙: a village to search, open coast with
// emergency repairs, water and waiting), hailing a fleet in reach (교섭) and sailing to a known port
// (항구이동). Rules: Commands.swift (coast), Discovery.swift (villages), Fleets.swift (hail).

/// The sea state plus the figures these commands change, and the cues sounded on the way.
func shoreReply(_ extra: [String: Any] = [:]) -> [String: Any] {
    guard var v = voyage else { return ["ok": false, "error": "no game"] }
    var o = seaState(v)
    if !v.soundCues.isEmpty { o["sounds"] = v.soundCues; v.soundCues.removeAll(); voyage = v }
    o["gold"] = v.gold; o["crew"] = v.crew; o["water"] = v.water; o["food"] = v.food
    o["fleet"] = fleetState()
    for (k, x) in extra { o[k] = x }
    return o
}

/// A port's name as the hero knows it (supply ports can be renamed).
func portNameOf(_ p: Int) -> String {
    guard let v = voyage else { return "" }
    let n = v.memory.string(DS.port + DS.portSize * p + 4, max: 14)
    return n.isEmpty ? (world.ports.first(where: { $0.id == p })?.name ?? "") : n
}

func shoreCommand(_ name: String, _ cmd: [String: Any]) -> [String: Any]? {
    func int(_ k: String) -> Int? { (cmd[k] as? NSNumber)?.intValue }
    guard ["ashore_start", "ashore_coast", "land_search", "land_host", "land_plunder", "coast_repair", "coast_search",
           "coast_water", "coast_leave", "coast_wait", "hail_fleet", "port_list", "auto_sail", "debug_warp"].contains(name), voyage != nil else { return nil }
    switch name {
    case "ashore_start":
        // 상륙 (0x34651): the coast landed on before, a sighted village, a port to put into, open coast, or msg 441.
        let v = voyage!
        if let t = v.landedAt, v.ashore {
            let water = act { $0.landOnCoast(at: (t[0], t[1])) }
            return shoreReply(["kind": "coast", "x": t[0], "y": t[1], "hasWater": water, "leaveAsk": message(417)])
        }
        if let s = v.landingSite { return shoreReply(["kind": "village", "site": s, "leaveAsk": message(417)]) }
        if (cmd["dockable"] as? Bool) == true { return shoreReply(["kind": "dock"]) }
        guard let t = v.coastTile(in: world) else { return shoreReply(["kind": "none", "note": message(441)]) }
        return shoreReply(["kind": "coastAsk", "text": message(440), "x": t.0, "y": t.1])
    case "ashore_coast":
        guard let x = int("x"), let y = int("y") else { return shoreReply() }
        let water = act { $0.landOnCoast(at: (x, y)) }
        return shoreReply(["kind": "coast", "x": x, "y": y, "hasWater": water, "leaveAsk": message(417)])
    case "land_search":
        // 보물탐색 (0x340FD): the hospitality bonus is the app's, passed in and given back.
        guard let site = int("site") else { return shoreReply() }
        let bonus = int("bonus") ?? 0
        let r = act { $0.searchSite(site, bonus: bonus, in: world) }
        var extra: [String: Any] = ["lines": r.lines, "found": r.found, "bonus": r.found ? 0 : bonus]
        if r.found { extra["picture"] = String(format: "pictures/%03d.png", world.discoveryInfo(site).picture) }
        return shoreReply(extra)
    case "land_host":
        var bonus = int("bonus") ?? 0
        if act({ $0.hostVillagers() }) {
            bonus += 5
            return shoreReply(["lines": [Korean.particles("우호도가 \(bonus)까지 올랐습니다.\n주민들이 수색을 돕기로 했습니다.")], "bonus": bonus])
        }
        return shoreReply(["lines": [message(435)], "bonus": bonus])
    case "land_plunder":
        let r = act { $0.plunderVillage() }
        return shoreReply(["lines": ["\(r.food)명분의 식량을 빼앗았습니다."] + (r.fight ? ["원주민이 맞서 싸웠습니다."] : []), "bonus": 0])
    case "coast_repair":
        guard let i = int("ship"), let part = int("part"), let n = int("lumber"), voyage!.ships.indices.contains(i), (0...2).contains(part) else { return shoreReply() }
        return shoreReply(["lines": [act { $0.emergencyRepair(ship: i, part: part, lumber: n, in: world) }]])
    case "coast_search":
        guard let x = int("x"), let y = int("y") else { return shoreReply() }
        let r = act { $0.searchCoast(at: (x, y), water: (cmd["water"] as? Bool) ?? false, in: world) }
        return shoreReply(["lines": r.lines, "hasWater": r.water])
    case "coast_water":
        guard let i = int("ship"), let n = int("barrels"), voyage!.ships.indices.contains(i) else { return shoreReply() }
        return shoreReply(["lines": [act { $0.takeWater(ship: i, barrels: n) } ? "물을 실었습니다." : message(422)]])
    case "coast_leave":
        act { $0.leaveCoast() }
        return shoreReply(["kind": "left"])
    case "coast_wait":
        act { $0.waitAshore() }
        return shoreReply(["kind": "waiting"])
    case "debug_warp":
        // Testing aid: put the ship on open coast far from any port ("coast") or beside the nearest fleet ("fleet").
        var v = voyage!
        if (cmd["to"] as? String) == "fleet" {
            let at = v.fleetsInSight().isEmpty ? Array(0..<Fleets.count) : v.fleetsInSight()
            let pool = at.filter { v.memory.fleetActive($0) && !v.memory.fleetInPort($0) && $0 != v.playerFleet }
            guard let f = pool.min(by: { a, b in
                let pa = v.memory.fleetAt(a), pb = v.memory.fleetAt(b)
                return abs(pa.x - Int(v.x)) + abs(pa.y - Int(v.y)) < abs(pb.x - Int(v.x)) + abs(pb.y - Int(v.y)) }) else { return shoreReply(["error": "no fleet"]) }
            let p = v.memory.fleetAt(f)
            v.x = Double(p.x) + 0.5; v.y = Double(p.y) + 0.5
            voyage = v
            return shoreReply(["warped": f])
        }
        let ox = Int(v.x), oy = Int(v.y)
        for r in 0..<400 {
            for dy in -r...r {
                for dx in -r...r where max(abs(dx), abs(dy)) == r {
                    let tx = ox + dx, ty = oy + dy
                    guard ty >= 0, ty < World.height, tx >= 0, tx < World.width, world.isSea(x: Double(tx) + 0.5, y: Double(ty) + 0.5) else { continue }
                    if world.ports.contains(where: { hypot(Double($0.x) - Double(tx), Double($0.y) - Double(ty)) < 6 }) { continue }
                    var t = v
                    t.x = Double(tx) + 0.5; t.y = Double(ty) + 0.5
                    if t.coastTile(in: world) != nil, t.landingSite == nil {
                        voyage = t
                        return shoreReply(["warped": -1])
                    }
                }
            }
        }
        return shoreReply(["error": "no coast"])
    case "hail_fleet":
        // 교섭 (0x1FABD): a patron's own scene, or the fleet's answer; a hunter may attack at once.
        guard let f = int("fleet"), voyage!.fleetsNearby().contains(f) else { return shoreReply() }
        let adm = voyage!.memory.fb(f, FleetField.admiral)
        if let s = patronScene(adm) { return shoreReply().merging(s) { _, n in n } }
        let h = act { $0.hail(f) }
        let m = voyage!.memory
        let target = m.fb(f, FleetField.target)
        var text = message(h.line)
        if [153, 154].contains(h.line), target < 130 { text = fill(h.line, m.string(DS.port + DS.portSize * target + 4, max: 14)) }
        if h.line == 157, target < 120 {
            text = fill(h.line, ["포르투갈", "에스파니아", "투르크", "잉글랜드", "이탈리아", "네덜란드", "해적"][min(6, m.fleetOf(person: target) / 10)], m.person(target).name)
        }
        if h.attacks {
            act { $0.pendingBattle = Encounter(attacker: adm, defender: $0.heroID) }
            encounterOpening = nil
        }
        return shoreReply(["lines": [text]])
    case "port_list":
        // 항구이동 (menu 29): the ports the hero knows, nearest first; the first mate must know surveying (msg 855).
        let v = voyage!
        let known = world.ports.filter { v.memory[DS.port + DS.portSize * $0.id + 0x13] & 0x10 != 0 }
            .sorted { a, b in
                hypot(world.deltaX(from: v.x, to: Double(a.x)), Double(a.y) - v.y) < hypot(world.deltaX(from: v.x, to: Double(b.x)), Double(b.y) - v.y)
            }
        let why = !v.canAutoSail ? message(855) : v.ashore ? "상륙 중에는 쓸 수 없습니다." : ""
        return shoreReply(["ports": known.prefix(30).map { ["id": $0.id, "name": portNameOf($0.id)] as [String: Any] }, "can": v.canAutoSail && !v.ashore, "why": why])
    case "auto_sail":
        guard let p = int("port"), let h = world.ports.first(where: { $0.id == p }) else { return shoreReply() }
        let ok = act { $0.autoSail(to: h, in: world) }
        return shoreReply(ok ? [:] : ["note": "항로를 찾지 못했습니다."])
    default: return nil
    }
}
