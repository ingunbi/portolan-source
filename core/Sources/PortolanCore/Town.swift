import Foundation

// Town services recovered from MAIN.EXE: building entry (0x1B08E →
// 0x1B150), the town arrest (0x1AF95) and the palace arrest (0x2A2A2), and the records the
// palace, bank, guild and shops share. Rules: docs/re/town.md.
//
// Everything the voyage model lacks is kept where the original keeps it, in the data segment
// image (`Voyage.memory`): bank balance [0x123E]/[0x1240], nation records DS:0x1106, the SNR0
// flags and vars, market investment counters, the item table DS:0x8144.

/// A line the town code prints: MESSAGE.DAT line `n` with its `%` fields filled in order, or
/// text the original builds itself (names, titles).
public enum TownLine: Equatable {
    case message(Int, [String])
    case text(String)
    /// Pieces printed on one line (e.g. msg 240, the price, msg 241).
    indirect case joined([TownLine])

    public static func msg(_ n: Int, _ args: CustomStringConvertible...) -> TownLine {
        .message(n, args.map { "\($0)" })
    }
}

extension TownLine {
    /// The line as printed, `messages` being MESSAGE.DAT: `%d`/`%ld`/`%u`/`%s` fields filled
    /// in order, `%%` a percent sign, colour escapes dropped, particle markers fitted.
    public func rendered(_ messages: [String]) -> String { TownLine.particles(raw(messages)) }

    private func raw(_ messages: [String]) -> String {
        switch self {
        case .text(let s): return s
        case .joined(let parts): return parts.map { $0.raw(messages) }.joined()
        case .message(let n, let args): return TownLine.fill(messages.indices.contains(n) ? messages[n] : "", args)
        }
    }

    /// printf-style fill of the original's message formats.
    public static func fill(_ format: String, _ args: [String]) -> String {
        var out = "", k = 0
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\u{1B}" {                                  // ESC + two bytes: colour codes
                i += 3
                continue
            }
            if c == "%", i + 1 < chars.count {
                if chars[i + 1] == "%" {
                    out.append("%")
                    i += 2
                    continue
                }
                var j = i + 1
                while j < chars.count, "-0123456789l".contains(chars[j]) { j += 1 }
                if j < chars.count, "dus".contains(chars[j]) {
                    out += k < args.count ? args[k] : ""
                    k += 1
                    i = j + 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Particle markers, including the town's own (이렸다, 이지, 으로부터의).
    static func particles(_ s: String) -> String {
        let extra: [(String, String, String, Bool)] = [            // marker, after a consonant, after a vowel, ㄹ counts as vowel
            ("(이렸다)", "이렸다", "렸다", false), ("(렸다)", "이렸다", "렸다", false),
            ("(이지)", "이지", "지", false), ("(으로부터의)", "으로부터의", "로부터의", true),
        ]
        var t = s
        for (marker, withCoda, without, rieul) in extra {
            while let r = t.range(of: marker) {
                let last = t[..<r.lowerBound].last
                let k = last.flatMap { Korean.coda($0) }
                let consonant = k != nil && !(rieul && k == 8)
                t.replaceSubrange(r, with: last == nil ? without : consonant ? withCoda : without)
            }
        }
        return Korean.particles(t)
    }
}

/// What a service answers before it asks for a number or a yes/no.
public enum TownAsk: Equatable {
    case refused([TownLine])
    /// Lines, then an amount from 0 to `max` (0 cancels).
    case amount([TownLine], max: Int)
    case yesNo([TownLine])
}

/// Result of walking into a building after its scripts ran.
public struct TownEntry: Equatable {
    public let admitted: Bool
    public let lines: [TownLine]
}

/// Data segment addresses the town code uses (DS offsets).
public enum TownDS {
    public static let nation = 0x1106, nationSize = 32
    public static let bankHundreds = 0x123E, bankUnits = 0x1240
    public static let storyBits = 0xC30
    public static let sharedChapter = 0xCEA, sharedBlock = 0xCEB, sharedFlags = 0xCEC, sharedVars = 0xCF4
    public static let heroV63 = 0xCE8
    /// Set on entering a church; the first prayer of the visit clears it (0x2C5EC).
    public static let prayerReady = 0xC6D8
    public static let goodsNames = 0x764, scriptGoodsNames = 0xC0B6
    public static let sites = 0x7E88, siteSize = 7
    public static let itemTable = 0x8144, itemSize = 26
    public static let fameTable = 0xB8B0

    public static func nation(_ n: Int) -> Int { nation + nationSize * n }
    public static func market(_ p: Int) -> Int { DS.market + DS.marketSize * p }
    public static func port(_ p: Int) -> Int { DS.port + DS.portSize * p }
    public static func item(_ i: Int) -> Int { itemTable + itemSize * i }
    public static func site(_ i: Int) -> Int { sites + siteSize * i }
}

public enum Town {
    public static let noNation = 6
    public static let maxItems = 20
    public static let fameCap = 50_000
    /// Nation names (DS:0x23B..), in support order.
    public static let nationNames = ["포르투갈", "에스파니아", "오스만제국", "영국", "이탈리아", "네덜란드"]
    /// Titles of ranks 1...9 (DATA1.LZW entry 16, loaded to DS:0xC685); rank 0 has none.
    public static let titles = ["", "기사", "준훈작", "훈작", "준남작", "남작", "자작", "백작", "후작", "공작"]
    /// Market +0x1C regions.
    public static let regions = ["유럽", "신대륙", "서아프리카", "동아프리카", "중동", "인도", "동남아", "동부아시아"]
    /// The kinds of fame, as the tavern names them (menu 10).
    public static let fameKinds = ["교역상", "해적", "모험가"]
    /// Ports whose CHIP_NO.DAT class is 2: their church is a mosque.
    public static let mosques: Set<Int> = [2, 4, 5, 18, 19, 20, 21, 22, 25, 72, 73, 74, 75, 76, 77, 78, 79, 80]

    /// Fame needed for the next rank, `500·(r+1)²` (SNR0 block 0; table DS:0xB8B0).
    public static func fameThreshold(rank r: Int) -> Int { 500 * (r + 1) * (r + 1) }

    /// Escape from a town or palace arrest: `swordplay + battleLevel·swordplay/100 ≥ rand(150)`.
    public static func escapes(swordplay s: Int, battleLevel l: Int, roll: Int) -> Bool { s + l * s / 100 >= roll }
}

extension Voyage {
    // MARK: where we are

    /// The market port the fleet lies in.
    public var townPort: Int { marketIndex }

    /// Port record +0x13 & 7 of the port, 6 when it belongs to no one.
    public var portNation: Int {
        markets.indices.contains(marketIndex) ? markets[marketIndex].nation : memory[TownDS.port(marketIndex) + 0x13] & 7
    }

    var heroPerson: Int { DS.person(memory[DS.heroID]) }
    var familyRecord: Int { DS.family(memory[DS.heroID]) }

    /// Person +0x31 & 0xF: the nation the hero serves, 6 for none. The model and the data
    /// segment the scripts read both carry it.
    public var nationality: Int {
        get { captain.nation }
        set {
            captain.nation = newValue
            memory[heroPerson + 0x31] = (memory[heroPerson + 0x31] & 0xF0) | (newValue & 0xF)
        }
    }

    /// Standing with nation `n` (family +6+n); 6 is the byte of nationless palaces (+0xC).
    public func standing(with n: Int) -> Int {
        standing.indices.contains(n) ? standing[n] : memory[familyRecord + 6 + min(n, 6)]
    }

    mutating func setStanding(_ n: Int, _ v: Int) {
        let v = max(0, min(255, v))
        if standing.indices.contains(n) { standing[n] = v } else { memory[familyRecord + 0x0C] = v }
    }

    public var highestFame: Int { fame.max() ?? 0 }

    /// The home port of the hero's fleet (fleet +0x26): the capital, or where the hero defected.
    public var homePort: Int {
        get { memory[DS.fleet(memory[heroPerson + 0x2C]) + 0x26] }
        set { memory[DS.fleet(memory[heroPerson + 0x2C]) + 0x26] = newValue }
    }

    // MARK: SNR0 state (DS:0xCEA)

    /// SNR0 flag `k` (f16 promotion due, f17 summoned, f18 commission accepted).
    public func sharedFlag(_ k: Int) -> Bool { memory[TownDS.sharedFlags + k >> 3] & (1 << (k & 7)) != 0 }

    mutating func setSharedFlag(_ k: Int, _ on: Bool) {
        let a = TownDS.sharedFlags + k >> 3
        memory[a] = on ? memory[a] | 1 << (k & 7) : memory[a] & ~(1 << (k & 7))
    }

    public func sharedVar(_ k: Int) -> Int { memory.word(TownDS.sharedVars + 2 * k) }
    mutating func setSharedVar(_ k: Int, _ v: Int) { memory.setWord(TownDS.sharedVars + 2 * k, v & 0xFFFF) }

    /// SNR0 chapter: 0 no job, 1...5 a guild job, 6...12 a royal commission.
    public var sharedChapter: Int { memory[TownDS.sharedChapter] }

    /// Script table 19 (DS:0xC0B6) holds near pointers to the goods names at run time; the
    /// SNR0 jobs print goods through it (`$r35`). It is filled from the goods name table.
    mutating func loadScriptGoodsNames() {
        for k in 0..<46 { memory.setWord(TownDS.scriptGoodsNames + 2 * k, memory.word(TownDS.goodsNames + 2 * k)) }
    }

    // MARK: entering a building

    /// The town-side rules for walking into building `b` after its scripts let you in
    /// (0x1B150): outside the harbour, palace, residence and church, a nation you stand below
    /// 80 with may arrest you (0x1AF95); the palace has its own guards and door (0x2A424); a
    /// church turns away Muslims and a mosque everyone else (0x2C5EB). In a port of your own
    /// nation the harbour office passes on the king's summons when it is due (0x282C6).
    public mutating func enterBuilding(_ b: Int) -> TownEntry {
        loadScriptGoodsNames()
        let here = memory[DS.currentPort]                       // set by the entry scripts
        if (100..<0xFF).contains(here) { return TownEntry(admitted: true, lines: []) }   // a supply port's quay
        let n = portNation
        if b == ScriptKey.palace { return enterPalace() }
        if b == ScriptKey.church {
            let mosque = Town.mosques.contains(townPort)
            if mosque != (nationality == 2) { return TownEntry(admitted: false, lines: [.msg(mosque ? 802 : 90)]) }
            memory[TownDS.prayerReady] = 1
        }
        var lines: [TownLine] = []
        if ![ScriptKey.harbor, ScriptKey.palace, ScriptKey.residence, ScriptKey.church].contains(b), n < 6, standing[n] < 80 {
            if rng(3) == 0 && rng(100) > standing[n] + 20 {
                return TownEntry(admitted: false, lines: townArrest(n))
            }
            lines.append(.msg(838, Town.nationNames[n]))
        }
        if b == ScriptKey.harbor { lines += harborSummons() }          // 0x282C6
        return TownEntry(admitted: true, lines: lines)
    }

    /// Town arrest (0x1AF95). Escaping keeps everything; otherwise three quarters of the
    /// purse go and the nation's standing rises by 20.
    mutating func townArrest(_ n: Int) -> [TownLine] {
        let name = memory.string(heroPerson + 0x0D, max: 13)
        var lines: [TownLine] = [.msg(839), .msg(840, name)]
        if Town.escapes(swordplay: captain.swordplay, battleLevel: captain.battleLevel, roll: rng(150)) {
            lines += [.msg(842), .msg(843)]
        } else {
            lines += [.msg(841), .msg(845)]
            gold -= 3 * gold / 4
            setStanding(n, min(200, standing(with: n) + 20))
        }
        return lines
    }

    /// Palace arrest (0x2A2A2): four fifths of the purse and of the bank balance (debts too)
    /// are seized, and standing is reset to 100.
    mutating func palaceArrest(_ n: Int) -> [TownLine] {
        let name = memory.string(heroPerson + 0x0D, max: 13)
        if Town.escapes(swordplay: captain.swordplay, battleLevel: captain.battleLevel, roll: rng(150)) {
            return [.msg(446), .msg(448)]
        }
        gold -= 4 * gold / 5
        bankBalance -= 4 * bankBalance / 5                     // truncates toward zero
        setStanding(n, 100)
        return [.msg(445), .msg(449, name), .msg(450), .msg(451), .msg(452)]
    }

    /// Palace door (0x2A424): a nation you stand at most 80 with may seize you; commoners
    /// enter only their own king's palace and only when summoned, unless nationless.
    mutating func enterPalace() -> TownEntry {
        let n = portNation, s = standing(with: n)
        if s <= 80 && rng(100) > s {
            let name = memory.string(heroPerson + 0x0D, max: 13)
            return TownEntry(admitted: false, lines: [.msg(443, name)] + palaceArrest(n))
        }
        if rank == 0 && nationality != 6 && (n != nationality || memory[TownDS.sharedFlags + 2] & 6 == 0) {
            return TownEntry(admitted: false, lines: [.msg(84)])
        }
        return TownEntry(admitted: true, lines: [])
    }
}
