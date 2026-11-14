import XCTest
@testable import PortolanCore

final class MarketTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func testLisbonMarketRecord() {
        let m = world.navigation.markets[0]
        XCTAssertEqual(m.economy, 780)
        XCTAssertEqual(m.support[0], 100)                       // Portuguese port
        XCTAssertEqual(world.navigation.drinks[m.drink], Drink(name: "럼주", price: 3))
        XCTAssertEqual(world.navigation.markets[1].economy, 770)
        XCTAssertEqual(world.navigation.drinks[world.navigation.markets[1].drink].name, "와인")
    }

    func testSupplyPrices() {
        let m = world.navigation.markets[0]                     // indices 52 (food, shot) and 51 (lumber)
        XCTAssertEqual(Supply.water.price(at: m), 0)
        XCTAssertEqual(Supply.food.price(at: m), 20)            // 20 * 102 / 100
        XCTAssertEqual(Supply.lumber.price(at: m), 90)          // 90 * 101 / 100
        XCTAssertEqual(Supply.shot.price(at: m), 122)           // 120 * 102 / 100
    }

    func testTavernMoodAndVolunteers() {
        var t = Tavern(market: world.navigation.markets[0], drinks: world.navigation.drinks, charm: 89)
        XCTAssertEqual(t.mood, 29)                              // 89 / 3
        XCTAssertLessThan(t.mood, Tavern.willingMood)
        XCTAssertEqual(t.treat(bottles: 4, charm: 89), 12)
        XCTAssertEqual(t.mood, 37)                              // 800 / 780 = 1 round, + 89 / 10
        XCTAssertEqual(t.volunteers(), 37)                      // min(37 * 780 / 500, 37)
        XCTAssertEqual(t.wage, 44)                              // 780 / 20 + 5
        XCTAssertEqual(t.bottlesAffordable(gold: 100), 33)
        XCTAssertEqual(t.bottlesAffordable(gold: 1000), 50)
        _ = t.treat(bottles: 50, charm: 89)
        XCTAssertEqual(t.mood, 100)
    }

    func testJoanHiresAndProvisionsInLisbon() {
        var v = Voyage.joanAfterPrologue(in: world)
        let m = v.market(in: world)
        var t = Tavern(market: m, drinks: world.navigation.drinks, charm: v.captain.charm)
        XCTAssertTrue(v.pay(t.treat(bottles: 4, charm: v.captain.charm)))
        XCTAssertEqual(v.gold, 988)
        XCTAssertEqual(v.hireable(at: t), 22)                   // purse: 988 / 44
        XCTAssertFalse(v.hire(23, at: t))
        XCTAssertTrue(v.hire(22, at: t))
        XCTAssertEqual(v.crew, 22)
        XCTAssertEqual(v.gold, 20)

        XCTAssertEqual(v.maxPurchase(.water, ship: 0, at: m), 80)
        XCTAssertTrue(v.buy(.water, barrels: 40, ship: 0, at: m))
        XCTAssertEqual(v.water, 400)                            // ten units per barrel
        XCTAssertEqual(v.gold, 20)
        XCTAssertEqual(v.maxPurchase(.food, ship: 0, at: m), 1)
        XCTAssertTrue(v.buy(.food, barrels: 1, ship: 0, at: m))
        XCTAssertEqual(v.food, 10)
        XCTAssertEqual(v.gold, 0)
        XCTAssertEqual(v.ships[0].freeCargo, 39)
    }

    func testSupplyPortKeepsLastMarket() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.arrive(at: world.ports[1])
        XCTAssertEqual(v.marketIndex, 1)
        v.arrive(at: world.ports[120])
        XCTAssertEqual(v.marketIndex, 1)
    }
}
