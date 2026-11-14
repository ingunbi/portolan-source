import SwiftUI
import PortolanCore

struct TradePanel: View {
    @ObservedObject var game: Game
    var body: some View {
        let generation = game.presentationGeneration
        TradeSessionPanel(game: game, generation: generation).id(generation)
    }
}

/// Quantities and negotiated prices belong to one presented voyage. Retained native
/// controls must neither mutate a new voyage nor be rebound to its transaction state.
private struct TradeSessionPanel: View {
    @ObservedObject var game: Game
    let generation: Int
    @State private var ship = 0
    @State private var pick = 0
    @State private var buyCount = 0
    @State private var hold = 0
    @State private var sellCount = 0
    /// Unit price the trader agreed to (0x24064), and the offer being made.
    @State private var deal: (good: Int, price: Int)?
    @State private var ask = 0
    @State private var talk = ""
    @State private var showPrices = false
    @State private var showInvestment = false
    @State private var showBargain = false

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
        let offers = v.offers(in: w)
        let selectedShip = min(max(0, ship), v.ships.count - 1)
        let s = v.ships[selectedShip]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if v.ships.count > 1 {
                    HStack(spacing: 8) {
                        Text("배").fixedSize()
                        GamePicker("배", selection: $ship,
                                   options: v.ships.indices.map { ($0, v.ships[$0].name) })
                    }.frame(width: 240)
                } else {
                    Text(s.name).font(GameFont.headline)
                }
                Button("시세·물가") {
                    guard game.presentationGeneration == generation else { return }
                    showPrices.toggle()
                }
                    .accessibilityIdentifier("portolan.trade.prices")
                    .popover(isPresented: $showPrices) { PriceList(game: game).padding(16) }
                Spacer()
                Text("적재 여유 \(s.freeCargo)통 · 짐칸 \(s.holds.count) / \(Trade.holds)")
                    .font(GameFont.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(v.licensed(in: w) ? "무역면허 적용 · 구입 가산금 면제" : "무역면허 없음 · 구입 단가에 20% 가산금 포함")
                .font(GameFont.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    if offers.indices.contains(pick) {
                        let o = offers[pick]
                        let list = v.price(of: o, in: w)
                        let unit = deal.flatMap { $0.good == o.good ? $0.price : nil } ?? list
                        let most = v.maxPurchase(o, ship: selectedShip, in: w, unitPrice: unit)
                        let n = min(buyCount, most)
                        let index = v.market(in: w).prices[w.navigation.goods[o.good].category]
                        HStack {
                            Text("사기").font(GameFont.headline)
                            Text("\(w.navigation.goods[o.good].name) · \(unit)닢/개").font(GameFont.callout).foregroundStyle(Theme.gold).fixedSize(horizontal: false, vertical: true)
                        }
                        TradeQuantity(value: $buyCount, maximum: most, id: "portolan.trade.buy.quantity")
                        if most == 0 {
                            Text(s.holds.count >= Trade.holds ? "짐칸이 모두 사용 중입니다. 적하를 먼저 판매하세요." :
                                 s.freeCargo == 0 ? "적재 공간이 없습니다. 적하나 보급품을 줄이세요." : "구입할 금화가 부족합니다.")
                                .font(GameFont.caption).foregroundStyle(Theme.gold)
                        }
                        HStack {
                            Button("구입 · \(n * unit)닢") {
                                guard game.presentationGeneration == generation else { return }
                                if game.buy(o, amount: n, ship: selectedShip, unitPrice: unit) {
                                    buyCount = 0; deal = nil; talk = ""
                                }
                            }.disabled(n == 0)
                                .accessibilityIdentifier("portolan.trade.buy")
                            Button("취소") {
                                guard game.presentationGeneration == generation else { return }
                                buyCount = 0; deal = nil; ask = list; talk = ""
                            }
                                .accessibilityIdentifier("portolan.trade.buy.cancel")
                        }
                        ScrollView {
                            VStack(spacing: 1) {
                                ForEach(offers.indices, id: \.self) { i in
                                    row(selected: i == pick, name: w.navigation.goods[offers[i].good].name,
                                        detail: w.navigation.categories[w.navigation.goods[offers[i].good].category],
                                        price: v.price(of: offers[i], in: w)) {
                                        pick = i; ask = v.price(of: offers[i], in: w)
                                        buyCount = 0; deal = nil; talk = ""
                                    }
                                    .accessibilityIdentifier("portolan.trade.offer.\(offers[i].good)")
                                }
                            }
                        }.frame(height: 132)
                        Text(talk.isEmpty ? Trade.remark(index: index) : talk).font(GameFont.caption).foregroundStyle(.secondary)
                        DisclosureGroup("흥정", isExpanded: $showBargain) {
                            HStack {
                                Text("1개").font(GameFont.caption)
                                Stepper("\(ask == 0 ? list : min(ask, list))닢", value: Binding(get: { ask == 0 ? list : min(ask, list) }, set: { ask = $0 }),
                                        in: 1...max(1, list)).monospacedDigit()
                                Button("제안") {
                                    guard game.presentationGeneration == generation else { return }
                                    if ask == 0 { ask = list }
                                    haggle(o, v)
                                }.disabled(unit < list)
                                    .accessibilityIdentifier("portolan.trade.haggle")
                            }.font(GameFont.callout)
                        }.font(GameFont.caption)
                    }
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 5) {
                    if s.holds.indices.contains(hold) {
                        let lot = s.holds[hold]
                        let n = min(sellCount, lot.amount)
                        HStack {
                            Text("팔기").font(GameFont.headline)
                            Text("\(w.navigation.goods[lot.good].name) · \(v.salePrice(of: lot.good, in: w))닢/개")
                                .font(GameFont.callout).foregroundStyle(Theme.gold).fixedSize(horizontal: false, vertical: true)
                        }
                        TradeQuantity(value: $sellCount, maximum: lot.amount, id: "portolan.trade.sell.quantity")
                        HStack {
                            Button("판매 · \(n * v.salePrice(of: lot.good, in: w))닢") {
                                guard game.presentationGeneration == generation else { return }
                                if game.sell(hold: hold, amount: n, ship: selectedShip) { sellCount = 0; hold = 0 }
                            }.disabled(n == 0)
                                .accessibilityIdentifier("portolan.trade.sell")
                            Button("취소") {
                                guard game.presentationGeneration == generation else { return }
                                sellCount = 0
                            }
                                .accessibilityIdentifier("portolan.trade.sell.cancel")
                        }
                    } else {
                        Text("팔기").font(GameFont.headline)
                    }
                    ScrollView {
                        VStack(spacing: 1) {
                            if s.holds.isEmpty {
                                Text("적하가 없습니다.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(s.holds.indices, id: \.self) { k in
                                row(selected: k == hold, name: w.navigation.goods[s.holds[k].good].name,
                                    detail: "\(s.holds[k].amount)개",
                                    price: v.salePrice(of: s.holds[k].good, in: w)) { hold = k; sellCount = 0 }
                                    .accessibilityIdentifier("portolan.trade.hold.\(k)")
                            }
                        }
                    }.frame(height: 132)
                }.frame(maxWidth: .infinity)
            }
            DisclosureGroup("도시 경제에 투자", isExpanded: $showInvestment) {
                InvestBox(game: game, field: .economy)
            }.font(GameFont.caption)
        }
        .padding(10)
        .gameSection()
        .onChange(of: ship) { _, _ in
            buyCount = 0; sellCount = 0; hold = 0; deal = nil; ask = 0; talk = ""
        }
    }

    /// One round of haggling: the trader's lines are MESSAGE.DAT 10, 11, 12, 851, 852.
    private func haggle(_ o: Offer, _ v: Voyage) {
        switch v.bargain(o, offer: ask, in: game.world) {
        case .accepted(let p):
            deal = (o.good, p)
            talk = game.message(10)
        case .counter(let p):
            talk = game.message(12).replacingOccurrences(of: "%d", with: "\(p)")
        case .settled(let p):
            deal = (o.good, p)
            talk = game.message(852).replacingOccurrences(of: "%u", with: "\(p)")
        case .firm:
            talk = game.message(11)
        }
    }

    private func row(selected: Bool, name: String, detail: String, price: Int, action: @escaping () -> Void) -> some View {
        Button {
            guard game.presentationGeneration == generation else { return }
            action()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(GameFont.body.weight(selected ? .semibold : .regular))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(GameFont.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("\(price)닢").font(GameFont.callout).monospacedDigit().fixedSize()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(selected ? Theme.gold.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// A precise quantity control: the slider, one-unit steps and maximum all share a
/// clamped binding, so a changing purse or hold can never leave a stale quantity.
private struct TradeQuantity: View {
    @Binding var value: Int
    let maximum: Int
    let id: String

    private var count: Int { min(max(0, value), maximum) }
    var body: some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { Double(count) }, set: { value = min(maximum, max(0, Int($0.rounded()))) }),
                   in: 0...Double(max(1, maximum)), step: 1)
                .disabled(maximum == 0)
                .accessibilityLabel("거래 수량")
                .accessibilityIdentifier(id)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: value = min(maximum, count + 1)
                    case .decrement: value = max(0, count - 1)
                    @unknown default: break
                    }
                }
            Button { value = max(0, count - 1) } label: { Image(systemName: "minus").frame(width: 12) }
                .disabled(count == 0)
                .accessibilityLabel("수량 1개 줄이기")
                .accessibilityIdentifier(id + ".decrease")
            Text("\(count)개").monospacedDigit().fixedSize().frame(minWidth: 34)
                .accessibilityIdentifier(id + ".count")
                .accessibilityValue(String(count))
            Button { value = min(maximum, count + 1) } label: { Image(systemName: "plus").frame(width: 12) }
                .disabled(count >= maximum)
                .accessibilityLabel("수량 1개 늘리기")
                .accessibilityIdentifier(id + ".increase")
            Button("최대") { value = maximum }
                .disabled(maximum == 0)
                .accessibilityIdentifier(id + ".maximum")
        }
    }
}
