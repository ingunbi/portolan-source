import Foundation

// The item shop (아이템, building 9, 0x297B9: stock 0x12E0B, buy 0x294A2, sell 0x295F7),
// equipping (0x28E75), the church (교회, building 10, 0x2C5EB) and the fortune teller (점술가,
// building 11, 0x2CD51). docs/re/town.md §9.

/// An item definition (DS:0x8144, 26 bytes, accessor 0x5BD2).
public struct ItemInfo: Equatable {
    public let id: Int
    public let name: String
    /// +0x16 × 100.
    public let price: Int
    /// +0x18: attack, defence, gift value or treasure-map site; 0 cannot be sold.
    public let power: Int
    /// +0x19 & 0xF: 0–3 swords, 4–5 shields, 6 armour, 7 instrument, 8 tool/licence,
    /// 9 consumable, 10 gift, 11 jewellery, 12 treasure map, 13 relic.
    public let type: Int
    /// +0x19 bit 0x10.
    public let equipped: Bool

    /// Equipment slot: 0 weapon, 1 shield, 2 armour; nil for what cannot be worn.
    public var slot: Int? { type < 4 ? 0 : type < 6 ? 1 : type == 6 ? 2 : nil }
}

public enum Fortune: Int, CaseIterable {
    case life, business, love, companion
    public static let price = 50
    public var name: String { ["인생운", "사업운", "연애운", "동료운"][rawValue] }
}

extension Voyage {
    public func item(_ id: Int) -> ItemInfo {
        let a = TownDS.item(id)
        return ItemInfo(id: id, name: memory.string(a, max: 21), price: memory.word(a + 0x16) * 100,
                        power: memory[a + 0x18], type: memory[a + 0x19] & 0x0F, equipped: memory[a + 0x19] & 0x10 != 0)
    }

    // MARK: item shop

    /// Items on sale here (0x12E0B): market +0x1D..+0x1F, and +0x20 too between 02:00 and 03:00.
    public var shopStock: [Int] {
        guard townPort < 100 else { return [] }
        let n = (6..<9).contains(tick) ? 4 : 3
        return (0..<n).map { memory[TownDS.market(townPort) + 0x1D + $0] }.filter { $0 != 0xFF }
    }

    /// 구입 (0x294A2): no gold (236), a full bag (237), and no second of the same equipment
    /// (332); the price is the list price, with no modifier.
    public func buyItemOffer(_ id: Int) -> TownAsk {
        let it = item(id)
        if gold == 0 { return .refused([.msg(236)]) }
        if items.count >= Town.maxItems { return .refused([.msg(237)]) }
        if items.contains(id) && it.type < 7 { return .refused([.msg(332)]) }
        return .yesNo([.joined([.msg(240, it.name), .text("\(it.price)"), .msg(241)])])
    }

    public mutating func buyItem(_ id: Int) -> [TownLine] {
        guard case .yesNo = buyItemOffer(id) else { return [] }
        guard pay(item(id).price) else { return [.msg(239)] }
        items.append(id)
        return [.msg(242)]
    }

    /// What the shop pays for an item (0x295F7): half the list price in hundreds; nothing for
    /// what has no power value.
    public func resalePrice(_ id: Int) -> Int {
        let it = item(id)
        return it.power == 0 ? 0 : (it.price / 100 / 2) * 100
    }

    /// 매각: equipment in use cannot be sold (333), and some things are not bought (929).
    public func sellItemOffer(_ id: Int) -> TownAsk {
        let it = item(id)
        guard items.contains(id) else { return .refused([.msg(243)]) }
        if it.equipped { return .refused([.msg(333)]) }
        let p = resalePrice(id)
        if p == 0 { return .refused([.msg(929)]) }
        return .yesNo([.joined([.msg(245, it.name), .text("\(p)"), .msg(247)])])
    }

    /// Turning the offer down: a lucky seller (`rand(100) ≤ luck`) gets `price·charm/200` more
    /// and is asked again (246); otherwise the deal is off (nil).
    public mutating func haggleItem(price p: Int) -> (price: Int, lines: [TownLine])? {
        guard rng(100) <= captain.luck else { return nil }
        let q = p + p * captain.charm / 200
        return (q, [.joined([.msg(246), .text("\(q)"), .msg(247)])])
    }

    public mutating func sellItem(_ id: Int, price p: Int) -> [TownLine] {
        guard case .yesNo = sellItemOffer(id), let k = items.firstIndex(of: id) else { return [] }
        earn(p)
        items.remove(at: k)
        return [.msg(242)]
    }

    /// 장비 (0x28E75): weapon, shield and armour slots; choosing the worn item takes it off,
    /// choosing another puts it on in place of the one in its slot.
    public mutating func toggleEquip(_ id: Int) -> [TownLine] {
        let it = item(id)
        guard items.contains(id), let slot = it.slot else { return [.msg(1090)] }
        if it.equipped {
            memory[TownDS.item(id) + 0x19] &= ~0x10
            return []
        }
        for other in items where other != id && item(other).slot == slot {
            memory[TownDS.item(other) + 0x19] &= ~0x10
        }
        memory[TownDS.item(id) + 0x19] |= 0x10
        return []
    }

    // MARK: church

    /// A mosque's lines are the church's plus 712 (91–96 → 803–808).
    var churchBase: Int { Town.mosques.contains(townPort) ? 712 : 0 }

    public func churchGreeting() -> TownLine { .msg(91 + churchBase) }
    public func churchFarewell() -> TownLine { .msg(96 + churchBase) }

    /// 예배 (0x2C408): the first prayer of a visit may add a point of luck.
    public mutating func pray() -> [TownLine] {
        if memory[TownDS.prayerReady] != 0 {
            memory[TownDS.prayerReady] = 0
            captain.luck = min(100, captain.luck + rng(2))
        }
        return [.msg(92 + churchBase)]
    }

    public func donationOffer() -> TownAsk { .amount([.msg(93 + churchBase)], max: gold) }

    /// 기부 (0x2C44E): less than about a tenth of the purse does nothing (94); otherwise
    /// `luck += 11 − gold/n` when `(rand(5)+1)·100 ≤ n`.
    public mutating func donate(_ n: Int) -> [TownLine] {
        guard n > 0, n <= gold else { return [] }
        let q = gold / n
        var lines: [TownLine]
        if q > 10 {
            lines = [.msg(94 + churchBase)]
        } else {
            lines = [.msg(95 + churchBase)]
            if (rng(5) + 1) * 100 <= n { captain.luck = min(100, captain.luck + 11 - q) }
        }
        gold -= n
        return lines
    }

    // MARK: fortune teller

    /// Readings available (menu 17): no love reading for Catalina, no companion reading alone.
    public var fortunes: [Fortune] {
        Fortune.allCases.filter { f in
            !(f == .love && memory[DS.heroID] == 1) && !(f == .companion && officers.isEmpty)
        }
    }

    /// Fame for the next rank as the fortune teller's table has it (DS:0xB8B0); rank 8 reads
    /// 40,000 though the promotion script needs 40,500, and rank 9 reads past the table.
    public var fortuneFameTarget: Int { memory.word(TownDS.fameTable + 2 * min(rank, 9)) }

    /// A reading (0x2CB8A, 0x2CBA9, 0x2CC63, 0x2CCDE) for 50 gold (299; 300 when short).
    /// `companion` is the officer index for 동료운.
    public mutating func readFortune(_ f: Fortune, companion: Int? = nil) -> [TownLine] {
        guard pay(Fortune.price) else { return [.msg(300)] }
        var lines: [TownLine] = [.msg(301)]
        switch f {
        case .life:
            lines.append(.msg(302 + captain.luck / 25))
        case .business:
            lines.append(.msg(545, Officers.threshold(level: captain.navLevel) - captain.navExp))
            lines.append(.msg(546, Officers.threshold(level: captain.battleLevel) - captain.battleExp))
            if nationality != 6 {
                let need = fortuneFameTarget - highestFame
                lines.append(need > 0 ? .msg(547, need) : .msg(754))
            }
        case .love:
            let woman = (0..<Barmaid.count).map { DS.woman + DS.womanSize * $0 }.first { w in   // all 30 (0x2CC7F)
                memory[w + 0x0C] == townPort && memory[w + 0x10] & 8 != 0 && memory[w + 0x10] & 0x40 == 0
            }
            if let w = woman {
                let a = memory[w + 0x0D]
                lines.append(a >= 80 ? .msg(326, memory.string(w, max: 11)) : a >= 50 ? .msg(327) : .msg(328))
            } else {
                lines.append(.msg(329))
            }
        case .companion:
            guard let k = companion, officers.indices.contains(k) else { return lines }
            lines.append(.msg(78 + officers[k].stats[7] / 25))
            lines.append(.msg(793 + officers[k].loyalty / 25))
        }
        return lines
    }
}
