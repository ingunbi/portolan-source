import SwiftUI
import PortolanCore

/// The shipyard: used ships, new builds, refits, repairs and sales, cannons (메뉴 22, 23).
struct ShipyardPanel: View {
    @ObservedObject var game: Game
    @State private var line = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(["중고선 구입", "함선 건조", "개조", "수리 · 매각", "무장", "공업투자"].enumerated()), id: \.offset) { index, title in
                            Button(title) { game.shipyardTab = index }
                                .buttonStyle(GameButtonStyle(prominent: game.shipyardTab == index))
                                .fixedSize()
                                .accessibilityIdentifier("portolan.shipyard.tab.\(index)")
                        }
                    }.padding(.bottom, 3)
                }
                .accessibilityIdentifier("portolan.shipyard.tabs.scroll")
                if !line.isEmpty { Text(line).font(GameFont.callout).foregroundStyle(.yellow).fixedSize(horizontal: false, vertical: true) }
            }
            switch game.shipyardTab {
            case 0: UsedShipBox(game: game, line: $line)
            case 1: BuildBox(game: game, line: $line)
            case 2 where !game.status.ships.isEmpty: RefitBox(game: game, line: $line)
            case 3: FleetBox(game: game, line: $line)
            case 4 where !game.status.ships.isEmpty: CannonBox(game: game)
            case 5: InvestBox(game: game, field: .industry)
            default: Text("아직 배가 없습니다.").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .gameSection()
        .onChange(of: game.shipyardTab) { line = "" }
    }
}

/// Shipwright replies to a deal.
private func reply(_ game: Game, _ r: ShipDeal) -> String {
    switch r {
    case .bought: return game.message(257)
    case .refused: return game.message(198)
    case .banned: return game.message(197)
    case .short: return game.message(207)
    case .noCaptain: return game.message(166)
    case .fleetFull: return "함대가 가득 찼습니다."
    case .cargoAboard: return "적하를 먼저 팔아 주십시오."
    case .busy, .notReady:
        let days = game.status.orderHere?.daysLeft ?? 0
        return game.message(261).replacingOccurrences(of: "%d", with: "\(days)")
    }
}

/// Offer slider shared by used ships and new builds: from the haggle floor up to the price.
private struct OfferSlider: View {
    @Binding var offer: Int
    let most: Int
    var body: some View {
        HStack {
            Text("제시액").font(GameFont.caption)
            Slider(value: Binding(get: { Double(min(offer, most)) }, set: { offer = Int($0 / 10) * 10 }),
                   in: 0...Double(max(most, 1)))
            Text("\(min(offer, most))닢").monospacedDigit().fixedSize().frame(minWidth: 110, alignment: .trailing)
        }
    }
}

private struct UsedShipBox: View {
    @ObservedObject var game: Game
    @Binding var line: String
    @State private var pick = 0
    @State private var offer = 0
    @State private var tradeIn = 0
    @State private var name = ""

    var body: some View {
        let v = game.status
        let w = game.world
        let stock = v.shipyardStock
        VStack(alignment: .leading, spacing: 6) {
            if stock.isEmpty { Text(game.message(165)).foregroundStyle(.secondary) }        // 지금은 매물이 없는데.
            ForEach(stock.indices, id: \.self) { k in
                let c = w.navigation.classes[stock[k]]
                Button { select(k, stock) } label: {
                    HStack {
                        Text(c.name).font(GameFont.body.weight(k == pick ? .semibold : .regular))
                        Text("선원 \(c.crewCapacity) · 대포 \(c.gunCapacity) · 적재 \(c.cargoCapacity) · 내구 \(9 * c.hull / 10)")
                            .font(GameFont.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(v.askingPrice(class: stock[k], in: w))닢").monospacedDigit()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(k == pick ? Theme.gold.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if stock.indices.contains(pick) {
                // The class picture (0x7EE9, GRAPH.DAT 28 + class) of the ship on offer (0x2A9F1).
                if let img = game.image(String(format: "sprites/ships/class_%02d.png", stock[pick])) {
                    Image(nsImage: img).pixelated().frame(width: 128, height: 96).clipShape(RoundedRectangle(cornerRadius: 4))
                }
                purchase(v, w, stock)
            }
        }
        .onAppear { select(0, stock) }
    }

    @ViewBuilder
    private func purchase(_ v: Voyage, _ w: World, _ stock: [Int]) -> some View {
        let cls = stock[pick]
        let asking = v.askingPrice(class: cls, in: w)
        let needsTrade = v.spareCaptains == 0
        let credit = needsTrade && v.ships.indices.contains(tradeIn) ? v.shipValue(tradeIn, in: w) / 2 : 0
        let most = min(asking, v.gold + credit)
        Text(game.message(168 + cls)).font(GameFont.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if needsTrade {
            HStack(spacing: 8) {
                Text("내줄 배").fixedSize()
                GamePicker("내줄 배", selection: $tradeIn,
                           options: v.ships.indices.map { ($0, "\(v.ships[$0].name) (+\(v.shipValue($0, in: w) / 2)닢)") })
            }
            Text(game.message(167)).font(GameFont.caption).foregroundStyle(.secondary)  // message 167
        }
        OfferSlider(offer: $offer, most: most)
        HStack {
            TextField("배 이름", text: $name).textFieldStyle(.roundedBorder).frame(width: 160)
            Button("구입") {
                let r = game.buyShip(slot: pick, offer: min(offer, most), tradeIn: needsTrade ? tradeIn : nil,
                                     name: name.isEmpty ? w.navigation.classes[cls].name : name)
                line = r == .bought ? game.message(199).components(separatedBy: ".").first.map { $0 + "." } ?? "" : reply(game, r)
                if r == .bought { select(0, game.status.shipyardStock) }
            }.disabled(most == 0 || v.shipyardBanned)
        }
    }

    private func select(_ k: Int, _ stock: [Int]) {
        pick = k
        guard stock.indices.contains(k) else { return }
        offer = (game.status.haggleFloor(game.status.askingPrice(class: stock[k], in: game.world)) + 9) / 10 * 10
        name = ""
    }
}

/// New builds (0x2B50E): class, hull material, the crew and gun split, then the price.
private struct BuildBox: View {
    @ObservedObject var game: Game
    @Binding var line: String
    @State private var cls = -1
    @State private var material = 2
    @State private var crew = 0
    @State private var guns = 0
    @State private var offer = 0
    @State private var name = ""

    var body: some View {
        let v = game.status
        let w = game.world
        let m = v.market(in: w)
        let list = Shipyard.buildable(at: m, in: w.navigation)
        VStack(alignment: .leading, spacing: 8) {
            if let o = v.orderHere {
                order(o)
            } else if list.isEmpty {
                Text(game.message(251)).foregroundStyle(.secondary)                // message 251
            } else {
                Text(game.message(252)).font(GameFont.callout)
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(list, id: \.self) { c in
                            Button { choose(c) } label: {
                                HStack {
                                    Text(w.navigation.classes[c].name).font(GameFont.body.weight(c == cls ? .semibold : .regular))
                                    Spacer()
                                    Text("\(Shipyard.buildDays(class: c, at: m, in: w.navigation))일").font(GameFont.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(c == cls ? Theme.gold.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.frame(width: 200)
                    if list.contains(cls) { terms(v, w, m) }
                }
            }
        }
        .onAppear { if let c = list.first, cls < 0 { choose(c) } }
    }

    @ViewBuilder
    private func terms(_ v: Voyage, _ w: World, _ m: Market) -> some View {
        let c = w.navigation.classes[cls]
        let asking = Shipyard.buildPrice(class: cls, material: material, at: m, in: w.navigation)
        let most = min(asking, v.gold)
        VStack(alignment: .leading, spacing: 6) {
            if let img = game.image(String(format: "sprites/ships/class_%02d.png", cls)) {
                Image(nsImage: img).pixelated().frame(width: 128, height: 96).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(game.message(254)).fixedSize(horizontal: false, vertical: true)
            GamePicker(game.message(254), selection: $material,
                       options: (0..<Shipyard.materialCount(class: cls, at: m)).map { k in
                           (k, "\(Shipyard.materials[k]) · 내구 \(Shipyard.builtHull(class: cls, material: k, in: w.navigation))")
                       })
            HStack {
                Text("선원").font(GameFont.caption).frame(width: 44, alignment: .leading)
                Slider(value: Binding(get: { Double(crew) }, set: { crew = min(Int($0.rounded()), c.capacity - guns) }),
                       in: Double(c.minCrew)...Double(max(c.minCrew + 1, c.maxCrew)))
                Text("\(crew)명").monospacedDigit().fixedSize().frame(minWidth: 80, alignment: .trailing)
            }
            HStack {
                Text("대포").font(GameFont.caption).frame(width: 44, alignment: .leading)
                Slider(value: Binding(get: { Double(guns) }, set: { guns = min(Int($0.rounded()), c.capacity - crew) }),
                       in: 0...Double(max(1, c.maxGuns)))
                Text("\(guns)문").monospacedDigit().fixedSize().frame(minWidth: 80, alignment: .trailing)
            }
            Text("적재 \(c.capacity - crew - guns) · 금화 \(asking)닢 · \(Shipyard.buildDays(class: cls, at: m, in: w.navigation))일")
                .font(GameFont.caption).foregroundStyle(.secondary).monospacedDigit()
            OfferSlider(offer: $offer, most: most)
            HStack {
                TextField("배 이름", text: $name).textFieldStyle(.roundedBorder).frame(width: 160)
                Button("주문") {
                    let r = game.act { $0.orderShip(class: cls, material: material, crew: crew, guns: guns, offer: min(offer, most),
                                                    name: name.isEmpty ? c.name : name, in: w) }
                    line = r == .bought
                        ? game.message(262).replacingOccurrences(of: "%d", with: "\(game.status.orderHere?.daysLeft ?? 0)")
                        : reply(game, r)
                }.disabled(most == 0 || v.shipyardBanned)
            }
        }
    }

    @ViewBuilder
    private func order(_ o: ShipOrder) -> some View {
        let c = game.world.navigation.classes[o.ship.classIndex]
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(o.ship.name) · \(c.name) · \(Shipyard.materials[o.ship.material])").font(GameFont.headline)
                Text("선원 \(o.ship.crewCapacity) · 대포 \(o.ship.gunCapacity) · 적재 \(o.ship.cargoCapacity) · 내구 \(o.ship.maxHull)")
                    .font(GameFont.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if o.daysLeft > 0 {
                Text(game.message(261).replacingOccurrences(of: "%d", with: "\(o.daysLeft)")).font(GameFont.callout)
            } else {
                Text(game.message(250)).font(GameFont.callout)
                Button("인수") {
                    let r = game.act { $0.takeDelivery() }
                    line = r == .bought ? "\(o.ship.name)호가 함대에 합류했습니다." : r == .noCaptain ? game.message(285) : reply(game, r)
                }
            }
        }
    }

    private func choose(_ c: Int) {
        cls = c
        let k = game.world.navigation.classes[c]
        crew = k.crewCapacity
        guns = k.gunCapacity
        material = min(2, Shipyard.materialCount(class: c, at: game.market) - 1)
        let asking = Shipyard.buildPrice(class: c, material: material, at: game.market, in: game.world.navigation)
        offer = (game.status.haggleFloor(asking) + 9) / 10 * 10
        name = ""
    }
}

/// Figureheads, the crew and gun split, and names (메뉴 23).
private struct RefitBox: View {
    @ObservedObject var game: Game
    @Binding var line: String
    @State private var ship = 0
    @State private var crew = 0
    @State private var guns = 0
    @State private var name = ""

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
        let w = game.world
        let i = min(max(0, ship), v.ships.count - 1)
        let s = v.ships[i]
        let c = w.navigation.classes[s.classIndex]
        VStack(alignment: .leading, spacing: 8) {
            if v.ships.count > 1 {
                HStack(spacing: 8) {
                    Text("배").fixedSize()
                    GamePicker("배", selection: $ship,
                               options: v.ships.indices.map { ($0, v.ships[$0].name) })
                }.frame(width: 240)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("선수상 · 지금 \(Shipyard.figureheadNames[s.figurehead])").font(GameFont.headline)
                    if v.figureheadStock > min(8, game.market.economy / 100 + 1) { Text(game.message(266)).font(GameFont.caption) }
                    ForEach(1...v.figureheadStock, id: \.self) { k in
                        HStack {
                            if let img = game.image(String(format: "sprites/figureheads/figurehead_%02d.png", k)) {
                                Image(nsImage: img).pixelated().frame(width: 32, height: 32)
                            }
                            Text(Shipyard.figureheadNames[k])
                            Spacer()
                            Button("금화 \(Shipyard.figureheadPrice(k))닢") {
                                line = game.act { $0.buyFigurehead(k, ship: i) } ? "\(Shipyard.figureheadNames[k]) 선수상을 달았소." : game.message(207)
                            }.disabled(s.figurehead == k || v.gold < Shipyard.figureheadPrice(k)).font(GameFont.caption)
                        }.font(GameFont.callout)
                    }
                }.frame(width: 330)
                VStack(alignment: .leading, spacing: 6) {
                    Text("적재비율 변경").font(GameFont.headline)
                    HStack {
                        Text("선원").font(GameFont.caption).frame(width: 44, alignment: .leading)
                        Slider(value: Binding(get: { Double(crew) }, set: { crew = min(Int($0.rounded()), c.capacity - guns) }),
                               in: Double(c.minCrew)...Double(max(c.minCrew + 1, c.maxCrew)))
                        Text("\(crew)명").monospacedDigit().fixedSize().frame(minWidth: 80, alignment: .trailing)
                    }
                    HStack {
                        Text("대포").font(GameFont.caption).frame(width: 44, alignment: .leading)
                        Slider(value: Binding(get: { Double(guns) }, set: { guns = min(Int($0.rounded()), c.capacity - crew) }),
                               in: 0...Double(max(1, c.maxGuns)))
                        Text("\(guns)문").monospacedDigit().fixedSize().frame(minWidth: 80, alignment: .trailing)
                    }
                    Text("적재 \(c.capacity - crew - guns) (지금 \(s.cargoLoad) 싣는 중)").font(GameFont.caption).foregroundStyle(.secondary)
                    Button("변경 · 금화 \(Shipyard.refitCost(class: s.classIndex, in: w.navigation))닢") {
                        line = game.act { $0.refit(i, crew: crew, guns: guns, in: w) } ? "좋아, 바꿔 주었소." : game.message(20)
                    }
                    Divider()
                    HStack {
                        TextField("새 이름", text: $name).textFieldStyle(.roundedBorder)
                        Button("이름 변경") {
                            game.act { $0.ships[i].name = name }
                            line = "\(name)호로 이름을 바꾸었소."
                            name = ""
                        }.disabled(name.isEmpty)
                    }
                }
            }
        }
        .onAppear { load(i) }
        .onChange(of: ship) { load(min(ship, game.status.ships.count - 1)) }
    }

    private func load(_ i: Int) {
        guard game.status.ships.indices.contains(i) else { return }
        crew = game.status.ships[i].crewCapacity
        guns = game.status.ships[i].gunCapacity
    }
}

private struct FleetBox: View {
    @ObservedObject var game: Game
    @Binding var line: String

    var body: some View {
        let v = game.status
        let w = game.world
        VStack(alignment: .leading, spacing: 6) {
            ForEach(v.ships.indices, id: \.self) { i in
                let s = v.ships[i]
                let cost = Shipyard.repairCost(s, in: w.navigation)
                HStack {
                    Text(s.name).font(GameFont.body.weight(.semibold))
                    Text("\(w.navigation.classes[s.classIndex].name) · \(Shipyard.materials[s.material])").font(GameFont.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("내구 \(s.hull)/\(s.maxHull) · 선회 \(s.rudder) · 추진 \(s.sail)").monospacedDigit().foregroundStyle(.secondary)
                    Button(cost == 0 ? "수리 불필요" : "수리 · \(cost)닢") {
                        line = game.repair(i) ? "수리를 마쳤소." : game.message(207)
                    }.disabled(cost == 0)
                    Button("매각 · \(v.shipValue(i, in: w) / 2)닢") {
                        let r = game.sellShip(i)
                        line = r == .bought ? game.message(164) : r == .cargoAboard ? game.message(211) : game.message(208)
                    }.disabled(v.ships.count < 2 || i == 0)
                }
                .font(GameFont.callout)
                .padding(8)
                .gameSection(radius: 8)
            }
        }
    }
}

/// Cannon fitting (메시지 270–272).
struct CannonBox: View {
    @ObservedObject var game: Game
    @State private var ship = 0
    @State private var type = 1
    @State private var count = 0

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
        let w = game.world
        let types = v.cannonTypes(in: w)
        let i = min(max(0, ship), v.ships.count - 1)
        let price = v.cannonPrice(type, in: w)
        let most = min(v.maxCannons(type, ship: i), v.gold / max(price, 1))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if v.ships.count > 1 {
                    GamePicker("배", selection: $ship,
                               options: v.ships.indices.map { ($0, v.ships[$0].name) })
                        .frame(width: 200)
                }
                GamePicker("대포 종류", selection: $type,
                           options: types.map { ($0, "\(w.navigation.cannons[$0 - 1].name) \(w.navigation.cannons[$0 - 1].price)닢") })
                    .frame(width: 240)
                Text("지금 \(v.ships[i].gunType == 0 ? "없음" : w.navigation.cannons[v.ships[i].gunType - 1].name) \(v.ships[i].guns)/\(v.ships[i].gunCapacity)문")
                    .foregroundStyle(.secondary)
            }
            if v.carronadeHere { Text(game.message(266)).font(GameFont.caption) }
            if v.ships[i].gunType != 0 && v.ships[i].gunType != type && v.ships[i].guns > 0 {
                Text(Korean.particles("지금 실린 \(w.navigation.cannons[v.ships[i].gunType - 1].name)(는) 내리게 됩니다."))
                    .font(GameFont.caption).foregroundStyle(.orange)
            }
            CountSlider(value: $count, max: max(0, most), unit: "문").frame(width: 420)
            Button("장착 · 금화 \(min(count, max(0, most)) * price)닢") {
                if game.buyCannons(type, count: min(count, most), ship: i) { count = 0 }
            }.disabled(min(count, most) <= 0)
        }
    }
}
