import SwiftUI
import PortolanCore

/// The 정보 menu (MENU 26, 0x20559), the same at sea and in port, and the treasure map view
/// (item use 80–89, 0x1D6EF). docs/re/info.md §1.
enum InfoScreen: Hashable {
    case fleet, ship, person, hero, cargo, cargoList, discoveries, chart, logbook, portMap
    case treasure(Int)

    static let menu: [InfoScreen] = [.fleet, .ship, .person, .hero, .cargo, .cargoList, .discoveries, .chart, .logbook, .portMap]

    var title: String {
        switch self {
        case .fleet: return "자함대정보"
        case .ship: return "함선정보"
        case .person: return "인물정보"
        case .hero: return "주인공정보"
        case .cargo: return "적하정보"
        case .cargoList: return "적하일람"
        case .discoveries: return "발견물정보"
        case .chart: return "항해도"
        case .logbook: return "항해일지"
        case .portMap: return "항구지도"
        case .treasure: return "보물지도"
        }
    }

    /// Greying of MENU 26 (0x20559).
    func enabled(_ v: Voyage, inPort: Bool) -> Bool {
        switch self {
        case .fleet, .ship: return !v.ships.isEmpty
        case .cargo, .cargoList: return !v.ships.isEmpty && !v.goodsTotals.isEmpty
        case .discoveries: return !v.foundSites.isEmpty
        case .chart: return v.memory.word(Discovery.chartedTotal) > 0
        case .logbook: return !v.logbook.isEmpty
        case .portMap: return inPort
        default: return true
        }
    }
}

/// The 정보 menu items, for the sea command bar and the harbour.
struct InfoMenuItems: View {
    @ObservedObject var game: Game
    var body: some View {
        ForEach(InfoScreen.menu, id: \.self) { s in
            Button(s.title) { game.info = s }.disabled(!s.enabled(game.status, inPort: game.harbor != nil))
        }
    }
}

struct InfoView: View {
    @ObservedObject var game: Game
    let screen: InfoScreen

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { game.info = nil }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(screen.title).font(.system(size: 26, weight: .bold, design: .serif))
                        Spacer()
                        Button { game.info = nil } label: { Image(systemName: "xmark.circle.fill").font(GameFont.title2) }
                            .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("portolan.info.close")
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            switch screen {
                            case .fleet: FleetScreen(game: game)
                            case .ship: ShipScreen(game: game)
                            case .person: PersonScreen(game: game)
                            case .hero: HeroScreen(game: game)
                            case .cargo: CargoScreen(game: game)
                            case .cargoList: CargoListScreen(game: game)
                            case .discoveries: DiscoveryScreen(game: game)
                            case .chart: ChartScreen(game: game)
                            case .logbook: LogbookScreen(game: game)
                            case .portMap: PortMapScreen(game: game)
                            case .treasure(let item): TreasureMapScreen(game: game, item: item)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: .infinity)
                        .accessibilityIdentifier("portolan.info.content")
                }
                .padding(24)
                .frame(width: min(920, geometry.size.width - 32), height: min(700, geometry.size.height - 32))
                .gamePanel()
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// A labelled bar as on the ship and person screens (0x8F08).
private struct StatBar: View {
    let label: String
    let value: Int
    let max: Int
    var body: some View {
        HStack {
            Text(label).font(GameFont.caption.monospaced()).frame(width: 120, alignment: .leading)
            Text("\(value)/\(max)").monospacedDigit().frame(width: 110, alignment: .trailing)
            ProgressView(value: Double(min(value, Swift.max(max, 1))), total: Double(Swift.max(max, 1))).frame(maxWidth: .infinity)
        }.font(GameFont.callout)
    }
}

/// 자함대정보 (0x1CAB2).
private struct FleetScreen: View {
    @ObservedObject var game: Game
    var body: some View {
        let v = game.status
        let sum = v.fleetSummary(in: game.world)
        let family = v.memory.string(DS.person(v.heroID) + 0x0D, max: 13)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                if let img = game.portrait(person: v.heroID) {
                    Image(nsImage: img).pixelated().frame(width: 64, height: 80).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(family)제독").font(GameFont.title3.bold())
                    Text("항해 레벨: \(v.captain.navLevel)   전투 레벨: \(v.captain.battleLevel)").monospacedDigit()
                }
            }
            if v.ships.isEmpty { Text(game.message(918)) } else { panorama(v) }
            ForEach(v.ships.indices, id: \.self) { i in
                let s = v.ships[i]
                HStack {
                    Text(s.name + "호").fontWeight(.semibold).frame(width: 150, alignment: .leading)
                    Text(game.world.navigation.classes[s.classIndex].name).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                    Text("내구 \(s.hull) · 선원 \(s.crew) · 대포 \(s.guns)").monospacedDigit()
                }.font(GameFont.callout)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow { Text("함대선회력: \(sum.rudder)"); Text("선원 총수: \(sum.crew)명") }
                GridRow { Text("함대추진력: \(sum.sail)"); Text("총포문수 : \(sum.guns)") }
                GridRow { Text("함대내구력: \(sum.hull)"); Text("전투력   : \(sum.power)") }
            }.monospacedDigit().padding(.top, 6)
        }
    }
}

extension FleetScreen {
    /// 0x1CAB2: the 16×16 sea tile over 40×20 cells, ship i's class picture at DS:0xAFF0 + 2i.
    func panorama(_ v: Voyage) -> some View {
        let slots: [(Double, Double)] = [(256, 160), (384, 64), (128, 64), (256, 16), (128, 208), (384, 208), (0, 16), (0, 160), (512, 16), (512, 160)]
        return ZStack(alignment: .topLeading) {
            if let tile = game.image("sprites/ships/fleet_sea_tile.png") {
                Rectangle().fill(ImagePaint(image: Image(nsImage: tile).interpolation(.none), scale: 1)).frame(width: 640, height: 320)
            }
            ForEach(Array(v.ships.prefix(10).enumerated()), id: \.offset) { i, s in
                if let img = game.image(String(format: "sprites/ships/class_%02d.png", s.classIndex)) {
                    Image(nsImage: img).pixelated().frame(width: 128, height: 96).offset(x: slots[i].0, y: slots[i].1)
                }
            }
        }
        .frame(width: 640, height: 320, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .scaleEffect(0.95, anchor: .topLeading)
        .frame(width: 608, height: 304, alignment: .topLeading)
    }
}

/// 함선정보 (0x1BB79).
private struct ShipScreen: View {
    @ObservedObject var game: Game
    @State private var ship = 0

    var body: some View {
        let v = game.status
        let i = min(ship, max(0, v.ships.count - 1))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("배")
                GamePicker("배", selection: $ship, options: v.ships.indices.map { ($0, v.ships[$0].name) })
            }.frame(width: 280)
            if v.ships.indices.contains(i) { detail(v, i) }
        }
    }

    @ViewBuilder
    private func detail(_ v: Voyage, _ i: Int) -> some View {
        let s = v.ships[i]
        let nav = game.world.navigation
        let c = nav.classes[s.classIndex]
        let sail = s.crew * s.sailorShare / 100, watch = s.crew * s.watchShare / 100
        let load = v.loadPercent(i, in: game.world)
        let labels = game.menus.indices.contains(41) ? game.menus[41] : ["HULL", "RUDDER", "SAILS", "CREW", "CONDITION", "CARGO", "CAPACITY"]
        HStack(spacing: 14) {
            // The class picture, the figurehead and the four store icons (0x1BB79).
            if let img = game.image(String(format: "sprites/ships/class_%02d.png", s.classIndex)) {
                Image(nsImage: img).pixelated().frame(width: 192, height: 144).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if s.figurehead > 0, let img = game.image(String(format: "sprites/figureheads/figurehead_%02d.png", s.figurehead)) {
                Image(nsImage: img).pixelated().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(0..<2, id: \.self) { r in
                    GridRow {
                        ForEach(0..<2, id: \.self) { k in
                            let n = 2 * r + k
                            HStack(spacing: 4) {
                                if let img = game.image("sprites/ships/cargo_\(n).png") { Image(nsImage: img).pixelated().frame(width: 16, height: 32) }
                                Text("\([s.water / 10, s.food / 10, s.lumber, s.shot][n])").monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(c.name)급").foregroundStyle(.secondary)
                Text(s.name + "호").font(GameFont.title3.bold())
                Text("선장  \(i == 0 ? v.captain.name : v.officers.indices.contains(i - 1) ? v.officers[i - 1].name : "—")")
                Text("무장  \(v.memory.name(0x808, s.gunType))" + (s.gunType == 0 ? "" : "  \(s.guns)/\(s.gunCapacity)"))
                Text("운항 \(sail)명 · 파수 \(watch)명 · 갑판 \(s.crew - sail - watch)명").monospacedDigit()
                Text("운항요원  \(c.minCrew)명").monospacedDigit()
                Text("적재율  \(load)%").monospacedDigit().foregroundStyle(load > 79 ? Color.red : load > 30 ? .yellow : .primary)
                Text("속도  \(v.shipKnots(i, in: game.world))KT").monospacedDigit()
                if s.figurehead > 0 { Text("선수상  \(Shipyard.figureheadNames[s.figurehead])") }
            }
            VStack(alignment: .leading, spacing: 4) {
                StatBar(label: labels[0], value: s.hull, max: s.maxHull)
                StatBar(label: labels[1], value: s.rudder, max: c.rudder)
                StatBar(label: labels[2], value: s.sail, max: c.sail)
                StatBar(label: labels[3], value: s.crew, max: s.crewCapacity)
                StatBar(label: labels[4], value: s.morale, max: 100)
                StatBar(label: labels[5], value: s.cargoLoad, max: s.cargoCapacity)
                StatBar(label: labels[6], value: s.load, max: c.capacity)
            }
        }
    }
}

/// 인물정보 (0x1C215): luck is not shown.
private struct PersonScreen: View {
    @ObservedObject var game: Game
    @State private var who = -1

    var body: some View {
        let v = game.status
        let k = who
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("인물")
                GamePicker("인물", selection: $who,
                           options: [(-1, v.captain.name)] + v.officers.indices.map { ($0, v.officers[$0].name) })
            }.frame(width: 280)
            detail(v, v.officers.indices.contains(k) ? k : -1)
        }
    }

    private func detail(_ v: Voyage, _ k: Int) -> some View {
        let m = v.memory
        let p = k < 0 ? v.heroID : v.officers[k].person
        let r = DS.person(p)
        let stats = k < 0 ? Array(v.captain.stats.prefix(7)) : Array(v.officers[k].stats.prefix(7))
        let skills = k < 0 ? v.captain.skills : v.officers[k].skills
        let nation = k < 0 ? v.captain.nation : m[r + 0x31] & 0xF
        let ship = k < 0 ? 0 : k < v.ships.count - 1 ? k + 1 : 0
        let role = k < 0 ? "제독" : k < v.ships.count - 1 ? "선장" : v.officers[k].post?.name ?? "항해사"
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                if let img = game.portrait(person: p) {
                    Image(nsImage: img).pixelated().frame(width: 64, height: 80).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if v.ships.indices.contains(ship) { Text(v.ships[ship].name + "호") }
                Text(role).foregroundStyle(.yellow)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(k < 0 ? v.captain.name : v.officers[k].name).font(GameFont.title3.bold())
                Text("연령: \(m[r + 0x2A])세").monospacedDigit()
                ForEach(0..<7, id: \.self) { i in
                    HStack {
                        Text(m.name(0x87E, i)).frame(width: 60, alignment: .leading)
                        ProgressView(value: Double(min(100, stats[safe: i] ?? 0)), total: 100).frame(width: 160)
                        Text("\(stats[safe: i] ?? 0)").monospacedDigit()
                    }.font(GameFont.callout)
                }
            }
            }
            VStack(alignment: .leading, spacing: 4) {
                if k < 0 {
                    Text("작위／ " + (v.rank > 0 ? Town.title(rank: v.rank, hero: v.heroID) : "없음"))
                } else {
                    Text("급료／ 금화\(v.officers[k].salary)닢")
                }
                Text("항해 레벨: \(k < 0 ? v.captain.navLevel : v.officers[k].navLevel)   경험: \(k < 0 ? v.captain.navExp : v.officers[k].navExp)")
                Text("전투 레벨: \(k < 0 ? v.captain.battleLevel : v.officers[k].battleLevel)   경험: \(k < 0 ? v.captain.battleExp : m.word(r + 0x28))")
                Text("국적／ \(m.name(0x866, min(6, nation)))")
                Text("기능")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(0..<5, id: \.self) { i in
                        Text(m.name(0x874, i)).foregroundStyle(skills & (0x10 >> i) != 0 ? Color.yellow : Color.gray.opacity(0.7))
                    }
                }
            }.monospacedDigit().font(GameFont.callout)
        }
    }
}

/// 주인공정보 (0x1C5E5).
private struct HeroScreen: View {
    @ObservedObject var game: Game
    var body: some View {
        let v = game.status
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 6) {
                Text("소지금").font(GameFont.headline)
                Text("금화: \(v.gold % 10000)").monospacedDigit()
                Text("금괴: \(v.gold / 10000)").monospacedDigit()
                Text("명성").font(GameFont.headline).padding(.top, 8)
                ForEach(0..<3, id: \.self) { i in
                    Text("\(game.menu(42, i)): \(v.fame[i])").monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("공헌도").font(GameFont.headline)
                ForEach(0..<6, id: \.self) { n in
                    HStack {
                        Text(v.memory.name(0x866, n)).frame(width: 110, alignment: .leading)
                        Text("\(abs(v.standing[n] - 100))").monospacedDigit()
                            .foregroundStyle(v.standing[n] < 100 ? Color.red : .primary)
                    }
                }
            }
        }
    }
}

/// 적하정보 (0x1C742).
private struct CargoScreen: View {
    @ObservedObject var game: Game
    var body: some View {
        let v = game.status
        VStack(alignment: .leading, spacing: 10) {
            if v.ships.allSatisfy({ $0.holds.isEmpty }) {
                Text("실려 있는 교역품이 없습니다.").foregroundStyle(.secondary)
            }
            ForEach(v.ships.indices, id: \.self) { i in
                let s = v.ships[i]
                if !s.holds.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name + "호").fontWeight(.semibold)
                        ForEach(s.holds.indices, id: \.self) { k in
                            HStack {
                                Text(game.world.navigation.goods[s.holds[k].good].name).frame(width: 120, alignment: .leading)
                                Text("\(s.holds[k].amount)").monospacedDigit()
                            }.font(GameFont.callout)
                        }
                    }
                }
            }
        }
    }
}

/// 적하일람 (0x1C8CC): totals, and where the goods sold best (msgs 848–850).
private struct CargoListScreen: View {
    @ObservedObject var game: Game
    @State private var line = ""

    var body: some View {
        let v = game.status
        VStack(alignment: .leading, spacing: 6) {
            if v.goodsTotals.isEmpty {
                Text("실려 있는 교역품이 없습니다.").foregroundStyle(.secondary)
            }
            ForEach(v.goodsTotals, id: \.good) { t in
                Button {
                    advise(v, t.good)
                } label: {
                    HStack {
                        Text(game.world.navigation.goods[t.good].name).frame(width: 140, alignment: .leading)
                        Text("\(t.amount)").monospacedDigit()
                    }
                }.buttonStyle(.plain)
            }
            if !line.isEmpty { Text(line).foregroundStyle(.yellow).padding(.top, 6) }
        }
    }

    private func advise(_ v: Voyage, _ g: Int) {
        let name = game.world.navigation.goods[g].name
        let port = game.portName(v.bestMarket(for: g, in: game.world))
        guard let who = v.cargoAdviser() else {
            line = ""
            return
        }
        if who.name == nil {
            line = game.fill(848, name, port)
        } else {
            line = "\(who.name!): " + (who.knows ? game.fill(849, name, port) : game.fill(850, name))
        }
    }
}

/// 발견물정보 (0x1CA4E → 0x33F3C).
private struct DiscoveryScreen: View {
    @ObservedObject var game: Game
    @State private var pick: Int?

    var body: some View {
        let v = game.status
        HStack(alignment: .top, spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(v.foundSites, id: \.self) { i in
                        Button(game.world.discoveryInfo(i).name) { pick = i }
                            .buttonStyle(.plain)
                            .foregroundStyle(pick == i ? Color.yellow : .primary)
                    }
                }
            }.frame(width: 200, height: 360)
            if let i = pick {
                let d = game.world.discoveryInfo(i)
                VStack(alignment: .leading, spacing: 8) {
                    if let img = game.image(String(format: "pictures/%03d.png", d.picture)) {
                        Image(nsImage: img).pixelated().frame(width: 144, height: 144)
                    }
                    Text(d.name).font(GameFont.title3.bold())
                    Text("（\(v.siteCategory(i))）  중요도\(v.siteGrade(i))").foregroundStyle(.secondary)
                    Text(d.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Parchment colours of the chart palette DS:0xAF50.
enum ChartColor {
    static let sea = Color(red: 0xFF / 255, green: 0xCC / 255, blue: 0xAA / 255)
    static let land = Color(red: 0xAA / 255, green: 0x88 / 255, blue: 0x66 / 255)
    static let fog = Color(red: 0xDD / 255, green: 0xAA / 255, blue: 0x88 / 255)
    static let fleet = Color(red: 0xBB / 255, green: 0x99 / 255, blue: 0x88 / 255)
}

private func explored(_ m: DataSegment, col: Int, row: Int) -> Bool {
    guard (0..<45).contains(row) else { return false }
    let c = ((col % 90) + 90) % 90
    return m[0xD74 + 12 * row + c / 8] & (0x80 >> (c & 7)) != 0
}

/// 항해도 (0x1D447): GRAPH.DAT picture 25 with the explored cells, turned 30 cells east.
private struct ChartScreen: View {
    @ObservedObject var game: Game
    @State private var zoom: (col: Int, row: Int)?

    var body: some View {
        let v = game.status
        if let z = zoom {
            VStack(alignment: .leading) {
                ChartZoom(game: game, col: z.col, row: z.row, fog: true, mark: nil)
                Button("돌아가기") { zoom = nil }
            }
        } else if let img = game.image("images/chart.png") {
            let scale = 852.0 / 640
            ZStack(alignment: .topLeading) {
                Image(nsImage: img).pixelated().frame(width: 640 * scale, height: 400 * scale)
                Canvas { ctx, _ in
                    for row in 0..<45 {
                        for col in 0..<90 where !explored(v.memory, col: col, row: row) {
                            let dc = (col + 30) % 90
                            ctx.fill(Path(CGRect(x: (50 + 6.0 * Double(dc)) * scale, y: (50 + 6.0 * Double(row)) * scale,
                                                 width: 6 * scale, height: 6 * scale)), with: .color(ChartColor.fog))
                        }
                    }
                    let fx = 50 + Double(((Int(v.x) + 720) % 2160 - 12) / 4), fy = 50 + Double((Int(v.y) - 12) / 4)
                    ctx.fill(Path(CGRect(x: fx * scale, y: fy * scale, width: 6 * scale, height: 6 * scale)), with: .color(.red))
                }
                .frame(width: 640 * scale, height: 400 * scale)
                .contentShape(Rectangle())
                .onTapGesture { p in
                    let dc = Int((p.x / scale - 50) / 6), row = Int((p.y / scale - 50) / 6)
                    guard (0..<90).contains(dc), (0..<45).contains(row) else { return }
                    let col = (dc - 30 + 90) % 90
                    let any = (0...1).contains { dx in (0...1).contains { dy in explored(v.memory, col: col + dx, row: row + dy) } }
                    if any { zoom = (col, row) }
                }
            }
            Text("탐험한 해역을 누르면 확대합니다.").font(GameFont.caption).foregroundStyle(.secondary)
        }
    }
}

/// Four 24×24-tile cells at 8 px a tile (0x1D251), as the chart zoom and the treasure map draw them.
private struct ChartZoom: View {
    @ObservedObject var game: Game
    let col: Int
    let row: Int
    let fog: Bool
    let mark: (x: Int, y: Int)?

    var body: some View {
        let m = game.status.memory
        let w = game.world
        Canvas { ctx, _ in
            for dy in 0..<2 {
                for dx in 0..<2 {
                    let c = (col + dx) % 90, r = row + dy
                    let open = !fog || explored(m, col: c, row: r)
                    for ty in 0..<24 {
                        for tx in 0..<24 {
                            let x = c * 24 + tx, y = r * 24 + ty
                            let sea = !open || w.isSea(x: Double(x) + 0.5, y: Double(y) + 0.5)
                            ctx.fill(Path(CGRect(x: Double(dx * 192 + tx * 8), y: Double(dy * 192 + ty * 8), width: 8, height: 8)),
                                     with: .color(sea ? ChartColor.sea : ChartColor.land))
                        }
                    }
                }
            }
            if let mk = mark {
                let px = Double(((mk.x - col * 24) % 2160 + 2160) % 2160) * 8, py = Double(mk.y - row * 24) * 8
                var p = Path()
                p.move(to: CGPoint(x: px - 6, y: py - 6)); p.addLine(to: CGPoint(x: px + 22, y: py + 22))
                p.move(to: CGPoint(x: px + 22, y: py - 6)); p.addLine(to: CGPoint(x: px - 6, y: py + 22))
                ctx.stroke(p, with: .color(.red), lineWidth: 4)
            }
        }
        .frame(width: 384, height: 384)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// The treasure map (0x1D6EF): the four cells around the site, without fog, and an X.
private struct TreasureMapScreen: View {
    @ObservedObject var game: Game
    let item: Int

    var body: some View {
        let m = game.status.memory
        let site = m[TownDS.item(item) + 0x18]
        let a = Discovery.site(site)
        let x = m.word(a), y = m.word(a + 2)
        let col = x % 24 < 12 ? (x / 24 + 89) % 90 : x / 24
        let row = y % 24 < 12 && y / 24 != 0 ? y / 24 - 1 : y / 24
        ChartZoom(game: game, col: col, row: row, fog: false, mark: (x, y))
    }
}

/// 항해일지 (0x1DCA8): six lines a page, opening on the last page.
private struct LogbookScreen: View {
    @ObservedObject var game: Game
    @State private var page: Int?

    var body: some View {
        let v = game.status
        let n = v.logbook.count
        let last = max(0, (n - (n > 0 ? 1 : 0)) / 6)
        let p = min(page ?? last, last)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(v.logbook.indices.filter { $0 / 6 == p }, id: \.self) { k in
                let e = v.logbook[k]
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%4d/%2d/%2d", e.year, e.month, e.day)).monospacedDigit().foregroundStyle(.secondary)
                    Text(v.logText(e, messages: game.messages, world: game.world)).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if p > 0 { Button(game.message(1147)) { page = p - 1 } }
                Spacer()
                if p < last { Button(game.message(1148)) { page = p + 1 } }
            }
        }.frame(minHeight: 280, alignment: .top)
    }
}

/// 항구지도 (0x1D930): the town map with the building names over their doors.
private struct PortMapScreen: View {
    @ObservedObject var game: Game
    private struct Maps: Decodable {
        struct Port: Decodable {
            let port: Int
            let map: Int
            let doors: [String: [Int]]
        }
        let buildings: [String]
        let ports: [Port]
    }
    private static var cache: Maps?

    var body: some View {
        let id = game.harbor?.id ?? 0
        let maps = load()
        let entry = maps?.ports.first { $0.port == id }
        let side = 600.0, scale = side / 1536
        ZStack(alignment: .topLeading) {
            if let e = entry, let img = game.image(String(format: "portmaps/%03d.png", e.map)) {
                Image(nsImage: img).pixelated().frame(width: side, height: side)
                ForEach(Array((maps?.buildings ?? []).enumerated()), id: \.offset) { k, name in
                    if k != 7, let d = e.doors[name], d.count == 2 {
                        Text(game.menu(58, k).isEmpty ? name : game.menu(58, k))
                            .font(GameFont.caption2.bold())
                            .padding(.horizontal, 3)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                            .fixedSize()
                            .position(x: (Double(d[0]) * 16 + 16) * scale, y: (Double(d[1]) * 16 - 10) * scale)
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .clipped()
    }

    private func load() -> Maps? {
        if let c = Self.cache { return c }
        guard let d = try? Data(contentsOf: game.assets.appendingPathComponent("portmaps/portmaps.json")),
              let m = try? JSONDecoder().decode(Maps.self, from: d) else { return nil }
        Self.cache = m
        return m
    }
}
