import XCTest
@testable import PortolanCore

/// Expected values are worked by hand from the disassembly, not from this code.
final class NavigationTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!
    var nav: NavigationData { world.navigation }

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func caravel(crew: Int = 20, water: Int = 200, food: Int = 200) -> Ship {
        Ship(class: 5, in: nav, crew: crew, water: water, food: food)
    }

    func testRandomMatchesCLibrary() {
        var r = GameRandom(seed: 1)
        XCTAssertEqual(r.next(), 16838)          // ANSI C reference rand() after srand(1)
        XCTAssertEqual(r.next(), 5758)
    }

    func testTablesFromExecutable() {
        XCTAssertEqual(nav.sailTable[0], [10, 8, 10, 9, 9, 8, 10, 10])
        XCTAssertEqual(nav.sailTable[4], [4, 6, 6, 7, 7, 8, 9, 10])
        XCTAssertEqual(nav.classes.count, 25)
        XCTAssertEqual(nav.classes[5].name, "카라벨 라티나")
        XCTAssertEqual(nav.classes[10].capacity, 800)
        XCTAssertTrue(nav.classes[19].oars)
        XCTAssertEqual(nav.windSummer.count, 450)
    }

    func testZoneOfLisbon() {
        XCTAssertEqual(Navigation.zone(x: 120, y: 358), 4 * 30 + 1)
    }

    func testCaravelTailwind() {
        // a = 8*75*4/150 = 16; load 60/120 -> trim 130 -> 20; level 1 -> 22; seamanship 75 -> 22
        let s = Navigation.fleetSpeed(ships: [caravel()], captain: .joan, heading: 2, windDir: 2, windStrength: 4, data: nav)
        XCTAssertEqual(s, 22)
    }

    func testCaravelHeadwindUsesRudder() {
        // row 4 lateen = 8 -> same 22, then 22 * rudder 90 / 100 = 19
        let s = Navigation.fleetSpeed(ships: [caravel()], captain: .joan, heading: 2, windDir: 6, windStrength: 4, data: nav)
        XCTAssertEqual(s, 19)
    }

    func testSquareRigSuffersUpwind() {
        var galleon = Ship(class: 10, in: nav, crew: 60, water: 100, food: 100)
        galleon.sailorShare = 100
        let down = Navigation.fleetSpeed(ships: [galleon], captain: .joan, heading: 2, windDir: 2, windStrength: 5, data: nav)
        let up = Navigation.fleetSpeed(ships: [galleon], captain: .joan, heading: 2, windDir: 6, windStrength: 5, data: nav)
        XCTAssertGreaterThan(down, up * 2)
    }

    func testFleetMovesAtSlowestShipAndAtLeastTwo() {
        let slow = Ship(class: 5, in: nav, crew: 2, water: 0, food: 0)   // undermanned
        let s = Navigation.fleetSpeed(ships: [caravel(), slow], captain: .joan, heading: 2, windDir: 2, windStrength: 4, data: nav)
        XCTAssertEqual(s, 2)
    }

    func testCalmStopsSailingShips() {
        let s = Navigation.fleetSpeed(ships: [caravel()], captain: .joan, heading: 2, windDir: 2, windStrength: 0, data: nav)
        XCTAssertEqual(s, 0)
    }

    func testOarsKeepAGalleyMovingInCalm() {
        var galley = Ship(class: 18, in: nav, crew: 30, water: 100, food: 100)
        galley.sailorShare = 100
        let s = Navigation.fleetSpeed(ships: [galley], captain: .joan, heading: 2, windDir: 2, windStrength: 0, data: nav)
        XCTAssertGreaterThan(s, 2)
    }

    func testDailyUseAndMorale() {
        XCTAssertEqual(Navigation.dailyUse(crew: 20, ration: 100), 21)
        XCTAssertEqual(Navigation.dailyUse(crew: 20, ration: 100, ashore: true), 11)
        XCTAssertEqual(Navigation.moraleLoss(leadership: 78, ration: 100), -1)   // (100-15-100)/10
        XCTAssertEqual(Navigation.moraleLoss(leadership: 78, ration: 50), 7)     // (100-15-50)/5
    }

    func testWindRollKeepsZoneDirection() {
        var rng = GameRandom(seed: 7)
        for _ in 0..<200 {
            let w = Navigation.roll(windByte: 0x14, currentByte: 0x1B, rng: &rng)   // east 4, current south 3
            XCTAssertTrue([1, 2, 3].contains(w.windDir))
            XCTAssertTrue([4, 5].contains(w.windStrength))
            XCTAssertEqual(w.currentDir, 3)
            XCTAssertEqual(w.currentStrength, 3)
        }
    }

    func testOneDayIs72TicksAndConsumesSupplies() throws {
        let lisbon = try XCTUnwrap(world.ports.first { $0.name == "리스본" })
        var v = Voyage(at: lisbon, in: world, ships: [caravel()])
        v.heading = .pi                                   // west, open Atlantic
        v.sail = 1
        for _ in 0..<Navigation.ticksPerDay { v.gameTick(in: world) }
        XCTAssertEqual(v.day, 1)
        XCTAssertEqual(v.water, 200 - 21)
        XCTAssertEqual(v.food, 200 - 21)
        XCTAssertEqual(v.month, 3)
        XCTAssertEqual(v.dayOfMonth, 1)
    }

    func testDistancePerDayMatchesSpeed() {
        var v = Voyage(x: 40.5, y: 400.5, ships: [caravel()])
        v.heading = .pi
        v.sail = 1
        let x0 = v.x
        var sum = 0
        for _ in 0..<Navigation.ticksPerDay {
            v.weather = Weather(windDir: 6, windStrength: 4, currentDir: 0, currentStrength: 0)
            v.speedUnits = 0
            let before = v.x
            v.gameTick(in: world)
            sum += v.speedUnits
            XCTAssertLessThan(v.x, before + 0.0001)
        }
        let travelled = x0 - v.x
        XCTAssertEqual(travelled, Double(sum) / 60, accuracy: 0.01)
    }

    func testStarvingShipBorrowsFromFleet() {
        var v = Voyage(x: 40.5, y: 400.5, ships: [caravel(water: 0, food: 0), caravel()])
        v.endOfDay(in: world)
        XCTAssertEqual(v.ships[0].water, 0)
        XCTAssertEqual(v.ships[1].water, 200 - 21 - 21)
        XCTAssertEqual(v.ships[0].morale, 100)
    }

    func testEmptyFleetLosesMorale() {
        var v = Voyage(x: 40.5, y: 400.5, ships: [caravel(water: 0, food: 0)])
        v.endOfDay(in: world)
        XCTAssertEqual(v.ships[0].morale, 100 - 16 - 16)
    }

    func testSeasonSwitchesInMarchAndSeptember() {
        var v = Voyage(x: 40.5, y: 400.5, ships: [caravel()])
        v.month = 7
        v.dayOfMonth = 30
        v.summerWinds = true
        v.endOfDay(in: world)
        XCTAssertEqual(v.month, 8)
        XCTAssertFalse(v.summerWinds)
    }
}
