import XCTest
@testable import PortolanCore

final class FleetTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func testRouteGraph() throws {
        let g = try XCTUnwrap(world.routes)
        XCTAssertGreaterThanOrEqual(g.nodes.count, 622)
        let n = g.nearest(x: g.nodes[100].x, y: g.nodes[100].y)
        XCTAssertEqual(n & 0x8000, 0x8000)
    }

    func testNewGameFleets() {
        let v = Voyage.newGame(in: world)
        XCTAssertEqual(v.memory.fleetAt(1).x, 2006)                      // Simon Segueira's merchants
        XCTAssertTrue(v.memory.fleetActive(1))
        XCTAssertFalse(v.memory.fleetActive(10))                        // Catalina has no ships yet
        XCTAssertEqual(v.memory.fb(61, FleetField.admiral), 114)        // Francia Loronoa
    }

    func testFleetsTravelAndCallAtPorts() {
        var v = Voyage.newGame(in: world)
        let start = (0..<70).map { v.memory.fleetAt($0) }
        v.passTime(ticks: 72 * 40, in: world)
        let moved = (1..<70).filter { v.memory.fleetActive($0) && v.memory.fleetAt($0) != start[$0] }.count
        XCTAssertGreaterThan(moved, 30)
        let inPort = (1..<70).filter { v.memory.fleetActive($0) && v.memory.fleetInPort($0) }.count
        XCTAssertGreaterThan(inPort, 0)
        // Fleet 1's first destination is port 1 mod 42 = Seville, its home Lisbon.
        XCTAssertEqual(v.memory.fb(1, FleetField.home), 0)
    }

    func testPathfindBuffersWaypoints() {
        var v = Voyage.newGame(in: world)
        v.memory.setFW(5, FleetField.route, 0x4000)
        XCTAssertTrue(v.pathfind(5, world.routes!))
        XCTAssertNotEqual(v.memory.fb(5, FleetField.route) & 0xF0, 0)
    }

    func testBeatenFleetIsRebuiltAndRelaunched() {
        var v = Voyage.newGame(in: world)
        v.disband(5)
        XCTAssertFalse(v.memory.fleetActive(5))
        for _ in 0..<6 where !v.memory.fleetActive(5) { v.worldMonth(in: world) }   // a captain is found by chance
        XCTAssertGreaterThan(v.memory.word(0x1106), 0)                     // Portugal's power
        XCTAssertTrue(v.memory.fleetActive(5))
        let adm = v.memory.fb(5, FleetField.admiral)
        XCTAssertEqual(v.memory.fleetOf(person: adm), 5)
        XCTAssertEqual(v.memory.fleetAt(5).x, v.memory.portXY(0).0)          // relaunched from Lisbon
        XCTAssertTrue([18, 19, 20, 21].contains(v.memory.shipClass(5, 0)))   // galleys
    }

    func testRelationsWarmBetweenUnflaggedNations() {
        var v = Voyage.newGame(in: world)
        v.memory.setWord(0x1106 + 32 * 0, 100)                             // Portugal stronger
        v.memory.setWord(0x1106 + 32 * 3, 80)                              // than England
        v.memory.setNB(0, 0xB + 3, 20)
        v.memory.setNB(3, 0xB + 0, 20)
        v.memory.setNB(0, 0x12 + 3, 0)
        v.relationsMonth()
        let r = v.memory.nb(0, 0xB + 3)
        XCTAssertTrue((23...27).contains(r), "\(r)")                         // table entry 8: state 1, +3..7
        XCTAssertEqual(v.memory.nb(3, 0xB + 0), r)
        XCTAssertEqual(v.memory.nb(0, 0x12 + 1) & 0x20, 0x20)              // Portugal and Spain stay allied
    }

    func testBlockadeKeepsThePlayerOutByDay() {
        var v = Voyage.newGame(in: world)
        v.memory.setNB(2, 0x12 + 0, 0x10)                                   // Turkey blockades Portugal
        v.tick = 30
        XCTAssertTrue(v.blockaded(port: 2))                                 // Istanbul
        v.tick = 65
        XCTAssertFalse(v.blockaded(port: 2))
        XCTAssertFalse(v.blockaded(port: 0))
    }

    func testWindowPathRunsStraightThenTurns() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.x = 60.5; v.y = 380.5                                             // open Atlantic west of Lisbon
        let w = v.window
        v.memory.setFW(5, FleetField.x, w.x + 10)
        v.memory.setFW(5, FleetField.y, w.y + 10)
        // Spec example: from local (10, 10) to (40, 20) in open sea, the diagonal run reaches
        // (20, 20); with the 45° leg the target is the goal itself.
        let straight = v.windowPath(5, goal: (w.x + 40, w.y + 20), smooth: false, world)
        let smooth = v.windowPath(5, goal: (w.x + 40, w.y + 20), smooth: true, world)
        XCTAssertTrue(straight.map { $0 == (w.x + 20, w.y + 20) } ?? false, "\(String(describing: straight))")
        XCTAssertTrue(smooth.map { $0 == (w.x + 40, w.y + 20) } ?? false, "\(String(describing: smooth))")
    }
}
