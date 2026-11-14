#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import PortolanCore

/// Developer playtest driver. It plans over readable town tiles, then uses the same
/// directional key handling and update loop as a player. It never writes hero/camera
/// coordinates, moves NPCs directly, or calls the building-entry method.
enum TownWalkDriver {
    private static let offsets = [(0, -1), (1, 0), (0, 1), (-1, 0)]
    private static let codes: [UInt16] = [KeyCode.up, KeyCode.right, KeyCode.down, KeyCode.left]

    static func enter(_ service: HarborPanel, game: Game, size: CGSize,
                      press: (String) throws -> Void) throws {
        func fail(_ message: String) -> Playthrough.Failure {
            Playthrough.Failure(message: "Town walk to \(service.title): " + message)
        }
        var messages = 0
        func acknowledgeMessages() throws {
            // Leaving a building can display its farewell after SwiftUI removes the
            // interior. Use the visible acknowledgement for every queued message.
            for _ in 0..<8 {
                guard let message = game.portMessageText else { return }
                print("town-walk: acknowledging port message: \(message)")
                try press("portolan.portMessage.dismiss")
                messages += 1
            }
            if game.portMessageText != nil { throw fail("port messages did not clear after eight acknowledgements") }
        }
        try acknowledgeMessages()
        if game.panel != nil { try press("portolan.building.leave") }
        try acknowledgeMessages()
        guard game.interaction.worldInputAllowed, let harbor = game.harbor,
              let map = game.world.town(harbor.id), let goal = map.doors[service.rawValue] else {
            throw fail("town input or real doorway unavailable")
        }
        guard service.isOpen(tick: game.voyage.tick) else { throw fail("door is closed") }
        let origin = game.voyage.townHero
        var moved = 0, waits = 0
        for _ in 0..<1600 {
            if game.buildingScene == service {
                print("town-walk: port \(harbor.id) \(service.title), \(origin.x),\(origin.y) → door \(goal.x),\(goal.y); \(moved) adjacent tile steps, \(waits) idle passes, \(messages) port messages; no coordinate writes")
                return
            }
            if game.session != nil || game.buildingScene != nil { throw fail("entered an unexpected building or script") }
            try acknowledgeMessages()
            guard game.interaction.worldInputAllowed, game.harbor?.id == harbor.id else {
                throw fail("town input lost before reaching the door")
            }
            let start = game.voyage.townHero
            guard let direction = nextDirection(map: map, from: start, to: goal, folk: game.voyage.townsfolk) else {
                waits += 1
                if waits > 300 { throw fail("no walkable path after 300 idle passes at \(start)") }
                game.update(dt: game.townStepTime + 0.001, viewSize: size)
                continue
            }
            let down = event(.keyDown, direction: direction, game: game)
            guard game.handleKey(down) else { throw fail("direction key was rejected") }
            let beforeTick = game.voyage.tick, beforeDay = game.voyage.day
            game.update(dt: game.townStepTime + 0.001, viewSize: size)
            _ = game.handleKey(event(.keyUp, direction: direction, game: game))
            let after = game.voyage.townHero
            let expected = (start.x + offsets[direction].0, start.y + offsets[direction].1)
            // Some original entry scripts immediately send the hero back outside. The
            // real entry still consumes time and returns the hero below the reached door.
            if expected == goal, after == (goal.x, goal.y + 1),
               game.voyage.tick != beforeTick || game.voyage.day != beforeDay {
                moved += 1
                print("town-walk: port \(harbor.id) \(service.title), \(origin.x),\(origin.y) → door \(goal.x),\(goal.y); \(moved) adjacent tile steps, \(waits) idle passes, \(messages) port messages; real timed door entry, no coordinate writes")
                return
            }
            // The production door transition places the hero one tile below its door.
            if game.buildingScene == nil {
                let distance = abs(after.x - start.x) + abs(after.y - start.y)
                guard distance <= 1 else { throw fail("non-adjacent move \(start) → \(after)") }
                if distance == 1 { moved += 1 } else { waits += 1 }
            } else {
                guard game.buildingScene == service,
                      abs(goal.x - start.x) + abs(goal.y - start.y) == 1 else {
                    throw fail("building opened away from its adjacent doorway")
                }
                moved += 1
            }
        }
        throw fail("step budget exhausted at \(game.voyage.townHero)")
    }

    private static func event(_ type: NSEvent.EventType, direction: Int, game: Game) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: game.inputWindow?.windowNumber ?? 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                         keyCode: codes[direction])!
    }

    /// Replan each step around the current NPC positions and every other building's door.
    private static func nextDirection(map: TownMap, from start: (x: Int, y: Int),
                                      to goal: (x: Int, y: Int), folk: [Townsperson]) -> Int? {
        let startID = start.y * TownMap.size + start.x
        var queue = [(start.x, start.y)]
        var head = 0
        var first: [Int: Int] = [startID: -1]
        let otherDoors = Set(map.doors.values.filter { $0 != goal }.map { $0.y * TownMap.size + $0.x })
        while head < queue.count {
            let p = queue[head]; head += 1
            for (direction, offset) in offsets.enumerated() {
                let x = p.0 + offset.0, y = p.1 + offset.1, id = y * TownMap.size + x
                guard (0...94).contains(x), (0...94).contains(y), first[id] == nil,
                      !otherDoors.contains(id), map.walkable(x, y),
                      !folk.contains(where: { abs($0.x - x) <= 1 && abs($0.y - y) <= 1 }) else { continue }
                let step = p == (start.x, start.y) ? direction : first[p.1 * TownMap.size + p.0]!
                if (x, y) == goal { return step }
                first[id] = step
                queue.append((x, y))
            }
        }
        return nil
    }
}
