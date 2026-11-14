import Foundation

// Officers, experience and the monthly turn, recovered from MAIN.EXE: hiring at the
// tavern (0x26112, 0x25FBF), pay and loyalty (0x18864), arrival experience (0x1B6EE),
// level thresholds (0x1B558), and the monthly economy (0x173CC). See docs/RE_NOTES.md.

/// Person record (DS:0x1242, 50 bytes) as it stands in a new game.
public struct Person: Codable, Equatable {
    public let name: String
    /// +0x1C: leadership, seamanship, knowledge, intuition, courage, swordplay, charm, luck.
    public let stats: [Int]
    public let navLevel: Int
    public let battleLevel: Int
    public let navExp: Int
    public let battleExp: Int
    public let loyalty: Int
    /// +0x2C: fleet the person serves, 0xFF for none.
    public let employer: Int
    /// +0x2D: port whose tavern they drink in, 0xFF when at sea.
    public let port: Int
    public let status: Int
    /// Face bits 0xC000 (+0x1B & 0xC0): a minor character, lost with a wrecked ship (0x196D8).
    public let generic: Bool
    /// +0x2F bit 3: speaks in the casual register (the odd-numbered message variants).
    public let casual: Bool
    /// +0x30: skill bits. Bit 1 makes a bookkeeper a match for traders (0x24173).
    public let skills: Int
    public let nation: Int

    /// Free navigators waiting in a tavern.
    public var isRecruit: Bool { employer == 0xFF && status == 0 && port < 100 }
}

public struct Officer: Codable, Equatable {
    public let person: Int
    public var name: String
    public var stats: [Int]
    public var navLevel: Int
    public var battleLevel: Int
    public var navExp: Int
    /// Monthly pay in gold; the original keeps it in tens (DS:0x2D75).
    public var salary: Int
    public var loyalty: Int
    public var unpaid = false
    public var post: OfficerPost?
    public var generic = false
    public var skills = 0
}

/// Posts besides ship captain (person +0x2E = post + 3, holders at DS:0xB050..0xB052;
/// names DS:0x858: 부선장, 경리주임, 수석항해사).
public enum OfficerPost: Int, Codable, CaseIterable {
    case firstMate, bookkeeper, chiefNavigator

    public var name: String { ["부선장", "경리주임", "수석항해사"][rawValue] }
}

public enum Officers {
    public static let maxOfficers = 30

    /// Experience needed for the next level (0x1B558).
    public static func threshold(level: Int) -> Int {
        let l = min(level, 18)
        return 30 * l * l
    }

    /// Spends experience on levels (0x1B570). Returns the number of levels gained.
    public static func levelUp(level: inout Int, exp: inout Int) -> Int {
        var gained = 0
        while exp >= threshold(level: level) {
            if level == 100 {
                exp = 0
                break
            }
            exp -= threshold(level: level)
            level += 1
            gained += 1
        }
        return gained
    }

    /// Experience for a landing after `days` at sea (0x1B713): ship captains get
    /// `2 × min(days, 70)²`, other officers `min(days, 100)²`.
    public static func landingExp(days: Int, commands: Bool) -> Int {
        commands ? 2 * min(days, 70) * min(days, 70) : min(days, 100) * min(days, 100)
    }

    /// The navigator's measure of a captain (0x2611C): the sum of both levels times the
    /// ability the navigator is best at.
    static func bestAbility(_ stats: [Int]) -> Int {
        var best = 0
        for i in 1..<7 where stats[i] > stats[best] { best = i }
        return best
    }
}

public enum OfficerOffer: Equatable {
    case salary(Int)
    case refused, busy, noRoom
}

extension Voyage {
    /// Navigators drinking in the port the fleet is in (person records in the data segment).
    public func recruits(in world: World) -> [Int] {
        (0..<120).filter { p in
            let r = memory.person(p)
            return r.isRecruit && r.port == marketIndex && !officers.contains { $0.person == p }
        }
    }

    public var spareCaptains: Int { officers.count - (ships.count - 1) }

    /// Abilities, navigation level and fate of whoever commands ship `i`: the admiral on the
    /// flagship, officers in list order on the others.
    public func commander(of i: Int, in world: World) -> (stats: [Int], navLevel: Int, generic: Bool) {
        guard i > 0, officers.indices.contains(i - 1) else { return (captain.stats, captain.navLevel, false) }
        let o = officers[i - 1]
        return (o.stats, o.navLevel, o.generic)
    }

    public func officer(holding post: OfficerPost) -> Officer? { officers.first { $0.post == post } }

    /// Appoints officer `k` (0x1E5C0). Ship captains cannot hold a post (message 227); the
    /// previous holder steps down.
    @discardableResult
    public mutating func appoint(_ k: Int, to post: OfficerPost?) -> Bool {
        guard officers.indices.contains(k), k >= ships.count - 1 else { return false }
        if let post { for j in officers.indices where officers[j].post == post { officers[j].post = nil } }
        officers[k].post = post
        return true
    }

    /// Takes ship `i` out of the fleet. Its captain, if kept, moves behind the captains.
    mutating func removeShip(_ i: Int, keepCaptain: Bool) {
        guard i > 0, ships.indices.contains(i) else { return }
        ships.remove(at: i)
        guard officers.indices.contains(i - 1) else { return }
        let o = officers.remove(at: i - 1)
        if keepCaptain { officers.append(o) }
    }

    /// Asks person `p` to sign on (0x2610E). They refuse a captain whose experience falls
    /// short: `rand(20) + theirs ≥ yours`, where each side is (navigation + battle level) ×
    /// the ability the navigator is best at. A rank adds a tenth per step. Pay is
    /// `min(20, theirs / 400 + rand(3) + 1) × 10` gold a month (0x25FBF).
    public mutating func offerTerms(to p: Int, in world: World) -> OfficerOffer {
        guard recruits(in: world).contains(p) else { return .busy }
        guard officers.count < Officers.maxOfficers else { return .noRoom }       // message 140
        let person = memory.person(p)
        let k = Officers.bestAbility(person.stats)
        let theirs = (person.navLevel + person.battleLevel) * person.stats[k]
        var yours = (captain.navLevel + captain.battleLevel) * captain.abilities[k]
        yours += yours * rank / 10
        guard rng(20) + theirs < yours else { return .refused }                   // message 145
        return .salary(min(20, theirs / 400 + rng(3) + 1) * 10)
    }

    /// Signs person `p` for `salary` (0x26021): loyalty rises by 10.
    public mutating func hireOfficer(_ p: Int, salary: Int, in world: World) {
        let person = memory.person(p)
        memory[DS.person(p) + 0x2C] = memory[DS.person(heroID) + 0x2C]
        memory[DS.person(p) + 0x2E] = 6
        officers.append(Officer(person: p, name: person.name, stats: person.stats, navLevel: person.navLevel,
                                battleLevel: person.battleLevel, navExp: person.navExp, salary: salary,
                                loyalty: min(100, person.loyalty + 10), generic: person.generic, skills: person.skills))
    }

    /// Lets an officer go; they return to this port's tavern.
    public mutating func dismissOfficer(_ k: Int) {
        guard officers.indices.contains(k), spareCaptains > 0 else { return }
        let a = DS.person(officers[k].person)
        memory[a + 0x2C] = 0xFF
        memory[a + 0x2D] = marketIndex
        memory[a + 0x2E] = 0
        officers.remove(at: k)
    }

    /// Experience on landing (0x1B6EE). Levels raise the first four abilities by rand(3) each.
    mutating func awardLandingExp(days: Int) {
        captain.navExp += Officers.landingExp(days: days, commands: true)
        let gained = Officers.levelUp(level: &captain.navLevel, exp: &captain.navExp)
        for _ in 0..<gained {
            captain.leadership = min(100, captain.leadership + rng(3))
            captain.seamanship = min(100, captain.seamanship + rng(3))
            captain.knowledge = min(100, captain.knowledge + rng(3))
            captain.intuition = min(100, captain.intuition + rng(3))
        }
        if gained > 0 { note("\(captain.name)의 항해 레벨이 올랐습니다.") }
        var any = gained > 0
        for k in officers.indices {
            var o = officers[k]
            o.navExp += Officers.landingExp(days: days, commands: k < ships.count - 1)
            let up = Officers.levelUp(level: &o.navLevel, exp: &o.navExp)
            for _ in 0..<up {
                for s in 0..<4 { o.stats[s] = min(100, o.stats[s] + rng(3)) }
            }
            if up > 0 { any = true }
            officers[k] = o
        }
        if any { soundCues.append("level_up") }                                // 0x1B6B0
    }

    /// The first of each month (0x189DA).
    mutating func newMonth(in world: World? = nil) {
        // March and September: the licences of the season lapse (0x172EA).
        if month % 6 == 2 { items.removeAll { (0x23...0x28).contains($0) } }
        monthlyTown()
        if let world { worldMonth(in: world) }
        monthlyRoyalAid()
        payOfficers()
    }

    /// Each category index moves 1–5 toward 50; economy and industry grow by a three-hundredth
    /// of the month's investment (0x173CC). Investment is not implemented, so they hold.
    mutating func driftMarkets() {
        for m in markets.indices {
            for c in markets[m].prices.indices {
                let step = rng(5) + 1
                if markets[m].prices[c] > 50 { markets[m].prices[c] -= step } else { markets[m].prices[c] += step }
            }
        }
    }

    /// Officers' pay (0x18864). If the purse cannot cover it, nobody is paid. Loyalty then
    /// moves by `2 × pay/10 − best of eight stats + admiral's leadership`, within 0...100,
    /// except for officers already at 100.
    mutating func payOfficers() {
        let total = officers.reduce(0) { $0 + $1.salary }
        guard total > 0 else { return }
        let paid = total <= gold
        if paid {
            gold -= total
            note("급료로 금화 \(total)닢을 선원들에게 나눠 주었습니다.")
        } else {
            note("선원들의 급료를 지급할 돈이 모자랍니다.")
        }
        for k in officers.indices {
            officers[k].unpaid = !paid
            guard officers[k].loyalty != 100 else { continue }
            let v = 2 * (officers[k].salary / 10) - (officers[k].stats.max() ?? 0) + captain.leadership
            officers[k].loyalty = min(100, max(0, officers[k].loyalty + v))
        }
    }
}
