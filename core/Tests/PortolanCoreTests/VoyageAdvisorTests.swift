import XCTest
@testable import PortolanCore

final class VoyageAdvisorTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!
    override func setUpWithError() throws { world = try World(assets: WorldTests.assets) }

    func voyage() -> Voyage {
        var v = Voyage.joanAfterPrologue(in: world)
        v.memory[TownDS.sharedChapter] = 0
        v.memory[TownDS.sharedFlags + 2] = 0
        v.ships[0].crew = 20
        v.ships[0].water = 420
        v.ships[0].food = 420
        return v
    }

    func setJob(_ chapter: Int, stage: Int = 0, voyage v: inout Voyage) {
        v.memory[TownDS.sharedChapter] = chapter
        v.memory[TownDS.sharedBlock] = stage
        v.memory[TownDS.sharedFlags] = 0
        v.setSharedVar(16, 0)
        v.setSharedVar(17, 1)
        v.setSharedVar(24, ((v.year - 1501) * 12 + v.month) * 30 + v.dayOfMonth + 12)
    }

    func testFleetStoresAreSharedRatherThanMinimumOfShips() {
        var v = voyage()
        var second = v.ships[0]
        second.water = 0
        second.food = 0
        v.ships.append(second)
        let a = v.advice(in: world)
        XCTAssertEqual(a.waterDays, 10)
        XCTAssertEqual(a.foodDays, 10)
        XCTAssertFalse(a.warnings.contains { $0.id == "water" })
    }

    func testNoFleetIsNotInfiniteOrReady() {
        var v = voyage()
        v.ships = []
        let a = v.advice(in: world)
        XCTAssertNil(a.supplyDays)
        XCTAssertEqual(a.warnings.first?.id, "no-ships")
        XCTAssertEqual(a.warnings.first?.severity, .critical)
    }

    func testRatsAndZeroRationsUseActualDailyRules() {
        var v = voyage()
        v.epidemic = true
        XCTAssertEqual(v.advice(in: world).foodDays, 420 / 31)
        v.waterRation = 0
        XCTAssertEqual(v.advice(in: world).waterDays, 420)
        XCTAssertTrue(v.advice(in: world).warnings.contains { $0.id == "ration" })
        v.ashore = true
        XCTAssertEqual(v.advice(in: world).foodDays, 420 / 21)
    }

    func testWarningsPrioritizeCriticalAndDoNotAdvanceOrMutate() throws {
        var v = voyage()
        v.ships[0].hull = v.ships[0].maxHull / 2
        v.ships[0].sailorShare = 0
        v.scurvy = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(v)
        let a = v.advice(in: world)
        XCTAssertTrue(a.warnings.contains { $0.id == "hull-0" && $0.severity == .critical })
        XCTAssertTrue(a.warnings.contains { $0.id == "crew-0" && $0.severity == .critical })
        XCTAssertTrue(a.warnings.contains { $0.id == "scurvy" })
        XCTAssertEqual(try encoder.encode(v), before)
    }

    func testGuildDeadlineUsesOriginalYearOffsetAndCanBeOverdue() {
        var v = voyage()
        setJob(3, voyage: &v)
        XCTAssertEqual(v.advice(in: world).objective?.daysRemaining, 12)
        XCTAssertEqual(v.advice(in: world).objective?.destinationID, 1)
        v.dayOfMonth += 14
        XCTAssertEqual(v.advice(in: world).objective?.daysRemaining, -2)
    }

    func testLetterReturnStageHasNoDeliveryDeadline() {
        var v = voyage()
        setJob(3, voyage: &v)
        v.memory[TownDS.sharedFlags] |= 1 << 1
        let o = v.advice(in: world).objective
        XCTAssertEqual(o?.destinationID, 0)
        XCTAssertNil(o?.daysRemaining)
        XCTAssertEqual(o?.title, "편지배달 · 보수 수령")
    }

    func testTransportBriefingDoesNotExposeStaleCargoOrDeadline() {
        var v = voyage()
        setJob(1, voyage: &v)
        v.setSharedVar(18, 65535)
        v.setSharedVar(19, 65535)
        let o = v.advice(in: world).objective
        XCTAssertEqual(o?.title, "상품수송 · 의뢰 확인")
        XCTAssertEqual(o?.destinationID, 0)
        XCTAssertNil(o?.daysRemaining)
        XCTAssertFalse(o?.detail.contains("65535") ?? true)
    }

    func testTransportReturnStageHasNoDeliveryDeadline() {
        var v = voyage()
        setJob(1, stage: 1, voyage: &v)
        v.memory[TownDS.sharedFlags] |= 1
        XCTAssertEqual(v.advice(in: world).objective?.title, "상품수송 · 보수 수령")
        XCTAssertNil(v.advice(in: world).objective?.daysRemaining)
    }

    func testRoyalCommissionNeverInheritsPreviousDeadline() {
        var v = voyage()
        setJob(7, stage: 2, voyage: &v)
        XCTAssertNil(v.advice(in: world).objective?.daysRemaining)
        XCTAssertEqual(v.advice(in: world).objective?.destinationID, 1)
        v.memory[TownDS.sharedFlags] |= 1 << 1
        XCTAssertEqual(v.advice(in: world).objective?.destinationID, v.homePort)
    }

    func testKnownPortsUseLiveDiscoveryFlagsOnly() {
        var v = voyage()
        for p in world.ports { v.memory[DS.port + DS.portSize * p.id + 0x13] &= ~0x10 }
        XCTAssertTrue(v.advice(in: world).knownPorts.isEmpty)
        let p = world.ports[0]
        v.memory[DS.port + DS.portSize * p.id + 0x13] |= 0x10
        XCTAssertEqual(v.advice(in: world).knownPorts.map(\.id), [p.id])
    }
}
