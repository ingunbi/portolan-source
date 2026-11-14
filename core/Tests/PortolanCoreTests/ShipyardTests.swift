import XCTest
@testable import PortolanCore

final class ShipyardTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!
    var data: NavigationData { world.navigation }

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func testRegionalListsAndIndustry() {
        XCTAssertEqual(data.shipRegions[0].map { data.classes[$0].name },
                       ["발사", "경갤리", "카라벨 라티나", "브리간틴", "플랜더스 갤리", "나오", "카락", "갤리온"])
        XCTAssertEqual(data.classes[10].requiredIndustry, 800)      // galleon
        XCTAssertEqual(data.markets[0].industry, 770)
        XCTAssertEqual(data.commonShips.count, 18)
    }

    func testLisbonStockOnNewGame() {
        let v = Voyage.joanAfterPrologue(in: world)
        let stock = v.shipyardStock
        XCTAssertEqual(stock.count, 5)
        let regional = Array(data.shipRegions[0].prefix(7))                     // no galleon at industry 770
        XCTAssertTrue(stock.prefix(3).allSatisfy(regional.contains))
        XCTAssertTrue(stock.suffix(2).allSatisfy(data.commonShips.contains))
    }

    func testPricesInLisbon() {
        let v = Voyage.joanAfterPrologue(in: world)
        XCTAssertEqual(Shipyard.priceLevel(v.market(in: world)), 50)            // 505 / 10
        XCTAssertEqual(v.askingPrice(class: 5, in: world), 2400)                // 10 * (240 * 100 / 100)
        XCTAssertEqual(v.askingPrice(class: 10, in: world), 60000)
        XCTAssertEqual(v.shipValue(0, in: world), 2400)                         // 10 * (192 + 48)
        XCTAssertEqual(v.haggleFloor(2400), 1972)                               // 2400 * (500 - 89) / 500
    }

    func testTradeInHermesForANewCaravel() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.ships[0].crew = 12
        v.ships[0].water = 300
        v.shipyardStocks = [ShipyardStock(port: 0, classes: [5, 7])]
        XCTAssertEqual(v.buyShip(slot: 0, offer: 1972, tradeIn: nil, name: "산타 마리아", in: world), .noCaptain)
        XCTAssertEqual(v.buyShip(slot: 1, offer: 2300, tradeIn: 0, name: "x", in: world), .short) // budget 1000 + 1200
        XCTAssertEqual(v.buyShip(slot: 0, offer: 1972, tradeIn: 0, name: "산타 마리아", in: world), .bought)
        XCTAssertEqual(v.gold, 1000 + 1200 - 1972)
        XCTAssertEqual(v.ships.count, 1)
        XCTAssertEqual(v.ships[0].name, "산타 마리아")
        XCTAssertEqual(v.ships[0].hull, 27)
        XCTAssertEqual([v.ships[0].crew, v.ships[0].water], [12, 300])
        XCTAssertEqual(v.shipyardStock, [7])
    }

    func testLowballCanBanTheBuyer() {
        var outcomes = Set<ShipDeal>()
        for seed in 1...40 {
            var v = Voyage.joanAfterPrologue(in: world)
            v.rng = GameRandom(seed: UInt32(seed))
            v.shipyardStocks = [ShipyardStock(port: 0, classes: [5])]
            let r = v.buyShip(slot: 0, offer: 1971, tradeIn: 0, name: "x", in: world)
            outcomes.insert(r)
            if r == .banned {
                XCTAssertTrue(v.shipyardBanned)
                v.arrive(at: world.ports[0], in: world)
                XCTAssertFalse(v.shipyardBanned)
            }
        }
        XCTAssertEqual(outcomes, [.refused, .banned])
    }

    func testRepairCost() {
        var v = Voyage.joanAfterPrologue(in: world)
        XCTAssertEqual(Shipyard.repairCost(v.ships[0], in: data), 0)
        XCTAssertFalse(v.repair(0, in: world))
        v.ships[0].hull = 20
        v.ships[0].rudder = 80
        XCTAssertEqual(Shipyard.repairCost(v.ships[0], in: data), 340)          // 20 * (7 + 10)
        XCTAssertTrue(v.repair(0, in: world))
        XCTAssertEqual([v.ships[0].hull, v.ships[0].rudder, v.gold], [27, 90, 660])
    }

    func testYardRemembersThreePorts() {
        var v = Voyage.joanAfterPrologue(in: world)
        let lisbon = v.shipyardStock
        v.arrive(at: world.ports[1], in: world)
        v.arrive(at: world.ports[0], in: world)
        XCTAssertEqual(v.shipyardStock, lisbon)
        for p in [1, 2, 3] { v.arrive(at: world.ports[p], in: world) }
        XCTAssertFalse(v.shipyardStocks.contains { $0.port == 0 })
        v.arrive(at: world.ports[120], in: world)                              // supply port: no yard
        XCTAssertEqual(v.shipyardStocks.first?.port, 3)
    }

    func testSellingNeedsAnotherShip() {
        var v = Voyage.joanAfterPrologue(in: world)
        XCTAssertEqual(v.sellShip(0, in: world), .refused)
        v.ships.append(Ship.built(class: 0, named: "b", in: data))
        XCTAssertEqual(v.sellShip(1, in: world), .bought)
        XCTAssertEqual(v.gold, 1000 + 600)                                      // balsa value 1200 / 2
        XCTAssertEqual(v.ships.count, 1)
    }
}

final class CannonTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    func testLisbonCannons() throws {
        let world = try World(assets: WorldTests.assets)
        var v = Voyage.joanAfterPrologue(in: world)
        XCTAssertEqual(world.navigation.cannons.map(\.name),
                       ["캐논", "데미캐논", "캐논페드로", "컬버린", "데미컬버린", "세이커", "카로네이드"])
        XCTAssertEqual(v.cannonTypes(in: world), [1, 2, 3, 4, 5, 6])          // (780 + 770) / 200 + 1, capped at 6
        XCTAssertEqual(v.ships[0].gunCapacity, 10)
        XCTAssertEqual(v.maxCannons(6, ship: 0), 10)
        XCTAssertTrue(v.buyCannons(6, count: 4, ship: 0, in: world))           // sakers, 5 each
        XCTAssertEqual(v.gold, 980)
        XCTAssertEqual(v.maxCannons(6, ship: 0), 6)
        XCTAssertEqual(v.maxCannons(2, ship: 0), 10)
        XCTAssertTrue(v.buyCannons(2, count: 2, ship: 0, in: world))           // demi-cannons replace them
        XCTAssertEqual([v.ships[0].guns, v.ships[0].gunType, v.gold], [2, 2, 820])
        XCTAssertFalse(v.buyCannons(1, count: 3, ship: 0, in: world))          // 1080 gold
    }
}

final class ShipBuildingTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func testLisbonBuildTerms() {
        let m = world.navigation.markets[0], d = world.navigation
        XCTAssertEqual(Shipyard.materialCount(class: 5, at: m), 4)          // (770 − 500) / 200 + 3
        XCTAssertEqual(Shipyard.materialCount(class: 22, at: m), 6)
        XCTAssertEqual(Shipyard.builtHull(class: 5, material: 3, in: d), 33) // 11 × 30 / 10
        XCTAssertEqual(Shipyard.buildPrice(class: 5, material: 2, at: m, in: d), 2400)
        XCTAssertEqual(Shipyard.buildPrice(class: 5, material: 0, at: m, in: d), 1920)
        XCTAssertEqual(Shipyard.buildDays(class: 5, at: m, in: d), 25)        // (100 − 15) × 30 / 100
        XCTAssertEqual(Shipyard.figureheadPrice(3), 4500)
    }

    func testOrderBuildAndCollect() {
        var v = Voyage.joanAfterPrologue(in: world)
        let c = Shipyard.buildable(at: v.market(in: world), in: world.navigation).first!
        let cls = world.navigation.classes[c]
        v.gold = 100_000
        let price = Shipyard.buildPrice(class: c, material: 1, at: v.market(in: world), in: world.navigation)
        XCTAssertEqual(v.orderShip(class: c, material: 1, crew: cls.minCrew, guns: 0, offer: price, name: "새배", in: world), .bought)
        XCTAssertEqual(v.orderShip(class: c, material: 1, crew: cls.minCrew, guns: 0, offer: price, name: "또", in: world), .busy)
        XCTAssertEqual(v.orderHere?.ship.cargoCapacity, cls.capacity - cls.minCrew)
        XCTAssertEqual(v.takeDelivery(), .notReady)
        v.orders[0].daysLeft = 0
        XCTAssertEqual(v.takeDelivery(), .noCaptain)
        v.hireOfficer(85, salary: 10, in: world)
        XCTAssertEqual(v.takeDelivery(), .bought)
        XCTAssertEqual(v.ships.count, 2)
        XCTAssertEqual(v.ships[1].maxHull, 9 * cls.hull / 10)
    }

    func testRefit() {
        var v = Voyage.joanAfterPrologue(in: world)
        XCTAssertTrue(v.refit(0, crew: 40, guns: 20, in: world))             // caravel latina 120: cargo 60
        XCTAssertEqual(v.ships[0].cargoCapacity, 60)
        XCTAssertEqual(v.gold, 760)                                           // 1000 − 240
        XCTAssertFalse(v.refit(0, crew: 41, guns: 0, in: world))             // more than 10 × 4 berths
    }
}

final class HaggleTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func testWineInLisbon() {
        var v = Voyage.joanAfterPrologue(in: world)
        let wine = v.offers(in: world).first { world.navigation.goods[$0.good].name == "와인" }!
        XCTAssertEqual(v.price(of: wine, in: world), 43)
        XCTAssertEqual(Trade.haggleFloor(price: 43, rank: 0), 40)
        XCTAssertEqual(v.bargain(wine, offer: 42, in: world), .accepted(42))
        XCTAssertEqual(v.bargain(wine, offer: 30, in: world), .settled(40))   // Joan has the knack
        v.captain.skills = 0
        XCTAssertEqual(v.bargain(wine, offer: 30, in: world), .counter(42))
        XCTAssertTrue(v.buy(wine, amount: 2, ship: 0, in: world, unitPrice: 40))
        XCTAssertEqual(v.gold, 920)
    }
}
