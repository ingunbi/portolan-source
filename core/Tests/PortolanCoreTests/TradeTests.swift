import XCTest
@testable import PortolanCore

final class TradeTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!
    var data: NavigationData { world.navigation }

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func testGoodsAndCategories() {
        XCTAssertEqual(data.goods.count, 46)
        XCTAssertEqual(data.goods[0], Good(name: "정향", category: 0))
        XCTAssertEqual(data.goods[16], Good(name: "돌소금", category: 2))
        XCTAssertEqual(data.goods[45], Good(name: "목재", category: 9))
        XCTAssertEqual(data.categories[4], "직물")
        XCTAssertEqual(data.zones.count, 13)
    }

    func testLisbonOffersAndPrices() {
        let m = data.markets[0]
        XCTAssertEqual(m.prices, [49, 50, 52, 50, 45, 54, 52, 51, 51, 51])
        let offers = Trade.offers(at: m, in: data)
        XCTAssertEqual(offers.map { data.goods[$0.good].name },
                       ["유제품", "어육", "올리브유", "와인", "면직물", "벨벳", "삼베", "염료", "무기", "돌소금"])
        func price(_ name: String, licensed: Bool = false) -> Int {
            Trade.buyPrice(offers.first { data.goods[$0.good].name == name }!, at: m, in: data, licensed: licensed)
        }
        XCTAssertEqual(price("와인"), 43)                 // 36 * 102 / 100 = 36, then * 12 / 10
        XCTAssertEqual(price("와인", licensed: true), 36)
        XCTAssertEqual(price("벨벳"), 91)                 // 80 * 95 / 100 = 76, then * 12 / 10
        XCTAssertEqual(price("돌소금"), 45)               // specialty: 38 * 102 / 100 = 38, then * 12 / 10
        XCTAssertEqual(Trade.sellPrice(15, at: m, in: data), 20)   // wine fetches 20 * 102 / 100
        XCTAssertEqual(Trade.sellPrice(16, at: m, in: data), 19)   // own specialty: 38 * 102 / 200
    }

    func testSmallEconomyHidesListings() {
        // Zone 0 lists dyes only where economy reaches 600; Algiers has 160.
        let algiers = data.markets[4]
        XCTAssertLessThan(algiers.economy, 600)
        XCTAssertFalse(Trade.offers(at: algiers, in: data).contains { data.goods[$0.good].name == "염료" })
    }

    func testBuyingInLisbonAndSellingInSeville() {
        var v = Voyage.joanAfterPrologue(in: world)
        let wine = v.offers(in: world).first { data.goods[$0.good].name == "와인" }!
        XCTAssertTrue(v.buy(wine, amount: 10, ship: 0, in: world))
        XCTAssertEqual(v.gold, 570)
        XCTAssertEqual(v.ships[0].holds, [CargoLot(good: 15, amount: 10)])
        XCTAssertEqual(v.market(in: world).prices[2], 52)  // 430 / 1280 rounds to no change

        v.gold = 100_000
        let velvet = v.offers(in: world).first { data.goods[$0.good].name == "벨벳" }!
        XCTAssertEqual(v.maxPurchase(velvet, ship: 0, in: world), 70)
        XCTAssertTrue(v.buy(velvet, amount: 70, ship: 0, in: world))
        XCTAssertEqual(v.gold, 100_000 - 70 * 91)
        // 6370 gold: velvet's category +4 (6370 / 1280), then every category +3.
        XCTAssertEqual(v.market(in: world).prices, [52, 53, 55, 53, 52, 57, 55, 54, 54, 54])
        XCTAssertEqual(v.ships[0].freeCargo, 0)

        v.arrive(at: world.ports[1])                       // Seville, also zone 0
        XCTAssertEqual(v.market(in: world).prices, [54, 54, 49, 51, 52, 53, 54, 50, 54, 45])
        XCTAssertEqual(v.salePrice(of: 24, in: world), 51)  // 50 * 102 / 100
        let before = v.gold
        XCTAssertTrue(v.sell(hold: 1, amount: 70, ship: 0, in: world))
        XCTAssertEqual(v.gold, before + 70 * 51)
        // 3570 gold: textiles -2 (3570 / 1270), then every category -3.
        XCTAssertEqual(v.market(in: world).prices, [51, 51, 46, 48, 47, 50, 51, 47, 51, 42])
        XCTAssertEqual(v.ships[0].holds, [CargoLot(good: 15, amount: 10)])
        XCTAssertEqual(data.markets[0].prices[4], 45)      // static data untouched
    }

    func testFiveHoldsLimit() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.gold = 10_000
        let offers = v.offers(in: world)
        for o in offers.prefix(5) { XCTAssertTrue(v.buy(o, amount: 1, ship: 0, in: world)) }
        XCTAssertEqual(v.ships[0].holds.count, 5)
        XCTAssertEqual(v.maxPurchase(offers[0], ship: 0, in: world), 0)
        XCTAssertFalse(v.buy(offers[5], amount: 1, ship: 0, in: world))
    }

    func testRejectedTransactionsLeavePurseCargoAndMarketUnchanged() {
        let original = Voyage.joanAfterPrologue(in: world)
        let salt = original.offers(in: world).first { $0.good == 16 }!
        func assertUnchanged(_ v: Voyage, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(v.gold, original.gold, file: file, line: line)
            XCTAssertEqual(v.ships[0].holds, original.ships[0].holds, file: file, line: line)
            XCTAssertEqual(v.ships[0].freeCargo, original.ships[0].freeCargo, file: file, line: line)
            XCTAssertEqual(v.market(in: world), original.market(in: world), file: file, line: line)
        }
        for n in [-1, 0, original.gold / original.price(of: salt, in: world) + 1,
                  original.ships[0].freeCargo + 1] {
            var v = original
            XCTAssertFalse(v.buy(salt, amount: n, ship: 0, in: world))
            assertUnchanged(v)
        }
        for price in [-100, 0, Int.max] {
            var v = original
            XCTAssertEqual(v.maxPurchase(salt, ship: 0, in: world, unitPrice: price), 0)
            XCTAssertFalse(v.buy(salt, amount: 1, ship: 0, in: world, unitPrice: price))
            assertUnchanged(v)
        }
        for ship in [-1, original.ships.count] {
            var v = original
            XCTAssertEqual(v.maxPurchase(salt, ship: ship, in: world), 0)
            XCTAssertFalse(v.buy(salt, amount: 1, ship: ship, in: world))
            XCTAssertFalse(v.sell(hold: 0, amount: 1, ship: ship, in: world))
            assertUnchanged(v)
        }
        var v = original
        let unavailable = Offer(good: 31, basePrice: 1)
        XCTAssertFalse(v.buy(unavailable, amount: 1, ship: 0, in: world))
        assertUnchanged(v)
    }

    func testSaleBoundsAndLastLotReleaseCargo() {
        var v = Voyage.joanAfterPrologue(in: world)
        let salt = v.offers(in: world).first { $0.good == 16 }!
        XCTAssertTrue(v.buy(salt, amount: 3, ship: 0, in: world))
        let gold = v.gold, holds = v.ships[0].holds, market = v.market(in: world), room = v.ships[0].freeCargo
        for n in [-1, 0, 4] { XCTAssertFalse(v.sell(hold: 0, amount: n, ship: 0, in: world)) }
        for hold in [-1, 1] { XCTAssertFalse(v.sell(hold: hold, amount: 1, ship: 0, in: world)) }
        XCTAssertEqual(v.gold, gold)
        XCTAssertEqual(v.ships[0].holds, holds)
        XCTAssertEqual(v.market(in: world), market)
        let price = v.salePrice(of: salt.good, in: world)
        XCTAssertTrue(v.sell(hold: 0, amount: 3, ship: 0, in: world))
        XCTAssertEqual(v.gold, gold + 3 * price)
        XCTAssertTrue(v.ships[0].holds.isEmpty)
        XCTAssertEqual(v.ships[0].freeCargo, room + 3)
    }
}
