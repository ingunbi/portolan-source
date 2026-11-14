import Foundation

// Guild jobs that finish in taverns and inns (docs/re/tavern_jobs.md): the debtor of a debt
// collection job (0x25BD7), the house-round hint (0x25589), the guild's lead for royal
// commission 11 (0x2C636) and the informant who sells the relic's map (0x25AE0). They read
// and write the shared script context (SNR0): v6 job, v16..v19, v23 rank tier.

public enum PatronHook: Equatable {
    /// Job 5: the person owes the bank.
    case debtor
    /// Commission 11: the person has the relic's map.
    case mapSeller
}

extension Voyage {
    /// "북위 %d도, 서경 %d도" for a map position (0x24D58).
    public func latLon(_ x: Int, _ y: Int) -> [TownLine] {
        let d = 0x280 - y
        let lat = abs(d) * 8 / 57
        let s = ((x + 0x7BD) % 0x870 + 0x870) % 0x870
        return [.msg(d >= 0 ? 126 : 127, lat), s > 0x438 ? .msg(129, (0x870 - s) / 6) : .msg(128, s / 6)]
    }

    /// The job hooks of the person handlers (§1.5): picking the debtor or the informant turns
    /// a talk, a drink or a job offer into their scene.
    public func patronHook(person p: Int, treat: Bool = false) -> PatronHook? {
        guard sharedChapter != 0, p == sharedVar(17) & 0xFF else { return nil }
        let job = sharedVar(6)
        if job == 11 && (!treat || sharedVar(18) != 0) { return .mapSeller }
        if job == 5 && sharedVar(18) != 0 { return .debtor }
        return nil
    }

    /// The debtor pays (luck, or two times in three) or runs to another port (0x25BD7).
    /// Returns what was said and whether he is still here.
    public mutating func meetDebtor() -> (lines: [TownLine], stays: Bool) {
        let p = sharedVar(17) & 0xFF
        let a = DS.person(p)
        let name = (memory.string(a, max: 13), memory.string(a + 0x0D, max: 13))
        var lines: [TownLine] = [.msg(608, name.0, name.1)]
        if rng(100) <= captain.luck || rng(3) != 0 {
            let bars = 5 * sharedVar(19)
            lines += [.msg(609, bars), .msg(614)]
            gold += 50000 * sharedVar(19)                                   // no cap here (0x25C6D)
            setSharedVar(18, 0)
            return (lines, true)
        }
        lines += [.msg(610), .msg(613)]
        memory[a + 0x2D] = memory[a + 0x2D] >= 42 ? rng(58) + 42 : rng(42)
        return (lines, false)
    }

    /// The informant's offer (0x25AE0): the relic's map for 1000 gold, unless already bought.
    public func mapOffer(in world: World) -> (lines: [TownLine], forSale: Bool) {
        let relic = sharedVar(18) & 0xFF
        if items.contains((relic - 10) & 0xFF) { return ([.msg(879)], false) }
        return ([.msg(604, itemName(relic)), .msg(605)], true)
    }

    public mutating func buyMap() -> [TownLine] {
        guard gold >= 1000 else { return [.msg(607)] }
        guard items.count < 20 else { return [.msg(606), .msg(880)] }
        let map = ((sharedVar(18) & 0xFF) - 10) & 0xFF
        items.append(map)
        let site = memory[0x8144 + 26 * map + 0x18]
        if site < 100 { memory[Discovery.site(site) + 6] |= 0x20 }
        gold -= 1000
        return [.msg(606)]
    }

    func itemName(_ id: Int) -> String { memory.string(0x8144 + 26 * id, max: 21) }

    func ownsRelicOrMap() -> Bool {
        let relic = sharedVar(18) & 0xFF
        return items.contains(relic) || items.contains((relic - 10) & 0xFF)
    }

    /// After a round for the house with a job on: where the debtor or the informant is, known
    /// in a third of the ports (0x25589). Nil when nobody here knows.
    public func tavernJobHint(in world: World) -> [TownLine]? {
        let job = sharedVar(6), who = sharedVar(17)
        guard sharedChapter != 0 else { return nil }
        if job == 11 && who != 0xFF && ownsRelicOrMap() { return nil }
        guard (job == 11 && who != 0xFF) || job == 5 else { return nil }
        guard Int(Int16(truncatingIfNeeded: who)) % 3 == marketIndex % 3 else { return nil }
        let p = who & 0xFF
        guard p < 120 else { return nil }
        let a = DS.person(p)
        let given = memory.string(a, max: 13), family = memory.string(a + 0x0D, max: 13)
        let port = memory[a + 0x2D]
        if port != 0xFF && port < world.ports.count {
            let name = portName(port)
            return [.msg(599, given, family, name), .joined([.msg(600, name)] + latLon(world.ports[port].x, world.ports[port].y) + [.msg(601)])]
        }
        let f = memory[a + 0x2C]
        let kind = f % 10 == 0 ? "함대" : f % 10 < 5 ? "상선대" : "전함대"
        return [.msg(602, given, family, (Town.nationNames + ["해적"])[min(6, f / 10)], kind), .msg(603)]
    }

    /// 업무알선 during royal commission 11 (0x2C636): which guild has the lead, then who
    /// knows where the relic's map is.
    public mutating func commission11Desk(in world: World) -> [TownLine] {
        guard sharedVar(6) == 11, !ownsRelicOrMap() else { return [.msg(595)] }
        if sharedVar(16) == 0xFF { setSharedVar(16, rng(42)) }
        let lead = sharedVar(16) & 0xFF
        let relic = itemName(sharedVar(18) & 0xFF)
        guard marketIndex == lead else {
            return [.msg(598, relic, portName(lead)),
                    .joined([.msg(600, portName(lead))] + latLon(world.ports[lead].x, world.ports[lead].y) + [.msg(601)])]
        }
        if sharedVar(17) == 0xFF {
            let near = rng(sharedVar(23) + 1) == 0
            let candidates = (79..<120).filter { p in
                let port = memory[DS.person(p) + 0x2D]
                return port != 0xFF && (near ? port < 42 : port >= 42)
            }
            if !candidates.isEmpty {
                var p = rng(41) + 79
                while !candidates.contains(p) { p = rng(41) + 79 }
                setSharedVar(17, p)
            }
        }
        let p = sharedVar(17) & 0xFF
        guard p < 120 else { return [.msg(595)] }
        return [.msg(596, relic, memory.string(DS.person(p), max: 13), memory.string(DS.person(p) + 0x0D, max: 13)), .msg(597)]
    }
}
