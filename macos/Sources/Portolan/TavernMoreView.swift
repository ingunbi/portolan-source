import SwiftUI
import PortolanCore

// The rest of the tavern (menu 15) and the inn's guests: 선원해고, the patron menus (한턱내기,
// 항해자정보, 고용), 여급과대화 and 도박. Rules live in PortolanCore/TavernMore.swift; every line said
// is MESSAGE.DAT (docs/re/tavern_more.md).

/// Which part of the tavern menu is open. `main` is 선원고용 · 한턱내기 · 항해자와대화.
enum TavernMode: Equatable {
    case main, dismiss, gambling
    case barmaid(Int)
}

extension Game {
    /// KAO portrait of tavern girl `g` (0x61 + g).
    func girlPortrait(_ g: Int) -> NSImage? { image(String(format: "portraits/%03d.png", 0x61 + g)) }

    /// A generated gambler's face, drawn for the port's nation.
    func gamblerPortrait(_ face: Int) -> NSImage? { portrait(face: face, nation: status.portNation) }

    /// "금괴 %4ld" "소지금 금화 %4ld" (960, 959): the purse as the gambling tables show it.
    var gamblingPurse: String {
        let g = status.gold
        return (g >= 10000 ? townText(.msg(960, g / 10000)) + "  " : "") + townText(.msg(959, g % 10000))
    }
}

private func face(_ img: NSImage?, _ w: CGFloat = 48) -> some View {
    Group {
        if let img { Image(nsImage: img).pixelated().frame(width: w, height: w * 1.25).clipShape(RoundedRectangle(cornerRadius: 5)) }
    }
}

// MARK: - menu 15

/// The entry greeting (17 from the heroine at the door, or the keeper's 18) and the tavern menu.
/// 선원해고 is greyed without a ship, 여급과대화 without a barmaid (0x26FF5).
struct TavernMenuBar: View {
    @ObservedObject var game: Game
    @Binding var mode: TavernMode
    @State private var greeting: [String] = []

    var body: some View {
        let v = game.status
        VStack(alignment: .leading, spacing: 8) {
            if !greeting.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    if let h = v.heroineHere { face(game.girlPortrait(h), 36) }
                    VStack(alignment: .leading, spacing: 2) {
                        if let h = v.heroineHere { Text(v.barmaid(h).name).font(GameFont.caption).foregroundStyle(.yellow) }
                        ForEach(greeting, id: \.self) { Text($0).font(GameFont.callout).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            HStack {
                item("선원 · 한턱내기 · 항해자", .main)
                item(Patron.tavernMenu[1], .dismiss).disabled(v.ships.isEmpty)
                Button(Patron.tavernMenu[4]) { if let g = v.barmaidHere { mode = .barmaid(g) } }
                    .buttonStyle(GameButtonStyle()).tint(mode.isBarmaid ? .yellow : nil)
                    .disabled(v.barmaidHere == nil || mode.isBarmaid)
                item(Patron.tavernMenu[5], .gambling)
            }
        }
        .onAppear { greeting = game.townText(game.status.tavernGreeting(in: game.world)) }
    }

    private func item(_ title: String, _ m: TavernMode) -> some View {
        Button(title) { mode = m }
            .buttonStyle(GameButtonStyle()).tint(mode == m ? .yellow : nil)
    }
}

private extension TavernMode {
    var isBarmaid: Bool { if case .barmaid = self { return true } else { return false } }
}

// MARK: - 항해자와대화

/// Who is here to talk to (tavern 0x26293, inn 0x28592), the greeting (0x25988 / 0x28409) and
/// the patron menu: tavern menu 12 (한턱내기, 항해자정보, 고용) until you leave, inn menu 3
/// (항해자정보, 고용) for one choice. Picking the debtor or the informant of a job plays their
/// scene instead (tavern_jobs §1.5).
struct PatronList: View {
    @ObservedObject var game: Game
    let place: Hangout
    var mood = 0
    @State private var talk = TownTalk()
    @State private var person: Int?

    var body: some View {
        let v = game.status
        let people = v.patrons(at: place)
        let clerk = Clerk(game: game, talk: $talk)
        VStack(alignment: .leading, spacing: 6) {
            Text(place == .tavern ? "항해자와대화" : "항해자와 대화").font(GameFont.headline)
            if people.isEmpty {
                Text(game.townText(v.nobodyLine(at: place, mood: mood))).font(GameFont.caption).foregroundStyle(.secondary)
            }
            ForEach(people, id: \.self) { p in row(p, v, clerk) }
            if let p = person, people.contains(p) { menu(p, clerk) }
            TalkBox(talk: $talk)
        }
    }

    private func row(_ p: Int, _ v: Voyage, _ clerk: Clerk) -> some View {
        let r = v.memory.person(p)
        return HStack {
            face(game.portrait(person: p), 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.name).font(GameFont.body.weight(person == p ? .semibold : .regular))
                Text("항해 \(r.navLevel) · 전투 \(r.battleLevel) · " + abilityLine(r.stats))
                    .font(GameFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("말을 건다") {
                let g = game.act { $0.greetPatron(p, at: place) }
                person = g.menu ? p : nil
                clerk.say(g.lines)
            }.disabled(talk.ask != nil)
        }.font(GameFont.callout)
    }

    private func menu(_ p: Int, _ clerk: Clerk) -> some View {
        HStack {
            Text(game.status.memory.person(p).name).font(GameFont.caption).foregroundStyle(.yellow)
            if place == .tavern { Button("한턱내기") { treat(p, clerk) } }
            Button("항해자정보") { rumour(p, clerk) }
            Button("고용") { join(p, clerk) }
            Spacer()
            Button("그만두기") { person = nil; clerk.say([]) }
        }
        .disabled(talk.ask != nil)
        .padding(8)
        .gameSection(radius: 8)
    }

    /// One drink for the patron (0x25CCC); the job hooks run after it is paid.
    private func treat(_ p: Int, _ clerk: Clerk) {
        switch game.act({ $0.treatPatron(p, in: game.world) }) {
        case .short(let l): clerk.say(l)
        case .talk(let l): clerk.say(l)
        case .hook:
            clerk.say([])
            game.patronScene(p, treat: true)
            leftIfGone(p)
        }
    }

    private func rumour(_ p: Int, _ clerk: Clerk) {
        if game.patronScene(p) { clerk.say([]); return leftIfGone(p) }
        clerk.say(game.act { $0.navigatorRumour(in: game.world) })
        oneChoiceAtTheInn()
    }

    private func join(_ p: Int, _ clerk: Clerk) {
        if game.patronScene(p) { clerk.say([]); return leftIfGone(p) }
        let r = game.act { $0.askToJoin(p, at: place, in: game.world) }
        oneChoiceAtTheInn()
        guard let salary = r.salary else { return clerk.say(r.lines) }
        clerk.say(r.lines, .yesNo { yes in
            guard yes else { return clerk.say([.msg(143)]) }
            game.hireOfficer(p, salary: salary)
            person = nil
            clerk.say([.msg(144)])
        })
    }

    /// The debtor who ran off takes his menu with him.
    private func leftIfGone(_ p: Int) {
        if !game.status.patrons(at: place).contains(p) { person = nil }
        oneChoiceAtTheInn()
    }

    private func oneChoiceAtTheInn() { if place == .inn { person = nil } }

    private func abilityLine(_ s: [Int]) -> String {
        let names = ["통솔", "항해", "지식", "직감", "용기", "검술", "매력"]
        var best = 0
        for i in 1..<7 where s[i] > s[best] { best = i }
        return "\(names[best]) \(s[best])"
    }
}

// MARK: - 선원해고

/// 선원해고 (0x25356): ship by ship, how many sailors stay (857), then the confirmation (858).
/// No cost and no refund; a ship left without crew loses its morale.
struct DismissCrewPanel: View {
    @ObservedObject var game: Game
    @State private var keep: [Int: Int] = [:]
    @State private var talk = TownTalk()

    var body: some View {
        let v = game.status
        let clerk = Clerk(game: game, talk: $talk)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(v.ships.indices, id: \.self) { i in
                let most = v.dismissLimit(ship: i)
                let k = min(keep[i] ?? v.ships[i].crew, most)
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.townText(v.dismissPrompt(ship: i))).font(GameFont.callout)
                    HStack {
                        CountSlider(value: Binding(get: { k }, set: { keep[i] = $0 }), max: most, unit: "명").frame(width: 320)
                        Text("사기 \(v.ships[i].morale)").font(GameFont.caption).foregroundStyle(.secondary).monospacedDigit()
                        Button("해고") { confirm(i, k, clerk) }.disabled(v.dismissConfirm(ship: i, keep: k) == nil)
                    }
                }
            }
            .disabled(talk.ask != nil)
            TalkBox(talk: $talk)
        }
        .padding(16)
        .gameSection()
    }

    private func confirm(_ i: Int, _ k: Int, _ clerk: Clerk) {
        guard let line = game.status.dismissConfirm(ship: i, keep: k) else { return }
        clerk.say([line], .yesNo { yes in
            if yes { game.act { $0.dismissCrew(ship: i, keep: k) } }
            keep[i] = nil
            clerk.say([])
        })
    }
}

// MARK: - 여급과대화

/// 여급과대화 (0x26CCB): ten gold to the keeper (146, 147), then menu 14 with her as long as you
/// stay: 자기자랑, 선물, 조사의뢰, 정보수집 (menu 13: 업무정보, 그녀의취향, 그녀의연령).
struct BarmaidPanel: View {
    @ObservedObject var game: Game
    let girl: Int
    let leave: () -> Void
    @State private var seated = false
    @State private var talk = TownTalk()
    @State private var gossip = false
    @State private var picking: Pick?

    private enum Pick { case sites, gifts }

    var body: some View {
        let v = game.status
        let b = v.barmaid(girl)
        let clerk = Clerk(game: game, talk: $talk)
        HStack(alignment: .top, spacing: 14) {
            face(game.girlPortrait(girl), 64)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(b.name).font(GameFont.headline)
                    Spacer()
                    Button("돌아가기") { leave() }
                }
                if seated {
                    HStack {
                        ForEach(v.barmaidTopics, id: \.self) { t in Button(t.name) { topic(t, clerk) } }
                    }
                    .disabled(talk.ask != nil)
                    if gossip {
                        HStack {
                            ForEach(GossipTopic.allCases, id: \.self) { t in
                                Button(t.name) { ask(t, clerk) }.disabled(t == .jobs && !v.jobInfoOffered)
                            }
                        }
                        .disabled(talk.ask != nil)
                    }
                    if let picking { pickList(picking, v, clerk) }
                }
                TalkBox(talk: $talk)
            }
        }
        .padding(16)
        .gameSection()
        .onAppear {
            let r = game.act { $0.callBarmaid(girl) }
            seated = r.seated
            clerk.say(r.lines)
        }
    }

    private func topic(_ t: BarmaidTopic, _ clerk: Clerk) {
        gossip = false
        picking = nil
        let v = game.status
        switch t {
        case .boast:
            if v.boastableSites.isEmpty { clerk.say([.msg(312)]) } else { clerk.say([]); picking = .sites }
        case .gift:
            if v.giftItems.isEmpty { clerk.say([v.noGiftLine(girl)]) } else { clerk.say([]); picking = .gifts }
        case .inquiry:
            switch v.inquiryDesk(girl) {
            case .says(let l): clerk.say(l)
            case .report: clerk.say(game.act { $0.inquiryReport(girl, in: game.world) })
            case .request: newRequest(clerk)
            }
        case .gossip:
            clerk.say([.msg(398)])
            gossip = true
        }
    }

    private func ask(_ t: GossipTopic, _ clerk: Clerk) {
        switch t {
        case .jobs:
            switch game.act({ $0.jobInfo(girl, in: game.world) }) {
            case .says(let l): clerk.say(l)
            case .inquiry: newRequest(clerk)
            }
        case .taste: clerk.say(game.act { $0.herTaste(girl) })
        case .age: clerk.say(game.status.herAge(girl))
        }
    }

    /// A new investigation (0x26570): which nation (534), which fleets (535), how long (536).
    private func newRequest(_ clerk: Clerk) {
        clerk.say([.msg(534)], .choice(Array(Patron.nations.prefix(7))) { n in
            guard let n else { return clerk.say([]) }
            clerk.say([.msg(535)], .choice(Voyage.inquiryKinds(nation: n)) { c in
                guard let c else {
                    game.act { $0.dropInquiry(girl) }
                    return clerk.say([])
                }
                clerk.say(game.act { $0.requestInquiry(girl, nation: n, kind: c) })
            })
        })
    }

    private func pickList(_ pick: Pick, _ v: Voyage, _ clerk: Clerk) -> some View {
        let entries: [(id: Int, name: String)] = pick == .sites
            ? v.boastableSites.map { s in (id: s, name: game.world.discovery(s).name) }
            : v.giftItems.map { i in (id: i, name: v.item(i).name) }
        return VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                        Button { chose(pick, e.id, clerk) } label: {
                            Text(e.name).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: 150)
            Button("그만두기") { picking = nil }
        }
        .disabled(talk.ask != nil)
        .padding(8)
        .gameSection(radius: 8)
    }

    private func chose(_ pick: Pick, _ id: Int, _ clerk: Clerk) {
        switch pick {
        case .sites:
            picking = nil
            let d = game.world.discovery(id)                                // 0x34043
            clerk.say([.text("「\(d.name)」")] + game.act { $0.boast(id, to: girl) })
        case .gifts:
            let it = game.status.item(id)
            let about = game.itemTexts
            let text = about.indices.contains(id) ? about[id] : ""
            clerk.say([.text(it.name)] + (text.isEmpty ? [] : [.text(text)]), .yesNo { yes in
                guard yes else { return clerk.say([]) }
                picking = nil
                clerk.say(game.act { $0.give(id, to: girl) })
            })
        }
    }
}

// MARK: - 도박

/// 도박 (0x26E14): Black Jack or Dice. A hero without a coin is turned away (1010); both games
/// need ten gold.
struct GamblingPanel: View {
    @ObservedObject var game: Game
    let leave: () -> Void
    @State private var table: Int?
    @State private var refusal: (face: Int, line: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(game.gamblingPurse).monospacedDigit().foregroundStyle(.yellow)
                Spacer()
                if table == nil { Button("돌아가기") { leave() } }
            }
            if let r = refusal {
                HStack(alignment: .top) {
                    face(game.gamblerPortrait(r.face), 40)
                    Text(r.line).font(GameFont.callout)
                }
            } else if let t = table {
                if t == 0 { BlackJackTable(game: game) { table = nil } } else { DiceTable(game: game) { table = nil } }
            } else {
                HStack {
                    ForEach(Gambling.games.indices, id: \.self) { k in
                        Button(Gambling.games[k]) { table = k }.buttonStyle(GameButtonStyle(prominent: true))
                    }
                }
                .disabled(!Gambling.canPlay(gold: game.status.gold))
            }
        }
        .padding(16)
        .gameSection()
        .onAppear {
            if let l = game.status.gamblingRefusal {
                refusal = (game.act { $0.gamblerFace() }, game.townText(l))
            }
        }
    }
}

/// Lines said at a table, the last few, each by its speaker's face.
private struct TableTalk: View {
    @ObservedObject var game: Game
    let lines: [TableLine]
    let faces: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.suffix(6).enumerated()), id: \.offset) { _, l in
                HStack(alignment: .top, spacing: 8) {
                    if l.speaker > 0 && l.speaker <= faces.count { face(game.gamblerPortrait(faces[l.speaker - 1]), 20) }
                    Text(game.townText(l.line)).font(GameFont.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The stake (995 "도박금 (10-%3ld)"): 10 up to `limit`.
private struct BetBox: View {
    @ObservedObject var game: Game
    let limit: Int
    let place: (Int) -> Void
    @State private var amount = Gambling.minBet

    var body: some View {
        HStack {
            Text(game.townText(.msg(995, limit))).monospacedDigit()
            Slider(value: Binding(get: { Double(min(max(amount, Gambling.minBet), limit)) }, set: { amount = Int($0.rounded()) }),
                   in: Double(Gambling.minBet)...Double(max(limit, Gambling.minBet + 1)))
                .frame(width: 220)
            Stepper("\(min(max(amount, Gambling.minBet), limit))닢", value: $amount, in: Gambling.minBet...max(limit, Gambling.minBet))
                .monospacedDigit()
            Button("건다") { place(min(max(amount, Gambling.minBet), limit)) }
                .buttonStyle(GameButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
        }
    }
}

/// A card (0x2DB08): the suit picture, or the back, with the rank printed over its corner.
private struct CardView: View {
    @ObservedObject var game: Game
    let card: Int?

    var body: some View {
        let name = card.map { ["spade", "heart", "club", "diamond"][$0 / 13 % 4] } ?? "back"
        ZStack(alignment: .topLeading) {
            if let img = game.image("sprites/gambling/card_\(name).png") {
                Image(nsImage: img).pixelated().frame(width: 48, height: 72)
            }
            if let c = card {
                Text(BlackJack.ranks[c % 13])
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 2)
                    .background(Color(white: 0.93))
                    .offset(x: 3, y: 2)
            }
        }
        .frame(width: 48, height: 72)
    }
}

/// Black Jack (0x2E263): the dealer asks (979), each round a fresh shoe; after it, again (981)
/// while ten gold remain, else 980; parting words for big wins or losses (982, 983).
private struct BlackJackTable: View {
    @ObservedObject var game: Game
    let close: () -> Void
    @State private var dealer = 0
    @State private var start = 0
    @State private var lines: [TableLine] = []
    @State private var round: BlackJackRound?
    @State private var stage = Stage.invite

    private enum Stage { case invite, betting, playing, again, over }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            face(game.gamblerPortrait(dealer), 56)
            VStack(alignment: .leading, spacing: 10) {
                if let r = round { hands(r) }
                TableTalk(game: game, lines: lines, faces: [dealer])
                controls
            }
        }
        .onAppear {
            dealer = game.act { $0.gamblerFace() }
            start = game.status.gold
            lines = [TableLine(1, .msg(979))]
        }
    }

    private func hands(_ r: BlackJackRound) -> some View {
        let hole = r.finished && r.holeShown
        let up: [Int?] = r.finished ? [hole ? r.dealer[0] : nil] + r.dealer.dropFirst().map { Optional($0) } : [nil]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(up.enumerated()), id: \.offset) { _, c in CardView(game: game, card: c) }
                if hole { Text(game.townText(.msg(978, r.dealerScore == 0 ? BlackJack.total(r.dealer) : r.dealerScore))).padding(.leading, 6) }
            }
            HStack(spacing: 4) {
                ForEach(Array(r.player.enumerated()), id: \.offset) { _, c in CardView(game: game, card: c) }
                if r.placed { Text(game.townText(.msg(978, r.playerTotal))).padding(.leading, 6) }
                if r.placed { Text("도박금 \(r.bet)닢").font(GameFont.caption).foregroundStyle(.secondary).padding(.leading, 6) }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch stage {
        case .invite:
            yesNo { newRound() } no: { close() }
        case .betting:
            if let r = round {
                BetBox(game: game, limit: Gambling.betLimit(gold: game.status.gold)) { n in
                    var x = r
                    if let remark = game.act({ x.place(n, &$0) }) {
                        round = x
                        lines.append(TableLine(1, remark))
                        stage = .playing
                        settleIfDone()
                    }
                }
            }
        case .playing:
            HStack {
                Button("ＨＩＴ") { play { $0.hit(&$1) } }.buttonStyle(GameButtonStyle(prominent: true))
                Button("ＳＴＡＮＤ") { play { $0.stand(&$1) } }
            }
        case .again:
            yesNo { newRound() } no: { leaveTable() }
        case .over:
            Button("자리를 뜬다") { close() }.keyboardShortcut(.defaultAction)
        }
    }

    private func yesNo(_ yes: @escaping () -> Void, no: @escaping () -> Void) -> some View {
        HStack {
            Button("예", action: yes).buttonStyle(GameButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            Button("아니오", action: no)
        }
    }

    private func newRound() {
        round = game.act { BlackJackRound(&$0) }
        stage = .betting
    }

    private func play(_ move: (inout BlackJackRound, inout Voyage) -> Void) {
        guard var r = round else { return }
        game.act { move(&r, &$0) }
        round = r
        settleIfDone()
    }

    private func settleIfDone() {
        guard let r = round, let s = r.settlement else { return }
        lines.append(TableLine(1, .msg(s.message)))
        if Gambling.canPlay(gold: game.status.gold) {
            lines.append(TableLine(1, .msg(981)))
            stage = .again
        } else {
            lines.append(TableLine(1, .msg(980)))
            leaveTable()
        }
    }

    private func leaveTable() {
        lines += BlackJack.farewell(start: start, gold: game.status.gold).map { TableLine(1, $0) }
        stage = .over
    }
}

/// Dice (0x2F620) with two players A and B: they ask (1001, 1002); each round the stake is
/// haggled, everyone rolls five dice up to three times, the best hand takes the pot; again (1005)
/// while ten gold remain, else 1003, 1004; parting words (1006–1009).
private struct DiceTable: View {
    @ObservedObject var game: Game
    let close: () -> Void
    @State private var players: [Int] = []
    @State private var start = 0
    @State private var order = 0
    @State private var history: [TableLine] = []
    @State private var round: DiceRound?
    /// The finished round's lines are already in `history`.
    @State private var merged = false
    @State private var stage = Stage.invite
    /// "이 눈으로 승부를？" answered no: picking the dice to keep.
    @State private var choosing = false
    @State private var keep = [Bool](repeating: false, count: 5)

    private enum Stage { case invite, round, again, over }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = round, r.phase == .rolling || r.phase == .finished { board(r) }
            TableTalk(game: game, lines: history + (merged ? [] : round?.lines ?? []), faces: players)
            controls
        }
        .onAppear {
            players = [game.act { $0.gamblerFace() }, game.act { $0.gamblerFace() }]
            start = game.status.gold
            history = [TableLine(1, .msg(1001))]
        }
    }

    private func board(_ r: DiceRound) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([1, 2, 0], id: \.self) { p in
                HStack(spacing: 6) {
                    if p == 0 {
                        Text(game.status.captain.name).font(GameFont.caption).frame(width: 120, alignment: .leading)
                    } else {
                        face(game.gamblerPortrait(players[p - 1]), 24).frame(width: 120, alignment: .leading)
                    }
                    if r.rolls[p] == 0 {
                        Text("—").foregroundStyle(.secondary)
                    } else {
                        ForEach(0..<5, id: \.self) { i in die(r, p, i) }
                        Text(Dice.handName(rank: Dice.rank(r.dice[p]))).font(GameFont.callout.weight(.semibold)).padding(.leading, 6)
                    }
                    if r.result != nil && winners(r.result!).contains(p) { Image(systemName: "crown.fill").foregroundStyle(.yellow) }
                }
            }
            if r.bet > 0 { Text("도박금 \(r.bet)닢").font(GameFont.caption).foregroundStyle(.secondary) }
        }
    }

    private func die(_ r: DiceRound, _ p: Int, _ i: Int) -> some View {
        let held = r.held[p][i] || (p == 0 && choosing && keep[i])
        let canToggle = p == 0 && choosing && !r.held[0][i]
        // 0x2E5ED: picture = the raw value; 0 is the red ace, which ranks highest.
        return Group {
            if let img = game.image("sprites/gambling/die_\(r.dice[p][i]).png") {
                Image(nsImage: img).pixelated().frame(width: 36, height: 36)
            } else {
                Image(systemName: "die.face.\(Dice.face(r.dice[p][i])).fill").font(.system(size: 26))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(held ? Color.yellow : .clear, lineWidth: 2))
        .onTapGesture { if canToggle { keep[i].toggle() } }
    }

    private func winners(_ r: Int) -> [Int] { [[0], [1], [2], [1, 2], [0, 1, 2], [0, 1], [0, 2]][min(r, 6)] }

    @ViewBuilder
    private var controls: some View {
        switch stage {
        case .invite:
            yesNo {
                history.append(TableLine(2, .msg(1002)))
                newRound()
            } no: { close() }
        case .round:
            if let r = round { roundControls(r) }
        case .again:
            yesNo { newRound() } no: { leaveTable() }
        case .over:
            Button("자리를 뜬다") { close() }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func roundControls(_ r: DiceRound) -> some View {
        switch r.phase {
        case .betting:
            BetBox(game: game, limit: r.limit) { n in step { $0.place(n, &$1) } }
        case .offer:
            yesNo { step { $0.answer(true, &$1) } } no: { step { $0.answer(false, &$1) } }
        case .rolling:
            if choosing {
                HStack {
                    Text("남길 주사위를 고르십시오.").font(GameFont.callout)
                    Button("굴린다") {
                        let k = keep
                        choosing = false
                        keep = [Bool](repeating: false, count: 5)
                        step { $0.reroll(keeping: k, &$1) }
                    }.buttonStyle(GameButtonStyle(prominent: true))
                }
            } else {
                HStack {
                    Text(game.message(984)).font(GameFont.callout)                       // 이 눈으로 승부를？
                    yesNo { step { $0.stay(&$1) } } no: { choosing = true }
                }
            }
        case .finished:
            EmptyView()
        }
    }

    private func yesNo(_ yes: @escaping () -> Void, no: @escaping () -> Void) -> some View {
        HStack {
            Button("예", action: yes).buttonStyle(GameButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            Button("아니오", action: no)
        }
    }

    private func newRound() {
        round = game.act { DiceRound(order: order, &$0) }
        merged = false
        stage = .round
    }

    private func step(_ f: (inout DiceRound, inout Voyage) -> Void) {
        guard var r = round else { return }
        game.act { f(&r, &$0) }
        round = r
        guard r.phase == .finished else { return }
        order = r.order
        history += r.lines
        merged = true
        if Gambling.canPlay(gold: game.status.gold) {
            history.append(TableLine(1, .msg(1005)))
            stage = .again
        } else {
            history += [TableLine(1, .msg(1003)), TableLine(2, .msg(1004))]
            leaveTable()
        }
    }

    private func leaveTable() {
        history += Dice.farewell(start: start, gold: game.status.gold)
        stage = .over
    }
}
