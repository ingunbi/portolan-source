import XCTest
@testable import PortolanCore

final class InteractionPolicyTests: XCTestCase {
    func testWorldInputAndTimeHaveSeparatePauseRules() {
        let sailing = InteractionPolicy()
        XCTAssertTrue(sailing.worldInputAllowed)
        XCTAssertTrue(sailing.sailingTimeAllowed)
        XCTAssertFalse(sailing.townTimeAllowed)
        let paused = InteractionPolicy(paused: true)
        XCTAssertTrue(paused.worldInputAllowed, "The player must be able to unpause")
        XCTAssertFalse(paused.sailingTimeAllowed)
        XCTAssertTrue(paused.canOpenSave)
        let town = InteractionPolicy(inHarbor: true)
        XCTAssertTrue(town.townTimeAllowed)
        XCTAssertFalse(town.sailingTimeAllowed)
    }

    func testEveryOverlayStopsBackgroundMovement() {
        for layer in InteractionPolicy.Layer.allCases where layer != .world {
            let policy = InteractionPolicy(layers: [layer])
            XCTAssertFalse(policy.worldInputAllowed, "\(layer)")
            XCTAssertFalse(policy.sailingTimeAllowed, "\(layer)")
            XCTAssertFalse(InteractionPolicy(layers: [layer], inHarbor: true).townTimeAllowed, "\(layer)")
        }
    }

    func testNestedConfirmationRestoresItsParentWithoutDiscardingIt() {
        let parent: Set<InteractionPolicy.Layer> = [.service, .dialogue, .slots]
        XCTAssertEqual(InteractionPolicy(layers: parent.union([.confirmation])).inputOwner, .confirmation)
        XCTAssertEqual(InteractionPolicy(layers: parent).inputOwner, .slots)
        XCTAssertEqual(InteractionPolicy(layers: parent.subtracting([.slots])).inputOwner, .dialogue)
    }

    func testResultPrecedesFatalGameOverAndDuelOwnsBattleInput() {
        let result = InteractionPolicy(layers: [.battle, .battleResult, .gameOver])
        XCTAssertEqual(result.inputOwner, .battleResult)
        XCTAssertFalse(result.canStoreVoyage)
        XCTAssertEqual(InteractionPolicy(layers: [.gameOver]).inputOwner, .gameOver)
        let duel = InteractionPolicy(layers: [.battle, .duel])
        XCTAssertTrue(duel.allows(.duel))
        XCTAssertFalse(duel.allows(.battle))
    }

    func testUnsafeSessionsCannotBeSavedEvenThroughAConfirmation() {
        let unsafe: [InteractionPolicy.Layer] = [.dialogue, .message, .battle, .duel, .encounter,
                                               .battleResult, .seaEvent, .landing, .coast, .command,
                                               .title, .opening, .ending, .gameOver, .transition]
        for layer in unsafe {
            let policy = InteractionPolicy(layers: [layer, .slots, .confirmation])
            XCTAssertFalse(policy.canStoreVoyage, "\(layer)")
            XCTAssertNotNil(policy.saveBlockReason, "\(layer)")
        }
    }

    func testSaveDialogCanCommitASafeVoyageAndRestorePause() {
        let policy = InteractionPolicy(layers: [.slots, .confirmation], paused: true)
        XCTAssertTrue(policy.canStoreVoyage)
        XCTAssertFalse(policy.canOpenSave)
        XCTAssertFalse(policy.canOpenLoad)
        XCTAssertFalse(policy.sailingTimeAllowed)
        XCTAssertFalse(InteractionPolicy(paused: true).sailingTimeAllowed)
        XCTAssertTrue(InteractionPolicy(layers: [.service], inHarbor: true).canStoreVoyage)
        XCTAssertTrue(InteractionPolicy(layers: [.command], allowsSavingFromCommand: true).canOpenSave,
                      "The existing system menu opens Save before clearing its command panel")
    }

    func testPendingEncounterCannotSlipIntoASave() {
        let pending = InteractionPolicy(hasPendingEncounter: true)
        XCTAssertFalse(pending.canStoreVoyage)
        XCTAssertFalse(pending.sailingTimeAllowed)
        XCTAssertTrue(pending.canPresentEncounter)
        XCTAssertFalse(InteractionPolicy(layers: [.slots], hasPendingEncounter: true).canPresentEncounter)
    }

    func testLoadCanReplaceASessionButNotBypassItsTopConfirmation() {
        XCTAssertTrue(InteractionPolicy(layers: [.title]).canOpenLoad)
        XCTAssertTrue(InteractionPolicy(layers: [.gameOver]).canOpenLoad)
        XCTAssertTrue(InteractionPolicy(layers: [.dialogue]).canOpenLoad)
        XCTAssertFalse(InteractionPolicy(layers: [.dialogue, .confirmation]).canOpenLoad)
        XCTAssertFalse(InteractionPolicy(layers: [.transition]).canOpenLoad)
    }

    func testRulesAndDiagnosticsYieldToSlotsAndConfirmation() {
        XCTAssertEqual(InteractionPolicy(layers: [.title, .rules]).inputOwner, .rules)
        XCTAssertEqual(InteractionPolicy(layers: [.rules, .diagnostics]).inputOwner, .diagnostics)
        XCTAssertEqual(InteractionPolicy(layers: [.rules, .slots]).inputOwner, .slots)
        XCTAssertEqual(InteractionPolicy(layers: [.diagnostics, .confirmation]).inputOwner, .confirmation)
        XCTAssertTrue(InteractionPolicy(layers: [.rules], paused: true).canStoreVoyage)
        XCTAssertFalse(InteractionPolicy(layers: [.battle, .rules]).canStoreVoyage)
    }

    func testDiagnosticsReportImpossibleCombinationsWithoutRejectingValidParents() {
        XCTAssertEqual(InteractionPolicy(layers: [.duel]).invalidCombinations, ["duel_without_battle"])
        XCTAssertEqual(InteractionPolicy(layers: [.battleResult]).invalidCombinations, ["result_without_battle"])
        XCTAssertEqual(InteractionPolicy(layers: [.service]).invalidCombinations, ["service_outside_harbor"])
        XCTAssertEqual(InteractionPolicy(layers: [.title, .dialogue]).invalidCombinations, ["title_with_active_session"])
        XCTAssertTrue(InteractionPolicy(layers: [.service, .dialogue, .slots, .confirmation], inHarbor: true).invalidCombinations.isEmpty)
        XCTAssertTrue(InteractionPolicy(layers: [.battle, .duel]).invalidCombinations.isEmpty)
        XCTAssertTrue(InteractionPolicy(layers: [.battle, .battleResult, .gameOver]).invalidCombinations.isEmpty)
    }
}
