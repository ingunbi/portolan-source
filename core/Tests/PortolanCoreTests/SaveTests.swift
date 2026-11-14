import XCTest
@testable import PortolanCore

/// The ten save slots and the post-load story fix-up (newgame.md §8).
final class SaveTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!
    var dir: URL!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("portolan-save-\(UUID().uuidString)")
        SaveGame.override = dir
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        SaveGame.override = nil
    }

    func testSlotsKeepTheirHeaders() throws {
        var v = Voyage.joanAfterPrologue(in: world)
        v.gold = 1234
        XCTAssertNil(SaveGame.header(3))
        try SaveGame.write(v, slot: 3, port: "리스본")
        let h = SaveGame.header(3)
        XCTAssertEqual(h?.port, "리스본")
        XCTAssertEqual(h?.type, 0)
        XCTAssertEqual(h?.date, SaveGame.dateText(v))
        XCTAssertTrue(h!.date.hasSuffix("/15\(v.year % 100)"))
        XCTAssertEqual(try SaveGame.read(slot: 3).gold, 1234)
        XCTAssertNil(SaveGame.header(4))
    }

    func testEndingSavesAndTheStoryFixUp() throws {
        var v = Voyage.joanAfterPrologue(in: world)
        v.memory[0xC30] &= ~0x42                                        // a story ending
        XCTAssertEqual(SaveGame.type(of: v, ending: true), 2)
        try SaveGame.write(v, slot: 0, port: nil, ending: true)
        let back = try SaveGame.read(slot: 0)
        XCTAssertFalse(back.storyOn)
        XCTAssertEqual(back.memory[ScriptContext.hero.base], 0xFF)

        v.memory[0xC30] = (v.memory[0xC30] | 0x40) & ~0x02                // the rank ending only
        XCTAssertEqual(SaveGame.type(of: v, ending: true), 3)
        var w = v
        w.memory[0xCEA] = 5
        w.afterLoad()
        XCTAssertEqual(w.memory[0xCEA], 0)
        XCTAssertEqual(w.memory[0xC30] & 0x42, 0x40)
    }
}
