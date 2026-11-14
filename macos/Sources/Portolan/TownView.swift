import SwiftUI
import PortolanCore

/// Buildings whose own menus come from the town rules (inn, palace, guild, bank, ...).
struct TownPanel: View {
    @ObservedObject var game: Game
    let building: HarborPanel
    @State private var line = ""

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text(building.title).font(GameFont.headline)
                switch building {
                case .inn:
                    inn
                    PatronList(game: game, place: .inn)                // menu 4 item 0 (TavernMoreView.swift)
                    PortSupportBox(game: game)
                case .residence: ResidencePanel(game: game)
                default:
                    TownServices(game: game, building: building)
                }
                if !line.isEmpty { Text(line).font(GameFont.callout).foregroundStyle(.yellow) }
            }
            Spacer()
        }
        .padding(16)
        .gameSection()
    }

    /// The inn (menu 4: 항해자와 대화, 항구의 지지율, 숙박): a night's sleep moves the clock to
    /// 8:00 next morning.
    private var inn: some View {
        HStack {
            Button("숙박 · 다음날 아침까지") {
                let t = game.status.tick
                game.act { $0.passTime(ticks: (Navigation.ticksPerDay - t) + 24, in: game.world) }
                line = "푹 쉬었습니다."
            }
            Button("두 시간 보내기") {
                game.act { $0.passTime(ticks: 6, in: game.world) }
            }
            .accessibilityIdentifier("portolan.inn.wait")
        }
    }
}

/// Speech windows, menus, yes/no and pictures of a running scenario script.
struct DialogueView: View {
    @ObservedObject var game: Game

    var body: some View {
        if let session = game.session, let run = session.run, let prompt = session.prompt {
            let waits = prompt == .next
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    (game.buildingScene == nil ? Color.black.opacity(0.48) : Theme.navy).ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { if waits { game.scriptAnswer(0) } }
                    VStack(spacing: 10) {
                        HStack(alignment: .top, spacing: 14) {
                        if let building = game.buildingScene {
                            BuildingInteriorView(game: game, building: building)
                                .frame(width: min(360, max(230, geometry.size.width * 0.29)))
                                .frame(maxHeight: .infinity)
                        }
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(spacing: 12) {
                                    if let picture = run.picture, let img = game.image("images/event\(game.status.memory[DS.heroID] + 1)_\(picture).png") {
                                        Image(nsImage: img).pixelated().aspectRatio(192 / 144, contentMode: .fit)
                                            .frame(maxHeight: min(200, geometry.size.height * 0.3))
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    ForEach(run.windows.filter { $0.id != 3 }.sorted { $0.id < $1.id }, id: \.id) { item in
                                        window(item, current: item.id == run.current, waits: waits)
                                    }
                                    Color.clear.frame(height: 1).id("dialogue-bottom")
                                }
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                                .onTapGesture { if waits { game.scriptAnswer(0) } }
                            }
                            .scrollIndicators(.visible)
                            .onAppear { proxy.scrollTo("dialogue-bottom", anchor: .bottom) }
                            .onChange(of: run.windows.map(\.text)) { _, _ in proxy.scrollTo("dialogue-bottom", anchor: .bottom) }
                        }
                        }
                        controls(prompt)
                            .padding(12)
                            .background(Theme.navy, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15)))
                    }
                    .padding(16)
                    .frame(width: min(game.buildingScene == nil ? 900 : 1240, geometry.size.width - 32))
                    .frame(maxHeight: geometry.size.height - 32)
                    .padding(.bottom, 16)
                }
            }
            .environment(\.colorScheme, .dark)
        }
    }

    /// A speech box: the portrait in a gold frame (the hero's side on the right), the speaker on a
    /// gold plate, the text, and a bobbing ▼ on the box that waits for a click.
    private func window(_ w: ScriptWindow, current: Bool, waits: Bool) -> some View {
        let hero = w.id == 2
        let face = w.face.flatMap { game.portrait(face: $0) }
        return HStack(alignment: .top, spacing: 16) {
            if !hero, let face { portrait(face) }
            VStack(alignment: .leading, spacing: 8) {
                if let sp = w.speaker {
                    Text(sp)
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Theme.goldGradient, in: Capsule())
                }
                Text(w.text)
                    .font(.system(size: 22, weight: .medium))
                    .lineSpacing(5)
                    .foregroundStyle(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hero, let face { portrait(face) }
        }
        .padding(18)
        .frame(minHeight: 120, alignment: .top)
        .background(LinearGradient(colors: [Theme.navyLight.opacity(0.97), Theme.navy.opacity(0.98)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.gold.opacity(current ? 0.7 : 0.3), lineWidth: current ? 1.5 : 1))
        .overlay(alignment: .bottomTrailing) {
            if current && waits { MoreMark().padding(.trailing, hero ? 118 : 16).padding(.bottom, 10) }
        }
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
    }

    private func portrait(_ img: NSImage) -> some View {
        Image(nsImage: img).pixelated().frame(width: 84, height: 105)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.gold.opacity(0.6), lineWidth: 1.5))
    }

    @ViewBuilder
    private func controls(_ prompt: ScriptPrompt) -> some View {
        switch prompt {
        case .next:
            HStack {
                Text("긴 대화는 스크롤로 확인할 수 있습니다").font(GameFont.caption).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button { game.scriptAnswer(0) } label: { Label("계속", systemImage: "arrow.right") }
                    .buttonStyle(GameButtonStyle(prominent: true))
                    .accessibilityIdentifier("portolan.dialogue.continue")
                Text("Return · Space").font(GameFont.caption).foregroundStyle(.white.opacity(0.7))
            }
        case .menu(let choices):
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                    ForEach(choices.indices, id: \.self) { k in
                        Button { game.scriptAnswer(k) } label: {
                            Text(choices[k]).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GameButtonStyle(prominent: k == 0))
                        .accessibilityIdentifier("portolan.dialogue.choice.\(k)")
                        .keyboardShortcut(k < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(k + 1)")), modifiers: []) : nil)
                    }
                }
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
        case .yesNo:
            HStack(spacing: 10) {
                Button("예") { game.scriptAnswer(1) }.buttonStyle(GameButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("portolan.dialogue.yes")
                Button("아니오") { game.scriptAnswer(0) }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("portolan.dialogue.no")
            }
        case .duel(let who):
            DuelPrompt(game: game, opponent: who)
        case .ending:
            Button("끝") { game.scriptAnswer(0) }.buttonStyle(GameButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
        }
    }
}

/// Town speech and service messages sit above the walking hints and every building panel.
struct PortMessageView: View {
    @ObservedObject var game: Game
    let text: String

    private func messageHeight(width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        #if os(macOS)
        let bounds = (text as NSString).boundingRect(with: CGSize(width: width, height: 2000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .medium), .paragraphStyle: paragraph])
        #else
        let bounds = (text as NSString).boundingRect(with: CGSize(width: width, height: 2000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: UIFont.systemFont(ofSize: 22, weight: .medium), .paragraphStyle: paragraph], context: nil)
        #endif
        return max(44, ceil(bounds.height) + 8)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.42).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { game.dismissTownMessage() }
                VStack(alignment: .leading, spacing: 16) {
                    Label(game.buildingScene?.title ?? (game.townMessage != nil ? "주민의 이야기" : "항구 소식"), systemImage: "text.bubble.fill")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.current)
                    ScrollView {
                        Text(text).font(.system(size: 22, weight: .medium)).foregroundStyle(Color.white)
                            .lineSpacing(7).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("portolan.portMessage.text")
                    }
                    .scrollIndicators(.visible)
                    .frame(height: min(messageHeight(width: min(800, geometry.size.width - 48) - 48), min(280, geometry.size.height - 220)))
                    HStack {
                        Text("Return · Space로도 닫을 수 있습니다").font(GameFont.caption).foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Button { game.dismissTownMessage() } label: { Label("확인", systemImage: "checkmark") }
                            .buttonStyle(GameButtonStyle(prominent: true))
                            .accessibilityIdentifier("portolan.portMessage.dismiss")
                    }
                }
                .padding(24)
                .frame(width: min(800, geometry.size.width - 48))
                .background(Theme.navy, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.current.opacity(0.5)))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The waiting ▼, bobbing.
struct MoreMark: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = Motion.instant ? 0 : tl.date.timeIntervalSinceReferenceDate
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.gold)
                .offset(y: 3 * sin(t * 5))
        }
        .frame(width: 14, height: 18)
        .allowsHitTesting(false)
    }
}

/// A sword duel called by a script (opcode E8): twenty exchanges at most, the meter is the result.
struct DuelPrompt: View {
    @ObservedObject var game: Game
    let opponent: Int
    @State private var duel: DuelState?

    var body: some View {
        VStack(spacing: 8) {
            if let d = duel {
                DuelBoard(game: game, duel: d) { move in
                    var x = d
                    Duel.step(&x, move: move, &game.voyage)
                    duel = x
                    if x.finished { game.scriptAnswer(x.meter) }
                }
            } else {
                Button("\(game.status.memory.person(opponent).name)와(과) 결투") {
                    duel = Duel.start(hero: game.status.memory[DS.heroID], against: opponent, game.status)
                }.buttonStyle(GameButtonStyle(prominent: true))
            }
        }
    }
}

/// The duel exchange: the meter, the last blow, and three moves (msgs 1053–1060).
struct DuelBoard: View {
    @ObservedObject var game: Game
    let duel: DuelState
    let move: (Int) -> Void

    var body: some View {
        let attacking = (duel.turn % 2 == 0) == duel.playerIsA
        let mine = duel.playerIsA ? duel.meter : 200 - duel.meter
        VStack(spacing: 8) {
            DuelStage(game: game, duel: duel)
            Text("턴 \(duel.turn + 1) : \(attacking ? "공격" : "방어")").font(GameFont.headline)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.red.opacity(0.6))
                    Capsule().fill(.blue).frame(width: g.size.width * Double(mine) / 200)
                }
            }.frame(width: 360, height: 10)
            if !duel.lastLine.isEmpty { Text(duel.lastLine).font(GameFont.callout).foregroundStyle(.secondary) }
            HStack {
                ForEach(0..<3, id: \.self) { k in
                    Button(attacking ? ["찌른다", "벤다", "친다"][k] : ["걷어낸다", "맞받는다", "비킨다"][k]) { move(k) }
                        .buttonStyle(GameButtonStyle(prominent: true))
                        .accessibilityIdentifier("portolan.duel.move.\(k)")
                }
            }
        }
    }
}

/// Landing at a sighted village (menu 35: 보물탐색, 환대, 식량약탈, 출항).
struct LandingView: View {
    @ObservedObject var game: Game
    let site: Int
    @State private var bonus = 0
    @State private var lines: [String] = []
    /// The find's picture (KAO 0x80 + COLONY +0x12, as 0x33F3C shows it).
    @State private var found = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    Text("상륙 · 부락").font(GameFont.title2.bold())
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if found, let img = game.image(String(format: "pictures/%03d.png", game.world.discoveryInfo(site).picture)) {
                                Image(nsImage: img).pixelated().frame(width: 144, height: 144)
                            }
                            ForEach(lines, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 330)
                    .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("보물탐색") {
                            let r = game.act { $0.searchSite(site, bonus: bonus, in: game.world) }
                            lines = r.lines
                            found = r.found
                            if r.found { bonus = 0 }
                        }.buttonStyle(GameButtonStyle(prominent: true))
                        Button("환대") {
                            if game.act({ $0.hostVillagers() }) {
                                bonus += 5
                                lines = [Korean.particles("우호도가 \(bonus)까지 올랐습니다.\n주민들이 수색을 돕기로 했습니다.")]
                            } else {
                                lines = [game.message(435)]
                            }
                        }
                        Button("식량약탈") {
                            let r = game.act { $0.plunderVillage() }
                            bonus = 0
                            lines = ["\(r.food)명분의 식량을 빼앗았습니다."] + (r.fight ? ["원주민이 맞서 싸웠습니다."] : [])
                        }
                        Spacer()
                        Button("출항") { game.landing = nil }.keyboardShortcut(.cancelAction)
                    }
                }
                .padding(24)
                .frame(width: min(680, geometry.size.width - 48))
                .frame(maxHeight: geometry.size.height - 40)
                .gamePanel(radius: 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Building 7: the patron (발견물보고, 모험이야기), the map maker (지리보고, 기능습득) or a
/// scholar who teaches a skill (0x2D9A8).
struct ResidencePanel: View {
    @ObservedObject var game: Game
    @State private var lines: [String] = []
    /// The completed world map picture (GRAPH.DAT 63, 0x2D3C1).
    @State private var chartDone = false

    var body: some View {
        let v = game.status
        let port = game.harbor?.id ?? 0
        VStack(alignment: .leading, spacing: 8) {
            if let k = v.resident(in: port) {
                let r = DS.npc + DS.npcSize * k
                HStack(spacing: 12) {
                    if let img = game.image(String(format: "portraits/%03d.png", v.memory[r + 0x11])) {
                        Image(nsImage: img).pixelated().frame(width: 48, height: 60).clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    Text(v.memory.string(r, max: 16)).font(GameFont.headline)
                }
                let type = v.residentType(k)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                    if type <= 1 {
                        Button(v.contracted(k) ? "계약 중" : "계약") {
                            lines = [game.act { $0.contract(k) } ? game.message(type == 0 ? 483 : 497) : game.message(496)]
                        }.disabled(v.contracted(k))
                    }
                    if type == 0 {
                        Button("발견물보고") { lines = game.act { $0.reportDiscoveries(to: k, in: game.world) } }.disabled(!v.contracted(k))
                        Button("모험이야기") { lines = [game.act { $0.rumour() }] }
                    }
                    if type == 1 {
                        Button("지리보고") {
                            lines = [game.act { $0.reportGeography(to: k) }]
                            chartDone = game.status.worldCharted && lines.first?.hasPrefix("와아") == true
                        }.disabled(!v.contracted(k))
                        Button("지도확인") {                                                      // 0x2D4E3
                            game.question = Question(text: game.message(785)) {
                                if let at = game.act({ $0.checkMap() }) {
                                    lines = [game.message(786), game.message(783) + at + " " + game.message(784)]
                                } else {
                                    lines = [game.message(239)]
                                }
                            }
                        }.disabled(!v.items.contains { (80...89).contains($0) })
                    }
                    if type >= 1 {
                        let o = v.skillOffer(k)
                        Button("\(o.name) 습득 · 금화 \(o.fee)닢") {
                            lines = [game.act { $0.learnSkill(at: k) } ? "\(o.name)을(를) 익혔습니다." : o.ok ? game.message(504) : "능력이 아직 모자랍니다."]
                        }.disabled(v.captain.skills & o.bit != 0)
                    }
                }
            } else {
                Text(game.message(933)).foregroundStyle(.secondary)
            }
            if chartDone, let img = game.image("images/graph_63.png") {
                Image(nsImage: img).pixelated().aspectRatio(contentMode: .fit).frame(maxWidth: 480)
            }
            ForEach(lines, id: \.self) { Text($0).font(GameFont.callout).foregroundStyle(.yellow).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
