import XCTest
@testable import PortolanCore

final class EventTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func testDeserters() {
        XCTAssertEqual(Incidents.deserters(crew: 30, morale: 10), 4)       // 10 × 30 / 100 + 1
        XCTAssertEqual(Incidents.deserters(crew: 30, morale: 0), 7)
        XCTAssertEqual(Incidents.deserters(crew: 0, morale: 0), 0)
        XCTAssertEqual(Incidents.deserters(crew: 10, morale: 25), 1)       // −50 / 100 truncates to 0
        XCTAssertEqual(Incidents.deserters(crew: 30, morale: 50), 30)      // −8 read unsigned
    }

    func testStormDamage() {
        // Joan: seamanship 75, level 1 → min(10, 25 / 3 + 1) = 9, plus rand(2).
        XCTAssertEqual(Incidents.stormDamage(seamanship: 75, navLevel: 1, oceanGoing: true, roll: 1), 10)
        XCTAssertEqual(Incidents.stormDamage(seamanship: 75, navLevel: 10, oceanGoing: true, roll: 0), 6)
        XCTAssertEqual(Incidents.stormDamage(seamanship: 75, navLevel: 1, oceanGoing: false, roll: 0), 45)
        XCTAssertTrue(world.navigation.classes[5].oceanGoing)
        XCTAssertFalse(world.navigation.classes[18].oceanGoing)           // light galley
    }

    func testStarvedShipLosesSailors() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.ships[0].crew = 30
        v.ships[0].morale = 20
        v.endOfDay(in: world)                                             // no water or food: −16 twice
        XCTAssertEqual(v.ships[0].morale, 0)
        // (20 − 4) × 30 / 100 + 1 = 5 leave, then (20 − 0) × 25 / 100 + 1 = 6.
        XCTAssertEqual(v.ships[0].crew, 19)
    }

    func testStormRunsItsCourse() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.ships[0].crew = 30
        v.ships[0].hull = 30
        v.event = .storm
        v.weather.windFlags = 0x80
        for _ in 0..<40 where v.event != nil {
            v.rollWeather(in: world)
            v.eventFresh = false
        }
        XCTAssertNil(v.event)
        XCTAssertTrue(v.log.contains("폭풍입니다!\n키가 말을 듣지 않습니다."))
        XCTAssertLessThan(v.ships[0].maxHull, 27)
    }

    func testFlagshipWreckEndsTheGame() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.ships[0].hull = 1
        v.event = .storm
        v.eventAnnounced = true
        v.rollWeather(in: world)
        XCTAssertNotNil(v.gameOver)
    }

    func testWreckedOfficerShipIsRemovedAndCaptainKept() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.hireOfficer(85, salary: 10, in: world)                          // Miguel Lear: a named character
        v.hireOfficer(96, salary: 10, in: world)                          // Alonso Mendoza: generic face
        XCTAssertFalse(v.officers[0].generic)
        XCTAssertTrue(v.officers[1].generic)
        v.ships.append(Ship.built(class: 0, named: "A", in: world.navigation))
        v.ships.append(Ship.built(class: 0, named: "B", in: world.navigation))
        v.ships[1].hull = 1
        v.ships[2].hull = 1
        v.event = .storm
        v.eventAnnounced = true
        v.rollWeather(in: world)
        XCTAssertEqual(v.ships.count, 1)
        XCTAssertEqual(v.officers.map(\.name), ["미구엘 레아르"])
    }

    func testPosts() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.hireOfficer(85, salary: 10, in: world)
        v.hireOfficer(96, salary: 10, in: world)
        v.ships.append(Ship.built(class: 0, named: "A", in: world.navigation))
        XCTAssertFalse(v.appoint(0, to: .firstMate))                      // commands ship A (message 227)
        XCTAssertTrue(v.appoint(1, to: .firstMate))
        XCTAssertEqual(v.officer(holding: .firstMate)?.name, "아론소 멘도사")
    }
}

final class AllegianceTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    func testPortsChangeHandsAtSeventyFive() throws {
        let world = try World(assets: WorldTests.assets)
        var v = Voyage.joanAfterPrologue(in: world)
        XCTAssertEqual(v.markets[27].nation, 6)                  // Bordeaux, England 80
        XCTAssertEqual(v.markets[4].nation, 0)                   // Algiers, Portugal 0
        v.updateAllegiance()
        XCTAssertEqual(v.markets[27].nation, 3)
        XCTAssertEqual(v.markets[4].nation, 6)
        XCTAssertEqual(v.markets[0].nation, 0)                   // Lisbon keeps its 100
        v.markets[60].support[1] = 80
        v.markets[60].economy = 100
        v.updateAllegiance()
        XCTAssertEqual(v.markets[60].nation, 1)
        XCTAssertTrue(v.developing.contains(60))
        let before = v.markets[60].prices
        v.markets[60].economy = 150
        v.updateAllegiance()
        XCTAssertFalse(v.developing.contains(60))
        XCTAssertTrue(zip(before, v.markets[60].prices).allSatisfy { $1 - $0 >= 10 || $1 == 100 })
    }
}
