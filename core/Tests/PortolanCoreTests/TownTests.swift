import XCTest
@testable import PortolanCore

final class TownTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    /// Plays one event of the given contexts, answering every question with `choice`.
    @discardableResult
    func play(_ v: inout Voyage, _ key1: Int, _ key2: Int, contexts: [ScriptContext], choice: Int = 1) -> ScriptSession {
        var s = ScriptSession(key1: key1, key2: key2, port: key1, contexts: contexts)
        s.advance(&v, in: world)
        var n = 0
        while let p = s.prompt, n < 300 {
            switch p {
            case .menu, .yesNo: s.answer(choice, &v, in: world)
            default: s.answer(0, &v, in: world)
            }
            n += 1
        }
        return s
    }

    func message(_ l: TownLine?) -> Int? {
        if case .message(let n, _)? = l { return n }
        return nil
    }

    // MARK: opening hours, entry, arrests

    func testTownArrest() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.gold = 10000
        v.standing[0] = 30
        var r = v.rng
        let arrested = r(3) == 0 && r(100) > 50
        let lines = v.enterBuilding(ScriptKey.market)
        XCTAssertEqual(lines.admitted, !arrested)
        if !arrested {
            XCTAssertEqual(message(lines.lines.first), 838)
        }
        // Forcing the arrest: no swordplay escapes only on a roll of 0.
        v.captain.swordplay = 0
        v.gold = 10000
        let escape = Town.escapes(swordplay: 0, battleLevel: 1, roll: { var q = v.rng; return q(150) }())
        let out = v.townArrest(0)
        XCTAssertEqual(message(out.first), 839)
        if !escape {
            XCTAssertEqual(v.gold, 2500)                           // 10000 − 3·10000/4
            XCTAssertEqual(v.standing[0], 50)                      // +20
            XCTAssertEqual(message(out.last), 845)
        }
        XCTAssertTrue(Town.escapes(swordplay: 80, battleLevel: 10, roll: 88))   // 80 + 10·80/100 = 88
        XCTAssertFalse(Town.escapes(swordplay: 80, battleLevel: 10, roll: 89))
    }

    func testHarbourAndChurchAreSafeAndChurchesRefuseInfidels() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.standing[0] = 0
        XCTAssertTrue(v.enterBuilding(ScriptKey.harbor).admitted)
        XCTAssertTrue(v.enterBuilding(ScriptKey.church).admitted)
        XCTAssertEqual(v.memory[TownDS.prayerReady], 1)
        v.marketIndex = 2                                           // Istanbul: a mosque
        let r = v.enterBuilding(ScriptKey.church)
        XCTAssertFalse(r.admitted)
        XCTAssertEqual(message(r.lines.first), 802)
        v.nationality = 2
        XCTAssertTrue(v.enterBuilding(ScriptKey.church).admitted)
        v.marketIndex = 0
        XCTAssertEqual(message(v.enterBuilding(ScriptKey.church).lines.first), 90)
    }

    func testPalaceDoor() {
        var v = Voyage.joanAfterPrologue(in: world)
        // A commoner is turned away from her own king (84) unless summoned.
        XCTAssertEqual(v.enterBuilding(ScriptKey.palace), TownEntry(admitted: false, lines: [.msg(84)]))
        v.setSharedFlag(17, true)
        XCTAssertTrue(v.enterBuilding(ScriptKey.palace).admitted)
        v.setSharedFlag(17, false)
        v.rank = 1
        XCTAssertTrue(v.enterBuilding(ScriptKey.palace).admitted)
        XCTAssertEqual(v.palaceGreeting(), [.msg(444, "페레로", "기사")])
        // A nationless hero may walk into any palace.
        v.rank = 0
        v.nationality = 6
        XCTAssertTrue(v.enterBuilding(ScriptKey.palace).admitted)
        XCTAssertEqual(v.palaceGreeting(), [.msg(576)])
    }

    func testPalaceArrestSeizesFourFifths() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.rank = 3
        v.standing[0] = 0
        v.captain.swordplay = 0
        v.gold = 10001
        v.bankBalance = -12100
        var r = v.rng
        _ = r(100)
        let escaped = r(150) == 0
        let e = v.enterBuilding(ScriptKey.palace)
        XCTAssertFalse(e.admitted)
        XCTAssertEqual(message(e.lines.first), 443)
        if !escaped {
            XCTAssertEqual(v.gold, 2001)                            // 10001 − 8000
            XCTAssertEqual(v.bankBalance, -2420)                    // −12100 − trunc(−9680)
            XCTAssertEqual(v.standing[0], 100)
        }
    }

    // MARK: bank

    func testInterest() {
        XCTAssertEqual(Bank.interest(on: 10000), 10300)
        XCTAssertEqual(Bank.interest(on: 33), 33)
        XCTAssertEqual(Bank.interest(on: -1000), -1100)
        XCTAssertEqual(Bank.interest(on: -15), -16)                 // −150/100 truncates to −1
        XCTAssertEqual(Bank.interest(on: 999_999), 1_000_000)
        XCTAssertEqual(Bank.interest(on: -950_000), -1_000_000)
    }

    func testBalanceIsStoredAsFlooredHundreds() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.bankBalance = 12345
        XCTAssertEqual(v.memory.word(0x123E), 123)
        XCTAssertEqual(v.memory[0x1240], 45)
        v.bankBalance = -150
        XCTAssertEqual(v.memory.word(0x123E), 0xFFFE)               // −2 hundreds
        XCTAssertEqual(v.memory[0x1240], 50)
        XCTAssertEqual(v.bankBalance, -150)
        v.bankBalance = -2_000_000
        XCTAssertEqual(v.bankBalance, -1_000_000)
    }

    func testDepositAndWithdraw() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.gold = 1000
        XCTAssertEqual(v.depositOffer(), .refused([.msg(100)]))
        v.gold = 5000
        XCTAssertEqual(v.depositOffer(), .amount([.msg(104), .msg(105, 5000)], max: 5000))
        XCTAssertEqual(v.deposit(3000), [.msg(106, 3000), .msg(103, 3000)])
        XCTAssertEqual(v.gold, 2000)
        v.monthlyBank()
        XCTAssertEqual(v.bankBalance, 3090)
        XCTAssertEqual(v.withdrawOffer(), .amount([.msg(103, 3090), .msg(108, 3090)], max: 3090))
        _ = v.withdraw(90)
        XCTAssertEqual(v.gold, 2090)
        XCTAssertEqual(v.bankBalance, 3000)
        XCTAssertEqual(v.borrowOffer(), .refused([.msg(111)]))
        v.bankBalance = 999_500
        v.gold = 2000
        XCTAssertEqual(v.depositOffer(), .amount([.msg(103, 999_500), .msg(105, 500)], max: 500))
        v.gold = Trade.goldCap - 50
        XCTAssertEqual(v.withdrawOffer(), .refused([.msg(107)]))
    }

    func testLoansFollowRank() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.gold = 0
        XCTAssertEqual(Bank.loanLimit(rank: 0, balance: 0), 1000)
        XCTAssertEqual(Bank.loanLimit(rank: 2, balance: 0), 41000)
        XCTAssertTrue(Bank.creditExhausted(rank: 0, balance: -901))   // −10 hundreds
        XCTAssertFalse(Bank.creditExhausted(rank: 0, balance: -900))
        v.rank = 1
        XCTAssertEqual(v.borrowOffer(), .amount([.msg(114, 11000), .msg(115, 11000)], max: 11000))
        XCTAssertEqual(v.borrow(11000), [.msg(116, 11000), .msg(117)])
        XCTAssertEqual(v.gold, 11000)
        XCTAssertEqual(v.bankBalance, -11000)
        XCTAssertEqual(v.borrowOffer(), .refused([.msg(113)]))     // −110 ≤ −100 − 10
        XCTAssertEqual(v.depositOffer(), .refused([.msg(102)]))
        v.monthlyBank()
        XCTAssertEqual(v.bankBalance, -12100)
        v.gold = 5000
        XCTAssertEqual(v.repayOffer(), .amount([.msg(149, 12100), .msg(119, 5000)], max: 5000))
        XCTAssertEqual(v.repay(5000), [.msg(120), .msg(117)])
        XCTAssertEqual(v.bankBalance, -7100)
        XCTAssertEqual(v.gold, 0)
        // A rich borrower hears he needs no loan, and may borrow anyway.
        v.bankBalance = 0
        v.gold = 1_000_000
        XCTAssertEqual(v.borrowOffer(), .amount([.msg(112), .msg(114, 11000), .msg(115, 11000)], max: 11000))
    }

    // MARK: investment

    func testSupportGain() {
        var s = [40, 20, 10, 0, 30, 0]
        Invest.gainSupport(&s, amount: 10000, base: 500, nation: 0)    // g = 20, shares 6, remainder 2
        XCTAssertEqual(s, [60, 13, 3, 0, 24, 0])
        s = [50, 50, 0, 0, 0, 0]
        Invest.gainSupport(&s, amount: 3000, base: 1000, nation: 6)    // nationless: others lose 3
        XCTAssertEqual(s, [48, 49, 0, 0, 0, 0])
        s = [90, 2, 1, 0, 0, 7]
        Invest.gainSupport(&s, amount: 50000, base: 1000, nation: 0)   // g = 10, shortfalls go round
        XCTAssertEqual(s, [100, 0, 0, 0, 0, 0])
        XCTAssertEqual(Invest.owner(support: [74, 75, 80, 0, 0, 0]), 2)
        XCTAssertEqual(Invest.owner(support: [74, 0, 0, 0, 0, 0]), 6)
    }

    func testInvestmentTakesAPort() {
        var v = Voyage.joanAfterPrologue(in: world)
        XCTAssertEqual(v.investOffer(.economy), .refused([.msg(2)]))   // Lisbon is a capital
        v.marketIndex = 6
        v.markets[6].economy = 500
        v.markets[6].industry = 300
        v.markets[6].support = [70, 10, 10, 0, 10, 0]
        v.markets[6].nation = 1
        v.gold = 60000
        XCTAssertEqual(v.investOffer(.economy), .amount([.msg(8)], max: 50000))
        XCTAssertEqual(v.invest(3000, in: .economy), [.msg(15)])
        XCTAssertEqual(v.markets[6].support, [76, 8, 8, 0, 8, 0])         // 3000 / 500 = 6
        XCTAssertEqual(v.markets[6].nation, 0)
        XCTAssertEqual(v.standing[1], 95)                                  // lost the port through you
        XCTAssertEqual(v.standing[0], 105)
        XCTAssertEqual(v.fame[0], 800)                                     // economy + industry
        XCTAssertEqual(v.gold, 57000)
        XCTAssertEqual(v.investment(.economy, port: 6), 3000)
        XCTAssertEqual(v.investOffer(.economy), .amount([.msg(8)], max: 47000))
        XCTAssertEqual(v.invest(400, in: .industry), [.msg(14)])
        XCTAssertEqual(v.invest(0, in: .industry), [.msg(13)])
        v.monthlyMarkets()
        XCTAssertEqual(v.markets[6].economy, 510)                          // + 3000 / 300
        XCTAssertEqual(v.markets[6].industry, 301)
        XCTAssertEqual(v.investment(.economy, port: 6), 0)
        v.setInvestment(.economy, port: 6, 50000)
        XCTAssertEqual(v.investOffer(.economy), .refused([.msg(7)]))
    }

    func testRegionsThatPay() {
        let ind = [0, 300, 299, 300, 300, 300, 0, 300]
        XCTAssertEqual((0..<8).map { Invest.regionPays($0, industry: ind) },
                       [true, true, false, true, true, true, false, false])     // the eastern chain breaks at 6
        XCTAssertFalse(Invest.regionPays(3, industry: [0, 0, 0, 300, 0, 0, 0, 0]))
    }

    // MARK: palace

    func testRoyalAid() {
        XCTAssertEqual(Palace.aid(x: 24000).gold, 8)
        XCTAssertEqual(Palace.aid(x: 24000).shipClass, 6)
        XCTAssertEqual(Palace.aid(x: 40000).ships, 10)
        var v = Voyage.joanAfterPrologue(in: world)
        v.rank = 2
        v.standing[0] = 130
        v.memory.setWord(TownDS.nation(0), 12000)
        v.monthlyRoyalAid()
        XCTAssertEqual(v.pendingGoldAid(0), 8)                    // 24000 / 3000
        XCTAssertEqual(v.pendingShipAid(0).shipClass, 6)
        XCTAssertEqual(v.pendingShipAid(0).count, 6)
        v.gold = 0
        XCTAssertEqual(v.receiveGoldAid(), [.msg(462, 8), .msg(463)])
        XCTAssertEqual(v.gold, 8000)
        XCTAssertEqual(v.receiveGoldAid(), [.msg(461)])
        // Ship aid needs a free captain; then the ship waits at the yard.
        XCTAssertEqual(v.shipAidOffer(in: world), .refused([.msg(532)]))
        v.hireOfficer(85, salary: 10, in: world)
        guard case .yesNo = v.shipAidOffer(in: world) else { return XCTFail() }
        _ = v.receiveShipAid(named: "원조", in: world)
        XCTAssertEqual(v.orders.last?.ship.classIndex, 6)
        XCTAssertEqual(v.orders.last?.port, 0)
        XCTAssertEqual(v.pendingShipAid(0).count, 5)
        XCTAssertEqual(v.shipAidOffer(in: world), .refused([.msg(532)]))  // the officer is spoken for
        v.standing[0] = 60
        v.monthlyRoyalAid()
        XCTAssertEqual(v.pendingShipAid(0).count, 0)
        XCTAssertEqual(v.pendingShipAid(0).shipClass, 0xFF)
    }

    func testCertificates() {
        XCTAssertEqual(Palace.certificatePrice(rank: 0, ownNation: true), 70000)
        XCTAssertEqual(Palace.certificatePrice(rank: 6, ownNation: true), 0)
        XCTAssertEqual(Palace.certificatePrice(rank: 3, ownNation: false), 80000)
        var v = Voyage.joanAfterPrologue(in: world)
        v.month = 4                                               // 4 % 6 ≥ 3: no warning
        XCTAssertEqual(v.certificateOffer(), .yesNo([.msg(873), .msg(875)]))
        v.month = 1
        XCTAssertEqual(v.certificateOffer(), .yesNo([.msg(873), .msg(874), .msg(875)]))
        v.gold = 69999
        XCTAssertEqual(v.buyCertificate(), [.msg(878)])
        v.gold = 70000
        XCTAssertEqual(v.buyCertificate(), [.msg(871)])
        XCTAssertTrue(v.licensed(in: world))                      // the trading post's licence check
        XCTAssertEqual(v.certificateOffer(), .refused([.msg(872)]))
    }

    func testPrivateerLicence() {
        var v = Voyage.joanAfterPrologue(in: world)
        XCTAssertEqual(v.privateerOffer(), .yesNo([.msg(866)]))
        v.fame = [0, 500, 0]
        XCTAssertEqual(v.requestPrivateerLicence(), [.msg(867)])
        v.fame = [3000, 2000, 0]
        XCTAssertEqual(v.requestPrivateerLicence(), [.msg(868)])
        v.fame = [1000, 2000, 0]
        XCTAssertEqual(message(v.requestPrivateerLicence().last), 871)
        XCTAssertTrue(v.items.contains(0x1D))
        XCTAssertEqual(v.privateerOffer(), .refused([.msg(864)]))
        v.marketIndex = 1                                          // Seville: not her king's
        XCTAssertEqual(v.privateerOffer(), .refused([]))
    }

    func testDefection() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.marketIndex = 1
        v.rank = 2
        v.memory[TownDS.nation(1) + 2] = 7                        // Spain was hunting her
        v.memory[TownDS.nation(1) + 5] = 9
        XCTAssertTrue(v.palaceMenu.defect)
        XCTAssertFalse(v.palaceMenu.aid)
        XCTAssertEqual(v.defect(), [.msg(460)])
        XCTAssertEqual(v.nationality, 1)
        XCTAssertEqual(v.memory[DS.person(0) + 0x31] & 0xF, 1)
        XCTAssertEqual(v.homePort, 1)
        XCTAssertEqual(v.standing[0], 70)
        XCTAssertEqual(v.standing[1], 110)
        XCTAssertEqual(v.warTarget(of: 1), 6)
        XCTAssertEqual(v.pendingGoldAid(1), 0)
        XCTAssertEqual(v.rank, 2)
        XCTAssertFalse(v.palaceMenu.defect)
        XCTAssertTrue(v.palaceMenu.aid)
    }

    func testPowerReport() {
        let v = Voyage.joanAfterPrologue(in: world)
        let r = v.powerReport(of: 0)
        XCTAssertEqual(message(r.first), 453)
        XCTAssertEqual(r[1], .msg(883, v.markets.filter { $0.nation == 0 }.count))
        XCTAssertEqual(r.count, 2 + 8 + 1)
    }

    /// The promotion path end to end: fame makes F16, the tavern rumour summons (F17), the
    /// audience at the home capital opens SNR0 commission 6, and delivering the goods it asks
    /// for raises the rank.
    func testRoyalCommissionPromotes() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.storyOn = false
        v.fame = [600, 0, 0]
        v.ships[0].cargoCapacity = 1000
        play(&v, 0, ScriptKey.tavern, contexts: [.shared])           // SNR0 0.0 "any": promotion due
        XCTAssertTrue(v.sharedFlag(16))
        let talk = v.tavernTreatTalk()
        XCTAssertEqual(talk.first, .msg(36))
        XCTAssertEqual(talk.last, .joined([.msg(409), .msg(410), .msg(416)]))
        XCTAssertTrue(v.sharedFlag(17))
        XCTAssertEqual(v.guildDesk(), .summoned([.msg(410), .msg(932)]))

        play(&v, 0, ScriptKey.palace, contexts: [.shared])           // gate: v6 = v30, ports
        XCTAssertTrue(v.enterBuilding(ScriptKey.palace).admitted)    // rank 0, but summoned
        v.setSharedVar(30, 6)                                         // the trade commission
        XCTAssertTrue(v.beginAudience())
        XCTAssertEqual(v.sharedChapter, 6)
        let gate = play(&v, 0, ScriptKey.palace, contexts: [.shared])
        XCTAssertTrue(gate.leave)
        XCTAssertTrue(v.sharedFlag(18))
        XCTAssertFalse(v.sharedFlag(17))
        let task = play(&v, 0, ScriptKey.audience, contexts: [.shared]) // states the task: yes
        XCTAssertTrue(task.leave)
        XCTAssertEqual(v.memory[TownDS.sharedBlock], 2)
        XCTAssertEqual(v.guildDesk(), .busy([.msg(595)]))
        XCTAssertFalse(v.palaceMenu.defect)

        let good = v.sharedVar(18), qty = v.sharedVar(19)
        XCTAssertTrue((32..<38).contains(good))
        XCTAssertGreaterThan(qty, 0)
        v.ships[0].holds = [CargoLot(good: good, amount: qty)]
        XCTAssertFalse(v.beginAudience())                             // F17 is spent
        play(&v, 0, ScriptKey.audience, contexts: [.shared])
        XCTAssertEqual(v.rank, 1)
        XCTAssertTrue(v.ships[0].holds.isEmpty)
        XCTAssertEqual(v.sharedChapter, 0)
        XCTAssertFalse(v.sharedFlag(18))
    }

    func testRefusingACommissionHalvesFame() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.storyOn = false
        v.fame = [601, 300, 41]
        play(&v, 0, ScriptKey.tavern, contexts: [.shared])
        v.marketIndex = 1                                            // not her nation's port
        XCTAssertEqual(v.enterBuilding(ScriptKey.harbor).lines, [])
        v.marketIndex = 0
        XCTAssertEqual(v.enterBuilding(ScriptKey.harbor).lines, [.joined([.msg(409), .msg(410), .msg(416)])])
        XCTAssertTrue(v.sharedFlag(17))
        v.setSharedVar(30, 6)
        XCTAssertTrue(v.beginAudience())
        play(&v, 0, ScriptKey.palace, contexts: [.shared])
        play(&v, 0, ScriptKey.audience, contexts: [.shared], choice: 0)
        XCTAssertEqual(v.fame, [300, 150, 20])
        XCTAssertEqual(v.sharedChapter, 0)
        XCTAssertEqual(v.rank, 0)
    }

    // MARK: guild

    func testGuildOffersAndAcceptance() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.storyOn = false
        v.gold = 0
        play(&v, 0, ScriptKey.guild, contexts: [.shared])             // SNR0 0.0 draws today's offers
        guard case .offers(let kinds) = v.guildDesk() else { return XCTFail() }
        XCTAssertEqual(kinds.count, 3)
        XCTAssertTrue(kinds.allSatisfy { (0..<5).contains($0) })
        // A refused briefing leaves the desk open.
        v.pickJob(0)
        XCTAssertEqual(v.memory[TownDS.sharedBlock], kinds[0] + 1)
        play(&v, 0, ScriptKey.guild, contexts: [.shared], choice: 0)
        XCTAssertFalse(v.settleJob())
        XCTAssertEqual(v.memory[TownDS.sharedBlock], 0)
        // Accepting makes the job's chapter current.
        v.pickJob(0)
        play(&v, 0, ScriptKey.guild, contexts: [.shared], choice: 1)
        XCTAssertTrue(v.settleJob())
        XCTAssertEqual(v.sharedChapter, kinds[0] + 1)
        if case .busy = v.guildDesk() {} else { XCTFail() }
    }

    func testFarPortsOnlyCarryLetters() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.storyOn = false
        v.marketIndex = 50
        play(&v, 50, ScriptKey.guild, contexts: [.shared])
        XCTAssertEqual(v.guildDesk(), .offers([2, 2, 2]))
    }

    func testNews() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.gold = 99
        XCTAssertEqual(v.buyNews(of: 1), [.msg(163)])
        v.gold = 100
        let lines = v.buyNews(of: 1)
        XCTAssertEqual(v.gold, 0)
        XCTAssertEqual(lines.first, .joined([.msg(1081, v.nationIncome(1)), .text("0")]))
        XCTAssertTrue(lines.contains(.msg(88, "에스파니아", "해적")))      // Spain's new-game target is 6
    }

    // MARK: items, church, fortune

    func testItemShop() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.tick = 30
        XCTAssertEqual(v.shopStock, [20, 24, 3])                       // 리스본
        v.marketIndex = 1
        v.tick = 7
        XCTAssertEqual(v.shopStock, [24, 6, 3, 13])                    // 세빌리아 at night
        let rapier = v.item(3)
        XCTAssertEqual(rapier.name, "레이피어")
        XCTAssertEqual(rapier.price, 3000)
        XCTAssertEqual(rapier.slot, 0)
        XCTAssertEqual(v.resalePrice(3), 1500)
        XCTAssertEqual(v.resalePrice(29), 0)                           // licences are not bought
        v.gold = 0
        XCTAssertEqual(v.buyItemOffer(3), .refused([.msg(236)]))
        v.gold = 2999
        XCTAssertEqual(v.buyItemOffer(3), .yesNo([.joined([.msg(240, "레이피어"), .text("3000"), .msg(241)])]))
        XCTAssertEqual(v.buyItem(3), [.msg(239)])
        v.gold = 10000
        _ = v.buyItem(3)
        XCTAssertEqual(v.gold, 7000)
        XCTAssertEqual(v.buyItemOffer(3), .refused([.msg(332)]))
        _ = v.buyItem(1)
        _ = v.toggleEquip(3)
        XCTAssertTrue(v.item(3).equipped)
        _ = v.toggleEquip(1)                                           // same slot: the rapier comes off
        XCTAssertTrue(v.item(1).equipped)
        XCTAssertFalse(v.item(3).equipped)
        XCTAssertEqual(v.sellItemOffer(1), .refused([.msg(333)]))
        XCTAssertEqual(v.toggleEquip(24), [.msg(1090)])
        XCTAssertEqual(v.sellItem(3, price: 1500), [.msg(242)])
        XCTAssertEqual(v.gold, 7000 - 1000 + 1500)
        XCTAssertFalse(v.items.contains(3))
        v.items = Array(repeating: 41, count: 20)
        XCTAssertEqual(v.buyItemOffer(3), .refused([.msg(237)]))
    }

    func testItemHaggle() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.captain.luck = 100
        v.captain.charm = 90
        XCTAssertEqual(v.haggleItem(price: 1500)?.price, 2175)         // 1500 + 1500·90/200
    }

    func testChurch() {
        var v = Voyage.joanAfterPrologue(in: world)
        XCTAssertTrue(v.enterBuilding(ScriptKey.church).admitted)
        v.captain.luck = 50
        var r = v.rng
        let gain = r(2)
        XCTAssertEqual(v.pray(), [.msg(92)])
        XCTAssertEqual(v.captain.luck, 50 + gain)
        _ = v.pray()                                                    // once a visit
        XCTAssertEqual(v.captain.luck, 50 + gain)
        v.captain.luck = 50
        v.gold = 1000
        XCTAssertEqual(v.donate(50), [.msg(94)])                        // 1000 / 50 = 20 > 10
        XCTAssertEqual(v.gold, 950)
        XCTAssertEqual(v.captain.luck, 50)
        v.gold = 1000
        r = v.rng
        let lucky = (r(5) + 1) * 100 <= 500
        XCTAssertEqual(v.donate(500), [.msg(95)])
        XCTAssertEqual(v.captain.luck, lucky ? 59 : 50)                 // 11 − 1000/500
        v.marketIndex = 2
        XCTAssertEqual(v.churchGreeting(), .msg(803))
    }

    func testFortunes() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.gold = 1000
        v.captain.luck = 50
        XCTAssertEqual(v.fortunes, [.life, .business, .love])
        XCTAssertEqual(v.readFortune(.life), [.msg(301), .msg(304)])    // 302 + 50/25
        XCTAssertEqual(v.gold, 950)
        v.fame = [100, 0, 0]
        v.captain.navExp = 10
        XCTAssertEqual(v.readFortune(.business),
                       [.msg(301), .msg(545, 20), .msg(546, 30 - v.captain.battleExp), .msg(547, 400)])
        v.rank = 8
        XCTAssertEqual(v.fortuneFameTarget, 40000)
        v.rank = 9
        XCTAssertEqual(v.fortuneFameTarget, 54346)                       // past the table
        XCTAssertEqual(v.readFortune(.love).last, .msg(328))           // 루치아 (flag 8), affection 0
        v.marketIndex = 6
        XCTAssertEqual(v.readFortune(.love).last, .msg(329))
        v.gold = 49
        XCTAssertEqual(v.readFortune(.life), [.msg(300)])
        v.gold = 100
        v.hireOfficer(85, salary: 10, in: world)
        let o = v.officers[0]
        XCTAssertEqual(v.readFortune(.companion, companion: 0),
                       [.msg(301), .msg(78 + o.stats[7] / 25), .msg(793 + o.loyalty / 25)])
    }

    func testRendering() {
        let msgs = ["%s(는) 은화 ", "소문난 %s(이렸다)!", "월 %ld닢 3%%", "\u{1B}C1힘\u{1B}C2%s", "(으로부터의) 몫은 \n%u(이지)."]
        XCTAssertEqual(TownLine.joined([.msg(0, "레이피어"), .text("3000")]).rendered(msgs), "레이피어는 은화 3000")
        XCTAssertEqual(TownLine.msg(1, "페레로").rendered(msgs), "소문난 페레로렸다!")
        XCTAssertEqual(TownLine.msg(1, "조안").rendered(msgs), "소문난 조안이렸다!")
        XCTAssertEqual(TownLine.msg(2, 5000).rendered(msgs), "월 5000닢 3%")
        XCTAssertEqual(TownLine.msg(3, "15").rendered(msgs), "힘15")
        XCTAssertEqual(TownLine.joined([.text("유럽"), .msg(4, 1203)]).rendered(msgs), "유럽으로부터의 몫은 \n1203이지.")
        XCTAssertEqual(TownLine.joined([.text("신대륙"), .msg(4, 12)]).rendered(msgs), "신대륙으로부터의 몫은 \n12지.")
    }

    // MARK: the month

    func testMonthlyTownRuns() {
        var v = Voyage.joanAfterPrologue(in: world)
        v.bankBalance = 1000
        v.setInvestment(.industry, port: 6, 600)
        let industry = v.markets[6].industry
        v.monthlyTown()
        XCTAssertEqual(v.bankBalance, 1030)
        XCTAssertEqual(v.markets[6].industry, industry + 2)
    }
}
