#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import PortolanCore

extension Image {
    /// Original art keeps hard pixel edges at any size.
    func pixelated() -> some View { interpolation(.none).resizable() }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .background(LinearGradient(colors: [Theme.navyLight.opacity(0.88), Theme.navy.opacity(0.9)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .environment(\.colorScheme, .dark)
    }
}

/// Stores are counted in tenths of a barrel, as in the original.
struct SupplyGauge: View {
    let title: String
    let units: Int
    let perDay: Int
    let tint: Color
    var width: CGFloat = 158
    var body: some View {
        let days = perDay > 0 ? units / perDay : 0
        let barrels = units / 10
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text("\(barrels)통 · \(days)일분").monospacedDigit().foregroundStyle(.secondary)
            }.font(GameFont.caption)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(days < 3 ? Color.red : tint).frame(width: g.size.width * max(0, min(1, Double(days) / 15)))
                }
            }.frame(height: 5)
        }.frame(width: width)
    }
}

struct CaptainCard: View {
    @ObservedObject var game: Game
    var body: some View {
        Panel {
            HStack(spacing: 12) {
                if let img = game.image("portraits/000.png") {
                    Image(nsImage: img).pixelated().frame(width: 64, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.gold.opacity(0.6), lineWidth: 1.5))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(game.status.captain.name).font(GameFont.headline).foregroundStyle(Theme.gold)
                    Text(game.dateText).font(GameFont.subheadline).foregroundStyle(.secondary)
                    Label("\(game.status.gold) 금화", systemImage: "dollarsign.circle.fill")
                        .font(GameFont.subheadline).foregroundStyle(.yellow).monospacedDigit()
                    Label("선원 \(game.status.crew)명 · \(game.status.ships.first?.name ?? "배 없음")",
                          systemImage: "person.3.fill").font(GameFont.caption)
                }
            }
        }
    }
}

struct MiniMap: View {
    @ObservedObject var game: Game
    var body: some View {
        Panel {
            ZStack(alignment: .topLeading) {
                if let img = game.image("minimap.png") {
                    Image(nsImage: img).resizable().frame(width: 236, height: 118)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.gold.opacity(0.35)))
                }
                Circle().fill(.red).overlay(Circle().stroke(.white, lineWidth: 1)).frame(width: 7, height: 7)
                    .offset(x: game.status.x / Double(World.width) * 236 - 3.5,
                            y: game.status.y / Double(World.height) * 118 - 3.5)
            }.frame(width: 236, height: 118)
        }
    }
}

struct HelmBar: View {
    @ObservedObject var game: Game
    var body: some View {
        let v = game.status
        Panel {
            HStack(spacing: 14) {
                stat("sailboat.fill", "돛", v.sail > 0 ? "펼침" : "접음", v.sail > 0 ? Theme.gold : .white, width: 50)
                stat("speedometer", "속력", String(format: "%.1f노트", v.speed), .white, width: 80)
                stat("face.smiling", "사기", "\(v.morale)", v.morale < Navigation.mutinyMorale ? .red : .white, width: 44)
                stat("calendar", "항해", "\(v.daysAtSea)일째", .white, width: 56)
                SupplyGauge(title: "식수", units: v.water, perDay: v.dailyWater, tint: Theme.wind, width: 124)
                SupplyGauge(title: "식량", units: v.food, perDay: v.dailyFood, tint: .orange, width: 124)
            }
        }
    }

    private func stat(_ symbol: String, _ label: String, _ value: String, _ tint: Color, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.gold.opacity(0.8))
            Text(value).font(.system(size: 16, weight: .bold)).monospacedDigit().foregroundStyle(tint)
        }
        .frame(width: width, alignment: .leading)
    }
}

struct TabEntry: Identifiable {
    let id = UUID()
    let title: String
    var enabled = true
    /// Why a greyed entry cannot be used (shown under it).
    var note: String? = nil
    var action: (() -> Void)?
    var children: [TabEntry] = []
}

extension Game {
    static let tabTitles = ["정보", "편성", "지휘", "항해"]

    /// The commands of tab `t`: 정보 (0x20559), 편성 (0x20703), 지휘 (0x207CF), 항해 (0x208C7),
    /// greyed as the original greys them (in port: 감시 · 교섭 · 전투 and 항구이동 · 정박 · 기항 · 상륙).
    func tabEntries(_ t: Int) -> [TabEntry] {
        let v = status
        let noShips = v.ships.isEmpty, noMates = v.officers.isEmpty
        let inPort = harbor != nil
        let near = inPort ? [] : v.fleetsNearby()
        func fleetName(_ f: Int) -> String {
            let adm = v.memory.fb(f, FleetField.admiral)
            return adm < 120 ? v.memory.person(adm).name : "함대"
        }
        switch t {
        case 0:
            return InfoScreen.menu.map { s in TabEntry(title: s.title, enabled: s.enabled(v, inPort: inPort), action: { [weak self] in self?.info = s }) }
        case 1:
            return [TabEntry(title: "선장변경", enabled: !noShips, action: { [weak self] in self?.command = .captain }),
                    TabEntry(title: "인사변경", enabled: !noMates, action: { [weak self] in self?.showFleet(tab: 1) }),
                    TabEntry(title: "승무원편성", enabled: !noShips, action: { [weak self] in self?.command = .crew }),
                    TabEntry(title: "승무원비율", enabled: !noShips, action: { [weak self] in self?.command = .shares }),
                    TabEntry(title: "함선처분", enabled: !noShips, action: { [weak self] in self?.command = .scuttle }),
                    TabEntry(title: "적하편성", enabled: !noShips, action: { [weak self] in self?.command = .cargo })]
        case 2:
            return [TabEntry(title: "감시", enabled: !inPort, action: { [weak self] in self?.command = .inspect }),
                    TabEntry(title: "교섭", enabled: !near.isEmpty,
                             children: near.map { f in TabEntry(title: fleetName(f), action: { [weak self] in self?.hailFleet(f) }) }),
                    TabEntry(title: "전투", enabled: !near.isEmpty,
                             children: near.map { f in TabEntry(title: fleetName(f), action: { [weak self] in self?.attackFleet(f) }) }),
                    TabEntry(title: "대열변경", enabled: !noShips, action: { [weak self] in self?.command = .formation }),
                    TabEntry(title: "식량할당", enabled: !noShips, action: { [weak self] in self?.showFleet(tab: 3) }),
                    TabEntry(title: "급여설정", enabled: !noMates, action: { [weak self] in self?.command = .pay })]
        default:
            let ports = knownPorts(v).prefix(30).map { p in
                TabEntry(title: portName(p.id), action: { [weak self] in
                    guard let self else { return }
                    if !self.act({ $0.autoSail(to: p, in: self.world) }) { self.say("항로를 찾지 못했습니다.") }
                })
            }
            let portsNote = !v.canAutoSail ? message(855) : inPort ? "항구 안에서는 쓸 수 없습니다." : v.ashore ? "상륙 중에는 쓸 수 없습니다." : nil
            return [TabEntry(title: "항구이동", enabled: v.canAutoSail && !v.ashore && !inPort, note: portsNote, children: Array(ports)),
                    TabEntry(title: v.anchored ? "출항" : "정박", enabled: !v.ashore && !inPort,
                             action: { [weak self] in guard let self else { return }; self.say(self.toggleAnchor()) }),
                    TabEntry(title: "기항", enabled: dockable != nil && !v.ashore && !inPort, action: { [weak self] in self?.dock() }),
                    TabEntry(title: "상륙", enabled: !inPort, action: { [weak self] in self?.goAshore() }),
                    TabEntry(title: "아이템", enabled: !v.items.isEmpty, action: { [weak self] in self?.command = .items }),
                    TabEntry(title: "기능", action: { [weak self] in self?.command = .system })]
        }
    }

    /// Ports the hero knows (port record +0x13 bit 0x10), nearest first.
    func knownPorts(_ v: Voyage) -> [Harbor] {
        world.ports.filter { v.memory[DS.port + DS.portSize * $0.id + 0x13] & 0x10 != 0 }
            .sorted { a, b in
                hypot(world.deltaX(from: v.x, to: Double(a.x)), Double(a.y) - v.y)
                    < hypot(world.deltaX(from: v.x, to: Double(b.x)), Double(b.y) - v.y)
            }
    }
}

struct HelpCard: View {
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("조작", systemImage: "keyboard").gameTitle()
                    Spacer()
                    Text("H로 접기").font(GameFont.caption2).foregroundStyle(.white.opacity(0.4))
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    row("W S", "돛 펴기 · 접기")
                    row("A D", "키 조작")
                    row("클릭", "목적지로 항해")
                    row("Return", "입항")
                    row("+ −", "확대 · 축소")
                    row("Space", "일시정지")
                    row("I", "함대 정보")
                    row("⌘S ⌘O", "저장 · 불러오기")
                }
            }
            .frame(width: 256)
        }
    }

    private func row(_ k: String, _ d: String) -> some View {
        GridRow {
            Text(k)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.18)))
            Text(d).font(GameFont.caption).foregroundStyle(.white.opacity(0.7))
        }
    }
}

struct HUD: View {
    @ObservedObject var game: Game
    var body: some View {
        GeometryReader { geometry in
            if game.harbor == nil && !game.title {
                ZStack {
                    weatherVeil
                    VStack(spacing: 14) {
                        topBar
                        HStack(alignment: .top) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 10) {
                                    nextStep
                                    #if os(macOS)
                                    if game.showHelp { HelpCard() }
                                    #endif
                                }
                            }.frame(width: 280)
                            Spacer(minLength: 20)
                            ScrollView {
                            VStack(alignment: .trailing, spacing: 10) {
                                MiniMap(game: game)
                                if geometry.size.height >= 760 { Panel { HelmDial(game: game) } }
                                if geometry.size.height < 760 {
                                    Panel {
                                        HStack(spacing: 12) {
                                            Label("풍향 " + HelmDial.names[game.status.weather.windDir & 7], systemImage: "wind").foregroundStyle(Theme.wind)
                                            Text("침로 " + HelmDial.names[game.status.heading8 & 7]).foregroundStyle(Theme.current)
                                        }.font(.system(size: 15, weight: .semibold))
                                    }
                                }
                                NearbyFleets(game: game)
                            }.frame(maxWidth: .infinity, alignment: .trailing)
                            }.frame(width: 340)
                        }.frame(maxHeight: .infinity)
                        Spacer(minLength: 0)
                        ScrollView { contextActions }.frame(maxHeight: 82).fixedSize(horizontal: false, vertical: true)
                        statusStrip
                        controls
                    }.padding(16)
                }
            }
        }.environment(\.colorScheme, .dark)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            if let portrait = game.portrait(face: game.status.heroID) {
                Image(nsImage: portrait).pixelated().frame(width: 36, height: 45)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(game.status.captain.name).font(.system(size: 20, weight: .bold))
                Text(game.status.ships.first?.name ?? "기함 없음").font(GameFont.caption).foregroundStyle(.secondary)
            }
            Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 30).padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.dateText).font(.system(size: 15, weight: .medium)).monospacedDigit()
                Label(game.paused ? "일시정지" : game.status.anchored ? "정박 중" : game.status.sail > 0 ? "항해 중" : "돛을 접었습니다", systemImage: game.paused ? "pause.fill" : "sailboat.fill")
                    .font(GameFont.caption).foregroundStyle(Theme.current)
            }
            Spacer()
            Label(game.status.gold.formatted(), systemImage: "circle.circle.fill")
                .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(Theme.gold).monospacedDigit()
            Text("금화").font(GameFont.caption).foregroundStyle(.secondary)
            Button { game.classicMap.toggle() } label: { Image(systemName: game.classicMap ? "square.grid.3x3" : "water.waves") }
                .help(game.classicMap ? "부드러운 바다 그림으로 전환" : "원작 바다 그림으로 전환")
        }.padding(.horizontal, 16).padding(.vertical, 10).gamePanel(radius: 16)
    }

    private var nextStep: some View {
        let advice = game.status.advice(in: game.world)
        return Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("항해 수첩").font(GameFont.caption.bold()).foregroundStyle(Theme.current)
                    Spacer()
                    Image(systemName: "book.closed").foregroundStyle(Theme.current)
                }
                if let id = game.plannedPortID, game.status.waypoint != nil {
                    Text(game.portName(id)).font(.system(size: 23, weight: .bold))
                    Text("목적지로 항해 중").font(GameFont.caption).foregroundStyle(.secondary)
                    Button("항로 취소 · 돛 접기") { game.cancelCourse() }
                } else if let objective = advice.objective {
                    Text(objective.title).font(.system(size: 17, weight: .bold))
                    Text(objective.detail).font(GameFont.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("다음 항구를 향해").font(.system(size: 19, weight: .bold))
                    Text("교역으로 함대를 키우고, 새로운 항구와 발견물을 찾아보세요.")
                        .font(GameFont.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let warning = advice.warnings.first {
                    Label(warning.title, systemImage: "exclamationmark.circle.fill")
                        .font(GameFont.caption.weight(.semibold)).foregroundStyle(warning.severity == .critical ? Color.orange : Theme.gold)
                }
                Button { game.openVoyagePlan() } label: {
                    HStack { Text("항해 계획"); Spacer(); Image(systemName: "arrow.up.right") }
                }.buttonStyle(GameButtonStyle(prominent: true))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusStrip: some View {
        let v = game.status
        let advice = v.advice(in: game.world)
        return HStack(spacing: 0) {
            metric("속력", String(format: "%.1f", v.speed), "노트", "speedometer", .white)
            metric("선원", "\(v.crew)", "명", "person.2.fill", .white)
            metric("사기", "\(v.morale)", "/ 100", "face.smiling", v.morale < Navigation.mutinyMorale ? .orange : Theme.current)
            metric("식수", advice.waterDays.map(String.init) ?? "—", "일분", "drop.fill", (advice.waterDays ?? 99) < 3 ? .orange : Theme.wind)
            metric("식량", advice.foodDays.map(String.init) ?? "—", "일분", "takeoutbag.and.cup.and.straw.fill", (advice.foodDays ?? 99) < 3 ? .orange : Theme.gold)
            metric("항해", "\(v.daysAtSea)", "일째", "sun.horizon", .white)
        }.padding(.vertical, 12).gamePanel(radius: 14)
    }

    private func metric(_ label: String, _ value: String, _ unit: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.72))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 21, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
                Text(unit).font(GameFont.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 18)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { game.paused.toggle() } label: { Label(game.paused ? "계속" : "정지", systemImage: game.paused ? "play.fill" : "pause.fill") }
                .help("Space · 시간 정지 / 계속")
            Button { game.adjustSail(game.voyage.sail > 0 ? -1 : 1) } label: {
                Label(game.status.sail > 0 ? "돛 접기" : "돛 펴기", systemImage: "sailboat")
            }.disabled(game.status.ashore)
            Button { game.showFleet(tab: 0) } label: { Label("함대", systemImage: "person.3") }
                .accessibilityIdentifier("portolan.hud.fleet")
            Button { game.showHelp.toggle() } label: { Image(systemName: "keyboard") }.help("조작 도움말 (H)")
            HStack(spacing: 0) {
                Button { game.setZoom(game.zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.help("축소")
                Button { game.setZoom(game.zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("확대")
            }
            Spacer(minLength: 0)
            CommandBar(game: game)
        }
    }

    private var contextActions: some View {
        VStack(spacing: 6) {
            if let notice = game.notice { banner(notice) }
            if game.status.aground { banner("해안에 막혔습니다. 침로를 바꾸거나 항로를 다시 지정하세요.") }
            if let event = game.status.event, game.status.eventAnnounced {
                banner(event == .storm ? "폭풍우 · 가까운 항구로 대피하세요" : event == .fog ? "짙은 안개 · 주변 함대에 주의하세요" : "무풍 · 바람을 기다립니다")
            }
            HStack {
                if game.status.landingSite != nil || game.status.ashore {
                    Button { game.goAshore() } label: { Label(game.status.ashore ? "상륙지" : "상륙 · 탐색", systemImage: "figure.walk") }
                        .buttonStyle(GameButtonStyle(prominent: true))
                }
                if let port = game.dockable {
                    Button { game.dock() } label: { Label("\(game.portName(port.id)) 입항  ↵", systemImage: "anchor") }
                        .buttonStyle(GameButtonStyle(prominent: true))
                }
            }
        }
    }

    @ViewBuilder private var weatherVeil: some View {
        switch game.status.eventAnnounced ? game.status.event : nil {
        case .storm?: Color(red: 0.05, green: 0.07, blue: 0.12).opacity(0.45).ignoresSafeArea().allowsHitTesting(false)
        case .fog?: Color(white: 0.85).opacity(0.55).ignoresSafeArea().allowsHitTesting(false)
        default: EmptyView()
        }
    }

    private func banner(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .medium)).multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.navy.opacity(0.94), in: Capsule())
    }
}

/// The remaster's colours: navy glass, gold for what is chosen or under way.
enum Theme {
    static let gold = Color(red: 0.91, green: 0.76, blue: 0.48)
    static let goldGradient = LinearGradient(colors: [Color(red: 1, green: 0.87, blue: 0.55), Color(red: 0.82, green: 0.56, blue: 0.2)],
                                             startPoint: .top, endPoint: .bottom)
    static let navy = Color(red: 0.035, green: 0.065, blue: 0.085)
    static let navyLight = Color(red: 0.075, green: 0.125, blue: 0.16)
    static let wind = Color(red: 0.47, green: 0.84, blue: 1)
    static let current = Color(red: 0.37, green: 0.84, blue: 0.75)
}

/// The helm: a compass card to steer by — a click on one of the eight points heads that way
/// (the wheel's pieces, 0x20985) — the heading as a gold needle, the wind and the current as
/// arrows toward where they set, and the sails in the middle (a click sets or furls them).
struct HelmDial: View {
    @ObservedObject var game: Game
    static let side: CGFloat = 196
    static let names = ["북", "북동", "동", "남동", "남", "남서", "서", "북서"]

    var body: some View {
        let v = game.status
        let moving = v.sail > 0 && !v.anchored
        let r = Self.side / 2
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(RadialGradient(colors: [Theme.navyLight, Theme.navy], center: .center, startRadius: 0, endRadius: r))
                Circle().strokeBorder(Theme.gold.opacity(0.6), lineWidth: 2)
                Circle().inset(by: 5).strokeBorder(Theme.gold.opacity(0.18), lineWidth: 1)
                Canvas { ctx, size in ticks(&ctx, size, r) }
                if v.weather.windStrength > 0 {
                    arrow(v.weather.windDir, length: r - 50, width: 3.5, color: Theme.wind)
                }
                if v.weather.currentStrength > 0 {
                    arrow(v.weather.currentDir, length: r - 64, width: 2.5, color: Theme.current)
                }
                needle
                    .rotationEffect(.radians(v.heading + .pi / 2))
                    .animation(.easeOut(duration: 0.25), value: v.heading)
                    .opacity(moving ? 1 : 0.45)
                ForEach(0..<8, id: \.self) { d in point(d, lit: moving && v.heading8 == d, radius: r - 24) }
                sails(moving)
            }
            .frame(width: Self.side, height: Self.side)
            HStack(spacing: 6) {
                chip("wind", v.weather.windStrength > 0 ? "바람 \(Self.names[v.weather.windDir & 7]) \(v.weather.windStrength)" : "바람 없음", Theme.wind)
                chip("water.waves", v.weather.currentStrength > 0 ? "해류 \(Self.names[v.weather.currentDir & 7]) \(v.weather.currentStrength)" : "해류 없음",
                     Theme.current)
            }
        }
        .disabled(v.ashore || game.harbor != nil)
        .help("방위를 누르면 그쪽으로 침로를 잡고, 가운데를 누르면 돛을 펴거나 접습니다.")
    }

    private func ticks(_ ctx: inout GraphicsContext, _ size: CGSize, _ r: CGFloat) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        for k in 0..<72 {
            let a = Double(k) * .pi / 36 - .pi / 2
            let major = k % 9 == 0, mid = k % 3 == 0
            let r0 = r - 9, r1 = r - (major ? 0 : mid ? 4 : 2) - 9 - (major ? 7 : 3)
            var p = Path()
            p.move(to: CGPoint(x: c.x + r0 * cos(a), y: c.y + r0 * sin(a)))
            p.addLine(to: CGPoint(x: c.x + r1 * cos(a), y: c.y + r1 * sin(a)))
            ctx.stroke(p, with: .color(.white.opacity(major ? 0.55 : mid ? 0.3 : 0.16)), lineWidth: major ? 1.6 : 1)
        }
    }

    /// One of the eight points: the cardinal letters, diamonds between; gold when heading there.
    private func point(_ d: Int, lit: Bool, radius: CGFloat) -> some View {
        let a = Double(d) * .pi / 4 - .pi / 2
        return Button { game.act { $0.steer(toward: d) } } label: {
            ZStack {
                Circle().fill(lit ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Color.white.opacity(0.001)))
                if d % 2 == 0 {
                    Text(Self.names[d])
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(lit ? Color.black.opacity(0.85) : d == 0 ? Color(red: 1, green: 0.45, blue: 0.4) : .white.opacity(0.85))
                } else {
                    Image(systemName: "diamond.fill").font(.system(size: 7))
                        .foregroundStyle(lit ? Color.black.opacity(0.85) : .white.opacity(0.45))
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(x: radius * cos(a), y: radius * sin(a))
    }

    private var needle: some View {
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: 0, y: -60))
                p.addLine(to: CGPoint(x: 7, y: 0))
                p.addLine(to: CGPoint(x: -7, y: 0))
                p.closeSubpath()
            }
            .fill(Theme.goldGradient)
            Path { p in
                p.move(to: CGPoint(x: 0, y: 34))
                p.addLine(to: CGPoint(x: 6, y: 0))
                p.addLine(to: CGPoint(x: -6, y: 0))
                p.closeSubpath()
            }
            .fill(Color.white.opacity(0.25))
        }
        .offset(x: Self.side / 2, y: Self.side / 2)
        .frame(width: Self.side, height: Self.side, alignment: .topLeading)
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
    }

    private func arrow(_ dir: Int, length: CGFloat, width: CGFloat, color: Color) -> some View {
        Path { p in
            let c = Self.side / 2
            p.move(to: CGPoint(x: c, y: c))
            p.addLine(to: CGPoint(x: c, y: c - length))
            p.move(to: CGPoint(x: c - 6, y: c - length + 7))
            p.addLine(to: CGPoint(x: c, y: c - length))
            p.addLine(to: CGPoint(x: c + 6, y: c - length + 7))
        }
        .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        .frame(width: Self.side, height: Self.side)
        .rotationEffect(.radians(Double(dir & 7) * .pi / 4))
        .animation(.easeInOut(duration: 0.4), value: dir)
    }

    private func sails(_ moving: Bool) -> some View {
        Button {
            game.adjustSail(moving ? -1 : 1)
        } label: {
            ZStack {
                Circle().fill(moving ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Theme.navy))
                Circle().strokeBorder(moving ? Color.white.opacity(0.5) : Theme.gold.opacity(0.6), lineWidth: 1.5)
                Image(systemName: moving ? "sailboat.fill" : "sailboat")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(moving ? Color.black.opacity(0.8) : Theme.gold)
            }
            .frame(width: 48, height: 48)
            .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func chip(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(GameFont.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
