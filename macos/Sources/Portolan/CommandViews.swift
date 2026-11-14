import SwiftUI
import PortolanCore

/// The commands of the 편성 (menu 27), 지휘 (menu 28) and 항해 (menu 29) menus that open a
/// window of their own (docs/re/commands.md).
enum FleetCommand: Int, Identifiable {
    case captain, crew, shares, scuttle, cargo, inspect, formation, pay, items, system
    var id: Int { rawValue }
    var title: String {
        ["선장변경", "승무원편성", "승무원비율", "함선처분", "적하편성", "감시", "대열변경", "급여설정", "아이템", "기능"][rawValue]
    }
}

/// A party ashore on open coast (menu 36): the tile, and the water roll made on landing.
struct CoastLanding {
    let x: Int
    let y: Int
    let water: Bool
}

struct CommandSheet: View {
    @ObservedObject var game: Game
    let command: FleetCommand
    @State private var lines: [String] = []
    @State private var pool = CrewPool()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(command.title).font(.system(size: 26, weight: .bold, design: .serif))
                        Spacer()
                        Button { close() } label: { Image(systemName: "xmark.circle.fill").font(GameFont.title2) }
                            .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("portolan.command.close")
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            switch command {
                            case .captain: CaptainChange(game: game, lines: $lines)
                            case .crew: CrewMove(game: game, pool: $pool)
                            case .shares: CrewShares(game: game)
                            case .scuttle: Scuttle(game: game, lines: $lines)
                            case .cargo: CargoMove(game: game, lines: $lines)
                            case .inspect: Inspect(game: game, lines: $lines)
                            case .formation: Formation(game: game)
                            case .pay: PaySetting(game: game, lines: $lines)
                            case .items: ItemUse(game: game, lines: $lines)
                            case .system: SystemMenu(game: game)
                            }
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                                Text(l).font(GameFont.callout).foregroundStyle(.yellow).fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    .accessibilityIdentifier("portolan.command.content")
                }
                .padding(24)
                .frame(width: min(900, geometry.size.width - 40), height: min(680, geometry.size.height - 32))
                .gamePanel()
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Sailors left in the pool are let go (msg 231).
    private func close() {
        if command == .crew && pool.sailors > 0 {
            game.question = Question(text: game.message(231)) { game.command = nil }
            return
        }
        game.command = nil
    }
}

/// The person in command of ship `i`: the hero on the flagship, else officer `i − 1`.
private func captainName(_ v: Voyage, _ i: Int) -> String {
    i == 0 ? v.captain.name : v.officers.indices.contains(i - 1) ? v.officers[i - 1].name : "—"
}

/// 선장변경 (0x1E3C6).
private struct CaptainChange: View {
    @ObservedObject var game: Game
    @Binding var lines: [String]

    var body: some View {
        let v = game.status
        let people = [(v.heroID, v.captain.name)] + v.officers.map { ($0.person, $0.name) }
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(v.ships.indices, id: \.self) { i in
                GridRow {
                    Text(v.ships[i].name + "호").fontWeight(.semibold)
                    Text(i == 0 ? "기함" : "").foregroundStyle(.yellow)
                    GamePicker("선장", selection: Binding(
                        get: { i == 0 ? v.heroID : v.officers.indices.contains(i - 1) ? v.officers[i - 1].person : -1 },
                        set: { p in
                            if game.act({ $0.changeCaptain(ship: i, to: p) }) {
                                lines = [Korean.particles("\(captainName(game.status, p == v.heroID ? 0 : i))(가) 선장이 되었습니다.")]
                            }
                        }), options: people)
                        .frame(width: 260)
                }
            }
        }
    }
}

/// 승무원편성 (0x1E8E7): sailors go into a pool and out to other ships.
private struct CrewMove: View {
    @ObservedObject var game: Game
    @Binding var pool: CrewPool

    var body: some View {
        let v = game.status
        VStack(alignment: .leading, spacing: 10) {
            Text("남은 승무원 \(pool.sailors)명").font(GameFont.headline).monospacedDigit()
            ForEach(v.ships.indices, id: \.self) { i in
                let s = v.ships[i]
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        Text(s.name + "호").fontWeight(.semibold)
                        Text("\(s.crew) / \(s.crewCapacity)명").monospacedDigit()
                        Text("사기 \(s.morale)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        ForEach([-10, -1, 1, 10], id: \.self) { d in
                            Button(d > 0 ? "+\(d)" : "\(d)") { set(i, s.crew + d) }
                                .accessibilityIdentifier("portolan.crew.\(i).delta.\(d)")
                        }
                        Button("전원") { set(i, min(s.crewCapacity, s.crew + pool.sailors)) }
                            .accessibilityIdentifier("portolan.crew.\(i).all")
                        Button("0") { set(i, 0) }
                            .accessibilityIdentifier("portolan.crew.\(i).none")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .gameSection()
            }
        }
    }

    private func set(_ i: Int, _ n: Int) {
        var p = pool
        let s = game.status.ships[i]
        let target = max(0, min(n, s.crew + p.sailors, s.crewCapacity))
        if game.act({ $0.setCrew(ship: i, to: target, pool: &p) }) { pool = p }
    }
}

/// 승무원비율 (0x1ECE2): 운항, 파수 and 갑판 shares of each ship's crew.
private struct CrewShares: View {
    @ObservedObject var game: Game

    var body: some View {
        let v = game.status
        VStack(alignment: .leading, spacing: 12) {
            ForEach(v.ships.indices, id: \.self) { i in
                let s = v.ships[i]
                let shares = [s.sailorShare, s.watchShare, 100 - s.sailorShare - s.watchShare]
                let heads = [s.crew * s.sailorShare / 100, s.crew * s.watchShare / 100]
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.name + "호 · \(s.crew)명").fontWeight(.semibold)
                    ForEach(0..<3, id: \.self) { r in
                        HStack {
                            Text(["운항", "파수", "갑판"][r]).frame(width: 40, alignment: .leading)
                            Button("−") { game.act { $0.nudgeShare(ship: i, row: r, up: false) } }
                                .accessibilityIdentifier("portolan.shares.\(i).\(r).decrease")
                            ProgressView(value: Double(shares[r]), total: 100).frame(width: 260)
                            Button("+") { game.act { $0.nudgeShare(ship: i, row: r, up: true) } }
                                .accessibilityIdentifier("portolan.shares.\(i).\(r).increase")
                            Text("\(r < 2 ? heads[r] : s.crew - heads[0] - heads[1])명 : \(shares[r])%").monospacedDigit()
                        }.font(GameFont.callout)
                    }
                }
            }
            Text("운항은 속도, 파수는 시야, 갑판은 전투 인원이 됩니다.").font(GameFont.caption).foregroundStyle(.secondary)
        }
    }
}

/// 함선처분 (0x1EE54): the ship and all aboard are given up.
private struct Scuttle: View {
    @ObservedObject var game: Game
    @Binding var lines: [String]

    var body: some View {
        let v = game.status
        VStack(alignment: .leading, spacing: 8) {
            if v.ships.count < 2 {
                Text(game.message(217))
            }
            ForEach(v.ships.indices, id: \.self) { i in
                HStack {
                    Text(v.ships[i].name + "호").fontWeight(.semibold).frame(width: 160, alignment: .leading)
                    Text("선원 \(v.ships[i].crew)명 · 적재 \(v.ships[i].cargoLoad)통").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("처분") {
                        guard i > 0 else {
                            lines = [game.message(233)]
                            return
                        }
                        let name = v.ships[i].name
                        game.question = Question(text: game.fill(234, name)) {
                            game.act { $0.scuttle(i) }
                            lines = []
                        }
                    }.disabled(v.ships.count < 2)
                }
            }
        }
    }
}

/// 적하편성 (0x1F5EF): barrels between ships; what is thrown out is lost.
private struct CargoMove: View {
    @ObservedObject var game: Game
    @Binding var lines: [String]
    @State private var from = 0
    @State private var to = 1
    @State private var kind = 0
    @State private var count = 0

    var body: some View {
        let v = game.status
        let kinds = kindsAboard(v)
        let k = kinds.indices.contains(kind) ? kinds[kind].0 : CargoKind.water
        let have = v.ships.indices.contains(from) ? v.amount(k, ship: from) : 0
        let room = to < v.ships.count && to != from ? v.ships[to].freeCargo : have
        VStack(alignment: .leading, spacing: 12) {
            ForEach(v.ships.indices, id: \.self) { i in
                let s = v.ships[i]
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(s.name + "호").fontWeight(.semibold)
                        Spacer()
                        Text("적재 여유 \(s.freeCargo)통").monospacedDigit()
                    }
                    Text("물 \(s.water / 10) · 식량 \(s.food / 10) · 자재 \(s.lumber) · 탄약 \(s.shot)").monospacedDigit()
                    if !s.holds.isEmpty {
                        Text(s.holds.map { "\(game.world.navigation.goods[$0.good].name) \($0.amount)" }.joined(separator: " · "))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.font(GameFont.callout)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("보낼 배").font(GameFont.caption)
                    GamePicker("보낼 배", selection: $from,
                               options: v.ships.indices.map { ($0, v.ships[$0].name) },
                               accessibilityIdentifier: "portolan.cargo.from")
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 5) {
                    Text("적하").font(GameFont.caption)
                    GamePicker("적하", selection: $kind,
                               options: kinds.indices.map { ($0, kinds[$0].1) },
                               accessibilityIdentifier: "portolan.cargo.kind")
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 5) {
                    Text("받을 배").font(GameFont.caption)
                    GamePicker("받을 배", selection: $to,
                               options: v.ships.indices.map { ($0, v.ships[$0].name) } + [(v.ships.count, "버린다")],
                               accessibilityIdentifier: "portolan.cargo.to")
                }.frame(maxWidth: .infinity)
            }
            HStack {
                ForEach(0..<4, id: \.self) { index in
                    Button(kinds[index].1) { kind = index; count = 0 }
                        .accessibilityIdentifier("portolan.cargo.kind." + ["water", "food", "lumber", "shot"][index])
                }
            }.controlSize(.small)
            HStack {
                SupplyQuantity(value: $count, maximum: min(have, room), id: "portolan.cargo.quantity").frame(minWidth: 400)
                Button(to >= v.ships.count ? "버리기" : "옮기기") {
                    let n = min(count, have, room)
                    let ok = to >= v.ships.count
                        ? game.act { $0.unload(k, ship: from, barrels: n) }
                        : game.act { $0.moveCargo(k, from: from, to: to, amount: n) }
                    lines = ok ? [] : [game.message(211)]
                    count = 0
                }.disabled(min(count, have, room) <= 0 || from == to)
                    .accessibilityIdentifier("portolan.cargo.transfer")
            }
        }
        .onChange(of: from) { _, _ in count = 0; kind = 0 }
        .onChange(of: to) { _, _ in count = 0 }
        .onChange(of: kind) { _, _ in count = 0 }
    }

    private func kindsAboard(_ v: Voyage) -> [(CargoKind, String)] {
        var r: [(CargoKind, String)] = [(.water, "물"), (.food, "식량"), (.lumber, "자재"), (.shot, "탄약")]
        if v.ships.indices.contains(from) {
            r += v.ships[from].holds.map { (.good($0.good), game.world.navigation.goods[$0.good].name) }
        }
        return r
    }
}

/// 감시 (0x1F84F): the fleets in sight.
private struct Inspect: View {
    @ObservedObject var game: Game
    @Binding var lines: [String]

    var body: some View {
        let v = game.status
        let fleets = v.fleetsInSight()
        VStack(alignment: .leading, spacing: 8) {
            if fleets.isEmpty { Text(game.message(215)) }
            ForEach(fleets, id: \.self) { f in
                let adm = v.memory.fb(f, FleetField.admiral)
                Button {
                    lines = game.act { $0.inspect(f, in: game.world) }
                } label: {
                    HStack {
                        Circle().fill(WorldOverlay.nationColors[min(6, f / 10)]).frame(width: 9, height: 9)
                        Text(adm < 120 ? v.memory.person(adm).name : "함대")
                    }
                }.buttonStyle(GameButtonStyle())
            }
        }
    }
}

/// 대열변경 (0x1FF1B): the ships behind the flagship, in order.
private struct Formation: View {
    @ObservedObject var game: Game

    var body: some View {
        let v = game.status
        VStack(alignment: .leading, spacing: 6) {
            if v.ships.count < 2 { Text(game.message(217)) }
            ForEach(v.ships.indices, id: \.self) { i in
                HStack {
                    Text("\(i + 1)번").monospacedDigit().frame(width: 40, alignment: .leading)
                    Text(v.ships[i].name + "호").fontWeight(.semibold).frame(width: 160, alignment: .leading)
                    Text(captainName(v, i)).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                    if i > 0 {
                        Button { move(i, -1) } label: { Image(systemName: "arrow.up") }.disabled(i == 1)
                        Button { move(i, 1) } label: { Image(systemName: "arrow.down") }.disabled(i == v.ships.count - 1)
                    }
                }
            }
        }
    }

    private func move(_ i: Int, _ d: Int) {
        var order = Array(1..<game.status.ships.count)
        order.swapAt(i - 1, i - 1 + d)
        game.act { $0.reorderShips(order) }
    }
}

/// 급여설정 (0x202C9): raises only, up to 2000 gold.
private struct PaySetting: View {
    @ObservedObject var game: Game
    @Binding var lines: [String]
    @State private var pay: [Int: Int] = [:]

    var body: some View {
        let v = game.status
        VStack(alignment: .leading, spacing: 8) {
            if v.officers.isEmpty { Text("동료가 없습니다.") }
            ForEach(v.officers.indices, id: \.self) { k in
                let o = v.officers[k]
                let p = pay[k] ?? o.salary
                HStack {
                    Text(o.name).fontWeight(.semibold).frame(width: 140, alignment: .leading)
                    Text("충성 \(o.loyalty)").monospacedDigit().frame(width: 85, alignment: .leading)
                    Text("월급 \(o.salary)닢").monospacedDigit().frame(width: 100, alignment: .leading)
                    Slider(value: Binding(get: { Double(p) }, set: { pay[k] = Int($0 / 10) * 10 }),
                           in: Double(min(o.salary, 2000))...2000).frame(minWidth: 100, maxWidth: 200)
                    Text("\(p)닢").monospacedDigit().frame(width: 85)
                    Button("설정") {
                        lines = [game.act { $0.raisePay(officer: k, to: p) }]
                        pay[k] = nil
                    }
                }
            }
        }
    }
}

/// 아이템 (0x293F1): the detail window (0x28C9A), then 장비 or 사용.
private struct ItemUse: View {
    @ObservedObject var game: Game
    @Binding var lines: [String]
    @State private var shown: Int?

    var body: some View {
        let v = game.status
        VStack(alignment: .leading, spacing: 6) {
            if v.items.isEmpty { Text("아이템이 없습니다.") }
            if let id = shown, v.items.contains(id) { ItemDetail(game: game, id: id) }
            ForEach(Array(v.items.enumerated()), id: \.offset) { _, id in
                let it = v.item(id)
                HStack {
                    Button(it.name) { shown = shown == id ? nil : id }
                        .buttonStyle(.plain).fontWeight(.semibold).frame(width: 200, alignment: .leading)
                        .foregroundStyle(shown == id ? Color.yellow : .primary)
                    if it.equipped { Text("장비중").font(GameFont.caption).foregroundStyle(.yellow) }
                    Spacer()
                    if it.slot != nil {
                        Button(it.equipped ? "해제" : "장비") { lines = game.townText(game.act { $0.toggleEquip(id) }) }
                            .accessibilityIdentifier("portolan.item.equip.\(id)")
                    }
                    Button("사용") {
                        if (80...89).contains(id) {                                     // 0x1D6EF
                            game.command = nil
                            game.info = .treasure(id)
                            return
                        }
                        lines = it.slot != nil ? [game.message(1098)] : game.act { $0.useItem(id) }
                    }
                }
            }
        }
    }
}

/// 기능 (menu 20): 환경, 저장, 로드, 중단.
private struct SystemMenu: View {
    @ObservedObject var game: Game
    @State private var environment = false

    var body: some View {
        HStack(spacing: 12) {
            Button("환경") { environment = true }
            Button("저장") {
                game.save()
                game.command = nil
            }
            Button("로드") {
                game.load()
                game.command = nil
            }
            Button("중단") {
                game.question = Question(text: "게임을 중단하고 타이틀로 돌아가겠습니까？") {
                    game.command = nil
                    game.newGame()
                }
            }
        }
        .buttonStyle(GameButtonStyle(prominent: true))
        .sheet(isPresented: $environment) { EnvironmentView(game: game) }
    }
}

/// Menu 36 on open coast: 출항, 응급수리, 탐색, 대기. It cannot be cancelled.
struct CoastView: View {
    @ObservedObject var game: Game
    let coast: CoastLanding
    @State private var lines: [String] = []
    @State private var repairing = false
    @State private var ship = 0
    @State private var part = 0
    @State private var lumber = 0
    @State private var water = false
    @State private var barrels = 0

    var body: some View {
        let v = game.status
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    Text("상륙").font(GameFont.title2.bold())
                    ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in Text(l).fixedSize(horizontal: false, vertical: true) }
                    if repairing { repair(v) }
                    if water && v.ships.indices.contains(ship) {
                        HStack {
                            GamePicker("배", selection: $ship, options: v.ships.indices.map { ($0, v.ships[$0].name) })
                                .frame(width: 200)
                            CountSlider(value: $barrels, max: v.ships[ship].freeCargo, unit: "통").frame(width: 260)
                            Button("싣기") {
                                lines = [game.act { $0.takeWater(ship: ship, barrels: barrels) } ? "물을 실었습니다." : game.message(422)]
                                barrels = 0
                            }.disabled(barrels == 0)
                        }
                    }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: .infinity)
                    HStack {
                        Button("출항") {
                            game.question = Question(text: game.message(417)) {
                                game.act { $0.leaveCoast() }
                                game.coast = nil
                            }
                        }.buttonStyle(GameButtonStyle(prominent: true))
                        Button("응급수리") { repairing.toggle(); water = false }
                        Button("탐색") {
                            let r = game.act { $0.searchCoast(at: (coast.x, coast.y), water: coast.water, in: game.world) }
                            lines = r.lines
                            water = r.water
                            repairing = false
                        }
                        Button("대기") {
                            game.act { $0.waitAshore() }
                            game.coast = nil
                        }
                    }
                }
                .padding(24)
                .frame(width: min(760, geometry.size.width - 40), height: min(560, geometry.size.height - 32))
                .gamePanel(radius: 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder
    private func repair(_ v: Voyage) -> some View {
        let total = v.ships.reduce(0) { $0 + $1.lumber }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                GamePicker("배", selection: $ship, options: v.ships.indices.map { ($0, v.ships[$0].name) })
                    .frame(width: 200)
                HStack(spacing: 6) {
                    ForEach(Array(["내구", "선회", "추진"].enumerated()), id: \.offset) { index, label in
                        Button(label) { part = index }
                            .buttonStyle(GameButtonStyle(prominent: part == index))
                    }
                }
                Text("자재 \(total)통").monospacedDigit()
            }
            if v.ships.indices.contains(ship) {
                let s = v.ships[ship]
                let c = game.world.navigation.classes[s.classIndex]
                Text("내구 \(s.hull)/\(s.maxHull) · 선회 \(s.rudder)/\(c.rudder) · 추진 \(s.sail)/\(c.sail)").monospacedDigit()
                HStack {
                    CountSlider(value: $lumber, max: total, unit: "통").frame(width: 260)
                    Button("수리") {
                        lines = [game.act { $0.emergencyRepair(ship: ship, part: part, lumber: lumber, in: game.world) }]
                        lumber = 0
                    }
                }
            }
        }
    }
}

/// The harbour office (building 3, menu 9 `출항|보급|도크`; supply ports menu 57 `출항|보급|명명`).
struct HarbourOffice: View {
    @ObservedObject var game: Game
    @State private var tab = 0
    @State private var name = ""
    @State private var line = ""

    var body: some View {
        let v = game.status
        let port = game.harbor?.id ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { game.depart() } label: {                                // 출항 (0x273DA)
                    Label("출항", systemImage: "sailboat.fill").font(GameFont.headline).padding(.horizontal, 10)
                }
                .buttonStyle(GameButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("portolan.harbor.depart")
                HStack(spacing: 6) {
                    Button("보급") { tab = 0 }
                        .buttonStyle(GameButtonStyle(prominent: tab == 0))
                        .accessibilityIdentifier("portolan.harbor.tab.supply")
                    if v.hasDock(port) {
                        Button("도크") { tab = 1 }
                            .buttonStyle(GameButtonStyle(prominent: tab == 1))
                            .accessibilityIdentifier("portolan.harbor.tab.dock")
                    }
                    if port >= 100 {
                        Button("명명") { tab = 2 }
                            .buttonStyle(GameButtonStyle(prominent: tab == 2))
                            .accessibilityIdentifier("portolan.harbor.tab.name")
                    }
                }
                Spacer()
                departureTable(v)
            }
            switch tab {
            case 1: dock(v, port)
            case 2: naming(port)
            default: SupplyPanel(game: game)
            }
            if !line.isEmpty { Text(line).font(GameFont.callout).foregroundStyle(.yellow) }
        }
    }

    /// The departure table (msgs 1113/1114): crew by role, load and stores per ship.
    private func departureTable(_ v: Voyage) -> some View {
        let days = min(v.water, v.food) / max(1, v.crew)
        return Text("운항 \(v.ships.reduce(0) { $0 + $1.crew * $1.sailorShare / 100 })명 · 약 \(days)일분")
            .font(GameFont.callout).monospacedDigit().foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func dock(_ v: Voyage, _ port: Int) -> some View {
        let stored = v.docked(at: port)
        VStack(alignment: .leading, spacing: 8) {
            Text(stored.isEmpty ? game.message(277) : game.fill(276, "\(stored.count)")).font(GameFont.callout)
            ForEach(stored.indices, id: \.self) { k in
                HStack {
                    Text(stored[k].ship.name + "호").fontWeight(.semibold).frame(width: 160, alignment: .leading)
                    Text(game.world.navigation.classes[stored[k].ship.classIndex].name).foregroundStyle(.secondary)
                    Spacer()
                    Button("배비") { line = game.act { $0.bringOut(k, at: port) } }
                    GameActionMenu("교환", actions: v.ships.indices.map { i in
                        GameMenuAction(v.ships[i].name) { line = game.act { $0.exchangeShip(i, with: k, at: port) } }
                    }, accessibilityIdentifier: "portolan.dock.exchange.\(k)")
                        .frame(width: 90)
                }
            }
            Divider()
            ForEach(v.ships.indices.dropFirst(), id: \.self) { i in
                HStack {
                    Text(v.ships[i].name + "호").frame(width: 160, alignment: .leading)
                    Text("선원 \(v.ships[i].crew)명").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("보관") {
                        let crew = v.ships[i].crew
                        let text = crew > 0 ? game.fill(281, "\(crew)") : game.message(201)
                        game.question = Question(text: text) { line = game.act { $0.storeShip(i, at: port) } }
                    }
                }
            }
        }
        .padding(16)
        .gameSection()
    }

    private func naming(_ port: Int) -> some View {
        HStack {
            Text(game.message(926)).font(GameFont.callout)
            TextField("이름", text: $name).textFieldStyle(.roundedBorder).frame(width: 140)
            Button("명명") {
                line = game.act { $0.renamePort(port, to: String(name.prefix(7)), in: game.world) }
                name = ""
            }.disabled(name.isEmpty)
        }
        .padding(16)
        .gameSection()
    }
}

/// The item window (0x28C9A): picture `0x55 + icon`, name and type, 장비 mark, the attack or
/// defence grade (MENU 34) and the ITEM.MES text.
struct ItemDetail: View {
    @ObservedObject var game: Game
    let id: Int

    var body: some View {
        let v = game.status
        let it = v.item(id)
        let icon = v.memory[TownDS.item(id) + 0x15]
        HStack(alignment: .top, spacing: 14) {
            if let img = game.image(String(format: "pictures/%03d.png", 0x55 + icon)) {
                Image(nsImage: img).pixelated().frame(width: 96, height: 96)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(it.name)（\(v.memory.name(0x8EA, it.type))）").font(GameFont.headline)
                    if it.equipped { Text("장비").font(GameFont.caption).foregroundStyle(.yellow) }
                }
                if it.type < 4 {
                    Text("공격력 " + game.menu(34, it.power >= 35 ? 4 : max(0, (it.power - 5) / 6))).foregroundStyle(.cyan)
                } else if it.type < 7 {
                    Text("방어력 " + game.menu(34, it.power > 40 ? 4 : max(0, (it.power - 10) / 10))).foregroundStyle(.cyan)
                }
                Text(game.itemTexts.indices.contains(id) ? game.itemTexts[id] : "")
                    .font(GameFont.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .gameSection(radius: 10)
    }
}

/// A sea event (0x305DE): three plain text boxes, each waiting for a key.
struct SeaEventView: View {
    @ObservedObject var game: Game
    let pages: [String]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    ScrollView {
                        Text(pages.first ?? "").font(.system(size: 22)).lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: .infinity)
                    HStack {
                        Spacer()
                        Button("계속") {
                            let rest = Array(pages.dropFirst())
                            game.seaEvent = rest.isEmpty ? nil : rest
                        }
                        .buttonStyle(GameButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("portolan.sea-event.continue")
                    }
                }
                .padding(24)
                .frame(width: min(720, geometry.size.width - 40), height: min(440, geometry.size.height - 40))
                .gamePanel(radius: 12)
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
