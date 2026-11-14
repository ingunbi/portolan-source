import Foundation
import PortolanCore

// The harbour office (항구, building 3): supplies, the departure estimate, the capital's dock and
// the naming of a supply port. Rules: PortolanCore/Commands.swift and Voyage.swift.

func harborState() -> [String: Any] {
    let v = voyage!
    let m = v.market(in: world)
    let port = v.townPort
    var o: [String: Any] = [:]
    o["ships"] = v.ships.enumerated().map { (i, s) -> [String: Any] in
        ["index": i, "name": s.name, "freeCargo": s.freeCargo, "cargoCap": s.cargoCapacity, "crew": s.crew,
         "held": [s.water / 10, s.food / 10, s.lumber, s.shot]]
    }
    o["supplies"] = Supply.allCases.map { ["kind": $0.rawValue, "name": $0.name, "price": $0.price(at: m)] as [String: Any] }
    o["days"] = min(v.water, v.food) / max(1, v.crew)
    o["operating"] = v.ships.reduce(0) { $0 + $1.crew * $1.sailorShare / 100 }
    o["crew"] = v.crew
    o["port"] = port
    o["supplyPort"] = port >= 100
    if v.hasDock(port) {
        o["dock"] = ["stored": v.docked(at: port).enumerated().map { (k, d) -> [String: Any] in
                        ["index": k, "name": d.ship.name, "className": world.navigation.classes[d.ship.classIndex].name] },
                     "empty": message(277), "some": fill(276, "\(v.docked(at: port).count)")] as [String: Any]
    }
    o["namingAsk"] = message(926)
    return o
}

func harborCommand(_ name: String, _ cmd: [String: Any]) -> [String: Any]? {
    func int(_ k: String) -> Int? { (cmd[k] as? NSNumber)?.intValue }
    guard name.hasPrefix("harbor_"), voyage != nil else { return nil }
    var note = ""
    var extra: [String: Any] = [:]
    let port = voyage!.townPort
    let kinds: [CargoKind] = [.water, .food, .lumber, .shot]
    switch name {
    case "harbor_state": break
    case "harbor_buy":
        guard let k = int("kind"), let s = Supply(rawValue: k), let n = int("barrels"), let ship = int("ship") else { break }
        let m = voyage!.market(in: world)
        extra["done"] = act { $0.buy(s, barrels: n, ship: ship, at: m) }
    case "harbor_unload":
        guard let k = int("kind"), kinds.indices.contains(k), let n = int("barrels"), let ship = int("ship") else { break }
        extra["done"] = act { $0.unload(kinds[k], ship: ship, barrels: n) }
    case "harbor_depart":
        // 출항 (0x273DA): no sailors, no stores, or the estimate and the question.
        let v = voyage!
        if v.crew == 0 { extra["ok"] = false; note = "선원이 한 사람도 없습니다. 주점에서 선원을 모으십시오." }
        else { let c = v.departureCheck(); extra["canDepart"] = c.ok; note = c.line }
    case "harbor_dock_out": if let k = int("index") { note = act { $0.bringOut(k, at: port) } }
    case "harbor_dock_exchange": if let i = int("ship"), let k = int("index") { note = act { $0.exchangeShip(i, with: k, at: port) } }
    case "harbor_dock_store":
        if let i = int("ship") {
            let crew = voyage!.ships.indices.contains(i) ? voyage!.ships[i].crew : 0
            if int("confirm") == 1 || crew == 0 { note = act { $0.storeShip(i, at: port) } }
            else { extra["ask"] = fill(281, "\(crew)"); extra["askShip"] = i }
        }
    case "harbor_rename": if let n = cmd["name"] as? String, !n.isEmpty { note = act { $0.renamePort(port, to: String(n.prefix(7)), in: world) } }
    default: return nil
    }
    var o = townReply(["ok": extra["ok"] ?? true, "note": note, "harbor": harborState()])
    for (k, v) in extra where k != "ok" { o[k] = v }
    return o
}
