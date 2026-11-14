#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import PortolanCore

/// Fixture-based native UI integration, deliberately separate from campaign playthroughs.
/// A prepared harbor, distinct gold amounts, corrupt bytes, a blocked directory, an ending
/// boundary and a sea-event page are injected. All slot/confirmation/recovery actions use
/// actual visible AX buttons. This is neither an earned campaign nor a VoiceOver test.
enum FoundationPlaythrough {
    struct NativeChecks {
        let sendKey: (UInt16, String, Bool) throws -> Void
        let repeatKey: (UInt16, String) throws -> Void
        let retainPress: (String) throws -> (() -> Void)
        let choose: (String, String) throws -> Void
        let focus: (String) throws -> Void
        let hasEditableFocus: () -> Bool
        let wait: (Double) -> Void
        let assetsFailure: () throws -> Void
    }

    static func run(game: Game, directory: URL, size: CGSize,
                    capture: @escaping (String, Game) -> Void,
                    press: @escaping (String) throws -> Void,
                    text: @escaping (String) -> String?,
                    key: @escaping (UInt16, String) throws -> Bool,
                    native: NativeChecks? = nil, selection: String = "all") throws {
        let files = FileManager.default
        let sandbox = (SaveGame.override ?? files.temporaryDirectory)
            .appendingPathComponent("portolan-foundation-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let previous = SaveGame.override
        SaveGame.override = sandbox
        defer { SaveGame.override = previous }
        print("foundation: isolated save directory \(sandbox.path) (retained for inspection)")
        let driver = Driver(game: game, directory: directory, sandbox: sandbox, size: size,
                            capture: capture, press: press, text: text, key: key)
        if selection == "focus", let native {
            try driver.serviceAndFocus(native)
            print("focus-only: PASS — prepared native focus regression, not the full M0 suite")
            return
        }
        if selection == "tail", let native {
            try driver.battleResultOwnership(native)
            try driver.staleTransition(native)
            try driver.rulesCopies(native)
            try driver.layoutRuleInvariance()
            try driver.diagnosticsUI()
            try native.assetsFailure()
            print("m0-tail: PASS — prepared tail regressions, not the full M0 suite")
            return
        }
        try driver.run()
        if let native { try driver.m0(native) }
    }

    private final class Driver {
        let game: Game
        let directory: URL
        let sandbox: URL
        let size: CGSize
        let capture: (String, Game) -> Void
        let press: (String) throws -> Void
        let text: (String) -> String?
        let key: (UInt16, String) throws -> Bool

        init(game: Game, directory: URL, sandbox: URL, size: CGSize,
             capture: @escaping (String, Game) -> Void, press: @escaping (String) throws -> Void,
             text: @escaping (String) -> String?, key: @escaping (UInt16, String) throws -> Bool) {
            self.game = game; self.directory = directory; self.sandbox = sandbox; self.size = size
            self.capture = capture; self.press = press; self.text = text; self.key = key
        }

        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Playthrough.Failure(message: "Foundation: " + message) }
        }

        func frame(_ name: String) throws {
            let name = "foundation_" + name
            capture(name, game)
            let file = directory.appendingPathComponent(name + ".png")
            let bytes = try Data(contentsOf: file)
            try require(!bytes.isEmpty, "Screenshot was not written: \(name)")
        }

        /// Include extension metadata, which Voyage intentionally omits from its own Codable keys.
        func snapshot(_ voyage: Voyage) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(SaveEnvelope(voyage: voyage,
                summary: SaveGame.Header(date: "fixture-state", port: nil, type: 0),
                generation: voyage.saveContext.generation))
        }

        func fixture() {
            game.resetPresentation()
            game.voyage = Voyage.joanAfterPrologue(in: game.world)
            game.status = game.voyage
            game.title = false
            game.panel = nil
            game.tavern = nil
            game.loaded = false
            game.harbor = game.world.ports[game.voyage.marketIndex]
            game.camera = (game.voyage.x, game.voyage.y)
            game.status = game.voyage
        }

        func dismissNotice() throws {
            if game.portMessageText != nil { try press("portolan.portMessage.dismiss") }
            try require(game.portMessageText == nil, "The port notice did not dismiss")
        }

        /// Exercise F4 → 기능 → 저장/로드, including the SystemMenu command policy exception.
        func openSlots(saving: Bool) throws {
            try require(game.interaction.worldInputAllowed, "An overlay blocks the system-menu entry")
            let consumed = try key(118, "")
            try require(consumed && game.tabMenu == 3, "F4 did not open the sailing command tab")
            guard let index = game.tabEntries(3).firstIndex(where: { $0.title == "기능" }) else {
                throw Playthrough.Failure(message: "Foundation: System menu entry is absent")
            }
            try press("portolan.command.entry.3.\(index)")
            try require(game.command == .system, "The system command did not open")
            try press("label:" + (saving ? "저장" : "로드"))
            try require(game.slotMode == (saving ? .save : .load) && game.command == nil,
                        "The system button did not open its slot window")
        }

        func save(slot: Int) throws {
            try openSlots(saving: true)
            try press("portolan.slots.slot.\(slot)")
            try require(game.question != nil, "Saving did not request confirmation")
            try press("portolan.question.yes")
            try require(game.slotMode == nil && game.saveError == nil, "Successful save did not close the slot window")
        }

        func run() throws {
            try require(SaveGame.directory.standardizedFileURL == sandbox.standardizedFileURL,
                        "Save override did not select the temporary directory")
            fixture()
            let current = sandbox.appendingPathComponent("slot0.json")
            let backup = current.appendingPathExtension("backup")
            let firstGold = game.voyage.gold
            try save(slot: 0)
            let firstBytes = try Data(contentsOf: current)
            let first = try SaveGame.read(from: current)
            try require(first.gold == firstGold && first.saveContext.generation == 1,
                        "First UI save did not produce generation one")
            try require(first.saveContext.contentRevision == game.world.contentRevision
                        && first.saveContext.rules == .original, "Save lost its asset revision or original rules")
            try frame("01_saved")
            try dismissNotice()

            // A distinctive fixture delta makes the current/backup selection observable.
            game.act { $0.gold += 37 }
            let secondGold = game.voyage.gold
            try save(slot: 0)
            let second = try SaveGame.read(from: current)
            let backupBytes = try Data(contentsOf: backup)
            try require(second.gold == secondGold && second.saveContext.generation == 2,
                        "Second UI save did not advance the current generation")
            try require(backupBytes == firstBytes && SaveGame.inspect(0).backupHeader != nil,
                        "The previous verified save was not retained as the backup")
            try dismissNotice()

            game.act { $0.gold += 71 }
            try openSlots(saving: false)
            try press("portolan.slots.slot.0")
            try press("portolan.question.yes")
            try require(game.loaded && game.voyage.gold == secondGold && game.slotMode == nil,
                        "Normal UI load did not restore the current generation")
            try require(game.harbor?.id == first.marketIndex, "Loading a port save did not restore its harbor")
            try frame("02_loaded_current")
            try dismissNotice()

            // Reproduce a file changing between a valid selection and its confirmed read.
            // A pre-corrupted row is disabled, so bypassing it would not test the real UI path.
            game.act { $0.gold += 41 }
            let active = try snapshot(game.voyage), published = try snapshot(game.status)
            let camera = game.camera, harbor = game.harbor?.id
            try openSlots(saving: false)
            try press("portolan.slots.slot.0")
            try require(game.question != nil, "A valid load selection did not request confirmation")
            let damaged = Data("{ foundation fixture: interrupted current save".utf8)
            try damaged.write(to: current, options: .atomic)
            try press("portolan.question.yes")
            try require(game.slotMode == .load && game.question == nil && game.loaded,
                        "Failed load closed the slots or reset the loaded marker")
            let afterFailure = try snapshot(game.voyage), publishedAfterFailure = try snapshot(game.status)
            try require(afterFailure == active && publishedAfterFailure == published
                        && game.harbor?.id == harbor && game.camera.x == camera.x && game.camera.y == camera.y,
                        "Failed load replaced the active session")
            try require(game.saveError?.contains("불러오지 못했습니다") == true
                        && text("portolan.slots.error")?.contains("불러오지 못했습니다") == true,
                        "Failed load did not display its error in the actual slot window")
            try frame("03_corrupt_load_error")
            try press("portolan.slots.close")

            try openSlots(saving: false)
            let inspection = SaveGame.inspect(0)
            try require(inspection.hasCurrent && !inspection.canLoad && inspection.problem != nil
                        && inspection.backupHeader != nil && text("portolan.slots.recovery.0") != nil,
                        "Damaged-current inspection did not expose explicit backup recovery")
            try frame("04_explicit_recovery")
            try press("portolan.slots.recovery.0")
            try require(game.question?.text.contains("덮어쓰지 않습니다") == true,
                        "Recovery did not explain that the current file is preserved")
            try press("portolan.question.no")
            let afterCancel = try snapshot(game.voyage)
            try require(afterCancel == active && game.slotMode == .load, "Recovery cancellation changed the session")
            try press("portolan.slots.recovery.0")
            try press("portolan.question.yes")
            try require(game.loaded && game.voyage.gold == firstGold && game.slotMode == nil
                        && game.harbor?.id == first.marketIndex, "Explicit recovery did not load the previous harbor save")
            let unchangedCurrent = try Data(contentsOf: current), unchangedBackup = try Data(contentsOf: backup)
            try require(unchangedCurrent == damaged && unchangedBackup == backupBytes && !SaveGame.inspect(0).canLoad,
                        "Recovery silently rewrote the damaged current file or backup")
            try frame("05_recovered_backup")
            try dismissNotice()
            print("foundation: PASS — actual system/slot buttons saved two generations, loaded current, showed corrupt-read error, preserved the session, cancelled and explicitly loaded backup; current/backup bytes preserved")

            try failedWrite()
            try endingSave()
            try dialogueOwnership()
            try seaEventClock()
        }

        func failedWrite() throws {
            let blocker = sandbox.appendingPathComponent("blocked-directory")
            try Data("foundation write-failure fixture".utf8).write(to: blocker)
            SaveGame.override = blocker
            defer { SaveGame.override = sandbox }
            let before = try snapshot(game.voyage)
            try openSlots(saving: true)
            try press("portolan.slots.slot.0")
            try press("portolan.question.yes")
            let after = try snapshot(game.voyage)
            try require(game.slotMode == .save && game.question == nil && before == after,
                        "A failed write closed the slot window or changed the voyage")
            try require(game.saveError?.contains("저장하지 못했습니다") == true
                        && text("portolan.slots.error")?.contains("저장하지 못했습니다") == true,
                        "A failed write did not display its error in the actual slot window")
            try frame("06_write_error")
            try press("portolan.slots.close")
            print("foundation: PASS — blocked temporary directory leaves save error readable and slot window open")
        }

        func endingSave() throws {
            fixture()
            // Inject only the completed-cinema boundary; no claim that an ending was earned.
            game.endingCode = 0
            game.finishEnding()
            try require(game.slotMode == .ending && game.endingCode == nil && !game.voyage.storyOn,
                        "finishEnding did not reach its post-ending save window")
            try frame("07_ending_slots")
            try press("portolan.slots.slot.2")
            try press("portolan.question.yes")
            let ending = try SaveGame.read(slot: 2)
            try require(game.title && game.slotMode == nil && game.saveError == nil
                        && SaveGame.header(2)?.type == 2 && !ending.storyOn,
                        "Ending save did not write post-ending data and return to the title")
            try frame("08_ending_saved_title")
            print("foundation: PASS — injected finishEnding boundary saved through actual slot buttons and returned to the title")
        }

        func dialogueOwnership() throws {
            game.startNewGame(hero: 0)
            try TownWalkDriver.enter(.residence, game: game, size: size, press: press)
            try require(game.session?.prompt == .next && game.buildingScene == .residence,
                        "The actual residence visit did not open the first story dialogue")
            let prompt = game.session?.prompt, windows = game.session?.run?.windows
            let before = try snapshot(game.voyage)
            game.save()
            let committed = game.save(slot: 4)
            try require(!committed && game.slotMode == nil && game.saveError != nil
                        && !FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("slot4.json").path),
                        "Dialogue allowed an incomplete Voyage-only save")
            _ = try key(118, "")
            _ = try key(KeyCode.w, "w")
            // Model a held movement key from before the overlay, then tick the real update loop.
            game.held.insert(KeyCode.w)
            for _ in 0..<90 { game.update(dt: 0.1, viewSize: size) }
            game.held.removeAll()
            let after = try snapshot(game.voyage)
            try require(before == after && game.tabMenu == nil && game.session?.prompt == prompt
                        && game.session?.run?.windows == windows, "Dialogue leaked town movement, time, menu input or script progress")
            try frame("09_dialogue_blocks_save")

            // Load is permitted above a dialogue; its Return must not advance the covered SNR.
            game.load()
            try require(game.slotMode == .load && game.interaction.allows(.slots), "Load slots did not own input above dialogue")
            _ = try key(KeyCode.returnKey, "\r")
            try require(game.session?.prompt == prompt && game.session?.run?.windows == windows,
                        "Return advanced the SNR behind the slot window")
            try frame("10_slots_cover_dialogue")
            try press("portolan.slots.close")
            try press("portolan.dialogue.continue")
            try require(game.session?.prompt != prompt || game.session?.run?.windows != windows,
                        "Closing the slots did not return input to the real dialogue button")
            print("foundation: PASS — real new-game residence dialogue blocks save APIs, movement/menu input and town updates; covering slots own Return; actual Continue resumes SNR")
        }

        func seaEventClock() throws {
            fixture()
            game.harbor = nil
            game.voyage.leaveTown()
            game.voyage.anchored = true
            game.status = game.voyage
            // A synthetic message exercises the same modal layer as real sea-event pages.
            game.seaEvent = ["시간 정지 검사용 해상 사건입니다. 확인할 때까지 항해 시계가 멈춰야 합니다."]
            let before = try snapshot(game.voyage)
            for _ in 0..<90 { game.update(dt: 0.1, viewSize: size) }
            let after = try snapshot(game.voyage)
            try require(before == after && !game.interaction.sailingTimeAllowed,
                        "The sea-event overlay advanced the simulation")
            try frame("11_sea_event_paused")
            try press("portolan.sea-event.continue")
            try require(game.seaEvent == nil && game.interaction.sailingTimeAllowed, "Sea-event Continue did not release the clock")
            let tick = game.voyage.tick, day = game.voyage.day
            game.update(dt: 0.1, viewSize: size)
            try require(game.voyage.tick != tick || game.voyage.day != day,
                        "The positive-control sea clock did not resume after dismissing the event")
            print("foundation: PASS — injected sea-event UI freezes nine simulated seconds, actual Continue restores a running clock")
        }

        func m0(_ native: NativeChecks) throws {
            try cancelAndRepeatedActions(native)
            try serviceAndFocus(native)
            try staleTrade(native)
            try battleResultOwnership(native)
            try staleTransition(native)
            try rulesCopies(native)
            try layoutRuleInvariance()
            try diagnosticsUI()
            try native.assetsFailure()
            print("m0: PASS — fixture boundary checks, actual AX actions, AppKit-dispatched focus events and explicit repeat-event policy checks; campaign/VoiceOver completion not claimed")
        }

        func cancelAndRepeatedActions(_ native: NativeChecks) throws {
            fixture()
            game.paused = true
            let before = try snapshot(game.voyage)
            try openSlots(saving: true)
            try press("portolan.slots.slot.3")
            try press("portolan.question.no")
            try require(game.slotMode == .save && game.paused, "Save-confirmation cancellation lost its parent or pause reason")
            try press("portolan.slots.close")
            let after = try snapshot(game.voyage)
            try require(before == after && game.paused && !game.interaction.sailingTimeAllowed
                        && !SaveGame.inspect(3).hasCurrent, "Save cancellation wrote a slot or resumed time")

            var first = 0, second = 0
            game.question = Question(text: "빠른 두 번 누르기 검사 · 첫 확인") {
                first += 1
                self.game.question = Question(text: "이 두 번째 확인은 첫 버튼의 오래된 동작으로 처리되면 안 됩니다.") { second += 1 }
            }
            let stale = try native.retainPress("portolan.question.yes")
            stale(); stale()
            native.wait(0.06)
            try require(first == 1 && second == 0 && game.question != nil,
                        "A retained confirmation action consumed its replacement question")
            try native.repeatKey(KeyCode.returnKey, "\r")
            try require(second == 0 && game.question != nil, "A repeat Return consumed the next confirmation")
            try press("portolan.question.no")
            try frame("m0_cancel_repeat")
            print("m0: PASS — nested save cancellation retains pause; retained AX double action and repeat Return do not consume a later confirmation")
        }

        func serviceAndFocus(_ native: NativeChecks) throws {
            game.startNewGame(hero: 0)
            let staleService = { self.game.enterDoor(HarborPanel.market.rawValue) }
            try TownWalkDriver.enter(.residence, game: game, size: size, press: press)
            let before = try snapshot(game.voyage)
            let windows = game.session?.run?.windows
            try require(game.session != nil && game.panel == nil, "Entry did not wait for its real SNR dialogue")
            staleService()
            try native.repeatKey(KeyCode.returnKey, "\r")
            let after = try snapshot(game.voyage)
            try require(before == after && game.panel == nil && game.buildingScene == .residence
                        && game.session?.run?.windows == windows,
                        "Covered service or repeated Return changed the unfinished building entry")
            try require(text("portolan.harbor.visit.\(HarborPanel.market.rawValue)") == nil,
                        "A covered service remains exposed in the AX tree")
            try frame("m0_service_entry_guard")

            // Use the real editable hero-name field as the focus source, not a fake responder.
            game.newGame()
            try press("portolan.title.menu.0")
            try press("portolan.hero.pick.0")
            try press("portolan.hero.confirm")
            native.wait(0.25)
            try native.focus("portolan.hero.given")
            try require(native.hasEditableFocus(), "The actual name text field did not acquire native editing focus")
            let oldName = text("portolan.hero.given")
            try native.sendKey(KeyCode.w, "w", false)
            try require(text("portolan.hero.given") != oldName && !game.held.contains(KeyCode.w),
                        "A field-editing key was swallowed by the game monitor")
            let name = text("portolan.hero.given")
            game.load()
            native.wait(0.1)
            try require(game.slotMode == .load && !native.hasEditableFocus(), "Slot entry left a covered text field editing")
            try native.sendKey(KeyCode.returnKey, "\r", true)
            try require(game.title && game.slotMode == .load, "Return behind the slots started a new campaign")
            try frame("m0_text_focus_covered")
            try press("portolan.slots.close")
            native.wait(0.1)
            try require(native.hasEditableFocus(), "Closing slots did not restore the valid parent name field")
            try native.sendKey(12, "q", false)
            try require(text("portolan.hero.given") != name && game.title,
                        "Restored native field focus did not accept text")
            print("m0: PASS — actual field focus and AppKit key dispatch edit the parent, modal entry removes editing focus, cancellation restores it; door entry cannot bypass entry dialogue; facility teleport buttons are absent")
        }

        func staleTrade(_ native: NativeChecks) throws {
            // Prepared market state: this verifies presentation boundaries, not an
            // earned campaign. Offer, quantity and purchase use actual native controls.
            fixture()
            game.panel = .market
            guard let offer = game.voyage.offers(in: game.world).first(where: {
                game.voyage.maxPurchase($0, ship: 0, in: game.world) >= 2
            }) else { throw Playthrough.Failure(message: "M0 trade fixture has no affordable two-unit offer") }
            let original = try snapshot(game.voyage)
            try press("portolan.trade.offer.\(offer.good)")
            try press("portolan.trade.buy.quantity.increase")
            try press("portolan.trade.buy.quantity.increase")
            try require(text("portolan.trade.buy.quantity.count")?.contains("2") == true,
                        "Actual quantity increment buttons did not select two units")
            let quantityOnly = try snapshot(game.voyage)
            try require(original == quantityOnly, "Selecting a trade quantity changed gameplay")
            let generation = game.presentationGeneration
            let oldBuy = try native.retainPress("portolan.trade.buy")
            try frame("m0_trade_selected_before_new_game")

            game.startNewGame(hero: 1)
            try require(game.voyage.heroID == 1 && game.voyage.ships.isEmpty
                        && game.presentationGeneration != generation,
                        "Different-hero new game did not replace the trade session with an empty fleet")
            // Force the empty-fleet rendering boundary as well as the immediate old action.
            game.panel = .market
            let empty = try snapshot(game.voyage), emptyPublished = try snapshot(game.status)
            oldBuy(); oldBuy()
            native.wait(0.08)
            let afterEmpty = try snapshot(game.voyage), afterEmptyPublished = try snapshot(game.status)
            try require(empty == afterEmpty && emptyPublished == afterEmptyPublished && game.voyage.ships.isEmpty,
                        "A retained trade action mutated or crashed the new empty-fleet session")
            try frame("m0_trade_empty_fleet_unchanged")

            fixture()
            game.panel = .market
            native.wait(0.08)
            try require(game.interaction.allows(.service)
                        && game.voyage.maxPurchase(offer, ship: 0, in: game.world) >= 2,
                        "Fresh market must admit this trade so a stale-action rejection is meaningful")
            let fresh = try snapshot(game.voyage), freshPublished = try snapshot(game.status)
            oldBuy(); oldBuy()
            native.wait(0.08)
            let afterFresh = try snapshot(game.voyage), afterFreshPublished = try snapshot(game.status)
            try require(fresh == afterFresh && freshPublished == afterFreshPublished,
                        "The old trade control became active again after a fresh market was opened")
            try frame("m0_trade_reopened_old_action_rejected")

            // Positive control: the new generation's own quantity and purchase still work.
            let before = game.voyage
            let unit = before.price(of: offer, in: game.world)
            let held = before.ships[0].holds.filter { $0.good == offer.good }.reduce(0) { $0 + $1.amount }
            try press("portolan.trade.offer.\(offer.good)")
            try press("portolan.trade.buy.quantity.increase")
            try press("portolan.trade.buy")
            let goods = game.voyage.ships[0].holds.filter { $0.good == offer.good }.reduce(0) { $0 + $1.amount }
            try require(game.voyage.gold == before.gold - unit && goods == held + 1,
                        "Fresh market controls did not complete exactly one valid purchase")
            print("m0: PASS — prepared market quantity selected through AX, retained purchase rejected after a different-hero empty-fleet transition and fresh market reopening; voyage/published money+cargo snapshots preserved; new control buys once")
        }

        func battleResultOwnership(_ native: NativeChecks) throws {
            fixture()
            game.harbor = nil
            var voyage = game.voyage
            voyage.ships[0].crew = 30
            voyage.exportToMemory(port: nil)
            guard var battle = Battle(attacker: voyage.heroID, defender: voyage.memory.fb(1, FleetField.admiral),
                                      voyage: &voyage, world: game.world) else {
                throw Playthrough.Failure(message: "M0 defeat-result fixture could not construct a battle")
            }
            // Inject the fatal resolution boundary. This does not claim a played defeat.
            let flagship = voyage.memory.slot(voyage.playerFleet, 0)
            voyage.memory[flagship + 2] = 0
            voyage.memory[flagship + 8] = 0
            battle.phase = .over
            battle.endCode = 5
            let result = voyage.finishBattle(&battle, in: game.world)
            game.voyage = voyage; game.status = voyage
            game.battle = battle; game.battleResult = result
            try require(game.interaction.allows(.battleResult) && game.status.gameOver != nil,
                        "Fatal result does not own input before game over")
            try frame("m0_defeat_result")
            try require(text("portolan.battle.result.close") != nil && text("portolan.gameover.restart") == nil,
                        "Game over obscures an unacknowledged battle result")
            let stale = try native.retainPress("portolan.battle.result.close")
            game.question = Question(text: "결과 위 확인창 입력 우선순위 검사") {}
            let before = try snapshot(game.voyage)
            stale()
            native.wait(0.06)
            let covered = try snapshot(game.voyage)
            try require(game.battleResult == result && before == covered, "A covered result action settled the battle")
            try press("portolan.question.no")
            // SwiftUI can replace/disable the AX object while a confirmation covers it.
            // The pre-modal reference is only a negative control; acquire the newly live
            // result action before testing an actual confirmation and its rapid duplicate.
            let live = try native.retainPress("portolan.battle.result.close")
            live(); live()
            native.wait(0.06)
            try require(game.battle == nil && game.battleResult == nil,
                        "The live result confirmation did not close the battle")
            let settled = try snapshot(game.voyage)
            live(); stale()
            native.wait(0.06)
            let repeated = try snapshot(game.voyage)
            try require(game.battle == nil && game.battleResult == nil && settled == repeated,
                        "A dismissed result action changed the settled voyage")
            try require(text("portolan.gameover.restart") != nil && text("portolan.battle.result.close") == nil,
                        "Acknowledging fatal result did not reveal game over")
            try frame("m0_defeat_gameover")
            try press("portolan.gameover.restart")
            try require(game.title && game.battle == nil && game.battleResult == nil && game.status.gameOver == nil,
                        "Restart retained the previous fatal battle")
            print("m0: PASS — injected fatal result remains above game over, covered/duplicate settlement is rejected, actual restart clears the old battle")
        }

        func staleTransition(_ native: NativeChecks) throws {
            fixture()
            game.harbor = nil
            game.voyage.event = .storm
            game.voyage.eventAnnounced = true
            game.status = game.voyage
            game.update(dt: 0, viewSize: size)
            try require(game.stormPicture, "Storm callback positive control was not scheduled")
            native.wait(3.2)
            try require(!game.stormPicture, "Native wait did not execute a current-generation delayed callback")
            fixture()
            game.harbor = nil
            game.voyage.event = .storm
            game.voyage.eventAnnounced = true
            game.status = game.voyage
            game.update(dt: 0, viewSize: size)
            try require(game.stormPicture, "Storm fixture did not schedule its delayed presentation callback")
            game.startNewGame(hero: 0)
            game.stormPicture = true // sentinel owned by the new presentation generation
            native.wait(3.2)
            try require(game.stormPicture && game.session == nil && game.battle == nil,
                        "A pre-transition delayed callback changed the replacement session")
            game.stormPicture = false
            print("m0: PASS — previous-generation storm callback cannot change a newly started session")
        }

        func rulesCopies(_ native: NativeChecks) throws {
            fixture()
            try save(slot: 6)
            try dismissNotice()
            let source = sandbox.appendingPathComponent("slot6.json")
            let originalBytes = try Data(contentsOf: source)
            let originalDate = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let original = try SaveGame.read(slot: 6)
            game.openRules()
            try require(text("portolan.rules.current")?.contains("원작") == true,
                        "Current campaign rule information is missing")
            try native.choose("portolan.rules.destination", "08 · 빈 슬롯")
            try press("portolan.rules.copy")
            try press("portolan.question.no")
            try require(game.voyage.saveContext.rules == .original && !SaveGame.inspect(7).hasCurrent,
                        "Cancelling a rules copy changed the campaign or wrote its target")
            try press("portolan.rules.copy")
            try press("portolan.question.yes")
            let copy = try SaveGame.read(slot: 7)
            try require(copy.saveContext.rules.mode == .expanded && copy.saveContext.rules.enabledFeatures.isEmpty
                        && copy.saveContext.saveID != original.saveContext.saveID && copy.saveContext.generation == 1
                        && game.voyage.saveContext.rules == copy.saveContext.rules,
                        "Explicit UI copy did not create a separate expanded profile with no active features")
            let sourceAfter = try Data(contentsOf: source)
            let dateAfter = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try require(sourceAfter == originalBytes && dateAfter == originalDate, "Successful expanded copy modified the original slot")
            try frame("m0_expanded_copy")
            if game.showRules { try press("portolan.rules.close") }
            try dismissNotice()
            try openSlots(saving: false)
            try press("portolan.slots.slot.6"); try press("portolan.question.yes")
            try dismissNotice()
            try require(game.voyage.saveContext.rules == .original, "Reloading original did not restore its rules")

            let blocked = sandbox.appendingPathComponent("rules-copy-blocked-directory")
            try Data("write failure fixture".utf8).write(to: blocked)
            SaveGame.override = blocked
            do {
                defer { SaveGame.override = sandbox }
                let before = try snapshot(game.voyage)
                game.openRules()
                try native.choose("portolan.rules.destination", "08 · 빈 슬롯")
                try press("portolan.rules.copy"); try press("portolan.question.yes")
                let after = try snapshot(game.voyage)
                try require(before == after && game.showRules && game.rulesError != nil && text("portolan.rules.error") != nil,
                            "Failed rules copy changed the session or hid the failure")
                try frame("m0_expanded_copy_error")
                try press("portolan.rules.close")
            }
            let sourceAfterFailure = try Data(contentsOf: source)
            let dateAfterFailure = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try require(sourceAfterFailure == originalBytes && dateAfterFailure == originalDate,
                        "Failed rules copy changed original bytes or modification time")

            // Start an actual new game through its real rule and hero selection buttons.
            game.newGame()
            try press("portolan.rules.open")
            try press("portolan.rules.select.expanded")
            try require(game.newGameRules.mode == .expanded && game.newGameRules.enabledFeatures.isEmpty,
                        "New-game expanded choice enabled unavailable features")
            try frame("m0_new_game_rules")
            try press("portolan.rules.close")
            try press("portolan.title.menu.0"); try press("portolan.hero.pick.0")
            try press("portolan.hero.confirm"); try press("portolan.hero.confirm")
            try require(!game.title && game.voyage.saveContext.rules.mode == .expanded,
                        "New game discarded the selected profile")
            try save(slot: 9)
            try dismissNotice()
            try openSlots(saving: false)
            try press("portolan.slots.slot.9"); try press("portolan.question.yes")
            try dismissNotice()
            game.openRules()
            try require(text("portolan.rules.current")?.contains("확장") == true
                        && text("portolan.rules.enabled")?.contains("없음") == true,
                        "Reloaded rules information differs from the saved profile")
            try frame("m0_reloaded_rules")
            try press("portolan.rules.close")
            print("m0: PASS — actual original/expanded UI, separate empty-slot copy, cancellation/write failure preserve original bytes+mtime, new-game selection and save/reload retain profile; all planned features inactive")
        }

        func layoutRuleInvariance() throws {
            fixture()
            game.harbor = nil
            game.voyage.leaveTown()
            game.voyage.anchored = true
            let initial = game.voyage
            let previousLayout = game.classicLayout
            defer { game.classicLayout = previousLayout }
            var hashes: [String] = []
            for classic in [false, true] {
                game.resetPresentation()
                game.classicLayout = classic
                game.voyage = initial; game.status = initial
                game.update(dt: 0.1, viewSize: size)
                hashes.append(try DiagnosticSnapshot(game.voyage).hash())
            }
            try require(hashes.count == 2 && hashes[0] == hashes[1] && game.voyage.saveContext.rules == .original,
                        "The same original-rule state/RNG/update produced different results under classic layout")
            print("m0: PASS — same original state, RNG and update under modern/classic layouts produce identical simulation hashes")
        }

        func diagnosticsUI() throws {
            fixture()
            game.restartDiagnostics()
            game.openDiagnostics()
            try press("portolan.diagnostics.enabled")
            try require(game.diagnostics?.enabled == false, "Actual diagnostic toggle did not disable observation")
            let stoppedCount = game.diagnostics?.recordCount
            game.observe(.sail(0)) { $0.setSail(0); return "applied" }
            try require(game.diagnostics?.recordCount == stoppedCount, "Disabled diagnostics still recorded a command")
            try press("portolan.diagnostics.enabled")
            try require(game.diagnostics?.enabled == true, "Diagnostic toggle did not resume observation")
            try press("portolan.diagnostics.restart")
            try require(game.diagnostics?.recordCount == 0, "Actual restart did not begin a fresh diagnostic record")
            try press("portolan.diagnostics.close")
            game.observe(.sail(0)) { $0.setSail(0); return "applied" }
            game.status = game.voyage
            try require((game.diagnostics?.recordCount ?? 0) > 0, "The fixture's real core sail command was not recorded")
            // A prepared sea boundary, followed by the production update path with fractional
            // time partitions; the exported bundle is also replayed in a separate CLI process.
            game.harbor = nil
            game.voyage.anchored = true
            game.status = game.voyage
            for delta in [0.013, 0.007, 0.021] { game.update(dt: delta, viewSize: size) }

            let destination = sandbox.appendingPathComponent("diagnostic.portolandiag", isDirectory: true)
            let oldDestination = getenv("PORTOLAN_DIAGNOSTIC_EXPORT").map { String(cString: $0) }
            setenv("PORTOLAN_DIAGNOSTIC_EXPORT", destination.path, 1)
            defer {
                if let oldDestination { setenv("PORTOLAN_DIAGNOSTIC_EXPORT", oldDestination, 1) }
                else { unsetenv("PORTOLAN_DIAGNOSTIC_EXPORT") }
            }
            game.openDiagnostics()
            try press("portolan.diagnostics.export")
            let bundle = try DiagnosticExport.read(from: destination)
            let result = try DiagnosticReplay.run(bundle, in: game.world, identity: .current)
            try require(result.matchedCommands >= 1 && result.matchedSegments >= 1,
                        "Native diagnostic export did not reproduce its supported core command hashes")
            try require(text("portolan.diagnostics.status")?.contains("저장했습니다") == true,
                        "Diagnostic export success is not visible")
            try frame("m0_diagnostics_saved")
            let before = try snapshot(game.voyage)
            let exportedBefore = try Data(contentsOf: destination.appendingPathComponent("diagnostic.json"))
            try press("portolan.diagnostics.export")
            let after = try snapshot(game.voyage)
            let exportedAfter = try Data(contentsOf: destination.appendingPathComponent("diagnostic.json"))
            try require(before == after && exportedBefore == exportedAfter
                        && text("portolan.diagnostics.status")?.contains("실패했습니다") == true,
                        "Repeated export changed the voyage/existing bundle or hid its error")
            try frame("m0_diagnostics_error")
            try press("portolan.diagnostics.close")
            try require(!game.showDiagnostics && game.interaction.worldInputAllowed, "Closing diagnostics did not restore game input")
            print("m0: PASS — actual diagnostic toggle/restart/export/close; supported core command hashes replayed; existing export rejected without modifying campaign or bundle")
        }
    }
}
