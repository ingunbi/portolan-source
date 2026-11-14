#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation
import PortolanCore

/// A combat playthrough from Catalina's actual opening chapter. Her story supplies the
/// galleon and ammunition; neither this driver nor the native UI harness grants resources.
/// The planner only reads the board. Every battle order presses a real SwiftUI control.
enum BattlePlaythrough {
    static func run(game: Game, capture: @escaping (String, Game) -> Void,
                    press: @escaping (String) throws -> Void,
                    setValue: @escaping (String, Double) throws -> Void,
                    answer: @escaping (Game, Int) throws -> Void) throws {
        try Driver(game: game, capture: capture, press: press, setValue: setValue, answer: answer).run()
    }

    private final class Driver {
        let game: Game
        let capture: (String, Game) -> Void
        let press: (String) throws -> Void
        let answer: (Game, Int) throws -> Void
        let setValue: (String, Double) throws -> Void
        let size = CGSize(width: 960, height: 600)
        let captureRequired = ProcessInfo.processInfo.environment["PORTOLAN_BATTLE_MODE"] == "capture"
        var fightToResult: Bool { captureRequired || ProcessInfo.processInfo.environment["PORTOLAN_BATTLE_MODE"] == "fight" }
        var boardings = 0
        var boardingWaits = 0
        var dialogueCount = 0
        var turns = 0
        var moves = 0
        var rotations = 0
        var volleys = 0
        var duelExchanges = 0
        var stage = 0

        init(game: Game, capture: @escaping (String, Game) -> Void,
             press: @escaping (String) throws -> Void, setValue: @escaping (String, Double) throws -> Void,
             answer: @escaping (Game, Int) throws -> Void) {
            self.game = game; self.capture = capture; self.press = press; self.answer = answer; self.setValue = setValue
        }

        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Playthrough.Failure(message: "battle: " + message) }
        }

        func log(_ line: String) { print("battle-playthrough: " + line) }
        func frame(_ name: String) {
            stage += 1
            capture(String(format: "battle_%02d_%@", stage, name), game)
        }

        func readDialogue(_ context: String) throws {
            var count = 0
            while let s = game.session, let prompt = s.prompt {
                try require(count < 600, "\(context): dialogue loop")
                guard let run = s.run else { throw Playthrough.Failure(message: "Dialogue prompt has no script") }
                let words = run.windows.filter { $0.id != 3 }.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if case .next = prompt { try require(!words.isEmpty || run.picture != nil, "\(context): blank dialogue") }
                if count == 0 { frame(context + "_dialogue") }
                for text in words { log("dialogue [\(context)]: " + text.replacingOccurrences(of: "\n", with: " / ")) }
                switch prompt {
                case .next: try answer(game, 0)
                case .menu(let choices):
                    try require(!choices.isEmpty, "empty choice menu")
                    log("choice: " + choices[0]); try answer(game, 0)
                case .yesNo: try answer(game, 1)
                case .duel: throw Playthrough.Failure(message: "Unexpected scripted duel in Catalina combat route")
                case .ending: throw Playthrough.Failure(message: "Unexpected ending in Catalina combat route")
                }
                count += 1; dialogueCount += 1
            }
            try require(game.session == nil, "\(context): blocked script without a prompt")
        }

        func dismissMessage() throws {
            if let line = game.portMessageText {
                log("town: " + line.replacingOccurrences(of: "\n", with: " / "))
                // This is the production acknowledgement also used by Return/Space.
                try press("portolan.portMessage.dismiss")
            }
        }

        func visit(_ service: HarborPanel, _ context: String) throws {
            try dismissMessage()
            if game.panel != nil { try press("portolan.building.leave") }
            try require(service.isOpen(tick: game.status.tick), "\(service.title) closed before \(context), tick \(game.status.tick)")
            try TownWalkDriver.enter(service, game: game, size: size, press: press)
            try readDialogue(context)
            try dismissMessage()
            log("visited \(service.title): chapter \(game.status.memory[ScriptContext.hero.base]).\(game.status.memory[ScriptContext.hero.base + 1]); ships \(game.status.ships.map(\.name)); tick \(game.status.tick)")
        }

        func equipSabre() throws {
            try dismissMessage()
            if game.panel != nil { try press("portolan.building.leave") }
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 0,
                                         windowNumber: 0, context: nil, characters: "\u{F707}",
                                         charactersIgnoringModifiers: "\u{F707}", isARepeat: false, keyCode: 118)!
            try require(game.handleKey(event), "F4 did not open the navigation menu")
            try require(game.tabMenu == 3, "F4 opened the wrong command menu")
            try press("portolan.command.entry.3.4")
            try require(game.command == .items, "The actual Items menu row did not open the inventory")
            if !game.status.item(15).equipped { try press("portolan.item.equip.15") }
            try require(game.status.item(15).equipped, "The sabre Equip button did not equip the story reward")
            frame("sabre_equipped")
            try press("portolan.command.close")
            try require(game.command == nil, "Closing inventory left the command panel open")
            log("received the optional story sabre and equipped it through F4 → Items → Equip")
        }

        func run() throws {
            game.startNewGame(hero: 1)
            try require(game.harbor?.name == "세빌리아", "Catalina did not start in Seville")
            try require(game.status.ships.isEmpty && game.status.gold == 0, "New game is not an untouched opening")
            frame("new_game")
            try visit(.residence, "commander_news")
            try visit(.residence, "sabre_gift")
            try require(game.status.items.contains(15), "The optional original residence scene did not give the sabre")
            try equipSabre()
            try visit(.tavern, "rumour")
            try visit(.residence, "petition_refused")
            try visit(.tavern, "decision")
            try visit(.harbor, "rebellion")
            try require(game.status.ships.count == 1 && game.status.ships[0].name == "리베리온", "The original prologue did not provide the Rebellion")
            try require(game.status.crew == 120 && game.status.ships[0].guns == 50 && game.status.ships[0].shot == 50,
                        "Story-provided combat ship is not crewed and armed")
            try require(game.status.water > 0 && game.status.food > 0, "The prologue did not provide provisions")
            log("original prologue: \(game.status.ships[0].name), crew \(game.status.crew), guns \(game.status.ships[0].guns), shot \(game.status.ships[0].shot), water \(game.status.water), food \(game.status.food)")
            frame("story_armed_ship")
            if captureRequired { try prepareCapture() }
            if game.harbor != nil {
                if game.panel != .harbor { try visit(.harbor, "departure_office") }
                try press("portolan.harbor.depart")
                try require(game.question != nil, "Departure estimate never appeared")
                try press("portolan.question.yes")
            }
            try readDialogue("departure")
            try require(game.harbor == nil, "Departure left Catalina in port")
            let start = (x: game.status.x, y: game.status.y)
            if captureRequired { try findMerchant() } else { try findEncounter() }
            let travelled = hypot(game.world.deltaX(from: start.x, to: game.status.x), game.status.y - start.y)
            try require(travelled > 2, "Encounter was reached without actually leaving the departure berth")
            log("encounter reached through actual sailing; displacement \(String(format: "%.1f", travelled)) tiles, day \(game.status.daysAtSea)")
            frame("encounter")
            try press("portolan.battle.start")
            try readDialogue("battle_start")
            try require(game.battle != nil, "Starting the encounter did not create a battle")
            frame("battle_board")
            let goldBeforeBattle = game.status.gold
            log(fightToResult ? "mode: fight to the original victory/defeat/sunset result" : "mode: verify a volley, then withdraw through the map edge")
            try fight()
            guard let result = game.battleResult else { throw Playthrough.Failure(message: "Battle ended without a result panel") }
            log("result \(result.code): \(result.lines.joined(separator: " / ")); commands: \(turns) turns, \(moves) moves, \(rotations) rotations, \(volleys) volleys, \(duelExchanges) duel exchanges")
            if captureRequired {
                try require([4, 6].contains(result.code) && boardings > 0 && moves > 0,
                            "Capture route did not win through real movement and boarding: result \(result.code)")
                try require(result.mayTake > 0 && !result.capturable.isEmpty, "Victory left no available prize/captain")
            } else {
                try require(moves > 0 && rotations > 0 && volleys > 0, "Combat did not exercise movement, turning and cannon fire")
            }
            if result.code == 5, let flagship = game.status.ships.first {
                try require(flagship.hull == 0 || flagship.crew == 0, "The lost flagship regained its pre-battle condition during result import")
            }
            frame("result_\(result.code)")
            let shipsBeforePrizes = game.status.ships.count
            var expectedPrizes: [(guns: Int, gunType: Int)] = []
            if [4, 6].contains(result.code) {
                try require(result.gold > 0 && game.status.gold == min(Trade.goldCap, goldBeforeBattle + result.gold),
                            "Victory spoils do not match the actual gold awarded")
                if let item = result.item { try require(game.status.items.contains(item), "Victory item is missing") }
                if let battle = game.battle {
                    for prize in result.capturable.prefix(result.mayTake) {
                        let unit = battle.units[prize], slot = game.status.memory.slot(unit.fleet, unit.slot)
                        expectedPrizes.append((game.status.memory[slot + 6], game.status.memory[slot + 8] & 7))
                        try press("portolan.battle.prize.\(prize)")
                    }
                }
                log("verified victory gold \(result.gold), item \(String(describing: result.item)); selecting \(expectedPrizes.count) captured ships")
                frame("victory_prizes_selected")
            }
            try press("portolan.battle.result.close")
            try readDialogue("battle_end")
            try require(game.battle == nil && game.battleResult == nil && game.encounter == nil && game.status.pendingBattle == nil,
                        "Confirming the result left combat blocking the world")
            try require(game.status.ships.count == shipsBeforePrizes + expectedPrizes.count, "Selected prize ships did not join the fleet")
            for (index, expected) in expectedPrizes.enumerated() {
                let ship = game.status.ships[shipsBeforePrizes + index]
                try require(ship.gunType == expected.gunType && ship.guns == min(ship.gunCapacity, expected.guns),
                            "Captured ship lost its cannon equipment during result confirmation")
            }
            frame("returned_from_battle")
            if captureRequired {
                try require(expectedPrizes.count > 0, "No prize was actually selected")
                try resumeWithPrize()
                return
            }
            if let over = game.status.gameOver {
                try require(fightToResult && [5, 7].contains(result.code), "The withdrawal route lost its flagship: \(over)")
                log("actual defeat: \(over); verified result before game-over presentation")
                frame("game_over")
                try press("portolan.gameover.restart")
                try require(game.title && game.status.gameOver == nil && game.battle == nil,
                            "Game-over restart did not return to the title screen")
                // Let the title's normal 0.9-second entrance finish before its evidence
                // frame; otherwise the successfully reopened menu is still fading in.
                frame("title_after_defeat")
                log("PASS — actual combat defeat \(result.code) → result confirmation → game-over screen → native restart → title; \(volleys) volleys, \(duelExchanges) real duel exchanges; no outcome assignments")
                return
            }
            // The normal ship controls must respond after closing the battle, too.
            game.pressed(KeyCode.up)
            try require(game.status.gameOver == nil, "Returning to sailing caused game over")
            game.update(dt: 1.0 / 60, viewSize: size)
            try require(game.battle == nil && game.encounter == nil, "The resolved encounter immediately reopened")
            log("PASS — untouched Catalina new game → original prologue → armed departure → visible fleet pursuit → actual nearby encounter → native movement/turn/fire/AI → result \(result.code) → sea; \(dialogueCount) dialogue answers; no resource, coordinate or outcome assignments")
        }

        func openFormation(_ row: Int) throws {
            try dismissMessage()
            if game.panel != nil { try press("portolan.building.leave") }
            game.pressed(120) // the normal F2 key path
            try require(game.tabMenu == 1, "F2 did not open formation")
            try press("portolan.command.entry.1.\(row)")
            try require(game.command != nil, "Formation command did not open")
        }

        func shares(ship: Int, sailing: Int) throws {
            for _ in 0..<100 where game.status.ships[ship].sailorShare != sailing {
                let direction = game.status.ships[ship].sailorShare < sailing ? "increase" : "decrease"
                try press("portolan.shares.\(ship).0.\(direction)")
            }
            for _ in 0..<100 where game.status.ships[ship].watchShare > 0 {
                try press("portolan.shares.\(ship).1.decrease")
            }
            try require(game.status.ships[ship].sailorShare == sailing && game.status.ships[ship].watchShare == 0,
                        "Crew-share controls failed")
        }

        func prepareCapture() throws {
            try visit(.market, "sell_story_gold")
            let before = game.status
            guard let lot = before.ships[0].holds.first else { throw Playthrough.Failure(message: "Missing story cargo") }
            try press("portolan.trade.hold.0")
            try setValue("portolan.trade.sell.quantity", Double(lot.amount))
            try press("portolan.trade.sell")
            try require(game.status.gold == before.gold + lot.amount * before.salePrice(of: lot.good, in: game.world),
                        "Story cargo sale did not fund the preparations")
            log("sold original cargo for \(game.status.gold - before.gold) gold")
            try visit(.tavern, "hire_combat_crew")
            for _ in 0..<4 { try press("portolan.tavern.bottles.decrease") }
            for _ in 0..<3 { try press("portolan.tavern.bottles.increaseTen") }
            try press("portolan.tavern.treat")
            try dismissMessage()
            try require(game.tavern.map { game.status.hireable(at: $0) >= 60 } == true, "Could not recruit enough volunteers")
            try press("portolan.tavern.hire.maximum")
            try press("portolan.tavern.hire")
            try require(game.status.crew == 180, "Maximum hire did not fill Rebellion's 180 berths")
            try openFormation(3)
            try shares(ship: 0, sailing: 25)
            frame("crew_prepared")
            try press("portolan.command.close")
            try visit(.harbor, "provision_combat_voyage")
            for kind in 0..<2 {
                for _ in 0..<15 { try press("portolan.supply.\(kind).quantity.increaseTen") }
                try press("portolan.supply.\(kind).buy")
            }
            try require(game.status.water == 2500 && game.status.food == 2500, "Supplies were not purchased normally")
            frame("prepared_for_capture")
            log("prepared with earned money: crew \(game.status.crew), sailing25/watch0/deck75, water \(game.status.water), food \(game.status.food), gold \(game.status.gold)")
        }

        func findMerchant() throws {
            game.update(dt: 0, viewSize: size)
            let lisbon = game.world.ports.first { $0.name == "리스본" }!
            guard let berth = game.world.berth(of: lisbon) else { throw Playthrough.Failure(message: "Lisbon has no sea berth") }
            clickMap(berth)
            try require(game.status.waypoint != nil, "Normal map click could not set Lisbon course")
            func merchant(_ f: Int) -> Bool { f / 10 != 4 && (1...4).contains(f % 10) }
            var day = -1
            for n in 0..<12000 {
                if game.encounter != nil { return }
                let v = game.status
                if v.daysAtSea != day {
                    day = v.daysAtSea
                    log("merchant search day \(day): position \(v.x),\(v.y), crew \(v.crew), food \(v.food), visible \(v.fleetsInSight())")
                }
                try require(v.food > 2 * v.dailyFood && v.water > 2 * v.dailyWater, "Capture patrol needs to replenish stores")
                if (15..<60).contains(v.tick), let f = v.fleetsNearby().first(where: merchant) {
                    log("selected visible merchant fleet \(f), admiral \(v.memory.person(v.memory.fb(f, FleetField.admiral)).name)")
                    frame("merchant_in_range")
                    try press("portolan.fleet.attack.\(f)")
                    game.update(dt: 0, viewSize: size)
                    try require(game.encounter != nil, "Visible merchant attack did not open encounter")
                    return
                }
                if n % 80 == 0, let f = v.fleetsInSight().filter(merchant).min(by: { a, b in
                    let pa = v.memory.fleetAt(a), pb = v.memory.fleetAt(b)
                    return hypot(Double(pa.x) - v.x, Double(pa.y) - v.y) < hypot(Double(pb.x) - v.x, Double(pb.y) - v.y)
                }) {
                    let p = v.memory.fleetAt(f)
                    clickMap((Double(p.x) + 0.5, Double(p.y) + 0.5))
                    log("pursuing visible merchant \(f) using ordinary chart course")
                }
                if game.status.waypoint == nil && !game.status.anchored {
                    // Arrival furls sails and pauses the remaster clock. Use the actual
                    // anchor command to wait for passing traffic while days advance.
                    game.pressed(118)
                    try require(game.tabMenu == 3, "F4 did not open the anchor command")
                    try press("portolan.command.entry.3.1")
                    try require(game.status.anchored, "Anchor button failed while waiting for a visible merchant")
                    log("anchored at the completed course to watch for passing merchants")
                }
                try tick()
            }
            throw Playthrough.Failure(message: "No visible merchant encountered within normal voyage")
        }

        func resumeWithPrize() throws {
            let before = game.status
            try require(before.ships.count == 2 && before.ships[1].crew == 0, "Expected the boarded enemy flagship with zero crew")
            try require(before.officers.first?.post == nil, "Prize captain retained an incompatible officer post")
            try openFormation(2)
            for _ in 0..<5 { try press("portolan.crew.0.delta.-10") }
            for _ in 0..<5 { try press("portolan.crew.1.delta.10") }
            try require(game.status.crew == before.crew && game.status.ships[1].crew == 50, "Crew redistribution created/lost sailors")
            frame("prize_crew_assigned")
            try press("portolan.command.close")
            try require(game.question == nil, "Crew pool was left behind")
            try openFormation(3)
            for i in game.status.ships.indices { try shares(ship: i, sailing: 50) }
            try press("portolan.command.close")
            try openFormation(5)
            // Original 0x1F1FF transfers whole barrels and drops each ship's
            // fractional barrel. Verify that exact rule, not invented conservation.
            let stores = (game.status.ships.reduce(0) { $0 + $1.water / 10 * 10 },
                          game.status.ships.reduce(0) { $0 + $1.food / 10 * 10 })
            for kind in 0..<2 {
                try press(kind == 0 ? "portolan.cargo.kind.water" : "portolan.cargo.kind.food")
                for _ in 0..<4 { try press("portolan.cargo.quantity.increaseTen") }
                try press("portolan.cargo.transfer")
            }
            try require(game.status.water == stores.0 && game.status.food == stores.1 && game.status.ships[1].water == 400 && game.status.ships[1].food == 400,
                        "Cargo distribution did not follow the original whole-barrel totals or left the prize unsupplied: water \(game.status.ships.map(\.water)), food \(game.status.ships.map(\.food))")
            frame("prize_supplied")
            try press("portolan.command.close")
            let lisbon = game.world.ports.first { $0.name == "리스본" }!
            let berth = game.world.berth(of: lisbon)!
            let origin = (game.status.x, game.status.y)
            clickMap(berth)
            try require(game.status.waypoint != nil, "The normal map-click course failed after capture")
            var frames = 0
            while game.dockable?.id != lisbon.id || hypot(game.world.deltaX(from: origin.0, to: game.status.x), game.status.y - origin.1) < 3 {
                try require(frames < 12000, "Prize fleet could not reach Lisbon")
                try tick()
                try require(game.encounter == nil && game.battle == nil, "Resolved battle reappeared or a new encounter interrupted return")
                frames += 1
            }
            let distance = hypot(game.world.deltaX(from: origin.0, to: game.status.x), game.status.y - origin.1)
            try require(distance > 2, "Prize fleet did not actually sail")
            game.pressed(KeyCode.returnKey)
            try readDialogue("prize_return_lisbon")
            try require(game.harbor?.id == lisbon.id && game.status.ships.count == 2, "Actual Return key failed to dock both ships")
            frame("prize_fleet_lisbon")
            log("PASS — native new-game prologue → earned cargo sale → paid hire/provisions → visible merchant pursuit → \(boardings) boarding attacks → victory → actual prize toggle/confirm → captain/50 crew/400 water/400 food → \(frames) sailing frames, \(String(format: "%.1f", distance)) tiles → Lisbon dock; ships \(game.status.ships.map(\.name)), crew \(game.status.ships.map(\.crew)); no resource/coordinate/outcome assignments")
        }

        func clickMap(_ target: (x: Double, y: Double)) {
            let point = CGPoint(x: size.width / 2 + game.world.deltaX(from: game.camera.x, to: target.x) * game.zoom,
                                y: size.height / 2 + (target.y - game.camera.y) * game.zoom)
            game.click(point)
        }

        func tick() throws {
            game.update(dt: 1.0 / 60, viewSize: size)
            if game.session != nil { try readDialogue("at_sea") }
            while let pages = game.seaEvent {
                log("sea event: " + (pages.first ?? ""))
                try press("portolan.sea-event.continue")
            }
            try require(game.status.gameOver == nil, "Voyage ended: \(game.status.gameOver ?? "")")
        }

        func findEncounter() throws {
            // Select a real, visible sea destination. Production Game.click plans the
            // coastal route; the test never writes route points or ship coordinates.
            game.update(dt: 0, viewSize: size)
            let origin = (x: game.status.x, y: game.status.y)
            var lastLogDay = -1
            var checkpoint = origin
            for n in 0..<1200 {
                if game.encounter != nil { return }
                let v = game.status
                if v.daysAtSea != lastLogDay {
                    lastLogDay = v.daysAtSea
                    log("search day \(v.daysAtSea): (\(String(format: "%.2f", v.x)),\(String(format: "%.2f", v.y))), food \(v.food), visible \(v.fleetsInSight()), speed \(v.speedUnits), heading \(v.heading), course \(String(describing: v.waypoint))")
                }
                let travelled = hypot(game.world.deltaX(from: origin.x, to: v.x), v.y - origin.y)
                if n > 0 && n % 120 == 0 {
                    let progress = hypot(game.world.deltaX(from: checkpoint.x, to: v.x), v.y - checkpoint.y)
                    try require(progress > 0.25, "Ship made no progress in 120 sailing frames: position (\(v.x),\(v.y)), sail \(v.sail), speed \(v.speedUnits), course \(String(describing: v.waypoint))")
                    checkpoint = (v.x, v.y)
                }
                try require(v.food > v.dailyWater && v.water > v.dailyWater, "Patrol must return for provisions before starvation")
                if travelled > 2, (15..<60).contains(v.tick), let f = v.fleetsNearby().first {
                    log("actual nearby fleet \(f), admiral \(v.memory.person(v.memory.fb(f, FleetField.admiral)).name)")
                    frame("nearby_fleet")
                    try press("portolan.fleet.attack.\(f)")
                    game.update(dt: 0, viewSize: size)
                    try require(game.encounter != nil, "Nearby fleet attack produced no encounter")
                    return
                }
                if v.waypoint == nil || n % 120 == 0 {
                    var target: (x: Double, y: Double)?
                    let visible = v.fleetsInSight().sorted { a, b in
                        let pa = v.memory.fleetAt(a), pb = v.memory.fleetAt(b)
                        return hypot(Double(pa.x) - v.x, Double(pa.y) - v.y) < hypot(Double(pb.x) - v.x, Double(pb.y) - v.y)
                    }
                    for f in visible {
                        let p = v.memory.fleetAt(f)
                        let point = (x: Double(p.x) + 0.5, y: Double(p.y) + 0.5)
                        if let path = game.world.seaPath(from: (v.x, v.y), to: point), !path.isEmpty {
                            target = point; log("following visible fleet \(f), sea destination \(point)")
                            break
                        }
                    }
                    if target == nil && v.waypoint == nil {
                        for delta in [(-12.0, 8.0), (-12.0, -8.0), (0.0, -16.0), (0.0, 16.0)] {
                            let point = (x: game.world.wrapX(v.x + delta.0), y: v.y + delta.1)
                            if let path = game.world.seaPath(from: (v.x, v.y), to: point), !path.isEmpty {
                                target = point; break
                            }
                        }
                    }
                    if let target {
                        clickMap(target)
                        try require(game.status.waypoint != nil, "Chart click did not set the selected sea course")
                    } else {
                        try require(v.waypoint != nil, "No navigable local sea course from the departure berth")
                    }
                }
                try tick()
            }
            throw Playthrough.Failure(message: "No real nearby encounter reached in the bounded sea patrol")
        }

        func fight() throws {
            var previousAI: [String] = []
            var aiActed = false
            for _ in 0..<2000 {
                guard let b = game.battle, b.phase != .over else { break }
                if b.phase == .duel, let duel = b.duel {
                    if duel.turn == 0 { frame("enemy_challenge"); log("Enemy initiated a real boarding duel") }
                    // Play every exchange through the actual attack/defence button. The
                    // original duel rules determine the result; no meter is assigned.
                    let move = duel.turn % 3
                    try press("portolan.duel.move.\(move)")
                    duelExchanges += 1
                    log("duel exchange \(duel.turn + 1): move \(move), meter \(duel.meter) → \(game.battle?.duel?.meter.description ?? "finished")")
                    try require(game.battle?.phase != .duel || game.battle?.duel?.turn != duel.turn,
                                "Duel move button did not advance the exchange")
                    continue
                }
                try require(b.phase == .command, "Unknown battle phase")
                guard let a = b.active else { throw Playthrough.Failure(message: "Command phase has no active flagship") }
                let v = game.status, u = b.units[a]
                let ai = b.units.indices.filter { b.units[$0].owner != 0x80 }.map { "\(b.units[$0].x),\(b.units[$0].y),\(b.units[$0].heading),\(b.units[$0].shot),\(b.crew($0, v))" }
                if !previousAI.isEmpty && ai != previousAI { aiActed = true }
                previousAI = ai
                let enemies = b.units.indices.filter { b.units[$0].side & 1 != u.side & 1 && b.alive($0, v) }
                try require(!enemies.isEmpty, "Battle stayed open without enemies")
                // Verify in-place turning through its real control before any movement.
                if !captureRequired && rotations == 0 {
                    try press("portolan.battle.turn.right")
                    try require(game.battle?.units[a].heading == (u.heading + 1) % 6 && game.battle?.moved == true,
                                "Native right-turn button did not rotate the flagship")
                    rotations += 1
                    try pass()
                    continue
                }
                if captureRequired {
                    guard let target = enemies.first(where: { b.isFlagship($0) && b.units[$0].side < 2 }) else {
                        throw Playthrough.Failure(message: "No visible main enemy flagship")
                    }
                    let t = b.units[target]
                    if b.canBoard(a, target) {
                        // Hold alongside the intact flagship so its boarding attack is
                        // answered before it gets a new turn to retreat after casualties.
                        if b.crew(target, v) > 50 && boardingWaits < 3 {
                            boardingWaits += 1
                            log("holding alongside for a boarding counterattack; enemy crew \(b.crew(target, v))")
                            try pass()
                            continue
                        }
                        let beforeCrew = b.crew(target, v), offered = b.duelOffered(target)
                        try press("portolan.battle.hex.\(t.x).\(t.y)")
                        if offered { frame("boarding_choice"); try press("portolan.battle.board") }
                        boardings += 1; turns += 1
                        try require(game.battle.map { $0.crew(target, game.status) < beforeCrew } == true,
                                    "Actual boarding button did not reduce the enemy crew")
                        log("boarding \(boardings): enemy crew \(beforeCrew) → \(game.battle!.crew(target, game.status)); own \(game.status.crew)")
                        frame("boarding_\(boardings)")
                        continue
                    }
                    if !b.moved {
                        let reach = b.reach(a, v).filter { !$0.value.path.isEmpty }
                        if let best = reach.sorted(by: { $0.key < $1.key }).max(by: {
                            -Battle.distance($0.key % Battle.width, $0.key / Battle.width, t.x, t.y)
                                < -Battle.distance($1.key % Battle.width, $1.key / Battle.width, t.x, t.y)
                        }) {
                            let x = best.key % Battle.width, y = best.key / Battle.width
                            try press("portolan.battle.hex.\(x).\(y)")
                            try require(game.battle?.units[a].x == x && game.battle?.units[a].y == y,
                                        "Boarding approach did not reach the selected legal hex")
                            moves += 1
                            if moves == 1 { frame("boarding_approach") }
                            continue
                        }
                    }
                    try pass()
                    continue
                }
                // A broadside is preferred to boarding: it verifies ammunition and actual
                // hull damage without pretending to have won a duel.
                let fireTargets = b.targets(v).filter { b.canFire(a, at: $0) }.sorted {
                    if b.isFlagship($0) != b.isFlagship($1) { return b.isFlagship($0) }
                    return b.hull($0, v) < b.hull($1, v)
                }
                if fightToResult || volleys == 0, let target = fireTargets.first {
                    let beforeShot = u.shot, beforeHull = b.hull(target, v), targetUnit = b.units[target]
                    try press("portolan.battle.hex.\(targetUnit.x).\(targetUnit.y)")
                    try require(game.battle?.units[a].shot == beforeShot - 1, "Cannon button did not spend a shot")
                    if let after = game.battle {
                        try require(after.hull(target, game.status) < beforeHull, "Cannon volley did not damage the selected ship")
                    }
                    volleys += 1; turns += 1
                    log("volley \(volleys): \(b.shipName(a, v)) → \(b.shipName(target, v)); hull \(beforeHull) → \(game.battle.map { $0.hull(target, game.status) } ?? 0)")
                    if volleys == 1 { frame("first_cannon_hit") }
                    continue
                }
                if !fightToResult && volleys > 0 && b.canLeave(v) {
                    try press("portolan.battle.leave")
                    turns += 1
                    log("withdrew through the actual edge-of-map command")
                    continue
                }
                if !b.moved {
                    let reachable = b.reach(a, v).filter { !$0.value.path.isEmpty }
                    // After the first verified broadside, disengage through the closest
                    // field edge. Before it, seek a legal broadside position.
                    func distanceToEnemy(_ x: Int, _ y: Int) -> Int {
                        enemies.map { Battle.distance(x, y, b.units[$0].x, b.units[$0].y) }.min() ?? 100
                    }
                    let exitDistances = distancesToOpenEdge(b)
                    func score(_ key: Int, _ heading: Int) -> Int {
                        let x = key % Battle.width, y = key / Battle.width
                        if !fightToResult && volleys > 0 {
                            let edge = exitDistances[key] ?? 1000
                            return -edge * 100 + min(8, distanceToEnemy(x, y))
                        }
                        let firing = enemies.filter { b.canFire(a, at: $0, fromX: x, y: y, heading: heading) }
                        if !firing.isEmpty {
                            let flagship = firing.contains { b.isFlagship($0) }
                            return (flagship ? 20000 : 10000) + min(5, distanceToEnemy(x, y)) * 100
                        }
                        let targetDistance = enemies.filter { !fightToResult || b.isFlagship($0) }
                            .map { Battle.distance(x, y, b.units[$0].x, b.units[$0].y) }.min() ?? distanceToEnemy(x, y)
                        return -abs(targetDistance - max(2, u.range)) * 100
                    }
                    if let move = reachable.sorted(by: { $0.key < $1.key }).max(by: {
                        let l = score($0.key, $0.value.heading), r = score($1.key, $1.value.heading)
                        return l == r ? $0.value.path.count < $1.value.path.count : l < r
                    }) {
                        let x = move.key % Battle.width, y = move.key / Battle.width
                        try press("portolan.battle.hex.\(x).\(y)")
                        try require(game.battle?.units[a].x == x && game.battle?.units[a].y == y && game.battle?.moved == true,
                                    "Native hex button did not sail to the highlighted destination")
                        moves += 1
                        if moves == 1 { frame("first_move") }
                        // Movement does not consume the attack. Inspect the updated board
                        // on the next iteration, so a broadside can follow on the same turn.
                        continue
                    }
                    try press("portolan.battle.turn.left")
                    rotations += 1
                }
                try pass()
            }
            try require(game.battle?.phase == .over && game.battleResult != nil, "Battle never reached a normal result")
            try require(aiActed, "Enemy AI never moved, turned or fired")
        }

        /// Read-only tactical planning over the visible battle terrain. Sailing still
        /// uses the highlighted reachable-cell button, including all heading/wind costs.
        func distancesToOpenEdge(_ b: Battle) -> [Int: Int] {
            var distance: [Int: Int] = [:], queue: [Int] = []
            for y in 0..<Battle.height {
                for x in 0..<Battle.width where x == 0 || y == 0 || x == Battle.width - 1 || y == Battle.height - 1 {
                    let key = y * Battle.width + x
                    if b.map[key] & 0x80 == 0 { distance[key] = 0; queue.append(key) }
                }
            }
            var next = 0
            while next < queue.count {
                let key = queue[next]; next += 1
                for heading in 0..<6 {
                    let p = Battle.neighbour(key % Battle.width, key / Battle.width, heading)
                    guard (0..<Battle.width).contains(p.0), (0..<Battle.height).contains(p.1) else { continue }
                    let other = p.1 * Battle.width + p.0
                    guard distance[other] == nil, b.map[other] & 0x80 == 0 else { continue }
                    distance[other] = distance[key]! + 1; queue.append(other)
                }
            }
            return distance
        }

        func pass() throws {
            let tick = game.status.tick
            try press("portolan.battle.pass")
            turns += 1
            if turns % 5 == 0 { log("turn \(turns), clock \(tick) → \(game.status.tick), hull \(game.status.ships.first?.hull ?? 0)") }
        }
    }
}
