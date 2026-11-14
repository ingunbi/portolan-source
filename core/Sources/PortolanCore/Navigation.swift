import Foundation

// Sailing rules recovered from MAIN.EXE. Image addresses are listed per rule; see
// docs/RE_NOTES.md. Directions are the game's eight points: 0 = north, clockwise.

public struct ShipClass: Codable, Equatable {
    public let name: String
    public let unknown0: Int
    public let hull: Int
    public let rudder: Int
    public let sail: Int
    public let guns: Int
    public let minCrew: Int
    public let capacity: Int
    public let unknown8: Int
    public let sailType: Int
    public let price: Int
    public let oars: Bool
    /// Shipyards carry the class only where industry reaches this (byte 0 × 10, 0x1B8A6).
    public let requiredIndustry: Int
    /// From the class template ship: gun ports, berths, and what is left for cargo.
    public let gunCapacity: Int
    public let crewCapacity: Int
    public let cargoCapacity: Int
    /// Template flag 0x40. Coastal craft and galleys take five times the storm damage (0x1963B).
    public let oceanGoing: Bool
    /// Range of the crew and gun split a yard can give the class (0x2AB31).
    public let maxCrew: Int
    public let maxGuns: Int
}

public struct Cannon: Codable, Equatable {
    public let name: String
    /// Tables DS:0x818, 0x828, 0x838; used by sea battles, which are not decoded yet.
    public let power: Int
    public let range: Int
    public let stat3: Int
    public let price: Int
}

public struct Hero: Codable, Equatable {
    public let name: String
    public let leadership: Int
    public let seamanship: Int
    public let knowledge: Int
    public let intuition: Int
    public let courage: Int
    public let swordplay: Int
    public let charm: Int
    public let luck: Int
    public let navLevel: Int
    public let battleLevel: Int
    public let fleet: Int
    /// Index into `World.ports` nearest the hero's fleet in the new-game data.
    public let port: Int
    /// Person +0x31 & 0xF.
    public let nation: Int
    public let skills: Int
}

/// New-game data segment (DATA1.LZW entry 15, DS:0xC30 onward).
public struct NewGame: Codable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let tick: Int
    public let gold: Int
    public let heroes: [Hero]
    public let persons: [Person]
}

public struct NavigationData: Codable {
    public let sailTable: [[Int]]
    public let windSummer: [Int]
    public let windWinter: [Int]
    public let current: [Int]
    public let classes: [ShipClass]
    public let newGame: NewGame
    public let markets: [Market]
    public let drinks: [Drink]
    public let zones: [TradeZone]
    public let goods: [Good]
    public let categories: [String]
    /// Classes each shipyard region may stock (DS:0xAECE, 11 × 8) and the common list (DS:0xAF26).
    public let shipRegions: [[Int]]
    public let commonShips: [Int]
    /// Cannon types 1...7 (index 0 here is type 1): names DS:0x808, price DS:0x848.
    public let cannons: [Cannon]

    public init(assets: URL) throws {
        self = try JSONDecoder().decode(NavigationData.self,
                                        from: Data(contentsOf: assets.appendingPathComponent("navigation.json")))
    }
}

/// The C library generator used by the game (0x4D54): seed * 1103515245 + 12345.
public struct GameRandom: Codable {
    public var seed: UInt32
    public init(seed: UInt32) { self.seed = seed }

    public mutating func next() -> Int {
        seed = seed &* 0x41C6_4E6D &+ 0x3039
        return Int((seed >> 16) & 0x7FFF)
    }

    /// rand(n) at 0x4D86; rand(0) is 0.
    public mutating func callAsFunction(_ n: Int) -> Int {
        n == 0 ? 0 : next() % n
    }
}

public struct Weather: Codable, Equatable {
    public var windDir: Int
    public var windStrength: Int
    public var currentDir: Int
    public var currentStrength: Int
    /// Bits 6 and 7 of the zone bytes mark storm and incident areas (0x19474).
    public var windFlags: Int
    public var currentFlags: Int

    public init(windDir: Int, windStrength: Int, currentDir: Int, currentStrength: Int,
                windFlags: Int = 0, currentFlags: Int = 0) {
        self.windDir = windDir
        self.windStrength = windStrength
        self.currentDir = currentDir
        self.currentStrength = currentStrength
        self.windFlags = windFlags
        self.currentFlags = currentFlags
    }
}

public struct Ship: Codable {
    @ShipIdentity public var shipInstanceID: UUID
    public var name = ""
    public var classIndex: Int
    public var hull: Int
    public var maxHull: Int
    public var crew: Int
    public var rudder: Int
    public var sail: Int
    public var guns: Int
    public var water: Int
    public var food: Int
    public var lumber = 0
    public var shot = 0
    /// Trade goods in up to five holds (cargo record +0xC amounts, +0x16 goods).
    public var holds: [CargoLot] = []
    public var crewCapacity: Int
    public var cargoCapacity: Int
    public var gunCapacity: Int
    /// Ship slot byte 8 & 7: cannon type 1...7, 0 for none.
    public var gunType = 0
    /// Share of the crew working the sails, cargo record byte 9.
    public var sailorShare = 50
    /// Cargo record +8: share of the crew on watch (파수), 25 by default. The rest of the
    /// crew, `100 − watch − sail` percent, works the guns and boards in battle.
    public var watchShare = 25
    /// Ship record byte 0x13 & 7: hull material, 2 for every yard template.
    public var material = 2
    public var morale = 100
    /// Cargo record +0x1D: figurehead 0 (none) to 10 (goddess). Wards off sea incidents (0x194F4).
    public var figurehead = 0

    public init(class index: Int, in data: NavigationData, crew: Int, water: Int, food: Int) {
        let c = data.classes[index]
        classIndex = index
        hull = c.hull
        maxHull = c.hull
        self.crew = crew
        rudder = c.rudder
        sail = c.sail
        guns = 0
        crewCapacity = c.crewCapacity
        cargoCapacity = c.cargoCapacity
        gunCapacity = c.gunCapacity
        self.water = water
        self.food = food
    }

    /// A ship as the shipyard hands it over (0x31C64): nine tenths of the class hull,
    /// no crew, guns or stores.
    public static func built(class index: Int, named name: String, in data: NavigationData) -> Ship {
        var s = Ship(class: index, in: data, crew: 0, water: 0, food: 0)
        s.name = name
        s.hull = 9 * data.classes[index].hull / 10
        s.maxHull = s.hull
        return s
    }

    /// Hold contents (0x5C2A): supplies count one tenth, so one barrel is ten units.
    public var cargoLoad: Int { water / 10 + food / 10 + lumber + shot + goods }
    public var goods: Int { holds.reduce(0) { $0 + $1.amount } }
    /// Total load used by the speed rule (0x5C7F).
    public var load: Int { cargoLoad + guns + crew }
    public var freeCargo: Int { max(0, cargoCapacity - cargoLoad) }
    public var vacancies: Int { max(0, crewCapacity - crew) }
}

public struct CargoLot: Codable, Equatable {
    public var good: Int
    public var amount: Int
    public init(good: Int, amount: Int) {
        self.good = good
        self.amount = amount
    }
}

public struct Captain: Codable {
    public var name = "조안 페레로"
    public var leadership: Int
    public var seamanship: Int
    public var knowledge: Int
    public var intuition = 0
    public var courage = 0
    public var swordplay = 0
    public var charm: Int
    public var luck: Int
    public var navLevel: Int
    public var battleLevel = 1
    /// Experience toward the next navigation level (person +0x26), and battle (+0x28).
    public var navExp = 0
    public var battleExp = 0
    /// KAO.LZW portrait (person +0x1A).
    public var face = 0
    /// Person +0x31 & 0xF: the nation served, in market support order.
    public var nation = 0
    /// Person +0x30. Bit 0 lets the hero talk a trader down to the floor (0x2414B).
    public var skills = 1

    public init(leadership: Int, seamanship: Int, knowledge: Int, charm: Int, luck: Int, navLevel: Int) {
        self.leadership = leadership
        self.seamanship = seamanship
        self.knowledge = knowledge
        self.charm = charm
        self.luck = luck
        self.navLevel = navLevel
    }

    public init(_ h: Hero) {
        self.init(leadership: h.leadership, seamanship: h.seamanship, knowledge: h.knowledge, charm: h.charm,
                  luck: h.luck, navLevel: h.navLevel)
        name = h.name
        intuition = h.intuition
        courage = h.courage
        swordplay = h.swordplay
        battleLevel = h.battleLevel
        nation = h.nation
        skills = h.skills
    }

    /// The hero as the person record has it.
    public init(person r: Person, face: Int) {
        self.init(leadership: r.stats[0], seamanship: r.stats[1], knowledge: r.stats[2], charm: r.stats[6],
                  luck: r.stats[7], navLevel: r.navLevel)
        name = r.name
        intuition = r.stats[3]
        courage = r.stats[4]
        swordplay = r.stats[5]
        battleLevel = r.battleLevel
        navExp = r.navExp
        battleExp = r.battleExp
        nation = r.nation
        skills = r.skills
        self.face = face & 0x3FFF
    }

    /// The seven abilities in record order (+0x1C): leadership, seamanship, knowledge,
    /// intuition, courage, swordplay, charm.
    public var abilities: [Int] { [leadership, seamanship, knowledge, intuition, courage, swordplay, charm] }
    /// All eight, with luck last, as in a person record.
    public var stats: [Int] { abilities + [luck] }

    /// Joan Ferrero in a new game (person record DS:0x1242).
    public static let joan: Captain = {
        var c = Captain(leadership: 78, seamanship: 75, knowledge: 73, charm: 89, luck: 50, navLevel: 1)
        c.intuition = 85
        c.courage = 82
        c.swordplay = 82
        return c
    }()
}

public enum Navigation {
    public static let ticksPerDay = 72
    public static let tileUnits = 60
    public static let weatherInterval = 12
    public static let zoneSize = 72

    static let dx = [0, 1, 1, 1, 0, -1, -1, -1]
    static let dy = [-1, -1, 0, 1, 1, 1, 0, -1]

    /// 72x72-tile zone of WINDCUR.DAT (0x22A0D).
    public static func zone(x: Int, y: Int) -> Int {
        (y / zoneSize) * 30 + x / zoneSize
    }

    /// Daily roll of the zone wind (0x199EC): strength may rise by one, direction may veer.
    public static func roll(windByte w: Int, currentByte c: Int, rng: inout GameRandom) -> Weather {
        let strength = min(7, (w & 7) + rng(2))
        let r3 = rng(3)
        let r5 = rng(5)
        let veer = ((r3 - 1) * (r5 >> 2)) << 3
        let dir = ((veer + (w & 0xF8)) & 0x38) >> 3
        return Weather(windDir: dir, windStrength: strength, currentDir: (c >> 3) & 7, currentStrength: c & 7,
                       windFlags: w & 0xC0, currentFlags: c & 0xC0)
    }

    /// Fleet speed in half knots (0x30C2F). Integer steps follow the original.
    public static func fleetSpeed(ships: [Ship], captain: Captain, heading: Int, windDir: Int, windStrength: Int,
                                  data: NavigationData) -> Int {
        let angle = abs(windDir - heading)
        let row = data.sailTable[angle]
        let headwind = (3...5).contains(angle)
        var slowest = 200
        var oared = 0
        for ship in ships {
            let c = data.classes[ship.classIndex]
            var wind = windStrength
            if c.oars {
                wind = max(windStrength, 3)
                oared += 1
            }
            var a = (row[c.sailType] * ship.sail * wind / 150) & 0xFF
            let manned = min(100, ship.sailorShare * ship.crew / c.minCrew)
            a = (manned * a / 100) & 0xFF
            let trim = min(150, -100 * ship.load / c.capacity + 180)
            a = (max(0, trim) * a / 100) & 0xFF
            var s = min(30, captain.navLevel * a / 10 + a)
            s = min(40, captain.seamanship * s / 75)
            if headwind { s = ship.rudder * s / 100 }
            slowest = min(slowest, s)
        }
        slowest = max(2, slowest)
        if windStrength == 0 && oared == 0 { return 0 }     // becalmed without oars
        return slowest
    }

    /// Per-tick displacement in 1/60 tile, before current (0x30E6E).
    public static func step(heading: Int, speed: Int) -> (Int, Int) {
        (dx[heading] * speed, dy[heading] * speed)
    }

    public static func currentStep(_ w: Weather) -> (Int, Int) {
        (dx[w.currentDir] * w.currentStrength, dy[w.currentDir] * w.currentStrength)
    }

    /// Barrels used per day by a ship's crew (0x18A3C water, 0x18AEE food).
    /// The divisor doubles while exploring ashore.
    public static func dailyUse(crew: Int, ration: Int, ashore: Bool = false) -> Int {
        crew * ration / (ashore ? 200 : 100) + 1
    }

    /// Morale change for a supplied ship (0x18A3C). Negative values raise morale.
    public static func moraleLoss(leadership: Int, ration: Int) -> Int {
        let v = -(leadership / 5 - 100) - ration
        return v > 0 ? v / 5 : v / 10
    }

    public static let starvationMoraleLoss = 16
    public static let mutinyMorale = 20

    static let monthDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    public static func daysIn(month: Int, year: Int) -> Int {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return monthDays[month] + (month == 1 && leap ? 1 : 0)
    }
}
