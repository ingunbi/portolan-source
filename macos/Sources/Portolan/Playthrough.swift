#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation
import PortolanCore

/// An integration playthrough of the actions exposed by the game. Unlike visual fixtures,
/// this never assigns ships, money, story flags, time or world coordinates to reach a goal.
/// It uses no real save slot. Every expected story gate is asserted rather than skipped.
enum Playthrough {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(game: Game, capture: @escaping (String, Game) -> Void,
                    press: @escaping (String) throws -> Void,
                    answer: @escaping (Game, Int) throws -> Void = { $0.scriptAnswer($1) }) throws {
        let play = Driver(game: game, capture: capture, press: press, answer: answer)
        try play.run()
    }

    private final class Driver {
        let game: Game
        let capture: (String, Game) -> Void
        let press: (String) throws -> Void
        let answer: (Game, Int) throws -> Void
        let size = CGSize(width: 960, height: 600)
        var dialogueCount = 0
        var lineCount = 0
        var stage = 0
        var firstWords = [String]()

        init(game: Game, capture: @escaping (String, Game) -> Void,
             press: @escaping (String) throws -> Void,
             answer: @escaping (Game, Int) throws -> Void) {
            self.game = game
            self.capture = capture
            self.press = press
            self.answer = answer
        }

        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(message: message) }
        }

        func frame(_ name: String) {
            stage += 1
            capture(String(format: "%02d_%@", stage, name), game)
        }

        func log(_ text: String) { print("playthrough: " + text) }

        /// A modal line must be recorded before it is explicitly acknowledged, as by a player.
        func acknowledgeTownMessage() {
            if let line = game.portMessageText, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                log("town message: " + line.replacingOccurrences(of: "\n", with: " / "))
                game.dismissTownMessage()
            }
        }

        /// Exercise the same scenario answers as the UI; never write a story flag directly.
        @discardableResult
        func readDialogue(_ context: String, menuChoice: Int = 0, captureFirst: Bool = true) throws -> Int {
            var count = 0
            while let session = game.session, let prompt = session.prompt {
                try require(count < 600, "\(context): dialogue did not end after 600 answers")
                guard let run = session.run else { throw Failure(message: "\(context): prompt without a script run") }
                let words = run.windows.filter { $0.id != 3 }
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if case .next = prompt {
                    try require(!words.isEmpty || run.picture != nil, "\(context): Continue prompt has no visible words or picture")
                }
                if count == 0 && captureFirst { frame(context + "_dialogue") }
                for word in words {
                    lineCount += 1
                    log("dialogue [\(context) \(count + 1)]: " + word.replacingOccurrences(of: "\n", with: " / "))
                    if firstWords.count < 8 { firstWords.append(word) }
                }
                switch prompt {
                case .next: try answer(game, 0)
                case .menu(let choices):
                    try require(!choices.isEmpty, "\(context): empty choice menu")
                    let choice = min(menuChoice, choices.count - 1)
                    log("choice: " + choices[choice])
                    try answer(game, choice)
                case .yesNo:
                    log("answer: 예")
                    try answer(game, 1)
                case .duel:
                    throw Failure(message: "\(context): unexpected duel; do not invent a winning result")
                case .ending:
                    throw Failure(message: "\(context): unexpected ending during the first voyage")
                }
                count += 1
                dialogueCount += 1
            }
            try require(game.session == nil, "\(context): script session is still blocking without a prompt")
            return count
        }

        func visit(_ service: HarborPanel, context: String, menuChoice: Int = 0, mustOpen: Bool = false) throws {
            acknowledgeTownMessage()
            try require(game.question == nil, "\(context): another confirmation is blocking the visit")
            try require(service.isOpen(tick: game.status.tick), "\(context): service is closed at tick \(game.status.tick)")
            guard let port = game.harbor, let map = game.world.town(port.id) else {
                throw Failure(message: "\(context): no town map")
            }
            try require(map.doors[service.rawValue] != nil, "\(context): no real doorway for \(service.title)")
            try TownWalkDriver.enter(service, game: game, size: size, press: press)
            if game.session != nil {
                try require(game.buildingScene == service, "\(context): entry dialogue is missing its interior")
                try require(game.panel == nil, "\(context): service opened before the entry script finished")
            }
            _ = try readDialogue(context, menuChoice: menuChoice)
            try require(game.buildingScene == game.panel || game.portMessageText != nil, "\(context): finished entry left a stale interior")
            // An entry script may legitimately send the hero back outside; callers distinguish it.
            if mustOpen { try require(game.panel == service, "\(context): \(service.title) did not open after its dialogue") }
            log("visited \(service.title); date \(game.dateText) tick \(game.status.tick); panel \(String(describing: game.panel))")
        }

        /// The inn UI's two-hour action. No direct clock assignment or invisible time jump.
        func waitTwoHours() throws {
            try require(game.panel == .inn && game.session == nil, "Two-hour wait is only available inside the inn")
            acknowledgeTownMessage()
            game.act { $0.passTime(ticks: 6, in: game.world) }
            log("여관에서 두 시간 보내기 → tick \(game.status.tick), \(game.dateText)")
        }

        func run() throws {
            game.startNewGame(hero: 0)
            try require(game.harbor?.name == "리스본", "Joan did not start in Lisbon")
            try require(game.status.ships.isEmpty && game.status.gold == 0, "New game was replaced with a post-prologue fixture")
            frame("new_game")
            try walkToTownConversation()

            let beforeFather = dialogueCount
            try visit(.residence, context: "father")
            try require(dialogueCount > beforeFather, "Father's dialogue never appeared")
            try require(firstWords.contains { $0.contains("아버님") }, "Expected father's dialogue text was not present")
            try require(game.status.officers.contains { $0.person == 69 }, "Rocco did not join through the father's story")
            try require(!game.status.orders.isEmpty, "The father did not order the first ship")

            try visit(.tavern, context: "carlotta")
            try require(game.status.gold >= 1000, "Carlotta did not give the voyage funds")
            try visit(.shipyard, context: "first_ship")
            try require(game.status.ships.count == 1 && game.status.ships[0].name == "헤르메스Ⅱ세", "Shipyard did not deliver the Hermes II")
            try require(game.status.orders.isEmpty, "Delivered ship remains in the construction queue")
            frame("ship_received")

            // The story specifies a 22:00 farewell. Reach evening through real inn actions;
            // repeated residence visits then naturally cross 22:00 through their entry time.
            try visit(.inn, context: "inn_evening", mustOpen: true)
            var waits = 0
            while !(60...65).contains(game.status.tick) {
                try require(waits < 16, "Could not reach the evening through two-hour inn stays")
                try waitTwoHours()
                waits += 1
            }
            var farewells = 0
            while !game.status.items.contains(0x34) && farewells < 4 {
                try visit(.residence, context: "mother_\(farewells + 1)")
                farewells += 1
            }
            try require(game.status.items.contains(0x34), "The mother's farewell did not award the silver hair ornament")

            // The priest and his optional funding are reached through the real church menu.
            // Midnight may have passed; the church opens at 04:00, so rest at the inn if needed.
            if !HarborPanel.church.isOpen(tick: game.status.tick) {
                try visit(.inn, context: "inn_before_church", mustOpen: true)
                while !HarborPanel.church.isOpen(tick: game.status.tick) { try waitTwoHours() }
            }
            try visit(.church, context: "enrico")
            try require(game.status.officers.contains { $0.person == 70 }, "Enrico did not join through the church story")
            if !HarborPanel.church.isOpen(tick: game.status.tick) {
                try visit(.inn, context: "inn_before_priest", mustOpen: true)
                while !HarborPanel.church.isOpen(tick: game.status.tick) { try waitTwoHours() }
            }
            try visit(.church, context: "priest_funds", menuChoice: 0)
            try require(game.status.gold >= 2000, "The priest's accepted funding did not arrive")

            try visit(.harbor, context: "rocco_lesson", menuChoice: 1)
            try require(game.status.officer(holding: .firstMate)?.person == 69, "Rocco's lesson did not appoint the first mate")
            try require(game.status.officer(holding: .bookkeeper)?.person == 70, "Rocco's lesson did not appoint the bookkeeper")
            acknowledgeTownMessage()

            if !HarborPanel.tavern.isOpen(tick: game.status.tick) {
                try visit(.inn, context: "inn_before_hiring", mustOpen: true)
                while !HarborPanel.tavern.isOpen(tick: game.status.tick) { try waitTwoHours() }
            }
            try visit(.tavern, context: "hire_crew", mustOpen: true)
            try require(game.treat(bottles: 4), "Tavern drinks could not be purchased with real funds")
            acknowledgeTownMessage()
            guard let tavern = game.tavern else { throw Failure(message: "Tavern vanished before crew hiring") }
            let crew = min(15, game.status.hireable(at: tavern))
            try require(crew >= 10, "Not enough real tavern volunteers/funds for the first voyage")
            try require(game.hire(crew), "Crew hiring failed")
            try require(game.status.crew == crew, "Hired crew did not board the ship")
            frame("crew_hired")

            try visit(.harbor, context: "provisions", mustOpen: true)
            acknowledgeTownMessage()
            try require(game.buy(.water, barrels: 20), "Could not load 20 barrels of water")
            try require(game.buy(.food, barrels: 20), "Could not buy 20 barrels of food with the voyage funds")
            try require(game.status.water >= 200 && game.status.food >= 200, "Purchased supplies missing from the ship")
            try require(game.status.departureCheck().ok, "Properly hired and supplied ship fails departure check")
            frame("provisioned")

            // The departure prompt is accepted the same way as the SwiftUI alert button.
            game.depart()
            guard let confirmation = game.question else { throw Failure(message: "Departure confirmation was not presented") }
            log("confirmation: " + confirmation.text.replacingOccurrences(of: "\n", with: " / "))
            game.question = nil
            confirmation.action()
            _ = try readDialogue("departure")
            acknowledgeTownMessage()
            try require(game.harbor == nil && game.panel == nil, "Accepting departure left the hero inside the port")

            let home = game.world.ports.first { $0.name == "리스본" }!
            guard let berth = game.world.berth(of: home) else { throw Failure(message: "Lisbon has no berth") }
            let origin = (x: game.status.x, y: game.status.y)
            game.update(dt: 0, viewSize: size)
            // Chart click 14 tiles west of the departure point; this is a real sea tile off Lisbon.
            let outbound = (x: game.world.wrapX(origin.x - 14), y: origin.y)
            try require(game.world.fleetFits(x: outbound.x, y: outbound.y), "Outbound click does not point to open water")
            clickMap(outbound)
            try require(game.status.waypoint != nil && game.status.sail > 0, "Clicking the sea did not set a sailing course")
            var frames = 0
            while hypot(game.world.deltaX(from: origin.x, to: game.voyage.x), game.voyage.y - origin.y) < 10 {
                try require(frames < 1800, "The first voyage could not move 10 sea tiles within 30 seconds")
                try tick()
                frames += 1
            }
            try require(game.world.nearestPort(x: game.voyage.x, y: game.voyage.y, within: 7)?.id != home.id,
                        "Outbound voyage never left Lisbon's entry radius")
            game.adjustSail(-1)
            frame("first_voyage")
            log("sailed from (\(origin.x),\(origin.y)) to (\(game.status.x),\(game.status.y)), \(game.status.daysAtSea) days at sea")

            // Stay at sea through the first and third daily story triggers, using the
            // player's real anchor command. Supplies, weather and NPC fleets keep running.
            let waterBefore = game.status.water, foodBefore = game.status.food
            log(game.toggleAnchor())
            try require(game.status.anchored, "The anchor command did not anchor the ship")
            frames = 0
            var firstDayObserved = false
            while game.status.daysAtSea < 3 {
                try require(frames < 5400, "Three game days at anchor did not elapse within 90 seconds")
                try tick()
                frames += 1
                if game.status.daysAtSea >= 1 && !firstDayObserved {
                    firstDayObserved = true
                    log("first day at sea: story \(game.status.memory[ScriptContext.hero.base]).\(game.status.memory[ScriptContext.hero.base + 1])")
                    frame("first_day_at_sea")
                }
            }
            try require(firstDayObserved, "The first-day story boundary was not observed")
            try require(game.status.officers.contains { $0.person == 71 }, "Domingo did not join through the real third-day sea dialogue")
            try require(game.status.memory[ScriptContext.hero.base] == 1, "The third-day story did not advance to chapter 1")
            try require(game.status.water < waterBefore && game.status.food < foodBefore, "Three days at sea did not consume the purchased supplies")
            frame("third_day_domingo")
            log("third day: Domingo joined, chapter 1; water \(waterBefore)→\(game.status.water), food \(foodBefore)→\(game.status.food)")

            clickMap(berth)
            try require(!game.status.anchored, "Setting the return course did not weigh anchor")
            frames = 0
            while game.dockable?.id != home.id {
                try require(frames < 2400, "The return course never reached Lisbon's real entry radius")
                try tick()
                frames += 1
            }
            game.dock()
            try require(game.harbor?.id == home.id, "Return-key/entry action did not dock in Lisbon")
            try require(game.status.waypoint == nil && game.status.route.isEmpty, "Docking left an active sailing route")
            frame("returned_to_lisbon")
            log("PASS — new game → father → funds → ship → mother → Enrico → officers → hired crew → paid supplies → departure confirmation → sea movement → 3 days at anchor → Domingo/chapter 1 → return to Lisbon; \(dialogueCount) prompts / \(lineCount) text windows; no teleports, injected resources, direct clock assignments or save-slot writes")
        }

        /// Reach an actual resident through keyboard movement. The search only plans inputs;
        /// it never places the hero or freezes the moving residents.
        func walkToTownConversation() throws {
            guard let harbor = game.harbor, let map = game.world.town(harbor.id) else {
                throw Failure(message: "No town for the resident conversation test")
            }
            let dirs = [(0, -1, KeyCode.w, "w"), (1, 0, KeyCode.d, "d"), (0, 1, KeyCode.s, "s"), (-1, 0, KeyCode.a, "a")]
            func nextInput() -> Int? {
                let hero = game.status.townHero, folk = game.status.townsfolk
                var queue: [(x: Int, y: Int, first: Int?)] = [(hero.x, hero.y, nil)]
                var seen: Set<Int> = [hero.y * 96 + hero.x]
                var index = 0
                while index < queue.count {
                    let here = queue[index]
                    index += 1
                    for (direction, delta) in dirs.enumerated() {
                        let x = here.x + delta.0, y = here.y + delta.1
                        guard (0..<94).contains(x), (0..<94).contains(y), seen.insert(y * 96 + x).inserted else { continue }
                        // A collision is resolved before the terrain step by the production rule.
                        if folk.contains(where: { abs($0.x - x) <= 1 && abs($0.y - y) <= 1 }) { return here.first ?? direction }
                        guard map.walkable(x, y), !map.doors.values.contains(where: { $0.x == x && $0.y == y }) else { continue }
                        queue.append((x, y, here.first ?? direction))
                    }
                }
                return nil
            }
            var steps = 0
            while game.portMessageText == nil {
                try require(steps < 400, "Walking could not reach a town conversation in 400 real key steps")
                guard let direction = nextInput() else { throw Failure(message: "No walkable route to an actual resident") }
                let input = dirs[direction]
                func event(_ type: NSEvent.EventType) -> NSEvent {
                    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: input.3,
                                     charactersIgnoringModifiers: input.3, isARepeat: false, keyCode: input.2)!
                }
                try require(game.handleKey(event(.keyDown)), "Town did not accept the movement key")
                game.update(dt: game.townStepTime + 0.001, viewSize: size)
                _ = game.handleKey(event(.keyUp))
                steps += 1
                try require(game.panel == nil && game.session == nil, "Resident route unexpectedly entered a building")
            }
            guard let message = game.portMessageText else { throw Failure(message: "Resident message is missing") }
            try require(!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Resident collision produced an empty message")
            log("resident reached after \(steps) key steps: " + message.replacingOccurrences(of: "\n", with: " / "))
            frame("resident_dialogue")
            let position = game.status.townHero
            for _ in 0..<60 { game.update(dt: 1.0 / 60, viewSize: size) }
            try require(game.portMessageText == message, "Resident dialogue disappeared before acknowledgement")
            try require(game.status.townHero == position, "The player moved while reading resident dialogue")
            game.dismissTownMessage()
            try require(game.portMessageText == nil, "Acknowledging resident dialogue did not close it")
            frame("resident_dialogue_closed")
        }

        func clickMap(_ target: (x: Double, y: Double)) {
            let point = CGPoint(x: size.width / 2 + game.world.deltaX(from: game.camera.x, to: target.x) * game.zoom,
                                y: size.height / 2 + (target.y - game.camera.y) * game.zoom)
            game.click(point)
        }

        func tick() throws {
            game.update(dt: 1.0 / 60, viewSize: size)
            if game.session != nil { _ = try readDialogue("at_sea", captureFirst: true) }
            try require(game.status.gameOver == nil, "First voyage ended: \(game.status.gameOver ?? "")")
            try require(game.encounter == nil && game.battle == nil, "Unexpected battle interrupted this smoke route; no forced escape or victory was applied")
            if let pages = game.seaEvent {
                throw Failure(message: "Sea event needs manual play during smoke route: \(pages.joined(separator: " / "))")
            }
        }
    }
}
