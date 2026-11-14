import Foundation

// Harbour services recovered from MAIN.EXE: the supply market (0x273FA), crew hiring
// at the tavern (0x24E2B, 0x24F0E, drinks 0x2589E) and the trading post (0x24215 buy,
// 0x24762 sell). See docs/RE_NOTES.md.

/// Economy record of one of the first 100 ports (DS:0x697C, 37 bytes, accessor 0x5B9E).
public struct Market: Codable, Equatable {
    public var economy: Int
    public var industry: Int
    /// Bytes 8..13: standing of the six nations in the port.
    public var support: [Int]
    /// Bytes 14..23: price index of each goods category, 0...100, scaled as `(index + 50) / 100`.
    /// Trading moves them, so the voyage keeps its own copy.
    public var prices: [Int]
    /// Byte 0x24: index into `NavigationData.drinks`.
    public let drink: Int
    /// Byte 0x1A (0xFF none): local specialty, price at 0x18, sold once economy reaches byte 0x1B × 10.
    public let specialty: Int
    public let specialtyPrice: Int
    public let specialtyEconomy: Int
    /// Byte 0x21: index into `NavigationData.zones`.
    public let zone: Int
    /// Byte 0x22: index into `NavigationData.shipRegions`.
    public let shipRegion: Int
    /// Port record byte 0x13 & 7: the nation the port is allied to, 6 for none.
    public var nation: Int
}

public struct Good: Codable, Equatable {
    public let name: String
    public let category: Int
}

/// One of the 13 trade zones (DS:0x77F0, 128 bytes, accessor 0x5BAE).
public struct TradeZone: Codable {
    public struct Listing: Codable, Equatable {
        public let good: Int
        public let price: Int
        /// Listed only in ports whose economy reaches this (byte 0x77 + k, × 10).
        public let economy: Int
    }
    /// Bytes 0x5C..0x7F: up to nine goods on sale.
    public let goods: [Listing]
    /// Bytes 0..0x5B: base price paid for each of the 46 goods.
    public let sellPrices: [Int]
}

/// A good on the trading post's list, with the base price it is scaled from.
public struct Offer: Equatable {
    public let good: Int
    public let basePrice: Int
}

public enum Trade {
    public static let holds = 5
    public static let goldCap = 600_000_000          // 0x24EE1

    /// Goods on sale (0x24215): zone listings the port's economy supports, then the specialty
    /// unless its category index has reached 90.
    public static func offers(at m: Market, in data: NavigationData) -> [Offer] {
        var list = data.zones[m.zone].goods.filter { $0.economy <= m.economy }.map { Offer(good: $0.good, basePrice: $0.price) }
        if m.specialty < data.goods.count && m.specialtyEconomy <= m.economy
            && m.prices[data.goods[m.specialty].category] < 90 {
            list.append(Offer(good: m.specialty, basePrice: m.specialtyPrice))
        }
        return list
    }

    /// Asking price (0x23E11). Without the port nation's trade licence (item 0x23 + nation,
    /// checked at 0x23DE5) the trader adds a fifth.
    public static func buyPrice(_ o: Offer, at m: Market, in data: NavigationData, licensed: Bool = false) -> Int {
        let p = o.basePrice * (m.prices[data.goods[o.good].category] + 50) / 100
        return p * (licensed ? 10 : 12) / 10
    }

    /// Price paid for a good (0x24628). The port's own specialty fetches half its price.
    public static func sellPrice(_ good: Int, at m: Market, in data: NavigationData) -> Int {
        let index = m.prices[data.goods[good].category] + 50
        if good == m.specialty { return m.specialtyPrice * index / 200 }
        return data.zones[m.zone].sellPrices[good] * index / 100
    }

    /// Haggling (0x24064). The trader never goes below `price × (19 − rank) / 20`, the family
    /// rank counting only in ports of the hero's own nation, and accepts any offer from halfway
    /// between that floor and the price.
    public static func haggleFloor(price p: Int, rank: Int) -> Int { p * (19 - rank) / 20 }

    public static func haggleAccepts(price p: Int, rank: Int) -> Int { p - (p - haggleFloor(price: p, rank: rank)) / 2 }

    /// Trader's remark on a category index (messages 23, 25, 24).
    public static func remark(index: Int) -> String {
        index <= 40 ? "지금이 살 때입니다." : index <= 60 ? "평범한 가격이군요." : "다소 비싼 거래입니다."
    }

    /// Buying raises the bought category by up to 10 and every category by up to 3 (0x23FD2).
    /// The original multiplies in 16 bits, so large deals wrap.
    static func afterBuy(_ m: inout Market, category: Int, total: Int) {
        let t = total & 0xFFFF
        m.prices[category] = min(100, m.prices[category] + min(10, t / ((m.economy & 0xFFFF) + 500)))
        let all = min(3, t / 1000)
        for i in m.prices.indices { m.prices[i] = min(100, m.prices[i] + all) }
    }

    /// Selling lowers them the same way, never below zero (0x24811).
    static func afterSell(_ m: inout Market, category: Int, total: Int) {
        let d = min(10, total / ((m.economy & 0xFFFF) + 500))
        m.prices[category] -= min(m.prices[category], d)
        let all = min(3, (total & 0xFFFF) / 1000)
        for i in m.prices.indices { m.prices[i] -= min(m.prices[i], all) }
    }
}

/// The trader's answer to an offer (0x24064).
public enum Bargain: Equatable {
    /// message 10
    case accepted(Int)
    /// "금화 %d닢에 사주세요." (message 12), then the offer is asked again.
    case counter(Int)
    /// The hero or a bookkeeper talks the trader down to the floor (messages 851, 852).
    case settled(Int)
    /// message 11
    case firm
}

public struct Drink: Codable, Equatable {
    public let name: String
    public let price: Int
}

public enum Supply: Int, CaseIterable {
    case water, food, lumber, shot

    public var name: String { ["식수", "식량", "자재", "포탄"][rawValue] }

    /// Units added to the hold per barrel bought. Water and food are kept in tenths.
    public var unitsPerBarrel: Int { self == .water || self == .food ? 10 : 1 }

    /// Gold per barrel (0x274A8): base price scaled by one of the port's price indices.
    public func price(at m: Market) -> Int {
        switch self {
        case .water: return 0
        case .food: return 20 * (m.prices[2] + 50) / 100
        case .lumber: return 90 * (m.prices[9] + 50) / 100
        case .shot: return 120 * (m.prices[2] + 50) / 100
        }
    }
}

/// One visit to a tavern. Mood rises with the drinks bought and sets how many sailors come.
public struct Tavern {
    public static let maxBottles = 50
    /// Below this mood the barkeep suggests more drink before recruiting (message 31).
    public static let willingMood = 30

    public let market: Market
    public let drink: Drink
    public private(set) var mood: Int

    /// Entering sets mood to a third of the captain's charm (0x26FF5).
    public init(market: Market, drinks: [Drink], charm: Int) {
        self.market = market
        drink = drinks[market.drink]
        mood = charm / 3
    }

    /// Bottles the purse allows (0x258E0). Gold above 10000 is counted as 10000 plus its remainder.
    public func bottlesAffordable(gold: Int) -> Int {
        let purse = gold >= 10000 ? gold % 10000 + 10000 : gold
        return min(Tavern.maxBottles, purse / drink.price)
    }

    /// Buys a round (0x25939). Returns the cost.
    public mutating func treat(bottles n: Int, charm: Int) -> Int {
        let rounds = 200 * n / market.economy
        mood = min(100, mood + rounds * charm / 10)
        return n * drink.price
    }

    /// Sailors who answer the call (0x24F17). `rank` is byte 13 of the family record (DS:0x11E6).
    public func volunteers(rank: Int = 0) -> Int {
        min(mood * market.economy / 500, (rank + 1) * mood)
    }

    /// Signing fee per sailor (0x24FB4).
    public var wage: Int { market.economy / 20 + 5 }
}
