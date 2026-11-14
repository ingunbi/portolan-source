import XCTest
@testable import PortolanCore

final class ScriptTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    /// Plays an event, clicking through lines and answering menus and yes/no with `choice`.
    @discardableResult
    func play(_ v: inout Voyage, _ key1: Int, _ key2: Int, port: Int? = 0, choice: Int = 0) -> (ScriptSession, [String]) {
        var s = ScriptSession(key1: key1, key2: key2, port: port)
        var said: [String] = []
        s.advance(&v, in: world)
        var n = 0
        while let p = s.prompt, n < 500 {
            said += s.run?.windows.map(\.text) ?? []
            switch p {
            case .next: s.answer(0, &v, in: world)
            case .menu, .yesNo: s.answer(choice, &v, in: world)
            case .duel: s.answer(170, &v, in: world)
            case .ending: s.answer(0, &v, in: world)
            }
            n += 1
        }
        return (s, said)
    }

    func testFilesDecode() {
        XCTAssertEqual(world.scripts.count, 7)
        XCTAssertEqual(world.scripts[1].blockStart(chapter: 0, block: 0), 0x32)
    }

    func testParticles() {
        XCTAssertEqual(Korean.particles("조안(를) 당신에게"), "조안을 당신에게")
        XCTAssertEqual(Korean.particles("카를로타(가) 왔다"), "카를로타가 왔다")
        XCTAssertEqual(Korean.particles("리스본(로)"), "리스본으로")
        XCTAssertEqual(Korean.particles("서울(로)"), "서울로")
        XCTAssertEqual(Korean.particles("금화 3(는)"), "금화 3은")
    }

    func testJoansPrologue() {
        var v = Voyage.newGame(in: world)
        XCTAssertEqual(v.gold, 0)
        XCTAssertTrue(v.ships.isEmpty)
        // Father's audience: Rocco joins and the caravel latina is ordered.
        let (_, lines) = play(&v, 0, ScriptKey.residence)
        XCTAssertFalse(lines.isEmpty, "the audience scene must speak")
        XCTAssertEqual(v.officers.map(\.person), [69])
        XCTAssertEqual(v.orders.first?.ship.classIndex, 5)
        // Carlotta hands over the duke's 1000 gold.
        play(&v, 0, ScriptKey.tavern)
        XCTAssertEqual(v.gold, 1000)
        // The shipyard delivers the Hermes II.
        play(&v, 0, ScriptKey.shipyard)
        XCTAssertEqual(v.ships.map(\.name), ["헤르메스Ⅱ세"])
        XCTAssertTrue(v.orders.isEmpty)
        // The mother's farewell waits for 22:00, then gives the silver hair ornament.
        play(&v, 0, ScriptKey.residence)
        XCTAssertFalse(v.items.contains(0x34))
        v.tick = 66
        play(&v, 0, ScriptKey.residence)
        XCTAssertTrue(v.items.contains(0x34))
        // The priest's offer: take the 1000 gold (menu choice 0) after Enrico joins.
        play(&v, 0, ScriptKey.church)
        XCTAssertTrue(v.officers.map(\.person).contains(70))
        play(&v, 0, ScriptKey.church, choice: 0)
        XCTAssertEqual(v.gold, 2000)
        // Rocco's lecture at the harbour appoints the first mate and the bookkeeper.
        play(&v, 0, ScriptKey.harbor, choice: 1)
        XCTAssertEqual(v.officer(holding: .firstMate)?.person, 69)
        XCTAssertEqual(v.officer(holding: .bookkeeper)?.person, 70)
    }
}
