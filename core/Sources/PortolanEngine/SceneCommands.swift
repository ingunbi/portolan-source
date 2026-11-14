import Foundation
import PortolanCore

// The scenario scripts (SNR*.DAT) as engine commands. A script runs until it needs the player:
// a click to go on, a menu, a yes/no, a sword duel or an ending. The app shows what the engine
// reports (speech windows, the picture, the prompt) and sends the answer back.

/// The script session running now, and the building whose entry started it (-1: none).
var script: ScriptSession?
var sceneBuilding = -1
/// A sword duel called by a script (opcode E8).
var sduel: DuelState?
/// What the building does once the running scene is over (the argument says whether the script sent the hero away).
var afterScene: ((Bool) -> [String: Any])?

/// Runs a script of a building's own (palace audience, guild jobs) or of a sea event (`atSea: true`, with the event as
/// `key1`). A scene with nothing to show is over at once.
func runScene(key1: Int? = nil, key2: Int, atSea: Bool = false, contexts: [ScriptContext], then: @escaping (Bool) -> [String: Any]) -> [String: Any] {
    guard var v = voyage else { return townReply(["ok": false]) }
    let port: Int? = atSea ? nil : v.townPort
    var s = ScriptSession(key1: key1 ?? (port ?? 0), key2: key2, port: port, contexts: contexts)
    s.advance(&v, in: world)
    voyage = v
    if s.done { return townReply(then(s.leave).merging(["ok": true]) { a, _ in a }) }
    script = s; sceneBuilding = -1; sduel = nil; afterScene = then
    return sceneReply()
}

func duelJSON(_ d: DuelState, _ v: Voyage) -> [String: Any] {
    ["a": d.a, "b": d.b, "meter": d.meter, "turn": d.turn, "playerIsA": d.playerIsA, "line": d.lastLine,
     "finished": d.finished, "damage": d.lastDamage,
     "nameA": v.memory.person(d.a).name, "nameB": v.memory.person(d.b).name]
}

/// The script's state for the app.
func sceneJSON(_ s: ScriptSession, _ v: Voyage) -> [String: Any] {
    var o: [String: Any] = ["done": s.done, "leave": s.leave, "hero": v.memory[DS.heroID]]
    if let e = s.ending { o["ending"] = e }
    guard let r = s.run else { return o }
    o["windows"] = r.windows.filter { $0.id != 3 }.sorted { $0.id < $1.id }.map { w -> [String: Any] in
        ["id": w.id, "face": w.face ?? -1, "speaker": w.speaker ?? "", "text": w.text]
    }
    o["current"] = r.current
    o["picture"] = r.picture ?? -1
    o["music"] = r.music ?? -1
    switch r.prompt {
    case .next?: o["prompt"] = ["kind": "next"]
    case .menu(let choices)?: o["prompt"] = ["kind": "menu", "choices": choices]
    case .yesNo?: o["prompt"] = ["kind": "yesNo"]
    case .duel(let who)?: o["prompt"] = ["kind": "duel", "opponent": who, "opponentName": v.memory.person(who).name]
    case .ending(let code)?: o["prompt"] = ["kind": "ending", "code": code]
    case nil: break
    }
    return o
}

/// After the script moved on: its state, and, once it is over, what the building's door does next.
func sceneReply() -> [String: Any] {
    guard let s = script, let v = voyage else { return townReply(["ok": true]) }
    var o: [String: Any] = ["ok": true, "scene": sceneJSON(s, v)]
    if let d = sduel { o["duel"] = duelJSON(d, v) }
    if s.done {
        let leave = s.leave
        script = nil
        if let f = afterScene {
            afterScene = nil
            o.merge(f(leave)) { a, _ in a }
        }
        if sceneBuilding >= 0 {
            let b = sceneBuilding
            sceneBuilding = -1
            o["entry"] = finishEntry(b, leave: leave)
        }
    }
    return townReply(o)
}

/// The town's own rules once the entry scripts let the hero in (0x1B150).
func finishEntry(_ b: Int, leave: Bool) -> [String: Any] {
    guard var v = voyage else { return ["ok": false] }
    if leave && b != 4 { return ["ok": true, "admitted": false, "lines": [String]()] }
    let entry = v.enterBuilding(b)
    voyage = v
    guard entry.admitted else { return ["ok": true, "admitted": false, "lines": render(entry.lines)] }
    openBuilding = b
    if b == 1 { tavern = Tavern(market: v.market(in: world), drinks: world.navigation.drinks, charm: v.captain.charm) }
    let greeting: [TownLine]
    var deserters: [Int] = []
    switch b {
    case 8: greeting = [v.bankGreeting(portName: world.ports.first(where: { $0.id == v.townPort })?.name ?? "")]
    case 9: greeting = [.msg(238)]
    case 10: greeting = [v.churchGreeting()]
    case 11: greeting = [.msg(298)]
    case 5: greeting = v.palaceGreeting()
    case 6: greeting = v.guildGreeting()
    case 1: greeting = v.tavernGreeting(in: world)
    case 3:
        // The quay: the guards go, then the rumour of a summons and the greeting (msg 56).
        var vv = v
        vv.harbourDropsGuards()
        let rumour = vv.harbourRumour(port: vv.townPort, in: world)
        // Companions who may want to stay ashore (0x280A3), asked after the greeting.
        if vv.townPort < 100 { deserters = vv.desertersAtHarbour() }
        voyage = vv
        greeting = [.text((rumour.map { $0 + "\n" } ?? "") + message(56))]
    default: greeting = []
    }
    var o: [String: Any] = deserters.isEmpty ? ["ok": true, "lines": render(entry.lines + greeting)]
        : askDeserters(deserters, intro: entry.lines + greeting)
    o["ok"] = true; o["admitted"] = true
    if let vv = voyage {
        o["wallet"] = walletInfo(vv)
        o["panel"] = panelInfo(b)
    }
    return o
}

/// A companion with little loyalty and a small wage may stay ashore: keep him for ten gold more
/// a month (801, 붙든다) or let him go (798, 보낸다). The list runs last to first so the indices hold.
func askDeserters(_ list: [Int], intro: [TownLine]) -> [String: Any] {
    guard let k = list.last, let v = voyage, v.officers.indices.contains(k) else { return talk(intro) }
    let o = v.officers[k]
    let rest = Array(list.dropLast())
    let text: TownLine = .text("\(o.name): \(message(798))\n\(fill(801, "\(o.salary + 10)"))")
    return talk(intro + [text], ask: ["kind": "yesNo", "yes": "붙든다", "no": "보낸다"]) { a in
        if case .yes(true) = a { act { $0.keepOfficer(k) } } else { act { $0.dismissOfficer(k) } }
        return askDeserters(rest, intro: [])
    }
}

func sceneCommand(_ name: String, _ cmd: [String: Any]) -> [String: Any]? {
    func int(_ k: String) -> Int? { (cmd[k] as? NSNumber)?.intValue }
    switch name {
    case "ending_info":
        // What the ending sequence (END.EXE) reads of the hero: who he is and which ruler greets him.
        guard let v = voyage else { return ["ok": false] }
        let m = v.memory, h = v.heroID
        return ["ok": true, "hero": h, "given": m.string(DS.person(h), max: 13),
                "family": m.string(DS.person(h) + 0x0D, max: 13), "nation": v.captain.nation]
    case "ending_text":
        // A line of the ending with the hero's names and the Korean particles settled.
        guard let v = voyage, let t = cmd["text"] as? String else { return ["ok": false] }
        let m = v.memory, h = v.heroID
        let text = t.replacingOccurrences(of: "{given}", with: m.string(DS.person(h), max: 13))
            .replacingOccurrences(of: "{family}", with: m.string(DS.person(h) + 0x0D, max: 13))
        return ["ok": true, "text": Korean.particles(text)]
    case "ending_finish":
        // After END.EXE (MAIN 0x17032): the story is over, story mode off (bit 0x40 kept only after the duke ending).
        guard var v = voyage else { return ["ok": false] }
        v.memory[0xC30] &= ~0x02
        if (int("code") ?? 0) != 0x0F { v.memory[0xC30] &= ~0x40 }
        v.storyOn = false
        voyage = v
        script = nil; pending = nil
        return townReply(["ok": true])
    case "scene_start":
        // A script of its own (palace audience, guild jobs): key2 is the building or event key.
        guard var v = voyage, let key2 = int("key2") else { return ["ok": false, "error": "no game"] }
        let port = int("port") ?? v.townPort
        let contexts: [ScriptContext] = (cmd["contexts"] as? [String])?.compactMap {
            $0 == "hero" ? .hero : $0 == "shared" ? .shared : nil } ?? [.shared, .hero]
        var s = ScriptSession(key1: int("key1") ?? port, key2: key2, port: port, contexts: contexts)
        s.advance(&v, in: world)
        voyage = v; script = s; sceneBuilding = -1; sduel = nil; afterScene = nil
        return sceneReply()
    case "scene_answer":
        guard var s = script, var v = voyage, let a = int("value") else { return sceneReply() }
        s.answer(a, &v, in: world)
        voyage = v; script = s
        return sceneReply()
    case "scene_state":
        return sceneReply()
    case "sduel_start":
        guard let s = script, case .duel(let who)? = s.prompt, let v = voyage else { return sceneReply() }
        sduel = Duel.start(hero: v.memory[DS.heroID], against: who, v)
        return sceneReply()
    case "sduel_move":
        guard var d = sduel, var v = voyage, let m = int("move") else { return sceneReply() }
        Duel.step(&d, move: m, &v)
        voyage = v
        if d.finished {
            sduel = nil
            guard var s = script else { return sceneReply() }
            s.answer(d.meter, &v, in: world)
            voyage = v; script = s
        } else {
            sduel = d
        }
        return sceneReply()
    default: return nil
    }
}
