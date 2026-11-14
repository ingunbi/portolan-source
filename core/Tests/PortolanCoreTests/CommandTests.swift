import XCTest
@testable import PortolanCore

/// The 편성 · 지휘 · 항해 commands and the harbour office (docs/re/commands.md).
final class CommandTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    /// Joan with Mendoza in command of a second ship.
    func twoShips() -> Voyage {
        var v = Voyage.joanAfterPrologue(in: world)
        v.hireOfficer(96, salary: 20, in: world)
        var s = Ship.built(class: 0, named: "발사", in: world.navigation)
        s.crew = 10
        s.morale = 40
        v.ships.append(s)
        return v
    }

    func testChangeCaptainMovesTheFlag() {
        var v = twoShips()
        let flag = v.ships[0].name
        XCTAssertTrue(v.changeCaptain(ship: 1, to: v.heroID))
        XCTAssertEqual(v.ships[0].name, "발사")                           // the hero's ship is the flagship
        XCTAssertEqual(v.ships[1].name, flag)
        XCTAssertEqual(v.officers[0].name, "아론소 멘도사")                // and Mendoza has the old one
    }

    func testCrewPoolAveragesMorale() {
        var v = twoShips()
        v.ships[0].crew = 30
        v.ships[0].morale = 80
        var pool = CrewPool()
        XCTAssertTrue(v.setCrew(ship: 0, to: 20, pool: &pool))
        XCTAssertEqual(pool, { var p = CrewPool(); p.sailors = 10; p.morale = 80; return p }())
        let cap = v.ships[1].crewCapacity
        XCTAssertGreaterThanOrEqual(cap, 15)
        XCTAssertTrue(v.setCrew(ship: 1, to: 15, pool: &pool))
        XCTAssertEqual(v.ships[1].morale, (40 * 10 + 80 * 5) / 15)
        XCTAssertEqual(pool.sailors, 5)
        XCTAssertFalse(v.setCrew(ship: 1, to: min(cap, 15 + 5) + 1, pool: &pool))
    }

    func testShareButtonsTradeAroundTheCircle() {
        var v = twoShips()
        XCTAssertEqual([v.ships[0].sailorShare, v.ships[0].watchShare], [50, 25])
        v.nudgeShare(ship: 0, row: 0, up: true)                            // 운항 takes from 파수
        XCTAssertEqual([v.ships[0].sailorShare, v.ships[0].watchShare], [51, 24])
        v.nudgeShare(ship: 0, row: 2, up: false)                           // 갑판 gives to 운항
        XCTAssertEqual([v.ships[0].sailorShare, v.ships[0].watchShare], [52, 24])
        v.ships[0].watchShare = 0
        v.nudgeShare(ship: 0, row: 0, up: true)                            // 파수 empty: 갑판 pays
        XCTAssertEqual([v.ships[0].sailorShare, v.ships[0].watchShare], [53, 0])
    }

    func testScuttleSparesTheFlagship() {
        var v = twoShips()
        XCTAssertFalse(v.scuttle(0))
        XCTAssertTrue(v.scuttle(1))
        XCTAssertEqual(v.ships.count, 1)
        XCTAssertFalse(v.scuttle(0))
        XCTAssertEqual(v.officers.count, 1)                                // the captain stays aboard
    }

    func testCargoMovesInWholeBarrels() {
        var v = twoShips()
        v.ships[0].water = 205
        v.ships[1].water = 37
        XCTAssertTrue(v.moveCargo(.water, from: 0, to: 1, amount: 5))
        XCTAssertEqual([v.ships[0].water, v.ships[1].water], [150, 80])   // the tenths are lost
        v.ships[0].holds = [CargoLot(good: 3, amount: 12)]
        XCTAssertTrue(v.moveCargo(.good(3), from: 0, to: 1, amount: 12))
        XCTAssertTrue(v.ships[0].holds.isEmpty)
        XCTAssertEqual(v.ships[1].holds, [CargoLot(good: 3, amount: 12)])
        XCTAssertFalse(v.moveCargo(.good(3), from: 1, to: 0, amount: 13))
    }

    func testFormationAndPay() {
        var v = twoShips()
        v.hireOfficer(85, salary: 30, in: world)
        v.ships.append(Ship.built(class: 0, named: "둘째", in: world.navigation))
        XCTAssertTrue(v.reorderShips([2, 1]))
        XCTAssertEqual(v.ships.map(\.name).suffix(2), ["둘째", "발사"])
        XCTAssertEqual(v.officers[1].name, "아론소 멘도사")                // captains travel with ships

        let k = 1
        let before = v.officers[k].loyalty
        XCTAssertEqual(v.raisePay(officer: k, to: 10), "그 금액으로는 어림도 없소.")
        XCTAssertEqual(v.raisePay(officer: k, to: 75), "감사합니다.")
        XCTAssertEqual(v.officers[k].salary, 70)
        XCTAssertEqual(v.officers[k].loyalty, min(100, before + 11))
        v.officers[k].loyalty = 80
        XCTAssertEqual(v.raisePay(officer: k, to: 500), "그런 걱정은 하지 않으셔도 됩니다.")
    }

    func testAnchoredFleetLetsTheDaysPass() {
        var v = twoShips()
        v.ships[0].crew = 20
        v.ships[0].water = 1000
        v.ships[0].food = 1000
        v.sail = 0
        let (x, y, day) = (v.x, v.y, v.day)
        v.tick(0.01, in: world)
        XCTAssertEqual(v.day, day)                                        // furled sails: the clock stops
        XCTAssertEqual(v.toggleAnchor(), "정선하겠습니다.")
        for _ in 0..<400 { v.tick(0.5, in: world) }
        XCTAssertGreaterThan(v.day, day)
        XCTAssertEqual(v.x, x)
        XCTAssertEqual(v.y, y)
        XCTAssertEqual(v.toggleAnchor(), "이동하겠습니다.")
        XCTAssertFalse(v.anchored)
    }

    func testAshoreHalvesRations() {
        var v = twoShips()
        v.ships[0].crew = 40
        let atSea = v.dailyWater
        v.waitAshore()
        XCTAssertLessThan(v.dailyWater, atSea)
        XCTAssertEqual(v.dailyWater, 40 * 100 / 200 + 1 + 10 * 100 / 200 + 1)
        v.leaveCoast()
        XCTAssertFalse(v.ashore || v.anchored)
    }

    func testEmergencyRepairUsesLumber() {
        var v = twoShips()
        v.ships[0].hull -= 12
        v.ships[1].lumber = 2
        v.ships[0].lumber = 1
        XCTAssertEqual(v.emergencyRepair(ship: 0, part: 1, lumber: 5, in: world), "수리할 곳이 없습니다.")
        XCTAssertEqual(v.emergencyRepair(ship: 0, part: 0, lumber: 9, in: world), "수리를 마쳤습니다.")
        XCTAssertEqual(v.ships[0].hull, v.ships[0].maxHull)                // (12 + 4) / 5 = 3 barrels
        XCTAssertEqual(v.ships[0].lumber + v.ships[1].lumber, 0)
        XCTAssertEqual(v.emergencyRepair(ship: 0, part: 0, lumber: 1, in: world), "이 배는 손상된 곳이 없습니다.")
    }

    func testItems() {
        var v = twoShips()
        v.items = [41, 42, 43, 23, 21]
        v.epidemic = true
        XCTAssertEqual(v.useItem(41), ["쥐들을 퇴치했습니다."])
        XCTAssertFalse(v.epidemic || v.items.contains(41))
        v.event = .storm
        XCTAssertEqual(v.useItem(42), ["폭풍우가 가라앉았습니다."])
        XCTAssertNil(v.event)
        XCTAssertTrue((10...15).contains(v.stormShelter))
        XCTAssertEqual(v.useItem(43), ["맛있다."])
        v.tick = 28
        XCTAssertEqual(v.useItem(23), ["9시 20분"])
        v.captain.skills |= 0x10
        v.x = 2039                                                         // (x + 1981) mod 2160 = 1860: 300 west
        v.y = 640 - 57 * 2 * 3                                             // 48° north at 2° steps
        XCTAssertEqual(v.useItem(21), ["북위 48도, 서경 50도"])
    }

    func testSightRange() {
        var v = twoShips()
        v.ships[0].crew = 30                                               // 7 on watch
        XCTAssertEqual(v.sightRange, 7)
        v.items.append(24)
        XCTAssertEqual(v.sightRange, 14)
        v.ships[0].crew = 4
        v.ships[1].crew = 4
        v.items = []
        XCTAssertEqual(v.sightRange, 2)
    }

    func testDepartureCheck() {
        var v = twoShips()
        v.ships[0].crew = 20
        v.ships[0].water = 0
        XCTAssertEqual(v.departureCheck().line, "이대로는 굶어 죽고 맙니다.")
        v.ships[0].water = 3000
        v.ships[0].food = 3000
        XCTAssertEqual(v.departureCheck().line, "식량은 약 100일 치입니다.\n출항할까요?")
        v.ships[1].sailorShare = 0
        XCTAssertFalse(v.departureCheck().ok)
    }

    func testDockInTheCapitals() {
        var v = twoShips()
        let lisbon = v.marketIndex
        XCTAssertTrue(v.hasDock(lisbon))
        XCTAssertFalse(v.hasDock(30))
        v.ships[1].lumber = 7
        XCTAssertEqual(v.storeShip(1, at: lisbon), "그럼, 맡아 두겠습니다.")
        XCTAssertEqual(v.ships.count, 1)
        XCTAssertEqual(v.docked(at: lisbon).map(\.ship.crew), [0])
        XCTAssertEqual(v.docked(at: lisbon)[0].ship.lumber, 7)             // cargo stays aboard
        XCTAssertEqual(v.bringOut(0, at: lisbon), "예항해 두겠습니다.")
        XCTAssertEqual(v.ships.count, 2)
        XCTAssertTrue(v.dock.isEmpty)
        _ = v.storeShip(1, at: lisbon)
        v.ships[0].crew = 25
        XCTAssertEqual(v.exchangeShip(0, with: 0, at: lisbon), "교체해 두겠습니다.")
        XCTAssertEqual(v.ships[0].name, "발사")
        XCTAssertEqual(v.ships[0].crew, min(25, v.ships[0].crewCapacity))
        XCTAssertEqual(v.docked(at: lisbon)[0].ship.crew, 0)
    }

    func testShipsWheelSetsAnEightWayHeading() {
        var v = twoShips()
        v.toggleAnchor()
        v.steer(toward: 2)                                                 // east
        XCTAssertEqual(v.heading8, 2)
        XCTAssertFalse(v.anchored)
        XCTAssertEqual(v.sail, Voyage.maxSail)
        v.steer(toward: 5)
        XCTAssertEqual(v.heading8, 5)
        v.waitAshore()
        v.steer(toward: 0)
        XCTAssertEqual(v.heading8, 5)                                      // ignored ashore (0x20A00)
    }

    func testRetirementAndEmptyShips() {
        var v = twoShips()
        v.year = 1553
        v.month = 11
        v.dayOfMonth = 30
        v.newDay()
        XCTAssertEqual(v.year, 1554)
        XCTAssertEqual(v.gameOverCode, 0x10)                               // [0x56E] > 52

        var w = twoShips()
        for i in w.ships.indices { w.ships[i].crew = 0 }
        w.endOfDay(in: world)
        XCTAssertEqual(w.gameOverCode, 0x19)
    }

    func testNamingASupplyPort() {
        var v = twoShips()
        let other = v.memory.string(DS.port + DS.portSize * 0 + 4, max: 14)
        XCTAssertFalse(v.renamePort(100, to: other, in: world).hasPrefix("조안항"), "a taken name is refused")
        XCTAssertTrue(v.renamePort(100, to: "조안항", in: world).hasPrefix("조안항"))
        XCTAssertEqual(v.memory.string(DS.port + DS.portSize * 100 + 4, max: 14), "조안항")
        XCTAssertEqual(v.renamePort(5, to: "x", in: world), "")
    }
}
