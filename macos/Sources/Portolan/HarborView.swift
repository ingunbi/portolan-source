import SwiftUI
import PortolanCore

/// Port facilities are reached by walking through their doors in the town map.
struct HarborView: View {
    @ObservedObject var game: Game
    let harbor: Harbor

    var body: some View {
        GeometryReader { geometry in
            let space = geometry.size
            let inset: CGFloat = space.height < 680 ? 12 : 18
            let width = max(760, space.width - inset * 2 - 32)
            let inside = game.buildingScene != nil
            let mapHeight = max(220, space.height - inset * 2 - 32 - 64 - (inside ? 10 : 104))
            ZStack {
                Theme.navy.opacity(0.9).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 10) {
                    header
                        .frame(height: 64)
                    if let panel = game.panel {
                        building(panel, height: mapHeight)
                    } else if let entering = game.buildingScene {
                        BuildingInteriorView(game: game, building: entering)
                            .frame(width: width, height: mapHeight)
                    } else {
                        TownWalkView(game: game, harbor: harbor, side: mapHeight, width: width)
                            .frame(width: width, height: mapHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                Label("시가지", systemImage: "figure.walk")
                                    .font(.system(size: 15, weight: .semibold))
                                    .padding(.horizontal, 11).padding(.vertical, 7)
                                    .background(Theme.navy.opacity(0.85), in: Capsule())
                                    .padding(10)
                                    .allowsHitTesting(false)
                            }
                    }
                    if !inside {
                        footer.frame(height: 84)
                    }
                }
                .padding(16)
                .frame(width: width + 32)
                .background(Theme.navyLight.opacity(0.8), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.4), radius: 28, y: 10)
                .frame(width: space.width, height: space.height)
            }
            .environment(\.colorScheme, .dark)
        }
        .transition(.opacity)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "building.2.crop.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.wind)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(game.portName(harbor.id))
                        .font(.system(size: 27, weight: .bold))
                    Text(harbor.id >= 100 ? "보급항" : "기항 중")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.wind)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.wind.opacity(0.1), in: Capsule())
                }
                Text(game.dateText + "  ·  " + timeText)
                    .font(.system(size: 15)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
            }
            Spacer(minLength: 12)
            Button { game.openVoyagePlan() } label: {
                Label("항해 계획", systemImage: "map")
            }
            .help("목적지, 보급 상태, 진행 중인 임무 확인")
            VStack(alignment: .trailing, spacing: 3) {
                Text("보유 금화").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 6) {
                    Image(systemName: "circle.circle.fill").font(.system(size: 15))
                    Text(game.status.gold.formatted()).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                }.foregroundStyle(Theme.gold)
            }
        }
    }

    private func building(_ panel: HarborPanel, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                if let image = game.buildingPicture(panel) {
                    Image(nsImage: image).pixelated().aspectRatio(136 / 112, contentMode: .fit)
                        .frame(width: 56, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(panel == .harbor ? "항구 사무소" : panel.title)
                        .font(.system(size: 24, weight: .semibold))
                    Text(panel.harborPurpose)
                        .font(.system(size: 15)).foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                Button { game.leaveBuilding() } label: {
                    Label("시가지로", systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("portolan.building.leave")
            }
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            ScrollView {
                BuildingContent(game: game, panel: panel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(panel)
            }
            .scrollIndicators(.automatic)
            .accessibilityIdentifier("portolan.building.content.scroll")
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(height: height)
        .background(Theme.navy.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 18) {
            if game.status.ships.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("아직 배가 없습니다", systemImage: "sailboat")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    Text("선박을 마련하면 보급 상태가 표시됩니다.")
                        .font(.system(size: 15)).foregroundStyle(.white.opacity(0.7))
                }
            } else {
                SupplyGauge(title: "식수", units: game.status.water, perDay: game.status.dailyWater, tint: Theme.wind, width: 132)
                SupplyGauge(title: "식량", units: game.status.food, perDay: game.status.dailyFood, tint: Theme.gold, width: 132)
                VStack(alignment: .leading, spacing: 4) {
                    Label("선원", systemImage: "person.2.fill")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    Text("\(game.status.crew) / \(game.status.ships.reduce(0) { $0 + $1.crewCapacity })명")
                        .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            CommandBar(game: game)
        }
        .padding(.horizontal, 4)
    }

    private var timeText: String {
        let tick = game.status.tick
        return String(format: "%02d:%02d", tick / 3, (tick % 3) * 20)
    }
}

private extension HarborPanel {
    var harborPurpose: String {
        switch self {
        case .harbor: return "보급을 마치고 다음 바다로 출항합니다."
        case .market: return "교역품을 사고팔고 시장에 투자합니다."
        case .tavern: return "선원과 항해사를 모으고 소식을 듣습니다."
        case .shipyard: return "배를 수리하고 함대를 정비합니다."
        case .inn: return "시간을 정해 쉬고 머무는 항해자를 만납니다."
        case .guild: return "일거리를 찾고 의뢰를 보고합니다."
        case .residence: return "인물을 만나 이야기와 모험을 이어갑니다."
        case .palace: return "국왕을 알현하고 왕실 임무를 확인합니다."
        case .bank: return "금화를 맡기거나 대출을 관리합니다."
        case .itemShop: return "항해와 전투에 필요한 물품을 살펴봅니다."
        case .church: return "기도하거나 기부합니다."
        case .fortuneTeller: return "앞으로의 운세를 물어봅니다."
        }
    }

}

struct BuildingContent: View {
    @ObservedObject var game: Game
    let panel: HarborPanel
    var body: some View {
        switch panel {
        case .tavern: if let t = game.tavern { TavernPanel(game: game, tavern: t) }
        case .harbor: if game.status.ships.isEmpty { NoShipNote() } else { HarbourOffice(game: game) }
        case .market: if game.status.ships.isEmpty { NoShipNote() } else { TradePanel(game: game) }
        case .shipyard: ShipyardPanel(game: game)
        default: TownPanel(game: game, building: panel)
        }
    }
}

/// Shown where a service needs a ship and the hero has none yet (the prologue).
struct NoShipNote: View {
    var body: some View {
        Text("아직 배가 없습니다.").foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .gameSection()
    }
}

/// Integer slider with its value, used for bottles, sailors and barrels.
struct CountSlider: View {
    @Binding var value: Int
    let max: Int
    let unit: String
    var body: some View {
        HStack {
            Slider(value: Binding(get: { Double(min(value, max)) }, set: { value = Int($0.rounded()) }),
                   in: 0...Double(Swift.max(max, 1)))
                .disabled(max == 0)
            Text("\(min(value, max))\(unit)").monospacedDigit().fixedSize().frame(minWidth: 80, alignment: .trailing)
        }
    }
}

private struct TavernPanel: View {
    @ObservedObject var game: Game
    let tavern: Tavern
    @State private var bottles = 4
    @State private var sailors = 0
    @State private var line = ""
    /// Menu 15 beyond 선원고용 · 한턱내기 · 항해자와대화 (TavernMoreView.swift).
    @State private var mode = TavernMode.main

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TavernMenuBar(game: game, mode: $mode)
            switch mode {
            case .main: main
            case .dismiss: DismissCrewPanel(game: game)
            case .barmaid(let g): BarmaidPanel(game: game, girl: g) { mode = .main }
            case .gambling: GamblingPanel(game: game) { mode = .main }
            }
        }
    }

    private var main: some View {
        let v = game.status
        let affordable = tavern.bottlesAffordable(gold: v.gold)
        let hireable = v.hiredToday ? 0 : v.hireable(at: tavern)
        return VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(tavern.drink.name) 한 병에 금화 \(tavern.drink.price)닢")
                    .font(GameFont.callout)
                SupplyQuantity(value: $bottles, maximum: affordable, id: "portolan.tavern.bottles", unit: "병")
                Button("한턱 내기 · 금화 \(min(bottles, affordable) * tavern.drink.price)닢") {
                    game.treat(bottles: min(bottles, affordable))
                }.disabled(min(bottles, affordable) == 0)
                    .accessibilityIdentifier("portolan.tavern.treat")
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("분위기")
                        Spacer()
                        Text("\(tavern.mood) / 100").monospacedDigit().foregroundStyle(.secondary)
                    }.font(GameFont.caption)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            Capsule().fill(tavern.mood < Tavern.willingMood ? Color.orange : Color.green)
                                .frame(width: g.size.width * Double(tavern.mood) / 100)
                            Rectangle().fill(.white.opacity(0.6)).frame(width: 1)
                                .offset(x: g.size.width * Double(Tavern.willingMood) / 100)
                        }
                    }.frame(height: 6)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                Text(advice(v)).font(GameFont.callout)
                Text("지원자 \(tavern.volunteers(rank: v.rank))명 · 선원 한 사람당 금화 \(tavern.wage)닢 · 빈 자리 \(v.vacancies)명")
                    .font(GameFont.caption).foregroundStyle(.secondary).monospacedDigit()
                CountSlider(value: $sailors, max: hireable, unit: "명")
                Button("가능한 인원 모두 선택 · \(hireable)명") { sailors = hireable }
                    .disabled(hireable == 0)
                    .accessibilityIdentifier("portolan.tavern.hire.maximum")
                Button("고용 · 금화 \(min(sailors, hireable) * tavern.wage)닢") {
                    let n = min(sailors, hireable)
                    if game.act({ $0.hireCrew(n, at: tavern) }) {             // once a day (0x252A7)
                        line = "\(n)명의 선원이 배에 올랐습니다."
                        sailors = 0
                    }
                }.disabled(min(sailors, hireable) == 0)
                    .accessibilityIdentifier("portolan.tavern.hire")
                if v.hiredToday && line.isEmpty {
                    Text("오늘은 이미 선원을 모았습니다.").font(GameFont.caption).foregroundStyle(.secondary)
                }
                if !line.isEmpty { Text(line).font(GameFont.caption).foregroundStyle(.green) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .gameSection()
        .onAppear { sailors = hireable }
        NavigatorPanel(game: game, mood: tavern.mood)
        }
    }

    /// Barkeep lines from MESSAGE.DAT 29, 30, 31, 121-123.
    private func advice(_ v: Voyage) -> String {
        if v.vacancies == 0 { return "선원은 충분해요." }
        if v.gold < 10 { return "금화가 부족해요." }
        if tavern.mood < Tavern.willingMood { return "선원을 모으려면 술을 한 순배 더 돌리는 편이 낫겠습니다." }
        let n = tavern.volunteers(rank: v.rank)
        return n == 0 ? "지원자가 한 사람도 나타나지 않았습니다."
            : n < 20 ? "지원자는 \(n)명에 그쳤습니다." : "선원 \(n)명이 모였습니다."
    }
}

struct SupplyPanel: View {
    @ObservedObject var game: Game
    @State private var ship = 0
    @State private var amounts = [Int](repeating: 0, count: Supply.allCases.count)
    /// The load/unload toggle (0x277AA); unloading gives nothing back (msg 1115).
    @State private var unloading = false

    var body: some View {
        if game.status.ships.isEmpty {
            Text("아직 배가 없습니다.").font(GameFont.body).foregroundStyle(.secondary)
        } else {
            fleetContent
        }
    }

    @ViewBuilder
    private var fleetContent: some View {
        let v = game.status
        let selectedShip = min(max(0, ship), v.ships.count - 1)
        let s = v.ships[selectedShip]
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if v.ships.count > 1 {
                    HStack(spacing: 8) {
                        Text("배").fixedSize()
                        GamePicker("배", selection: $ship,
                                   options: v.ships.indices.map { ($0, v.ships[$0].name) },
                                   accessibilityIdentifier: "portolan.supply.ship")
                    }.frame(width: 240)
                    Button("이전 배") { ship = max(0, ship - 1) }.disabled(ship == 0)
                        .accessibilityIdentifier("portolan.supply.ship.previous")
                    Button("다음 배") { ship = min(v.ships.count - 1, ship + 1) }.disabled(ship >= v.ships.count - 1)
                        .accessibilityIdentifier("portolan.supply.ship.next")
                } else {
                    Text(s.name).font(GameFont.headline)
                }
                Spacer()
                Text("적재 여유 \(s.freeCargo) / \(s.cargoCapacity)통")
                    .font(GameFont.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("싣기") { unloading = false }
                    .buttonStyle(GameButtonStyle(prominent: !unloading))
                    .accessibilityIdentifier("portolan.supply.mode.load")
                Button("내리기") { unloading = true }
                    .buttonStyle(GameButtonStyle(prominent: unloading))
                    .accessibilityIdentifier("portolan.supply.mode.unload")
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Supply.allCases, id: \.self) { kind in row(kind, v, s, ship: selectedShip) }
            }
        }
        .padding(16)
        .gameSection()
        .onChange(of: ship) { _, _ in amounts = Array(repeating: 0, count: Supply.allCases.count) }
        .onChange(of: unloading) { _, _ in amounts = Array(repeating: 0, count: Supply.allCases.count) }
    }

    private func row(_ kind: Supply, _ v: Voyage, _ s: Ship, ship: Int) -> some View {
        let price = kind.price(at: game.market)
        let held = [s.water / 10, s.food / 10, s.lumber, s.shot][kind.rawValue]
        let most = unloading ? held : v.maxPurchase(kind, ship: ship, at: game.market)
        let n = min(amounts[kind.rawValue], most)
        let cargo: [CargoKind] = [.water, .food, .lumber, .shot]
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 14) {
                Text(kind.name).font(GameFont.headline)
                Text(price == 0 ? "무료" : "1통 \(price)닢").font(GameFont.callout).monospacedDigit().foregroundStyle(.secondary)
                Text("보유 \(held)통").font(GameFont.callout).monospacedDigit()
            }
            HStack(spacing: 16) {
                SupplyQuantity(value: $amounts[kind.rawValue], maximum: most,
                               id: "portolan.supply.\(kind.rawValue).quantity")
                Spacer(minLength: 10)
                if unloading {
                    Button("내리기") {
                        if game.act({ $0.unload(cargo[kind.rawValue], ship: ship, barrels: n) }) { amounts[kind.rawValue] = 0 }
                    }.disabled(n == 0)
                        .accessibilityIdentifier("portolan.supply.\(kind.rawValue).unload")
                } else {
                    Button(price == 0 ? "싣기" : "구입 · \(n * price)닢") {
                        if game.buy(kind, barrels: n, ship: ship) { amounts[kind.rawValue] = 0 }
                    }.disabled(n == 0)
                        .accessibilityIdentifier("portolan.supply.\(kind.rawValue).buy")
                }
            }
        }

    }
}

/// Exact barrel quantities shared by harbour loading and cargo redistribution.
/// Real buttons also make large, precise orders possible without dragging a slider.
struct SupplyQuantity: View {
    @Binding var value: Int
    let maximum: Int
    let id: String
    var unit: String = "통"
    private var count: Int { min(max(0, value), max(0, maximum)) }

    var body: some View {
        HStack(spacing: 5) {
            step(-10)
            step(-1)
            Text("\(count)\(unit)").font(GameFont.body).monospacedDigit().fixedSize().frame(minWidth: 60)
                .accessibilityIdentifier(id + ".count").accessibilityValue(String(count))
            step(1)
            step(10)
            Button("전체") { value = max(0, maximum) }
                .disabled(maximum <= 0)
                .accessibilityIdentifier(id + ".maximum")
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func step(_ delta: Int) -> some View {
        let suffix = delta == -10 ? "decreaseTen" : delta == -1 ? "decrease" : delta == 1 ? "increase" : "increaseTen"
        return Button(delta == -1 ? "−" : delta == 1 ? "+" : delta > 0 ? "+\(delta)" : "\(delta)") {
            value = min(max(0, maximum), max(0, count + delta))
        }
        .disabled(delta < 0 ? count == 0 : count >= maximum)
        .accessibilityIdentifier(id + "." + suffix)
    }
}

/// Navigators in the tavern (항해자와대화, PatronList in TavernMoreView.swift) and the officers
/// already signed.
private struct NavigatorPanel: View {
    @ObservedObject var game: Game
    let mood: Int

    var body: some View {
        let v = game.status
        VStack(alignment: .leading, spacing: 20) {
            PatronList(game: game, place: .tavern, mood: mood)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text("동료 \(v.officers.count)명 · 남는 선장 \(max(0, v.spareCaptains))").font(GameFont.headline)
                ForEach(v.officers.indices, id: \.self) { k in
                    let o = v.officers[k]
                    HStack {
                        Text(o.name)
                        Text("항해 \(o.navLevel) · 충성 \(o.loyalty) · 월 \(o.salary)닢").font(GameFont.caption).foregroundStyle(.secondary)
                        Spacer()
                        if k < v.ships.count - 1 {
                            Text("\(v.ships[k + 1].name) 선장").font(GameFont.caption)
                        } else {
                            let officerOptions: [(OfficerPost?, String)] = [(nil, "—")] + OfficerPost.allCases.map { post -> (OfficerPost?, String) in
                            (post, post.name)
                        }
                        GamePicker("담당 직책", selection: Binding(get: { o.post }, set: { p in game.act { $0.appoint(k, to: p) } }),
                                       options: officerOptions)
                                .frame(width: 150)
                        }
                        Button("해고") { game.dismissOfficer(k) }.disabled(v.spareCaptains <= 0).font(GameFont.caption)
                    }.font(GameFont.callout)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .gameSection()
    }
}

/// 시세·물가 (교역소 MENU 6[3], 0x24C72): free, no time.
struct PriceList: View {
    @ObservedObject var game: Game
    @State private var category = 0

    var body: some View {
        let v = game.status
        let list = v.priceList(category: category, in: game.world)
        let name = v.memory.name(0x7CA, category)
        VStack(alignment: .leading, spacing: 8) {
            GamePicker("교역품 분류", selection: $category,
                       options: (0..<10).map { ($0, v.memory.name(0x7CA, $0)) })
                .frame(width: 200)
            Text(game.fill(151, name, "\(list.index)")).foregroundStyle(.yellow)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("상품명").foregroundStyle(.secondary)
                    Text("매각").foregroundStyle(.secondary)
                    Text("매입").foregroundStyle(.secondary)
                }
                ForEach(list.rows, id: \.good) { r in
                    GridRow {
                        Text(game.world.navigation.goods[r.good].name)
                        Text(r.buy.map { "\($0)" } ?? " ----").monospacedDigit()
                        Text("\(r.sell)").monospacedDigit()
                    }
                }
            }.font(GameFont.callout)
        }.frame(width: 420)
    }
}
