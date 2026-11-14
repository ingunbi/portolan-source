import Foundation
import PortolanCore

// The tavern (주점, building 1): the round of drinks, signing sailors, letting them go, the
// patrons who will sign on as officers, and the officers already signed. Rules: Market.swift
// (Tavern), TavernMore.swift, TavernJobs.swift, Officers.swift.

/// This visit's tavern (its mood lasts until the hero leaves).
var tavern: Tavern?
/// The barmaid the hero has paid to sit with (her index), until he leaves her table.
var barmaidSeat: Int?

/// The navigators waiting at the tavern or the inn.
func patronsJSON(_ v: Voyage, place: Hangout) -> [[String: Any]] {
    v.patrons(at: place).map { p -> [String: Any] in
        let r = v.memory.person(p)
        let names = ["통솔", "항해", "지식", "직감", "용기", "검술", "매력"]
        var best = 0
        for i in 1..<7 where r.stats[i] > r.stats[best] { best = i }
        return ["p": p, "name": r.name, "navLevel": r.navLevel, "battleLevel": r.battleLevel,
                "ability": "\(names[best]) \(r.stats[best])", "face": v.memory.word(DS.person(p) + 0x1A), "nation": v.memory[DS.person(p) + 0x31] & 0xF]
    }
}

/// Talk with a navigator, at the tavern or the inn: greet (menu opens), the navigators' news, ask to join.
/// At the inn one choice ends the menu (0x28409).
func patronTalk(_ name: String, _ cmd: [String: Any], place: Hangout) -> [String: Any]? {
    func int(_ k: String) -> Int? { (cmd[k] as? NSNumber)?.intValue }
    switch name {
    case "greet":
        guard let p = int("p") else { return talk([]) }
        let g = act { $0.greetPatron(p, at: place) }
        var r = talk(g.lines)
        r["patronMenu"] = g.menu ? p : -1
        return r
    case "patron_rumour":
        guard let p = int("p") else { return talk([]) }
        var r = patronScene(p) ?? talk(act { $0.navigatorRumour(in: world) })
        if place == .inn { r["patronMenu"] = -1 }
        return r
    case "patron_join":
        guard let p = int("p") else { return talk([]) }
        if let s = patronScene(p) { return s }
        let r = act { $0.askToJoin(p, at: place, in: world) }
        guard let salary = r.salary else {
            var o = talk(r.lines)
            if place == .inn { o["patronMenu"] = -1 }
            return o
        }
        var o = talk(r.lines, ask: ["kind": "yesNo"]) { a in
            guard case .yes(true) = a else { return talk([.msg(143)]) }
            act { $0.hireOfficer(p, salary: salary, in: world) }
            var o = talk([.msg(144)]); o["patronMenu"] = -1
            return o
        }
        if place == .inn { o["patronMenu"] = -1 }
        return o
    default: return nil
    }
}

func tavernState() -> [String: Any] {
    guard let v = voyage, let t = tavern else { return [:] }
    var o: [String: Any] = [:]
    let affordable = t.bottlesAffordable(gold: v.gold)
    let hireable = v.hiredToday ? 0 : v.hireable(at: t)
    o["drink"] = t.drink.name; o["price"] = t.drink.price
    o["mood"] = t.mood; o["willing"] = Tavern.willingMood
    o["bottlesMax"] = affordable
    o["volunteers"] = t.volunteers(rank: v.rank); o["wage"] = t.wage
    o["vacancies"] = v.vacancies; o["hireable"] = hireable; o["hiredToday"] = v.hiredToday
    // Barkeep lines from MESSAGE.DAT 29, 30, 31, 121-123.
    let n = t.volunteers(rank: v.rank)
    o["advice"] = v.vacancies == 0 ? "선원은 충분해요." : v.gold < 10 ? "금화가 부족해요."
        : t.mood < Tavern.willingMood ? "선원을 모으려면 술을 한 순배 더 돌리는 편이 낫겠습니다."
        : n == 0 ? "지원자가 한 사람도 나타나지 않았습니다."
        : n < 20 ? "지원자는 \(n)명에 그쳤습니다." : "선원 \(n)명이 모였습니다."
    let people = v.patrons(at: .tavern)
    o["patrons"] = patronsJSON(v, place: .tavern)
    o["nobody"] = people.isEmpty ? render([v.nobodyLine(at: .tavern, mood: t.mood)]).first ?? "" : ""
    o["officers"] = v.officers.enumerated().map { (k, of) -> [String: Any] in
        ["k": k, "name": of.name, "navLevel": of.navLevel, "loyalty": of.loyalty, "salary": of.salary,
         "post": of.post?.rawValue ?? -1, "captainOf": k < v.ships.count - 1 ? v.ships[k + 1].name : ""]
    }
    o["posts"] = OfficerPost.allCases.map { $0.name }
    o["spareCaptains"] = max(0, v.spareCaptains)
    o["ships"] = v.ships.enumerated().map { (i, s) -> [String: Any] in
        ["index": i, "name": s.name, "crew": s.crew, "morale": s.morale, "keepMax": v.dismissLimit(ship: i),
         "prompt": render([v.dismissPrompt(ship: i)]).first ?? ""]
    }
    o["hasBarmaid"] = v.barmaidHere != nil
    if let g = v.barmaidHere {
        let b = v.barmaid(g)
        let seated = barmaidSeat == g
        o["barmaid"] = ["girl": g, "name": b.name, "portrait": b.portrait, "seated": seated,
                        "topics": v.barmaidTopics.map { ["id": $0.rawValue, "name": $0.name] as [String: Any] },
                        "gossip": GossipTopic.allCases.map { ["id": $0.rawValue, "name": $0.name,
                                                              "enabled": $0 != .jobs || v.jobInfoOffered] as [String: Any] }] as [String: Any]
    } else { barmaidSeat = nil }
    return o
}

/// A new investigation (0x26570): which nation (534), which fleets (535), how long (536).
func barmaidRequest(_ g: Int) -> [String: Any] {
    talk([.msg(534)], ask: ["kind": "choice", "options": Array(Patron.nations.prefix(7))]) { a in
        guard case .choice(let n?) = a else { return talk([]) }
        return talk([.msg(535)], ask: ["kind": "choice", "options": Voyage.inquiryKinds(nation: n)]) { a in
            guard case .choice(let c?) = a else { act { $0.dropInquiry(g) }; return talk([]) }
            return talk(act { $0.requestInquiry(g, nation: n, kind: c) })
        }
    }
}

/// The topics of the barmaid's table (menu 14): 자기자랑, 선물, 조사의뢰, 정보수집.
func barmaidTopic(_ g: Int, _ t: BarmaidTopic) -> [String: Any] {
    let v = voyage!
    switch t {
    case .boast:
        let sites = v.boastableSites
        if sites.isEmpty { return talk([.msg(312)]) }
        return talk([], ask: ["kind": "choice", "options": sites.map { world.discovery($0).name }]) { a in
            guard case .choice(let k?) = a, sites.indices.contains(k) else { return talk([]) }
            return talk([.text("「\(world.discovery(sites[k]).name)」")] + act { $0.boast(sites[k], to: g) })
        }
    case .gift:
        let gifts = v.giftItems
        if gifts.isEmpty { return talk([v.noGiftLine(g)]) }
        return talk([], ask: ["kind": "choice", "options": gifts.map { v.item($0).name }]) { a in
            guard case .choice(let k?) = a, gifts.indices.contains(k) else { return talk([]) }
            let id = gifts[k]
            let about = itemTexts.indices.contains(id) ? itemTexts[id] : ""
            return talk([.text(voyage!.item(id).name)] + (about.isEmpty ? [] : [.text(about)]), ask: ["kind": "yesNo"]) { a in
                guard case .yes(true) = a else { return talk([]) }
                return talk(act { $0.give(id, to: g) })
            }
        }
    case .inquiry:
        switch v.inquiryDesk(g) {
        case .says(let l): return talk(l)
        case .report: return talk(act { $0.inquiryReport(g, in: world) })
        case .request: return barmaidRequest(g)
        }
    case .gossip:
        return talk([.msg(398)])
    }
}

/// The job hooks of a patron (a debtor, the informant who sells the relic's map): their scene takes the place of the talk.
func patronScene(_ p: Int, treat: Bool = false) -> [String: Any]? {
    switch voyage!.patronHook(person: p, treat: treat) {
    case .debtor?:
        return talk(act { $0.meetDebtor() }.lines)
    case .mapSeller?:
        let offer = voyage!.mapOffer(in: world)
        if offer.forSale {
            return talk(offer.lines, ask: ["kind": "yesNo"]) { a in
                if case .yes(true) = a { return talk(act { $0.buyMap() }) }
                return talk([])
            }
        }
        return talk(offer.lines)
    case nil: return nil
    }
}

func tavernAction(_ action: String, _ cmd: [String: Any]) -> [String: Any]? {
    func int(_ k: String) -> Int? { (cmd[k] as? NSNumber)?.intValue }
    guard action.hasPrefix("tavern."), var t = tavern else { return nil }
    switch action {
    case "tavern.treat":
        let v = voyage!
        let n = min(int("bottles") ?? 0, t.bottlesAffordable(gold: v.gold))
        guard n > 0 else { return talk([]) }
        let cost = t.treat(bottles: n, charm: v.captain.charm)
        tavern = t
        act { $0.gold -= min($0.gold, cost) }
        let lines = act { $0.tavernTreatTalk() } + (act { $0.tavernJobHint(in: world) } ?? [])
        return talk(lines)
    case "tavern.hire":
        let n = int("n") ?? 0
        if act({ $0.hireCrew(n, at: t) }) { return talk([.text("\(n)명의 선원이 배에 올랐습니다.")]) }
        return talk([])
    case "tavern.greet", "tavern.patron_rumour", "tavern.patron_join":
        return patronTalk(String(action.dropFirst(7)), cmd, place: .tavern)
    case "tavern.patron_treat":
        guard let p = int("p") else { return talk([]) }
        switch act({ $0.treatPatron(p, in: world) }) {
        case .short(let l), .talk(let l): return talk(l)
        case .hook: return patronScene(p, treat: true) ?? talk([])
        }
    case "tavern.barmaid":
        guard let g = voyage!.barmaidHere else { return talk([]) }
        let r = act { $0.callBarmaid(g) }
        barmaidSeat = r.seated ? g : nil
        return talk(r.lines)
    case "tavern.barmaid_leave":
        barmaidSeat = nil
        return talk([])
    case "tavern.barmaid_topic":
        guard let g = barmaidSeat, let t = int("topic").flatMap({ BarmaidTopic(rawValue: $0) }) else { return talk([]) }
        return barmaidTopic(g, t)
    case "tavern.barmaid_gossip":
        guard let g = barmaidSeat, let t = int("topic").flatMap({ GossipTopic(rawValue: $0) }) else { return talk([]) }
        switch t {
        case .jobs:
            switch act({ $0.jobInfo(g, in: world) }) {
            case .says(let l): return talk(l)
            case .inquiry: return barmaidRequest(g)
            }
        case .taste: return talk(act { $0.herTaste(g) })
        case .age: return talk(voyage!.herAge(g))
        }
    case "tavern.dismiss":
        guard let i = int("ship"), let keep = int("keep"), let line = voyage!.dismissConfirm(ship: i, keep: keep) else { return talk([]) }
        return talk([line], ask: ["kind": "yesNo"]) { a in
            if case .yes(true) = a { act { $0.dismissCrew(ship: i, keep: keep) } }
            return talk([])
        }
    case "tavern.appoint":
        guard let k = int("k") else { return talk([]) }
        let post = int("post").flatMap { OfficerPost(rawValue: $0) }
        act { $0.appoint(k, to: post) }
        return talk([])
    case "tavern.dismiss_officer":
        guard let k = int("k") else { return talk([]) }
        act { $0.dismissOfficer(k) }
        return talk([])
    default: return nil
    }
}
