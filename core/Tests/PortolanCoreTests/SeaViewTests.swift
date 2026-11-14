import XCTest
@testable import PortolanCore

/// The original sea view's scrolling (seamap.md §6).
final class SeaViewTests: XCTestCase {
    func testStartsWithTheFleetInTheMiddle() {
        let o = World.seaViewOrigin(from: nil, fleetX: 100.5, fleetY: 300.5, margin: 6)
        XCTAssertEqual(o.x, 100 - 11)
        XCTAssertEqual(o.y, 300 - 11)
    }

    func testStaysInsideTheDeadZone() {
        let start = World.seaViewOrigin(from: nil, fleetX: 100.5, fleetY: 300.5, margin: 6)
        for d in -6...6 {
            let o = World.seaViewOrigin(from: start, fleetX: 100.5 + Double(d), fleetY: 300.5 - Double(d), margin: 6)
            XCTAssertEqual(o.x, start.x, "dx \(d)")
            XCTAssertEqual(o.y, start.y, "dy \(d)")
        }
    }

    func testScrollsATileAtATimePastTheDeadZone() {
        var o = World.seaViewOrigin(from: nil, fleetX: 100.5, fleetY: 300.5, margin: 6)
        for step in 1...10 {
            o = World.seaViewOrigin(from: o, fleetX: 100.5 + Double(step), fleetY: 300.5, margin: 6)
        }
        // The fleet is 10 tiles east: the view followed for the last 4 of them, keeping it at 11 + 6.
        XCTAssertEqual(o.x, 89 + 4)
        XCTAssertEqual(110 - o.x, 17)
        let tight = World.seaViewOrigin(from: (89, 289), fleetX: 101.5, fleetY: 300.5, margin: 0)
        XCTAssertEqual(tight.x, 90)
    }

    func testKeepsToTheThirdAndTheRows() {
        let east = World.seaViewOrigin(from: nil, fleetX: 715.5, fleetY: 5.5, margin: 6)
        XCTAssertEqual(east.x, 696)                                 // 720·0 + 696
        XCTAssertEqual(east.y, 0)
        // Into the next third: the view starts over there.
        let next = World.seaViewOrigin(from: east, fleetX: 721.5, fleetY: 5.5, margin: 6)
        XCTAssertEqual(next.x, 720)
        let south = World.seaViewOrigin(from: nil, fleetX: 300.5, fleetY: 1078.5, margin: 6)
        XCTAssertEqual(south.y, World.height - 24)
        let wrap = World.seaViewOrigin(from: nil, fleetX: -0.5, fleetY: 500.5, margin: 6)
        XCTAssertEqual(wrap.x, 1440 + 696)
    }
}
