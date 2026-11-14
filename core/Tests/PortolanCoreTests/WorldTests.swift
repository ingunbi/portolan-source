import XCTest
@testable import PortolanCore

final class WorldTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    static let assets = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("assets")

    /// The tests that read the game's data need the `assets/` folder you extract from your own copy of the original
    /// game (see README). Without it they are skipped, not failed.
    static func skipUnlessAssets() throws {
        let marker = assets.appendingPathComponent("world_mask.bin").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: marker), "assets/ not found: extract it from your own copy of the original game (see README)")
    }

    func loadWorld() throws -> World { try World(assets: Self.assets) }

    func port(_ name: String, _ w: World) throws -> Harbor {
        try XCTUnwrap(w.ports.first { $0.name == name })
    }

    func testRealPortsAndGeography() throws {
        let w = try loadWorld()
        XCTAssertGreaterThanOrEqual(w.ports.count, 100)
        let lisbon = try port("리스본", w)
        XCTAssertEqual(lisbon.x, 120)
        XCTAssertEqual(lisbon.y, 358)
        XCTAssertTrue(w.isSea(x: 40, y: 400), "mid Atlantic")
        XCTAssertFalse(w.isSea(x: 600, y: 300), "inner Asia")
    }

    func testEveryPortHasABerth() throws {
        let w = try loadWorld()
        for p in w.ports { XCTAssertNotNil(w.berth(of: p), p.name) }
    }

    func testShipNeverEntersLand() throws {
        let w = try loadWorld()
        var v = Voyage.joanAfterPrologue(in: w)
        v.ships[0].crew = 30
        v.sail = Voyage.maxSail
        v.heading = 0.3                       // aimed into Iberia
        for _ in 0..<6000 {
            v.tick(1.0 / 60, in: w)
            XCTAssertTrue(w.isSea(x: v.x, y: v.y))
        }
    }

    func testEastWestWraps() throws {
        let w = try loadWorld()
        XCTAssertEqual(w.wrapX(-1), 2159)
        XCTAssertEqual(w.wrapX(2161), 1)
        XCTAssertEqual(w.deltaX(from: 2150, to: 10), 20)
        XCTAssertEqual(w.deltaX(from: 10, to: 2150), -20)
    }

    func testAutopilotSailsLisbonWestwardAndStops() throws {
        let w = try loadWorld()
        var v = Voyage.joanAfterPrologue(in: w)
        v.ships[0].crew = 30
        let target = (x: v.x - 50, y: v.y)
        v.setCourse(x: target.x, y: target.y)
        for _ in 0..<(60 * 600) where v.waypoint != nil { v.tick(1.0 / 60, in: w) }
        XCTAssertNil(v.waypoint)
        XCTAssertEqual(v.sail, 0)
        XCTAssertLessThan(abs(w.deltaX(from: v.x, to: target.x)), 3)
        XCTAssertGreaterThan(v.day, 0)
    }

    func testEveryPortHasRoomForAFleet() throws {
        let w = try loadWorld()
        for p in w.ports {
            var room = false
            for dy in -7...7 where !room {
                for dx in -7...7 where w.fleetFits(x: Double(p.x + dx) + 0.5, y: Double(p.y + dy) + 0.5) {
                    room = true
                    break
                }
            }
            XCTAssertTrue(room, "\(p.name)")
        }
    }

    func testCourseIntoLandHeavesTo() throws {
        let w = try loadWorld()
        var v = Voyage.joanAfterPrologue(in: w)
        v.ships[0].crew = 30
        v.ships[0].water = 100_000                // no starving on the way
        v.ships[0].food = 100_000
        v.setCourse(x: 600, y: 300)           // deep inside Asia
        for _ in 0..<(60 * 600) where v.waypoint != nil { v.tick(1.0 / 60, in: w) }
        XCTAssertNil(v.waypoint)
        XCTAssertEqual(v.sail, 0)
        XCTAssertFalse(v.aground)
    }
}
