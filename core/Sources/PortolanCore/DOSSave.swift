import Foundation

/// The original's save file KOUKAI2.DAT (newgame.md §8.1): ten slots, each a 15-byte header
/// at 1 + 15·s and the data segment DS:0xC30..0x8B6B plus the 0x300-byte voyage log at
/// 0x97 + 33340·s. A slot is turned into a remaster voyage by laying its bytes over the
/// new-game data segment and rebuilding the Swift side from the records.
public struct DOSSave {
    public static let slots = 10
    static let slotSize = 33340
    static let dataStart = 0xC30, dataEnd = 0x8B6C

    public struct Header: Equatable {
        public let date: String
        /// The port the save was made in, nil at sea.
        public let port: Int?
        /// 0 normal, 2 after a story ending, 3 after the rank ending.
        public let type: Int
    }

    public let bytes: [UInt8]

    public init?(url: URL) {
        guard let d = try? [UInt8](Data(contentsOf: url)), d.count >= 0x97 + DOSSave.slotSize * DOSSave.slots else { return nil }
        bytes = d
    }

    public func header(_ s: Int) -> Header? {
        let h = Array(bytes[(1 + 15 * s)..<(1 + 15 * s + 15)])
        guard h[0] != 0 else { return nil }
        let date = String(decoding: h[0..<12].prefix { $0 != 0 }, as: UTF8.self)
        return Header(date: date, port: h[12] == 0xFF ? nil : Int(h[12]), type: Int(h[13]))
    }

    /// The slot as a remaster voyage, or nil when the slot is empty.
    public func voyage(slot s: Int, in world: World) -> Voyage? {
        guard header(s) != nil, var memory = world.memory else { return nil }
        let base = 0x97 + DOSSave.slotSize * s
        for n in DOSSave.dataStart..<DOSSave.dataEnd { memory[n] = Int(bytes[base + n - DOSSave.dataStart]) }
        let log = Array(bytes[(base + DOSSave.dataEnd - DOSSave.dataStart)..<(base + DOSSave.dataEnd - DOSSave.dataStart + 0x300)])
        return Voyage.fromDOS(memory: memory, log: log, in: world)
    }
}

extension Voyage {
    /// Rebuilds a voyage from an original data segment (the save slot over the new-game image).
    static func fromDOS(memory m: DataSegment, log: [UInt8], in world: World) -> Voyage {
        let hero = m[DS.heroID]
        var v = Voyage.newGame(in: world, hero: min(5, hero))
        v.memory = m
        // The date the save copied to DS:0xC36..0xC39 (0x1661A): years since 1501, month, day, tick.
        v.year = 1501 + m[0xC36]
        v.month = min(11, m[0xC37])
        v.dayOfMonth = min(30, m[0xC38])
        v.tick = min(71, m[0xC39])
        v.daysAtSea = m[DS.daysAtSea]
        // Incidents [0xC3F]: event 1 storm, 2 calm, 3 fog; 0x10 rats, 0x20 scurvy.
        let inc = m[0xC3F]
        v.event = [1: SeaEvent.storm, 2: .calm, 3: .fog][inc & 0xF]
        v.eventAnnounced = v.event != nil
        v.epidemic = inc & 0x10 != 0
        v.scurvy = inc & 0x20 != 0
        v.stormShelter = m[0x1032]

        // The markets of the 100 trading ports (DS:0x697C, 37 bytes).
        v.markets = world.navigation.markets.enumerated().map { i, base in
            var mk = base
            guard i < 100 else { return mk }
            let r = DS.market + DS.marketSize * i
            mk.economy = m.word(r)                                 // +2 / +6 are this month's investments
            mk.industry = m.word(r + 4)
            mk.support = (0..<6).map { m[r + 8 + $0] }
            mk.prices = (0..<10).map { m[r + 14 + $0] }
            mk.nation = m[DS.port + DS.portSize * i + 0x13] & 7
            return mk
        }

        // The ships of the player's fleet: slot +7 points at the ship record, the cargo record
        // of the same slot names the captain (+0x1B). The hero's ship goes first.
        // [0xC6DA] lies outside the saved block; the hero's fleet is person +0x2C.
        let fleet = DS.fleet(m.pb(hero, 0x2C))
        var found: [(ship: Ship, captain: Int)] = []
        for i in 0..<10 {
            let slot = fleet + 0x2B + 9 * i
            guard m[slot + 8] & 0x30 == 0x10 else { continue }
            let rec = DS.ship + DS.shipSize * m[slot + 7]
            let cls = min(world.navigation.classes.count - 1, m[rec + 0x12])
            var s = Ship(class: cls, in: world.navigation, crew: m.word(slot), water: 0, food: 0)
            s.name = m.string(rec, max: 14)
            s.material = m[rec + 0x13] & 7
            s.gunCapacity = m[rec + 0x14]
            s.crewCapacity = m.word(rec + 0x15)
            s.cargoCapacity = m.word(rec + 0x17)
            s.hull = m[slot + 2]
            s.maxHull = m[slot + 3]
            s.rudder = m[slot + 4]
            s.sail = m[slot + 5]
            s.guns = m[slot + 6]
            s.gunType = m[slot + 8] & 7
            let c = DS.cargo + DS.cargoSize * i
            s.water = m.word(c)
            s.food = m.word(c + 2)
            s.lumber = m.word(c + 4)
            s.shot = m.word(c + 6)
            s.watchShare = m[c + 8]
            s.sailorShare = m[c + 9]
            s.holds = (0..<5).compactMap { k in
                m[c + 0x16 + k] == 0xFF || m.word(c + 0xC + 2 * k) == 0 ? nil : CargoLot(good: m[c + 0x16 + k], amount: m.word(c + 0xC + 2 * k))
            }
            s.morale = m[c + 0x1C]
            s.figurehead = m[c + 0x1D]
            found.append((s, m[c + 0x1B]))
        }
        if let k = found.firstIndex(where: { $0.captain == hero }), k > 0 { found.insert(found.remove(at: k), at: 0) }
        v.ships = found.map(\.ship)

        // The hero, companions, purse, fame and holds; then the captains go in ship order, as
        // the remaster has officer i − 1 command ship i.
        v.memory.setWord(0xC6DA, fleet)                            // the pointer the running game keeps
        v.importFromMemory(in: world)
        v.ships = found.map(\.ship)                                 // (the import reads slot i as record i)
        var captains: [Officer] = []
        for (_, p) in found.dropFirst() {
            if let k = v.officers.firstIndex(where: { $0.person == p }) {
                var o = v.officers.remove(at: k)
                o.post = nil
                captains.append(o)
            }
        }
        v.officers = captains + v.officers

        // Where the fleet is: in a port ([0xC3A]) or at sea at the fleet record's tile.
        let port = m[DS.currentPort]
        if port < world.ports.count {
            let h = world.ports[port]
            v.x = Double(h.x) + 0.5
            v.y = Double(h.y) + 0.5
            if port < 100 { v.marketIndex = port }
            v.sail = 0
            v.restockShipyard(port: port, in: world)
        } else {
            v.x = Double(m.word(fleet) % World.width) + 0.5            // fleet record +0 / +2: the tile
            v.y = Double(min(World.height - 1, m.word(fleet + 2))) + 0.5
            v.sail = 0
            v.anchored = true
        }
        v.memory[0xC3B] = 0x82                                     // keep the town positions (0x170C7)

        // The voyage log: 48 entries of 16 bytes, a first word 0xFFFF ends it (info.md §1.9).
        v.logbook = []
        for k in 0..<48 {
            let e = Array(log[(16 * k)..<(16 * k + 16)])
            let w = { (o: Int) in Int(e[o]) | Int(e[o + 1]) << 8 }
            if w(0) == 0xFFFF { break }
            v.logbook.append(LogEntry(date: w(0), type: w(2), a: w(4), b: w(6), c: w(8), d: w(10)))
        }
        v.afterLoad()
        return v
    }
}
