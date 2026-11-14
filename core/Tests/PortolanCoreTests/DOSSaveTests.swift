import XCTest
@testable import PortolanCore

/// Loading the original's KOUKAI2.DAT slots (newgame.md §8.1).
final class DOSSaveTests: XCTestCase {
    override func setUp() async throws {
        try WorldTests.skipUnlessAssets()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.file.path), "needs original/GAME/SAVE/KOUKAI2.DAT from your own copy of the original game")
    }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    static var file: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("original/GAME/SAVE/KOUKAI2.DAT")
    }

    func testTheSavedSlotsLoad() throws {
        let save = try XCTUnwrap(DOSSave(url: Self.file))
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        var loaded = 0
        for s in 0..<DOSSave.slots {
            guard let h = save.header(s) else {
                XCTAssertNil(save.voyage(slot: s, in: world))
                continue
            }
            let v = try XCTUnwrap(save.voyage(slot: s, in: world))
            loaded += 1
            // The header date is the game date the slot holds.
            XCTAssertEqual(h.date, String(format: "%2d/%@/15%02d", v.dayOfMonth + 1, months[v.month], v.year % 100), "slot \(s)")
            XCTAssertFalse(v.ships.isEmpty, "slot \(s)")
            XCTAssertTrue(v.ships.allSatisfy { $0.hull <= $0.maxHull && $0.crew <= max($0.crewCapacity, $0.crew) }, "slot \(s)")
            XCTAssertTrue((0..<World.height).contains(Int(v.y)), "slot \(s)")
            if let p = h.port { XCTAssertEqual(Int(v.x), world.ports[p].x, "slot \(s)") } else { XCTAssertTrue(world.isSea(x: v.x, y: v.y), "slot \(s)") }
            XCTAssertLessThanOrEqual(v.officers.count, 30)
            XCTAssertLessThanOrEqual(v.logbook.count, 48)
            print("DOS slot \(s): \(h.date) hero \(v.heroID) \(v.captain.name) ships \(v.ships.map(\.name)) gold \(v.gold) officers \(v.officers.count) log \(v.logbook.count)")
        }
        XCTAssertEqual(loaded, 7)
    }
}
