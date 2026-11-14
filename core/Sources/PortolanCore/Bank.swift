import Foundation

// The bank (은행, building 8, 0x28C33): deposit 0x28754, withdraw 0x288B5, borrow 0x289CF,
// repay 0x28B29, and the monthly interest 0x1730D. The balance is `100·[0x123E] + [0x1240]`:
// signed hundreds, floored, and the units 0...99. A negative balance is a debt.

public enum Bank {
    /// Deposits and debts are pinned to ±1,000,000.
    public static let cap = 1_000_000
    public static let depositRate = 3, loanRate = 10

    /// The first of the month (0x1730D): 3 % on savings, 10 % on debts, truncated toward zero.
    public static func interest(on b: Int) -> Int {
        let rate = b >= 0 ? depositRate : loanRate
        return max(-cap, min(cap, b + b * rate / 100))
    }

    /// Credit of rank `r`: `10000·r² + 1000`, less what is already owed (0x289CF).
    public static func loanLimit(rank r: Int, balance b: Int) -> Int { 10000 * r * r + 1000 + b }

    /// `[0x123E] <= −100·r² − 10`: the hundreds of the debt already reach the credit line.
    public static func creditExhausted(rank r: Int, balance b: Int) -> Bool {
        hundreds(b) <= -100 * r * r - 10
    }

    static func hundreds(_ b: Int) -> Int { b >= 0 ? b / 100 : -((99 - b) / 100) }
}

extension Voyage {
    /// Bank balance in gold (DS:0x123E s16 hundreds + DS:0x1240 units); negative is a debt.
    public var bankBalance: Int {
        get { 100 * Int(Int16(truncatingIfNeeded: memory.word(TownDS.bankHundreds))) + memory[TownDS.bankUnits] }
        set {
            let b = max(-Bank.cap, min(Bank.cap, newValue))
            let h = Bank.hundreds(b)
            memory.setWord(TownDS.bankHundreds, h & 0xFFFF)
            memory[TownDS.bankUnits] = b - 100 * h
        }
    }

    /// Greeting (0x28C33): the Venice head office, else the branch of this port.
    public func bankGreeting(portName: String) -> TownLine {
        townPort == 13 ? .msg(97) : .msg(98, portName)
    }

    private var balanceLine: TownLine { bankBalance == 0 ? .msg(104) : .msg(103, bankBalance) }

    /// 예금 (0x28754): needs more than 1000 gold, no debt, and room under 1,000,000.
    public func depositOffer() -> TownAsk {
        let b = bankBalance
        if gold <= 1000 { return .refused([.msg(100)]) }
        if b >= Bank.cap { return .refused([.msg(101)]) }
        if b < 0 { return .refused([.msg(102)]) }
        let most = min(gold, Bank.cap - b)
        return .amount([balanceLine, .msg(105, most)], max: most)
    }

    public mutating func deposit(_ v: Int) -> [TownLine] {
        guard case .amount(_, let most) = depositOffer(), v > 0, v <= most else { return [] }
        bankBalance += v
        gold -= v
        return [.msg(106, v), .msg(103, bankBalance)]
    }

    /// 출금 (0x288B5).
    public func withdrawOffer() -> TownAsk {
        let b = bankBalance
        if b <= 0 { return .refused([.msg(104)]) }
        if gold > Trade.goldCap - 100 { return .refused([.msg(107)]) }
        return .amount([.msg(103, b), .msg(108, b)], max: b)
    }

    public mutating func withdraw(_ v: Int) -> [TownLine] {
        guard case .amount(_, let most) = withdrawOffer(), v > 0, v <= most else { return [] }
        if gold + v > Trade.goldCap { return [.msg(109)] }
        bankBalance -= v
        gold += v
        return [.msg(110, v), .msg(103, bankBalance)]
    }

    /// 대출 (0x289CF). A rich borrower is told he needs no loan (112), and the loan goes on.
    public func borrowOffer() -> TownAsk {
        let b = bankBalance
        if b > 0 { return .refused([.msg(111)]) }
        if Bank.creditExhausted(rank: rank, balance: b) { return .refused([.msg(113)]) }
        let limit = max(0, Bank.loanLimit(rank: rank, balance: b))
        return .amount((gold >= Bank.cap ? [.msg(112)] : []) + [.msg(114, limit), .msg(115, limit)], max: limit)
    }

    public mutating func borrow(_ v: Int) -> [TownLine] {
        guard case .amount(_, let most) = borrowOffer(), v > 0, v <= most else { return [] }
        bankBalance -= v
        earn(v)
        return [.msg(116, v), .msg(117)]
    }

    /// 상환 (0x28B29): up to the debt or the purse.
    public func repayOffer() -> TownAsk {
        let b = bankBalance
        if b >= 0 { return .refused([.msg(118)]) }
        let most = min(-b, gold)
        return .amount([.msg(149, -b), .msg(119, most)], max: most)
    }

    public mutating func repay(_ v: Int) -> [TownLine] {
        guard case .amount(_, let most) = repayOffer(), v > 0, v <= most else { return [] }
        bankBalance += v
        gold -= v
        return [.msg(120), .msg(117)]
    }

    /// Monthly interest (0x1730D), first day of each month. Unpaid debt has no other
    /// consequence: it compounds until it is pinned at −1,000,000.
    public mutating func monthlyBank() {
        bankBalance = Bank.interest(on: bankBalance)
    }
}
