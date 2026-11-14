import XCTest
@testable import PortolanCore

/// The walking town (docs/re/town_walk.md).
final class TownWalkTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func lisbon() -> (Voyage, TownMap) {
        var v = Voyage.joanAfterPrologue(in: world)
        v.memory[0xC3B] = 0xFF
        let m = world.town(0)!
        v.arriveInTown(port: 0, map: m)
        return (v, m)
    }

    /// Tile steps from the hero to `goal` over walkable tiles (breadth first).
    func path(_ m: TownMap, from a: (x: Int, y: Int), to g: (x: Int, y: Int)) -> [Int]? {
        var prev: [Int: (Int, Int)] = [a.y * 96 + a.x: (-1, -1)]
        var queue = [a]
        while !queue.isEmpty {
            let p = queue.removeFirst()
            if p == g {
                var dirs: [Int] = []
                var k = p.y * 96 + p.x
                while let (from, d) = prev[k], from >= 0 {
                    dirs.append(d)
                    k = from
                }
                return dirs.reversed()
            }
            for (d, (dx, dy)) in Voyage.townDirs.enumerated() {
                let q = (x: p.x + dx, y: p.y + dy)
                guard (0...94).contains(q.x), (0...94).contains(q.y), prev[q.y * 96 + q.x] == nil,
                      m.walkable(q.x, q.y) || q == g else { continue }
                prev[q.y * 96 + q.x] = (p.y * 96 + p.x, d)
                queue.append(q)
            }
        }
        return nil
    }

    func testArrivalBelowTheHarbourDoor() {
        let (v, m) = lisbon()
        let h = m.doors[3]!
        XCTAssertEqual(v.townHero.x, h.x)
        XCTAssertEqual(v.townHero.y, h.y + 1)
        XCTAssertTrue(m.walkable(v.townHero.x, v.townHero.y))
        XCTAssertEqual(v.memory[0xC3B], 0)
        XCTAssertNil(v.townDoor(map: m))
        XCTAssertEqual(m.doors.count, 11)                                   // 리스본 has no 점술가
    }

    func testWalkingToTheTavernDoor() throws {
        var (v, m) = lisbon()
        v.tick = 0                                                          // night: nobody about
        let door = m.doors[1]!
        let steps = try XCTUnwrap(path(m, from: v.townHero, to: door))
        for d in steps {
            XCTAssertEqual(v.townStep(d, port: 0, map: m), .moved)
            let w = (v.townHero.x - v.townCamera.x, v.townHero.y - v.townCamera.y)
            XCTAssertTrue((0...22).contains(w.0) && (0...22).contains(w.1))
            if v.townCamera.x > 0 && v.townCamera.x < 72 { XCTAssertTrue((4...18).contains(w.0), "camera margin") }
        }
        XCTAssertEqual(v.townDoor(map: m), 1)
        v.townEnterDoor()
        XCTAssertEqual(v.townHero.y, door.y + 1)
    }

    func testWallsSlideOrStop() {
        var (v, m) = lisbon()
        v.tick = 0
        // Walk up into the harbour office's wall above its door, many times: never inside a wall.
        for _ in 0..<40 {
            _ = v.townStep(0, port: 0, map: m)
            XCTAssertTrue(m.walkable(v.townHero.x, v.townHero.y) || v.townDoor(map: m) != nil)
        }
    }

    func testTownsfolkByDayAndNight() {
        var (v, m) = lisbon()
        v.tick = 30
        let folk = v.townsfolk
        XCTAssertEqual(folk.filter(\.walker).count, 4)
        XCTAssertEqual(folk.filter { !$0.walker }.map(\.k), [0, 1, 3])     // man, dog, merchant
        let tavern = m.doors[1]!
        XCTAssertTrue(folk.contains { $0.slot == 5 && $0.x == tavern.x + 2 && $0.y == tavern.y + 1 })
        for _ in 0..<200 { v.townsfolkTick(port: 0, map: m) }
        for p in v.townsfolk where p.walker { XCTAssertTrue((0..<94).contains(p.x) && (0..<94).contains(p.y)) }
        v.tick = 65
        XCTAssertTrue(v.townsfolk.isEmpty)
    }

    func testBumpingIntoTheDogTalks() {
        var (v, m) = lisbon()
        v.tick = 30
        let tavern = m.doors[1]!
        // Stand two tiles left of the dog and step right.
        v.memory.setWord(0xC40, max(0, min(72, tavern.x - 12)))
        v.memory.setWord(0xC42, max(0, min(72, tavern.y - 12)))
        v.memory.setWord(0xC44, tavern.x - v.townCamera.x)
        v.memory.setWord(0xC46, tavern.y + 1 - v.townCamera.y)
        for i in 0..<4 { v.memory[0xC48 + 3 * i] = 0xFF }                   // walkers out of the way
        XCTAssertEqual(v.townStep(1, port: 0, map: m), .talk(6))
        XCTAssertEqual(v.townTalk(6, port: 0, in: world), [.msg(619)])
        XCTAssertNotEqual(v.townStep(1, port: 0, map: m), .talk(6))       // ten steps before the next word
    }

    func testBlockadeGuardsStandBelowTheHarbour() {
        var v = Voyage.joanAfterPrologue(in: world)
        let lisbonNation = v.market(in: world).nation
        let mine = v.memory.pb(v.heroID, 0x31) & 0xF
        v.memory[0x1106 + 32 * lisbonNation + 0x12 + mine] |= 0x10               // nation record +0x12: at war
        v.tick = 30
        v.memory[0xC3B] = 0xFF
        let m = world.town(0)!
        v.arriveInTown(port: 0, map: m)
        XCTAssertEqual(v.townsfolk.filter { !$0.walker && $0.k == 2 }.count, 3)
        XCTAssertEqual(v.townStep(3, port: 0, map: m), .talk(7))
    }

    func testEveryPortHasATown() {
        XCTAssertEqual(world.towns.count, 130)
        XCTAssertEqual(world.towns.compactMap { $0 }.count, 130)
        for p in 0..<100 { XCTAssertNotNil(world.town(p)!.doors[3], "port \(p)") }
        XCTAssertEqual(world.town(120)!.map, 100)
    }
}
