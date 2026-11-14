import Foundation
import PortolanCore

// The residence of a story character (building 7, 0x2D9A8): a patron who pays for discoveries and tells
// tales, a map maker who pays for charted sea, a scholar who teaches a skill. Rules: Discovery.swift.

/// The panel of building 7: who lives here (nil name: nobody) and what the hero may do.
func residenceState() -> [String: Any] {
    guard let v = voyage else { return [:] }
    guard let k = v.resident(in: v.townPort) else { return ["none": message(933)] }
    let r = DS.npc + DS.npcSize * k
    let type = v.residentType(k)
    var o: [String: Any] = [
        "k": k, "name": v.memory.string(r, max: 16), "portrait": v.memory[r + 0x11], "type": type,
        "contracted": v.contracted(k), "hasMap": v.items.contains { (80...89).contains($0) },
    ]
    if type >= 1 {
        let s = v.skillOffer(k)
        o["skill"] = ["name": s.name, "fee": s.fee, "ok": s.ok, "has": v.captain.skills & s.bit != 0] as [String: Any]
    }
    return o
}

func residenceAction(_ action: String, _ cmd: [String: Any]) -> [String: Any]? {
    guard action.hasPrefix("residence."), let v0 = voyage, let k = v0.resident(in: v0.townPort) else { return nil }
    let type = v0.residentType(k)
    switch action {
    case "residence.contract":
        return talk([.text(act { $0.contract(k) } ? message(type == 0 ? 483 : 497) : message(496))])
    case "residence.report":
        if type == 0 { return talk(act { $0.reportDiscoveries(to: k, in: world) }.map { TownLine.text($0) }) }
        let t = act { $0.reportGeography(to: k) }
        var r = talk(t.isEmpty ? [] : [.text(t)])
        if voyage!.worldCharted && t.hasPrefix("와아") { r["picture"] = "images/graph_63.png" }
        return r
    case "residence.rumour":
        return talk([.text(act { $0.rumour() })])
    case "residence.map":
        // 지도확인 (0x2D4E3): the treasure site of a map held, for a fee (msg 785).
        return talk([.msg(785)], ask: ["kind": "yesNo"]) { a in
            guard case .yes(true) = a else { return talk([]) }
            if let at = act({ $0.checkMap() }) { return talk([.msg(786), .text(message(783) + at + " " + message(784))]) }
            return talk([.msg(239)])
        }
    case "residence.learn":
        let o = voyage!.skillOffer(k)
        if act({ $0.learnSkill(at: k) }) { return talk([.text(Korean.particles("\(o.name)을(를) 익혔습니다."))]) }
        return talk([.text(o.ok ? message(504) : "능력이 아직 모자랍니다.")])
    default: return nil
    }
}
