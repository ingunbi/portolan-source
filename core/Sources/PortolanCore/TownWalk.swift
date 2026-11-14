import Foundation

// The walking town (항구 시가지, docs/re/town_walk.md): the hero walks the 96×96-tile town map a
// tile at a time, townsfolk wander, and a door tile enters its building. Positions live where
// the original keeps them, inside the saved data segment: camera [0xC40]/[0xC42], walker in the
// window [0xC44]/[0xC46], townsfolk DS:0xC48 + 3i, last town loaded [0xC3B], talk cooldown [0x950E].

/// One town map: PORTMAP tile numbers, the chip set's walk thresholds and the door tiles.
public struct TownMap {
    public static let size = 96
    public let map: Int
    public let tiles: [UInt8]
    /// PORTCHIP entry 2s+1 bytes 1..3 (0x8747).
    public let walk: (a: Int, b: Int, c: Int)
    /// Door tile of each building (MENU 58 order = `HarborPanel`), from ZA_DAT.DAT.
    public let doors: [Int: (x: Int, y: Int)]

    public func tile(_ x: Int, _ y: Int) -> Int {
        guard (0..<TownMap.size).contains(x), (0..<TownMap.size).contains(y) else { return 0xFF }
        return Int(tiles[y * TownMap.size + x])
    }

    /// 0x5F6A / 0x5FF4: only the feet row of the 2×2 sprite is tested.
    public func walkable(_ x: Int, _ y: Int) -> Bool {
        let l = tile(x, y + 1), r = tile(x + 1, y + 1)
        return l < walk.b && (r < walk.a || (walk.b <= r && r < walk.c))
    }

    /// Loads the towns of all 130 ports from `assets/portmaps` (tools/portmaps.py).
    public static func load(assets: URL) -> [TownMap?] {
        struct Port: Decodable {
            let port: Int
            let map: Int
            let chipSet: Int
            let doors: [String: [Int]]
        }
        struct File: Decodable {
            let buildings: [String]
            let walk: [[Int]]
            let ports: [Port]
        }
        let dir = assets.appendingPathComponent("portmaps")
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("portmaps.json")),
              let f = try? JSONDecoder().decode(File.self, from: d) else { return [] }
        var maps: [Int: [UInt8]] = [:]
        return f.ports.map { p in
            if maps[p.map] == nil {
                maps[p.map] = (try? [UInt8](Data(contentsOf: dir.appendingPathComponent(String(format: "%03d.tiles", p.map))))) ?? []
            }
            guard let tiles = maps[p.map], tiles.count == size * size, f.walk.indices.contains(p.chipSet) else { return nil }
            let w = f.walk[p.chipSet]
            var doors: [Int: (x: Int, y: Int)] = [:]
            for (k, name) in f.buildings.enumerated() {
                if let xy = p.doors[name], xy.count == 2 { doors[k] = (xy[0], xy[1]) }
            }
            return TownMap(map: p.map, tiles: tiles, walk: (w[1], w[2], w[3]), doors: doors)
        }
    }
}

/// What a step attempt did (0x6568).
public enum TownStep: Equatable {
    case moved
    /// Turned in place: the window edge, or nowhere to slide.
    case stayed
    /// Bumped into a townsperson (0x63A1); the talk code of `townTalk`.
    case talk(Int)
}

/// One townsperson to draw: slot 0..7, top-left tile, and the CHAR.LZW sprite.
public struct Townsperson: Equatable {
    public let slot: Int
    public let x: Int, y: Int
    /// Walkers (slots 0–3): facing 0 up, 1 right, 2 down, 3 left. Standing figures: kind
    /// 0 man, 1 dog, 2 guard, 3 merchant.
    public let k: Int
    public var walker: Bool { slot < 4 }
}

extension Voyage {
    static let townDirs = [(0, -1), (1, 0), (0, 1), (-1, 0)]

    var townCameraX: Int { get { memory.word(0xC40) } set { memory.setWord(0xC40, newValue) } }
    var townCameraY: Int { get { memory.word(0xC42) } set { memory.setWord(0xC42, newValue) } }
    var townWinX: Int { get { memory.word(0xC44) } set { memory.setWord(0xC44, newValue) } }
    var townWinY: Int { get { memory.word(0xC46) } set { memory.setWord(0xC46, newValue) } }

    /// The window origin, in tiles (24×24 tiles shown).
    public var townCamera: (x: Int, y: Int) { (townCameraX, townCameraY) }
    /// The hero's top-left tile.
    public var townHero: (x: Int, y: Int) { (townCameraX + townWinX, townCameraY + townWinY) }

    /// Night in town (0x603B): before 04:00 or from 20:00 nobody is about.
    public var townNight: Bool { tick < 12 || tick >= 60 }

    /// Town entry (0x8AB2). Coming from sea the hero stands below the harbour door facing down
    /// and the townsfolk are placed; a save made in this town keeps everyone where they were.
    public mutating func arriveInTown(port: Int, map: TownMap) {
        guard memory[0xC3B] != port else { return }
        if memory[0xC3B] == 0xFF, let h = map.doors[3] {
            townCameraX = max(0, min(72, h.x - 12))
            townCameraY = max(0, min(72, h.y - 13))
            townWinX = h.x - townCameraX
            townWinY = h.y + 1 - townCameraY
            townsfolkInit(port: port, map: map)
        }
        memory[0xC3B] = port
        memory[0x950E] = 10
    }

    /// Leaving port (0x273C3).
    public mutating func leaveTown() { memory[0xC3B] = 0xFF }

    // MARK: townsfolk

    func folk(_ i: Int) -> (x: Int, y: Int, k: Int) { (memory[0xC48 + 3 * i], memory[0xC49 + 3 * i], memory[0xC4A + 3 * i]) }
    mutating func setFolk(_ i: Int, _ x: Int, _ y: Int, _ k: Int) {
        memory[0xC48 + 3 * i] = x & 0xFF
        memory[0xC49 + 3 * i] = y & 0xFF
        memory[0xC4A + 3 * i] = k & 0xFF
    }

    /// 0x8993: a walker left of and a figure right of the 교역소, 주점, 조선소 and 여관 doors (a
    /// walker on the 조선소 door, no figure there); blockade guards below the harbour door.
    mutating func townsfolkInit(port: Int, map: TownMap) {
        for (i, b) in [0, 1, 2, 4].enumerated() {
            guard let d = map.doors[b] else {
                setFolk(i, 0xFF, 0xFF, 2)
                setFolk(4 + i, 0xFF, 0xFF, i)
                continue
            }
            setFolk(i, d.x - 2, d.y + 1, 2)
            setFolk(4 + i, d.x + 2, d.y + 1, i)
            if i == 2 {
                setFolk(2, d.x, d.y, 2)
                setFolk(6, 0xFF, 0xFF, 2)
            }
        }
        if let h = map.doors[3], blockaded(port: port), townHero == (h.x, h.y + 1) {    // war.md §4.1
            setFolk(4, h.x - 2, h.y + 2, 2)
            setFolk(5, h.x, h.y + 2, 2)
            setFolk(6, h.x + 2, h.y + 3, 2)
        }
    }

    /// 0x28123: the harbour master may send the guards away early or late in the day.
    public mutating func harbourDropsGuards() {
        guard tick <= 18 || tick >= 54, rng(3) == 0 else { return }
        for i in 4..<8 where folk(i).k == 2 && folk(i).x != 0xFF { setFolk(i, 0xFF, 0xFF, 2) }
    }

    /// 0x6050: a slot within one tile of (x, y): slot + 1, 7 for any guard; for a townsperson
    /// the hero counts too. Nobody collides at night.
    func townCollide(_ me: Int, _ x: Int, _ y: Int) -> Int {
        guard !townNight else { return 0 }
        for j in 0..<8 where j != me {
            let f = folk(j)
            guard f.x != 0xFF, abs(f.x - x) <= 1, abs(f.y - y) <= 1 else { continue }
            return j >= 4 && f.k == 2 ? 7 : j + 1
        }
        if me >= 0 {
            let h = townHero
            if abs(h.x - x) <= 1 && abs(h.y - y) <= 1 { return 1 }
        }
        return 0
    }

    /// npc_tick (0x6147), once per pass of the walk loop.
    public mutating func townsfolkTick(port: Int, map: TownMap) {
        if townNight {
            townsfolkInit(port: port, map: map)
            return
        }
        for i in 0..<4 {
            let f = folk(i)
            guard f.x != 0xFF else { continue }
            let d = rng(10) == 0 ? rng(4) : f.k
            var (x, y) = (f.x, f.y)
            if rng(3) == 0 {
                x += Voyage.townDirs[d].0
                y += Voyage.townDirs[d].1
            }
            if townCollide(i, x, y) == 0 && (0..<94).contains(x) && (0..<94).contains(y) && map.walkable(x, y) {
                setFolk(i, x, y, d)
            } else {
                setFolk(i, f.x, f.y, (d + rng(3) - 1) & 3)
            }
        }
    }

    /// Who is about, for drawing (nobody at night).
    public var townsfolk: [Townsperson] {
        guard !townNight else { return [] }
        return (0..<8).compactMap { i in
            let f = folk(i)
            return f.x == 0xFF ? nil : Townsperson(slot: i, x: f.x, y: f.y, k: f.k)
        }
    }

    // MARK: the hero

    /// One step (0x6568): bump-to-talk, the sideways slide around an obstacle, the camera
    /// margin of four tiles. The townsfolk move afterwards, as in the original.
    public mutating func townStep(_ dir: Int, port: Int, map: TownMap) -> TownStep {
        var (dx, dy) = Voyage.townDirs[dir & 3]
        guard (0...22).contains(townWinX + dx), (0...22).contains(townWinY + dy) else {
            townsfolkTick(port: port, map: map)
            return .stayed
        }
        let p0 = townHero
        let r = townCollide(-1, p0.x + dx, p0.y + dy)
        if r != 0 && memory[0x950E] >= 10 {
            memory[0x950E] = 0
            return .talk(r)
        }
        if memory[0x950E] < 10 { memory[0x950E] += 1 }
        func free(_ x: Int, _ y: Int) -> Bool { map.walkable(x, y) && townCollide(-1, x, y) == 0 }
        var moved = true
        if !free(p0.x + dx, p0.y + dy) {
            var k = [1: 20, -1: 20]
            for s in [1, -1] {
                for n in 1..<20 {
                    let q = (p0.x + s * n * dy, p0.y + s * n * dx)
                    guard (0...94).contains(q.0), (0...94).contains(q.1), free(q.0, q.1) else { break }
                    let q2 = (q.0 + dx, q.1 + dy)
                    guard (0...94).contains(q2.0), (0...94).contains(q2.1) else { break }
                    if free(q2.0, q2.1) {
                        k[s] = n
                        break
                    }
                }
            }
            if k[1] == 20 && k[-1] == 20 {
                moved = false
            } else {
                let s = k[-1]! > k[1]! ? 1 : -1
                (dx, dy) = (s * dy, s * dx)
            }
        }
        if moved {
            townWinX += dx
            townWinY += dy
            if (dx == -1 && townWinX < 4 && townCameraX > 0) || (dx == 1 && townWinX > 18 && townCameraX < 72) {
                townWinX -= dx
                townCameraX += dx
            }
            if (dy == -1 && townWinY < 4 && townCameraY > 0) || (dy == 1 && townWinY > 18 && townCameraY < 72) {
                townWinY -= dy
                townCameraY += dy
            }
        }
        townsfolkTick(port: port, map: map)
        return moved ? .moved : .stayed
    }

    /// The facing after a step: the slide direction when the hero slid (0x6568).
    public static func townFacing(from a: (x: Int, y: Int), to b: (x: Int, y: Int), tried dir: Int) -> Int {
        let dx = b.x - a.x, dy = b.y - a.y
        if dx == 0 && dy == 0 { return dir }
        return dy < 0 ? 0 : dy > 0 ? 2 : dx < 0 ? 3 : 1
    }

    /// 0x5F1F: the building whose door is the hero's top-left tile.
    public func townDoor(map: TownMap) -> Int? {
        let h = townHero
        return (0..<12).first { k in map.doors[k].map { $0.x == h.x && $0.y == h.y } ?? false }
    }

    /// Entering a building puts the hero one tile below its door (0x1B08E).
    public mutating func townEnterDoor() { townWinY += 1 }

    /// What a townsperson says (0x63A1); pure flavour.
    public func townTalk(_ r: Int, port: Int, in world: World) -> [TownLine] {
        let m = port < 100 ? market(in: world) : nil
        let nation = m?.nation ?? 6
        switch r {
        case 1: return [.msg(642 + port)]
        case 2: return [.msg(630 + dayOfMonth % 10)]
        case 3:
            let stock = shipyardStocks.first { $0.port == port } ?? shipyardStocks.first
            if let c = stock?.classes.first, world.navigation.classes.indices.contains(c) {
                return [.msg(640, world.navigation.classes[c].name)]
            }
            return [.msg(641)]
        case 4: return [.msg(623 + min(6, nation))]
        case 5:
            let name = memory.string(DS.port + DS.portSize * port + 4, max: 14)
            if port >= 100 { return [.msg(578, name)] }
            let nationName = nation < 6 ? memory.name(0x866, nation) : ""
            if isCapital(port) { return [.msg(579, nationName, name)] }
            if nation < 6 {
                let kind = memory[DS.port + DS.portSize * port + 0x13] & 0x80 != 0 ? "식민지" : "동맹항"
                return [.msg(580, nationName, kind, name)]
            }
            return [.msg(581, name)]
        case 6: return [.msg(619 + port % 3)]
        case 7: return [.msg(622, memory.name(0x866, min(6, memory.pb(heroID, 0x31) & 0xF)))]
        default:
            if let s = m?.specialty, s < world.navigation.goods.count {
                return [.msg(616), .msg(617, world.navigation.goods[s].name)]
            }
            return [.msg(616), .msg(618)]
        }
    }
}

extension World {
    /// The town of port `p`, if its map was exported.
    public func town(_ p: Int) -> TownMap? { towns.indices.contains(p) ? towns[p] : nil }
}
