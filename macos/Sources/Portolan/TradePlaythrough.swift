#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import PortolanCore

/// Continues the new-game playthrough with the same earned money, ship and stores.
/// Trade quantities and transactions use the live SwiftUI accessibility controls.
enum TradePlaythrough {
    static func run(game: Game, capture: @escaping (String, Game) -> Void,
                    press: @escaping (String) throws -> Void,
                    setValue: @escaping (String, Double) throws -> Void,
                    answer: @escaping (Game, Int) throws -> Void) throws {
        try Driver(game: game, capture: capture, press: press, setValue: setValue, answer: answer).run()
    }

    private final class Driver {
        let game: Game
        let capture: (String, Game) -> Void
        let press: (String) throws -> Void
        let setValue: (String, Double) throws -> Void
        let answer: (Game, Int) throws -> Void
        let size = CGSize(width: 960, height: 600)

        init(game: Game, capture: @escaping (String, Game) -> Void,
             press: @escaping (String) throws -> Void, setValue: @escaping (String, Double) throws -> Void,
             answer: @escaping (Game, Int) throws -> Void) {
            self.game = game; self.capture = capture; self.press = press
            self.setValue = setValue; self.answer = answer
        }

        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Playthrough.Failure(message: "Trade: " + message) }
        }

        func log(_ message: String) { print("trade-playthrough: " + message) }

        func clearMessage() throws {
            var count = 0
            while let text = game.portMessageText {
                try require(count < 8, "port message failed to close")
                log("message: " + text.replacingOccurrences(of: "\n", with: " / "))
                try press("portolan.portMessage.dismiss")
                count += 1
            }
        }

        func readDialogue(_ context: String) throws {
            var count = 0
            while let session = game.session, let prompt = session.prompt {
                try require(count < 600, "\(context) dialogue failed to end")
                if count == 0 { capture("trade_\(context)_dialogue", game) }
                switch prompt {
                case .next: try answer(game, 0)
                case .yesNo: try answer(game, 1)
                case .menu(let choices):
                    try require(!choices.isEmpty, "\(context) has an empty choice menu")
                    try answer(game, 0)
                case .duel, .ending:
                    throw Playthrough.Failure(message: "Trade: unexpected duel/ending during \(context)")
                }
                count += 1
            }
            try require(game.session == nil, "\(context) session is blocking without a prompt")
        }

        func visit(_ service: HarborPanel) throws {
            try clearMessage()
            if !service.isOpen(tick: game.status.tick) {
                try TownWalkDriver.enter(.inn, game: game, size: size, press: press)
                try readDialogue("inn")
                try require(game.panel == .inn, "could not enter the inn to wait for opening time")
                var waits = 0
                while !service.isOpen(tick: game.status.tick) {
                    try require(waits < 16, "the trading post did not open after inn waits")
                    try clearMessage()
                    try press("portolan.inn.wait")
                    waits += 1
                }
            }
            try clearMessage()
            try TownWalkDriver.enter(service, game: game, size: size, press: press)
            try readDialogue(service.title)
            try clearMessage()
            try require(game.panel == service, "\(service.title) did not open")
        }

        func run() throws {
            try require(game.harbor?.id == 0 && !game.status.ships.isEmpty, "requires the real first voyage back in Lisbon")
            try visit(.market)
            let before = game.status, world = game.world
            guard let salt = before.offers(in: world).first(where: { world.navigation.goods[$0.good].name == "돌소금" }),
                  let destination = world.ports.first(where: { $0.name == "세빌리아" }) else {
                throw Playthrough.Failure(message: "Trade: Lisbon salt or Seville is missing")
            }
            let unit = before.price(of: salt, in: world)
            let market = before.market(in: world), category = world.navigation.goods[salt.good].category
            let untaxed = salt.basePrice * (market.prices[category] + 50) / 100
            try require(unit == untaxed * (before.licensed(in: world) ? 10 : 12) / 10, "displayed unit price does not include the correct licence surcharge")
            let maximum = before.maxPurchase(salt, ship: 0, in: world)
            try require(maximum >= 2, "earned funds/stores leave no room for a meaningful trade")
            try require(maximum == min(before.gold / unit, before.ships[0].freeCargo), "purchase maximum ignores money or cargo space")
            try rejectedTransactions(offer: salt)

            // Selecting and cancelling a quantity must be free of gameplay side effects.
            try press("portolan.trade.offer.\(salt.good)")
            try setValue("portolan.trade.buy.quantity", Double(min(3, maximum)))
            capture("trade_01_lisbon_quantity", game)
            try press("portolan.trade.buy.cancel")
            _ = try? press("portolan.trade.buy") // disabled at zero, even a native press must not transact
            try unchanged(from: before, context: "cancelled/zero purchase")

            // Buy through the actual slider + button. Keep a little cash for voyage expenses.
            let amount = max(1, min(maximum, (before.gold - min(100, before.gold / 5)) / unit))
            try setValue("portolan.trade.buy.quantity", Double(amount))
            capture("trade_01b_purchase_total", game)
            try press("portolan.trade.buy")
            try require(game.status.gold == before.gold - amount * unit, "buy button charged the wrong total")
            let previousGoods = before.ships[0].holds.filter { $0.good == salt.good }.reduce(0) { $0 + $1.amount }
            try require(game.status.ships[0].holds.filter { $0.good == salt.good }.reduce(0) { $0 + $1.amount } == previousGoods + amount, "bought salt did not enter the selected ship")
            try require(game.status.ships[0].freeCargo == before.ships[0].freeCargo - amount, "purchase did not consume cargo space")
            var boughtMarket = market
            let purchaseTotal = (amount * unit) & 0xFFFF
            boughtMarket.prices[category] = min(100, boughtMarket.prices[category] + min(10, purchaseTotal / (market.economy + 500)))
            boughtMarket.prices = boughtMarket.prices.map { min(100, $0 + min(3, purchaseTotal / 1000)) }
            try require(game.status.market(in: world) == boughtMarket, "purchase changed the price index incorrectly")
            capture("trade_02_salt_bought", game)
            log("리스본 돌소금 \(amount)개 × \(unit)닢 구입; 금화 \(before.gold)→\(game.status.gold), 적재 여유 \(before.ships[0].freeCargo)→\(game.status.ships[0].freeCargo); 취소·0개·잔액/공간 초과 검증")

            try visit(.harbor)
            try require(game.status.departureCheck().ok, "trade left the ship unable to depart")
            try press("portolan.harbor.depart")
            try require(game.question != nil, "no departure confirmation")
            try press("portolan.question.yes")
            try readDialogue("departure")
            try require(game.harbor == nil, "departure confirmation left the ship in Lisbon")
            try require(game.beginPlannedRoute(to: destination), "the known Lisbon–Seville sea route cannot be set")
            let origin = (game.status.x, game.status.y), stores = (game.status.water, game.status.food)
            capture("trade_03_seville_course", game)
            var frames = 0
            while game.dockable?.id != destination.id {
                try require(frames < 12_000, "Seville's docking radius was never reached: position \(game.status.x),\(game.status.y), sail \(game.status.sail), waypoint \(String(describing: game.status.waypoint))")
                game.update(dt: 1.0 / 60, viewSize: size)
                if game.session != nil { try readDialogue("at_sea") }
                try require(game.status.gameOver == nil, "voyage ended: \(game.status.gameOver ?? "")")
                try require(game.encounter == nil && game.battle == nil, "an actual encounter needs playing before the trade route can continue")
                var acknowledgedPages = 0
                while let pages = game.seaEvent {
                    try require(!pages.isEmpty && acknowledgedPages < 32, "sea event pages did not finish within 32 acknowledgements")
                    log("sea event page: " + pages[0])
                    capture("trade_at_sea_event_\(frames)_page_\(acknowledgedPages + 1)", game)
                    try press("portolan.sea-event.continue")
                    let remaining = Array(pages.dropFirst())
                    try require(game.seaEvent == (remaining.isEmpty ? nil : remaining),
                                "sea event acknowledgement did not advance exactly one page")
                    acknowledgedPages += 1
                }
                frames += 1
            }
            try require(hypot(world.deltaX(from: origin.0, to: game.status.x), game.status.y - origin.1) > 10,
                        "ship did not actually sail between ports")
            game.dock()
            try require(game.harbor?.id == destination.id, "arrival action did not dock at Seville")
            try require(game.status.route.isEmpty && game.status.waypoint == nil, "docking left the old route active")
            capture("trade_04_seville_arrival", game)
            log("실제 항로 \(frames)프레임 항해 후 세빌리아 입항; 식수 \(stores.0)→\(game.status.water), 식량 \(stores.1)→\(game.status.food)")

            try visit(.market)
            guard let hold = game.status.ships[0].holds.firstIndex(where: { $0.good == salt.good }) else {
                throw Playthrough.Failure(message: "Trade: cargo disappeared while sailing")
            }
            let beforeSale = game.status, saleUnit = beforeSale.salePrice(of: salt.good, in: world)
            try press("portolan.trade.hold.\(hold)")
            try setValue("portolan.trade.sell.quantity", 1)
            try press("portolan.trade.sell.cancel")
            _ = try? press("portolan.trade.sell")
            try unchanged(from: beforeSale, context: "cancelled/zero sale")
            try setValue("portolan.trade.sell.quantity", Double(amount))
            capture("trade_04b_sale_total", game)
            try press("portolan.trade.sell")
            try require(game.status.gold == min(Trade.goldCap, beforeSale.gold + amount * saleUnit), "sale button paid the wrong total")
            try require(game.status.ships[0].holds.filter { $0.good == salt.good }.reduce(0) { $0 + $1.amount } == previousGoods, "sold cargo was not removed")
            try require(game.status.ships[0].freeCargo == beforeSale.ships[0].freeCargo + amount, "sale did not release cargo space")
            var soldMarket = beforeSale.market(in: world)
            let saleTotal = amount * saleUnit
            soldMarket.prices[category] = max(0, soldMarket.prices[category] - min(10, saleTotal / (soldMarket.economy + 500)))
            soldMarket.prices = soldMarket.prices.map { max(0, $0 - min(3, (saleTotal & 0xFFFF) / 1000)) }
            try require(game.status.market(in: world) == soldMarket, "sale changed the price index incorrectly")
            try require(saleUnit > unit, "the Lisbon specialty route unexpectedly loses money before sailing costs")
            capture("trade_05_salt_sold", game)
            log("PASS — UI 구입→정상 출항→실제 항로→세빌리아 입항→UI 판매; \(amount)개 × \(saleUnit)닢 판매, 교역 차익 \(amount * (saleUnit - unit))닢, 보유 금화 \(game.status.gold); 시세 \(beforeSale.market(in: world).prices)→\(soldMarket.prices); 자금·좌표·시각 직접대입 없음")
        }

        func unchanged(from before: Voyage, context: String) throws {
            try require(game.status.gold == before.gold && game.status.ships[0].holds == before.ships[0].holds &&
                        game.status.ships[0].freeCargo == before.ships[0].freeCargo &&
                        game.status.market(in: game.world) == before.market(in: game.world), "\(context) changed money/cargo/prices")
        }

        /// Rejected boundary requests run against a value copy of the *earned* state.
        /// No trial resources or clock/coordinate values are injected into the live game.
        func rejectedTransactions(offer: Offer) throws {
            let original = game.status, world = game.world
            for amount in [-1, 0, original.maxPurchase(offer, ship: 0, in: world) + 1,
                           original.ships[0].freeCargo + 1, original.gold / max(1, original.price(of: offer, in: world)) + 1] {
                var trial = original
                try require(!trial.buy(offer, amount: amount, ship: 0, in: world), "invalid buy quantity \(amount) was accepted")
                try require(trial.gold == original.gold && trial.ships[0].holds == original.ships[0].holds && trial.market(in: world) == original.market(in: world), "rejected buy mutated its state")
            }
        }
    }
}
