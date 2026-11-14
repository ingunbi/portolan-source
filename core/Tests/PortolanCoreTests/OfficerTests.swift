import XCTest
@testable import PortolanCore

final class OfficerTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func testLisbonTavernAndRefusal() {
        var v = Voyage.joanAfterPrologue(in: world)
        XCTAssertEqual(v.recruits(in: world), [85, 96])
        XCTAssertEqual(world.navigation.newGame.persons[96].name, "아론소 멘도사")
        // Mendoza is best at knowledge (80): his 2 × 80 = 160 beats Joan's 2 × 73 = 146.
        XCTAssertEqual(v.offerTerms(to: 96, in: world), .refused)
        XCTAssertEqual(v.offerTerms(to: 85, in: world), .refused)     // (7 + 6) × 86 = 1118
        XCTAssertEqual(v.offerTerms(to: 80, in: world), .busy)        // drinks in Alexandria
    }

    func testExperiencedCaptainHiresAndBuysASecondShip() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.captain.navLevel = 10                                        // (10 + 1) × 73 = 803
        guard case .salary(let pay) = v.offerTerms(to: 96, in: world) else { return XCTFail() }
        XCTAssertTrue([10, 20, 30].contains(pay))                      // 160 / 400 + rand(3) + 1, × 10
        v.hireOfficer(96, salary: pay, in: world)
        XCTAssertEqual(v.officers.map(\.name), ["아론소 멘도사"])
        XCTAssertEqual(v.officers[0].loyalty, 10)
        XCTAssertEqual(v.recruits(in: world), [85])
        XCTAssertEqual(v.spareCaptains, 1)

        v.gold = 5000
        v.shipyardStocks = [ShipyardStock(port: 0, classes: [0])]
        XCTAssertEqual(v.buyShip(slot: 0, offer: 1200, tradeIn: nil, name: "발사", in: world), .bought)
        XCTAssertEqual(v.ships.count, 2)
        XCTAssertEqual(v.spareCaptains, 0)
        v.dismissOfficer(0)
        XCTAssertEqual(v.officers.count, 1)                            // still commands the balsa
    }

    func testMonthlyPayAndLoyalty() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.hireOfficer(96, salary: 20, in: world)
        v.payOfficers()
        XCTAssertEqual(v.gold, 980)
        XCTAssertEqual(v.officers[0].loyalty, 12)                       // 10 + (2 × 2 − 80 + 78)
        v.gold = 5
        v.payOfficers()
        XCTAssertEqual(v.gold, 5)
        XCTAssertTrue(v.officers[0].unpaid)
    }

    func testLevelsFromLanding() {
        XCTAssertEqual(Officers.threshold(level: 1), 30)
        XCTAssertEqual(Officers.threshold(level: 30), 9720)              // capped at level 18
        var v = Voyage.joanAfterPrologue(in: world)
        v.daysAtSea = 10                                                // 2 × 10² = 200: 30 + 120 spent
        v.arrive(at: world.ports[1], in: world)
        XCTAssertEqual(v.captain.navLevel, 3)
        XCTAssertEqual(v.captain.navExp, 50)
        XCTAssertGreaterThanOrEqual(v.captain.leadership, 78)
        XCTAssertEqual(Officers.landingExp(days: 120, commands: false), 10000)
    }

    func testMonthDriftsPricesTowardFifty() {
        var v = Voyage.joanAfterPrologue(in: world)
        let before = v.markets[0].prices                                // [49, 50, 52, 50, 45, 54, 52, 51, 51, 51]
        v.driftMarkets()
        for (a, b) in zip(before, v.markets[0].prices) {
            XCTAssertTrue(a > 50 ? (a - 5...a - 1).contains(b) : (a + 1...a + 5).contains(b))
        }
    }

    func testLicencesLapseInMarch() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.items = [0x23, 0x29]
        v.month = 2
        v.newMonth()
        XCTAssertEqual(v.items, [0x29])
    }

    func testSaveRoundTrip() throws {
        var v = Voyage.joanAfterPrologue(in: world)
        v.hireOfficer(96, salary: 20, in: world)
        v.ships[0].holds = [CargoLot(good: 15, amount: 3)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portolan-test-save.json")
        try SaveGame.write(v, to: url)
        let r = try SaveGame.read(from: url)
        XCTAssertEqual(r.gold, v.gold)
        XCTAssertEqual(r.ships[0].holds, v.ships[0].holds)
        XCTAssertEqual(r.officers, v.officers)
        XCTAssertEqual(r.memory.bytes, v.memory.bytes)
        XCTAssertEqual(r.markets, v.markets)
        XCTAssertEqual(r.shipyardStocks, v.shipyardStocks)
        XCTAssertEqual([r.year, r.month, r.dayOfMonth], [v.year, v.month, v.dayOfMonth])
        XCTAssertEqual(r.rng.seed, v.rng.seed)
        try? FileManager.default.removeItem(at: url)
    }
}
