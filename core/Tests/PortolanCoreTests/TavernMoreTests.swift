import XCTest
@testable import PortolanCore

final class TavernMoreTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var world: World!

    override func setUpWithError() throws {
        world = try World(assets: WorldTests.assets)
    }

    private func lisbon() -> Voyage { Voyage.joanAfterPrologue(in: world) }

    private func tavern(_ v: Voyage) -> Tavern {
        Tavern(market: v.market(in: world), drinks: world.navigation.drinks, charm: v.captain.charm)
    }

    // MARK: 선원고용 / 선원해고

    func testSailorsAreHiredOnceADay() {
        var v = lisbon()
        let t = tavern(v)
        XCTAssertFalse(v.hiredToday)
        XCTAssertTrue(v.hireCrew(5, at: t))
        XCTAssertEqual(v.ships[0].crew, 5)
        XCTAssertEqual(v.ships[0].morale, 60)                          // (5·60 + 100·0) / 5
        XCTAssertTrue(v.hiredToday)
        XCTAssertEqual(v.memory[0xC3C] & 1, 1)
        let gold = v.gold
        XCTAssertFalse(v.hireCrew(5, at: t))                           // greyed until tomorrow
        XCTAssertEqual(v.gold, gold)
        XCTAssertFalse(v.hireCrew(0, at: t))

        v.passTime(ticks: Navigation.ticksPerDay - v.tick)            // the day rolls over (0x190F9)
        XCTAssertFalse(v.hiredToday)
        XCTAssertEqual(v.memory[0xC3C], 0)
        v.ships[0].morale = 100
        XCTAssertTrue(v.hireCrew(5, at: t))
        XCTAssertEqual(v.ships[0].morale, 80)                          // (5·60 + 100·5) / 10
    }

    func testCancelledHiringLeavesTheFlag() {
        var v = lisbon()
        v.gold = 0
        XCTAssertFalse(v.hireCrew(5, at: tavern(v)))
        XCTAssertFalse(v.hiredToday)
    }

    func testDismissingSailors() {
        var v = lisbon()
        v.ships[0].crew = 20
        let gold = v.gold
        XCTAssertEqual(v.dismissPrompt(ship: 0), .msg(857, v.ships[0].name, 20))
        XCTAssertNil(v.dismissConfirm(ship: 0, keep: 20))             // nothing changes
        XCTAssertNil(v.dismissConfirm(ship: 0, keep: 21))
        XCTAssertEqual(v.dismissConfirm(ship: 0, keep: 12), .msg(858, 8))
        XCTAssertTrue(v.dismissCrew(ship: 0, keep: 12))
        XCTAssertEqual(v.ships[0].crew, 12)
        XCTAssertEqual(v.ships[0].morale, 100)                         // no morale change
        XCTAssertEqual(v.gold, gold)                                   // no cost, no refund
        XCTAssertTrue(v.dismissCrew(ship: 0, keep: 0))                 // no minimum
        XCTAssertEqual(v.ships[0].crew, 0)
        XCTAssertEqual(v.ships[0].morale, 0)                           // an empty ship loses its morale
        XCTAssertFalse(v.dismissCrew(ship: 0, keep: 0))
    }

    // MARK: people in port

    func testLisbonNavigatorsStayAtTheInn() {
        var v = lisbon()
        // 85 (+0x2F 0xC0) and 96 (0xE1) lack bit 0x10: both are inn guests.
        XCTAssertEqual(v.patrons(at: .inn), [85, 96])
        XCTAssertEqual(v.patrons(at: .tavern), [])
        XCTAssertEqual(v.nobodyLine(at: .tavern, mood: 29), .msg(39))
        XCTAssertEqual(v.nobodyLine(at: .tavern, mood: 50), .msg(38))
        XCTAssertEqual(v.nobodyLine(at: .inn, mood: 0), .msg(68))      // someone is in port

        XCTAssertEqual(v.greetPatron(85, at: .inn), PatronGreeting(lines: [.msg(72), .msg(75)], menu: true))
        XCTAssertEqual(v.greetPatron(85, at: .tavern), PatronGreeting(lines: [.msg(41), .msg(43)], menu: true))
        v.memory[DS.person(96) + 0x2C] = 63                            // a pirate
        let pirate = v.greetPatron(96, at: .inn)
        XCTAssertFalse(pirate.menu)
        XCTAssertTrue([[TownLine.msg(859)], [.msg(860)]].contains(pirate.lines))
        XCTAssertTrue(v.greetPatron(96, at: .tavern).menu)

        v.hireOfficer(85, salary: 20, in: world)
        let own = v.greetPatron(85, at: .tavern)
        XCTAssertFalse(own.menu)
        XCTAssertTrue((134...136).map { [TownLine.msg($0)] }.contains(own.lines))
        XCTAssertTrue((69...71).map { [TownLine.msg($0)] }.contains(v.greetPatron(85, at: .inn).lines))
    }

    func testTreatingOnePatron() {
        var v = lisbon()
        let gold = v.gold
        // Joan (+0x2F type 0) and Miguel (type 0, bit 0x40): 6 × 3 × 2 = 36.
        guard case .talk(let lines) = v.treatPatron(85, in: world) else { return XCTFail() }
        XCTAssertEqual(v.gold, gold - 3)                               // one rum
        XCTAssertEqual(v.memory[DS.person(85) + 0x2B], 36)
        XCTAssertEqual(lines, [.msg(44), .joined([.msg(46), .msg(139, "통솔력")])])   // 84 > 75, friendship > 30
        // Mendoza: type 1, bit 0x40: 6 × 1 × 2 = 12, and no boast yet.
        XCTAssertEqual(v.treatPatron(96, in: world), .talk([.msg(45)]))
        XCTAssertEqual(v.memory[DS.person(96) + 0x2B], 12)
        // Without bit 0x40 the same kind gains 18.
        v.memory[DS.person(96) + 0x2F] = 0xA0
        XCTAssertEqual(v.treatPatron(96, in: world), .talk([.msg(44)]))
        XCTAssertEqual(v.memory[DS.person(96) + 0x2B], 30)
        // A pirate grumbles and still warms up; friendship stops at 100.
        v.memory[DS.person(85) + 0x2C] = 64
        v.memory[DS.person(85) + 0x2B] = 90
        guard case .talk(let p) = v.treatPatron(85, in: world) else { return XCTFail() }
        XCTAssertEqual(p.first, .msg(861))
        XCTAssertEqual(v.memory[DS.person(85) + 0x2B], 100)
        v.gold = 2
        XCTAssertEqual(v.treatPatron(96, in: world), .short([.msg(76)]))
        XCTAssertEqual(v.gold, 2)
    }

    func testTavernHiringNeedsAFriend() {
        var v = lisbon()
        v.captain.navLevel = 10                                         // passes the experience test
        XCTAssertEqual(v.askToJoin(96, at: .tavern, in: world).lines, [.msg(48), .msg(141)])
        let inn = v.askToJoin(96, at: .inn, in: world)                  // the inn skips the friendship test
        XCTAssertNotNil(inn.salary)
        XCTAssertEqual(inn.lines.first, .msg(48))
        v.memory[DS.person(96) + 0x2B] = 31
        XCTAssertNotNil(v.askToJoin(96, at: .tavern, in: world).salary)
        v.memory[DS.person(96) + 0x2E] = 2                              // has a post
        XCTAssertEqual(v.askToJoin(96, at: .tavern, in: world).lines, [.msg(48), .msg(49)])
    }

    func testNavigatorRumour() {
        for seed in 1...30 as ClosedRange<UInt32> {
            var v = lisbon()
            v.rng = GameRandom(seed: seed)
            var r = v.rng
            let t = min(99, 0 + r(8))
            let port = t - min(r(4), t)
            let lines = v.navigatorRumour(in: world)
            if port == 0 {
                XCTAssertEqual(lines, [.msg(47, "럼주")])
            } else if let q = (0..<120).first(where: { v.memory[DS.person($0) + 0x2D] == port && v.memory[DS.person($0) + 0x31] & 0x20 != 0 }) {
                XCTAssertEqual(lines, [.msg(570, v.portName(port), v.memory.string(DS.person(q) + 0x0D, max: 13))])
            } else {
                XCTAssertEqual(lines, [.msg(571, v.portName(port))])
            }
            XCTAssertTrue((0...7).contains(port))
        }
    }

    // MARK: tavern girls

    func testLisbonGirls() {
        let v = lisbon()
        XCTAssertEqual(v.heroineHere, 0)                                // 카를로타 greets at the door
        XCTAssertEqual(v.barmaidHere, 1)                                // 루치아
        XCTAssertEqual(v.barmaid(1).name, "루치아")
        XCTAssertEqual(v.barmaid(1).age, 16)
        XCTAssertEqual(v.barmaid(1).taste, 3)
        XCTAssertEqual(v.barmaid(1).portrait, 0x62)
        XCTAssertEqual(v.tavernGreeting(in: world), [.msg(17, "조안", "럼주")])
        XCTAssertEqual(v.barmaidTopics, [.boast, .gift, .inquiry, .gossip])
        var w = v
        w.memory[Barmaid.record(1) + 0x10] &= ~0x08                     // SNR1 kidnaps her
        XCTAssertNil(w.barmaidHere)
    }

    func testBarmaidFee() {
        var v = lisbon()
        v.gold = 9
        let short = v.callBarmaid(1)
        XCTAssertFalse(short.seated)
        XCTAssertEqual(short.lines, [.msg(146, "루치아"), .msg(147)])
        XCTAssertEqual(v.gold, 9)
        v.gold = 100
        let seated = v.callBarmaid(1)
        XCTAssertTrue(seated.seated)
        XCTAssertEqual(seated.lines, [.msg(146, "루치아")])
        XCTAssertEqual(v.gold, 90)
    }

    func testInquiryNeedsAffection() {
        var v = lisbon()
        let lucia = Barmaid.record(1), teresa = Barmaid.record(4)       // easy-going (0x3F) / not (0x0E)
        v.memory[lucia + 0x0D] = 39
        XCTAssertEqual(v.inquiryDesk(1), .says([.msg(533)]))
        v.memory[lucia + 0x0D] = 40
        XCTAssertEqual(v.inquiryDesk(1), .request)
        v.memory[teresa + 0x0D] = 79
        XCTAssertEqual(v.inquiryDesk(4), .says([.msg(533)]))
        v.memory[teresa + 0x0D] = 80
        XCTAssertEqual(v.inquiryDesk(4), .request)

        let said = v.requestInquiry(1, nation: 0, kind: 0)             // Portuguese merchant fleets
        let days = v.barmaid(1).daysLeft
        XCTAssertTrue((14...16).contains(days))                         // rand(3) + (110 − 40) / 5
        XCTAssertEqual(said, [.msg(536, days)])
        XCTAssertEqual(v.barmaid(1).request, 0x00)
        XCTAssertEqual(v.inquiryDesk(1), .says([.msg(537)]))
        v.passTime(ticks: Navigation.ticksPerDay * days)
        XCTAssertEqual(v.barmaid(1).daysLeft, 0)
        XCTAssertEqual(v.inquiryDesk(1), .report)
        let report = v.inquiryReport(1, in: world)
        XCTAssertEqual(Array(report.prefix(2)), [.msg(538), .joined([.msg(539, "포르투갈"), .msg(540, "상선대")])])
        XCTAssertGreaterThanOrEqual(report.count, 6)                    // fleets 1–4: at least one line each
        XCTAssertEqual(v.barmaid(1).request, 0xFF)
        XCTAssertEqual(v.barmaid(1).daysLeft, 0xFF)

        v.requestInquiry(4, nation: 6, kind: 2)                        // 사략선대: 80 → 6–8 days
        XCTAssertTrue((6...8).contains(v.barmaid(4).daysLeft))
        XCTAssertEqual(Voyage.inquiryKinds(nation: 6)[2], "사략선대")
        v.dropInquiry(4)
        XCTAssertEqual(v.barmaid(4).request, 0xFF)
    }

    func testTasteAgeAndBoasting() {
        var v = lisbon()
        let lucia = Barmaid.record(1), teresa = Barmaid.record(4)
        XCTAssertEqual(v.herTaste(1), [.msg(403)])                       // rand(50) < 0 never
        XCTAssertEqual(v.herAge(1), [.msg(403)])
        v.memory[lucia + 0x0D] = 50
        XCTAssertEqual(v.herTaste(1), [.msg(408)])                       // taste 3, always told from 50
        XCTAssertEqual(v.barmaid(1).affection, 54)                       // +4, no daily limit
        XCTAssertEqual(v.herTaste(1), [.msg(408)])
        XCTAssertEqual(v.barmaid(1).affection, 58)
        v.memory[lucia + 0x0D] = 80
        XCTAssertEqual(v.herAge(1), [.msg(403)])                         // needs more than 80
        v.memory[lucia + 0x0D] = 81
        XCTAssertEqual(v.herAge(1), [.msg(404, 16)])
        v.memory[teresa + 0x0D] = 60
        XCTAssertEqual(v.herTaste(4), [.msg(405)])
        XCTAssertEqual(v.barmaid(4).affection, 62)                       // taste 0: +2

        let site = TownDS.site(2)                                        // value 30, ruins (+6 & 7 = 4)
        v.memory[site + 6] = (v.memory[site + 6] & ~0x80) | 0x20
        XCTAssertEqual(v.boastableSites, [2])
        v.memory[lucia + 0x0D] = 0
        XCTAssertEqual(v.boast(2, to: 1), [.joined([.msg(313), .msg(318)])])
        XCTAssertEqual(v.barmaid(1).affection, 8)                        // (30 / 10 + 1) × 2
        _ = v.boast(2, to: 1)
        XCTAssertEqual(v.barmaid(1).affection, 16)                       // taste 3: no daily limit
        v.passTime(ticks: Navigation.ticksPerDay - v.tick)
        XCTAssertEqual(v.boast(2, to: 4), [.msg(313)])
        XCTAssertEqual(v.barmaid(4).affection, 66)                       // taste 0: +4 ...
        _ = v.boast(2, to: 4)
        XCTAssertEqual(v.barmaid(4).affection, 66)                       // ... once a day (bit 0x40)
        v.passTime(ticks: Navigation.ticksPerDay)
        _ = v.boast(2, to: 4)
        XCTAssertEqual(v.barmaid(4).affection, 70)
    }

    func testGifts() {
        var v = lisbon()
        let lucia = Barmaid.record(1), flora = Barmaid.record(3)
        XCTAssertEqual(v.giftItems, [])
        XCTAssertEqual(v.noGiftLine(1), .msg(330))                       // easy-going
        XCTAssertEqual(v.noGiftLine(4), .msg(331))
        v.items = [60, 25, 57, 60]                                        // 진주 팔찌 (jewel, 10), cat, 비단 리본 (accessory, 2)
        XCTAssertEqual(v.giftItems, [60, 57, 60])
        v.memory[lucia + 0x0D] = 80
        XCTAssertEqual(v.give(60, to: 1), [.joined([.msg(321), .msg(324)]), .msg(325)])   // taste 3 likes anything; a kiss at 80
        XCTAssertEqual(v.barmaid(1).affection, 100)                       // 80 + 20, capped
        XCTAssertEqual(v.items, [25, 57, 60])
        XCTAssertEqual(v.give(57, to: 3), [.msg(321)])                    // 프로라 likes jewels (taste 1)
        XCTAssertEqual(v.barmaid(3).affection, 2)
        XCTAssertEqual(v.give(60, to: 3), [.joined([.msg(321), .msg(323)])])
        XCTAssertEqual(v.memory[flora + 0x0D], 22)
        XCTAssertEqual(v.items, [25])
    }

    func testJobInfo() {
        var v = lisbon()
        XCTAssertFalse(v.jobInfoOffered)
        v.memory[TownDS.sharedChapter] = 5
        XCTAssertFalse(v.jobInfoOffered)                                  // block 0: still greyed
        v.memory[TownDS.sharedBlock] = 1
        XCTAssertTrue(v.jobInfoOffered)
        v.setSharedVar(6, 5)
        XCTAssertEqual(v.jobInfo(1, in: world), .says([.msg(589)]))
        v.setSharedVar(6, 9)
        XCTAssertEqual(v.jobInfo(1, in: world), .says([.msg(586)]))
        v.setSharedVar(6, 4)
        XCTAssertEqual(v.jobInfo(1, in: world), .inquiry)
        v.setSharedVar(6, 11); v.setSharedVar(17, 0xFF); v.setSharedVar(18, 90)
        XCTAssertEqual(v.jobInfo(1, in: world), .says([.msg(588)]))
        v.items = [90]
        XCTAssertEqual(v.jobInfo(1, in: world), .says([.msg(1019, "순금 가면")]))
        XCTAssertEqual(v.barmaid(1).affection, 10)
        _ = v.jobInfo(1, in: world)
        XCTAssertEqual(v.barmaid(1).affection, 10)                        // once a day
        v.setSharedVar(6, 7); v.setSharedVar(17, 0); v.setSharedVar(18, 0)
        XCTAssertEqual(v.jobInfo(1, in: world), .says([.msg(585)]))       // the job is here
    }

    func testNewYearAgesGirlsAndPersons() {
        var v = lisbon()
        v.month = 11
        v.dayOfMonth = Navigation.daysIn(month: 11, year: v.year) - 1
        let age = v.memory[DS.person(85) + 0x2A]
        v.passTime(ticks: Navigation.ticksPerDay - v.tick)
        XCTAssertEqual(v.month, 0)
        XCTAssertEqual(v.barmaid(1).age, 17)
        XCTAssertEqual(v.memory[DS.person(85) + 0x2A], age + 1)
    }

    // MARK: Black Jack

    func testCardValues() {
        XCTAssertEqual(BlackJack.value(0), 1)                             // A
        XCTAssertEqual(BlackJack.value(9), 10)                            // 10
        XCTAssertEqual(BlackJack.value(12), 10)                           // K
        XCTAssertEqual(BlackJack.total([0, 9]), 21)                       // A + 10
        XCTAssertEqual(BlackJack.total([0, 5]), 17)                       // soft 17
        XCTAssertEqual(BlackJack.total([0, 13, 9]), 12)                   // one ace at 11 only while ≤ 11
        XCTAssertEqual(BlackJack.name(13 + 10), "♥J")
        var rng = GameRandom(seed: 7)
        let shoe = BlackJack.shoe(&rng)
        XCTAssertEqual(shoe.count, 24)
        XCTAssertEqual(Set(shoe).count, 24)
    }

    func testBlackJackSettlement() {
        typealias S = BlackJack.Settlement
        // Ties and double busts go to the dealer.
        XCTAssertEqual(BlackJack.settle(player: [9, 8], p: 19, dealer: [22, 21], d: 19), S(0, 0, 974))
        XCTAssertEqual(BlackJack.settle(player: [9, 8, 7], p: 0, dealer: [22, 21, 5], d: 0), S(0, 0, 974))
        // Player wins.
        XCTAssertEqual(BlackJack.settle(player: [9, 8], p: 19, dealer: [22, 20], d: 18), S(2, 0, 968))
        XCTAssertEqual(BlackJack.settle(player: [0, 10], p: 21, dealer: [22, 20], d: 18), S(6, 0, 966))   // A + J of the first suit
        XCTAssertEqual(BlackJack.settle(player: [13, 25], p: 21, dealer: [22, 20], d: 18), S(3, 0, 967))  // A + K
        XCTAssertEqual(BlackJack.settle(player: [0, 22], p: 21, dealer: [22, 20], d: 18), S(2, 0, 968))   // A + 10
        XCTAssertEqual(BlackJack.settle(player: [6, 19, 32], p: 21, dealer: [22, 20], d: 18), S(4, 0, 969)) // 7-7-7
        XCTAssertEqual(BlackJack.settle(player: [5, 6, 7], p: 21, dealer: [22, 20], d: 18), S(4, 0, 970))  // 6-7-8 of a suit
        XCTAssertEqual(BlackJack.settle(player: [11, 12, 13], p: 21, dealer: [22, 20], d: 18), S(4, 0, 970)) // Q-K-A over a suit edge
        XCTAssertEqual(BlackJack.settle(player: [1, 2, 3, 4, 14], p: 20, dealer: [22, 20], d: 18), S(4, 0, 971)) // five cards
        // Dealer specials.
        XCTAssertEqual(BlackJack.settle(player: [9, 8], p: 19, dealer: [10, 0], d: 21), S(0, 4, 972))
        XCTAssertEqual(BlackJack.settle(player: [9, 8], p: 19, dealer: [13, 12], d: 21), S(0, 1, 973))
        XCTAssertEqual(BlackJack.settle(player: [9, 8], p: 19, dealer: [13, 22], d: 21), S(0, 0, 974))
        XCTAssertEqual(BlackJack.settle(player: [9, 8], p: 19, dealer: [19, 6, 32], d: 21), S(0, 2, 975))
        XCTAssertEqual(BlackJack.settle(player: [9, 8], p: 19, dealer: [1, 2, 3, 14, 15], d: 20), S(0, 2, 977))
        XCTAssertEqual(BlackJack.settle(player: [9, 8, 7], p: 0, dealer: [1, 2, 3, 14, 15, 9], d: 0), S(0, 0, 974))

        XCTAssertEqual(BlackJack.pay(gold: 100, bet: 50, S(6, 0, 966)), 400)    // net +5×
        XCTAssertEqual(BlackJack.pay(gold: 300, bet: 50, S(0, 4, 972)), 100)    // 5× in all
        XCTAssertEqual(BlackJack.pay(gold: 100, bet: 50, S(0, 4, 972)), 0)      // never below zero
        XCTAssertEqual(BlackJack.pay(gold: 100, bet: 50, S(0, 0, 974)), 100)
    }

    func testDealerStandsOnSoft17() {
        var v = lisbon()
        v.gold = 1000
        // Player 10 + 9; hole A, then 6: a soft 17 stands.
        var r = BlackJackRound(shoe: [9, 0, 8, 5] + Array(20..<40))
        XCTAssertEqual(r.place(100, &v), .msg(965))
        XCTAssertEqual(v.gold, 900)
        XCTAssertEqual(r.playerTotal, 19)
        r.stand(&v)
        XCTAssertEqual(r.dealer, [0, 5])
        XCTAssertTrue(r.holeShown)
        XCTAssertEqual(r.dealerScore, 17)
        XCTAssertEqual(r.settlement, BlackJack.Settlement(2, 0, 968))
        XCTAssertEqual(v.gold, 1100)
    }

    func testDealerDrawsSixCardsAndAfterABust() {
        var v = lisbon()
        v.gold = 1000
        // Player 10 + 3 stands on 13; the dealer's 2,2,2,2,3,3 is 14 after six cards, hole unseen.
        var r = BlackJackRound(shoe: [9, 1, 2, 14, 27, 40, 15, 28] + Array(30..<46))
        r.place(10, &v)
        r.stand(&v)
        XCTAssertEqual(r.dealer.count, 6)
        XCTAssertFalse(r.holeShown)
        XCTAssertEqual(r.dealerScore, 14)
        XCTAssertEqual(r.settlement, BlackJack.Settlement(0, 2, 977))   // dealer wins with five cards or more
        XCTAssertEqual(v.gold, 970)                                     // the bet and twice more

        // A bust: the dealer still plays; his 20 does not make it worse.
        var b = BlackJackRound(shoe: [9, 9, 8, 7, 22] + Array(30..<49))
        v.gold = 1000
        b.place(20, &v)                                                  // 10 + 9
        b.hit(&v)                                                        // + 8 = 27
        XCTAssertTrue(b.finished)
        XCTAssertEqual(b.playerScore, 0)
        XCTAssertEqual(b.dealer, [9, 22])
        XCTAssertEqual(b.settlement, BlackJack.Settlement(0, 0, 974))
        XCTAssertEqual(v.gold, 980)
    }

    func testBetLimits() {
        var v = lisbon()
        XCTAssertEqual(Gambling.betLimit(gold: 1000), 500)
        XCTAssertEqual(Gambling.betLimit(gold: 300), 300)
        v.gold = 1000
        var r = BlackJackRound(&v)
        XCTAssertNil(r.place(9, &v))
        XCTAssertNil(r.place(501, &v))
        XCTAssertEqual(r.place(500, &v), .msg(964))
        XCTAssertEqual(v.gold, 500)
        v.gold = 15
        var s = BlackJackRound(&v)
        XCTAssertNil(s.place(16, &v))
        XCTAssertEqual(s.place(15, &v), .msg(963))
        XCTAssertEqual(BlackJack.remark(bet: 200), 965)
        v.gold = 0
        XCTAssertEqual(v.gamblingRefusal, .msg(1010))
        XCTAssertFalse(Gambling.canPlay(gold: 9))

        v.gold = 300
        var d = DiceRound(order: 0, &v)
        XCTAssertEqual(d.limit, 300)
        XCTAssertFalse(d.place(9, &v))
        XCTAssertFalse(d.place(301, &v))
        XCTAssertTrue(d.place(200, &v))                                  // 200 and up: no haggling
        XCTAssertEqual(d.phase, .rolling)
        XCTAssertEqual(v.gold, 100)
        XCTAssertEqual(Array(d.lines.suffix(2).map(\.line)), [.msg(993), .msg(994)])
    }

    func testBlackJackFarewell() {
        XCTAssertEqual(BlackJack.farewell(start: 1000, gold: 1501), [.msg(982)])
        XCTAssertEqual(BlackJack.farewell(start: 1000, gold: 499), [.msg(983)])
        XCTAssertEqual(BlackJack.farewell(start: 1000, gold: 1500), [])
        XCTAssertEqual(BlackJack.farewell(start: 1000, gold: 0), [])
    }

    // MARK: Dice

    func testDiceHands() {
        XCTAssertEqual(Dice.rank([3, 3, 3, 3, 3]), 10)
        XCTAssertEqual(Dice.rank([0, 3, 3, 3, 3]), 6)
        XCTAssertEqual(Dice.rank([2, 2, 3, 3, 3]), 4)
        XCTAssertEqual(Dice.rank([1, 3, 3, 3, 5]), 3)
        XCTAssertEqual(Dice.rank([1, 1, 3, 3, 5]), 2)
        XCTAssertEqual(Dice.rank([1, 1, 2, 3, 5]), 1)
        XCTAssertEqual(Dice.rank([1, 2, 3, 4, 5]), 0)                    // no straights
        XCTAssertEqual([10, 6, 4, 3, 2, 1, 0].map(Dice.handName), ["파이브 다이스", "포 다이스", "풀 하우스", "쓰리 다이스", "투 페어", "원 페어", ""])
        XCTAssertEqual(Dice.face(0), 6)
        XCTAssertEqual(Dice.keys([0, 0, 2, 2, 5]), [6, 2])               // sixes first
        XCTAssertEqual(Dice.keys([2, 2, 5, 5, 1].sorted()), [2, 5])      // else the lower pair first
        XCTAssertEqual(Dice.keys([2, 2, 3, 3, 3]), [3, 2])
        XCTAssertEqual(Dice.pairs([0, 1, 1, 4, 4]), [false, true, true, true, true])
    }

    func testDiceCompare() {
        let five = [3, 3, 3, 3, 3], four = [1, 2, 2, 2, 2], blank = [1, 2, 3, 4, 5]
        XCTAssertEqual(Dice.compare(five, four, blank), 0)
        XCTAssertEqual(Dice.compare(four, five, blank), 1)
        XCTAssertEqual(Dice.compare(blank, four, five), 2)
        XCTAssertEqual(Dice.compare(blank, five, five), 3)
        XCTAssertEqual(Dice.compare(blank, blank, blank), 4)               // the original reads garbage here
        XCTAssertEqual(Dice.compare([1, 1, 2, 3, 4], [1, 1, 2, 4, 5], [1, 1, 3, 4, 5]), 4)   // equal pairs: the original says B
        XCTAssertEqual(Dice.compare(five, five, four), 5)
        XCTAssertEqual(Dice.compare(five, four, five), 6)
        XCTAssertEqual(Dice.compare([0, 0, 0, 1, 2], [4, 4, 4, 1, 2], [5, 5, 5, 1, 2]), 0)   // three sixes beat three fives
        // Two pair: 3-3/4-4 beats 2-2/5-5 because the lower pair is compared first.
        XCTAssertEqual(Dice.compare([1, 2, 2, 5, 5], [1, 3, 3, 4, 4], blank), 1)
    }

    func testDiceRollSortsAndKeepsHolds() {
        var rng = GameRandom(seed: 3)
        var dice: [Int] = []
        var held = [false, false, false, false, false]
        Dice.roll(&dice, held: &held, &rng)
        XCTAssertEqual(dice, dice.sorted())
        held = [true, false, false, false, true]
        let kept = [dice[0], dice[4]]
        Dice.roll(&dice, held: &held, &rng)
        XCTAssertEqual(dice, dice.sorted())
        XCTAssertEqual(held.filter { $0 }.count, 2)
        XCTAssertEqual(zip(dice, held).filter { $0.1 }.map(\.0), kept.sorted())
    }

    func testDiceRoundsPayThePot() {
        for seed in 1...60 as ClosedRange<UInt32> {
            var v = lisbon()
            v.rng = GameRandom(seed: seed)
            v.gold = 1000
            var d = DiceRound(order: Int(seed % 3), &v)
            XCTAssertTrue(d.place(50, &v))
            if case .offer(let prop) = d.phase {
                XCTAssertTrue((55...100).contains(prop))                 // +10..100 %
                d.answer(seed % 2 == 0, &v)
            }
            let bet = d.bet
            XCTAssertEqual(v.gold, 1000 - bet)
            XCTAssertEqual(d.rolls[0], 1)
            d.reroll(keeping: Dice.pairs(d.dice[0]), &v)
            if d.phase == .rolling { d.stay(&v) }
            XCTAssertEqual(d.phase, .finished)
            XCTAssertEqual(d.rolls[1], 3)                                // opponents always roll three times
            XCTAssertEqual(d.rolls[2], 3)
            let r = try! XCTUnwrap(d.result)
            XCTAssertEqual(r, Dice.compare(d.dice[0], d.dice[1], d.dice[2]))
            let back = [0: 3 * bet, 4: bet, 5: 3 * bet / 2, 6: 3 * bet / 2][r] ?? 0
            XCTAssertEqual(v.gold, 1000 - bet + back)
            if r == 0 { XCTAssertEqual(d.order, 2) }
            if r == 1 { XCTAssertEqual(d.order, 0) }
            if r == 2 { XCTAssertEqual(d.order, 1) }
        }
    }

    func testDiceHaggling() {
        var saw = Set<Int>()
        for seed in 1...200 as ClosedRange<UInt32> {
            var v = lisbon()
            v.rng = GameRandom(seed: seed)
            v.gold = 1000
            var d = DiceRound(order: 0, &v)
            d.place(150, &v)                                             // from 100 up: +10..50 %
            guard case .offer(let prop) = d.phase else { continue }
            XCTAssertTrue((165...225).contains(prop))
            d.answer(false, &v)
            XCTAssertTrue([150, prop, (prop + 150) / 2].contains(d.bet))
            if case .message(let n, _) = d.lines.suffix(2).first!.line { saw.insert(n) }
        }
        XCTAssertEqual(saw, [988, 989, 991])
    }
}
