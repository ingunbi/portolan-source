import Foundation
import PortolanCore

// The walking town (TownWalk.swift): the hero's tile, the window, the townsfolk and the talk of a townsperson
// the hero bumps into. The app sends the direction held at each pass of the walk loop and draws what comes back.

func townView(_ v: Voyage) -> [String: Any] {
    let h = v.townHero, c = v.townCamera
    return ["hero": [h.x, h.y], "camera": [c.x, c.y], "tick": v.tick, "night": v.townNight,
            "folk": v.townsfolk.map { ["slot": $0.slot, "x": $0.x, "y": $0.y, "k": $0.k] as [String: Any] }]
}

func townWalkCommand(_ name: String, _ cmd: [String: Any]) -> [String: Any]? {
    guard name == "town_view" || name == "town_pass", let p = dockedPort, voyage != nil, let m = world.town(p) else { return nil }
    switch name {
    case "town_view":
        return townReply(["ok": true, "town": townView(voyage!)])
    default:
        // One pass of the walk loop (0x1B337): a step toward `dir` (0 up, 1 right, 2 down, 3 left) and the door check,
        // or, with no direction, the townsfolk alone.
        let dir = (cmd["dir"] as? NSNumber)?.intValue ?? -1
        var v = voyage!
        var o: [String: Any] = ["ok": true]
        if (0...3).contains(dir) {
            let before = v.townHero
            let r = v.townStep(dir, port: p, map: m)
            o["face"] = Voyage.townFacing(from: before, to: v.townHero, tried: dir)
            if case .talk(let t) = r { o["talk"] = render(v.townTalk(t, port: p, in: world)) }
            if let k = v.townDoor(map: m) { o["door"] = k }
        } else {
            v.townsfolkTick(port: p, map: m)
        }
        voyage = v
        o["town"] = townView(v)
        return o
    }
}
