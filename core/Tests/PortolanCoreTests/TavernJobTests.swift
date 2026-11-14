import XCTest
@testable import PortolanCore

final class TavernJobTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func testLatLon() {
        let v = Voyage.newGame(in: world)
        XCTAssertEqual(v.latLon(120, 358), [.msg(126, 39), .msg(129, 9)])          // Lisbon: 북위 39도, 서경 9도
    }

    func testDebtorPaysOrRuns() {
        var paid = 0, ran = 0
        for seed in 1...40 as ClosedRange<UInt32> {
            var v = Voyage.newGame(in: world)
            v.rng = GameRandom(seed: seed)
            v.memory[TownDS.sharedChapter] = 5
            v.setSharedVar(6, 5); v.setSharedVar(17, 85); v.setSharedVar(18, 255); v.setSharedVar(19, 1)
            XCTAssertEqual(v.patronHook(person: 85), .debtor)
            XCTAssertNil(v.patronHook(person: 96))
            let r = v.meetDebtor()
            if r.stays {
                paid += 1
                XCTAssertEqual(v.gold, 50000)
                XCTAssertEqual(v.sharedVar(18), 0)
                XCTAssertNil(v.patronHook(person: 85))
            } else {
                ran += 1
                XCTAssertEqual(v.gold, 0)
            }
        }
        XCTAssertGreaterThan(paid, ran)                                             // luck or two in three
    }

    func testInformantSellsTheMap() {
        var v = Voyage.newGame(in: world)
        v.memory[TownDS.sharedChapter] = 11
        v.setSharedVar(6, 11); v.setSharedVar(17, 85); v.setSharedVar(18, 90)        // 순금 가면
        XCTAssertEqual(v.patronHook(person: 85), .mapSeller)
        XCTAssertTrue(v.mapOffer(in: world).forSale)
        XCTAssertEqual(v.buyMap(), [.msg(607)])                                     // no money
        v.gold = 5000
        XCTAssertEqual(v.buyMap(), [.msg(606)])
        XCTAssertTrue(v.items.contains(80))
        XCTAssertEqual(v.gold, 4000)
        XCTAssertFalse(v.mapOffer(in: world).forSale)                               // 879 next time
    }

    func testCommission11Leads() {
        var v = Voyage.newGame(in: world)
        v.memory[TownDS.sharedChapter] = 11
        v.setSharedVar(6, 11); v.setSharedVar(16, 0xFF); v.setSharedVar(17, 0xFF); v.setSharedVar(18, 90); v.setSharedVar(23, 0)
        let first = v.commission11Desk(in: world)
        let lead = v.sharedVar(16)
        XCTAssertTrue((0..<42).contains(lead))
        if lead != v.marketIndex { XCTAssertEqual(first.first.map { if case .message(let n, _) = $0 { return n } else { return 0 } }, 598) }
        v.marketIndex = lead
        _ = v.commission11Desk(in: world)
        let p = v.sharedVar(17)
        XCTAssertTrue((79..<120).contains(p))
        XCTAssertLessThan(v.memory[DS.person(p) + 0x2D], 42)                         // tier 0: a near port
    }
}
