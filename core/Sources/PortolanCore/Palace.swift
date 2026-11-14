import Foundation

// The royal palace (왕궁, building 5, 0x2A424): audience 0x29EDD and its submenu (세력상황
// 0x29BC8, 사략허가서 0x29C3A, 면세증 0x29D46), defection 0x29FB0, gold aid 0x2A0CD, ship aid
// 0x2A155; the monthly royal aid 0x183DA. Promotion itself is the
// SNR0 royal commission (chapters 6–12), which the audience starts. docs/re/town.md §4–5.

public enum Palace {
    /// Privateer licence of nation n (item 0x1D + n), tax-exemption certificate (0x23 + n).
    public static func privateerLicence(_ n: Int) -> Int { 0x1D + n }
    public static func taxCertificate(_ n: Int) -> Int { 0x23 + n }

    /// Price of a tax-exemption certificate (0x29D46): free for an own-nation count or
    /// better, `(7 − rank)·10000` at home, `(11 − rank)·10000` abroad.
    public static func certificatePrice(rank r: Int, ownNation: Bool) -> Int {
        ownNation ? (r >= 6 ? 0 : (7 - r) * 10000) : (11 - r) * 10000
    }

    /// Royal aid accrued in a month for `x = rank × nation income` (0x183DA): gold in
    /// thousands (cap 100), the class of ship on offer (cap 7) and ships added (≤ 10).
    public static func aid(x: Int) -> (gold: Int, other: Int, shipClass: Int, ships: Int) {
        (x / 3000, x / 1000, min(7, x / 4000), min(10, x / 4000))
    }

    /// The ruler of nation n is story NPC 10 + n (DS:0x29B2); nation 6's palace has NPC 16.
    public static func ruler(of n: Int) -> Int { 10 + min(n, 6) }

    /// Portrait of each ruler (NPC +0x11), as the commission scripts set it (v50).
    public static let rulerFaces = [20, 24, 29, 27, 37, 28, 30]
}

/// The palace menu (menu 16): only four items are ever offered (밀회 never is).
public struct PalaceMenu: Equatable {
    public var defect: Bool
    public var aid: Bool
}

extension Voyage {
    // MARK: nation records (DS:0x1106)

    func nationByte(_ n: Int, _ off: Int) -> Int { memory[TownDS.nation(n) + off] }
    mutating func setNationByte(_ n: Int, _ off: Int, _ v: Int) { memory[TownDS.nation(n) + off] = v }

    /// Gold aid waiting at nation n's palace, in thousands (+5).
    public func pendingGoldAid(_ n: Int) -> Int { nationByte(n, 5) }
    /// Aid ships waiting (+8) and their class (+7, 0xFF none).
    public func pendingShipAid(_ n: Int) -> (count: Int, shipClass: Int) { (nationByte(n, 8), nationByte(n, 7)) }
    /// War target of nation n (+2): another nation, 6 the pirates, 7 the player.
    public func warTarget(of n: Int) -> Int { nationByte(n, 2) }
    /// Relation of nation n with nation j (+0xB + j; 100 with itself).
    public func relation(_ n: Int, _ j: Int) -> Int { nationByte(n, 0x0B + j) }

    /// Royal aid, every month for every nation (0x183DA): standing 130 or more earns a share
    /// of `rank × income`; below 70 whatever was pending is withdrawn.
    public mutating func monthlyRoyalAid() {
        for n in 0..<6 {
            if standing[n] >= 130 {
                let a = Palace.aid(x: rank * nationIncome(n))
                setNationByte(n, 5, min(100, nationByte(n, 5) + a.gold))
                setNationByte(n, 6, min(100, nationByte(n, 6) + a.other))
                setNationByte(n, 7, a.shipClass)
                setNationByte(n, 8, min(255, nationByte(n, 8) + a.ships))
            } else if standing[n] < 70 {
                setNationByte(n, 5, 0)
                setNationByte(n, 6, 0)
                setNationByte(n, 8, 0)
                setNationByte(n, 7, 0xFF)
            }
        }
    }

    // MARK: entering

    /// The ruler's greeting: by family name and title, or the commoner's special admission.
    public func palaceGreeting() -> [TownLine] {
        let family = memory.string(heroPerson + 0x0D, max: 13)
        return rank > 0 ? [.msg(444, family, Town.title(rank: rank, hero: heroID))] : [.msg(576)]
    }

    /// Which items of menu 16 are enabled (mask [0xA9BA]). Defection is for foreign palaces
    /// with no commission under way and no summons; aid only from your own king.
    public var palaceMenu: PalaceMenu {
        let n = portNation, p = nationality
        let chapter = memory[TownDS.sharedChapter]
        let commission = chapter != 0 && chapter != 0xFF && sharedVar(6) >= 6
        let summoned = memory[TownDS.sharedFlags + 2] & 6 != 0
        return PalaceMenu(defect: n != p && !commission && !summoned, aid: n == p)
    }

    /// Rank 9 with the story option bit 2 ends the game (0x17032, code 15) after any palace action.
    public var palaceEnding: Int? { rank == 9 && memory[TownDS.storyBits] & 2 != 0 ? 15 : nil }

    // MARK: audience (0x29EDD)

    /// First step of 알현: a summoned hero at a palace of his own nation has the commission
    /// chosen by SNR0 (v30) loaded as the SNR0 chapter. Returns true when the caller must then
    /// run SNR0 (port, 5); the audience continues with the hero script and SNR0 (port, 0x15),
    /// and only if neither left does the submenu (세력상황, 사략허가서, 면세증) open.
    public mutating func beginAudience() -> Bool {
        loadScriptGoodsNames()
        guard portNation == nationality, sharedFlag(17) else { return false }
        memory[TownDS.sharedChapter] = sharedVar(30) & 0xFF
        memory[TownDS.sharedBlock] = 0
        return true
    }

    /// Ports owned by nation n (msg 883) and what each region pays it (msgs 455–457), for 세력상황.
    public func powerReport(of n: Int) -> [TownLine] {
        let family = memory.string(heroPerson + 0x0D, max: 13)
        let h = holdings(of: n)
        var lines: [TownLine] = [.msg(453, family), .msg(883, markets.indices.filter { $0 < 100 && markets[$0].nation == n }.count)]
        for r in 0..<8 {
            let name = Town.regions[r]
            if h.ports[r] == 0 {
                lines.append(.text(name + "에는 우리나라 항구가 없다."))
            } else if !Invest.regionPays(r, industry: h.industry) {
                lines.append(.text(name + " 방면 항로는 끊겨 있다."))
            } else {
                lines.append(.joined([.text(name), .msg(457, h.economy[r] / Invest.regionDivisor[r])]))
            }
        }
        return lines + [.msg(454)]
    }

    private var freeItemSlot: Bool { items.count < Town.maxItems }

    /// 사략허가서 (0x29C3A), own nation only: needs 1000 pirate fame, and pirate fame must be
    /// the highest of the three. Returns the refusal, or the question (866) to put.
    public func privateerOffer() -> TownAsk {
        let n = portNation
        guard n < 6, n == nationality else { return .refused([]) }
        if items.contains(Palace.privateerLicence(n)) { return .refused([.msg(864)]) }
        if !freeItemSlot { return .refused([.msg(865)]) }
        return .yesNo([.msg(866)])
    }

    public mutating func requestPrivateerLicence() -> [TownLine] {
        guard case .yesNo = privateerOffer() else { return [] }
        if fame[1] < 1000 { return [.msg(867)] }
        if fame[1] < fame[0] || fame[1] < fame[2] { return [.msg(868)] }
        items.append(Palace.privateerLicence(portNation))
        return [.msg(869), .msg(870, memory.string(heroPerson + 0x0D, max: 13)), .msg(871)]
    }

    /// 면세증 (0x29D46), at any palace you are let into: half a year's exemption from the 20 %
    /// purchase surcharge in that nation's markets. Certificates lapse in the March/September
    /// routine, so one bought late in a half-year comes with a warning (874).
    public func certificateOffer() -> TownAsk {
        let n = portNation
        guard n < 6 else { return .refused([]) }
        if items.contains(Palace.taxCertificate(n)) { return .refused([.msg(872)]) }
        if !freeItemSlot { return .refused([.msg(865)]) }
        return .yesNo([.msg(873)] + (month % 6 < 3 ? [.msg(874)] : []) + [.msg(875)])
    }

    public var certificatePrice: Int {
        Palace.certificatePrice(rank: rank, ownNation: portNation == nationality)
    }

    /// After a yes to 875: the king's words, and the price to agree to (0 = free).
    public func certificateTerms() -> (lines: [TownLine], price: Int) {
        let price = certificatePrice
        let family = memory.string(heroPerson + 0x0D, max: 13)
        return ([.msg(869), .msg(876, family)] + (price > 0 ? [.msg(877, price / 10000)] : []), price)
    }

    public mutating func buyCertificate() -> [TownLine] {
        guard case .yesNo = certificateOffer() else { return [] }
        let price = certificatePrice
        guard pay(price) else { return [.msg(878)] }
        items.append(Palace.taxCertificate(portNation))
        return [.msg(871)]
    }

    // MARK: defection (0x29FB0)

    public func defectionQuestion() -> [TownLine] {
        [.msg(458, memory.string(heroPerson + 0x0D, max: 13))]
    }

    /// Swears allegiance to this palace's nation. The new king stops hunting you and drops
    /// any aid pending; the old nation loses 30 standing, the new one gains 10 (at least 100).
    /// The fleet's home port becomes this port. Rank is kept.
    public mutating func defect() -> [TownLine] {
        let n = portNation, old = nationality
        guard palaceMenu.defect else { return [] }
        nationality = n
        homePort = townPort
        if warTarget(of: n) == 7 { setNationByte(n, 2, 6) }
        for off in [5, 6, 7] { setNationByte(n, off, 0) }
        if standing(with: old) >= 30 { setStanding(old, standing(with: old) - 30) }
        setStanding(n, max(100, min(200, standing(with: n) + 10)))
        return [.msg(460)]
    }

    // MARK: aid (0x2A0CD, 0x2A155)

    public mutating func receiveGoldAid() -> [TownLine] {
        let n = portNation
        guard n == nationality, n < 6 else { return [] }
        let a = pendingGoldAid(n)
        if a == 0 { return [.msg(461)] }
        if gold + 1000 * a > Trade.goldCap { return [.msg(530)] }
        gold += 1000 * a
        setNationByte(n, 5, 0)
        return [.msg(462, a), .msg(463)]
    }

    /// Ship aid: refused when nothing is pending (461), the fleet is full (531), no officer is
    /// free to captain it (532), or a ship ordered here still waits at the yard (461).
    /// Otherwise the answer names the class (464) and asks for the ship's name (555).
    public func shipAidOffer(in world: World) -> TownAsk {
        let n = portNation
        guard n == nationality, n < 6 else { return .refused([]) }
        let pending = pendingShipAid(n)
        if pending.count == 0 || pending.shipClass > 7 { return .refused([.msg(461)]) }
        if ships.count + orders.count >= Shipyard.maxShips { return .refused([.msg(531)]) }
        if spareCaptains - orders.count <= 0 { return .refused([.msg(532)]) }
        if orders.contains(where: { $0.port == townPort }) { return .refused([.msg(461)]) }
        return .yesNo([.msg(464, world.navigation.classes[pending.shipClass].name), .msg(555)])
    }

    /// The aid ship is ordered as a yard order (0x31C64: hull 9/10 of the class) and waits
    /// at this port's shipyard.
    public mutating func receiveShipAid(named name: String, in world: World) -> [TownLine] {
        guard case .yesNo = shipAidOffer(in: world) else { return [] }
        let n = portNation
        let c = pendingShipAid(n).shipClass
        var s = Ship.built(class: c, named: name.isEmpty ? world.navigation.classes[c].name : name, in: world.navigation)
        s.morale = 100
        orders.append(ShipOrder(port: townPort, ship: s, daysLeft: 0))
        setNationByte(n, 8, nationByte(n, 8) - 1)
        return [.msg(552), .msg(463)]
    }
}
