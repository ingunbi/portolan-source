import Foundation

// Sea events (docs/re/sea_events.md): ten invisible one-tile points at a time, DS:0xF9E + 4i
// (x, y words) and DS:0xFC6 + i (type); [0xFD0] is the next MONSTER.DAT record. Stepping on a
// point applies a fixed effect, no roll and no condition, and the next record takes its slot.

extension Voyage {
    static let seaEventSlots = 10

    /// The points now active, for tests and tools.
    public var seaEventPoints: [(x: Int, y: Int, type: Int)] {
        (0..<Voyage.seaEventSlots).map { (memory.word(0xF9E + 4 * $0), memory.word(0xFA0 + 4 * $0), memory[0xFC6 + $0]) }
    }

    /// 0x30731 after the player's step: every tile from `before` to the fleet's tile is tested
    /// (the original moves one tile at most). True when an event fired.
    mutating func checkSeaEvents(from before: (Int, Int), in world: World) -> Bool {
        let to = (Int(x), Int(y))
        var dx = to.0 - before.0
        if dx > World.width / 2 { dx -= World.width } else if dx < -World.width / 2 { dx += World.width }
        let dy = to.1 - before.1, n = max(abs(dx), abs(dy))
        for k in (n == 0 ? 0 : 1)...max(n, 0) {
            let tx = ((before.0 + (n == 0 ? 0 : dx * k / n)) % World.width + World.width) % World.width
            let ty = before.1 + (n == 0 ? 0 : dy * k / n)
            for i in 0..<Voyage.seaEventSlots where memory.word(0xF9E + 4 * i) == tx && memory.word(0xFA0 + 4 * i) == ty && (tx, ty) != (0, 0) {
                fireSeaEvent(slot: i, in: world)
                return true
            }
        }
        return false
    }

    /// 0x3076A: clear the slot, apply the effect (0x305DE), then read the next record.
    mutating func fireSeaEvent(slot i: Int, in world: World) {
        let t = memory[0xFC6 + i]
        memory.setWord(0xF9E + 4 * i, 0)
        memory.setWord(0xFA0 + 4 * i, 0)
        if applySeaEvent(t) { seaAlarms.append(t) }
        let k = memory[0xFD0]
        let next = world.seaEventPoints.indices.contains(k) ? world.seaEventPoints[k] : (x: 0, y: 0, type: 0)
        memory.setWord(0xF9E + 4 * i, next.x)
        memory.setWord(0xFA0 + 4 * i, next.y)
        memory[0xFC6 + i] = next.type
        memory[0xFD0] = min(0xFF, k + 1)
    }

    /// The handlers of DS:0xBB58. False when nothing happens and nothing is shown: the ones
    /// that strike the hindmost other ship when the hero's ship sails alone.
    mutating func applySeaEvent(_ t: Int) -> Bool {
        let last = ships.count > 1 ? ships.count - 1 : nil          // the hindmost ship the hero does not command
        switch t {
        case 0:                                                     // sirens: a quarter of every crew
            for s in ships.indices { ships[s].crew -= 25 * ships[s].crew / 100 }
        case 1:                                                     // the great eye: courage −10
            captain.courage -= min(captain.courage, 10)
            for k in officers.indices { officers[k].stats[4] -= min(officers[k].stats[4], 10) }
        case 2:                                                     // fog: a ship is gone, her captain stays
            guard let s = last else { return false }
            removeShip(s, keepCaptain: true)
        case 3:                                                     // the ray: nothing
            break
        case 4:                                                     // St Elmo's fire: morale +10
            for s in ships.indices { ships[s].morale += min(10, 100 - ships[s].morale) }
        case 5:                                                     // the firebird: sails halved
            guard let s = last else { return false }
            ships[s].sail >>= 1
        case 6:                                                     // the dragon storm: all goods overboard
            for s in ships.indices { ships[s].holds = [] }
        case 7:                                                     // the dragon passes: morale −10
            for s in ships.indices { ships[s].morale -= min(ships[s].morale, 10) }
        case 8:                                                     // whales: hull halved
            guard let s = last else { return false }
            ships[s].hull >>= 1
        case 9:                                                     // the ghost ship: luck −30
            captain.luck -= min(captain.luck, 30)
        default:
            return false
        }
        return true
    }
}
