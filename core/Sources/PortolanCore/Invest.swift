import Foundation

// Investment and support (0x24A58 trading post 투자, 0x2C24F shipyard 공업투자, support gain
// 0x24936 / 0x2C04A, owner change 0x2C16E) and the monthly market growth (0x173CC).
// docs/re/town.md §3.

/// Which market field an investment raises: economy (market +0, counter +2) or industry
/// (+4, counter +6).
public enum InvestField: Int, CaseIterable {
    case economy, industry

    /// Offset of this month's investment counter in the market record (u16).
    var counter: Int { self == .economy ? 2 : 6 }
}

public enum Invest {
    /// Each field of each port takes at most 50,000 a month.
    public static let monthlyCap = 50_000
    /// Next month the field grows by a three-hundredth of the money, up to 1000.
    public static let growthDivisor = 300, fieldCap = 1000

    /// Support bought with `v` gold where the field stands at `base` (0x24936): the
    /// investor's nation `p` gains `v / base` (up to 100 %), the others lose as much between
    /// them, equal shares first, then the remainder one point at a time round-robin. With no
    /// nationality nobody gains and the others still lose.
    public static func gainSupport(_ support: inout [Int], amount v: Int, base: Int, nation p: Int) {
        var g = (v & 0xFFFF) / max(1, base & 0xFFFF)
        if p < 6 {
            g = min(g, 100 - support[p])
            support[p] += g
        } else {
            g = min(g, 100)
        }
        let others = (0..<6).filter { $0 != p && support[$0] > 0 }
        guard !others.isEmpty else { return }
        let share = g / others.count
        var rest = g - share * others.count
        for n in others {
            let cut = min(share, support[n])
            support[n] -= cut
            rest += share - cut
        }
        var n = 0
        while rest > 0 {
            guard (0..<6).contains(where: { $0 != p && support[$0] > 0 }) else { break }
            if n != p && support[n] > 0 {
                support[n] -= 1
                rest -= 1
            }
            n = (n + 1) % 6
        }
    }

    /// Owner of a port by support (0x2C16E): the last nation with 75 % or more, else none.
    public static func owner(support: [Int]) -> Int {
        var owner = 6
        for n in 0..<6 where support[n] >= 75 { owner = n }
        return owner
    }

    /// Nation income divisors by region (DS:0xAC50).
    static let regionDivisor = [4, 3, 3, 2, 3, 1, 1, 1]

    /// Whether region `r` pays its owner (0x17464, for the 세력상황 report): Europe always; the
    /// eastern regions in a chain from the Middle East that breaks at the first region with
    /// less than 300 industry; the New World and West Africa with 300 industry; East Africa
    /// with 300 there and in West Africa or the Middle East.
    public static func regionPays(_ r: Int, industry ind: [Int]) -> Bool {
        switch r {
        case 0: return true
        case 1, 2: return ind[r] >= 300
        case 3: return (ind[2] >= 300 || ind[4] >= 300) && ind[3] >= 300
        default: return (4...r).allSatisfy { ind[$0] >= 300 }
        }
    }
}

extension Voyage {
    /// Money invested in `field` of port `p` this month (market +2 / +6).
    public func investment(_ field: InvestField, port p: Int) -> Int {
        memory.word(TownDS.market(p) + field.counter)
    }

    mutating func setInvestment(_ field: InvestField, port p: Int, _ v: Int) {
        memory.setWord(TownDS.market(p) + field.counter, v)
    }

    /// Capital of nation `n` (nation record +0xA).
    public func capital(of n: Int) -> Int { memory[TownDS.nation(n) + 0x0A] }

    /// A capital of any of the six nations takes no investment (0x1ADEC).
    public func isCapital(_ p: Int) -> Bool { (0..<6).contains { capital(of: $0) == p } }

    /// Market +0x1C: region 0...7 of a market port.
    public func region(of p: Int) -> Int { memory[TownDS.market(p) + 0x1C] }

    /// 투자 / 공업투자 (0x24A58, 0x2C24F): up to 50,000 per field per month, not in a capital.
    public func investOffer(_ field: InvestField) -> TownAsk {
        let p = townPort
        guard p < 100, markets.indices.contains(p) else { return .refused([.msg(2)]) }
        if isCapital(p) { return .refused([.msg(2)]) }
        let done = investment(field, port: p)
        if done >= Invest.monthlyCap { return .refused([.msg(7)]) }
        return .amount([.msg(8)], max: min(gold, Invest.monthlyCap - done))
    }

    /// Invests `v` gold. The field only grows next month; support moves now, and the port may
    /// change hands (0x2C16E). An amount of 0 is a polite refusal (message 13).
    public mutating func invest(_ v: Int, in field: InvestField) -> [TownLine] {
        guard case .amount(_, let most) = investOffer(field) else { return [] }
        guard v > 0, v <= most else { return [.msg(13)] }
        let p = townPort
        let thanks = v < 500 ? 14 : v < 10000 ? 15 : 16
        setInvestment(field, port: p, investment(field, port: p) + v)
        gold -= v
        let base = field == .economy ? markets[p].economy : markets[p].industry
        Invest.gainSupport(&markets[p].support, amount: v, base: base, nation: nationality)
        reassignOwner(p)
        return [.msg(thanks)]
    }

    /// The owner follows support (0x2C16E). A nation that loses the port through you loses 5
    /// standing; a port that joins your own nation brings its economy plus industry in trade
    /// fame and 5 standing.
    mutating func reassignOwner(_ port: Int) {
        let old = markets[port].nation
        let new = Invest.owner(support: markets[port].support)
        let p = nationality
        markets[port].nation = new
        if old != 6 && new != old && old != p {
            setStanding(old, standing(with: old) - min(5, standing(with: old)))
        }
        if old != p && new == p {
            fame[0] += min(Town.fameCap - fame[0], markets[port].economy + markets[port].industry)
            setStanding(p, min(200, standing(with: p) + 5))
        }
    }

    /// The monthly market routine (0x173CC), in place of `driftMarkets`: economy and industry
    /// grow by a three-hundredth of the month's investment (at most 1000) and the counters are
    /// cleared; then each price index moves 1–5 toward 50.
    public mutating func monthlyMarkets() {
        for m in markets.indices {
            if m < 100 {
                let e = investment(.economy, port: m), i = investment(.industry, port: m)
                markets[m].economy = min(Invest.fieldCap, markets[m].economy + e / Invest.growthDivisor)
                markets[m].industry = min(Invest.fieldCap, markets[m].industry + i / Invest.growthDivisor)
                setInvestment(.economy, port: m, 0)
                setInvestment(.industry, port: m, 0)
            }
            for c in markets[m].prices.indices {
                let step = rng(5) + 1
                if markets[m].prices[c] > 50 { markets[m].prices[c] -= step } else { markets[m].prices[c] += step }
            }
        }
    }

    /// Economy (developing ports count once, others twice) and industry of nation `n`'s
    /// ports, by region (0x17464).
    public func holdings(of n: Int) -> (economy: [Int], industry: [Int], ports: [Int]) {
        var eco = [Int](repeating: 0, count: 8), ind = eco, count = eco
        for p in markets.indices where p < 100 && markets[p].nation == n {
            let r = min(7, region(of: p))
            eco[r] += markets[p].economy * (developing.contains(p) ? 1 : 2)
            ind[r] += markets[p].industry
            count[r] += 1
        }
        return (eco, ind, count)
    }

    /// Nation record +0: monthly income.
    public func nationIncome(_ n: Int) -> Int { memory.word(TownDS.nation(n)) }

    /// The town side of the first of the month, to call in place of `driftMarkets()`: bank
    /// interest (0x1730D), then market growth and price drift (0x173CC).
    public mutating func monthlyTown() {
        monthlyBank()
        monthlyMarkets()
    }
}
