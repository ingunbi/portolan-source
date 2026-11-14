import Foundation

// The guild (조합, building 6, 0x2CB18): 업무알선 0x2C77F hands out the SNR0 jobs, 나라정보
// 0x2CA2A sells news of a nation. The jobs themselves are SNR0 chapters 1–5, run by the
// building scripts. Also the royal summons the tavern (0x25721 → 0x257F4) and the harbour
// office (0x282C6) deliver. docs/re/town.md §5, §8; docs/re/scenario.md §5.

public enum Guild {
    /// Job kinds (names DS:0xB84A): SNR0 block kind+1 of chapter 0 briefs them.
    public static let jobNames = ["상품수송", "상품구입", "편지배달", "해적퇴치", "빚독촉"]
    public static let newsPrice = 100
}

/// What the guild master says to 업무알선.
public enum GuildDesk: Equatable {
    /// A job is under way: royal (595), here (931), or elsewhere (338).
    case busy([TownLine])
    /// Promotion due and summoned: go to the king (410 + nation, 932).
    case summoned([TownLine])
    /// The three jobs SNR0 chapter 0 drew for today (kinds v0..v2).
    case offers([Int])
}

extension Voyage {
    func portName(_ p: Int) -> String { memory.string(TownDS.port(p) + 4, max: 15) }
    var familyName: String { memory.string(heroPerson + 0x0D, max: 13) }
    var givenName: String { memory.string(heroPerson, max: 13) }

    /// Guild greeting (85), unless a script on the way in did the talking (v63 of either context).
    public func guildGreeting() -> [TownLine] {
        sharedVar(63) == 0 && memory.word(TownDS.heroV63) == 0 ? [.msg(85)] : []
    }

    /// 업무알선 (0x2C77F).
    public func guildDesk() -> GuildDesk {
        if sharedChapter != 0 {
            if sharedVar(6) >= 6 { return .busy([.msg(595)]) }
            let target = sharedVar(16) & 0xFF
            return .busy(target == townPort ? [.msg(931)] : [.msg(338, portName(target))])
        }
        if memory[TownDS.sharedFlags + 2] & 3 == 3 {
            return .summoned([.msg(410 + min(nationality, 6)), .msg(932)])
        }
        return .offers((0..<3).map { sharedVar($0) & 0xFF })
    }

    /// Picking offer `k` (0...2) loads its briefing: SNR0 block kind+1 with the offer's seed
    /// as v8. The caller then runs SNR0 (port, 6) alone and calls `settleJob()`.
    public mutating func pickJob(_ k: Int) {
        loadScriptGoodsNames()
        memory[TownDS.sharedBlock] = (sharedVar(k) & 0xFF) + 1
        setSharedVar(8, sharedVar(3 + k))
    }

    /// After the briefing: the job accepted is the chapter in v6 (0 if refused), block 0.
    /// Returns true when a job was taken.
    @discardableResult
    public mutating func settleJob() -> Bool {
        memory[TownDS.sharedChapter] = sharedVar(6) & 0xFF
        memory[TownDS.sharedBlock] = 0
        return sharedChapter != 0
    }

    /// 나라정보 (0x2CA2A): the price question (86).
    public func newsOffer() -> TownAsk { .yesNo([.msg(86)]) }

    /// Pays 100 for the news of nation `n` (0x2C899): its income and your standing with it,
    /// its relations, its war target and where its merchant fleet is heading.
    public mutating func buyNews(of n: Int) -> [TownLine] {
        guard pay(Guild.newsPrice) else { return [.msg(163)] }
        var lines: [TownLine] = [.joined([.msg(1081, nationIncome(n)), .text("\(abs(100 - standing(with: n)))")])]
        lines.append(.joined([.text("          "), .msg(1082), .msg(1083)]))
        for j in 0..<6 where j != n {
            let flags = nationByte(n, 0x12 + j)
            lines.append(.text("\(Town.nationNames[j])  \(abs(30 - relation(n, j)))  \(flags & 0x20 != 0 ? "☆" : "－")  \(flags & 0x10 != 0 ? "☆" : "－")"))
        }
        let target = warTarget(of: n)
        let name = Town.nationNames[min(n, 5)]
        if target == 7 {
            lines.append(.msg(853, name))
        } else if target < 6 {
            lines.append(.msg(88, name, Town.nationNames[target]))
        } else if target == 6 {
            lines.append(.msg(88, name, "해적"))
        }
        let port = nationByte(n, 4)
        if port < 130 { lines.append(.msg(89, portName(port))) }
        return lines
    }

    // MARK: the royal summons

    /// The rumour that the king is looking for you (409, 410 + nation, 416) sets F17, when no
    /// job is under way, promotion is due or already summoned, and no commission was accepted.
    var summonsDue: Bool {
        sharedChapter == 0 && memory[TownDS.sharedFlags + 2] & 3 != 0 && memory[TownDS.sharedFlags + 2] & 4 == 0
    }

    mutating func deliverSummons() -> [TownLine] {
        setSharedFlag(17, true)
        return [.joined([.msg(409), .msg(410 + min(nationality, 6)), .msg(416)])]
    }

    /// The harbour office passes the summons on in a port of your own nation (0x282C6).
    public mutating func harborSummons() -> [TownLine] {
        guard summonsDue, portNation == nationality else { return [] }
        return deliverSummons()
    }

    /// What the house says after 한턱내기 (0x25721): your fame (36 under 1000, 132 under
    /// 5000 naming its kind, else 133), then the king's summons if it is due.
    public mutating func tavernTreatTalk() -> [TownLine] {
        var k = 0
        for i in 1..<3 where fame[i] > fame[k] { k = i }
        let m = fame[k]
        var lines: [TownLine] = m < 1000 ? [.msg(36)]
            : m < 5000 ? [.msg(132, Town.fameKinds[k], givenName, familyName)] : [.msg(133, givenName, familyName)]
        if summonsDue { lines += deliverSummons() }
        return lines
    }
}
