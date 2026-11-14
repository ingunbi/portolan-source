import Foundation

public struct Harbor: Codable, Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let x: Int
    public let y: Int
}

/// The 2160x1080 tile world decoded from WORLDMAP.LZW. East and west wrap.
public struct World {
    public static let width = 2160
    public static let height = 1080
    public enum Terrain: UInt8 { case sea = 0, land = 1, rough = 2 }

    public let tiles: [UInt8]
    public let ports: [Harbor]
    public let navigation: NavigationData
    /// Hash of the registered asset manifest, or "unvalidated" for synthetic test worlds.
    public let contentRevision: String
    public let contentWarnings: [ContentValidationIssue]
    /// Data segment of a new game, and the scenario scripts SNR0 (shared) .. SNR6.
    public var memory: DataSegment?
    public var scripts: [ScriptFile] = []
    var colony: [UInt8] = []
    /// Route graph of the fleets out of sight (DATA1[4]).
    public var routes: RouteGraph?
    /// Walking towns of the 130 ports (assets/portmaps).
    public var towns: [TownMap?] = []
    /// MONSTER.DAT: the sea event points read in after each event (x, y, type).
    public var seaEventPoints: [(x: Int, y: Int, type: Int)] = []

    public init(tiles: [UInt8], ports: [Harbor], navigation: NavigationData,
                contentRevision: String = "unvalidated", contentWarnings: [ContentValidationIssue] = []) {
        precondition(tiles.count == World.width * World.height)
        self.tiles = tiles
        self.ports = ports
        self.navigation = navigation
        self.contentRevision = contentRevision
        self.contentWarnings = contentWarnings
    }

    public init(assets: URL) throws {
        // Validate before the tile initializer's precondition and before any optional loaders
        // can silently turn a missing file into a partial world.
        let validation = ContentValidation.validate(assets: assets, scope: .runtime)
        try validation.requireValid()
        // world_mask.bin carries the original's passability (chip ≥ 0x34 blocks, tools/seamap.py).
        let tiles = [UInt8](try Data(contentsOf: assets.appendingPathComponent("world_mask.bin")))
        guard tiles.count == World.width * World.height else {
            throw ContentValidationError(issues: [.init(severity: .error, code: "invalid_size",
                path: "world_mask.bin", logicalID: "world", expected: "\(World.width * World.height)바이트",
                actual: "\(tiles.count)바이트; 검사 후 파일이 변경됨")])
        }
        struct File: Codable { let ports: [Harbor] }
        let data = try Data(contentsOf: assets.appendingPathComponent("ports.json"))
        self.init(tiles: tiles, ports: try JSONDecoder().decode(File.self, from: data).ports,
                  navigation: try NavigationData(assets: assets), contentRevision: validation.contentRevision,
                  contentWarnings: validation.warnings)
        memory = try DataSegment(contentsOf: assets.appendingPathComponent("ds.bin"))
        let dir = assets.appendingPathComponent("scenario")
        let t = try Data(contentsOf: assets.appendingPathComponent("text.json"))
        let text = try JSONSerialization.jsonObject(with: t) as? [String: Any] ?? [:]
        // Logical index n must always mean SNRn. A missing file fails instead of shifting
        // every later protagonist down by one position.
        scripts = try (0..<7).map { n in
            guard let lines = text["scenario\(n)"] as? [String] else {
                throw ContentValidationError(issues: [.init(severity: .error, code: "invalid_text",
                    path: "text.json", logicalID: "scenario\(n)", expected: "시나리오 대사 배열",
                    actual: "검사 후 자료가 변경됨")])
            }
            let d = try Data(contentsOf: dir.appendingPathComponent("SNR\(n).DAT"))
            return ScriptFile(data: [UInt8](d), lines: lines)
        }
        colony = [UInt8](try Data(contentsOf: dir.appendingPathComponent("COLONY.DAT")))
        routes = RouteGraph(data: [UInt8](try Data(contentsOf: assets.appendingPathComponent("routes.bin"))))
        towns = TownMap.load(assets: assets)
        guard towns.count == 130, towns.allSatisfy({ $0 != nil }) else {
            throw ContentValidationError(issues: [.init(severity: .error, code: "invalid_town",
                path: "portmaps/portmaps.json", logicalID: "towns", expected: "항구 지도 130개",
                actual: "검사 후 지도 자료를 읽지 못함")])
        }
        let d = [UInt8](try Data(contentsOf: dir.appendingPathComponent("MONSTER.DAT")))
        seaEventPoints = stride(from: 0, to: max(0, d.count - 4), by: 5).map { k -> (Int, Int, Int) in
            let x = Int(d[k]) | (Int(d[k + 1]) << 8)
            let y = Int(d[k + 2]) | (Int(d[k + 3]) << 8)
            let kind = Int(d[k + 4])
            return (x, y, kind)
        }
        DataSegment.loadNames([UInt8](try Data(contentsOf: dir.appendingPathComponent("NAME.TBL"))))
    }

    /// Script table 18: COLONY.DAT record `i` is read to DS:0xBEF6.
    func loadDiscovery(_ i: Int, into m: inout DataSegment) {
        let size = 0xDA
        guard (i + 1) * size <= colony.count else { return }
        for k in 0..<size { m[0xBEF6 + k] = Int(colony[i * size + k]) }
    }

    public func wrapX(_ x: Double) -> Double {
        let w = Double(World.width)
        let r = x.truncatingRemainder(dividingBy: w)
        return r < 0 ? r + w : r
    }

    /// The sea view's top-left tile in the original 24×24 map window (seamap.md §6): it starts with
    /// the fleet's 2×2 footprint in the middle (fleet − 11, 0x1620D) and scrolls only as far as it
    /// must to keep the footprint inside the dead zone 11 ± `margin` (해상이동치 `[0xC35]`, 0x312AD);
    /// it stays inside the fleet's 720-tile third and the map's rows, and starts over when the fleet
    /// is in another third or far from the view.
    public static func seaViewOrigin(from old: (x: Int, y: Int)?, fleetX: Double, fleetY: Double, margin: Int) -> (x: Int, y: Int) {
        let fx = ((Int((fleetX - 0.5).rounded(.down)) % width) + width) % width
        let fy = Int((fleetY - 0.5).rounded(.down))
        let third = fx / 720, v = max(0, min(10, margin))
        var o = (x: fx - 11, y: fy - 11)
        if let old, (720 * third...720 * third + 696).contains(old.x), abs(fx - old.x) <= 24, abs(fy - old.y) <= 24 {
            o = old
            let dx = fx - o.x, dy = fy - o.y
            if dx < 11 - v { o.x = fx - (11 - v) } else if dx > 11 + v { o.x = fx - (11 + v) }
            if dy < 11 - v { o.y = fy - (11 - v) } else if dy > 11 + v { o.y = fy - (11 + v) }
        }
        o.x = max(720 * third, min(720 * third + 696, o.x))
        o.y = max(0, min(height - 24, o.y))
        return o
    }

    /// The fleet's 2×2 footprint around (x, y) is all sea (0x30AA0 tests the four tiles of a
    /// fleet; seamap.md: a chip of 0x34 or more blocks).
    public func fleetFits(x: Double, y: Double) -> Bool {
        let tx = (x - 0.5).rounded(.down), ty = (y - 0.5).rounded(.down)
        return isSea(x: tx, y: ty) && isSea(x: tx + 1, y: ty) && isSea(x: tx, y: ty + 1) && isSea(x: tx + 1, y: ty + 1)
    }

    /// Some port icons leave a 2×2 berth connected to open water only diagonally.
    /// Treat it as a narrow berth until the fleet reaches a cell with an ordinary exit.
    public func fleetCanManeuver(x: Double, y: Double) -> Bool {
        guard fleetFits(x: x, y: y) else { return false }
        let cx = (x - 0.5).rounded(.down) + 0.5, cy = (y - 0.5).rounded(.down) + 0.5
        return [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)].contains {
            fleetFits(x: cx + $0.0, y: cy + $0.1)
        }
    }

    public func isSea(x: Double, y: Double) -> Bool {
        let iy = Int(y.rounded(.down))
        guard iy >= 0, iy < World.height else { return false }
        let ix = Int(wrapX(x)) % World.width
        return tiles[iy * World.width + ix] == Terrain.sea.rawValue
    }

    /// Shortest signed east-west distance from a to b.
    public func deltaX(from a: Double, to b: Double) -> Double {
        let w = Double(World.width)
        var d = (b - a).truncatingRemainder(dividingBy: w)
        if d > w / 2 { d -= w }
        if d < -w / 2 { d += w }
        return d
    }

    public func nearestPort(x: Double, y: Double, within r: Double) -> Harbor? {
        var best: (Harbor, Double)?
        for p in ports {
            let dx = deltaX(from: x, to: Double(p.x)), dy = Double(p.y) - y
            let d = (dx * dx + dy * dy).squareRoot()
            if d <= r, d < (best?.1 ?? .infinity) { best = (p, d) }
        }
        return best?.0
    }

    /// A* over sea tiles from (x0, y0) to (x1, y1), eight ways, within `radius` tiles of the
    /// start; waypoints are thinned to the corners of the path. For rivers and coasts where a
    /// straight course runs aground.
    public func seaPath(from a: (x: Double, y: Double), to b: (x: Double, y: Double), radius: Int = 120) -> [(Double, Double)]? {
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite, radius >= 0,
              a.y >= 0, a.y < Double(World.height), b.y >= 0, b.y < Double(World.height),
              isSea(x: a.x, y: a.y), isSea(x: b.x, y: b.y) else { return nil }
        let sx = Int(wrapX(a.x)), sy = Int(a.y), tx = Int(wrapX(b.x)), ty = Int(b.y)
        // A berth can be a one-tile inlet. Stop on an adjacent navigable tile instead of
        // inserting an unchecked final waypoint that the fleet can never reach.
        let targetFits = fleetCanManeuver(x: Double(tx) + 0.5, y: Double(ty) + 0.5)
        func key(_ x: Int, _ y: Int) -> Int { (y + 1) * 4096 + ((x % World.width) + World.width) % World.width }
        func h(_ x: Int, _ y: Int) -> Int {
            let dx = abs(Int(deltaX(from: Double(x), to: Double(tx)))), dy = abs(ty - y)
            return 10 * max(dx, dy) + 4 * min(dx, dy)
        }
        var g: [Int: Int] = [key(sx, sy): 0], from: [Int: Int] = [:]
        var open = SeaPathFrontier()
        open.insert(f: h(sx, sy), x: sx, y: sy)
        var closed: Set<Int> = []
        var destination: Int?
        while let c = open.removeMinimum() {
            let ck = key(c.x, c.y)
            if closed.contains(ck) { continue }
            closed.insert(ck)
            let atTarget = key(c.x, c.y) == key(tx, ty)
            let besideBerth = !targetFits && abs(Int(deltaX(from: Double(c.x), to: Double(tx)))) <= 1
                && abs(c.y - ty) <= 1 && fleetFits(x: Double(c.x) + 0.5, y: Double(c.y) + 0.5)
            if atTarget || besideBerth { destination = ck; break }
            if closed.count > 40_000 { break }
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = c.x + dx, ny = c.y + dy
                    guard ny >= 0, ny < World.height, abs(nx - sx) <= radius, abs(ny - sy) <= radius,
                          fleetFits(x: Double(nx) + 0.5, y: Double(ny) + 0.5) else { continue }
                    // A diagonal destination can be water even when its corner cuts
                    // through a headland. Match the continuously moving 2×2 fleet.
                    let escapingBerth = ck == key(sx, sy) && !fleetCanManeuver(x: a.x, y: a.y)
                    if dx != 0 && dy != 0 && !escapingBerth {
                        guard fleetFits(x: Double(nx) + 0.5, y: Double(c.y) + 0.5),
                              fleetFits(x: Double(c.x) + 0.5, y: Double(ny) + 0.5) else { continue }
                    }
                    let nk = key(nx, ny), cost = g[ck]! + (dx != 0 && dy != 0 ? 14 : 10)
                    if cost < g[nk] ?? Int.max {
                        g[nk] = cost
                        from[nk] = ck
                        open.insert(f: cost + h(nx, ny), x: nx, y: ny)
                    }
                }
            }
        }
        guard var k = destination else { return nil }
        var cells: [(Int, Int)] = []
        while k != key(sx, sy) {
            guard let p = from[k] else { return nil }
            cells.append((k % 4096, k / 4096 - 1))
            k = p
        }
        // A valid, already-reached destination still has one point for callers to follow.
        if cells.isEmpty { return [(Double(sx) + 0.5, Double(sy) + 0.5)] }
        cells.reverse()
        // Keep only the points where the direction changes.
        var out: [(Double, Double)] = []
        for (n, c) in cells.enumerated() {
            if n == cells.count - 1 || n == 0 { out.append((Double(c.0) + 0.5, Double(c.1) + 0.5)); continue }
            let p = cells[n - 1], q = cells[n + 1]
            if (c.0 - p.0, c.1 - p.1) != (q.0 - c.0, q.1 - c.1) { out.append((Double(c.0) + 0.5, Double(c.1) + 0.5)) }
        }
        return out
    }

    /// Nearest sea tile around a port, used to place a ship leaving harbour.
    public func berth(of port: Harbor) -> (x: Double, y: Double)? {
        for r in 0...12 {
            for dy in -r...r {
                for dx in -r...r where max(abs(dx), abs(dy)) == r {
                    let x = Double(port.x + dx) + 0.5, y = Double(port.y + dy) + 0.5
                    if isSea(x: x, y: y) { return (wrapX(x), y) }
                }
            }
        }
        return nil
    }
}

/// A stable min-heap keeps coastal A* searches O(log n) per frontier operation, including
/// failed searches over large areas. Equal priorities retain the old insertion order.
private struct SeaPathFrontier {
    struct Entry {
        let f: Int
        let order: Int
        let x: Int
        let y: Int

        func precedes(_ other: Entry) -> Bool {
            f < other.f || (f == other.f && order < other.order)
        }
    }

    private var heap: [Entry] = []
    private var nextOrder = 0

    mutating func insert(f: Int, x: Int, y: Int) {
        heap.append(Entry(f: f, order: nextOrder, x: x, y: y))
        nextOrder += 1
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].precedes(heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    mutating func removeMinimum() -> Entry? {
        guard !heap.isEmpty else { return nil }
        if heap.count == 1 { return heap.removeLast() }
        let minimum = heap[0]
        heap[0] = heap.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1
            guard left < heap.count else { break }
            let right = left + 1
            let child = right < heap.count && heap[right].precedes(heap[left]) ? right : left
            guard heap[child].precedes(heap[parent]) else { break }
            heap.swapAt(parent, child)
            parent = child
        }
        return minimum
    }
}
