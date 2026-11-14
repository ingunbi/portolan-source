import Foundation

// The rest of the tavern and the inn's guests (docs/re/tavern_more.md): the per-day flags
// `[0xC3C]`, 선원해고 (0x25356), the patron menus of the tavern (0x261C0) and the inn (0x28409),
// the tavern girls (여급과대화 0x26CCB, records DS:0x2B56) and the gambling tables (도박 0x26E14:
// Black Jack 0x2E263, Dice 0x2F620). Native RNG throughout. 밀회 (palace menu 16 item 4) and the
// hidden 결투 of menus 3/12 do not exist in the original and are left out.

/// `[0xC3C]`: flags that last until the day rolls over (0x190F9).
public enum DailyFlag {
    public static let address = 0xC3C
    /// Sailors were signed today: 선원고용 is greyed (0x252A7).
    public static let hired = 0x01
    /// A barmaid's affection bonus was already taken today (자기자랑, the relic in 업무정보).
    public static let boasted = 0x40
}

/// Where a navigator waits: the tavern (person +0x2F bit 0x10) or the inn.
public enum Hangout: Equatable {
    case tavern, inn
}

/// Name tables the tavern prints.
public enum Patron {
    /// Nations as the fleets know them (DS:0x866).
    public static let nations = ["포르투갈", "에스파니아", "오스만제국", "영국", "이탈리아", "네덜란드", "해적", "측량"]
    /// Person +0x2E (DS:0x858).
    public static let roles = ["", "제독", "선장", "부선장", "경리주임", "수석항해사", "항해사"]
    /// The five abilities a patron boasts of (DS:0x87E).
    public static let abilities = ["통솔력", "항해술", "지식", "직감", "용기", "검술", "매력"]
    /// Menu 11: kind of fleet by its number's last digit.
    public static let fleetKinds = ["함대", "상선대", "전함대"]
    /// Menu 15, the tavern's own menu.
    public static let tavernMenu = ["선원고용", "선원해고", "한턱내기", "항해자와대화", "여급과대화", "도박"]

    static func fleetKind(_ f: Int) -> String { fleetKinds[f % 10 == 0 ? 0 : (f % 10) / 5 + 1] }
}

/// The patron's greeting and whether the patron menu follows.
public struct PatronGreeting: Equatable {
    public let lines: [TownLine]
    /// False for your own officers, and for pirates met at the inn.
    public let menu: Bool
}

/// 한턱내기 for one patron (0x25CCC).
public enum PatronTreat: Equatable {
    /// Not enough gold for the drink (76).
    case short([TownLine])
    /// The drink was paid and a job hook takes over (debtor or informant, tavern_jobs §1.5).
    case hook
    case talk([TownLine])
}

// MARK: - per-day flags, hiring, dismissing

extension Voyage {
    var dailyFlags: Int {
        get { memory[DailyFlag.address] }
        set { memory[DailyFlag.address] = newValue }
    }

    /// 선원고용 works once a day (`[0xC3C]` bit 0x01).
    public var hiredToday: Bool { dailyFlags & DailyFlag.hired != 0 }

    /// The tavern's part of the day rollover (0x190F9): the day's flags are cleared and the girls'
    /// investigations draw a day nearer (0x190D1). On New Year's Day (0x15A79) every person and
    /// every girl turns a year older.
    mutating func tavernDay() {
        dailyFlags = 0
        for g in 0..<Barmaid.count {
            let a = Barmaid.record(g) + 0x0F
            if memory[a] != 0xFF && memory[a] != 0 { memory[a] -= 1 }
        }
        if month == 0 && dayOfMonth == 0 {
            for p in 0..<120 { memory[DS.person(p) + 0x2A] += 1 }
            for g in 0..<Barmaid.count { memory[Barmaid.record(g) + 0x0B] += 1 }
        }
    }

    /// 선원고용 from the tavern menu (0x252A7): once a day, and each ship that grew blends its
    /// morale with the newcomers' 60, `(old·morale + new·60) / crew` (0x252E6).
    @discardableResult
    public mutating func hireCrew(_ n: Int, at tavern: Tavern) -> Bool {
        guard !hiredToday else { return false }
        let before = ships.map(\.crew)
        guard hire(n, at: tavern) else { return false }
        for i in ships.indices where ships[i].crew > before[i] {
            ships[i].morale = ((ships[i].crew - before[i]) * 60 + ships[i].morale * before[i]) / ships[i].crew
        }
        dailyFlags |= DailyFlag.hired
        return true
    }

    /// 선원해고 (0x25356 → 0x2515E with n = 0): message 857.
    public func dismissPrompt(ship i: Int) -> TownLine { .msg(857, ships[i].name, ships[i].crew) }

    /// Most sailors ship `i` may keep: its crew, at most its berths.
    public func dismissLimit(ship i: Int) -> Int { min(ships[i].crew, ships[i].crewCapacity) }

    /// message 858; nil when `keep` changes nothing.
    public func dismissConfirm(ship i: Int, keep: Int) -> TownLine? {
        guard ships.indices.contains(i), (0...dismissLimit(ship: i)).contains(keep), keep != ships[i].crew else { return nil }
        return .msg(858, ships[i].crew - keep)
    }

    /// Ship `i` keeps `keep` sailors: no cost, no refund, no minimum. A ship left without crew
    /// loses all morale.
    @discardableResult
    public mutating func dismissCrew(ship i: Int, keep: Int) -> Bool {
        guard dismissConfirm(ship: i, keep: keep) != nil else { return false }
        ships[i].crew = keep
        for k in ships.indices where ships[k].crew == 0 { ships[k].morale = 0 }
        return true
    }
}

// MARK: - the people in port

extension Voyage {
    func given(_ p: Int) -> String { memory.string(DS.person(p), max: 13) }
    func family(_ p: Int) -> String { p < 120 ? memory.string(DS.person(p) + 0x0D, max: 13) : "" }
    var heroIsFemale: Bool { memory[heroPerson + 0x31] & 0x10 != 0 }

    func drinkName(in world: World) -> String {
        let d = market(in: world).drink
        return world.navigation.drinks.indices.contains(d) ? world.navigation.drinks[d].name : ""
    }

    /// Persons in port (0x12B5D): in use, not the hero, and waiting here, sailing with the hero,
    /// or in a fleet below 70 that lies in port at this port's position.
    public func portPeople() -> [Int] {
        let port = townPort
        let px = memory.word(TownDS.port(port)), py = memory.word(TownDS.port(port) + 2)
        let heroFleet = memory[heroPerson + 0x2C]
        return (0..<120).filter { p in
            let a = DS.person(p)
            guard p != heroID, memory[a + 0x31] & 0x20 != 0 else { return false }
            let f = memory[a + 0x2C]
            if memory[a + 0x2D] == port || f == heroFleet { return true }
            guard f < 70, memory.fleetInPort(f) else { return false }
            let at = memory.fleetAt(f)
            return at.x == px && at.y == py
        }
    }

    /// The tavern's drinkers (0x12BEB, person +0x2F bit 0x10) or the inn's guests (0x12C4B).
    public func patrons(at place: Hangout) -> [Int] {
        portPeople().filter { (memory[DS.person($0) + 0x2F] & 0x10 != 0) == (place == .tavern) }
    }

    /// When nobody is there: the tavern points at the inn in a good mood (38, without looking)
    /// or sees no one (39); the inn finds nobody in port (67) or sends you to the tavern (68).
    public func nobodyLine(at place: Hangout, mood: Int) -> TownLine {
        switch place {
        case .tavern: return .msg(mood >= 50 ? 38 : 39)
        case .inn: return .msg(portPeople().isEmpty ? 67 : 68)
        }
    }

    /// Greeting of person `p` (tavern 0x25988, inn 0x28409): your own officers (134–136 / 69–71)
    /// and pirates at the inn (859/860) open no menu; elsewhere the patron says who he serves.
    public mutating func greetPatron(_ p: Int, at place: Hangout) -> PatronGreeting {
        let a = DS.person(p)
        let f = memory[a + 0x2C]
        let tavern = place == .tavern
        if f == memory[heroPerson + 0x2C] { return PatronGreeting(lines: [.msg((tavern ? 134 : 69) + rng(3))], menu: false) }
        if (60..<70).contains(f) { return PatronGreeting(lines: [.msg(859 + rng(2))], menu: tavern) }
        var lines: [TownLine] = [.msg(tavern ? 41 : 72)]
        guard f != 0xFF else { return PatronGreeting(lines: lines + [.msg(tavern ? 43 : 75)], menu: true) }
        let nat = Patron.nations[min(f / 10, 7)], kind = Patron.fleetKind(f), role = memory[a + 0x2E]
        let who: TownLine = role == 1 ? .msg(tavern ? 137 : 73, nat, kind, given(p))
            : .msg(tavern ? 138 : 74, nat, kind, Patron.roles[min(role, 6)], given(p))
        lines.append(tavern ? .joined([.msg(42), who]) : who)
        return PatronGreeting(lines: lines, menu: true)
    }

    /// 한턱내기 for patron `p` (0x25CCC): one drink at this port's price. Friendship +6, ×3 when
    /// the two are of one kind (person +0x2F & 3: 44 "마음이 맞을 것 같군", else 45), ×2 for
    /// persons with +0x2F bit 0x40; a pirate (fleet 60–69) only grumbles (861) but warms all the
    /// same. Past 30 he boasts of his best of the first five abilities if it is over 75 (46 + 139).
    public mutating func treatPatron(_ p: Int, in world: World) -> PatronTreat {
        let d = market(in: world).drink
        let price = world.navigation.drinks.indices.contains(d) ? world.navigation.drinks[d].price : 0
        guard pay(price) else { return .short([.msg(76)]) }
        if patronHook(person: p, treat: true) != nil { return .hook }
        let a = DS.person(p)
        let pirate = (60..<70).contains(memory[a + 0x2C])
        let alike = (memory[heroPerson + 0x2F] ^ memory[a + 0x2F]) & 3 == 0
        var lines: [TownLine] = [.msg(pirate ? 861 : alike ? 44 : 45)]
        memory[a + 0x2B] = min(100, memory[a + 0x2B] + 6 * (alike ? 3 : 1) * (memory[a + 0x2F] & 0x40 != 0 ? 2 : 1))
        var best = 0
        for k in 1..<5 where memory[a + 0x1C + k] > memory[a + 0x1C + best] { best = k }
        if memory[a + 0x2B] > 30 && memory[a + 0x1C + best] > 75 {
            lines.append(.joined([.msg(46), .msg(139, Patron.abilities[best])]))
        }
        return .talk(lines)
    }

    /// 항해자정보 (0x25E34): a rumour, not a profile. A port from three below to seven above this
    /// one: small talk here (47), else the first person waiting there (570) or nobody (571).
    public mutating func navigatorRumour(in world: World) -> [TownLine] {
        let here = townPort
        let t = min(99, here + rng(8))
        let port = t - min(rng(4), t)
        if port == here { return [.msg(47, drinkName(in: world))] }
        let q = (0..<120).first { memory[DS.person($0) + 0x2D] == port && memory[DS.person($0) + 0x31] & 0x20 != 0 }
        return q.map { [.msg(570, portName(port), family($0))] } ?? [.msg(571, portName(port))]
    }

    /// 고용 (0x2609F): the hero asks (48); a man with a post won't change (49), the fleet is full
    /// (140), a tavern patron who is no friend yet refuses (≤ 30, 141; the inn skips this), then
    /// the experience test of `offerTerms` (salary 142, or 145).
    public mutating func askToJoin(_ p: Int, at place: Hangout, in world: World) -> (lines: [TownLine], salary: Int?) {
        let a = DS.person(p)
        let ask: [TownLine] = [.msg(48)]
        if memory[a + 0x2E] != 0 { return (ask + [.msg(49)], nil) }
        if officers.count >= Officers.maxOfficers { return (ask + [.msg(140)], nil) }
        if place == .tavern && memory[a + 0x2B] <= 30 { return (ask + [.msg(141)], nil) }
        switch offerTerms(to: p, in: world) {
        case .salary(let s): return (ask + [.msg(142, s)], s)
        case .refused: return (ask + [.msg(145)], nil)
        case .noRoom: return (ask + [.msg(140)], nil)
        case .busy: return (ask + [.msg(49)], nil)
        }
    }
}

// MARK: - tavern girls

/// A tavern girl (DS:0x2B56 + 17·i, 30 records).
public struct Barmaid: Equatable {
    public static let count = 30
    static func record(_ i: Int) -> Int { DS.woman + DS.womanSize * i }

    public let index: Int
    public let name: String
    /// +0xB, told by 그녀의연령.
    public let age: Int
    public let port: Int
    /// +0xD, 0...100.
    public let affection: Int
    /// +0xE: `nation | kind << 4` of the fleets she was asked to look into, 0xFF none.
    public let request: Int
    /// +0xF: days until she knows, 0xFF none.
    public let daysLeft: Int
    public let flags: Int

    /// KAO portrait `0x61 + i`.
    public var portrait: Int { 0x61 + index }
    /// What she likes (+0x10 >> 4): 0 clothes, 1 jewels, 2 sincerity, 3 talk.
    public var taste: Int { (flags >> 4) & 3 }
    /// +0x10 bit 0: asks 40 affection, not 80, before an investigation.
    public var easyGoing: Bool { flags & 1 != 0 }
    public var present: Bool { flags & 8 != 0 }
    /// +0x10 bit 0x40: greets at the door, not a barmaid.
    public var heroine: Bool { flags & 0x40 != 0 }

    /// 자기자랑 replies by discovery category (DS:0x8DA order).
    static let boastLines = [314, 315, 316, 317, 318, 319, 320, 315]
    /// Fleet numbers `nation·10 + k` of each investigation kind (DS:0xB5F6).
    static let kindFleets = [1, 5, 7, 10]
}

public enum BarmaidTopic: Int, CaseIterable {
    case boast, gift, inquiry, gossip
    /// Menu 14.
    public var name: String { ["자기자랑", "선물", "조사의뢰", "정보수집"][rawValue] }
}

public enum GossipTopic: Int, CaseIterable {
    case jobs, taste, age
    /// Menu 13.
    public var name: String { ["업무정보", "그녀의취향", "그녀의연령"][rawValue] }
}

/// 조사의뢰 (0x26862) before anything is asked.
public enum InquiryDesk: Equatable {
    /// messages 533 (affection short) and 537.
    case says([TownLine])
    /// The report is ready (0x26648).
    case report
    /// She takes a request: which nation (534), then which kind (535).
    case request
}

/// 업무정보 (0x268C3).
public enum JobInfo: Equatable {
    case says([TownLine])
    /// Jobs 4 and 12 go straight to a fleet investigation (0x26570), affection or not.
    case inquiry
}

extension Voyage {
    public func barmaid(_ i: Int) -> Barmaid {
        let a = Barmaid.record(i)
        return Barmaid(index: i, name: memory.string(a, max: 11), age: memory[a + 0x0B], port: memory[a + 0x0C],
                       affection: memory[a + 0x0D], request: memory[a + 0x0E], daysLeft: memory[a + 0x0F], flags: memory[a + 0x10])
    }

    private func girlsHere() -> [Barmaid] {
        (0..<Barmaid.count).map(barmaid).filter { $0.port == townPort && $0.present }
    }

    /// The girl who greets you at the door (0x26F15): present here with bit 0x40; never for a
    /// female hero.
    public var heroineHere: Int? { heroIsFemale ? nil : girlsHere().first { $0.heroine }?.index }

    /// The barmaid (0x26F55): the first girl present here who is not a heroine; 여급과대화 is greyed
    /// without one. A female hero needs an easy-going one (the original tests a stale pointer).
    public var barmaidHere: Int? {
        guard let g = girlsHere().first(where: { !$0.heroine }) else { return nil }
        return heroIsFemale && !g.easyGoing ? nil : g.index
    }

    /// Entering the tavern (0x26FF5), unless a script spoke: the heroine's welcome (17) or the
    /// keeper's (18); a female hero's barmaid then mentions her investigation (307 / 308).
    public func tavernGreeting(in world: World) -> [TownLine] {
        guard sharedVar(63) == 0 && memory.word(TownDS.heroV63) == 0 else { return [] }
        let drink = drinkName(in: world)
        var lines: [TownLine] = heroineHere != nil ? [.msg(17, givenName, drink)] : [.msg(18, drink)]
        if heroIsFemale, let g = barmaidHere.map(barmaid) {
            lines.append(.msg(g.request != 0xFF && g.daysLeft == 0 ? 307 : 308))
        }
        return lines
    }

    /// 여급과대화 (0x26CCB): the keeper asks ten gold for her company (146; 147 when short). One
    /// fee covers the whole talk.
    public mutating func callBarmaid(_ g: Int) -> (lines: [TownLine], seated: Bool) {
        let lines: [TownLine] = [.msg(146, barmaid(g).name)]
        guard gold >= 10 else { return (lines + [.msg(147)], false) }
        gold -= 10
        return (lines, true)
    }

    /// Menu 14: a female hero has nothing to boast or give.
    public var barmaidTopics: [BarmaidTopic] { heroIsFemale ? [.inquiry, .gossip] : BarmaidTopic.allCases }

    // MARK: 자기자랑 (0x262D5)

    /// Sites to boast of: active and found, or their treasure map bought (site +6: 0x80 clear, 0x20 set).
    public var boastableSites: [Int] {
        (0..<100).filter { s in
            let f = memory[TownDS.site(s) + 6]
            return f & 0x80 == 0 && f & 0x20 != 0
        }
    }

    /// 자기자랑 of site `s` to girl `g` (313): `value / 10 + 1` affection, once a day (flag 0x40).
    /// A girl of taste 2 or 3 doubles it, answers the tale (314–320) and listens any number of
    /// times (she clears the flag first).
    public mutating func boast(_ s: Int, to g: Int) -> [TownLine] {
        let a = TownDS.site(s), r = Barmaid.record(g)
        var gain = memory[a + 5] / 10 + 1
        var line: TownLine = .msg(313)
        if barmaid(g).taste >= 2 {
            gain *= 2
            line = .joined([.msg(313), .msg(Barmaid.boastLines[memory[a + 6] & 7])])
            dailyFlags &= ~DailyFlag.boasted
        }
        if dailyFlags & DailyFlag.boasted == 0 {
            memory[r + 0x0D] = min(100, memory[r + 0x0D] + gain)
            dailyFlags |= DailyFlag.boasted
        }
        return [line]
    }

    // MARK: 선물 (0x263F8)

    /// Presents in the bag (0x12E82): accessories (type 10) and jewels (type 11), as held.
    public var giftItems: [Int] { items.filter { [10, 11].contains(item($0).type) } }

    /// Nothing to give: 330 (easy-going) or 331.
    public func noGiftLine(_ g: Int) -> TownLine { .msg(barmaid(g).easyGoing ? 330 : 331) }

    /// 선물 of item `id` to girl `g` (321): `min(10, value)` affection, doubled for what she likes
    /// (taste 0 accessories 322, taste 1 jewels 323, taste 3 anything 324; taste 2 nothing), with
    /// a kiss (325) when she already stood at 80. The first such item leaves the bag.
    public mutating func give(_ id: Int, to g: Int) -> [TownLine] {
        guard let k = items.firstIndex(of: id) else { return [] }
        let r = Barmaid.record(g), it = item(id), taste = barmaid(g).taste
        var gain = min(10, it.power)
        let liked: Int? = taste == 0 && it.type == 10 ? 322 : taste == 1 && it.type == 11 ? 323 : taste == 3 ? 324 : nil
        var lines: [TownLine] = [.msg(321)]
        if let liked {
            gain *= 2
            lines = [.joined([.msg(321), .msg(liked)])]
            if memory[r + 0x0D] >= 80 { lines.append(.msg(325)) }
        }
        memory[r + 0x0D] = min(100, memory[r + 0x0D] + gain)
        items.remove(at: k)
        return lines
    }

    // MARK: 조사의뢰 (0x26862)

    /// A request pending: not done (537) or the report. None: she needs 80 affection (40 if
    /// easy-going; a female hero none), else 533.
    public func inquiryDesk(_ g: Int) -> InquiryDesk {
        let b = barmaid(g)
        if b.request != 0xFF { return b.daysLeft != 0 ? .says([.msg(537)]) : .report }
        if !heroIsFemale && b.affection < 80 / ((b.flags & 1) + 1) { return .says([.msg(533)]) }
        return .request
    }

    /// Menu 44 (the nations' fleets) or 45 (the pirates').
    public static func inquiryKinds(nation n: Int) -> [String] {
        n == 6 ? ["카리브해적", "코르세르", "사략선대"] : ["상선대", "경비함대", "외양함대"]
    }

    /// A new request (0x26570, free): nation `n` 0–6, kind `c` 0–2. She needs `rand(3) +
    /// (110 − affection) / 5` days (/ 85 for a female hero) and says so (536).
    public mutating func requestInquiry(_ g: Int, nation n: Int, kind c: Int) -> [TownLine] {
        let r = Barmaid.record(g)
        memory[r + 0x0E] = min(n, 6) | min(c, 2) << 4
        let days = rng(3) + (110 - memory[r + 0x0D]) / (5 * ((memory[heroPerson + 0x31] & 0x10) + 1))
        memory[r + 0x0F] = days
        return [.msg(536, days)]
    }

    /// Esc at "어떤 함대인가요？" (535) drops the request, a pending one too (+0xE = 0xFF).
    public mutating func dropInquiry(_ g: Int) { memory[Barmaid.record(g) + 0x0E] = 0xFF }

    /// The report (0x26648), from the fleets as they are now: for each fleet of the kind its
    /// admiral and mission (541 + 542/543/548–551), cargo (544) and position (553, 554), or that
    /// it was wiped out (556). The request is then closed.
    public mutating func inquiryReport(_ g: Int, in world: World) -> [TownLine] {
        let r = Barmaid.record(g), req = memory[r + 0x0E]
        let n = min(req & 0x0F, 6), c = min(req >> 4, 2)
        let kind = Voyage.inquiryKinds(nation: n)[c]
        var lines: [TownLine] = [.msg(538), n != 6 ? .joined([.msg(539, Patron.nations[n]), .msg(540, kind)]) : .msg(540, kind)]
        let first = Barmaid.kindFleets[c]
        for k in first..<Barmaid.kindFleets[c + 1] {
            let f = n * 10 + k
            guard memory.fleetActive(f) else {
                lines.append(.msg(556, k - first + 1))
                continue
            }
            let t = memory.fb(f, FleetField.target)
            let port = t < 130 ? portName(t) : ""
            var head: [TownLine] = [.msg(541, family(memory.fb(f, FleetField.admiral)))]
            switch memory.fb(f, FleetField.mission) {
            case 0, 1, 2: head.append(.msg(542, port))
            case 3: head.append(.msg(550, port))
            case 4: head.append(.msg(551))
            case 5, 6, 7: head.append(.msg(543, family(t)))
            case 8: head.append(.msg(549, family(t)))
            case 9: head.append(.msg(548, port))
            default: break
            }
            lines.append(.joined(head))
            let good = memory.fb(f, FleetField.good)
            if good != 0xFF { lines.append(.msg(544, goodsName(good, in: world))) }
            let at = memory.fleetAt(f)
            lines.append(.joined([.msg(553)] + latLon(at.x, at.y) + [.msg(554)]))
        }
        memory[r + 0x0E] = 0xFF
        memory[r + 0x0F] = 0xFF
        return lines
    }

    func goodsName(_ g: Int, in world: World) -> String {
        world.navigation.goods.indices.contains(g) ? world.navigation.goods[g].name : memory.string(memory.word(TownDS.goodsNames + 2 * g))
    }

    // MARK: 정보수집 (0x26C59)

    /// 업무정보 is greyed unless a job is past its briefing (`[0xCEA]` and `[0xCEB]` set).
    public var jobInfoOffered: Bool { sharedChapter != 0 && memory[TownDS.sharedBlock] != 0 }

    /// 업무정보 (0x268C3, tavern_jobs.md §6): what she heard about the job (v6) in hand.
    public mutating func jobInfo(_ g: Int, in world: World) -> JobInfo {
        let job = sharedVar(6), v18 = sharedVar(18), port = sharedVar(17) & 0xFF
        let r = Barmaid.record(g)
        switch job {
        case 4, 12: return .inquiry
        case 9: return .says([.msg(586)])
        case 10: return .says([.msg(587)])
        case 11:
            for id in items {
                if id == (v18 - 10) & 0xFF { return .says([.msg(1018, itemName(id))]) }       // the map
                if id == v18 & 0xFF {                                                          // the relic
                    if dailyFlags & DailyFlag.boasted == 0 {
                        memory[r + 0x0D] = min(100, memory[r + 0x0D] + 10)
                        dailyFlags |= DailyFlag.boasted
                    }
                    return .says([.msg(1019, itemName(id))])
                }
            }
            return .says([.msg(sharedVar(17) == 0xFF ? 588 : 589)])
        case 5: return .says([.msg(589)])
        default: break
        }
        guard port < 100 else { return .says([]) }
        let here = townPort == port
        let near = latLon(memory.word(TownDS.port(port)), memory.word(TownDS.port(port) + 2))
        switch job {
        case 3:                                                     // the original prints 590 without its port
            return .says([.joined([.msg(590, portName(port))] + near + [.msg(594)])])
        case 7, 8:
            if here { return .says([.msg(585)]) }
            let seat: TownLine = .msg(v18 < 4 ? 591 : 592, Patron.nations[min(v18, 7)])
            return .says([.joined([seat, .msg(593, portName(port))] + near + [.msg(594)])])
        case 1:
            if here { return .says([.msg(585)]) }
            if hearsNothing(g) { return .says([.msg(399)]) }
            return .says([.joined([.msg(401, portName(port)), .msg(385 + marketRecord(port, world).zone), .msg(402)])])
        case 2, 6:
            if hearsNothing(g) { return .says([.msg(399)]) }
            let goods = goodsName(v18, in: world)
            if let q = (0..<40).first(where: { p in
                let m = marketRecord(p, world)
                return m.specialty == v18 && m.specialtyEconomy <= m.economy
            }) {
                return .says([.msg(400, goods, portName(q))])
            }
            // Zones are searched from 12 down to 0 and the last match stands: the lowest zone wins.
            if let z = world.navigation.zones.indices.first(where: { world.navigation.zones[$0].goods.contains { $0.good == v18 } }) {
                return .says([.joined([.msg(202, goods), .msg(385 + z), .msg(203)])])
            }
            return .says([.msg(399)])
        default:
            return .says([])
        }
    }

    private func marketRecord(_ p: Int, _ world: World) -> Market {
        markets.indices.contains(p) ? markets[p] : world.navigation.markets[p]
    }

    /// `charm + affection ≤ rand(150)` and a male hero: "죄송해요, 모르겠어요." (399).
    private mutating func hearsNothing(_ g: Int) -> Bool {
        let roll = rng(150)
        return captain.charm + barmaid(g).affection <= roll && !heroIsFemale
    }

    /// 그녀의취향 (0x26BB8): when `rand(50) < affection` she tells (405 + taste) and likes being
    /// asked (+2, +4 for taste 2/3, no daily limit); else "그것은 비밀이예요." (403).
    public mutating func herTaste(_ g: Int) -> [TownLine] {
        let r = Barmaid.record(g), taste = barmaid(g).taste
        guard rng(50) < memory[r + 0x0D] else { return [.msg(403)] }
        memory[r + 0x0D] = min(100, memory[r + 0x0D] + (taste < 2 ? 2 : 4))
        return [.msg(405 + taste)]
    }

    /// 그녀의연령 (0x26C2D): above 80 affection she tells (404), else 403.
    public func herAge(_ g: Int) -> [TownLine] {
        let b = barmaid(g)
        return [b.affection > 80 ? .msg(404, b.age) : .msg(403)]
    }
}

// MARK: - 도박 (0x26E14)

/// A line at a gambling table and who says it: 0 nobody in particular, 1 the dealer or the first
/// dice player (A), 2 the second dice player (B).
public struct TableLine: Equatable {
    public let speaker: Int
    public let line: TownLine
    public init(_ speaker: Int, _ line: TownLine) {
        self.speaker = speaker
        self.line = line
    }
}

public enum Gambling {
    public static let minBet = 10, maxBet = 500
    /// "Black Jack", "Dice" (DS:0xB616, DS:0xB621).
    public static let games = ["Black Jack", "Dice"]

    /// Largest stake (0x2DA11): `min(gold, 500)`. Both games need at least 10.
    public static func betLimit(gold: Int) -> Int { min(gold, maxBet) }
    public static func canPlay(gold: Int) -> Bool { gold >= minBet }
}

extension Voyage {
    /// 도박 (0x26E14): nobody plays with a hero who has no coin at all (1010).
    public var gamblingRefusal: TownLine? { gold == 0 ? .msg(1010) : nil }

    /// A gambler's generated face (`rand(0x3FFF) | 0xC000`).
    public mutating func gamblerFace() -> Int { rng(0x3FFF) | 0xC000 }
}

/// Black Jack (0x2E263) against one dealer, 24 cards from a fresh deck each round.
public enum BlackJack {
    /// Rank letters (DS:0xB90C), suits for display.
    public static let ranks = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
    /// In the order of the card pictures (DATA1[9]: ♠ ♥ ♣ ♦, sprites.md §5).
    public static let suits = ["♠", "♥", "♣", "♦"]

    public static func name(_ c: Int) -> String { suits[c / 13 % 4] + ranks[c % 13] }

    /// Card value (0x2DD8A): `min(10, rank + 1)`.
    public static func value(_ c: Int) -> Int { min(10, c % 13 + 1) }

    /// Hand total (0x2DBB2): an ace counts 11 once while the sum is at most 11.
    public static func total(_ hand: [Int]) -> Int {
        let s = hand.reduce(0) { $0 + value($1) }
        return hand.contains { $0 % 13 == 0 } && s <= 11 ? s + 10 : s
    }

    /// The shoe (0x2DA2A): a fresh 52-card deck, 208 swaps `deck[k % 52] ↔ deck[rand(52)]`, the
    /// first 24 cards.
    public static func shoe(_ rng: inout GameRandom) -> [Int] {
        var deck = Array(0..<52)
        for k in 0..<208 { deck.swapAt(k % 52, rng(52)) }
        return Array(deck.prefix(24))
    }

    /// The dealer's remark on a bet (0x2DBEE): 963 under 20, 964 over 200, else 965.
    public static func remark(bet: Int) -> Int { bet < 20 ? 963 : bet > 200 ? 964 : 965 }

    public struct Settlement: Equatable {
        /// What the player gets back, as multiples of the bet already taken.
        public let playerMultiple: Int
        /// What the player pays on top of the lost bet.
        public let dealerMultiple: Int
        public let message: Int
        public init(_ pm: Int, _ dm: Int, _ msg: Int) {
            playerMultiple = pm
            dealerMultiple = dm
            message = msg
        }
    }

    /// Settle (0x2DD9D). `player` and `dealer` are the hands as dealt (the dealer's hole card
    /// first), `p` and `d` the scores with 0 for a bust. Ties and double busts go to the dealer.
    public static func settle(player: [Int], p: Int, dealer: [Int], d: Int) -> Settlement {
        if d < p {
            if p == 21 && player.count == 2 {
                if Set(player) == [0, 10] { return Settlement(6, 0, 966) }              // A + J of the first suit
                if player.contains(where: { $0 % 13 > 9 }) { return Settlement(3, 0, 967) }
                return Settlement(2, 0, 968)
            }
            if p == 21 && player.count == 3 {
                if let s = special(player) { return Settlement(4, 0, s == 0 ? 969 : 970) }
                return Settlement(2, 0, 968)
            }
            return player.count >= 5 ? Settlement(4, 0, 971) : Settlement(2, 0, 968)
        }
        if d == 21 && dealer.count == 2 {
            if Set(dealer) == [0, 10] { return Settlement(0, 4, 972) }
            if dealer.contains(where: { $0 % 13 > 9 }) { return Settlement(0, 1, 973) }
            return Settlement(0, 0, 974)
        }
        if d == 21 && dealer.count == 3 {
            if let s = special(dealer) { return Settlement(0, 2, s == 0 ? 975 : 976) }
            return Settlement(0, 0, 974)
        }
        if dealer.count >= 5 && d != 0 { return Settlement(0, 2, 977) }
        return Settlement(0, 0, 974)
    }

    /// Three cards sorted by id: one rank (0, 7-7-7) or consecutive ids (1, a run in one suit, or
    /// Q-K-A across a suit boundary).
    private static func special(_ hand: [Int]) -> Int? {
        let s = hand.sorted()
        if s[0] % 13 == s[1] % 13 && s[0] % 13 == s[2] % 13 { return 0 }
        if s[1] == s[0] + 1 && s[2] == s[1] + 1 { return 1 }
        return nil
    }

    /// Gold after a settlement (0x2E01E): `+ (pm − dm)·bet`, never below zero, no purse cap.
    public static func pay(gold: Int, bet: Int, _ s: Settlement) -> Int {
        if s.dealerMultiple != 0 && (gold == 0 || s.dealerMultiple * bet > gold) { return 0 }
        return gold + (s.playerMultiple - s.dealerMultiple) * bet
    }

    /// Leaving the table (0x2E263): "벌써 돌아가는 거냐？" after winning more than 500 (982), "또
    /// 오시오！" after losing more than 500 (983); nothing when broke.
    public static func farewell(start: Int, gold: Int) -> [TownLine] {
        guard gold != 0 else { return [] }
        return (gold > start + 500 ? [.msg(982)] : []) + (gold + 500 < start ? [.msg(983)] : [])
    }
}

/// One round of Black Jack (0x2E09B).
public struct BlackJackRound: Equatable {
    public let shoe: [Int]
    public private(set) var bet = 0
    /// The player's cards: shoe[0], then shoe[2...].
    public private(set) var player: [Int]
    /// The dealer's cards, the hole card (shoe[1]) first; empty until the player is done.
    public private(set) var dealer: [Int] = []
    /// The hole card is turned once the dealer stands on 17 or more; six cards under 17 stay hidden.
    public private(set) var holeShown = false
    public private(set) var playerScore = 0
    public private(set) var dealerScore = 0
    public private(set) var settlement: BlackJack.Settlement?
    private var next = 2

    public var placed: Bool { bet > 0 }
    public var finished: Bool { settlement != nil }
    public var playerTotal: Int { BlackJack.total(player) }

    /// A fresh shoe; the player's first card is shown before the bet.
    public init(_ v: inout Voyage) {
        self.init(shoe: BlackJack.shoe(&v.rng))
    }

    init(shoe: [Int]) {
        self.shoe = shoe
        player = [shoe[0]]
    }

    /// The bet, 10...min(gold, 500), taken at once; the second card follows. Returns the dealer's
    /// remark, nil for a bet out of range.
    @discardableResult
    public mutating func place(_ amount: Int, _ v: inout Voyage) -> TownLine? {
        guard !placed, amount >= Gambling.minBet, amount <= Gambling.betLimit(gold: v.gold) else { return nil }
        bet = amount
        v.gold -= amount
        deal(&v)
        return .msg(BlackJack.remark(bet: amount))
    }

    /// ＨＩＴ.
    public mutating func hit(_ v: inout Voyage) {
        guard placed, !finished else { return }
        deal(&v)
    }

    /// ＳＴＡＮＤ.
    public mutating func stand(_ v: inout Voyage) {
        guard placed, !finished else { return }
        finish(playerTotal, &v)
    }

    /// A bust ends the player's turn with 0; seven cards stand.
    private mutating func deal(_ v: inout Voyage) {
        player.append(shoe[next])
        next += 1
        if playerTotal > 21 { finish(0, &v) } else if player.count == 7 { finish(playerTotal, &v) }
    }

    /// The dealer draws to 17 (a soft 17 stands) or six cards, even after a player's bust.
    private mutating func finish(_ p: Int, _ v: inout Voyage) {
        playerScore = p
        dealer = [shoe[1]]
        var k = next
        while true {
            dealer.append(shoe[k])
            k += 1
            let t = BlackJack.total(dealer)
            if t >= 17 {
                holeShown = true
                dealerScore = t > 21 ? 0 : t
                break
            }
            if dealer.count == 6 {
                dealerScore = t
                break
            }
        }
        let s = BlackJack.settle(player: player, p: p, dealer: dealer, d: dealerScore)
        settlement = s
        v.gold = BlackJack.pay(gold: v.gold, bet: bet, s)
    }
}

/// Poker dice (0x2F620) against two players. Dice are raw 0–5 with 0 for six.
public enum Dice {
    /// Hand names by rank (DS:0xB9F6).
    public static func handName(rank: Int) -> String {
        [1: "원 페어", 2: "투 페어", 3: "쓰리 다이스", 4: "풀 하우스", 6: "포 다이스", 10: "파이브 다이스"][rank] ?? ""
    }

    /// Pips shown for a raw die.
    public static func face(_ d: Int) -> Int { d == 0 ? 6 : d }

    /// A roll (0x2EE2A): unheld dice get `rand(6)`, then all five are insertion-sorted ascending on
    /// the raw value (sixes first), their holds moving with them.
    public static func roll(_ dice: inout [Int], held: inout [Bool], _ rng: inout GameRandom) {
        if dice.count != 5 { dice = [0, 0, 0, 0, 0] }
        for i in 0..<5 where !held[i] { dice[i] = rng(6) }
        for i in 1..<5 {
            var j = i
            while j > 0 && dice[j - 1] > dice[j] {
                dice.swapAt(j - 1, j)
                held.swapAt(j - 1, j)
                j -= 1
            }
        }
    }

    /// What a player keeps between rolls (0x2E68C): every die that matches another.
    public static func pairs(_ dice: [Int]) -> [Bool] {
        dice.map { d in dice.filter { $0 == d }.count > 1 }
    }

    /// Hand rank (0x2E70A): the number of equal pairs among the five dice. 10 five, 6 four,
    /// 4 full house, 3 three, 2 two pair, 1 one pair, 0 nothing; no straights.
    public static func rank(_ dice: [Int]) -> Int {
        var n = 0
        for i in 0..<dice.count { for j in (i + 1)..<dice.count where dice[i] == dice[j] { n += 1 } }
        return n
    }

    /// Tie-break faces (higher wins, kickers ignored): five → the die; four or three → the middle
    /// die; full house → the middle die, then the pair; two pair → the first pair in raw order
    /// (sixes if any, else the lower pair, 0x2E745), then the other; one pair → the pair.
    public static func keys(_ dice: [Int]) -> [Int] {
        let d = dice.sorted()
        let paired = d.enumerated().filter { $0.offset == 0 || d[$0.offset - 1] != $0.element }.map(\.element)
            .filter { v in d.filter { $0 == v }.count == 2 }
        switch rank(d) {
        case 10: return [face(d[0])]
        case 6, 3: return [face(d[2])]
        case 4: return [face(d[2])] + paired.map(face)
        case 2, 1: return paired.map(face)
        default: return []
        }
    }

    /// Who wins (0x2E8DD) among you, A and B: 0 you, 1 A, 2 B, 3 A and B, 4 all three, 5 you
    /// and A, 6 you and B. The original's slips in the all-equal-rank cases are not kept.
    public static func compare(_ you: [Int], _ a: [Int], _ b: [Int]) -> Int {
        let s = [you, a, b].map { [rank($0)] + keys($0) }
        let best = s.max { $0.lexicographicallyPrecedes($1) }!
        let top = (0..<3).filter { s[$0] == best }
        switch top {
        case [0]: return 0
        case [1]: return 1
        case [2]: return 2
        case [1, 2]: return 3
        case [0, 1]: return 5
        case [0, 2]: return 6
        default: return 4
        }
    }

    /// Leaving (0x2F620): A and B grumble after you won more than 500 (1006, 1007) or gloat after
    /// you lost more than 500 (1008, 1009); nothing when broke.
    public static func farewell(start: Int, gold: Int) -> [TableLine] {
        guard gold != 0 else { return [] }
        if gold > start + 500 { return [TableLine(1, .msg(1006)), TableLine(2, .msg(1007))] }
        if gold + 500 < start { return [TableLine(1, .msg(1008)), TableLine(2, .msg(1009))] }
        return []
    }
}

/// One round of dice (0x2F233): bet and haggle, three rolls each in turn, the pot.
public struct DiceRound: Equatable {
    public enum Phase: Equatable {
        /// Waiting for the stake (962).
        case betting
        /// The other player wants `n` gold instead (985): yes or no.
        case offer(Int)
        /// Your dice are on the table: "이 눈으로 승부를？" (984).
        case rolling
        case finished
    }

    /// Who asks for the stake (1 = A, 2 = B), and the most it may be.
    public let asker: Int
    public let limit: Int
    public private(set) var bet = 0
    public private(set) var phase = Phase.betting
    /// Dice of you, A and B, sorted raw, and their holds.
    public private(set) var dice: [[Int]] = [[], [], []]
    public private(set) var held = [[Bool]](repeating: [Bool](repeating: false, count: 5), count: 3)
    public private(set) var rolls = [0, 0, 0]
    public private(set) var lines: [TableLine]
    /// The compare code, once all have rolled.
    public private(set) var result: Int?
    /// Who rolls first next round: 0 A,B,you; 1 B,you,A; 2 you,A,B.
    public private(set) var order: Int

    public init(order: Int, _ v: inout Voyage) {
        self.order = order
        limit = Gambling.betLimit(gold: v.gold)
        asker = v.rng(2) + 1
        lines = [TableLine(asker, .msg(962))]
    }

    private var other: Int { 3 - asker }
    private var sequence: [Int] { [[1, 2, 0], [2, 0, 1], [0, 1, 2]][min(order, 2)] }

    /// The stake (10...limit), then the haggling (0x2F048): at 200 or more, or one time in four,
    /// both agree (993, 994); else the other asks for 10–100 % more (10–50 % from 100 up).
    @discardableResult
    public mutating func place(_ amount: Int, _ v: inout Voyage) -> Bool {
        guard phase == .betting, (Gambling.minBet...max(Gambling.minBet, limit)).contains(amount), amount <= v.gold else { return false }
        bet = amount
        if amount >= 200 || v.rng(4) == 0 {
            lines += [TableLine(asker, .msg(993)), TableLine(other, .msg(994))]
            start(&v)
            return true
        }
        let prop = amount + amount * (v.rng(amount < 100 ? 10 : 5) + 1) / 10
        lines.append(TableLine(other, .msg(985, prop)))
        phase = .offer(prop)
        return true
    }

    /// Your answer to the higher stake: yes takes it (986, 987); no keeps yours one time in
    /// three (991, 992), else they settle on theirs (988, 987) or halfway (989, 990).
    public mutating func answer(_ yes: Bool, _ v: inout Voyage) {
        guard case .offer(let prop) = phase else { return }
        if yes {
            bet = prop
            lines += [TableLine(asker, .msg(986)), TableLine(other, .msg(987))]
        } else if v.rng(3) == 0 {
            lines += [TableLine(asker, .msg(991, bet)), TableLine(other, .msg(992))]
        } else {
            bet = v.rng(2) != 0 ? prop : (prop + bet) / 2
            lines += bet == prop ? [TableLine(asker, .msg(988, bet)), TableLine(other, .msg(987))]
                : [TableLine(asker, .msg(989, bet)), TableLine(other, .msg(990))]
        }
        start(&v)
    }

    /// The stake leaves the purse; whoever rolls before you rolls, then your first roll.
    private mutating func start(_ v: inout Voyage) {
        bet = min(bet, limit)
        v.gold -= bet
        for p in sequence.prefix(while: { $0 != 0 }) { opponentRolls(p, &v) }
        rollOnce(0, &v)
        phase = .rolling
    }

    private mutating func rollOnce(_ p: Int, _ v: inout Voyage) {
        Dice.roll(&dice[p], held: &held[p], &v.rng)
        rolls[p] += 1
    }

    /// Three rolls, keeping every die that matches another after the first two.
    private mutating func opponentRolls(_ p: Int, _ v: inout Voyage) {
        for k in 0..<3 {
            rollOnce(p, &v)
            if k < 2 { held[p] = zip(held[p], Dice.pairs(dice[p])).map { $0 || $1 } }
        }
    }

    /// "이 눈으로 승부를？" yes.
    public mutating func stay(_ v: inout Voyage) {
        guard phase == .rolling else { return }
        finish(&v)
    }

    /// No: the dice marked in `keep` are held for good and the rest roll again; after the third
    /// roll, or with all five held, you stand.
    public mutating func reroll(keeping keep: [Bool], _ v: inout Voyage) {
        guard phase == .rolling else { return }
        for i in 0..<5 where i < keep.count && keep[i] { held[0][i] = true }
        guard held[0].contains(false) else { return finish(&v) }
        rollOnce(0, &v)
        if rolls[0] == 3 { finish(&v) }
    }

    /// Those after you roll; the pot: you alone 3× (997), shared with one 3/2× (1000), all three
    /// 1× (999), else lost (998). The winner leads off next round.
    private mutating func finish(_ v: inout Voyage) {
        for p in sequence.drop(while: { $0 != 0 }).dropFirst() { opponentRolls(p, &v) }
        let r = Dice.compare(dice[0], dice[1], dice[2])
        result = r
        switch r {
        case 0:
            lines.append(TableLine(1, .msg(997)))
            v.gold += 3 * bet
            order = 2
        case 1, 2, 3:
            lines.append(TableLine(r == 2 ? 2 : 1, .msg(998)))
            if r == 1 { order = 0 } else if r == 2 { order = 1 } else if order == 2 { order = 0 }
        case 4:
            lines.append(TableLine(1, .msg(999)))
            v.gold += bet
        default:
            if r == 5 && order == 1 { order = 2 }
            if r == 6 && order == 0 { order = 1 }
            lines.append(TableLine(r == 5 ? 2 : 1, .msg(1000)))
            v.gold += 3 * bet / 2
        }
        phase = .finished
    }
}
