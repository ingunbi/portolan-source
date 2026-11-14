import Foundation

/// The player's fleet at sea. Time advances in the game's 72 ticks per day. Speed,
/// wind, current, supplies and morale follow the decoded rules in `Navigation`.
public struct Voyage: Codable {
    /// Persistence metadata is encoded by SaveEnvelope, not in original game state.
    public var saveContext = SaveContext()
    /// Real seconds per game day. Presentation choice; the original waits on the CPU.
    public static var secondsPerDay = 2.4
    public static let maxSail = 1

    public var x: Double
    public var y: Double
    /// Radians in screen space: 0 = east, clockwise.
    public var heading = Double.pi
    public var sail = 0
    /// Optional array storage keeps the current leg in JSON saves. Older saves omit it.
    private var savedWaypoint: [Double]?
    public var waypoint: (x: Double, y: Double)? {
        get {
            guard let point = savedWaypoint, point.count == 2, point.allSatisfy(\.isFinite) else { return nil }
            return (point[0], point[1])
        }
        set { savedWaypoint = newValue.map { [$0.x, $0.y] } }
    }
    /// The rest of a 항구이동 course after the current waypoint.
    public var route: [[Double]] = []
    /// A grounded course is re-planned once per order.
    var replanned = false
    public var aground = false

    public var ships: [Ship]
    public var captain = Captain.joan
    public var gold = 1000
    public var waterRation = 100
    /// Economy record in effect. Supply ports (index 100 and up) have none, and the original
    /// keeps the pointer of the last market port (`[0xC6E2]`).
    public var marketIndex = 0
    /// Family rank, byte 13 of the family record; 0 in a new game.
    public var rank = 0
    /// Port markets as trading has left them. Empty until the voyage is placed in a world.
    public var markets: [Market] = []
    /// Item numbers held (DS:0x2D93, 20 slots).
    public var items: [Int] = []
    public var shipyardStocks: [ShipyardStock] = []
    /// Set when a lowball offer angers the shipwright; lifted on the next landing.
    public var shipyardBanned = false
    public var officers: [Officer] = []
    /// Ships on the stocks in some yard.
    public var orders: [ShipOrder] = []
    /// Ships left in the capitals' docks.
    public var dock: [DockedShip] = []
    /// 정박 (`[0xF91]` bit 0x20): the fleet lies still at sea while the days go by.
    public var anchored = false
    /// A party is ashore (bits 0x08/0x10): half rations and no storm damage.
    public var ashore = false
    /// Why the game ended (MAIN 0x17032 codes): 0x10 retirement (msg 1016), 0x18 storm (1014),
    /// 0x19 no crew (1015), 0x1A battle lost (1013).
    public var gameOverCode: Int?
    /// Sea events that fired and await their three message boxes (types 0..9); not saved.
    public var seaAlarms: [Int] = []
    /// Sound effects asked for by the rules (sfx.md: "level_up", "treasure"); not saved.
    public var soundCues: [String] = []
    /// 항해일지: at most 48 lines, oldest first.
    public var logbook: [LogEntry] = []
    /// The coast tile where the party went ashore, while the fleet lies there.
    public var landedAt: [Int]?
    /// Ports that changed hands while small (port flag 8); their prices jump once economy reaches 150.
    public var developing: Set<Int> = []
    /// What the yard here has this visit.
    public var figureheadStock = 1
    public var carronadeHere = false
    /// Family record (DS:0x11E6): trade, pirate and adventure fame (each ≤ 50,000), and
    /// standing with the six nations (0...200, 100 at the start; lower is worse).
    public var fame = [0, 0, 0]
    public var standing = [100, 100, 100, 100, 100, 100]
    /// The data segment as the scripts see it; persons outside the fleet live only here.
    public var memory = DataSegment()
    /// The hero's story runs (new-game option, `[0xC30] & 0x40`).
    public var storyOn = true
    public var foodRation = 100

    public var year = 1522
    public var month = 3
    public var dayOfMonth = 0
    public var tick = 0
    public var day = 0
    public var daysAtSea = 0
    public var summerWinds: Bool
    public var weather: Weather
    public var speedUnits = 0
    /// Rats in the holds (`[0xC3F]` bit 0x10, 0x18D3C; earlier notes called it an epidemic):
    /// each ship loses a barrel of food a day.
    public var epidemic = false
    public var scurvy = false
    /// Incident in progress ([0xC3F] & 0xF); announced once it breaks (bit 0x40 cleared),
    /// fresh on the day it broke (bit 0x80, cleared each day by 0x190F9).
    public var event: SeaEvent?
    public var eventAnnounced = false
    public var eventFresh = false
    /// Days left without storms ([0x1032], counted down daily).
    public var stormShelter = 0
    /// Why the voyage ended, if it did.
    public var gameOver: String?
    /// A sea battle the world started (an NPC reached the player, or the player attacked).
    public var pendingBattle: Encounter?
    public var log: [String] = []
    public var rng = GameRandom(seed: 1)

    private var pending = 0.0
    /// Remaster autopilot: days under sail without leaving the tile, and that tile.
    private var stuckDays = 0
    private var dayTile: [Int] = []

    /// Development checkpoints preserve sub-tick integration and autopilot state. This is
    /// intentionally separate from user saves and never enables mid-battle save/load.
    public var diagnosticRuntime: DiagnosticRuntime {
        get { DiagnosticRuntime(pending: pending, stuckDays: stuckDays, dayTile: dayTile,
                                replanned: replanned, seaAlarms: seaAlarms, soundCues: soundCues, log: log) }
        set {
            pending = newValue.pending; stuckDays = newValue.stuckDays; dayTile = newValue.dayTile
            replanned = newValue.replanned; seaAlarms = newValue.seaAlarms
            soundCues = newValue.soundCues; log = newValue.log
        }
    }

    enum CodingKeys: String, CodingKey {
        case route
        case savedWaypoint = "waypoint"
        case x, y, heading, sail, aground, ships, captain, gold, waterRation, foodRation, marketIndex, rank
        case markets, items, shipyardStocks, shipyardBanned, officers, fame, standing, memory, storyOn, orders, figureheadStock, carronadeHere, developing, dock, anchored, ashore, landedAt, logbook, gameOverCode
        case year, month, dayOfMonth, tick, day, daysAtSea, summerWinds, weather, speedUnits, epidemic, scurvy, rng
        case event, eventAnnounced, eventFresh, stormShelter, gameOver, pendingBattle
    }

    public var speed: Double { Double(speedUnits) / 2 }
    public var crew: Int { ships.reduce(0) { $0 + $1.crew } }
    public var water: Int { ships.reduce(0) { $0 + $1.water } }
    public var food: Int { ships.reduce(0) { $0 + $1.food } }
    public var morale: Int { ships.map(\.morale).min() ?? 0 }
    public var vacancies: Int { ships.reduce(0) { $0 + $1.vacancies } }
    public var dailyWater: Int { ships.reduce(0) { $0 + Navigation.dailyUse(crew: $1.crew, ration: waterRation, ashore: ashore) } }
    public var dailyFood: Int { ships.reduce(0) { $0 + Navigation.dailyUse(crew: $1.crew, ration: foodRation, ashore: ashore) } }
    public var dayClock: Double { Double(tick) / Double(Navigation.ticksPerDay) * Voyage.secondsPerDay }

    /// Eight-point heading used by the original rules.
    public var heading8: Int {
        let compass = heading + .pi / 2
        let i = Int((compass / (.pi / 4)).rounded())
        return ((i % 8) + 8) % 8
    }

    public init(x: Double, y: Double, ships: [Ship]) {
        self.x = x
        self.y = y
        self.ships = ships
        summerWinds = (3..<9).contains(month)          // initial load, 0x1604E
        weather = Weather(windDir: 0, windStrength: 0, currentDir: 0, currentStrength: 0)
    }

    public init(at port: Harbor, in world: World, ships: [Ship]) {
        let b = world.berth(of: port) ?? (Double(port.x), Double(port.y))
        self.init(x: b.x, y: b.y, ships: ships)
        markets = world.navigation.markets
        if let m = world.memory {
            memory = m
            let fam = DS.family(m[DS.heroID])
            fame = (0..<3).map { m.word(fam + 2 * $0) }
            standing = (0..<6).map { m[fam + 6 + $0] }
            rank = m[fam + 0x0D]
        }
        refreshWeather(in: world)
    }

    /// A new game with hero `h` (0x1626B): 17 May 1522, 08:00, in the home port of the hero's
    /// fleet, with no ship, gold, officers or items — each hero's prologue script hands those
    /// out. Luck is rolled anew; the hero's fleet becomes the player's. `given`/`family`
    /// rename the hero (name entry 0x15DAE).
    /// `seed` drives luck and every later roll; the game passes the clock, tests a constant.
    public static func newGame(in world: World, hero h: Int = 0, given: String? = nil, family: String? = nil, seed: UInt32 = 1) -> Voyage {
        let ng = world.navigation.newGame
        var m = world.memory ?? DataSegment()
        m[DS.heroID] = h
        let p = DS.person(h)
        if let given, !given.isEmpty { m.setString(p, given, max: 13) }
        if let family, !family.isEmpty { m.setString(p + 0x0D, family, max: 13) }
        let fleet = m[p + 0x2C]
        m[DS.fleet(fleet) + FleetField.state] |= 1
        let home = m[DS.fleet(fleet) + FleetField.home]
        m[DS.port + DS.portSize * home + 0x13] |= 0x50
        var v = Voyage(at: world.ports[home], in: world, ships: [])
        v.memory = m
        v.rng = GameRandom(seed: seed)
        v.memory[p + 0x23] = v.rng(101)
        v.marketIndex = home
        v.captain = Captain(person: v.memory.person(h), face: v.memory.word(p + 0x1A))
        v.year = ng.year
        v.month = ng.month
        v.dayOfMonth = ng.day
        v.tick = ng.tick
        v.summerWinds = (3..<9).contains(v.month)
        v.gold = 0
        let fam = DS.family(h)
        v.fame = (0..<3).map { v.memory.word(fam + 2 * $0) }
        v.standing = (0..<6).map { v.memory[fam + 6 + $0] }
        v.rank = v.memory[fam + 0x0D]
        v.refreshWeather(in: world)
        v.restockShipyard(port: home, in: world)
        v.seedDiscoveries(in: world)
        return v
    }

    /// Joan in Lisbon at the end of the opening chapter of scenario 1.
    public static func joanAfterPrologue(in world: World) -> Voyage {
        let ng = world.navigation.newGame
        let hero = ng.heroes[0]
        // SNR1.DAT 0x25C `F9 05 05` orders class 5; 0x5CD `FA 05 0084` names it after line 132.
        let hermes = Ship.built(class: Prologue.joanShipClass, named: Prologue.joanShipName, in: world.navigation)
        var v = Voyage(at: world.ports[hero.port], in: world, ships: [hermes])
        v.marketIndex = hero.port
        v.captain = Captain(hero)
        v.year = ng.year
        v.month = ng.month
        v.dayOfMonth = ng.day
        v.tick = ng.tick
        v.summerWinds = (3..<9).contains(v.month)
        v.gold = ng.gold + Prologue.joanRequiredGold
        v.refreshWeather(in: world)
        v.restockShipyard(port: hero.port, in: world)
        v.memory[ScriptContext.hero.base] = 1                // the story stands at chapter 1
        return v
    }

    public static func screenAngle(of dir: Int) -> Double { Double(dir) * .pi / 4 - .pi / 2 }

    /// Steering weighs anchor (0x20989) but does nothing while a party is ashore (0x20A00).
    public mutating func steer(_ radians: Double) {
        guard !ashore else { return }
        waypoint = nil
        route = []
        anchored = false
        heading += radians
    }

    public mutating func setSail(_ delta: Int) {
        guard !ashore else { return }
        if delta > 0 { anchored = false }
        sail = min(Voyage.maxSail, max(0, sail + delta))
    }

    /// A click on the ship's wheel (0x20985): weigh anchor, drop any course and head one of
    /// the eight ways. Ignored while a party is ashore (0x20A00).
    public mutating func steer(toward dir8: Int) {
        guard !ashore else { return }
        waypoint = nil
        route = []
        anchored = false
        heading = Voyage.screenAngle(of: dir8 & 7)
        sail = Voyage.maxSail
    }

    /// 정박 / 출항 (0x2087A, msgs 1150 / 1149).
    @discardableResult
    public mutating func toggleAnchor() -> String {
        if anchored {
            anchored = false
            if sail == 0 { sail = Voyage.maxSail }
            return "이동하겠습니다."
        }
        anchored = true
        waypoint = nil
        route = []
        return "정선하겠습니다."
    }

    public mutating func setCourse(x tx: Double, y ty: Double) {
        guard !ashore else { return }
        anchored = false
        waypoint = (tx, ty)
        replanned = false
        sail = Voyage.maxSail
    }

    /// A chart click follows navigable water immediately. Previously a new click erased
    /// the coastal detour, so repeatedly following a fleet across a headland could leave
    /// the ship consuming stores against the same shore. Failed orders are atomic.
    @discardableResult
    public mutating func setSeaCourse(x tx: Double, y ty: Double, in world: World) -> Bool {
        guard !ashore, tx.isFinite, ty.isFinite, ty >= 0, ty < Double(World.height),
              world.isSea(x: tx, y: ty) else { return false }
        let span = max(abs(world.deltaX(from: x, to: tx)), abs(ty - y))
        guard span.isFinite, span < Double(World.width + World.height),
              let path = world.seaPath(from: (x, y), to: (tx, ty), radius: max(120, Int(ceil(span)) + 4)),
              let first = path.first else { return false }
        setCourse(x: first.0, y: first.1)
        route = path.dropFirst().map { [$0.0, $0.1] }
        return true
    }

    public mutating func refreshWeather(in world: World) {
        let z = Navigation.zone(x: Int(world.wrapX(x)), y: max(0, min(World.height - 1, Int(y))))
        let winds = summerWinds ? world.navigation.windSummer : world.navigation.windWinter
        weather = Navigation.roll(windByte: winds[z], currentByte: world.navigation.current[z], rng: &rng)
    }

    public mutating func tick(_ dt: Double, in world: World) {
        steerTowardWaypoint(dt, in: world)
        heading = atan2(sin(heading), cos(heading))
        // Furled sails pause the remaster's clock; at anchor or ashore the days go on (0x30DF9).
        guard sail > 0 || anchored, gameOver == nil else {
            speedUnits = 0
            return
        }
        pending += dt * Double(Navigation.ticksPerDay) / Voyage.secondsPerDay
        while pending >= 1 && (sail > 0 || anchored) && gameOver == nil && pendingBattle == nil {
            pending -= 1
            gameTick(in: world)
        }
    }

    private mutating func steerTowardWaypoint(_ dt: Double, in world: World) {
        guard let w = waypoint else { return }
        let dx = world.deltaX(from: x, to: w.x), dy = w.y - y
        let nearWaypoint = (dx * dx + dy * dy).squareRoot() < 1.5
        // Only skip a nearby coastal bend when the start of the next leg is clear.
        // A distance threshold alone can cut the corner of a narrow bay into land.
        let nextIsClear: Bool
        if nearWaypoint, let next = route.first {
            let fullX = world.deltaX(from: x, to: next[0]), fullY = next[1] - y
            let fraction = min(1, 1.5 / max(0.001, hypot(fullX, fullY)))
            let nx = fullX * fraction, ny = fullY * fraction
            let steps = max(1, Int(ceil(max(abs(nx), abs(ny)) * 4)))
            nextIsClear = (1...steps).allSatisfy { step in
                world.fleetFits(x: x + nx * Double(step) / Double(steps), y: y + ny * Double(step) / Double(steps))
            }
        } else { nextIsClear = true }
        if nearWaypoint && nextIsClear {
            if let next = route.first {
                route.removeFirst()
                waypoint = (next[0], next[1])
                replanned = false
                return
            }
            waypoint = nil
            sail = 0
            return
        }
        var turn = atan2(dy, dx) - heading
        turn = atan2(sin(turn), cos(turn))
        heading += max(-2 * dt, min(2 * dt, turn))
    }

    /// One of the 72 ticks of a day: weather, speed, movement, then the day roll.
    mutating func gameTick(in world: World) {
        if tick % Navigation.weatherInterval == 0 { rollWeather(in: world) }
        if anchored {
            speedUnits = 0
            _ = checkSeaEvents(from: (Int(x), Int(y)), in: world)
            moveFleetsInSight(in: world)
            let t0 = tick
            tick += 1
            runFleets(fromTick: t0, toTick: tick, atSea: true, in: world)
            if tick >= Navigation.ticksPerDay {
                tick = 0
                endOfDay(in: world)
            }
            return
        }
        speedUnits = Navigation.fleetSpeed(ships: ships, captain: captain, heading: heading8,
                                           windDir: weather.windDir, windStrength: weather.windStrength,
                                           data: world.navigation)

        // The original moves along one of eight vectors whose axes are each ±1, so
        // diagonals cover more ground. A continuous heading is scaled the same way.
        let c = cos(heading), s = sin(heading)
        let norm = max(abs(c), abs(s))
        let current = Navigation.currentStep(weather)
        let mx = (c / norm * Double(speedUnits) + Double(current.0)) / Double(Navigation.tileUnits)
        let my = (s / norm * Double(speedUnits) + Double(current.1)) / Double(Navigation.tileUnits)
        let before = (Int(x), Int(y))
        move(dx: mx, dy: my, in: world)
        // 0x3070D: the sea event points first; a fired event skips the sighting this tick.
        if !checkSeaEvents(from: before, in: world) && before != (Int(x), Int(y)) { lookAround(in: world) }

        moveFleetsInSight(in: world)
        let t0 = tick
        tick += 1
        runFleets(fromTick: t0, toTick: tick, atSea: true, in: world)
        if tick >= Navigation.ticksPerDay {
            tick = 0
            checkProgress(in: world)
            endOfDay(in: world)
        }
    }

    /// A course held against the coast by wind or current can slide back and forth without
    /// ever being fully blocked. Two days under way in the same tile count as blocked.
    private mutating func checkProgress(in world: World) {
        guard waypoint != nil, speedUnits > 0 else {
            stuckDays = 0
            return
        }
        let t = [Int(x), Int(y)]
        stuckDays = t == dayTile ? stuckDays + 1 : 0
        dayTile = t
        if stuckDays >= 2 {
            stuckDays = 0
            courseBlocked(in: world)
        }
    }

    /// A course that runs ashore is re-planned along the coast once, else the ship heaves to.
    private mutating func courseBlocked(in world: World) {
        guard let w = waypoint else { return }
        if !replanned, let path = world.seaPath(from: (x, y), to: w), path.count > 1 {
            replanned = true
            route = path.map { [$0.0, $0.1] } + route
            waypoint = (route[0][0], route[0][1])
            route.removeFirst()
            return
        }
        waypoint = nil
        route = []
        sail = 0
    }

    /// Blocked moves try each axis alone, as the original does (0x30FCA).
    private mutating func move(dx mx: Double, dy my: Double, in world: World) {
        let nx = world.wrapX(x + mx), ny = y + my
        // The whole 2×2 footprint must be sea (0x30AA0); a fleet that does not fit where it is
        // (just out of port) may move anywhere a single tile is sea, to get clear.
        let fits = world.fleetCanManeuver(x: x, y: y)
        let ok = { (px: Double, py: Double) in fits ? world.fleetFits(x: px, y: py) : world.isSea(x: px, y: py) }
        if ok(nx, ny) {
            x = nx
            y = ny
            aground = false
        } else if ok(nx, y) {
            x = nx
            aground = false
        } else if ok(x, ny) {
            y = ny
            aground = false
        } else if waypoint != nil {
            // Autopilot may start with the bow facing the quay. Give the rudder time to
            // turn toward the valid next leg instead of discarding that leg on tick one.
            if let w = waypoint {
                let desired = atan2(w.y - y, world.deltaX(from: x, to: w.x))
                let turn = atan2(sin(desired - heading), cos(desired - heading))
                if abs(turn) > .pi / 18 { return }
            }
            courseBlocked(in: world)
        } else {
            aground = true
        }
    }

    /// Daily upkeep at sea (0x18F98, 0x190F9).
    mutating func endOfDay(in world: World) {
        daysAtSea += 1
        newDay(in: world)
        consume(\.water, ration: waterRation, in: world)
        consume(\.food, ration: foodRation, in: world)
        rollDisease()
        for i in ships.indices {
            if epidemic { ships[i].food -= min(10, ships[i].food) }                     // 0x18DBE
            if scurvy { ships[i].crew -= min(ships[i].crew, rng(2) + (100 - captain.knowledge) / 5) }
        }
        if !ships.isEmpty && ships.allSatisfy({ $0.crew == 0 }) {               // 0x18F8D
            note("선원이 모두 쓰러졌습니다.")
            gameOver = "선원이 한 사람도 남지 않아 항해불능이 되었습니다."
            gameOverCode = 0x19
        }
    }

    /// The calendar and the daily world routines, at sea or in port (0x190F9).
    mutating func newDay(in world: World? = nil) {
        day += 1
        dayOfMonth += 1
        if dayOfMonth >= Navigation.daysIn(month: month, year: year) {
            dayOfMonth = 0
            month += 1
            if month == 12 {
                month = 0
                year += 1
                if year - 1501 > 52 && gameOver == nil {                         // 0x15A8B
                    gameOver = "30년의 항해가 막을 내렸습니다."
                    gameOverCode = 0x10
                }
            }
            if month % 6 == 2 { summerWinds = month == 2 }  // 0x17294
            newMonth(in: world)
        }
        eventFresh = false
        tavernDay()                                         // [0xC3C], girls' requests, ages (TavernMore.swift)
        stormShelter -= min(1, stormShelter)
        for k in orders.indices { orders[k].daysLeft -= min(1, orders[k].daysLeft) }
        updateAllegiance()
    }

    /// Time spent in port: building visits and the inn move the clock (72 ticks a day), and
    /// the fleets of the world go about their business.
    public mutating func passTime(ticks n: Int, in world: World? = nil) {
        for _ in 0..<n {
            let t0 = tick
            tick += 1
            if let world { runFleets(fromTick: t0, toTick: tick, atSea: false, in: world) }
            if tick >= Navigation.ticksPerDay {
                tick = 0
                newDay(in: world)
            }
        }
    }

    /// Daily port allegiance (0x1902A): a nation with 75 support takes the port; a ruling
    /// nation below 75 loses it to no one. A small port above index 41 that changes hands is
    /// marked, and once its economy reaches 150 all its prices rise by `rand(5) + 10`.
    mutating func updateAllegiance() {
        if markets.isEmpty { return }
        for m in markets.indices {
            for n in 0..<6 {
                if markets[m].support[n] >= 75 {
                    guard n != markets[m].nation else { continue }
                    markets[m].nation = n                                       // 0x18FB9
                    if markets[m].economy < 150 && m > 41 { developing.insert(m) }
                } else if n == markets[m].nation {
                    markets[m].nation = 6                                       // 0x18FE4
                    developing.remove(m)
                }
            }
            if developing.contains(m) && markets[m].economy >= 150 {             // 0x18FEF
                developing.remove(m)
                for c in markets[m].prices.indices {
                    markets[m].prices[c] += min(rng(5) + 10, 100 - markets[m].prices[c])
                }
            }
        }
    }

    /// Each ship eats from its own stores, else from the first ship that still has some. The
    /// ship that gives up the stores answers for morale, under its own commander's leadership;
    /// below 20 the eating ship loses sailors (0x18A3C, 0x18B9E, 0x189FC).
    private mutating func consume(_ stock: WritableKeyPath<Ship, Int>, ration: Int, in world: World) {
        for i in ships.indices {
            if let source = ships[i][keyPath: stock] > 0 ? i : ships.firstIndex(where: { $0[keyPath: stock] > 0 }) {
                let use = Navigation.dailyUse(crew: ships[i].crew, ration: ration, ashore: ashore)
                ships[source][keyPath: stock] -= min(use, ships[source][keyPath: stock])
                let loss = Navigation.moraleLoss(leadership: commander(of: source, in: world).stats[0], ration: ration)
                ships[source].morale = max(0, min(100, ships[source].morale - loss))
                if ships[source].morale < Navigation.mutinyMorale { desert(i) }
            } else {
                ships[i].morale -= min(Navigation.starvationMoraleLoss, ships[i].morale)
                if ships[i].morale < Navigation.mutinyMorale { desert(i) }
            }
        }
    }

    private mutating func desert(_ i: Int) {
        let n = Incidents.deserters(crew: ships[i].crew, morale: ships[i].morale)
        guard n > 0 else { return }
        ships[i].crew -= n
        note("\(ships[i].name)호의 선원 \(n)명이 배를 떠났습니다.")
    }

    /// Epidemic after 30 days at sea (0x18D3C), scurvy after 60 (0x18E20).
    private mutating func rollDisease() {
        if !epidemic && !items.contains(25) && daysAtSea > 30 && rng(captain.navLevel / 5 + 2) == 0 && rng(105) > captain.luck {
            epidemic = true                                                              // a cat keeps rats away
            note("배에 쥐가 번지고 있습니다.\n대책이 필요합니다.")                // 473
        }
        if !scurvy && daysAtSea > 60 && rng(105) > captain.luck {
            scurvy = true
            note("선원 가운데 괴혈병 환자가 생긴 듯합니다.")
        }
    }

    mutating func note(_ s: String) {
        if log.last != s { log.append(s) }
    }

    /// Entering port ends the voyage counters. Assumed: the original resets them on landing.
    public mutating func arrive(at port: Harbor, in world: World) {
        if daysAtSea > 0 { awardLandingExp(days: daysAtSea) }
        writeLog(0, daysAtSea, port.id)                                        // 0x1BA5D
        arrive(at: port)
        shipyardBanned = false
        restockShipyard(port: port.id, in: world)
    }

    public mutating func arrive(at port: Harbor) {
        sail = 0
        anchored = false
        ashore = false
        waypoint = nil
        route = []
        aground = false
        speedUnits = 0
        daysAtSea = 0
        epidemic = false
        scurvy = false
        event = nil                                         // 0x1B709
        if port.id < 100 { marketIndex = port.id }
    }

    public func market(in world: World) -> Market {
        markets.indices.contains(marketIndex) ? markets[marketIndex] : world.navigation.markets[marketIndex]
    }

    /// Deducts gold if the purse covers it (0x24EBB).
    public mutating func pay(_ amount: Int) -> Bool {
        guard amount <= gold else { return false }
        gold -= amount
        return true
    }

    /// Adds gold up to the purse limit (0x24EE1).
    public mutating func earn(_ amount: Int) {
        gold = min(Trade.goldCap, gold + amount)
    }

    /// Holding the trade licence of the market port's nation waives the surcharge.
    public func licensed(in world: World) -> Bool {
        let n = market(in: world).nation
        return n < 6 && items.contains(0x23 + n)
    }

    public func offers(in world: World) -> [Offer] { Trade.offers(at: market(in: world), in: world.navigation) }

    public func price(of o: Offer, in world: World) -> Int {
        Trade.buyPrice(o, at: market(in: world), in: world.navigation, licensed: licensed(in: world))
    }

    /// Most of an offer ship `i` can take (0x23EEF). The original also needs an empty hold,
    /// even when the same good is already aboard (0x23CE6).
    public func maxPurchase(_ o: Offer, ship i: Int, in world: World, unitPrice: Int? = nil) -> Int {
        guard ships.indices.contains(i), offers(in: world).contains(o),
              ships[i].holds.count < Trade.holds else { return 0 }
        let price = unitPrice ?? price(of: o, in: world)
        guard price > 0 else { return 0 }
        return min(max(0, gold) / price, ships[i].freeCargo)
    }

    /// Answer to offering `x` gold a unit (0x24064). The hero's own skill (person +0x30 bit 0)
    /// or a bookkeeper's accounting (bit 1) wins the floor price after the first counter.
    public func bargain(_ o: Offer, offer x: Int, in world: World) -> Bargain {
        let p = price(of: o, in: world)
        let r = market(in: world).nation == captain.nation ? rank : 0
        let floor = Trade.haggleFloor(price: p, rank: r)
        let mid = Trade.haggleAccepts(price: p, rank: r)
        if x >= mid { return .accepted(min(x, p)) }
        if mid - floor <= 1 { return .firm }
        let keeper = officer(holding: .bookkeeper)
        if captain.skills & 1 != 0 || (keeper?.skills ?? 0) & 2 != 0 { return .settled(floor) }
        return .counter(max(floor, p - (mid - floor) / 2))
    }

    @discardableResult
    public mutating func buy(_ o: Offer, amount n: Int, ship i: Int, in world: World, unitPrice: Int? = nil) -> Bool {
        guard ships.indices.contains(i), offers(in: world).contains(o) else { return false }
        let p = unitPrice ?? price(of: o, in: world)
        guard p > 0, n > 0, n <= maxPurchase(o, ship: i, in: world, unitPrice: p), pay(n * p) else { return false }
        if let k = ships[i].holds.firstIndex(where: { $0.good == o.good }) {
            ships[i].holds[k].amount += n
        } else {
            ships[i].holds.append(CargoLot(good: o.good, amount: n))
        }
        tradeMarket(world) { Trade.afterBuy(&$0, category: world.navigation.goods[o.good].category, total: n * p) }
        writeLog(12, o.good, 0, (n * p) & 0xFFFF, n)                          // 0x23F99
        return true
    }

    public func salePrice(of good: Int, in world: World) -> Int {
        Trade.sellPrice(good, at: market(in: world), in: world.navigation)
    }

    /// Sells `n` from hold `k` of ship `i` (0x247C2).
    @discardableResult
    public mutating func sell(hold k: Int, amount n: Int, ship i: Int, in world: World) -> Bool {
        guard ships.indices.contains(i), ships[i].holds.indices.contains(k),
              world.navigation.goods.indices.contains(ships[i].holds[k].good),
              n > 0, n <= ships[i].holds[k].amount else { return false }
        let good = ships[i].holds[k].good
        let p = salePrice(of: good, in: world)
        earn(n * p)
        ships[i].holds[k].amount -= n
        if ships[i].holds[k].amount == 0 { ships[i].holds.remove(at: k) }
        tradeMarket(world) { Trade.afterSell(&$0, category: world.navigation.goods[good].category, total: n * p) }
        return true
    }

    private mutating func tradeMarket(_ world: World, _ change: (inout Market) -> Void) {
        if markets.isEmpty { markets = world.navigation.markets }
        change(&markets[marketIndex])
    }

    /// Most barrels of `s` that ship `i` can take: hold space, and for priced goods the purse (0x2741A).
    public func maxPurchase(_ s: Supply, ship i: Int, at m: Market) -> Int {
        let room = ships[i].freeCargo
        let price = s.price(at: m)
        return price == 0 ? room : min(room, gold / price)
    }

    /// Loads `barrels` of `s` into ship `i` and pays for them (0x27532).
    @discardableResult
    public mutating func buy(_ s: Supply, barrels: Int, ship i: Int, at m: Market) -> Bool {
        guard barrels > 0, barrels <= maxPurchase(s, ship: i, at: m), pay(barrels * s.price(at: m)) else { return false }
        let units = barrels * s.unitsPerBarrel
        switch s {
        case .water: ships[i].water += units
        case .food: ships[i].food += units
        case .lumber: ships[i].lumber += units
        case .shot: ships[i].shot += units
        }
        return true
    }

    /// Sailors that can be signed now: volunteers, berths, and the purse (0x24FC7).
    public func hireable(at tavern: Tavern) -> Int {
        min(tavern.volunteers(rank: rank), gold / tavern.wage, vacancies)
    }

    /// Signs `n` sailors and berths them ship by ship. The original then asks for each
    /// ship's complement (message 230); the remaster fills the flagship first.
    @discardableResult
    public mutating func hire(_ n: Int, at tavern: Tavern) -> Bool {
        guard n > 0, n <= hireable(at: tavern), pay(n * tavern.wage) else { return false }
        var left = n
        for i in ships.indices where left > 0 {
            let k = min(left, ships[i].vacancies)
            ships[i].crew += k
            left -= k
        }
        return true
    }
}
