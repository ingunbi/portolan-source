import XCTest
@testable import PortolanCore

/// All six heroes start as the original's 0x1626B leaves them, and their prologue scripts
/// (SNR1..6 chapter 0) hand out the ships, money and companions.
final class HeroTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func play(_ v: inout Voyage, _ port: Int, _ b: Int) {
        var s = ScriptSession(key1: port, key2: b, port: port)
        s.advance(&v, in: world)
        var n = 0
        while let p = s.prompt, n < 600 {
            switch p {
            case .yesNo: s.answer(1, &v, in: world)
            case .duel: s.answer(180, &v, in: world)
            default: s.answer(0, &v, in: world)
            }
            n += 1
        }
    }

    func testStartingPorts() {
        let homes = ["리스본", "세빌리아", "런던", "암스테르담", "제노바", "이스탄불"]
        for h in 0..<6 {
            let v = Voyage.newGame(in: world, hero: h)
            XCTAssertEqual(v.heroID, h)
            XCTAssertEqual(world.ports[v.marketIndex].name, homes[h], "hero \(h)")
            XCTAssertTrue(v.ships.isEmpty)
            XCTAssertEqual(v.gold, 0)
            XCTAssertTrue(v.memory.fleetActive(v.playerFleet))
            XCTAssertEqual(v.captain.name, v.memory.person(h).name)
            XCTAssertEqual(v.memory.word(Discovery.chartedTotal), 130)
        }
        XCTAssertEqual(Voyage.newGame(in: world, hero: 3).captain.skills, 0x18)    // Ernst: map making + surveying
    }

    func testRename() {
        let v = Voyage.newGame(in: world, hero: 0, given: "마리아", family: "실바")
        XCTAssertEqual(v.captain.name, "마리아 실바")
    }

    func testProloguesHandOutShips() {
        var got: [Int: [String]] = [:]
        for h in 0..<6 {
            var v = Voyage.newGame(in: world, hero: h)
            let port = v.marketIndex
            for round in 0..<6 {
                for b in [7, 5, 1, 2, 3, 0, 8, 4, 10, 9] {
                    play(&v, port, b)
                    if v.tick < 66 && round >= 1 { v.passTime(ticks: 4) }
                }
                if round == 2 { v.tick = 66 }
            }
            got[h] = v.ships.map(\.name)
            print("HERO \(h) \(v.captain.name): ships \(v.ships.map(\.name)) gold \(v.gold) officers \(v.officers.map(\.name)) items \(v.items) chapter \(v.memory[ScriptContext.hero.base]).\(v.memory[ScriptContext.hero.base + 1])")
        }
        XCTAssertEqual(got[0], ["헤르메스Ⅱ세"])
        XCTAssertFalse(got[1]?.isEmpty ?? true, "Catalina steals her galleon in Seville")
        XCTAssertFalse(got[3]?.isEmpty ?? true, "Ernst gets his caravel in Amsterdam")
    }
}
