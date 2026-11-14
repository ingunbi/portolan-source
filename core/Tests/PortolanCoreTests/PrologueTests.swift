import XCTest
@testable import PortolanCore

final class PrologueTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func testNewGameSegment() {
        let ng = world.navigation.newGame
        XCTAssertEqual([ng.year, ng.month, ng.day, ng.tick], [1522, 4, 16, 24])   // 17 May 1522, 08:00
        XCTAssertEqual(ng.gold, 0)
        let homes = ng.heroes.map { world.ports[$0.port].name }
        XCTAssertEqual(homes, ["리스본", "세빌리아", "런던", "암스테르담", "제노바", "이스탄불"])
        let joan = ng.heroes[0]
        XCTAssertEqual(joan.name, "조안 페레로")
        XCTAssertEqual([joan.leadership, joan.seamanship, joan.knowledge, joan.luck, joan.navLevel], [78, 75, 73, 50, 1])
    }

    func testShipyardHandsOverAnEmptyShip() {
        let s = Ship.built(class: 5, named: "헤르메스Ⅱ세", in: world.navigation)
        XCTAssertEqual(world.navigation.classes[5].hull, 30)
        XCTAssertEqual(s.hull, 27)                         // 9 * 30 / 10
        XCTAssertEqual(s.rudder, 90)
        XCTAssertEqual(s.sail, 75)
        XCTAssertEqual([s.crew, s.guns, s.water, s.food], [0, 0, 0, 0])
        XCTAssertEqual(s.sailorShare, 50)
        XCTAssertEqual([s.crewCapacity, s.cargoCapacity], [30, 80])       // template 45: 120 - 10 guns - 30 crew
    }

    func testJoanStartsInLisbonAfterPrologue() {
        let v = Voyage.joanAfterPrologue(in: world)
        XCTAssertEqual(v.ships.count, 1)
        XCTAssertEqual(v.ships[0].name, "헤르메스Ⅱ세")
        XCTAssertEqual(world.navigation.classes[v.ships[0].classIndex].name, "카라벨 라티나")
        XCTAssertEqual(v.gold, 1000)
        XCTAssertEqual(v.water, 0)
        XCTAssertEqual(v.food, 0)
        XCTAssertEqual(v.crew, 0)
        XCTAssertEqual(v.captain.charm, 89)
        XCTAssertEqual(v.captain.name, "조안 페레로")
        XCTAssertEqual([v.year, v.month, v.dayOfMonth, v.tick], [1522, 4, 16, 24])
        XCTAssertTrue(v.summerWinds)
        XCTAssertLessThan(abs(v.x - 120), 6)
        XCTAssertLessThan(abs(v.y - 358), 6)
    }
}
