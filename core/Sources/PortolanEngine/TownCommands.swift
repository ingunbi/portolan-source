import Foundation
import PortolanCore

// The town's buildings as engine commands. A building talks like the original's clerks do:
// lines of MESSAGE.DAT, then maybe a question (yes/no, an amount, a choice, a name). The
// question's answer comes back as `town_answer`; what happens next is kept in `pending`.

enum Answer {
    case yes(Bool), amount(Int), choice(Int?), name(String)
}

/// What to do with the answer to the question just asked.
var pending: ((Answer) -> [String: Any])?
/// The port the fleet lies in (nil at sea) and the building opened last.
var dockedPort: Int?
var openBuilding = -1

let buildingTitles = ["교역소", "주점", "조선소", "항구", "여관", "왕궁", "조합", "저택", "은행", "아이템", "교회", "점술가"]

@discardableResult
func act<T>(_ f: (inout Voyage) -> T) -> T {
    var v = voyage!
    let r = f(&v)
    voyage = v
    return r
}

func render(_ lines: [TownLine]) -> [String] { lines.map { $0.rendered(messages) } }

/// The purse and the ship's stores the app shows, and the clock.
func walletInfo(_ v: Voyage) -> [String: Any] {
    var o: [String: Any] = [
        "gold": v.gold, "crew": v.crew, "water": v.water, "food": v.food,
        "year": v.year, "month": v.month, "day": v.dayOfMonth, "tick": v.tick,
        "bank": v.bankBalance, "luck": v.captain.luck, "port": v.townPort, "hasShip": !v.ships.isEmpty,
    ]
    if let s = v.ships.first {
        o["shot"] = s.shot; o["guns"] = s.guns; o["lumber"] = s.lumber
        o["class"] = s.classIndex; o["hull"] = s.hull; o["maxHull"] = s.maxHull
        o["rudder"] = s.rudder; o["sail"] = s.sail
        o["crewCap"] = s.crewCapacity; o["cargoCap"] = s.cargoCapacity; o["gunCap"] = s.gunCapacity
        o["shipName"] = s.name
    }
    return o
}

/// The app's own purse and stores come along (the same fields as `enter_sea`).
func applyWallet(_ v: inout Voyage, _ cmd: [String: Any]) {
    func int(_ k: String) -> Int? { (cmd[k] as? NSNumber)?.intValue }
    if let g = int("gold") { v.gold = g }
    guard !v.ships.isEmpty else { return }
    if let c = int("crew") { v.ships[0].crew = c }
    if let w = int("water") { v.ships[0].water = w }
    if let f = int("food") { v.ships[0].food = f }
    if let s = int("shot") { v.ships[0].shot = s }
    if let l = int("lumber") { v.ships[0].lumber = l }
    if let g = int("guns") { v.ships[0].guns = g; v.ships[0].gunType = max(1, v.ships[0].gunType) }
    // The goods in the hold, as the app keeps them (good → amount).
    if let cargo = cmd["cargo"] as? [String: Any] {
        v.ships[0].holds = cargo.compactMap { k, a in
            guard let g = Int(k), let n = (a as? NSNumber)?.intValue, n > 0 else { return nil }
            return CargoLot(good: g, amount: n)
        }.sorted { $0.good < $1.good }
    }
}

// MARK: - clerks

func talk(_ lines: [TownLine], ask: [String: Any]? = nil, _ next: ((Answer) -> [String: Any])? = nil) -> [String: Any] {
    pending = ask == nil ? nil : next
    var o: [String: Any] = ["ok": true, "lines": render(lines)]
    if let ask { o["ask"] = ask }
    return o
}

/// An amount service: the refusal, or the question and then `perform`.
func offer(_ o: TownAsk, _ perform: @escaping (Int) -> [TownLine]) -> [String: Any] {
    switch o {
    case .refused(let l): return talk(l)
    case .yesNo(let l):
        return talk(l, ask: ["kind": "yesNo"]) { a in
            if case .yes(true) = a { return talk(perform(1)) }
            return talk([])
        }
    case .amount(let l, let most):
        return talk(l, ask: ["kind": "amount", "max": most]) { a in
            if case .amount(let n) = a, n > 0 { return talk(perform(n)) }
            return talk([])
        }
    }
}

/// A yes/no service: the refusal, or the question; `no` is what is said on a no.
func confirm(_ o: TownAsk, no: [TownLine] = [], _ perform: @escaping () -> [TownLine]) -> [String: Any] {
    switch o {
    case .refused(let l): return talk(l)
    case .yesNo(let l), .amount(let l, _):
        return talk(l, ask: ["kind": "yesNo"]) { a in
            if case .yes(true) = a { return talk(perform()) }
            return talk(no)
        }
    }
}

// MARK: - opening hours and entry

/// Opening hours in ticks of the day (0x1B0C1; 3 ticks an hour), by building number.
func isOpen(_ b: Int, tick t: Int) -> Bool {
    switch b {
    case 0, 2, 5, 6, 8: return (12...59).contains(t)
    case 1: return !(12...23).contains(t)
    case 9: return (24...59).contains(t) || (6...8).contains(t)
    case 10: return (12...71).contains(t)
    case 11: return (48...71).contains(t)
    default: return true
    }
}

/// What a building shows besides what its clerk says.
func panelInfo(_ b: Int) -> [String: Any] {
    guard let v = voyage else { return [:] }
    let p = v.townPort
    var o: [String: Any] = [:]
    switch b {
    case 0, 2:                                         // 투자 / 공업투자
        if v.markets.indices.contains(p) {
            let field: InvestField = b == 0 ? .economy : .industry
            let m = v.markets[p]
            o["invest"] = ["field": b == 0 ? "economy" : "industry", "label": b == 0 ? "경제력" : "공업력",
                           "value": b == 0 ? m.economy : m.industry, "done": v.investment(field, port: p), "cap": Invest.monthlyCap]
        }
    case 1:
        o["tavern"] = tavernState()
    case 4:                                            // 항구의 지지율
        if v.markets.indices.contains(p) {
            let m = v.markets[p]
            o["support"] = (0..<6).map { ["nation": Town.nationNames[$0], "pct": m.support[$0], "owner": $0 == m.nation] as [String: Any] }
            o["supportTitle"] = message(1084); o["ownerMark"] = message(1085)
        }
        let guests = v.patrons(at: .inn)
        o["patrons"] = patronsJSON(v, place: .inn)
        o["nobody"] = guests.isEmpty ? render([v.nobodyLine(at: .inn, mood: 0)]).first ?? "" : ""
    case 5:
        let n = v.portNation
        let menu = v.palaceMenu
        o["palace"] = ["nation": n < 6 ? Town.nationNames[n] : "", "standing": n < 6 ? v.standing(with: n) : 0,
                       "defect": menu.defect, "aid": menu.aid, "face": Palace.rulerFaces[min(n, 6)],
                       "ownNation": n == v.nationality, "foreign": n < 6] as [String: Any]
    case 7:
        o["residence"] = residenceState()
    case 8:
        o["balance"] = v.bankBalance
    case 9:
        func info(_ id: Int) -> [String: Any] {
            let it = v.item(id)
            return ["id": id, "name": it.name, "price": it.price, "power": it.power, "type": it.type,
                    "slot": it.slot ?? -1, "equipped": it.equipped]
        }
        o["stock"] = v.shopStock.map(info)
        o["items"] = v.items.map(info)
        o["maxItems"] = Town.maxItems
        o["noStock"] = message(99); o["noItems"] = message(243)
    case 10:
        o["luck"] = v.captain.luck
    case 11:
        o["fortunes"] = Fortune.allCases.map { ["id": $0.rawValue, "name": $0.name, "ok": v.fortunes.contains($0)] as [String: Any] }
    default: break
    }
    return o
}

/// Adds the wallet and the building's panel to a reply.
func townReply(_ r: [String: Any]) -> [String: Any] {
    var o = r
    if let v = voyage {
        o["wallet"] = walletInfo(v)
        if openBuilding >= 0 { o["panel"] = panelInfo(openBuilding) }
        if let e = v.palaceEnding, openBuilding == 5 { o["ending"] = e }
    }
    return o
}

/// Port music by trade region (0x1B6EE): Europe, Africa and the New World, the Middle East, India,
/// the Far East; supply ports have their own.
func portSong(zone: Int, port: Int) -> Int {
    if port >= 100 { return 15 }
    switch zone {
    case 0...2: return 10
    case 4, 9: return 12
    case 10: return 13
    case 11, 12: return 14
    default: return 11
    }
}

func townCommand(_ name: String, _ cmd: [String: Any]) -> [String: Any]? {
    func int(_ k: String) -> Int? { (cmd[k] as? NSNumber)?.intValue }
    switch name {
    case "dock":
        // Arriving in port: the voyage's counters end, the port's market becomes the town's.
        guard var v = voyage, let p = int("port"), let h = world.ports.first(where: { $0.id == p }) else { return ["ok": false, "error": "no port"] }
        applyWallet(&v, cmd)
        if dockedPort != p { v.arrive(at: h, in: world) }
        if let m = world.town(p) { v.arriveInTown(port: p, map: m) }             // the hero below the quay door, the townsfolk placed
        dockedPort = p; openBuilding = -1; pending = nil
        voyage = v
        return townReply(["ok": true, "port": p, "music": portSong(zone: p < 100 ? v.market(in: world).zone : 0, port: p)])

    case "town_enter":
        // Opening a building's door: hours, the hour it takes, the town's rules of admission.
        guard var v = voyage, let b = int("building"), dockedPort != nil else { return ["ok": false, "error": "not in port"] }
        applyWallet(&v, cmd)
        pending = nil; openBuilding = -1
        guard isOpen(b, tick: v.tick) else {
            voyage = v
            return townReply(["ok": true, "admitted": false, "lines": [message(765)]])
        }
        if let m = world.town(v.townPort), v.townDoor(map: m) == b { v.townEnterDoor() }       // one tile below the door (0x1B08E)
        v.passTime(ticks: v.rng(3) + 2, in: world)
        // The scripts of the door first (0x1B08E): the shared ones, then the hero's story.
        var sess = ScriptSession(key1: v.townPort, key2: b, port: v.townPort)
        sess.advance(&v, in: world)
        voyage = v; script = sess; sceneBuilding = b; sduel = nil
        return sceneReply().merging(["admitted": NSNull()]) { a, _ in a }

    case "debug_arm":
        // Testing aid: powder, guns and sailors for the flagship.
        guard var v = voyage, !v.ships.isEmpty else { return ["ok": false] }
        v.ships[0].shot = max(v.ships[0].shot, 120); v.ships[0].guns = max(v.ships[0].guns, 10)
        v.ships[0].gunType = max(1, v.ships[0].gunType); v.ships[0].crew = max(v.ships[0].crew, 30)
        v.exportToMemory(port: nil)
        voyage = v
        return townReply(["ok": true])

    case "debug_story_off":
        // Testing aid: the hero's story scripts stop (the shared ones still run), so every door opens.
        guard var v = voyage else { return ["ok": false] }
        v.storyOn = false
        voyage = v
        return townReply(["ok": true])

    case "debug_gold":
        guard var v = voyage else { return ["ok": false] }
        v.gold += int("amount") ?? 0
        voyage = v
        return townReply(["ok": true])

    case "debug_ship":
        // Testing aid: a caravel with a crew and stores, when the story has not handed one over yet.
        guard var v = voyage else { return ["ok": false] }
        if v.ships.isEmpty {
            var ship = Ship.built(class: int("class") ?? 5, named: "시험호", in: world.navigation)
            ship.crew = 15; ship.water = 260; ship.food = 80
            v.ships = [ship]
        }
        voyage = v
        return townReply(["ok": true])

    case "town_leave":
        // Leaving a building: the church says its farewell.
        var lines: [String] = []
        if openBuilding == 10, let v = voyage { lines = render([v.churchFarewell()]) }
        openBuilding = -1; pending = nil
        return townReply(["ok": true, "lines": lines])

    case "town_answer":
        guard let next = pending else { return townReply(["ok": true, "lines": []]) }
        pending = nil
        let a: Answer
        if let y = cmd["yes"] as? Bool { a = .yes(y) }
        else if let n = int("value") { a = .amount(n) }
        else if cmd["choice"] != nil { a = .choice((int("choice")).flatMap { $0 < 0 ? nil : $0 }) }
        else if let s = cmd["name"] as? String { a = .name(s) }
        else { a = .yes(false) }
        return townReply(next(a))

    case "town_do":
        guard let action = cmd["action"] as? String, voyage != nil else { return ["ok": false, "error": "no action"] }
        pending = nil
        return townReply(townAction(action, cmd))

    default: return nil
    }
}

func guildDesk() -> [String: Any] {
    let v = voyage!
    if v.sharedChapter != 0 && v.sharedVar(6) == 11 { return talk(act { $0.commission11Desk(in: world) }) }
    switch v.guildDesk() {
    case .busy(let l), .summoned(let l): return talk(l)
    case .offers(let kinds):
        return talk([], ask: ["kind": "choice", "options": kinds.map { Guild.jobNames[min($0, 4)] }]) { a in
            guard case .choice(let k?) = a else { return talk([]) }
            act { $0.pickJob(k) }
            return runScene(key2: ScriptKey.guild, contexts: [.shared]) { _ in
                if !act({ $0.settleJob() }) { return guildDesk() }
                return talk([])
            }
        }
    }
}

func townAction(_ action: String, _ cmd: [String: Any]) -> [String: Any] {
    func int(_ k: String) -> Int? { (cmd[k] as? NSNumber)?.intValue }
    if let r = tavernAction(action, cmd) { return r }
    if let r = residenceAction(action, cmd) { return r }
    if action.hasPrefix("inn."), let r = patronTalk(String(action.dropFirst(4)), cmd, place: .inn) { return r }
    let v = voyage!
    switch action {
    // 은행
    case "bank.deposit": return offer(v.depositOffer()) { n in act { $0.deposit(n) } }
    case "bank.withdraw": return offer(v.withdrawOffer()) { n in act { $0.withdraw(n) } }
    case "bank.borrow": return offer(v.borrowOffer()) { n in act { $0.borrow(n) } }
    case "bank.repay": return offer(v.repayOffer()) { n in act { $0.repay(n) } }

    // 교회
    case "church.pray": return talk(act { $0.pray() })
    case "church.donate": return offer(v.donationOffer()) { n in act { $0.donate(n) } }

    // 점술가: every reading costs 50; 동료운 first asks whose
    case "fortune.read":
        guard let f = Fortune(rawValue: int("fortune") ?? 0) else { return talk([]) }
        let fee = { (companion: Int?) -> [String: Any] in
            talk([.msg(299)], ask: ["kind": "yesNo"]) { a in
                guard case .yes(true) = a else { return talk([]) }
                return talk(act { $0.readFortune(f, companion: companion) })
            }
        }
        guard f == .companion else { return fee(nil) }
        return talk([.msg(792)], ask: ["kind": "choice", "options": v.officers.map { $0.name }]) { a in
            guard case .choice(let k?) = a else { return talk([]) }
            return fee(k)
        }

    // 아이템
    case "item.buy":
        guard let id = int("id") else { return talk([]) }
        return confirm(v.buyItemOffer(id)) { act { $0.buyItem(id) } }
    case "item.equip":
        guard let id = int("id") else { return talk([]) }
        return talk(act { $0.toggleEquip(id) })
    case "item.sell":
        guard let id = int("id") else { return talk([]) }
        // 매각 (0x295F7): a no may talk the price up for a lucky seller, then the offer is repeated.
        func ask(_ lines: [TownLine], _ price: Int) -> [String: Any] {
            talk(lines, ask: ["kind": "yesNo"]) { a in
                if case .yes(true) = a { return talk(act { $0.sellItem(id, price: price) }) }
                if let h = act({ $0.haggleItem(price: price) }) { return ask(h.lines, h.price) }
                return talk([])
            }
        }
        switch v.sellItemOffer(id) {
        case .refused(let l): return talk(l)
        case .yesNo(let l), .amount(let l, _): return ask(l, v.resalePrice(id))
        }

    // 조합: 업무알선 (0x2C77F): the offers come back after each refusal, as in the original
    case "guild.desk": return guildDesk()

    // 왕궁: 알현 (0x29EDD): the commission for a summoned hero, then the hero's and the shared audience scripts
    case "palace.audience":
        let begin = act { $0.beginAudience() }
        let next: (Bool) -> [String: Any] = { _ in
            runScene(key2: ScriptKey.audience, contexts: [.hero]) { leave in
                if leave { return talk([]) }
                return runScene(key2: ScriptKey.audience, contexts: [.shared]) { leave2 in
                    var r = talk([]); if !leave2 { r["audience"] = true }; return r
                }
            }
        }
        if begin { return runScene(key2: ScriptKey.palace, contexts: [.shared], then: next) }
        return next(false)

    // 조합: 나라정보 (0x2CA2A): which nation (162), then the fee (86)
    case "guild.news":
        return talk([.msg(162)], ask: ["kind": "choice", "options": Town.nationNames]) { a in
            guard case .choice(let n?) = a else { return talk([]) }
            let ask: [TownLine]
            switch voyage!.newsOffer() { case .refused(let l), .yesNo(let l), .amount(let l, _): ask = l }
            return talk(ask, ask: ["kind": "yesNo"]) { b in
                if case .yes(true) = b { return talk(act { $0.buyNews(of: n) }) }
                return talk([.msg(87)])
            }
        }

    // 투자 (교역소) / 공업투자 (조선소)
    case "invest.do":
        let field: InvestField = openBuilding == 0 ? .economy : .industry
        return offer(v.investOffer(field)) { n in act { $0.invest(n, in: field) } }

    // 여관
    case "inn.sleep":
        act { $0.passTime(ticks: (Navigation.ticksPerDay - $0.tick) + 24, in: world) }
        return talk([.text("푹 쉬었습니다.")])
    case "inn.wait":
        act { $0.passTime(ticks: 6, in: world) }
        return talk([])

    // 왕궁 (알현의 이야기 장면은 아직 없다)
    case "palace.defect":
        return talk(v.defectionQuestion(), ask: ["kind": "yesNo"]) { a in
            if case .yes(true) = a { return talk(act { $0.defect() }) }
            return talk([.msg(459)])
        }
    case "palace.gold_aid": return talk(act { $0.receiveGoldAid() })
    case "palace.power": return talk(v.powerReport(of: v.portNation))
    case "palace.privateer": return confirm(v.privateerOffer()) { act { $0.requestPrivateerLicence() } }
    case "palace.certificate":
        switch v.certificateOffer() {
        case .refused(let l): return talk(l)
        case .yesNo(let l), .amount(let l, _):
            return talk(l, ask: ["kind": "yesNo"]) { a in
                guard case .yes(true) = a else { return talk([]) }
                let terms = voyage!.certificateTerms()
                if terms.price == 0 { return talk(terms.lines + act { $0.buyCertificate() }) }
                return talk(terms.lines, ask: ["kind": "yesNo"]) { b in
                    if case .yes(true) = b { return talk(act { $0.buyCertificate() }) }
                    return talk([])
                }
            }
        }
    case "palace.ship_aid":
        switch v.shipAidOffer(in: world) {
        case .refused(let l): return talk(l)
        case .yesNo(let l), .amount(let l, _):
            let c = v.pendingShipAid(v.portNation).shipClass
            let suggested = world.navigation.classes[min(c, 7)].name
            return talk(l, ask: ["kind": "name", "suggested": suggested]) { a in
                guard case .name(let n) = a else { return talk([]) }
                return talk(act { $0.receiveShipAid(named: n, in: world) })
            }
        }
    default:
        return ["ok": false, "error": "unknown action \(action)"]
    }
}


// MARK: - shipyard

/// Everything the shipyard's six tabs show.
func yardState() -> [String: Any] {
    let v = voyage!
    let nav = world.navigation
    let m = v.market(in: world)
    func cls(_ c: Int) -> [String: Any] {
        let k = nav.classes[c]
        return ["class": c, "name": k.name, "crew": k.crewCapacity, "guns": k.gunCapacity, "cargo": k.cargoCapacity,
                "hull": 9 * k.hull / 10, "capacity": k.capacity, "minCrew": k.minCrew, "maxCrew": k.maxCrew, "maxGuns": k.maxGuns,
                "oars": k.oars, "desc": message(168 + c)]
    }
    var o: [String: Any] = [:]
    o["stock"] = v.shipyardStock.enumerated().map { (slot, c) -> [String: Any] in
        var d = cls(c)
        let asking = v.askingPrice(class: c, in: world)
        d["slot"] = slot; d["price"] = asking; d["floor"] = v.haggleFloor(asking)
        return d
    }
    o["noStock"] = message(165)
    o["banned"] = v.shipyardBanned
    o["needsTrade"] = v.spareCaptains == 0
    o["tradeMessage"] = message(167)
    let types = v.cannonTypes(in: world)
    o["cannons"] = types.map { ["type": $0, "name": nav.cannons[$0 - 1].name, "price": v.cannonPrice($0, in: world)] as [String: Any] }
    o["ships"] = v.ships.enumerated().map { (i, s) -> [String: Any] in
        ["index": i, "name": s.name, "class": s.classIndex, "className": nav.classes[s.classIndex].name,
         "material": Shipyard.materials[min(s.material, 5)], "hull": s.hull, "maxHull": s.maxHull, "rudder": s.rudder, "sail": s.sail,
         "crew": s.crew, "crewCap": s.crewCapacity, "guns": s.guns, "gunCap": s.gunCapacity, "gunType": s.gunType,
         "cargoCap": s.cargoCapacity, "cargoLoad": s.cargoLoad, "figurehead": s.figurehead,
         "repair": Shipyard.repairCost(s, in: nav), "value": v.shipValue(i, in: world), "refit": Shipyard.refitCost(class: s.classIndex, in: nav),
         "cannonMax": types.map { v.maxCannons($0, ship: i) },
         "limits": cls(s.classIndex)]
    }
    o["buildable"] = Shipyard.buildable(at: m, in: nav).map { c -> [String: Any] in
        var d = cls(c)
        d["days"] = Shipyard.buildDays(class: c, at: m, in: nav)
        d["materials"] = (0..<Shipyard.materialCount(class: c, at: m)).map { k -> [String: Any] in
            let price = Shipyard.buildPrice(class: c, material: k, at: m, in: nav)
            return ["k": k, "name": Shipyard.materials[k], "hull": Shipyard.builtHull(class: c, material: k, in: nav),
                    "price": price, "floor": v.haggleFloor(price)]
        }
        return d
    }
    o["noBuild"] = message(251); o["buildAsk"] = message(252); o["materialAsk"] = message(254)
    if let ord = v.orderHere {
        o["order"] = ["name": ord.ship.name, "class": nav.classes[ord.ship.classIndex].name, "material": Shipyard.materials[min(ord.ship.material, 5)],
                      "crew": ord.ship.crewCapacity, "guns": ord.ship.gunCapacity, "cargo": ord.ship.cargoCapacity, "hull": ord.ship.maxHull,
                      "daysLeft": ord.daysLeft, "waiting": message(261).replacingOccurrences(of: "%d", with: "\(ord.daysLeft)"),
                      "ready": message(250)] as [String: Any]
    }
    o["figureheads"] = (1...max(1, v.figureheadStock)).map { ["k": $0, "name": Shipyard.figureheadNames[min($0, 10)], "price": Shipyard.figureheadPrice($0)] as [String: Any] }
    o["figureheadRare"] = v.figureheadStock > min(8, m.economy / 100 + 1) ? message(266) : ""
    o["carronade"] = v.carronadeHere
    o["gold"] = v.gold
    return o
}

func dealNote(_ r: ShipDeal) -> String {
    switch r {
    case .bought: return message(257)
    case .refused: return message(198)
    case .banned: return message(197)
    case .short: return message(207)
    case .noCaptain: return message(166)
    case .fleetFull: return "함대가 가득 찼습니다."
    case .cargoAboard: return "적하를 먼저 팔아 주십시오."
    case .busy, .notReady:
        return message(261).replacingOccurrences(of: "%d", with: "\(voyage?.orderHere?.daysLeft ?? 0)")
    }
}

func yardCommand(_ name: String, _ cmd: [String: Any]) -> [String: Any]? {
    func int(_ k: String) -> Int? { (cmd[k] as? NSNumber)?.intValue }
    guard name.hasPrefix("yard_"), voyage != nil else { return nil }
    var note = ""
    switch name {
    case "yard_state": break
    case "yard_buy":
        guard let slot = int("slot"), let offer = int("offer") else { break }
        let trade = int("tradeIn").flatMap { $0 >= 0 ? $0 : nil }
        let nm = (cmd["name"] as? String) ?? ""
        let cname = voyage!.shipyardStock.indices.contains(slot) ? world.navigation.classes[voyage!.shipyardStock[slot]].name : ""
        let r = act { $0.buyShip(slot: slot, offer: offer, tradeIn: trade, name: nm.isEmpty ? cname : nm, in: world) }
        note = r == .bought ? (message(199).components(separatedBy: ".").first.map { $0 + "." } ?? "") : dealNote(r)
    case "yard_sell":
        guard let i = int("ship") else { break }
        let r = act { $0.sellShip(i, in: world) }
        note = r == .bought ? message(164) : r == .cargoAboard ? message(211) : message(208)
    case "yard_order":
        guard let c = int("class"), let mat = int("material"), let crew = int("crew"), let guns = int("guns"), let offer = int("offer") else { break }
        let nm = (cmd["name"] as? String) ?? ""
        let r = act { $0.orderShip(class: c, material: mat, crew: crew, guns: guns, offer: offer,
                                   name: nm.isEmpty ? world.navigation.classes[c].name : nm, in: world) }
        note = r == .bought ? message(262).replacingOccurrences(of: "%d", with: "\(voyage!.orderHere?.daysLeft ?? 0)") : dealNote(r)
    case "yard_delivery":
        let n = voyage!.orderHere?.ship.name ?? ""
        let r = act { $0.takeDelivery() }
        note = r == .bought ? "\(n)호가 함대에 합류했습니다." : r == .noCaptain ? message(285) : dealNote(r)
    case "yard_refit":
        guard let i = int("ship"), let crew = int("crew"), let guns = int("guns") else { break }
        note = act { $0.refit(i, crew: crew, guns: guns, in: world) } ? "좋아, 바꿔 주었소." : message(20)
    case "yard_rename":
        guard let i = int("ship"), let nm = cmd["name"] as? String, !nm.isEmpty, voyage!.ships.indices.contains(i) else { break }
        act { $0.ships[i].name = nm }
        note = "\(nm)호로 이름을 바꾸었소."
    case "yard_figurehead":
        guard let k = int("k"), let i = int("ship") else { break }
        note = act { $0.buyFigurehead(k, ship: i) } ? "\(Shipyard.figureheadNames[min(k, 10)]) 선수상을 달았소." : message(207)
    case "yard_cannons":
        guard let t = int("type"), let n = int("count"), let i = int("ship") else { break }
        note = act { $0.buyCannons(t, count: n, ship: i, in: world) } ? "" : message(207)
    case "yard_repair":
        guard let i = int("ship") else { break }
        note = act { $0.repair(i, in: world) } ? "수리를 마쳤소." : message(207)
    default: return nil
    }
    var o = townReply(["ok": true, "note": note, "yard": yardState()])
    o["invest"] = panelInfo(2)["invest"] ?? NSNull()
    return o
}
