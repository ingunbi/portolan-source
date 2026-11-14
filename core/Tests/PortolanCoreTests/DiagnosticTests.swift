import XCTest
import Dispatch
@testable import PortolanCore

final class DiagnosticTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    static var cachedWorld: World?
    var world: World!
    var speed = 2.4
    override func setUpWithError() throws {
        if Self.cachedWorld == nil { Self.cachedWorld = try World(assets: WorldTests.assets) }
        world = Self.cachedWorld; speed = Voyage.secondsPerDay; Voyage.secondsPerDay = 2.4
    }
    override func tearDown() { Voyage.secondsPerDay = speed }
    func fixture() -> Voyage {
        var v = Voyage.joanAfterPrologue(in: world)
        v.ships[0].crew = 30; v.ships[0].water = 1000; v.ships[0].food = 1000
        v.gold = 50_000; v.anchored = true
        v.saveContext.contentRevision = world.contentRevision
        return v
    }
    func perform(_ command: DiagnosticCommand, _ v: inout Voyage, _ recorder: DiagnosticRecorder) throws {
        let before = DiagnosticSnapshot(v)
        let result = try command.apply(to: &v, in: world)
        recorder.record(command, before: before, after: DiagnosticSnapshot(v), result: result, context: .init(screen: "test"))
    }
    func recorder(maxRecords: Int = 300, maxBytes: Int = 4 * 1024 * 1024, maxEvents: Int = 128) -> DiagnosticRecorder {
        DiagnosticRecorder(contentRevision: world.contentRevision, maxRecords: maxRecords, maxBytes: maxBytes, maxEvents: maxEvents)
    }
    func testDifferentDeltaSplitsReplayWithFractionalClockAndSteering() throws {
        for deltas in [[0.08], [0.02, 0.03, 0.03], [0.004, 0.007, 0.009, 0.005]] {
            var v = fixture(); v.anchored = false; v.sail = 1
            let recorder = recorder()
            for dt in deltas { try perform(.advance(dt: dt, turn: 0.5, secondsPerDay: 2.4), &v, recorder) }
            let bundle = try JSONDecoder().decode(DiagnosticBundle.self, from: DiagnosticCodec.encode(recorder.bundle))
            let replay = try DiagnosticReplay.run(bundle, in: world)
            XCTAssertEqual(replay.matchedCommands, deltas.count)
            XCTAssertEqual(bundle.segments[0].records.map(\.consumedDelta), deltas)
            XCTAssertTrue(replay.entireSessionReplayed)
        }
    }
    func testCheckpointRotationKeepsSubtickIntegratorAndAutopilotState() throws {
        var v = fixture(); v.developing = [8, 2, 50, 10]
        v.diagnosticRuntime = DiagnosticRuntime(pending: 0.31, stuckDays: 1, dayTile: [120, 358],
                                               replanned: true, seaAlarms: [], soundCues: [], log: [])
        let recorder = recorder(maxRecords: 4)
        for _ in 0..<13 { try perform(.advance(dt: 0.007, turn: 0, secondsPerDay: 2.4), &v, recorder) }
        XCTAssertGreaterThan(recorder.bundle.safeCheckpointsDiscarded, 0)
        XCTAssertLessThanOrEqual(recorder.recordCount, 4)
        let bundle = try JSONDecoder().decode(DiagnosticBundle.self, from: DiagnosticCodec.encode(recorder.bundle))
        let replay = try DiagnosticReplay.run(bundle, in: world)
        XCTAssertFalse(replay.entireSessionReplayed, "Evicted history is not an entire-session replay")
        XCTAssertEqual(replay.safeCheckpointsDiscarded, bundle.safeCheckpointsDiscarded)
        XCTAssertEqual(bundle.segments.last?.finalHash, try DiagnosticSnapshot(v).hash())
    }
    func testRecordingOnAndOffHasNoEffectOnMoneyRNGTimeOrState() throws {
        var recording = fixture(), disabled = recording
        let on = recorder(), off = recorder(); off.enabled = false
        let commands: [DiagnosticCommand] = [.sail(1), .advance(dt: 0.02, turn: -1, secondsPerDay: 2.4),
                                            .supply(kind: 1, barrels: 2, ship: 0), .sell(hold: 999, amount: 1, ship: 0)]
        for command in commands {
            try perform(command, &recording, on); try perform(command, &disabled, off)
            XCTAssertEqual(try DiagnosticSnapshot(recording).hash(), try DiagnosticSnapshot(disabled).hash())
        }
        XCTAssertEqual(off.recordCount, 0)
        XCTAssertEqual(recording.rng.seed, disabled.rng.seed)
        XCTAssertNoThrow(try DiagnosticReplay.run(on.bundle, in: world))
    }
    func testBattleEventObservationOnAndOffPreservesCommandsRNGAndSettlement() throws {
        // The same played-to-completion path as BattleTests.playedBattle, not a fabricated
        // victory. Both runs start from one prepared battle and observe diagnostic-only events.
        var prepared = Voyage.joanAfterPrologue(in: world)
        prepared.rng = GameRandom(seed: 7)
        prepared.ships[0].crew = 30; prepared.ships[0].guns = 10
        prepared.ships[0].gunType = 1; prepared.ships[0].shot = 40
        let p = prepared.memory.fleetAt(1)
        prepared.x = Double(p.x) + 0.5; prepared.y = Double(p.y) + 0.5; prepared.tick = 20
        let encounter = Encounter(attacker: prepared.heroID, defender: prepared.memory.fb(1, FleetField.admiral))
        prepared.pendingBattle = encounter
        let preparedBattle = try XCTUnwrap(prepared.beginBattle(encounter, in: world))
        func play(_ observer: DiagnosticRecorder) throws -> (Voyage, Battle, BattleResult, Int) {
            var v = prepared, b = preparedBattle, turns = 0
            observer.event("battle.begin", voyage: v, context: .init(screen: "battle"))
            while b.phase != .over && turns < 2000 {
                if b.phase == .duel {
                    b.duelMove(turns % 3, &v, world: world)
                } else if b.active != nil {
                    if let target = b.targets(v).first { b.playerAttack(target, &v, world: world) }
                    else { b.endTurn(&v, world: world) }
                }
                turns += 1
                observer.event("battle.command", voyage: v,
                               context: .init(screen: "battle", battleLocation: "turn=\(turns);phase=\(b.phase)"))
            }
            XCTAssertEqual(b.phase, .over, "The battle must end through real commands before settlement")
            guard b.phase == .over else { throw DiagnosticError.invalid("전투 관찰 회귀 검사가 턴 한도에 도달했습니다.") }
            let result = v.finishBattle(&b, in: world)
            observer.event("battle.settlement", voyage: v, context: .init(screen: "battleResult"))
            return (v, b, result, turns)
        }
        let on = recorder(maxEvents: 2048), off = recorder(maxEvents: 2048); off.enabled = false
        let observed = try play(on), unobserved = try play(off)
        XCTAssertGreaterThan(observed.3, 0)
        XCTAssertEqual(observed.3, unobserved.3)
        XCTAssertEqual(observed.2, unobserved.2, "Victory/defeat and all settlement rewards must be identical")
        XCTAssertEqual(observed.0.rng.seed, unobserved.0.rng.seed)
        XCTAssertEqual(observed.0.gold, unobserved.0.gold)
        XCTAssertEqual(try DiagnosticSnapshot(observed.0).hash(), try DiagnosticSnapshot(unobserved.0).hash())
        XCTAssertEqual(try DiagnosticCodec.hash(DiagnosticCodec.encode(observed.1)),
                       try DiagnosticCodec.hash(DiagnosticCodec.encode(unobserved.1)))
        XCTAssertGreaterThan(on.bundle.diagnosticOnlyEvents.count, 1)
        XCTAssertEqual(off.bundle.diagnosticOnlyEvents.count, 0)
        XCTAssertFalse(on.isStopped)
        XCTAssertEqual(on.recordCount, 0, "Battle observations must not be mislabeled as replayable core commands")
        XCTAssertThrowsError(try DiagnosticReplay.run(on.bundle, in: world))
    }
    func testActualTradeMutationReplaysAcceptedAndRejectedCommands() throws {
        var v = fixture(); let r = recorder()
        let offer = try XCTUnwrap(Trade.offers(at: v.market(in: world), in: world.navigation).first)
        for amount in [2, 0, 999_999] {
            let before = DiagnosticSnapshot(v)
            let accepted = v.buy(offer, amount: amount, ship: 0, in: world)
            r.record(.buy(good: offer.good, basePrice: offer.basePrice, amount: amount, ship: 0),
                     before: before, after: DiagnosticSnapshot(v), result: accepted ? "accepted" : "rejected", context: .init(screen: "trade"))
        }
        let before = DiagnosticSnapshot(v)
        let sold = v.sell(hold: 0, amount: 1, ship: 0, in: world)
        r.record(.sell(hold: 0, amount: 1, ship: 0), before: before, after: DiagnosticSnapshot(v),
                 result: sold ? "accepted" : "rejected", context: .init(screen: "trade"))
        XCTAssertEqual(try DiagnosticReplay.run(r.bundle, in: world).matchedCommands, 4)
    }
    func testNegotiatedTradePriceIsRecordedAndReplayedWithoutChangingTheQuote() throws {
        var v = fixture(); let r = recorder()
        v.ships[0].water = 0; v.ships[0].food = 0
        let offer = try XCTUnwrap(Trade.offers(at: v.market(in: world), in: world.navigation).first { v.price(of: $0, in: world) > 1 })
        let marketPrice = v.price(of: offer, in: world)
        let negotiatedPrice = max(1, marketPrice - max(1, marketPrice / 10))
        XCTAssertNotEqual(negotiatedPrice, marketPrice)
        let initialGold = v.gold
        let before = DiagnosticSnapshot(v)
        XCTAssertTrue(v.buy(offer, amount: 2, ship: 0, in: world, unitPrice: negotiatedPrice))
        XCTAssertEqual(v.gold, initialGold - 2 * negotiatedPrice)
        r.record(.buy(good: offer.good, basePrice: offer.basePrice, amount: 2, ship: 0, unitPrice: negotiatedPrice),
                 before: before, after: DiagnosticSnapshot(v), result: "accepted", context: .init(screen: "trade"))
        let decoded = try JSONDecoder().decode(DiagnosticBundle.self, from: DiagnosticCodec.encode(r.bundle))
        XCTAssertEqual(try DiagnosticReplay.run(decoded, in: world).matchedCommands, 1)
        XCTAssertEqual(decoded.segments.last?.finalHash, try DiagnosticSnapshot(v).hash())
        var changed = decoded
        changed.segments[0].records[0].command = .buy(good: offer.good, basePrice: offer.basePrice, amount: 2, ship: 0)
        XCTAssertThrowsError(try DiagnosticReplay.run(changed, in: world), "Losing the agreed price must invalidate replay")
        let unchanged = try DiagnosticSnapshot(v).hash()
        XCTAssertThrowsError(try DiagnosticCommand.buy(good: offer.good, basePrice: offer.basePrice, amount: 1, ship: 0,
                                                       unitPrice: Int.max).apply(to: &v, in: world))
        XCTAssertEqual(try DiagnosticSnapshot(v).hash(), unchanged)
    }
    func testMissingCommandsModifiedDeltaAndTruncatedNoOpTailAreRejected() throws {
        var v = fixture(); let r = recorder()
        for _ in 0..<4 { try perform(.sail(0), &v, r) }
        var missing = r.bundle; missing.segments[0].records.remove(at: 1)
        XCTAssertThrowsError(try DiagnosticReplay.run(missing, in: world))
        var tail = r.bundle; tail.segments[0].records.removeLast()
        XCTAssertThrowsError(try DiagnosticReplay.run(tail, in: world))
        var modified = r.bundle; modified.segments[0].records[0].consumedDelta = 0.5
        XCTAssertThrowsError(try DiagnosticReplay.run(modified, in: world))
        modified = r.bundle; modified.segments[0].records[0].afterHash = "broken"
        XCTAssertThrowsError(try DiagnosticReplay.run(modified, in: world))
    }
    func testVersionPlatformAndContentMismatchesAreNotSuccessfulReplays() throws {
        var v = fixture(); let r = recorder(); try perform(.sail(0), &v, r)
        var b = r.bundle; b.contentRevision = "other"
        XCTAssertThrowsError(try DiagnosticReplay.run(b, in: world))
        b = r.bundle; b.platform = "other"
        XCTAssertThrowsError(try DiagnosticReplay.run(b, in: world))
        b = r.bundle; b.schemaVersion = 100
        XCTAssertThrowsError(try DiagnosticReplay.run(b, in: world))
        b = r.bundle; b.identity = BuildIdentity(appVersion: "other", buildNumber: "27", buildID: "other", sourceRevision: "other", contentRevision: world.contentRevision)
        XCTAssertThrowsError(try DiagnosticReplay.run(b, in: world))
    }
    func testUnsupportedBoundaryAndSpaceLimitsAreExplicitWithoutChangingGame() throws {
        var v = fixture(); let initial = try DiagnosticSnapshot(v).hash()
        let small = recorder(maxBytes: 1024)
        try perform(.sail(0), &v, small)
        XCTAssertTrue(small.isStopped)
        XCTAssertFalse(small.bundle.incompleteReasons.isEmpty)
        XCTAssertEqual(try DiagnosticSnapshot(v).hash(), initial)
        let events = recorder(maxEvents: 2)
        for _ in 0..<4 { events.event("script", voyage: v, context: .init(screen: "dialogue", scriptLocation: "hero:pc=32")) }
        XCTAssertTrue(events.isStopped)
        XCTAssertEqual(events.bundle.diagnosticOnlyEvents.count, 2)
        XCTAssertEqual(try DiagnosticSnapshot(v).hash(), initial)
        let mixed = recorder(); try perform(.sail(0), &v, mixed)
        mixed.event("script", voyage: v, context: .init(screen: "dialogue"))
        try perform(.sail(0), &v, mixed)
        XCTAssertFalse(try DiagnosticReplay.run(mixed.bundle, in: world).entireSessionReplayed)
        XCTAssertEqual(mixed.bundle.segments.count, 2)
    }
    func testExportIntegrityPartialFilesAndWriteFailureDoNotAlterGame() throws {
        var v = fixture(); let r = recorder(); try perform(.sail(0), &v, r)
        let before = try DiagnosticSnapshot(v).hash()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("portolan-diag-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let export = parent.appendingPathComponent("valid.portolandiag")
        let content = ContentValidation.validate(assets: WorldTests.assets, scope: .runtime).manifest
        try DiagnosticExport.write(r.bundle, content: content, to: export)
        let decoded = try DiagnosticExport.read(from: export)
        XCTAssertNoThrow(try DiagnosticReplay.run(decoded, in: world))
        XCTAssertThrowsError(try DiagnosticExport.write(r.bundle, content: content, to: export))
        try Data("{}".utf8).write(to: export.appendingPathComponent("diagnostic.json"))
        XCTAssertThrowsError(try DiagnosticExport.read(from: export))
        try FileManager.default.removeItem(at: export.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try DiagnosticExport.read(from: export))
        let blocker = parent.appendingPathComponent("blocker")
        try Data([1]).write(to: blocker)
        XCTAssertThrowsError(try DiagnosticExport.write(r.bundle, content: content, to: blocker.appendingPathComponent("failure")))
        XCTAssertEqual(try DiagnosticSnapshot(v).hash(), before)
    }

    func testDisabledNoOpIntervalCannotClaimEntireSessionReplay() throws {
        var v = fixture(); let r = recorder()
        try perform(.sail(0), &v, r)
        let before = try DiagnosticSnapshot(v).hash()
        r.enabled = false
        try perform(.sail(0), &v, r) // Same state means hash-gap detection alone cannot see this gap.
        r.enabled = true
        try perform(.sail(0), &v, r)
        XCTAssertEqual(try DiagnosticSnapshot(v).hash(), before)
        XCTAssertEqual(r.bundle.disabledIntervals, 1)
        XCTAssertEqual(r.recordCount, 2)
        XCTAssertEqual(r.bundle.segments.count, 2)
        XCTAssertFalse(try DiagnosticReplay.run(r.bundle, in: world).entireSessionReplayed)
    }

    func testEventOnlyRecordingObeysByteBudgetAndBoundsLongContext() throws {
        let v = fixture(), r = recorder(maxBytes: 2048, maxEvents: 1024)
        let long = String(repeating: "경계", count: 10_000)
        for _ in 0..<20 {
            r.event(long, voyage: v, context: .init(screen: long, scriptLocation: long, violations: Array(repeating: long, count: 50)))
            XCTAssertEqual(r.encodedByteCount, try DiagnosticCodec.encode(r.bundle).count)
            XCTAssertLessThanOrEqual(r.encodedByteCount, r.maxBytes)
        }
        XCTAssertTrue(r.isStopped)
        XCTAssertTrue(r.bundle.recordingStopped)
        XCTAssertLessThan(r.bundle.diagnosticOnlyEvents.count, r.maxEvents)
        XCTAssertFalse(r.bundle.incompleteReasons.isEmpty)
    }

    func testCachedByteCountMatchesJSONAcrossDigitsEventsAndEviction() throws {
        var v = fixture(); let r = recorder(maxRecords: 4)
        for i in 1...105 {
            try perform(.sail(0), &v, r)
            if [2, 10, 11, 100].contains(i) { r.event("context", voyage: v, context: .init(screen: "test")) }
            if [1, 2, 8, 9, 10, 11, 40, 41, 98, 99, 100, 101, 105].contains(i) {
                XCTAssertEqual(r.encodedByteCount, try DiagnosticCodec.encode(r.bundle).count, "sequence boundary \(i)")
            }
        }
        r.enabled = false; r.enabled = true
        XCTAssertEqual(r.encodedByteCount, try DiagnosticCodec.encode(r.bundle).count)
        XCTAssertGreaterThan(r.bundle.safeCheckpointsDiscarded, 9)
        XCTAssertLessThanOrEqual(r.recordCount, 4)
        XCTAssertNoThrow(try DiagnosticReplay.run(r.bundle, in: world))
    }

    func testOversizedReplacementPreservesLastReplayableCheckpoint() throws {
        var v = fixture(); let sizing = recorder()
        try perform(.sail(0), &v, sizing)
        let r = recorder(maxBytes: try DiagnosticCodec.encode(sizing.bundle).count + 1024)
        try perform(.sail(0), &v, r)
        let retainedHash = try XCTUnwrap(r.bundle.segments.last?.finalHash)
        v.ships[0].name = String(repeating: "large fixture", count: r.maxBytes / 4)
        let changed = try DiagnosticSnapshot(v).hash()
        try perform(.sail(0), &v, r)
        XCTAssertTrue(r.isStopped)
        XCTAssertEqual(r.recordCount, 1)
        XCTAssertEqual(r.bundle.segments.last?.finalHash, retainedHash)
        XCTAssertEqual(try DiagnosticSnapshot(v).hash(), changed, "Observation must not alter the oversized source state")
        XCTAssertEqual(r.encodedByteCount, try DiagnosticCodec.encode(r.bundle).count)
        XCTAssertLessThanOrEqual(r.encodedByteCount, r.maxBytes)
        XCTAssertFalse(try DiagnosticReplay.run(r.bundle, in: world).entireSessionReplayed)
    }

    func testUnobservedPresentationDrainStartsAnExplicitCheckpoint() throws {
        var v = fixture(); let r = recorder()
        v.log = ["presentation fixture"]
        try perform(.sail(0), &v, r)
        v.log.removeAll() // Game.update drains this outside the supported core command.
        try perform(.sail(0), &v, r)
        XCTAssertEqual(r.bundle.segments.count, 2)
        XCTAssertFalse(r.bundle.incompleteReasons.isEmpty)
        let replay = try DiagnosticReplay.run(r.bundle, in: world)
        XCTAssertEqual(replay.matchedCommands, 2)
        XCTAssertFalse(replay.entireSessionReplayed)
    }

    func testInvalidRepairAndReplayCountersThrowInsteadOfTrapping() throws {
        var v = fixture()
        let before = try DiagnosticSnapshot(v).hash()
        for ship in [-1, v.ships.count, 999_999] {
            XCTAssertThrowsError(try DiagnosticCommand.repair(ship: ship).apply(to: &v, in: world))
        }
        XCTAssertEqual(try DiagnosticSnapshot(v).hash(), before)
        let r = recorder(); try perform(.sail(0), &v, r)
        var sequence = r.bundle
        sequence.segments[0].firstSequence = Int.max
        sequence.segments[0].lastSequence = Int.max
        sequence.segments[0].records[0].commandSequence = Int.max
        XCTAssertThrowsError(try DiagnosticReplay.run(sequence, in: world))
        var step = r.bundle
        step.segments[0].firstSimulationStep = Int.max
        step.segments[0].records[0].simulationStep = Int.max
        XCTAssertThrowsError(try DiagnosticReplay.run(step, in: world))
        var runtime = v.diagnosticRuntime; runtime.stuckDays = Int.max; v.diagnosticRuntime = runtime
        XCTAssertThrowsError(try DiagnosticSnapshot(v).restore())
        v.day = Int.max
        let invalidTime = recorder(); invalidTime.event("overflow fixture", voyage: v, context: .init(screen: "test"))
        XCTAssertTrue(invalidTime.isStopped)
    }

    func testRecord120AdvanceStepsReportsElapsedWithoutAnUnstableFPSThreshold() throws {
        var v = fixture(); let r = recorder()
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<120 { try perform(.advance(dt: 1.0 / 600, turn: 0, secondsPerDay: 2.4), &v, r) }
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print(String(format: "diagnostic-benchmark: 120 advance observations %.2f ms (%.3f ms/step), retained %d bytes", elapsedMS, elapsedMS / 120, r.encodedByteCount))
        XCTAssertFalse(r.isStopped)
        XCTAssertEqual(r.encodedByteCount, try DiagnosticCodec.encode(r.bundle).count)
        XCTAssertEqual(try DiagnosticReplay.run(r.bundle, in: world).matchedCommands, 120)
    }
}
