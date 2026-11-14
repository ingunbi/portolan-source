import Foundation
import PortolanCore

// The tavern's gambling tables (도박): Black Jack against the dealer and poker dice against two
// players. The round state machines are PortolanCore's (TavernMore.swift); the engine keeps the
// table's talk and stage between commands.

var tableGame = -1                 // 0 Black Jack, 1 Dice
var tableStage = "invite"          // invite, betting, playing, round, again, over
var tableStart = 0
var tableFaces: [Int] = []
var tableLines: [TableLine] = []
var bjRound: BlackJackRound?
var diceRound: DiceRound?
var diceOrder = 0
/// The finished dice round's lines are already in `tableLines`.
var diceMerged = false

func tableLine(_ l: TableLine) -> [String: Any] { ["speaker": l.speaker, "text": render([l.line]).first ?? ""] }

/// "금괴 %4ld" "소지금 금화 %4ld" (960, 959): the purse as the tables show it.
func purseText(_ v: Voyage) -> String {
    render((v.gold >= 10000 ? [.msg(960, v.gold / 10000)] : []) + [.msg(959, v.gold % 10000)]).joined(separator: "  ")
}

func gambleState() -> [String: Any] {
    guard let v = voyage else { return [:] }
    var o: [String: Any] = ["game": tableGame, "stage": tableStage, "gold": v.gold,
        "purse": purseText(v), "nation": v.portNation, "hero": v.captain.name,
        "betText": render([.msg(995, diceRound?.limit ?? Gambling.betLimit(gold: v.gold))]).first ?? "",
        "faces": tableFaces, "canPlay": Gambling.canPlay(gold: v.gold), "minBet": Gambling.minBet, "limit": Gambling.betLimit(gold: v.gold)]
    var lines = tableLines
    if let d = diceRound, !diceMerged { lines += d.lines }
    o["lines"] = lines.suffix(6).map(tableLine)
    if let r = bjRound {
        let hole = r.finished && r.holeShown
        let dealer: [Int] = r.finished ? [hole ? r.dealer[0] : -1] + r.dealer.dropFirst() : [-1]
        o["bj"] = ["player": r.player, "dealer": dealer, "playerTotal": r.playerTotal, "placed": r.placed, "bet": r.bet,
                   "finished": r.finished, "holeShown": hole,
                   "dealerTotal": hole ? (r.dealerScore == 0 ? BlackJack.total(r.dealer) : r.dealerScore) : -1,
                   "names": r.player.map { BlackJack.name($0) }, "dealerNames": dealer.map { $0 < 0 ? "?" : BlackJack.name($0) },
                   "remark": render([.msg(978, r.playerTotal)]).first ?? "",
                   "dealerRemark": hole ? render([.msg(978, r.dealerScore == 0 ? BlackJack.total(r.dealer) : r.dealerScore)]).first ?? "" : ""] as [String: Any]
    }
    if let r = diceRound {
        let winners = r.result.map { [[0], [1], [2], [1, 2], [0, 1, 2], [0, 1], [0, 2]][min($0, 6)] } ?? []
        var phase = "betting", offer = 0
        switch r.phase {
        case .betting: phase = "betting"
        case .offer(let n): phase = "offer"; offer = n
        case .rolling: phase = "rolling"
        case .finished: phase = "finished"
        }
        o["dice"] = ["phase": phase, "offer": offer, "bet": r.bet, "limit": r.limit, "rolls": r.rolls, "dice": r.dice, "held": r.held,
                     "hands": r.dice.map { $0.isEmpty ? "" : Dice.handName(rank: Dice.rank($0)) }, "winners": winners,
                     "ask": message(984)] as [String: Any]
    }
    return o
}

func gambleReply(_ extra: [String: Any] = [:]) -> [String: Any] {
    var o = townReply(["ok": true, "gamble": gambleState()])
    for (k, v) in extra { o[k] = v }
    return o
}

private func leaveTable() {
    let v = voyage!
    if tableGame == 0 { tableLines += BlackJack.farewell(start: tableStart, gold: v.gold).map { TableLine(1, $0) } }
    else { tableLines += Dice.farewell(start: tableStart, gold: v.gold) }
    tableStage = "over"
}

private func newRound() {
    if tableGame == 0 { bjRound = act { BlackJackRound(&$0) }; tableStage = "betting" }
    else { diceRound = act { DiceRound(order: diceOrder, &$0) }; diceMerged = false; tableStage = "round" }
}

private func settleBlackJack() {
    guard let r = bjRound, let s = r.settlement else { return }
    tableLines.append(TableLine(1, .msg(s.message)))
    if Gambling.canPlay(gold: voyage!.gold) { tableLines.append(TableLine(1, .msg(981))); tableStage = "again" }
    else { tableLines.append(TableLine(1, .msg(980))); leaveTable() }
}

private func stepDice(_ f: (inout DiceRound, inout Voyage) -> Void) {
    guard var r = diceRound else { return }
    act { f(&r, &$0) }
    diceRound = r
    guard r.phase == .finished else { return }
    diceOrder = r.order
    tableLines += r.lines
    diceMerged = true
    if Gambling.canPlay(gold: voyage!.gold) { tableLines.append(TableLine(1, .msg(1005))); tableStage = "again" }
    else { tableLines += [TableLine(1, .msg(1003)), TableLine(2, .msg(1004))]; leaveTable() }
}

func gamblingCommand(_ name: String, _ cmd: [String: Any]) -> [String: Any]? {
    func int(_ k: String) -> Int? { (cmd[k] as? NSNumber)?.intValue }
    guard name.hasPrefix("gamble_"), voyage != nil else { return nil }
    switch name {
    case "gamble_enter":
        // A hero without a coin is turned away (1010).
        if let l = voyage!.gamblingRefusal {
            let face = act { $0.gamblerFace() }
            return townReply(["ok": true, "refusal": ["face": face, "line": render([l]).first ?? "", "nation": voyage!.portNation], "gamble": gambleState()])
        }
        tableGame = -1; tableStage = "invite"; bjRound = nil; diceRound = nil
        return gambleReply()
    case "gamble_open":
        guard let g = int("game") else { return gambleReply() }
        tableGame = g; tableStart = voyage!.gold; tableStage = "invite"; bjRound = nil; diceRound = nil; diceOrder = 0
        if g == 0 {
            tableFaces = [act { $0.gamblerFace() }]
            tableLines = [TableLine(1, .msg(979))]
        } else {
            tableFaces = [act { $0.gamblerFace() }, act { $0.gamblerFace() }]
            tableLines = [TableLine(1, .msg(1001))]
        }
        return gambleReply()
    case "gamble_close":
        tableGame = -1; bjRound = nil; diceRound = nil
        return gambleReply()
    case "gamble_yes", "gamble_no":
        let yes = name == "gamble_yes"
        if tableStage == "invite" {
            if yes { if tableGame == 1 { tableLines.append(TableLine(2, .msg(1002))) }; newRound() } else { tableGame = -1 }
        } else if tableStage == "again" {
            if yes { newRound() } else { leaveTable() }
        }
        return gambleReply()
    case "gamble_bet":
        guard let n = int("amount") else { return gambleReply() }
        if tableGame == 0, var r = bjRound {
            if let remark = act({ r.place(n, &$0) }) {
                bjRound = r; tableLines.append(TableLine(1, remark)); tableStage = "playing"; settleBlackJack()
            }
        } else if tableGame == 1 { stepDice { $0.place(n, &$1) } }
        return gambleReply()
    case "gamble_hit", "gamble_stand":
        guard var r = bjRound else { return gambleReply() }
        act { v in if name == "gamble_hit" { r.hit(&v) } else { r.stand(&v) } }
        bjRound = r; settleBlackJack()
        return gambleReply()
    case "gamble_answer":
        stepDice { $0.answer((cmd["yes"] as? Bool) ?? false, &$1) }
        return gambleReply()
    case "gamble_stay":
        stepDice { $0.stay(&$1) }
        return gambleReply()
    case "gamble_reroll":
        let keep = ((cmd["keep"] as? [Any]) ?? []).map { ($0 as? Bool) ?? ($0 as? NSNumber)?.boolValue ?? false }
        let held = keep + [Bool](repeating: false, count: max(0, 5 - keep.count))
        stepDice { $0.reroll(keeping: Array(held.prefix(5)), &$1) }
        return gambleReply()
    default: return nil
    }
}
