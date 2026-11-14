import SwiftUI
import PortolanCore

// Town buildings whose menus are native code in the original: bank (menu 0), palace
// (menus 16, 55), guild (menu 1), item shop, church (menu 7) and fortune teller (menu 17),
// plus the investment box of the trading post and the shipyard and the inn's support table.
// Rules live in PortolanCore (Town.swift and friends); every line said is MESSAGE.DAT.

// MARK: - text and the door

extension Game {
    func townText(_ l: TownLine) -> String { l.rendered(messages) }
    func townText(_ ls: [TownLine]) -> [String] { ls.map(townText) }

    /// The town-side door rules after a building's scripts let the hero in (0x1B150; palace
    /// 0x2A424; church 0x2C5EB): false when arrested or turned away. What was said shows as a
    /// notice.
    @discardableResult
    func enterTown(_ b: HarborPanel) -> Bool {
        let entry = act { $0.enterBuilding(b.rawValue) }
        let text = townText(entry.lines).joined(separator: "\n")
        if !text.isEmpty { say(text) }
        return entry.admitted
    }
}

/// Dispatch for the town buildings (TownPanel's switch). A new visit (the clock moves on
/// every entry) starts each panel afresh.
struct TownServices: View {
    @ObservedObject var game: Game
    let building: HarborPanel

    var body: some View {
        Group {
            switch building {
            case .bank: BankPanel(game: game)
            case .palace: PalacePanel(game: game)
            case .guild: GuildPanel(game: game)
            case .itemShop: ItemShopPanel(game: game)
            case .church: ChurchPanel(game: game)
            case .fortuneTeller: FortunePanel(game: game)
            default: Text("볼일이 끝났습니다.").foregroundStyle(.secondary)
            }
        }
        .id("\(building.rawValue).\(game.status.day).\(game.status.tick)")
    }
}

// MARK: - conversation

/// What the clerk has said and the question waiting for an answer.
struct TownTalk {
    var lines: [String] = []
    var ask: TownQuestion?
    var serial = 0
}

enum TownQuestion {
    case yesNo((Bool) -> Void)
    case amount(Int, (Int) -> Void)
    case choice([String], (Int?) -> Void)
    case name(String, (String) -> Void)
}

/// Puts town lines and questions into a talk box.
struct Clerk {
    let game: Game
    let talk: Binding<TownTalk>

    func say(_ lines: [TownLine], _ ask: TownQuestion? = nil) {
        talk.wrappedValue = TownTalk(lines: game.townText(lines), ask: ask, serial: talk.wrappedValue.serial + 1)
    }

    /// An amount service: refusal, or the question and then `perform`.
    func offer(_ o: TownAsk, perform: @escaping (Int) -> [TownLine]) {
        switch o {
        case .refused(let l): say(l)
        case .yesNo(let l): say(l, .yesNo { yes in say(yes ? perform(1) : []) })
        case .amount(let l, let most):
            say(l, .amount(most) { v in say(v == 0 ? [] : perform(v)) })
        }
    }

    /// A yes/no service: refusal, or the question; `no` is what is said on a no.
    func confirm(_ o: TownAsk, no: [TownLine] = [], perform: @escaping () -> [TownLine]) {
        switch o {
        case .refused(let l): say(l)
        case .yesNo(let l), .amount(let l, _): say(l, .yesNo { yes in say(yes ? perform() : no) })
        }
    }
}

struct TalkBox: View {
    @Binding var talk: TownTalk

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(talk.lines.enumerated()), id: \.offset) { _, l in
                Text(l).font(GameFont.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let ask = talk.ask {
                QuestionView(ask: ask) { talk.ask = nil }.id(talk.serial)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuestionView: View {
    let ask: TownQuestion
    let clear: () -> Void
    @State private var amount = 0
    @State private var name = ""

    var body: some View {
        switch ask {
        case .yesNo(let f):
            HStack {
                Button("예") { clear(); f(true) }.buttonStyle(GameButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                Button("아니오") { clear(); f(false) }
            }
        case .amount(let most, let f):
            HStack {
                TextField("", value: $amount, format: .number).textFieldStyle(.roundedBorder).frame(width: 150)
                    .monospacedDigit()
                Slider(value: Binding(get: { Double(min(amount, most)) }, set: { amount = Int($0.rounded()) }),
                       in: 0...Double(max(most, 1)))
                    .disabled(most == 0).frame(minWidth: 140)
                Text("0–\(most)").font(GameFont.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("최대") { amount = most }
                Button("확인") { clear(); f(min(max(0, amount), most)) }.buttonStyle(GameButtonStyle(prominent: true))
                Button("그만두기") { clear(); f(0) }
            }
        case .choice(let options, let f):
            HStack {
                ForEach(options.indices, id: \.self) { k in
                    Button(options[k]) { clear(); f(k) }.buttonStyle(GameButtonStyle(prominent: true))
                }
                Button("그만두기") { clear(); f(nil) }
            }
        case .name(let suggested, let f):
            HStack {
                TextField(suggested, text: $name).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("확인") { clear(); f(name.isEmpty ? suggested : name) }.buttonStyle(GameButtonStyle(prominent: true))
            }
        }
    }
}

// MARK: - scripts inside a panel

/// Scenario script runs a native menu starts (the guild briefing, the palace audience),
/// played in the panel so the menu can go on from how each run ended (`leave`). A duel
/// is handed over to the game's own dialogue and duel screen.
final class ScriptStage: ObservableObject {
    @Published private(set) var session: ScriptSession?
    private var then: ((ScriptSession) -> Void)?

    func play(_ game: Game, key2: Int, contexts: [ScriptContext], then: @escaping (ScriptSession) -> Void) {
        let port = game.voyage.townPort
        let world = game.world
        var s = ScriptSession(key1: port, key2: key2, port: port, contexts: contexts)
        game.act { s.advance(&$0, in: world) }
        settle(s, game, then)
    }

    func answer(_ value: Int, _ game: Game) {
        guard var s = session, let then else { return }
        let world = game.world
        game.act { s.answer(value, &$0, in: world) }
        settle(s, game, then)
    }

    private func settle(_ s: ScriptSession, _ game: Game, _ then: @escaping (ScriptSession) -> Void) {
        if let code = s.ending { game.endingCode = code }
        if case .duel? = s.prompt {
            session = nil
            self.then = nil
            game.session = s
            return
        }
        if s.done {
            session = nil
            self.then = nil
            then(s)
        } else {
            session = s
            self.then = then
        }
    }
}

struct ScriptStageView: View {
    @ObservedObject var game: Game
    @ObservedObject var stage: ScriptStage

    var body: some View {
        if let s = stage.session, let run = s.run, let prompt = s.prompt {
            VStack(alignment: .leading, spacing: 8) {
                if let p = run.picture, let img = game.image("images/event\(game.status.memory[DS.heroID] + 1)_\(p).png") {
                    Image(nsImage: img).pixelated().aspectRatio(192 / 144, contentMode: .fit).frame(width: 288)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                ForEach(run.windows.filter { $0.id != 3 }.sorted { $0.id < $1.id }, id: \.id) { w in window(w) }
                controls(prompt)
            }
        }
    }

    private func window(_ w: ScriptWindow) -> some View {
        let face = w.face.flatMap { $0 < 128 ? game.image(String(format: "portraits/%03d.png", $0)) : nil }
        return HStack(alignment: .top, spacing: 12) {
            if let face { Image(nsImage: face).pixelated().frame(width: 64, height: 80).clipShape(RoundedRectangle(cornerRadius: 6)) }
            VStack(alignment: .leading, spacing: 4) {
                if let sp = w.speaker { Text(sp).font(GameFont.headline).foregroundStyle(.yellow) }
                Text(w.text).font(GameFont.callout).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .gameSection(radius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.15)))
    }

    @ViewBuilder
    private func controls(_ prompt: ScriptPrompt) -> some View {
        switch prompt {
        case .next:
            Button { stage.answer(0, game) } label: { Label("계속", systemImage: "chevron.down") }
                .keyboardShortcut(.defaultAction)
        case .menu(let choices):
            HStack {
                ForEach(choices.indices, id: \.self) { k in
                    Button(choices[k]) { stage.answer(k, game) }.buttonStyle(GameButtonStyle(prominent: true))
                }
            }
        case .yesNo:
            HStack {
                Button("예") { stage.answer(1, game) }.buttonStyle(GameButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                Button("아니오") { stage.answer(0, game) }
            }
        case .ending:
            Button("끝") { stage.answer(0, game) }.buttonStyle(GameButtonStyle(prominent: true))
        case .duel:
            EmptyView()
        }
    }
}

// MARK: - bank (menu 0)

struct BankPanel: View {
    @ObservedObject var game: Game
    @State private var talk = TownTalk()

    var body: some View {
        let v = game.status
        let clerk = Clerk(game: game, talk: $talk)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("예금") { clerk.offer(game.status.depositOffer()) { n in game.act { $0.deposit(n) } } }
                Button("출금") { clerk.offer(game.status.withdrawOffer()) { n in game.act { $0.withdraw(n) } } }
                Button("대출") { clerk.offer(game.status.borrowOffer()) { n in game.act { $0.borrow(n) } } }
                Button("상환") { clerk.offer(game.status.repayOffer()) { n in game.act { $0.repay(n) } } }
                Spacer()
                Text(v.bankBalance >= 0 ? "예금잔고 \(v.bankBalance)닢 · 월 3%" : "차입금 \(-v.bankBalance)닢 · 월 10%")
                    .monospacedDigit().foregroundStyle(v.bankBalance >= 0 ? Color.secondary : Color.orange)
            }
            .disabled(talk.ask != nil)
            TalkBox(talk: $talk)
        }
        .onAppear {
            let name = game.world.ports.indices.contains(v.townPort) ? game.world.ports[v.townPort].name : ""
            clerk.say([v.bankGreeting(portName: name)])
        }
    }
}

// MARK: - palace (menus 16 and 55)

struct PalacePanel: View {
    @ObservedObject var game: Game
    @StateObject private var stage = ScriptStage()
    @State private var talk = TownTalk()
    /// The audience submenu (세력상황, 사략허가서, 면세증) is open.
    @State private var audience = false

    var body: some View {
        let v = game.status
        let n = v.portNation
        let menu = v.palaceMenu
        let clerk = Clerk(game: game, talk: $talk)
        HStack(alignment: .top, spacing: 14) {
            if let img = game.image(String(format: "portraits/%03d.png", Palace.rulerFaces[min(n, 6)])) {
                Image(nsImage: img).pixelated().frame(width: 64, height: 80).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("알현") { audienceFlow(clerk) }
                    Button("망명") { defect(clerk) }.disabled(!menu.defect)
                    Button("자금원조") { clerk.say(game.act { $0.receiveGoldAid() }); after() }.disabled(!menu.aid)
                    Button("선박원조") { shipAid(clerk) }.disabled(!menu.aid)
                    Spacer()
                    if n < 6 { Text("\(Town.nationNames[n]) · 공헌도 \(v.standing(with: n))").foregroundStyle(.secondary) }
                }
                .disabled(stage.session != nil || talk.ask != nil)
                if audience {
                    HStack {
                        Button("세력상황") { clerk.say(game.status.powerReport(of: n)); after() }
                        Button("사략허가서") { privateer(clerk) }.disabled(n != v.nationality)
                        Button("면세증") { certificate(clerk) }.disabled(n >= 6)
                        Button("물러나기") { audience = false; talk = TownTalk() }
                    }
                    .disabled(talk.ask != nil)
                }
                ScriptStageView(game: game, stage: stage)
                TalkBox(talk: $talk)
            }
        }
        .onAppear { clerk.say(game.status.palaceGreeting()) }
    }

    /// Rank 9 with the story option ends the game after any palace action (0x17032, 15).
    private func after() {
        if let e = game.status.palaceEnding { game.endingCode = e }
    }

    /// 알현 (0x29EDD): the commission for a summoned hero (SNR0 port,5), then the hero's and
    /// the shared audience scripts (port,0x15); the submenu opens if neither sent you away.
    private func audienceFlow(_ clerk: Clerk) {
        audience = false
        clerk.say([])
        let rest = {
            stage.play(game, key2: ScriptKey.audience, contexts: [.hero]) { s in
                guard !s.leave else { return after() }
                stage.play(game, key2: ScriptKey.audience, contexts: [.shared]) { s in
                    if !s.leave { audience = true }
                    after()
                }
            }
        }
        if game.act({ $0.beginAudience() }) {
            stage.play(game, key2: ScriptKey.palace, contexts: [.shared]) { _ in rest() }
        } else {
            rest()
        }
    }

    private func defect(_ clerk: Clerk) {
        clerk.say(game.status.defectionQuestion(), .yesNo { yes in
            clerk.say(yes ? game.act { $0.defect() } : [.msg(459)])
            after()
        })
    }

    private func shipAid(_ clerk: Clerk) {
        switch game.status.shipAidOffer(in: game.world) {
        case .refused(let l): clerk.say(l); after()
        case .yesNo(let l), .amount(let l, _):
            let c = game.status.pendingShipAid(game.status.portNation).shipClass
            clerk.say(l, .name(game.world.navigation.classes[min(c, 7)].name) { name in
                clerk.say(game.act { $0.receiveShipAid(named: name, in: game.world) })
                after()
            })
        }
    }

    private func privateer(_ clerk: Clerk) {
        clerk.confirm(game.status.privateerOffer()) { game.act { $0.requestPrivateerLicence() } }
        after()
    }

    private func certificate(_ clerk: Clerk) {
        switch game.status.certificateOffer() {
        case .refused(let l): clerk.say(l)
        case .yesNo(let l), .amount(let l, _):
            clerk.say(l, .yesNo { yes in
                guard yes else { return clerk.say([]) }
                let terms = game.status.certificateTerms()
                if terms.price == 0 {
                    clerk.say(terms.lines + game.act { $0.buyCertificate() })
                } else {
                    clerk.say(terms.lines, .yesNo { yes in clerk.say(yes ? game.act { $0.buyCertificate() } : []) })
                }
            })
        }
        after()
    }
}

// MARK: - guild (menu 1)

struct GuildPanel: View {
    @ObservedObject var game: Game
    @StateObject private var stage = ScriptStage()
    @State private var talk = TownTalk()

    var body: some View {
        let clerk = Clerk(game: game, talk: $talk)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("업무알선") { desk(clerk) }
                Button("나라정보") { news(clerk) }
                Spacer()
                if game.status.sharedChapter != 0 {
                    Text(jobLabel(game.status)).foregroundStyle(.secondary)
                }
            }
            .disabled(stage.session != nil || talk.ask != nil)
            ScriptStageView(game: game, stage: stage)
            TalkBox(talk: $talk)
        }
        .onAppear { clerk.say(game.status.guildGreeting()) }
    }

    private func jobLabel(_ v: Voyage) -> String {
        let c = v.sharedChapter
        return c <= 5 ? "진행 중: \(Guild.jobNames[max(0, c - 1)])" : "진행 중: 칙명"
    }

    /// 업무알선 (0x2C77F): the offers come back after each refusal, as in the original.
    private func desk(_ clerk: Clerk) {
        if game.status.sharedChapter != 0 && game.status.sharedVar(6) == 11 {
            return clerk.say(game.act { $0.commission11Desk(in: game.world) })   // 0x2C636
        }
        switch game.status.guildDesk() {
        case .busy(let l), .summoned(let l): clerk.say(l)
        case .offers(let kinds):
            clerk.say([], .choice(kinds.map { Guild.jobNames[min($0, 4)] }) { k in
                guard let k else { return clerk.say([]) }
                game.act { $0.pickJob(k) }
                stage.play(game, key2: ScriptKey.guild, contexts: [.shared]) { _ in
                    if !game.act({ $0.settleJob() }) { desk(clerk) }
                }
            })
        }
    }

    /// 나라정보 (0x2CA2A): which nation (162), then the fee (86).
    private func news(_ clerk: Clerk) {
        clerk.say([.msg(162)], .choice(Town.nationNames) { n in
            guard let n else { return clerk.say([]) }
            clerk.say(game.status.newsOffer().lines, .yesNo { yes in
                clerk.say(yes ? game.act { $0.buyNews(of: n) } : [.msg(87)])
            })
        })
    }
}

private extension TownAsk {
    var lines: [TownLine] {
        switch self {
        case .refused(let l), .yesNo(let l), .amount(let l, _): return l
        }
    }
}

// MARK: - item shop

struct ItemShopPanel: View {
    @ObservedObject var game: Game
    @State private var talk = TownTalk()
    @State private var pick: Int?

    var body: some View {
        let v = game.status
        let clerk = Clerk(game: game, talk: $talk)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("구입").font(GameFont.headline)
                    if v.shopStock.isEmpty { Text(game.message(99)).foregroundStyle(.secondary) }
                    ForEach(v.shopStock, id: \.self) { id in
                        let it = v.item(id)
                        row(id, it.name, detail: stats(it), price: it.price) {
                            clerk.confirm(game.status.buyItemOffer(id)) { game.act { $0.buyItem(id) } }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("소지품 \(v.items.count) / \(Town.maxItems)").font(GameFont.headline)
                    if v.items.isEmpty { Text(game.message(243)).font(GameFont.caption).foregroundStyle(.secondary) }
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(v.items.enumerated()), id: \.offset) { _, id in
                                let it = v.item(id)
                                HStack {
                                    row(id, (it.equipped ? "◆ " : "") + it.name, detail: stats(it), price: nil) { pick = id }
                                    if it.slot != nil {
                                        Button(it.equipped ? "해제" : "장비") { clerk.say(game.act { $0.toggleEquip(id) }) }.font(GameFont.caption)
                                    }
                                    Button("매각") { sell(id, clerk) }.font(GameFont.caption)
                                }
                            }
                        }
                    }.frame(height: min(180, CGFloat(max(1, v.items.count)) * 52))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(talk.ask != nil)
            if let id = pick { ItemDetail(game: game, id: id) }
            TalkBox(talk: $talk)
        }
        .onAppear {
            clerk.say([.msg(238)])
        }
    }

    private func stats(_ it: ItemInfo) -> String {
        it.slot == 0 ? "공격력 \(it.power)" : it.slot != nil ? "방어력 \(it.power)" : ""
    }

    /// 매각 (0x295F7): a no may talk the price up for a lucky seller, then the offer is repeated.
    private func sell(_ id: Int, _ clerk: Clerk) {
        func ask(_ lines: [TownLine], _ price: Int) {
            clerk.say(lines, .yesNo { yes in
                if yes { return clerk.say(game.act { $0.sellItem(id, price: price) }) }
                if let h = game.act({ $0.haggleItem(price: price) }) { ask(h.lines, h.price) } else { clerk.say([]) }
            })
        }
        switch game.status.sellItemOffer(id) {
        case .refused(let l): clerk.say(l)
        case .yesNo(let l), .amount(let l, _): ask(l, game.status.resalePrice(id))
        }
    }

    private func row(_ id: Int, _ name: String, detail: String, price: Int?, action: @escaping () -> Void) -> some View {
        Button(action: { pick = id; action() }) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(GameFont.body.weight(pick == id ? .semibold : .regular))
                        .fixedSize(horizontal: false, vertical: true)
                    if !detail.isEmpty { Text(detail).font(GameFont.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let price { Text("\(price)닢").monospacedDigit() }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(pick == id ? Theme.gold.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - church (menu 7)

struct ChurchPanel: View {
    @ObservedObject var game: Game
    @State private var talk = TownTalk()

    var body: some View {
        let clerk = Clerk(game: game, talk: $talk)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("예배") { clerk.say(game.act { $0.pray() }) }
                Button("기부") { clerk.offer(game.status.donationOffer()) { n in game.act { $0.donate(n) } } }
                Spacer()
                Text("운 \(game.status.captain.luck)").monospacedDigit().foregroundStyle(.secondary)
            }
            .disabled(talk.ask != nil)
            TalkBox(talk: $talk)
        }
        .onAppear { clerk.say([game.status.churchGreeting()]) }
        .onDisappear { game.say(game.townText(game.status.churchFarewell())) }
    }
}

// MARK: - fortune teller (menu 17)

struct FortunePanel: View {
    @ObservedObject var game: Game
    @State private var talk = TownTalk()

    var body: some View {
        let clerk = Clerk(game: game, talk: $talk)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ForEach(Fortune.allCases, id: \.self) { f in
                    Button(f.name) { ask(f, clerk) }.disabled(!game.status.fortunes.contains(f))
                }
            }
            .disabled(talk.ask != nil)
            TalkBox(talk: $talk)
        }
        .onAppear { clerk.say([.msg(298)]) }
    }

    /// Every reading costs 50 (299); 동료운 first asks whose (792).
    private func ask(_ f: Fortune, _ clerk: Clerk) {
        let fee = { (companion: Int?) in
            clerk.say([.msg(299)], .yesNo { yes in
                guard yes else { return clerk.say([]) }
                clerk.say(game.act { $0.readFortune(f, companion: companion) })
            })
        }
        guard f == .companion else { return fee(nil) }
        clerk.say([.msg(792)], .choice(game.status.officers.map(\.name)) { k in
            guard let k else { return clerk.say([]) }
            fee(k)
        })
    }
}

// MARK: - trading post / shipyard investment, inn support table

/// 투자 at the trading post (economy) or 공업투자 at the shipyard (industry), 0x24A58 / 0x2C24F.
struct InvestBox: View {
    @ObservedObject var game: Game
    let field: InvestField
    @State private var talk = TownTalk()

    var body: some View {
        let v = game.status
        let p = v.townPort
        let clerk = Clerk(game: game, talk: $talk)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(field == .economy ? "투자" : "공업투자") {
                    clerk.offer(game.status.investOffer(field)) { n in game.act { $0.invest(n, in: field) } }
                }
                .disabled(talk.ask != nil)
                if v.markets.indices.contains(p) {
                    let m = v.markets[p]
                    Text("\(field == .economy ? "경제력" : "공업력") \(field == .economy ? m.economy : m.industry) · 이번 달 투자 \(v.investment(field, port: p)) / \(Invest.monthlyCap)닢")
                        .font(GameFont.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            TalkBox(talk: $talk)
        }
    }
}

/// 항구의 지지율 (0x285E2): the six nations' support in this port, the owner marked.
struct PortSupportBox: View {
    @ObservedObject var game: Game

    var body: some View {
        let v = game.status
        let p = v.townPort
        if v.markets.indices.contains(p) {
            let m = v.markets[p]
            VStack(alignment: .leading, spacing: 4) {
                Text(game.message(1084)).font(GameFont.caption).foregroundStyle(.secondary)
                ForEach(0..<6, id: \.self) { n in
                    HStack {
                        Text(Town.nationNames[n]).frame(width: 80, alignment: .leading)
                        GeometryReader { g in
                            Capsule().fill(n == m.nation ? Color.yellow : Color.white.opacity(0.35))
                                .frame(width: g.size.width * Double(m.support[n]) / 100)
                        }.frame(height: 6)
                        Text("\(m.support[n])%").monospacedDigit().fixedSize().frame(minWidth: 56, alignment: .trailing)
                        Text(n == m.nation ? game.message(1085) : "").font(GameFont.caption).frame(width: 74, alignment: .leading)
                    }.font(GameFont.callout)
                }
            }
            .frame(maxWidth: 420)
        }
    }
}
