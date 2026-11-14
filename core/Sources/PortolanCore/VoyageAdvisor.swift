import Foundation

/// Read-only guidance for the remaster. It never advances the clock, reveals unknown ports,
/// changes a script flag, or claims that the original game has awarded a new objective.
public struct VoyageAdvice {
    /// Estimates using the fleet's shared stores and its present crew/rations. Nil: no fleet.
    /// Ships can draw from another ship when their own stores run out (Voyage.consume).
    public let waterDays: Int?
    public let foodDays: Int?
    public var supplyDays: Int? {
        guard let waterDays, let foodDays else { return nil }
        return min(waterDays, foodDays)
    }
    public let warnings: [VoyageWarning]
    public let objective: VoyageObjective?
    public let knownPorts: [Harbor]
}

public struct VoyageWarning: Identifiable, Equatable {
    public enum Severity: Int, Comparable {
        case attention, critical
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    public enum Action: String {
        case supplies, shipyard, crew, items, tavern, navigation
    }
    public let id: String
    public let title: String
    public let detail: String
    public let severity: Severity
    public let action: Action
}

public struct VoyageObjective: Equatable {
    public let title: String
    public let detail: String
    public let destinationID: Int?
    /// Uses the original job clock (30 days/month, year offset 1501), not elapsed voyage days.
    /// Negative means overdue; nil means no active deadline, including a report/reward stage.
    public let daysRemaining: Int?
}

extension Voyage {
    public func advice(in world: World) -> VoyageAdvice {
        // dailyUse includes the original +1 even at zero ration or zero crew. Do not invent
        // infinite endurance for zero rations. Existing rats consume another barrel per ship.
        let waterUse = ships.reduce(0) { $0 + Navigation.dailyUse(crew: $1.crew, ration: waterRation, ashore: ashore) }
        let foodUse = ships.reduce(0) { $0 + Navigation.dailyUse(crew: $1.crew, ration: foodRation, ashore: ashore) + (epidemic ? 10 : 0) }
        let waterDays = waterUse > 0 ? max(0, water) / waterUse : nil
        let foodDays = foodUse > 0 ? max(0, food) / foodUse : nil
        var warnings: [VoyageWarning] = []
        func warn(_ id: String, _ title: String, _ detail: String,
                  _ severity: VoyageWarning.Severity, _ action: VoyageWarning.Action) {
            warnings.append(VoyageWarning(id: id, title: title, detail: detail, severity: severity, action: action))
        }

        if ships.isEmpty {
            warn("no-ships", "항해할 배가 필요합니다", "이야기를 진행하거나 조선소에서 함선을 마련하세요.", .critical, .shipyard)
        }
        for (name, days) in [("식수", waterDays), ("식량", foodDays)] {
            if let days, days < 7 {
                warn(name == "식수" ? "water" : "food", "\(name) 약 \(days)일분",
                     "현재 선원과 배급 기준입니다. 항구 사무소에서 보급하세요.", days < 3 ? .critical : .attention, .supplies)
            }
        }
        if !ships.isEmpty && (waterRation < 100 || foodRation < 100) {
            warn("ration", "배급을 줄인 상태입니다", "물자가 오래가더라도 선장의 통솔력과 배급량에 따라 사기가 떨어질 수 있습니다.", .attention, .crew)
        }
        for (i, ship) in ships.enumerated() {
            let name = ship.name.isEmpty ? "함선 \(i + 1)" : ship.name
            if ship.crew * ship.sailorShare / 100 == 0 {
                warn("crew-\(i)", "\(name) 운항 인원 없음", "주점에서 선원을 고용하고 승무원 비율의 운항 인원을 배정하세요.", .critical, .crew)
            } else if world.navigation.classes.indices.contains(ship.classIndex) {
                let minimum = world.navigation.classes[ship.classIndex].minCrew
                if ship.crew * ship.sailorShare / 100 < minimum {
                    warn("crew-\(i)", "\(name) 운항 인원 부족", "운항에 배정된 선원이 \(minimum)명보다 적어 속력이 낮아집니다.", .attention, .crew)
                }
            }
            if ship.maxHull > 0 && ship.hull < ship.maxHull {
                let percent = max(0, ship.hull) * 100 / ship.maxHull
                warn("hull-\(i)", "\(name) 선체 \(percent)%", "조선소에서 수리하세요. 해안 상륙 중에는 자재로 응급수리할 수 있습니다.", percent <= 50 ? .critical : .attention, .shipyard)
            }
        }
        if !ships.isEmpty && morale < 40 {
            warn("morale", "함대 최저 사기 \(morale)", "배급을 확인하고 주점에서 한턱내세요. 사기가 \(Navigation.mutinyMorale) 미만이면 선원 이탈 위험이 있습니다.", morale < Navigation.mutinyMorale ? .critical : .attention, .tavern)
        }
        if epidemic {
            warn("rats", "쥐 떼가 식량을 먹고 있습니다", "배마다 매일 식량 1통이 추가로 줄어듭니다. 쥐약을 사용하세요.", .critical, .items)
        }
        if scurvy {
            warn("scurvy", "괴혈병으로 선원이 줄어듭니다", "라임 주스를 사용하거나 항구에 입항하세요.", .critical, .items)
        }
        if aground {
            warn("aground", "얕은 바다에 걸렸습니다", "침로를 바꾸거나 다른 항로를 선택하세요.", .attention, .navigation)
        }
        if event == .storm {
            warn("storm", "폭풍우 발생", "선체 상태를 확인하세요. 성스런 향유가 있으면 아이템에서 사용할 수 있습니다.", .critical, .items)
        }
        // Stable within each severity so the HUD does not rearrange equal-priority warnings.
        let ordered = warnings.enumerated().sorted {
            $0.element.severity == $1.element.severity ? $0.offset < $1.offset : $0.element.severity > $1.element.severity
        }.map(\.element)
        let ports = world.ports.filter { memory[DS.port + DS.portSize * $0.id + 0x13] & 0x10 != 0 }
            .sorted {
                let a = hypot(world.deltaX(from: x, to: Double($0.x)), Double($0.y) - y)
                let b = hypot(world.deltaX(from: x, to: Double($1.x)), Double($1.y) - y)
                return a == b ? $0.id < $1.id : a < b
            }
        return VoyageAdvice(waterDays: waterDays, foodDays: foodDays, warnings: ordered,
                            objective: activeObjective(in: world), knownPorts: ports)
    }

    /// The shared scenario is the authority. Stage 0 of transport/purchase/debt jobs still
    /// needs its first briefing, so stale variables from the previous job must not be shown.
    private func activeObjective(in world: World) -> VoyageObjective? {
        let chapter = sharedChapter, stage = memory[TownDS.sharedBlock]
        func destination(_ id: Int) -> Int? { world.ports.contains { $0.id == id } ? id : nil }
        func name(_ id: Int) -> String {
            let live = destination(id).map { portName($0) } ?? ""
            return live.isEmpty ? world.ports.first(where: { $0.id == id })?.name ?? "의뢰 항구" : live
        }
        func objective(_ title: String, _ detail: String, port: Int? = nil, days: Int? = nil) -> VoyageObjective {
            VoyageObjective(title: title, detail: detail, destinationID: port.flatMap(destination), daysRemaining: days)
        }
        let start = sharedVar(16), target = sharedVar(17)
        let goods = world.navigation.goods.indices.contains(sharedVar(18)) ? world.navigation.goods[sharedVar(18)].name : "의뢰 상품"
        let quantity = sharedVar(19)
        let deadline = sharedVar(24) - (((year - 1501) * 12 + month) * 30 + dayOfMonth)
        switch chapter {
        case 1:
            if stage == 0 { return objective("상품수송 · 의뢰 확인", "\(name(start)) 교역소에서 운반할 상품을 받으세요.", port: start) }
            if sharedFlag(0) { return objective("상품수송 · 보수 수령", "\(name(start)) 교역소로 돌아가 보수를 받으세요.", port: start) }
            return objective("상품수송", "\(name(target)) 교역소에 \(goods) \(quantity)개를 운반하세요.", port: target, days: deadline)
        case 2:
            if stage == 0 { return objective("상품구입 · 의뢰 확인", "\(name(start)) 교역소에서 구입 조건을 확인하세요.", port: start) }
            return objective("상품구입", "\(goods) \(quantity)개를 구해 \(name(start)) 교역소로 가져가세요.", port: start, days: deadline)
        case 3:
            if sharedFlag(1) || sharedFlag(2) { return objective("편지배달 · 보수 수령", "\(name(start)) 조합으로 돌아가 결과를 보고하세요.", port: start) }
            return objective("편지배달", "\(name(target)) 조합에 편지를 전하세요.", port: target, days: deadline)
        case 4:
            if quantity == 0 { return objective("해적퇴치 · 결과 보고", "\(name(start)) 조합으로 돌아가 보수를 받으세요.", port: start) }
            return objective("해적퇴치", "해적 함대 \(quantity)개를 더 격파한 뒤 \(name(start)) 조합에 보고하세요.", days: deadline)
        case 5:
            if stage == 0 { return objective("빚독촉 · 의뢰 확인", "\(name(start)) 은행에서 채무자와 조건을 확인하세요.", port: start) }
            if sharedVar(18) == 0 { return objective("빚독촉 · 회수금 전달", "\(name(start)) 은행에 회수한 돈을 전달하세요.", port: start, days: deadline) }
            let debtor = (0..<120).contains(target) ? memory.person(target).name : "채무자"
            return objective("빚독촉", "주점과 여관에서 \(debtor)을 찾으세요. 주점에서 한턱내면 단서를 들을 수 있습니다.", days: deadline)
        case 6...12:
            // Before the audience is accepted, only the invitation is established.
            if stage < 2 { return objective("왕실 임무 · 알현", "\(name(homePort)) 왕궁에서 임무를 확인하세요.", port: homePort) }
            switch chapter {
            case 6:
                return objective("왕실 상품 조달", "\(goods) \(quantity)개를 마련해 \(name(homePort)) 왕궁에 가져가세요.", port: homePort)
            case 7, 8:
                if sharedFlag(1) { return objective("왕실 임무 · 귀국 보고", "\(name(homePort)) 왕궁에 외교 임무의 결과를 보고하세요.", port: homePort) }
                return objective(chapter == 7 ? "왕실 서신 전달" : "왕실 친선 사절", "\(name(target)) 왕궁에서 알현하세요.", port: target)
            case 9:
                return objective("왕실 세력 확장", "항구에 투자해 자국의 세력을 넓히고 \(name(homePort)) 왕궁에 보고하세요.", port: homePort)
            case 10:
                return objective("왕실 발견물 보고", "새로운 발견물을 찾아 \(name(homePort)) 왕궁에 보고하세요.", port: homePort)
            case 11:
                let relic = sharedVar(18)
                let relicName = (90...96).contains(relic) ? itemName(relic) : "의뢰받은 보물"
                if items.contains(relic) { return objective("왕실 보물 · 귀국 보고", "\(relicName)을 \(name(homePort)) 왕궁에 가져가세요.", port: homePort) }
                if items.contains(relic - 10) { return objective("왕실 보물 탐색", "보물지도를 확인하고 해안에 상륙해 \(relicName)을 찾으세요.") }
                return objective("왕실 보물 탐색", start == 255 ? "조합에서 \(relicName)의 단서를 찾으세요." : "\(name(start)) 조합에서 \(relicName)의 단서를 확인하세요.", port: start == 255 ? nil : start)
            default:
                return objective("왕실 함대 토벌", "왕실이 지정한 적국 함대를 격파하고 \(name(homePort)) 왕궁에 보고하세요.", port: homePort)
            }
        default:
            if sharedFlag(17) { return objective("왕실의 부름", "\(name(homePort)) 왕궁에서 알현하세요.", port: homePort) }
            return nil
        }
    }
}
