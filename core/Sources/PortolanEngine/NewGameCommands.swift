import Foundation
import PortolanCore

// What the hero selection shows before a game exists (0x15E5F, 0x15C71): each hero's name, age, stats, the skill
// the hero starts with and his story (MESSAGE.DAT 50–55), from the game's initial data segment.

/// Skill shown for each hero (DS:0xABA0 into the names at DS:0x874).
let heroSkills = ["교섭", "포술", "포술", "지도제작", "측량", "회계"]

func newGameCommand(_ name: String, _ cmd: [String: Any]) -> [String: Any]? {
    guard name == "hero_info" else { return nil }
    let m = world.memory ?? DataSegment()
    let heroes = (0..<6).map { h -> [String: Any] in
        let p = m.person(h)
        return ["h": h, "name": p.name, "given": m.string(DS.person(h), max: 13), "family": m.string(DS.person(h) + 0x0D, max: 13),
                "age": m[DS.person(h) + 0x2A], "stats": Array(p.stats.prefix(7)), "skill": heroSkills[h], "story": message(50 + h)]
    }
    return ["ok": true, "heroes": heroes, "statNames": ["통솔력", "항해술", "지식", "직감", "용기", "검술", "매력"],
            "ask": message(947), "rename": "이름을 바꾸려면 새 이름을 입력하세요. 그대로 쓰려면 건드리지 마세요.", "allGood": "모두 좋습니까?"]
}
