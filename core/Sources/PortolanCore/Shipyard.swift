import Foundation

// Shipyard rules recovered from MAIN.EXE: stock on arrival (0x1B7CE), asking price and
// haggling (0x2B20A), ship value (0x2A602), sale (0x2B9C1) and repair (0x2B8BE).
// See docs/RE_NOTES.md.

public struct ShipyardStock: Codable, Equatable {
    public let port: Int
    public var classes: [Int]
}

public enum ShipDeal: Equatable {
    case bought, refused, banned, short, noCaptain, fleetFull, cargoAboard, busy, notReady
}

/// A ship on the stocks. The original parks it in a fleet slot flagged 0x20 with the port
/// in its captain byte, and counts the days in market byte 0x23 (0x2B6CD, daily 0x190A3).
public struct ShipOrder: Codable {
    public let port: Int
    public var ship: Ship
    public var daysLeft: Int
}

public enum Shipyard {
    public static let maxShips = 10
    public static let repairRate = 20
    /// The yard remembers the stock of the last three ports (DS:0x7E70, 3 × 8 bytes).
    public static let remembered = 3

    /// Port price level: mean of the ten category indices (0x1AE1E).
    public static func priceLevel(_ m: Market) -> Int { m.prices.reduce(0, +) / 10 }

    /// Five ships for a newly visited port (0x1B879): three from the regional list among the
    /// classes its industry supports, two from the common list scaled by economy. The original
    /// counts eligible classes but draws from the head of the list, which is ordered by size.
    public static func stock(at m: Market, in data: NavigationData, rng: inout GameRandom) -> [Int] {
        let region = data.shipRegions[m.shipRegion]
        let n = region.filter { data.classes[$0].requiredIndustry <= m.industry }.count
        var list: [Int] = []
        if n > 0 { for _ in 0..<3 { list.append(region[rng(n)]) } }
        for _ in 0..<2 { list.append(data.commonShips[rng(min(m.economy, 680) / 40 + 1)]) }
        return list
    }

    /// Asking price of a class (0x2B87B → 0x2B20A).
    public static func askingPrice(class c: Int, at m: Market, in data: NavigationData) -> Int {
        10 * (data.classes[c].price * (priceLevel(m) + 50) / 100)
    }

    /// Value of a ship (0x2A602). The yard pays half of it.
    public static func value(of s: Ship, at m: Market, in data: NavigationData) -> Int {
        let p = data.classes[s.classIndex].price
        return 10 * ((4 * p / 5 + p * s.material / 10) * (priceLevel(m) + 50) / 100)
    }

    /// Lowest offer the shipwright takes (0x2B2B8): charm shaves up to a fifth off.
    public static func floor(asking: Int, charm: Int) -> Int { asking * (500 - charm) / 500 }

    /// Hull materials (DS:0x2FE): teak, cedar, beech, oak, copper sheathing, iron.
    public static let materials = ["티크", "삼목", "너도밤나무", "오크", "동갑", "철갑"]

    /// Classes a yard builds (0x2B50E): every class of its region that its industry supports.
    public static func buildable(at m: Market, in data: NavigationData) -> [Int] {
        data.shipRegions[m.shipRegion].filter { data.classes[$0].requiredIndustry <= m.industry }
    }

    /// Materials offered (0x2B450): three, a fourth from industry 700 and a fifth from 900.
    /// Iron is for the ironclad alone, which may take any.
    public static func materialCount(class c: Int, at m: Market) -> Int {
        c == 22 ? 6 : (m.industry - min(500, m.industry)) / 200 + 3
    }

    /// Hull of a new build (0x2B4D1): a tenth more or less per material step from beech, at most 100.
    public static func builtHull(class c: Int, material: Int, in data: NavigationData) -> Int {
        min(100, (material + 8) * data.classes[c].hull / 10)
    }

    /// Price of a new build (0x2B5CB → 0x2B20A): the yard's scale on 4/5 of the class price
    /// plus a tenth of it per material step, the same measure as a ship's value.
    public static func buildPrice(class c: Int, material: Int, at m: Market, in data: NavigationData) -> Int {
        let p = data.classes[c].price
        return 10 * ((4 * p / 5 + p * material / 10) * (priceLevel(m) + 50) / 100)
    }

    /// Days on the stocks (0x2B6AC): `(100 − industry / 50) × class hull / 100`.
    public static func buildDays(class c: Int, at m: Market, in data: NavigationData) -> Int {
        (100 - m.industry / 50) * data.classes[c].hull / 100
    }

    /// Changing the crew and gun split costs the class price in gold (0x2BEBF, message 274).
    public static func refitCost(class c: Int, in data: NavigationData) -> Int { data.classes[c].price }

    /// Figureheads on sale (0x2BCF5): one kind per 100 economy up to eight; in a rich port a
    /// lucky admiral may find one or two finer ones (message 266). Kind `k` costs `k² × 500`.
    public static func figureheads(at m: Market, luck: Int, rng: inout GameRandom) -> Int {
        var n = min(8, m.economy / 100 + 1)
        if m.industry > 800 && m.economy > 800 && luck > 80 && rng(20) == 0 {
            n += 1
            if rng(luck) >= 90 { n += 1 }
        }
        return n
    }

    public static let figureheadNames = ["없음", "바다표범", "제독", "유니콘", "사자", "독수리", "위인", "포세이돈", "용", "천사", "여신"]
    public static func figureheadPrice(_ k: Int) -> Int { k * k * 500 }

    /// Hull, rudder and sail points missing, 20 gold each (0x2B900).
    public static func repairCost(_ s: Ship, in data: NavigationData) -> Int {
        let c = data.classes[s.classIndex]
        return repairRate * ((s.maxHull - s.hull) + (c.rudder - s.rudder) + (c.sail - s.sail))
    }
}

extension Voyage {
    /// Stock at the port the fleet is in, if it has a yard.
    public var shipyardStock: [Int] {
        shipyardStocks.first { $0.port == marketIndex }?.classes ?? []
    }

    /// Reuses a remembered port's stock or rolls a new one (0x1B7CE). The figureheads and the
    /// rare carronade are drawn for each visit.
    mutating func restockShipyard(port: Int, in world: World) {
        guard port < 100 else { return }
        let m = world.navigation.markets[port]
        figureheadStock = Shipyard.figureheads(at: markets.isEmpty ? m : markets[port], luck: captain.luck, rng: &rng)
        carronadeHere = m.economy > 900 && m.industry > 900 && captain.luck > 90 && rng(20) == 0
        if let k = shipyardStocks.firstIndex(where: { $0.port == port }) {
            shipyardStocks.insert(shipyardStocks.remove(at: k), at: 0)
            return
        }
        let classes = Shipyard.stock(at: market(in: world), in: world.navigation, rng: &rng)
        shipyardStocks.insert(ShipyardStock(port: port, classes: classes), at: 0)
        if shipyardStocks.count > Shipyard.remembered { shipyardStocks.removeLast() }
    }

    public func askingPrice(class c: Int, in world: World) -> Int {
        Shipyard.askingPrice(class: c, at: market(in: world), in: world.navigation)
    }

    public func shipValue(_ i: Int, in world: World) -> Int {
        Shipyard.value(of: ships[i], at: market(in: world), in: world.navigation)
    }

    public var haggleFloor: (Int) -> Int { { Shipyard.floor(asking: $0, charm: captain.charm) } }

    /// Buys stock slot `k` for `offer` gold (0x2B20A). Each extra ship needs a captain, so
    /// without spare officers the yard takes a ship in trade at half its value (message 167).
    /// The remaster moves crew and stores to the new ship and refuses while trade goods are aboard.
    public mutating func buyShip(slot k: Int, offer: Int, tradeIn: Int?, name: String, in world: World) -> ShipDeal {
        guard !shipyardBanned else { return .banned }
        guard let entry = shipyardStocks.firstIndex(where: { $0.port == marketIndex }),
              shipyardStocks[entry].classes.indices.contains(k) else { return .refused }
        let c = shipyardStocks[entry].classes[k]
        let asking = askingPrice(class: c, in: world)
        var credit = 0
        if let t = tradeIn {
            guard ships.indices.contains(t) else { return .refused }
            guard ships[t].holds.isEmpty else { return .cargoAboard }
            credit = shipValue(t, in: world) / 2
        } else {
            guard ships.count < Shipyard.maxShips else { return .fleetFull }
            guard spareCaptains > 0 else { return .noCaptain }   // 0x2AC85
        }
        guard offer <= asking, offer <= gold + credit else { return .short }
        if offer < haggleFloor(asking) {
            if rng(5) == 0 {
                shipyardBanned = true                     // message 197, flag 0xC3C bit 1
                return .banned
            }
            return .refused
        }
        var ship = Ship.built(class: c, named: name, in: world.navigation)
        if let t = tradeIn {
            let old = ships[t]
            ship.crew = min(old.crew, ship.crewCapacity)
            ship.morale = old.morale
            ship.sailorShare = old.sailorShare
            ship.water = min(old.water, ship.cargoCapacity * 10)
            ship.food = min(old.food, ship.freeCargo * 10)
            ship.lumber = min(old.lumber, ship.freeCargo)
            ship.shot = min(old.shot, ship.freeCargo)
            ships[t] = ship
        } else {
            ships.append(ship)
            officers[ships.count - 2].post = nil          // the new captain gives up any post
        }
        gold = gold + credit - offer
        shipyardStocks[entry].classes.remove(at: k)
        return .bought
    }

    /// Sells ship `i` for half its value (0x2BA43). The flagship alone cannot be sold.
    public mutating func sellShip(_ i: Int, in world: World) -> ShipDeal {
        guard ships.count > 1, ships.indices.contains(i) else { return .refused }
        guard ships[i].holds.isEmpty else { return .cargoAboard }
        earn(shipValue(i, in: world) / 2)
        removeShip(i, keepCaptain: true)
        return .bought
    }

    /// Cannon types the yard sells (0x2BDC1): `min(6, (economy + industry) / 200 + 1)`, in
    /// table order, and the carronade when a lucky visit to a rich port turned one up.
    public func cannonTypes(in world: World) -> [Int] {
        let m = market(in: world)
        return Array(1...min(6, (m.economy + m.industry) / 200 + 1)) + (carronadeHere ? [7] : [])
    }

    /// Orders a new ship (0x2B50E). One build per yard; it holds a fleet slot while building.
    public mutating func orderShip(class c: Int, material: Int, crew: Int, guns: Int, offer: Int, name: String,
                                   in world: World) -> ShipDeal {
        let m = market(in: world), data = world.navigation
        guard !shipyardBanned else { return .banned }
        guard !orders.contains(where: { $0.port == marketIndex }) else { return .busy }      // message 261
        guard Shipyard.buildable(at: m, in: data).contains(c), material < Shipyard.materialCount(class: c, at: m),
              (data.classes[c].minCrew...data.classes[c].maxCrew).contains(crew),
              (0...data.classes[c].maxGuns).contains(guns),
              crew + guns <= data.classes[c].capacity else { return .refused }
        guard ships.count + orders.count < Shipyard.maxShips else { return .fleetFull }
        let asking = Shipyard.buildPrice(class: c, material: material, at: m, in: data)
        guard offer <= asking, offer <= gold else { return .short }
        if offer < haggleFloor(asking) {
            if rng(5) == 0 {
                shipyardBanned = true
                return .banned
            }
            return .refused
        }
        gold -= offer
        var ship = Ship(class: c, in: data, crew: 0, water: 0, food: 0)
        ship.name = name
        ship.material = material
        ship.hull = Shipyard.builtHull(class: c, material: material, in: data)
        ship.maxHull = ship.hull
        ship.crewCapacity = crew
        ship.gunCapacity = guns
        ship.cargoCapacity = data.classes[c].capacity - crew - guns
        orders.append(ShipOrder(port: marketIndex, ship: ship, daysLeft: Shipyard.buildDays(class: c, at: m, in: data)))
        return .bought
    }

    public var orderHere: ShipOrder? { orders.first { $0.port == marketIndex } }

    /// Collects a finished ship (messages 250, 263). Its captain must come from the officers (285).
    public mutating func takeDelivery() -> ShipDeal {
        guard let k = orders.firstIndex(where: { $0.port == marketIndex }) else { return .refused }
        guard orders[k].daysLeft == 0 else { return .notReady }
        guard spareCaptains > 0 else { return .noCaptain }
        ships.append(orders.remove(at: k).ship)
        officers[ships.count - 2].post = nil
        return .bought
    }

    /// New crew and gun capacity for ship `i` (0x2AB31). Refused while its cargo would not fit
    /// (message 20); crew and guns beyond the new berths are put ashore.
    @discardableResult
    public mutating func refit(_ i: Int, crew: Int, guns: Int, in world: World) -> Bool {
        let c = world.navigation.classes[ships[i].classIndex]
        guard (c.minCrew...c.maxCrew).contains(crew), (0...c.maxGuns).contains(guns), crew + guns <= c.capacity,
              ships[i].cargoLoad <= c.capacity - crew - guns,
              pay(Shipyard.refitCost(class: ships[i].classIndex, in: world.navigation)) else { return false }
        ships[i].crewCapacity = crew
        ships[i].gunCapacity = guns
        ships[i].cargoCapacity = c.capacity - crew - guns
        ships[i].crew = min(ships[i].crew, crew)
        ships[i].guns = min(ships[i].guns, guns)
        return true
    }

    /// Mounts figurehead `k` on ship `i` (0x2BA9B).
    @discardableResult
    public mutating func buyFigurehead(_ k: Int, ship i: Int) -> Bool {
        guard (1...figureheadStock).contains(k), pay(Shipyard.figureheadPrice(k)) else { return false }
        ships[i].figurehead = k
        return true
    }

    /// Most guns of `type` ship `i` can mount (0x2BBC5). A different type replaces the
    /// guns aboard, so the whole gun deck is free for it.
    public func maxCannons(_ type: Int, ship i: Int) -> Int {
        ships[i].gunCapacity - (ships[i].gunType == type ? ships[i].guns : 0)
    }

    public func cannonPrice(_ type: Int, in world: World) -> Int { world.navigation.cannons[type - 1].price }

    /// Mounts `n` guns of `type` (0x2BC43). Old guns of another type are scrapped.
    @discardableResult
    public mutating func buyCannons(_ type: Int, count n: Int, ship i: Int, in world: World) -> Bool {
        guard n > 0, n <= maxCannons(type, ship: i), pay(n * cannonPrice(type, in: world)) else { return false }
        ships[i].guns = ships[i].gunType == type ? ships[i].guns + n : n
        ships[i].gunType = type
        return true
    }

    @discardableResult
    public mutating func repair(_ i: Int, in world: World) -> Bool {
        let cost = Shipyard.repairCost(ships[i], in: world.navigation)
        guard cost > 0, pay(cost) else { return false }
        let c = world.navigation.classes[ships[i].classIndex]
        ships[i].hull = ships[i].maxHull
        ships[i].rudder = c.rudder
        ships[i].sail = c.sail
        return true
    }
}
