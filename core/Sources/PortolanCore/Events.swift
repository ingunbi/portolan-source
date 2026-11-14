import Foundation

// Incidents at sea recovered from MAIN.EXE: sailors deserting when morale falls below 20
// (0x189FC), and the storm, calm, fog and missing-ship areas marked by bits 6 and 7 of
// the WINDCUR.DAT zone bytes. The check runs with each weather roll (0x199EC → 0x19474),
// an incident in progress with the next ones (0x19923). See docs/RE_NOTES.md.

public enum SeaEvent: Int, Codable {
    case storm = 1, calm, fog

    /// Officer's warning (messages 340, 344, 348; two lines on when their knowledge is under 70).
    func warning(knowing: Bool) -> String {
        switch (self, knowing) {
        case (.storm, true): return "날씨가 심상치 않습니다.\n폭풍이 올 징조입니다."
        case (.calm, true): return "공기가 묘합니다.\n바람이 잦아들 것 같습니다."
        case (.fog, true): return "공기가 눅눅합니다.\n안개가 낄 것 같습니다."
        case (.storm, false): return "불길한 예감이 듭니다."
        case (.calm, false), (.fog, false): return "왠지 좋지 않은 기운이 느껴집니다."
        }
    }

    public var announcement: String { onset }

    /// Messages 352, 354, 356.
    var onset: String {
        ["폭풍입니다!\n키가 말을 듣지 않습니다.", "바람이 완전히 멎었습니다.",
         "안개가 짙습니다.\n앞이 보이지 않습니다."][rawValue - 1]
    }

    /// Messages 360, 362, 364.
    var end: String {
        ["위기를 넘겼습니다.", "바람이 불어옵니다.", "안개가 걷혔습니다."][rawValue - 1]
    }
}

public enum Incidents {
    /// Sailors leave a ship when the ship it drew stores from falls under 20 morale (0x189FC).
    /// The count uses the eating ship's own morale and an unsigned minimum, so a contented
    /// ship eating from a mutinous one loses everyone; kept as the original has it.
    public static func deserters(crew: Int, morale: Int) -> Int {
        let v = (Navigation.mutinyMorale - morale) * crew / 100 + 1
        return v < 0 ? crew : min(crew, v)
    }

    /// Storm damage to one ship (0x195FC): seamanship and level of its commander soften it,
    /// coastal craft take five times as much.
    public static func stormDamage(seamanship: Int, navLevel: Int, oceanGoing: Bool, roll: Int) -> Int {
        let d = min(10, (100 - seamanship) / (navLevel / 5 + 3) + 1) + roll
        return oceanGoing ? d : 5 * d
    }
}

extension Voyage {
    /// Weather roll every 12 ticks (0x199EC). During an incident the wind holds and only the
    /// zone flags and the current follow the fleet. Then the incident runs or a new one is drawn.
    mutating func rollWeather(in world: World) {
        let z = Navigation.zone(x: Int(world.wrapX(x)), y: max(0, min(World.height - 1, Int(y))))
        let w = (summerWinds ? world.navigation.windSummer : world.navigation.windWinter)[z]
        let c = world.navigation.current[z]
        if event != nil {
            weather.windFlags = w & 0xC0
            weather.currentDir = (c >> 3) & 7
            weather.currentStrength = c & 7
            weather.currentFlags = c & 0xC0
            runEvent(zoneWind: w, in: world)
        } else {
            weather = Navigation.roll(windByte: w, currentByte: c, rng: &rng)
        }
        if event == nil && gameOver == nil { checkEvent(in: world) }
    }

    /// Chance of an incident in a marked zone (0x19474): the luckiest of admiral, first mate
    /// and chief navigator, and the fleet's mean figurehead, both hold it off.
    mutating func checkEvent(in world: World) {
        guard weather.windFlags & 0x80 != 0 else { return }
        let watch = officers.filter { $0.post == .firstMate || $0.post == .chiefNavigator }
        let luck = ([captain.luck] + watch.map { $0.stats[7] }).max() ?? 0
        let figure = ships.reduce(0) { $0 + $1.figurehead } / max(1, ships.count)
        guard rng(155) > luck + 50, rng(11) > figure else { return }
        if weather.windFlags & 0x40 != 0 { loseShip(in: world) }
        switch weather.currentFlags {
        case 0x40 where rng(7) + 3 >= weather.windStrength && stormShelter == 0: begin(.storm)   // 0x193F4
        case 0x80 where rng(6) >= weather.windStrength: begin(.calm)                             // 0x1942C
        case 0xC0 where rng(10) == 0 && rng(6) >= weather.windStrength: begin(.fog)              // 0x1944A
        default: break
        }
    }

    /// A ship under a minor captain drops out of sight for good (0x1926E, message 336).
    private mutating func loseShip(in world: World) {
        for i in ships.indices.dropFirst() {
            let c = commander(of: i, in: world)
            if rng(100) > c.stats[7] && c.generic {
                note("\(ships[i].name)(가) 시야에서 사라졌습니다.")
                removeShip(i, keepCaptain: false)
                return
            }
        }
    }

    /// The incident is set; the first mate or chief navigator, whichever has the better
    /// intuition, may see it coming (0x19377, 0x192EB).
    private mutating func begin(_ e: SeaEvent) {
        event = e
        eventAnnounced = false
        let mate = officer(holding: .firstMate), nav = officer(holding: .chiefNavigator)
        let watch = mate.map { m in nav.map { m.stats[3] > $0.stats[3] ? m : $0 } ?? m } ?? nav
        if let o = watch, rng(100) <= o.stats[3] { note(e.warning(knowing: o.stats[2] >= 70)) }
    }

    /// One step of the incident (0x19923). It breaks at the roll after the warning and cannot
    /// end on the day it broke.
    private mutating func runEvent(zoneWind w: Int, in world: World) {
        guard let e = event else { return }
        if !eventAnnounced {
            note(e.onset)
            eventAnnounced = true
            eventFresh = true
        }
        var over = false
        switch e {
        case .storm:                                                              // 0x195AC
            if !ashore { stormStrikes(in: world) }                               // 0x195B4
            guard gameOver == nil else { return }
            weather.windStrength = 7
            over = !eventFresh && (rng(8) == 0 || weather.windFlags & 0x80 == 0)
        case .calm:                                                               // 0x1985F
            over = !eventFresh && rng(20) == 0 && w & 7 != 0
            weather.windStrength = 0
        case .fog:                                                                // 0x198D7
            over = !eventFresh && (rng(30) == 0 || weather.windFlags & 0x80 == 0)
        }
        if over {
            event = nil
            note(e.end)
        }
    }

    /// Every ship loses hull, rudder and sails, and a point of maximum hull down to a quarter
    /// of its class (0x195FC). A wreck takes a minor captain with it; others are rescued
    /// (messages 358, 809). Losing the flagship ends the game (0x197DA).
    private mutating func stormStrikes(in world: World) {
        var i = 0
        while i < ships.count {
            let c = commander(of: i, in: world)
            let cls = world.navigation.classes[ships[i].classIndex]
            let d = Incidents.stormDamage(seamanship: c.stats[1], navLevel: c.navLevel, oceanGoing: cls.oceanGoing, roll: rng(2))
            ships[i].hull -= min(ships[i].hull, d)
            ships[i].sail -= min(ships[i].sail, d / 2)
            ships[i].rudder -= min(ships[i].rudder, d / 2)
            ships[i].maxHull = max(cls.hull / 4, ships[i].maxHull - 1)
            ships[i].hull = min(ships[i].maxHull, ships[i].hull)
            guard ships[i].hull == 0 else {
                i += 1
                continue
            }
            note("\(ships[i].name)호가 가라앉았습니다.")
            if i == 0 {
                gameOver = "기함 \(ships[0].name)호가 폭풍우에 침몰했습니다."
                gameOverCode = 0x18                                              // 0x197DF
                return
            }
            if !c.generic { note("\(officers[i - 1].name)(는) 간신히 구조되었습니다.") }
            removeShip(i, keepCaptain: !c.generic)
        }
    }
}
