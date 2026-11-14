import XCTest
@testable import PortolanCore

/// The MONSTER.DAT sea events (docs/re/sea_events.md).
final class SeaEventTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func twoShips() -> Voyage {
        var v = Voyage.joanAfterPrologue(in: world)
        v.hireOfficer(96, salary: 20, in: world)
        var s = Ship.built(class: 0, named: "발사", in: world.navigation)
        s.crew = 20
        s.morale = 50
        v.ships.append(s)
        v.ships[0].crew = 40
        v.ships[0].morale = 95
        return v
    }

    func testPointsAndRecords() {
        let v = Voyage.joanAfterPrologue(in: world)
        XCTAssertEqual(world.seaEventPoints.count, 40)
        XCTAssertEqual(world.seaEventPoints.suffix(10).filter { $0.x == 0 && $0.y == 0 }.count, 10)  // 30..39 empty
        XCTAssertEqual(v.seaEventPoints.filter { $0.x != 0 }.count, 10)
        XCTAssertEqual(v.memory[0xFD0], 0)
        XCTAssertFalse((world.seaEventPoints.prefix(30) + v.seaEventPoints).contains { $0.type == 7 })   // never placed
    }

    func testSteppingOnAPointFiresOnceAndRefills() {
        var v = twoShips()
        let p = v.seaEventPoints[0]
        v.x = Double(p.x) + 0.5
        v.y = Double(p.y) + 0.5
        XCTAssertTrue(v.checkSeaEvents(from: (p.x - 1, p.y), in: world))
        XCTAssertEqual(v.seaAlarms, [p.type])
        XCTAssertEqual(v.memory[0xFD0], 1)
        let next = world.seaEventPoints[0]
        XCTAssertEqual(v.seaEventPoints[0].x, next.x)
        XCTAssertEqual(v.seaEventPoints[0].type, next.type)
        XCTAssertFalse(v.checkSeaEvents(from: (p.x, p.y), in: world))                            // consumed
    }

    func testEffects() {
        var v = twoShips()
        _ = v.applySeaEvent(0)
        XCTAssertEqual(v.ships.map(\.crew), [30, 15])
        let courage = v.captain.courage
        _ = v.applySeaEvent(1)
        XCTAssertEqual(v.captain.courage, max(0, courage - 10))
        _ = v.applySeaEvent(4)
        XCTAssertEqual(v.ships.map(\.morale), [100, 60])
        _ = v.applySeaEvent(7)
        XCTAssertEqual(v.ships.map(\.morale), [90, 50])
        v.ships[1].holds = [CargoLot(good: 3, amount: 9)]
        v.ships[1].water = 70
        _ = v.applySeaEvent(6)
        XCTAssertTrue(v.ships[1].holds.isEmpty)
        XCTAssertEqual(v.ships[1].water, 70)
        let sail = v.ships[1].sail, hull = v.ships[1].hull
        XCTAssertTrue(v.applySeaEvent(5))
        XCTAssertEqual(v.ships[1].sail, sail / 2)
        XCTAssertTrue(v.applySeaEvent(8))
        XCTAssertEqual(v.ships[1].hull, hull / 2)
        v.captain.luck = 20
        _ = v.applySeaEvent(9)
        XCTAssertEqual(v.captain.luck, 0)
        XCTAssertTrue(v.applySeaEvent(2))
        XCTAssertEqual(v.ships.count, 1)
        XCTAssertEqual(v.officers.count, 1)                                                      // the captain stays
        XCTAssertFalse(v.applySeaEvent(2))                                                       // the hero alone: silent
        XCTAssertFalse(v.applySeaEvent(5))
        XCTAssertFalse(v.applySeaEvent(8))
    }

    func testFortyEventsAtMost() {
        var v = twoShips()
        for _ in 0..<60 {
            guard let i = v.seaEventPoints.firstIndex(where: { $0.x != 0 || $0.y != 0 }) else { break }
            v.fireSeaEvent(slot: i, in: world)
        }
        XCTAssertEqual(v.memory[0xFD0], 40)
        XCTAssertTrue(v.seaEventPoints.allSatisfy { $0.x == 0 && $0.y == 0 })
    }
}
