import XCTest
@testable import PortolanCore

/// A long scripted play: the prologue, then a year of trading voyages between Iberian and
/// North African ports, visiting every building, with the world running. Checks invariants
/// as it goes; meant to shake out crashes and impossible states.
final class SoakTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    func play(_ v: inout Voyage, _ key1: Int, _ key2: Int, port: Int?) {
        var s = ScriptSession(key1: key1, key2: key2, port: port)
        s.advance(&v, in: world)
        var n = 0
        while let p = s.prompt, n < 1000 {
            switch p {
            case .yesNo: s.answer(1, &v, in: world)
            case .duel: s.answer(170, &v, in: world)
            default: s.answer(0, &v, in: world)
            }
            n += 1
        }
        XCTAssertLessThan(n, 1000, "script \(key1)/\(key2) does not end")
    }

    func check(_ v: Voyage, _ when: String) {
        XCTAssertGreaterThanOrEqual(v.gold, 0, when)
        XCTAssertLessThanOrEqual(v.ships.count, 10, when)
        XCTAssertLessThanOrEqual(v.officers.count, 30, when)
        XCTAssertLessThanOrEqual(v.items.count, 20, when)
        for s in v.ships {
            XCTAssertLessThanOrEqual(s.hull, s.maxHull, when)
            XCTAssertGreaterThanOrEqual(s.crew, 0, when)
            XCTAssertLessThanOrEqual(s.holds.count, Trade.holds, when)
        }
        XCTAssertTrue((0..<12).contains(v.month), when)
        for f in 0..<Fleets.count where v.memory.fleetActive(f) {
            let p = v.memory.fleetAt(f)
            XCTAssertTrue((0..<World.width).contains(p.x) && (0..<World.height).contains(p.y), "\(when): fleet \(f) at \(p)")
        }
        for m in v.markets {
            XCTAssertTrue(m.prices.allSatisfy { (0...100).contains($0) }, when)
            XCTAssertTrue(m.support.allSatisfy { (0...100).contains($0) }, when)
        }
    }

    /// Sails to a port with the autopilot; false if it takes too long.
    func sail(_ v: inout Voyage, to port: Harbor) -> Bool {
        guard world.berth(of: port) != nil, v.autoSail(to: port, in: world, anyWaters: true) else { return false }
        for _ in 0..<8_000 {
            v.tick(Voyage.secondsPerDay / Double(Navigation.ticksPerDay), in: world)
            if v.pendingBattle != nil { v.pendingBattle = nil }
            if v.gameOver != nil { return false }
            if world.nearestPort(x: v.x, y: v.y, within: 7)?.id == port.id {
                v.arrive(at: port, in: world)
                return true
            }
            if v.sail == 0 && !v.autoSail(to: port, in: world, anyWaters: true) { return false }
        }
        return false
    }

    func testAYearOfVoyages() {
        var v = Voyage.newGame(in: world)
        for b in [7, 1, 2, 7, 10, 10, 3, 9] { play(&v, 0, b, port: 0) }
        v.tick = 66
        play(&v, 0, 7, port: 0)
        XCTAssertEqual(v.ships.count, 1)
        check(v, "prologue")
        let route = ["리스본", "세빌리아", "세우타", "알제", "팔마", "발렌시아", "바르셀로나", "마르세이유", "제노바", "마르세이유", "바르셀로나", "세빌리아", "마데이라", "산타크루즈", "마데이라", "리스본"]
        let ports = route.compactMap { n in world.ports.first { $0.name == n } }
        var arrivals = 0
        for leg in 0..<24 {
            let here = ports[leg % ports.count], next = ports[(leg + 1) % ports.count]
            // In port: crew, stores, a little trade, every building.
            let t = Tavern(market: v.market(in: world), drinks: world.navigation.drinks, charm: v.captain.charm)
            v.hire(min(v.hireable(at: t), 20), at: t)
            for s in [Supply.water, .food] { v.buy(s, barrels: min(v.maxPurchase(s, ship: 0, at: v.market(in: world)), 40), ship: 0, at: v.market(in: world)) }
            if here.id < 100 {
                for b in 0..<12 {
                    v.passTime(ticks: 3, in: world)
                    play(&v, here.id, b, port: here.id)
                    check(v, "leg \(leg) building \(b)")
                }
                if let o = v.offers(in: world).first, v.maxPurchase(o, ship: 0, in: world) > 0 {
                    v.buy(o, amount: min(5, v.maxPurchase(o, ship: 0, in: world)), ship: 0, in: world)
                }
                while let k = v.ships[0].holds.indices.first, v.gold < 1_000_000 { v.sell(hold: k, amount: v.ships[0].holds[k].amount, ship: 0, in: world) }
            }
            // Sailors can be hired once a day, so the prologue's hire may be all there is.
            v.ships[0].crew = min(v.ships[0].crewCapacity, max(v.ships[0].crew, 30))
            v.ships[0].holds = []
            v.ships[0].water = 300
            v.ships[0].food = 300
            v.ships[0].lumber = 0
            v.ships[0].shot = 0
            v.ships[0].morale = 100
            let ok = sail(&v, to: next)
            if ok { arrivals += 1 } else if let b = world.berth(of: next) {
                // Becalmed or beaten upwind until the stores ran out: towed in, as a player would reload.
                if v.gameOverCode == 0x19 {
                    v.gameOver = nil
                    v.gameOverCode = nil
                }
                v.x = b.x
                v.y = b.y
                v.arrive(at: next, in: world)
            }
            check(v, "after leg \(leg)")
            if v.gameOver != nil { break }
        }
        XCTAssertGreaterThan(arrivals, 12)
        XCTAssertGreaterThan(v.fame[2], 0)                                  // ports discovered on the way
        // Let the world run three more months in port.
        v.passTime(ticks: 72 * 90, in: world)
        check(v, "three months later")
        let active = (0..<Fleets.count).filter { v.memory.fleetActive($0) }.count
        XCTAssertGreaterThan(active, 40)
        // Save and load the whole state.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portolan-soak.json")
        XCTAssertNoThrow(try SaveGame.write(v, to: url))
        let r = try? SaveGame.read(from: url)
        XCTAssertEqual(r?.memory.bytes, v.memory.bytes)
        XCTAssertEqual(r?.fame, v.fame)
    }
}
