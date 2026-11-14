import XCTest
@testable import PortolanCore

final class RoutePlanningTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    private func ocean(land: [(Int, Int)] = [], ports: [Harbor] = []) throws -> World {
        let real = try World(assets: WorldTests.assets)
        var tiles = [UInt8](repeating: World.Terrain.sea.rawValue, count: World.width * World.height)
        for (x, y) in land { tiles[y * World.width + x] = World.Terrain.land.rawValue }
        return World(tiles: tiles, ports: ports, navigation: real.navigation)
    }

    private func graph(_ points: [(Int, Int)], links: [Int: Int] = [:]) -> RouteGraph {
        var bytes = [UInt8](repeating: 0, count: points.count * 16)
        func word(_ value: Int, at offset: Int) {
            bytes[offset] = UInt8(value & 255)
            bytes[offset + 1] = UInt8((value >> 8) & 255)
        }
        for (index, point) in points.enumerated() {
            let offset = index * 16
            word(point.0, at: offset)
            word(point.1, at: offset + 2)
            for edge in 0..<4 { word(edge == 0 ? links[index] ?? 0xFFFF : 0xFFFF, at: offset + 4 + edge * 2) }
            bytes[offset + 12] = 1
        }
        return RouteGraph(data: bytes)
    }

    func testSeaPathRejectsLandAndInvalidCoordinates() throws {
        let world = try ocean(land: [(41, 100)])
        XCTAssertNil(world.seaPath(from: (40.5, 100.5), to: (41.5, 100.5)), "An adjacent land tile is not a destination")
        XCTAssertNil(world.seaPath(from: (.nan, 100), to: (50, 100)))
        XCTAssertNil(world.seaPath(from: (40, 100), to: (.infinity, 100)))
        XCTAssertNil(world.seaPath(from: (40, -0.5), to: (50, 100)))
        XCTAssertNil(world.seaPath(from: (40, 100), to: (50, Double(World.height))))
        XCTAssertNil(world.seaPath(from: (40, 100), to: (50, 100), radius: -1))
    }

    func testNarrowBerthEndsAtNavigableApproach() throws {
        let world = try ocean(land: [(51, 100), (51, 101)])
        let path = try XCTUnwrap(world.seaPath(from: (40.5, 100.5), to: (50.5, 100.5)))
        let end = try XCTUnwrap(path.last)
        XCTAssertTrue(world.fleetFits(x: end.0, y: end.1))
        XCTAssertLessThanOrEqual(abs(end.0 - 50.5), 1)
        XCTAssertLessThanOrEqual(abs(end.1 - 100.5), 1)
        XCTAssertTrue(path.allSatisfy { world.fleetFits(x: $0.0, y: $0.1) })
    }

    func testAlreadyReachedAndWrappedDestinationsHaveValidPaths() throws {
        let world = try ocean()
        let same = try XCTUnwrap(world.seaPath(from: (40.5, 100.5), to: (40.5, 100.5)))
        XCTAssertEqual(same.count, 1)
        XCTAssertEqual(same[0].0, 40.5)
        let wrapped = try XCTUnwrap(world.seaPath(from: (-1.5, 100.5), to: (2.5, 100.5), radius: 8))
        XCTAssertEqual(wrapped.last?.0, 2.5)
        XCTAssertTrue(wrapped.allSatisfy { $0.0 >= 0 && $0.0 < Double(World.width) })
    }

    func testEmptyGraphAndAshoreOrdersKeepExistingCourse() throws {
        let port = Harbor(id: 0, name: "목적항", x: 80, y: 100)
        var world = try ocean(ports: [port])
        var voyage = Voyage.joanAfterPrologue(in: world)
        voyage.x = 40.5
        voyage.y = 100.5
        voyage.setCourse(x: 50.5, y: 100.5)
        voyage.route = [[60.5, 100.5]]
        world.routes = RouteGraph(data: [])
        XCTAssertFalse(voyage.autoSail(to: port, in: world))
        world.routes = graph([(40, 100)])
        voyage.ashore = true
        XCTAssertFalse(voyage.autoSail(to: port, in: world, anyWaters: true))
        XCTAssertEqual(voyage.waypoint?.x, 50.5)
        XCTAssertEqual(voyage.route, [[60.5, 100.5]])
    }

    func testUnreachableApproachDoesNotReplaceCourse() throws {
        let port = Harbor(id: 0, name: "막힌 항구", x: 80, y: 100)
        let ring = (97...103).flatMap { y in (77...83).compactMap { x in (x == 80 && y == 100) ? nil : (x, y) } }
        var world = try ocean(land: ring, ports: [port])
        world.routes = graph([(40, 100)])
        var voyage = Voyage.joanAfterPrologue(in: world)
        voyage.x = 40.5
        voyage.y = 100.5
        voyage.setCourse(x: 50.5, y: 100.5)
        voyage.route = [[60.5, 100.5]]
        XCTAssertFalse(voyage.autoSail(to: port, in: world, anyWaters: true))
        XCTAssertEqual(voyage.waypoint?.x, 50.5)
        XCTAssertEqual(voyage.route, [[60.5, 100.5]])
    }

    func testChartedWaterRestrictionIsPreserved() throws {
        let port = Harbor(id: 0, name: "목적항", x: 80, y: 100)
        var world = try ocean(ports: [port])
        world.routes = graph([(40, 100), (60, 100), (80, 100)], links: [0: 1, 1: 2])
        var voyage = Voyage.joanAfterPrologue(in: world)
        voyage.x = 40.5
        voyage.y = 100.5
        voyage.memory[Discovery.chartedNodes] = 0
        XCTAssertFalse(voyage.autoSail(to: port, in: world))
        voyage.memory[Discovery.chartedNodes] = 0x40
        XCTAssertTrue(voyage.autoSail(to: port, in: world))
        XCTAssertNotNil(voyage.waypoint)
    }

    func testRealLisbonToSevilleRouteCanStillBePlanned() throws {
        let world = try World(assets: WorldTests.assets)
        var voyage = Voyage.joanAfterPrologue(in: world)
        let destination = try XCTUnwrap(world.ports.first { $0.name == "세빌리아" })
        XCTAssertTrue(voyage.autoSail(to: destination, in: world, anyWaters: true))
        XCTAssertNotNil(voyage.waypoint)
        XCTAssertTrue(voyage.route.allSatisfy { $0.count == 2 })
    }

    func testRealLisbonToSevilleAutoSailReachesDockingRadiusBeforeStoresRunOut() throws {
        let world = try World(assets: WorldTests.assets)
        let seville = try XCTUnwrap(world.ports.first { $0.name == "세빌리아" })
        var voyage = Voyage.joanAfterPrologue(in: world)
        voyage.ships[0].crew = 15
        voyage.ships[0].water = 200
        voyage.ships[0].food = 200
        let start = (voyage.x, voyage.y)
        XCTAssertTrue(voyage.autoSail(to: seville, in: world, anyWaters: true))
        var frames = 0
        while world.nearestPort(x: voyage.x, y: voyage.y, within: 7)?.id != seville.id,
              voyage.gameOver == nil, frames < 2_400 {
            voyage.tick(1.0 / 60, in: world)
            frames += 1
        }
        print("Lisbon–Seville autosail: \(frames) frames, \(voyage.daysAtSea) days, (\(voyage.x), \(voyage.y)), water \(voyage.water), food \(voyage.food), waypoint \(String(describing: voyage.waypoint))")
        XCTAssertNil(voyage.gameOver, "A short coastal trade route must not circle until the crew starves")
        XCTAssertEqual(world.nearestPort(x: voyage.x, y: voyage.y, within: 7)?.id, seville.id,
                       "Planning an itinerary is not enough: the live sailing rules must reach Seville")
        XCTAssertGreaterThan(hypot(world.deltaX(from: start.0, to: voyage.x), voyage.y - start.1), 10)
        XCTAssertGreaterThan(voyage.water, 0)
        XCTAssertGreaterThan(voyage.food, 0)
        XCTAssertLessThan(voyage.water, 200, "The route must advance real game time and consume stores")
        XCTAssertLessThan(voyage.food, 200)
    }

    func testManualSeaCourseSailsOutOfRealSevilleBerthAndStops() throws {
        let world = try World(assets: WorldTests.assets)
        let seville = try XCTUnwrap(world.ports.first { $0.name == "세빌리아" })
        let berth = try XCTUnwrap(world.berth(of: seville))
        XCTAssertEqual(berth.x, 144.5)
        XCTAssertEqual(berth.y, 373.5)
        let target = (x: 137.5, y: 381.5)
        let path = try XCTUnwrap(world.seaPath(from: berth, to: target))
        let end = try XCTUnwrap(path.last)
        print("Seville departure planned path: \(path)")
        XCTAssertTrue(world.fleetFits(x: end.0, y: end.1))

        var voyage = Voyage.joanAfterPrologue(in: world)
        // Unit fixture: recreate the real departure position, with an ordinary crew
        // and sufficient stores. All movement after the order runs through tick().
        voyage.x = berth.x
        voyage.y = berth.y
        voyage.ships[0].crew = 15
        voyage.ships[0].water = 200
        voyage.ships[0].food = 200
        XCTAssertTrue(voyage.setSeaCourse(x: target.x, y: target.y, in: world))
        print("Seville departure initial waypoint: \(String(describing: voyage.waypoint)); route: \(voyage.route)")
        XCTAssertNotNil(voyage.waypoint)
        for frame in 0..<2_400 where voyage.waypoint != nil && voyage.gameOver == nil {
            voyage.tick(1.0 / 60, in: world)
            if frame < 3 || voyage.waypoint == nil {
                print("Seville departure frame \(frame + 1): (\(voyage.x), \(voyage.y)), heading \(voyage.heading), waypoint \(String(describing: voyage.waypoint)), route \(voyage.route)")
            }
            XCTAssertTrue(world.isSea(x: voyage.x, y: voyage.y), "A planned coastal course must not cross land")
        }
        XCTAssertNil(voyage.gameOver)
        XCTAssertNil(voyage.waypoint, "A chart click must complete rather than remain stuck beside Seville")
        XCTAssertTrue(voyage.route.isEmpty)
        XCTAssertEqual(voyage.sail, 0)
        XCTAssertLessThan(hypot(world.deltaX(from: voyage.x, to: end.0), voyage.y - end.1), 1.6,
                          "Stopping against the coast is not a successful arrival")
        XCTAssertGreaterThan(hypot(world.deltaX(from: berth.x, to: voyage.x), voyage.y - berth.y), 8)
    }

    func testRejectedManualSeaOrdersPreserveCourseAndAnchorAtomically() throws {
        let islandRing = (97...103).flatMap { y in
            (77...83).compactMap { x in (x == 80 && y == 100) ? nil : (x, y) }
        }
        let world = try ocean(land: [(41, 100)] + islandRing)
        // This synthetic ocean has no ports; a direct voyage fixture avoids asking
        // the real prologue factory to index a missing Lisbon port.
        var original = Voyage(x: 40.5, y: 100.5, ships: [])
        original.setCourse(x: 50.5, y: 105.5)
        original.route = [[60.5, 105.5], [65.5, 105.5]]
        original.anchored = true
        let targets: [(Double, Double)] = [
            (41.5, 100.5),                       // land
            (80.5, 100.5),                       // sea enclosed by an impassable island ring
            (.nan, 100.5), (.infinity, 100.5),
            (50.5, .nan), (50.5, .infinity),
            (50.5, -0.5), (50.5, Double(World.height))
        ]
        func assertPreserved(_ voyage: Voyage, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(voyage.waypoint?.x, original.waypoint?.x, file: file, line: line)
            XCTAssertEqual(voyage.waypoint?.y, original.waypoint?.y, file: file, line: line)
            XCTAssertEqual(voyage.route, original.route, file: file, line: line)
            XCTAssertEqual(voyage.sail, original.sail, file: file, line: line)
            XCTAssertEqual(voyage.anchored, original.anchored, file: file, line: line)
            XCTAssertEqual(voyage.x, original.x, file: file, line: line)
            XCTAssertEqual(voyage.y, original.y, file: file, line: line)
        }
        for target in targets {
            var voyage = original
            XCTAssertFalse(voyage.setSeaCourse(x: target.0, y: target.1, in: world))
            assertPreserved(voyage)
        }
        var ashore = original
        ashore.ashore = true
        XCTAssertFalse(ashore.setSeaCourse(x: 50.5, y: 105.5, in: world))
        assertPreserved(ashore)
    }

    func testSaveRoundTripRetainsCurrentAutopilotLeg() throws {
        let world = try World(assets: WorldTests.assets)
        var voyage = Voyage.joanAfterPrologue(in: world)
        let destination = try XCTUnwrap(world.ports.first { $0.name == "세빌리아" })
        XCTAssertTrue(voyage.autoSail(to: destination, in: world, anyWaters: true))
        let data = try JSONEncoder().encode(voyage)
        let restored = try JSONDecoder().decode(Voyage.self, from: data)
        XCTAssertEqual(restored.waypoint?.x, voyage.waypoint?.x)
        XCTAssertEqual(restored.waypoint?.y, voyage.waypoint?.y)
        XCTAssertEqual(restored.route, voyage.route)
        XCTAssertEqual(restored.sail, voyage.sail)
    }

    func testOlderSaveWithoutWaypointStillLoads() throws {
        let world = try World(assets: WorldTests.assets)
        var voyage = Voyage.joanAfterPrologue(in: world)
        voyage.setCourse(x: 50.5, y: 100.5)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(voyage)) as? [String: Any])
        json.removeValue(forKey: "waypoint")
        let restored = try JSONDecoder().decode(Voyage.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.waypoint)
        XCTAssertEqual(restored.gold, voyage.gold)
        XCTAssertEqual(restored.memory.bytes, voyage.memory.bytes)
    }

    func testArrivalClearsRemainingAutopilotLegs() throws {
        let world = try World(assets: WorldTests.assets)
        var voyage = Voyage.joanAfterPrologue(in: world)
        voyage.setCourse(x: 100.5, y: 350.5)
        voyage.route = [[110.5, 350.5], [120.5, 350.5]]
        voyage.arrive(at: world.ports[0])
        XCTAssertNil(voyage.waypoint)
        XCTAssertTrue(voyage.route.isEmpty)
        XCTAssertEqual(voyage.sail, 0)
    }
}
