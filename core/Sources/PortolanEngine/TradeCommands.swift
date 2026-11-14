import Foundation
import PortolanCore

// The trading post (교역소) as engine commands: what is on offer, the hold, buying, selling, the
// haggle and the price list. The rules are PortolanCore's (Market.swift, Voyage.swift).

func tradeState() -> [String: Any] {
    let v = voyage!
    let nav = world.navigation
    let m = v.market(in: world)
    var o: [String: Any] = [:]
    o["ships"] = v.ships.enumerated().map { (i, s) -> [String: Any] in
        ["index": i, "name": s.name, "freeCargo": s.freeCargo, "cargoCap": s.cargoCapacity,
         "holds": s.holds.map { lot -> [String: Any] in
             ["good": lot.good, "name": nav.goods[lot.good].name, "amount": lot.amount, "price": v.salePrice(of: lot.good, in: world),
              "category": nav.categories[nav.goods[lot.good].category]]
         }]
    }
    o["offers"] = v.offers(in: world).map { off -> [String: Any] in
        let cat = nav.goods[off.good].category
        return ["good": off.good, "name": nav.goods[off.good].name, "category": nav.categories[cat],
                "price": v.price(of: off, in: world), "remark": Trade.remark(index: m.prices[cat])]
    }
    o["holdsMax"] = Trade.holds
    o["licensed"] = v.licensed(in: world)
    o["categories"] = (0..<10).map { v.memory.name(0x7CA, $0) }
    return o
}

func tradeCommand(_ name: String, _ cmd: [String: Any]) -> [String: Any]? {
    func int(_ k: String) -> Int? { (cmd[k] as? NSNumber)?.intValue }
    guard name.hasPrefix("trade_"), voyage != nil else { return nil }
    var note = ""
    var extra: [String: Any] = [:]
    switch name {
    case "trade_state": break
    case "trade_buy":
        guard let good = int("good"), let n = int("amount"), let ship = int("ship"),
              let off = voyage!.offers(in: world).first(where: { $0.good == good }) else { break }
        let unit = int("unit")
        let ok = act { $0.buy(off, amount: n, ship: ship, in: world, unitPrice: unit) }
        extra["done"] = ok
    case "trade_sell":
        guard let hold = int("hold"), let n = int("amount"), let ship = int("ship") else { break }
        extra["done"] = act { $0.sell(hold: hold, amount: n, ship: ship, in: world) }
    case "trade_haggle":
        // One round of haggling: the trader's lines are MESSAGE.DAT 10, 11, 12, 851, 852.
        guard let good = int("good"), let offer = int("offer"),
              let off = voyage!.offers(in: world).first(where: { $0.good == good }) else { break }
        switch voyage!.bargain(off, offer: offer, in: world) {
        case .accepted(let p): extra["deal"] = p; note = message(10)
        case .counter(let p): note = message(12).replacingOccurrences(of: "%d", with: "\(p)")
        case .settled(let p): extra["deal"] = p; note = message(852).replacingOccurrences(of: "%u", with: "\(p)")
        case .firm: note = message(11)
        }
    case "trade_prices":
        // 시세·물가 (0x24C72): free, no time.
        let c = max(0, min(9, int("category") ?? 0))
        let list = voyage!.priceList(category: c, in: world)
        let catName = voyage!.memory.name(0x7CA, c)
        extra["prices"] = ["category": c, "title": fill(151, catName, "\(list.index)"),
                           "rows": list.rows.map { r -> [String: Any] in
                               ["good": r.good, "name": world.navigation.goods[r.good].name, "buy": r.buy ?? -1, "sell": r.sell] }]
    default: return nil
    }
    var o = townReply(["ok": true, "note": note, "trade": tradeState()])
    for (k, v) in extra { o[k] = v }
    return o
}
