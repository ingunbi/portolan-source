import SwiftUI
import PortolanCore

/// Title menu (0x16994, MENU 56): Load Data, Start New Game, Environment, Quit Game — over the
/// opening's fleet panorama with the 大航海時代II logo (OPEN.EXE), as a modern title screen.
struct TitleView: View {
    var previewHero: Int?
    @ObservedObject var game: Game
    @State var choosing = false
    @State private var environment = false
    /// 종료: the KOEI logo (GRAPH.DAT 60 and 62) until a key, then back to DOS (0x16987).
    @State private var quitting = false
    @State private var selected = 0
    @State private var shown = false

    private var items: [(title: String, symbol: String, action: () -> Void)] {
        var rows: [(title: String, symbol: String, action: () -> Void)] = [
         ("새 게임", "sailboat.fill", { choosing = true }),
         ("불러오기", "tray.and.arrow.down.fill", { game.load() }),
         ("환경 설정", "slider.horizontal.3", { environment = true })]
        #if os(macOS)
        rows.append(("종료", "power", { quitting = true }))
        #endif
        return rows
    }

    var body: some View {
        ZStack {
            TitleBackdrop(game: game, dim: choosing ? 0.55 : 0)
            if choosing {
                HeroSelectView(game: game, hero: choosing ? previewHero : nil) { choosing = false }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                menu.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: choosing)
        .overlay { if quitting { quitScreen } }
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $environment) { EnvironmentView(game: game) }
        .onAppear {
            if Motion.instant { shown = true } else { withAnimation(.easeOut(duration: 0.9)) { shown = true } }
        }
    }

    /// The screen in bands: the logo, the fleet panorama (TitleBackdrop.band), the menu, the keys.
    private var menu: some View {
        GeometryReader { g in
            let h = g.size.height
            let logoHeight = min(h * 0.13, g.size.width * 0.5 / 5)
            VStack(spacing: 0) {
                Spacer().frame(height: h * 0.045)
                if let logo = game.image("opening/op00_10.png") {
                    Image(nsImage: logo).pixelated()
                        .frame(width: logoHeight * 5, height: logoHeight)
                        .blendMode(.screen)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : -12)
                }
                HStack(spacing: 14) {
                    line
                    Text("PORTOLAN  ·  OPEN SOURCE")
                        .font(.system(size: 12, weight: .semibold, design: .serif))
                        .tracking(5)
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize()
                    Text("ENGINE")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(3)
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Theme.goldGradient, in: Capsule())
                        .fixedSize()
                    line
                }
                .frame(width: logoHeight * 5, height: h * TitleBackdrop.band.top - h * 0.045 - logoHeight)
                .opacity(shown ? 1 : 0)
                Spacer().frame(height: h * TitleBackdrop.band.height + h * 0.025)
                VStack(spacing: max(6, h * 0.01)) {
                    ForEach(items.indices, id: \.self) { i in
                        TitleMenuButton(title: items[i].title, symbol: items[i].symbol, selected: selected == i,
                                        height: max(38, min(54, h * 0.058))) {
                            selected = i
                            items[i].action()
                        }
                        .accessibilityIdentifier("portolan.title.menu.\(i)")
                        .onHover { if $0 { selected = i } }
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 16)
                        .animation(Motion.instant ? nil : .easeOut(duration: 0.5).delay(0.25 + 0.07 * Double(i)), value: shown)
                    }
                }
                Spacer(minLength: 8)
                HStack {
                    HStack(spacing: 14) {
                        KeyHint(keys: "↑ ↓", text: "선택", width: nil)
                        KeyHint(keys: "Return", text: "결정", width: nil)
                    }
                    Spacer()
                    Text("Portolan  ·  오픈소스 엔진 (원작 자료는 직접 준비)")
                        .font(GameFont.caption).foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
            }
            .frame(width: g.size.width, height: g.size.height)
            .background(keys)
        }
    }

    private var line: some View {
        Rectangle().fill(LinearGradient(colors: [.clear, Theme.gold.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing))
            .frame(height: 1)
    }

    /// ↑/↓ move the choice, Return takes it (the original's menu keys).
    private var keys: some View {
        Group {
            Button("") { selected = (selected + items.count - 1) % items.count }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { selected = (selected + 1) % items.count }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { items[selected].action() }.keyboardShortcut(.defaultAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .disabled(environment || quitting)
    }

    private var quitScreen: some View {
        GeometryReader { g in
            let s = min(g.size.width / 640, g.size.height / 400)
            ZStack(alignment: .topLeading) {
                Color.black
                if let a = game.image("images/graph_60.png") {
                    Image(nsImage: a).pixelated().frame(width: a.size.width, height: a.size.height).offset(x: 216, y: 80)
                }
                if let b = game.image("images/graph_62.png") {
                    Image(nsImage: b).pixelated().frame(width: b.size.width, height: b.size.height).offset(x: 184, y: 200)
                }
            }
            .frame(width: 640, height: 400, alignment: .topLeading)
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: 640 * s, height: 400 * s, alignment: .topLeading)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture { quitGame() }
        .background(KeyCatcher { quitGame() })
    }
}

/// The opening's fleet at sea (OPEN.EXE panorama, two water frames): a crisp band across the
/// middle of the screen drifting slowly from side to side, over a blurred copy that fills the rest.
struct TitleBackdrop: View {
    @ObservedObject var game: Game
    var dim: Double = 0
    /// The band's top and height as parts of the screen height.
    static let band = (top: 0.215, height: 0.40)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = Motion.instant ? 0 : tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in draw(&ctx, size, t) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let full = CGRect(origin: .zero, size: size)
        ctx.fill(Path(full), with: .color(Theme.navy))
        let sway = 0.5 - 0.5 * cos(t * 2 * .pi / 140)
        // The ambience: the picture shrunk and drawn huge (a still blur).
        if let soft = game.softImage("opening/pan_ships_0.png") {
            let w = size.height * 4.8
            var c = ctx
            c.opacity = 0.3
            c.draw(Image(nsImage: soft).resizable().interpolation(.high),
                   in: CGRect(x: -(w - size.width) * sway, y: 0, width: w, height: size.height))
        }
        // The band: the panorama in its own pixels, the water's two frames in turn.
        let bandHeight = size.height * Self.band.height
        let scale = max(bandHeight / 200, size.width / 960)
        let w = 960 * scale, h = 200 * scale
        let top = size.height * Self.band.top + (bandHeight - h) / 2
        if let img = game.image(Int(t / 0.45) % 2 == 0 ? "opening/pan_ships_0.png" : "opening/pan_ships_1.png") {
            ctx.draw(Image(nsImage: img).interpolation(.none), in: CGRect(x: -(w - size.width) * sway, y: top, width: w, height: h))
        }
        let edge = Gradient(colors: [Theme.navy.opacity(0.95), Theme.navy.opacity(0)])
        ctx.fill(Path(CGRect(x: 0, y: top, width: size.width, height: h * 0.16)),
                 with: .linearGradient(edge, startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: top + h * 0.16)))
        ctx.fill(Path(CGRect(x: 0, y: top + h * 0.8, width: size.width, height: h * 0.2)),
                 with: .linearGradient(edge, startPoint: CGPoint(x: 0, y: top + h), endPoint: CGPoint(x: 0, y: top + h * 0.8)))
        // A vignette, and the dimming behind the hero select.
        ctx.fill(Path(full), with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.6)]),
                                                   center: CGPoint(x: size.width / 2, y: size.height / 2),
                                                   startRadius: min(size.width, size.height) * 0.3,
                                                   endRadius: max(size.width, size.height) * 0.75))
        if dim > 0 { ctx.fill(Path(full), with: .color(.black.opacity(dim))) }
    }
}

/// Entrance animations and the drifting backdrop stand still (the snapshot harness).
enum Motion {
    nonisolated(unsafe) static var instant = false
}

/// A title menu entry: one width for all, an icon, gold glass when chosen.
struct TitleMenuButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    var height: CGFloat = 54
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 22)
                    .foregroundStyle(selected ? Theme.gold : .white.opacity(0.55))
                Text(title)
                    .font(.system(size: height < 46 ? 17 : 19, weight: .semibold))
                    .foregroundStyle(selected ? .white : .white.opacity(0.78))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.gold)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 20)
            .frame(width: height < 46 ? 290 : 320, height: height)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AnyShapeStyle(LinearGradient(colors: [Theme.gold.opacity(0.32), Theme.navyLight.opacity(0.7)],
                                                                  startPoint: .leading, endPoint: .trailing))
                                   : AnyShapeStyle(Color.black.opacity(0.38)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.gold.opacity(0.85) : .white.opacity(0.1), lineWidth: selected ? 1.5 : 1)
            }
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.goldGradient).frame(width: 4, height: 26).padding(.leading, 6).opacity(selected ? 1 : 0)
            }
            .shadow(color: selected ? Theme.gold.opacity(0.3) : .clear, radius: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(selected ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// Hero select (0x15E5F): six portraits, the info window (0x15C71, luck hidden), "좋습니까?",
/// name entry (0x15DAE) and "모두 좋습니까?".
struct HeroSelectView: View {
    @ObservedObject var game: Game
    @State var hero: Int?
    let back: () -> Void
    @State private var given = ""
    @State private var family = ""
    @State private var naming = false

    /// Skill shown for each hero (DS:0xABA0 into the names at DS:0x874).
    static let skillShown = ["교섭", "포술", "포술", "지도제작", "측량", "회계"]

    var body: some View {
        let m = game.world.memory ?? DataSegment()
        GeometryReader { geometry in
            let compact = geometry.size.height < 680
            let panelWidth = min(1120, geometry.size.width - 48)
            let padding: CGFloat = compact ? 16 : 24
            let spacing: CGFloat = compact ? 10 : 18
            let portraitWidth: CGFloat = compact ? 72 : 100
            let columnWidth = (panelWidth - padding * 2 - 12 * 5) / 6
            VStack(spacing: spacing) {
                Text("주인공을 선택해 주세요")
                    .font(.system(size: compact ? 26 : 28, weight: .bold))
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<6, id: \.self) { h in
                        Button { pick(h, m) } label: {
                            VStack(spacing: compact ? 6 : 10) {
                                if let img = game.image(String(format: "portraits/%03d.png", h)) {
                                    Image(nsImage: img).pixelated()
                                        .frame(width: portraitWidth, height: portraitWidth * 1.25)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hero == h ? Theme.gold : .white.opacity(0.2), lineWidth: hero == h ? 3 : 1))
                                        .shadow(color: hero == h ? Theme.gold.opacity(0.35) : .clear, radius: 8)
                                }
                                Text(m.person(h).name)
                                    .font(.system(size: 16, weight: hero == h ? .bold : .medium))
                                    .foregroundStyle(hero == h ? Theme.gold : .white.opacity(0.9))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .frame(height: 40, alignment: .top)
                            }
                            .frame(width: columnWidth)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("portolan.hero.pick.\(h)")
                        .accessibilityLabel(m.person(h).name)
                        .accessibilityAddTraits(hero == h ? .isSelected : [])
                    }
                }
                ScrollViewReader { reader in
                    ScrollView {
                        if let h = hero {
                            info(h, m, compact: compact).id("hero-info")
                        } else {
                            Text("초상화를 선택하면 인물의 이야기와 능력치를 볼 수 있습니다.")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(maxWidth: .infinity, minHeight: 160)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gameSection()
                    .onChange(of: naming) { _, value in
                        withAnimation(.easeOut(duration: 0.2)) {
                            reader.scrollTo(value ? "hero-name-fields" : "hero-info", anchor: value ? .bottom : .top)
                        }
                    }
                    .onChange(of: hero) { _, _ in reader.scrollTo("hero-info", anchor: .top) }
                }
                footer(m)
            }
            .padding(padding)
            .frame(width: panelWidth, height: min(680, geometry.size.height - (compact ? 24 : 40)))
            .background(LinearGradient(colors: [Theme.navyLight.opacity(0.98), Theme.navy], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.gold.opacity(0.4)))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pick(_ h: Int, _ m: DataSegment) {
        hero = h
        given = m.string(DS.person(h), max: 13)
        family = m.string(DS.person(h) + 0x0D, max: 13)
        naming = false
    }

    private func info(_ h: Int, _ m: DataSegment, compact: Bool) -> some View {
        let p = m.person(h)
        let labels = ["통솔력", "항해술", "지식", "직감", "용기", "검술", "매력"]
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: compact ? 28 : 40) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(p.name).font(.system(size: 24, weight: .bold))
                        .accessibilityIdentifier("portolan.hero.selected")
                        .accessibilityValue(String(h))
                    Text("\(m[DS.person(h) + 0x2A])세 · 기술 \(Self.skillShown[h])")
                        .font(.system(size: 17)).foregroundStyle(.white.opacity(0.8))
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        ForEach(0..<4, id: \.self) { r in
                            GridRow {
                                ForEach([r, r + 4], id: \.self) { k in
                                    if k < 7 {
                                        Text(labels[k]).foregroundStyle(.white.opacity(0.8))
                                        Text("\(p.stats[k])").fontWeight(.semibold).monospacedDigit()
                                    }
                                }
                            }
                        }
                    }.font(.system(size: 18))
                }
                .frame(width: compact ? 280 : 310, alignment: .leading)
                Text(game.message(50 + h))
                    .font(.system(size: 18))
                    .lineSpacing(5)
                    .foregroundStyle(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if naming {
                Divider()
                Text("이름을 바꾸려면 새 이름을 입력하세요. 그대로 쓰려면 건드리지 마세요.")
                    .font(.system(size: 17)).foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 14) {
                    Text("이름")
                    TextField("이름", text: $given).frame(width: 160)
                        .accessibilityIdentifier("portolan.hero.given")
                    Text("성")
                    TextField("성", text: $family).frame(width: 160)
                        .accessibilityIdentifier("portolan.hero.family")
                }
                .font(.system(size: 18))
                .textFieldStyle(.roundedBorder)
                .id("hero-name-fields")
            }
        }
        .padding(compact ? 16 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(_ m: DataSegment) -> some View {
        HStack(spacing: 14) {
            Button("돌아가기") { back() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("portolan.hero.back")
            Spacer()
            if let h = hero {
                Text(naming ? "모두 좋습니까?" : game.message(947))
                    .font(.system(size: 18))
                Button("예") {
                    if naming {
                        game.startNewGame(hero: h, given: String(given.prefix(6)), family: String(family.prefix(6)))
                    } else {
                        naming = true
                    }
                }
                .buttonStyle(GameButtonStyle(prominent: true, fontSize: 18))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("portolan.hero.confirm")
                Button("아니오") {
                    if naming { pick(h, m) } else { hero = nil }
                }
                .accessibilityIdentifier("portolan.hero.cancel")
            }
        }
        .buttonStyle(GameButtonStyle(fontSize: 18))
        .frame(minHeight: 42)
    }

}

/// Environment (0x20E97): BGM and display effects on or off (`[0xC30]` bits 0x04, 0x01) and the
/// sea speed (`[0xC32]`, 0...10). Mouse and scroll settings have no use here.
struct EnvironmentView: View {
    @ObservedObject var game: Game
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let m = game.status.memory
        VStack(alignment: .leading, spacing: 14) {
            Text("환경").font(GameFont.title2.bold())
            Toggle("ＢＧＭ", isOn: Binding(get: { m[0xC30] & 4 != 0 }, set: { on in game.setOption(0x04, on) }))
            Toggle("표시효과", isOn: Binding(get: { m[0xC30] & 1 != 0 }, set: { on in game.setOption(0x01, on) }))
            Toggle("효과음", isOn: Binding(get: { m[0xC30] & 8 != 0 }, set: { on in game.setOption(0x08, on) }))
            Toggle("원작 바다 그림", isOn: $game.classicMap)
            Toggle("원작 화면 배치", isOn: $game.classicLayout)
            Toggle("영문 화면 틀 (TYPE 1)", isOn: Binding(get: { m[0xC30] & 0x80 != 0 }, set: { on in game.setOption(0x80, on) }))
            HStack {
                Text("해상이동치")
                Slider(value: Binding(get: { Double(m[0xC35]) }, set: { game.setScrollMargin(Int($0.rounded())) }), in: 0...10)
                Text("\(m[0xC35] * 10)%").monospacedDigit().frame(width: 64)
            }
            .help("원작 화면 배치에서 바다 지도 창이 함대를 따라 움직이기 전의 여유 칸 수")
            HStack {
                Text("해상속도")
                Slider(value: Binding(get: { Double(m[0xC32]) }, set: { game.setSeaSpeed(Int($0.rounded())) }), in: 0...10)
                Text("\(m[0xC32] * 10)%").monospacedDigit().frame(width: 64)
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .font(GameFont.body)
    }
}
