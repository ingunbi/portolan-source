import XCTest
@testable import PortolanCore

final class BattleTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func testGeometry() {
        XCTAssertEqual(Battle.distance(10, 10, 10, 12), 2)
        XCTAssertEqual(Battle.distance(10, 10, 11, 10), 1)                 // even column: SE is (x+1, y)
        XCTAssertTrue(Battle.neighbour(10, 10, 2) == (11, 10))
        XCTAssertTrue(Battle.neighbour(11, 10, 2) == (12, 11))
        XCTAssertTrue(Battle.inArc(10, 10, heading: 0, 13, 10))             // heading north: beam to the east
        XCTAssertFalse(Battle.inArc(10, 10, heading: 0, 10, 14))            // dead ahead / astern
    }

    /// A Portuguese caravel against Simon Segueira's merchants, played out to the end.
    func playedBattle(seed: UInt32) -> (Voyage, Battle, BattleResult) {
        var v = Voyage.joanAfterPrologue(in: world)
        v.rng = GameRandom(seed: seed)
        v.ships[0].crew = 30
        v.ships[0].guns = 10
        v.ships[0].gunType = 1
        v.ships[0].shot = 40
        let p = v.memory.fleetAt(1)
        v.x = Double(p.x) + 0.5
        v.y = Double(p.y) + 0.5
        v.tick = 20
        v.pendingBattle = Encounter(attacker: v.heroID, defender: v.memory.fb(1, FleetField.admiral))
        var b = v.beginBattle(v.pendingBattle!, in: world)!
        var guardTurns = 0
        while b.phase != .over && guardTurns < 2000 {
            if b.phase == .duel {
                b.duelMove(guardTurns % 3, &v, world: world)
            } else if b.active != nil {
                if let t = b.targets(v).first { b.playerAttack(t, &v, world: world) } else { b.endTurn(&v, world: world) }
            }
            guardTurns += 1
        }
        let r = v.finishBattle(&b, in: world)
        return (v, b, r)
    }

    func testBattleRunsToAnEnd() {
        for seed in [1, 7, 42] as [UInt32] {
            let (v, b, r) = playedBattle(seed: seed)
            XCTAssertNotEqual(b.endCode, 0)
            XCTAssertTrue([1, 3, 4, 5, 6, 7].contains(r.code), "code \(r.code)")
            XCTAssertGreaterThan(b.log.lines.count, 0)
            if r.code == 4 || r.code == 6 { XCTAssertGreaterThan(v.fame[1], 0) }
        }
    }

    /// A click just outside a cropped hex map used to alias a valid dictionary key on
    /// another row. It must leave both the ship and its movement allowance untouched.
    func testOutOfBoundsMovementDoesNotAliasReachableCell() throws {
        var v = Voyage.joanAfterPrologue(in: world)
        v.ships[0].crew = 30
        v.exportToMemory(port: nil)
        var b = try XCTUnwrap(Battle(attacker: v.heroID, defender: v.memory.fb(1, FleetField.admiral), voyage: &v, world: world))
        b.advance(&v, world: world)
        let i = try XCTUnwrap(b.active)
        let u = b.units[i]
        // These coordinates flatten to the active ship's own reachable key.
        XCTAssertFalse(b.playerMove(to: u.x + Battle.width, u.y - 1, v))
        XCTAssertFalse(b.playerMove(to: u.x - Battle.width, u.y + 1, v))
        XCTAssertEqual(b.units[i].x, u.x)
        XCTAssertEqual(b.units[i].y, u.y)
        XCTAssertFalse(b.moved)
    }

    func testInvalidAttackDoesNotConsumeTurn() throws {
        var v = Voyage.joanAfterPrologue(in: world)
        v.ships[0].crew = 30
        v.exportToMemory(port: nil)
        var b = try XCTUnwrap(Battle(attacker: v.heroID, defender: v.memory.fb(1, FleetField.admiral), voyage: &v, world: world))
        b.advance(&v, world: world)
        let i = try XCTUnwrap(b.active), tick = v.tick
        let originalUnits = b.units.map { "\($0.x),\($0.y),\($0.heading),\($0.shot)" }
        for target in [-1, b.units.count, i] { b.playerAttack(target, &v, world: world) }
        XCTAssertEqual(b.active, i)
        XCTAssertEqual(v.tick, tick)
        XCTAssertEqual(b.units.map { "\($0.x),\($0.y),\($0.heading),\($0.shot)" }, originalUnits)
        XCTAssertNil(b.lastStrike)
    }

    /// The result sheet chooses prizes after the enemy fleet has been disbanded. This
    /// isolates that deferred transfer; it does not manufacture a battle victory.
    func testDeferredPrizeKeepsItsCannonTypeAfterFleetDisbands() throws {
        var (v, battle, prize) = try prizeResultFixture()
        let unit = battle.units[prize], enemyFleet = unit.fleet
        let slot = v.memory.slot(enemyFleet, unit.slot)
        let cannonType = v.memory[slot + 8] & 7, guns = v.memory[slot + 6]
        let hull = v.memory[slot + 2], crew = v.memory.word(slot) / 10
        XCTAssertGreaterThan(cannonType, 0)
        v.disband(enemyFleet)
        XCTAssertFalse(v.memory.fleetActive(enemyFleet))
        XCTAssertFalse(v.memory.slotUsed(enemyFleet, unit.slot))
        v.takePrizes([prize], from: battle, names: ["나포선"], in: world)
        let taken = try XCTUnwrap(v.ships.last)
        XCTAssertEqual(v.ships.count, 2)
        XCTAssertEqual(taken.gunType, cannonType, "Disbanding must not turn the captured guns into untyped cannon")
        XCTAssertEqual(taken.guns, min(guns, taken.gunCapacity))
        XCTAssertEqual(taken.hull, hull)
        XCTAssertEqual(taken.crew, crew)
        XCTAssertEqual(v.memory[slot + 8], 0, "The source slot is cleared after its prize is transferred")
        XCTAssertEqual(v.spareCaptains, 0)
        XCTAssertNil(v.officers[0].post)
        XCTAssertEqual(v.memory.person(v.officers[0].person).status, 2, "The assigned captain is also reflected in script memory")
    }

    /// Unit-only aftermath fixture. The terminal result and nearby ship are arranged
    /// deliberately; this is not evidence of a played battle or a legitimate victory.
    private func prizeResultFixture() throws -> (Voyage, Battle, Int) {
        var v = Voyage.newGame(in: world, hero: 1, seed: 1)
        let port = v.marketIndex
        // Use Catalina's real prologue to obtain a ship and the spare captain.
        for building in [7, 1, 7, 1, 3] {
            v.passTime(ticks: 3, in: world)
            var session = ScriptSession(key1: port, key2: building, port: port)
            session.advance(&v, in: world)
            var answers = 0
            while let prompt = session.prompt {
                answers += 1
                XCTAssertLessThan(answers, 600)
                guard answers < 600 else { throw NSError(domain: "BattleTests", code: 1) }
                switch prompt {
                case .yesNo: session.answer(1, &v, in: world)
                case .next, .menu: session.answer(0, &v, in: world)
                default: throw NSError(domain: "BattleTests", code: 2)
                }
            }
        }
        XCTAssertEqual(v.ships.count, 1)
        XCTAssertEqual(v.spareCaptains, 1)
        v.exportToMemory(port: nil)
        let enemyFleet = 15
        var battle = try XCTUnwrap(Battle(attacker: v.heroID, defender: v.memory.fb(enemyFleet, FleetField.admiral), voyage: &v, world: world))
        let prize = try XCTUnwrap(battle.sides[1].first)
        let own = try XCTUnwrap(battle.sides[0].first)
        battle.units[prize].x = battle.units[own].x + 1
        battle.units[prize].y = battle.units[own].y
        battle.endCode = 6
        battle.phase = .over
        return (v, battle, prize)
    }

    func testPrizeSelectionRejectsInvalidOwnDistantAndDuplicateShips() throws {
        var (v, battle, prize) = try prizeResultFixture()
        v.hireOfficer(96, salary: 20, in: world) // a second free captain exposes duplicate-transfer bugs
        let own = try XCTUnwrap(battle.sides[0].first)
        let enemyFleet = battle.units[prize].fleet
        let slot = v.memory.slot(enemyFleet, battle.units[prize].slot)
        let initialShips = v.ships.count, initialGold = v.gold

        var unfinished = battle
        unfinished.phase = .command
        unfinished.endCode = 0
        v.takePrizes([prize], from: unfinished, names: [], in: world)
        XCTAssertEqual(v.ships.count, initialShips)
        var distant = battle
        distant.units[prize].x = distant.units[own].x + 7
        v.takePrizes([prize], from: distant, names: [], in: world)
        XCTAssertEqual(v.ships.count, initialShips)

        v.disband(enemyFleet)
        v.takePrizes([-1, battle.units.count, own, prize, prize], from: battle, names: [], in: world)
        XCTAssertEqual(v.ships.count, initialShips + 1, "Only the valid nearby enemy ship may be transferred")
        XCTAssertEqual(v.gold, initialGold)
        XCTAssertEqual(v.spareCaptains, 1)
        XCTAssertEqual((0..<9).map { v.memory[slot + $0] }, Array(repeating: 0, count: 9))
        v.takePrizes([prize], from: battle, names: [], in: world)
        XCTAssertEqual(v.ships.count, initialShips + 1, "A repeated result confirmation must not clone the consumed source")
        XCTAssertEqual(v.spareCaptains, 1)
    }

    func testPrizeRequiresAnAvailableCaptainAndFleetSlot() throws {
        let (original, battle, prize) = try prizeResultFixture()
        var noCaptain = original
        noCaptain.officers = []
        noCaptain.takePrizes([prize], from: battle, names: [], in: world)
        XCTAssertEqual(noCaptain.ships.count, 1)
        var fullFleet = original
        for person in 96..<105 { fullFleet.hireOfficer(person, salary: 20, in: world) }
        fullFleet.ships += Array(repeating: fullFleet.ships[0], count: 9)
        XCTAssertGreaterThan(fullFleet.spareCaptains, 0)
        fullFleet.takePrizes([prize], from: battle, names: [], in: world)
        XCTAssertEqual(fullFleet.ships.count, 10)
        XCTAssertTrue(fullFleet.memory.slotUsed(battle.units[prize].fleet, battle.units[prize].slot), "A rejected choice must not destroy its source ship")
    }

    func testZeroCrewPrizeCanBeMannedSuppliedAndSailedWithoutCreatingResources() throws {
        var (v, battle, prize) = try prizeResultFixture()
        v.ships[0].crew = 30
        v.ships[0].water = 200
        v.ships[0].food = 200
        let source = v.memory.slot(battle.units[prize].fleet, battle.units[prize].slot)
        v.memory.setWord(source, 0) // boarding can legitimately leave an intact, unmanned hulk
        v.disband(battle.units[prize].fleet)
        v.takePrizes([prize], from: battle, names: [], in: world)
        XCTAssertEqual(v.ships.count, 2)
        XCTAssertEqual(v.ships[1].crew, 0)
        XCTAssertEqual(v.ships[1].water, 0)
        XCTAssertEqual(v.ships[1].food, 0)
        XCTAssertFalse(v.departureCheck().ok)
        var pool = CrewPool()
        XCTAssertTrue(v.setCrew(ship: 0, to: 20, pool: &pool))
        XCTAssertTrue(v.setCrew(ship: 1, to: 10, pool: &pool))
        XCTAssertEqual(pool.sailors, 0)
        XCTAssertEqual(v.crew, 30)
        XCTAssertTrue(v.moveCargo(.water, from: 0, to: 1, amount: 5))
        XCTAssertTrue(v.moveCargo(.food, from: 0, to: 1, amount: 5))
        XCTAssertEqual(v.water, 200)
        XCTAssertEqual(v.food, 200)
        XCTAssertTrue(v.ships.allSatisfy { $0.crew > 0 && $0.water > 0 && $0.food > 0 })
        XCTAssertTrue(v.departureCheck().ok)
        let origin = (v.x, v.y)
        XCTAssertTrue(v.setSeaCourse(x: 137.5, y: 381.5, in: world))
        for _ in 0..<300 where v.waypoint != nil && v.gameOver == nil { v.tick(1.0 / 60, in: world) }
        XCTAssertNil(v.gameOver)
        XCTAssertGreaterThan(hypot(world.deltaX(from: origin.0, to: v.x), v.y - origin.1), 0.5,
                             "Manning and supplying the prize must let the expanded fleet resume actual sailing")
    }

    func testSunkFlagshipDoesNotRegainHullDuringResultImport() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.ships[0].crew = 30
        v.exportToMemory(port: nil)
        let slot = v.memory.slot(v.playerFleet, 0)
        // afterHit clears the occupied bit when hull reaches zero; result import must
        // retain that damage rather than exporting the untouched voyage-side ship.
        v.memory[slot + 2] = 0
        v.memory[slot + 8] = 0
        v.importBattleShips()
        XCTAssertEqual(v.ships.count, 1, "Keep the flagship record available to the defeat presentation")
        XCTAssertEqual(v.ships[0].hull, 0)
        XCTAssertEqual(v.memory[slot + 2], 0)
        XCTAssertEqual(v.ships[0].crew, 30)
    }

    func testDuelExchange() {
        let v = Voyage.joanAfterPrologue(in: world)
        var d = Duel.start(hero: 0, against: 60, v)
        var w = v
        while !d.finished { Duel.step(&d, move: 1, &w) }
        XCTAssertTrue(d.turn == 20 || d.meter == 0 || d.meter == 200)
    }
}
