import XCTest
@testable import PortolanCore

/// The 정보 screens and their records (docs/re/info.md).
final class InfoTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func testLogbookKeepsTheLast48Lines() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.logDeparture(from: v.marketIndex)
        XCTAssertEqual(v.logbook.count, 1)
        XCTAssertEqual(v.logbook[0].type, 1)
        XCTAssertEqual(v.logbook[0].year, v.year)
        XCTAssertEqual(v.logbook[0].month, v.month + 1)
        let text = v.logText(v.logbook[0], messages: Self.messages, world: world)
        XCTAssertTrue(text.hasSuffix("리스본항을 떠났다."), text)
        for k in 0..<60 { v.writeLog(9, k % 100) }
        XCTAssertEqual(v.logbook.count, 48)
        XCTAssertEqual(v.logbook.last?.a, 59)
        XCTAssertEqual(v.logbook.first?.a, 12)
    }

    func testArrivalAndPurchaseAreLogged() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.ships = [Ship.built(class: 0, named: "발사", in: world.navigation)]
        v.daysAtSea = 12
        v.arrive(at: world.ports[1], in: world)
        XCTAssertEqual(v.logbook.last.map { [$0.type, $0.a, $0.b] }, [0, 12, 1])
        v.gold = 100_000
        let o = v.offers(in: world)[0]
        XCTAssertTrue(v.buy(o, amount: 3, ship: 0, in: world))
        let e = v.logbook.last!
        XCTAssertEqual([e.type, e.a, e.d], [12, o.good, 3])
        XCTAssertTrue(v.logText(e, messages: Self.messages, world: world).contains("3개 구입했다"))
    }

    func testBattleLogWording() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.writeLog(2, 15, 0)
        v.writeLog(2, 61, 2)
        XCTAssertTrue(v.logText(v.logbook[0], messages: Self.messages, world: world).hasSuffix(", 이겼다"))
        XCTAssertTrue(v.logText(v.logbook[1], messages: Self.messages, world: world).hasSuffix("했지만 달아날 수밖에 없었다"))
        XCTAssertEqual(Voyage.logResult(code: 1), 1)
        XCTAssertNil(Voyage.logResult(code: 5))
    }

    func testFleetSummary() {
        var v = Voyage.joanAfterPrologue(in: world)
        var a = Ship.built(class: 0, named: "가", in: world.navigation)
        a.crew = 20
        var b = Ship.built(class: 3, named: "나", in: world.navigation)
        b.crew = 40
        b.hull = 30
        v.ships = [a, b]
        let s = v.fleetSummary(in: world)
        XCTAssertEqual(s.crew, 60)
        XCTAssertEqual(s.hull, min(30, a.hull, 100))
        // No guns: power is 2·hull + gunners, gunners = 25 % of the crew.
        XCTAssertEqual(s.power, 2 * a.hull + 5 + 2 * 30 + 10)
        XCTAssertGreaterThan(v.shipKnots(0, in: world), 0)
    }

    func testTitlesFollowTheHero() {
        XCTAssertEqual(Town.title(rank: 9, hero: 0), "공작")
        XCTAssertEqual(Town.title(rank: 1, hero: 5), "사족")
        XCTAssertEqual(Town.title(rank: 9, hero: 5), "대재상")
    }

    func testNameTables() {
        let m = Voyage.joanAfterPrologue(in: world).memory
        XCTAssertEqual(m.name(0x7CA, 0), "향신료")
        XCTAssertEqual(m.name(0x866, 6), "해적")
        XCTAssertEqual(m.name(0x874, 4), "교섭")
        XCTAssertEqual(m.name(0x808, 7), "카로네이드")
    }

    func testPriceListCoversTheCategory() {
        let v = Voyage.joanAfterPrologue(in: world)
        let spices = v.priceList(category: 0, in: world)
        XCTAssertEqual(spices.rows.map(\.good), Array(0..<6))
        XCTAssertEqual(spices.index, v.market(in: world).prices[0] + 50)
        XCTAssertEqual(v.priceList(category: 9, in: world).rows.map(\.good), Array(40..<46))
    }

    func testDiscoveriesAndTheMapMaker() {
        var v = Voyage.joanAfterPrologue(in: world)
        XCTAssertTrue(v.foundSites.isEmpty)
        v.memory[Discovery.site(3) + 6] = (v.memory[Discovery.site(3) + 6] & 0x1F) | 0x60
        XCTAssertEqual(v.foundSites, [3])
        XCTAssertFalse(world.discoveryInfo(3).name.isEmpty)
        XCTAssertTrue(["D", "C", "B", "A", "☆"].contains(v.siteGrade(3)))

        XCTAssertNil(v.checkMap())
        v.items.append(80)
        v.gold = 20_000
        XCTAssertNil(v.checkMap())                                         // more than 20,000 needed
        v.gold = 20_001
        let at = v.checkMap()
        XCTAssertNotNil(at)
        XCTAssertEqual(v.gold, 1)
        XCTAssertTrue(at!.contains("도, "))
    }

    static let messages: [String] = {
        struct Text: Decodable { let message: [String] }
        let d = try! Data(contentsOf: WorldTests.assets.appendingPathComponent("text.json"))
        return try! JSONDecoder().decode(Text.self, from: d).message
    }()
}
