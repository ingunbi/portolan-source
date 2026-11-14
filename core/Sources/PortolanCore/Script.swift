import Foundation

// Scenario script VM recovered from MAIN.EXE (main loop 0x32B8B, dispatch 0x323B1 / 0x325B1 /
// 0x326EB / 0x3287A). Scripts run against the data segment (`Voyage.memory`), which
// `ScriptSync` fills from the voyage before a run and reads back after it. Format and opcode
// table: docs/re/scenario.md.

/// SNRn.DAT: "SNDT", big-endian chapter offsets, block offsets, then trigger tables and code.
public struct ScriptFile {
    public let bytes: [UInt8]
    public let lines: [String]
    /// Absolute offset of each chapter header.
    let chapters: [Int]

    public init(data: [UInt8], lines: [String]) {
        bytes = data
        self.lines = lines
        var c: [Int] = []
        var i = 0x10
        while i + 4 <= data.count {
            let v = ScriptFile.u32(data, i)
            if v == 0xFFFF_FFFF { break }
            c.append(v)
            i += 4
        }
        chapters = c
    }

    static func u32(_ d: [UInt8], _ a: Int) -> Int {
        Int(d[a]) << 24 | Int(d[a + 1]) << 16 | Int(d[a + 2]) << 8 | Int(d[a + 3])
    }

    func u16(_ a: Int) -> Int { a + 1 < bytes.count ? Int(bytes[a]) << 8 | Int(bytes[a + 1]) : 0xFFFF }

    /// Absolute start of block `b` of chapter `c` (loader 0x32206); nil when the story is over.
    func blockStart(chapter c: Int, block b: Int) -> Int? {
        guard c < chapters.count else { return nil }
        let rel = u16(chapters[c] + 2 * b)
        return rel == 0xFFFF ? nil : chapters[c] + rel
    }

    /// Trigger lookup (0x32E02 / 0x32CC1): first entry whose keys match; 0xA3 is any port
    /// below `limit`, 0xFF any second key.
    func find(start: Int, key1: Int, key2: Int, limit: Int) -> Int? {
        var i = start
        while i + 3 < bytes.count, bytes[i] != 0xFF {
            let k1 = Int(bytes[i]), k2 = Int(bytes[i + 1])
            if (k1 == key1 || (key1 < limit && k1 == 0xA3)) && (k2 == key2 || k2 == 0xFF) { return u16(i + 2) }
            i += 4
        }
        return nil
    }
}

/// The hero's story (SNR1..6) and the shared scripts (SNR0) keep separate state in the data
/// segment: chapter, block, 64 flags, 64 words (DS:0xC60 / DS:0xCEA).
public enum ScriptContext: Int, Codable {
    case hero, shared

    public var base: Int { self == .hero ? 0xC60 : 0xCEA }
    var flags: Int { base + 2 }
    var vars: Int { base + 0xA }
    /// The wildcard port key matches ports below this (0x32E02 / 0x32CC1).
    var limit: Int { self == .hero ? 100 : 0x82 }
}

/// Trigger keys besides (port, building).
public enum ScriptKey {
    public static let atSea = 0xA0, battleStart = 0xA1, battleEnd = 0xA2
    /// Building numbers (door table DS:0x88C).
    public static let market = 0, tavern = 1, shipyard = 2, harbor = 3, inn = 4, palace = 5, guild = 6,
                      residence = 7, bank = 8, itemShop = 9, church = 10, fortuneTeller = 11, audience = 0x15
}

/// A speech window as the scripts drive it (0x31428): 0 narration, 1 the other speaker,
/// 2 the hero's side, 3 a picture frame.
public struct ScriptWindow: Equatable {
    public let id: Int
    public var face: Int?
    public var speaker: String?
    public var text = ""

    public init(id: Int, face: Int? = nil, speaker: String? = nil, text: String = "") {
        self.id = id
        self.face = face
        self.speaker = speaker
        self.text = text
    }
}

/// What a running script waits for.
public enum ScriptPrompt: Equatable {
    case next                       // C7: click to go on
    case menu([String])             // C9
    case yesNo                      // E9
    case duel(Int)                  // E8: sword duel with person n
    case ending(Int)                // F4
}

public struct ScriptRun {
    public var diagnosticLocation: String { "\(context):start=\(start),pc=\(pc),prompt=\(String(describing: prompt))" }
    public let context: ScriptContext
    let file: ScriptFile
    let start: Int
    var pc: Int
    var seed: UInt32
    public private(set) var windows: [ScriptWindow] = []
    /// The window `C0` selected last (the one the text goes to).
    public internal(set) var current = 0
    public private(set) var picture: Int?
    public private(set) var music: Int?
    var textBuffer = ""
    var nextBlock = false, nextChapter = false
    public private(set) var leave = false
    public private(set) var prompt: ScriptPrompt?
    var promptTarget = 0
    public private(set) var finished = false
    /// Fleets the script asked to re-route (D1).
    public private(set) var replans: [Int] = []

    /// Looks up the trigger and prepares a run (0x32EB6 / 0x32D65), or nil when nothing fires.
    public init?(_ context: ScriptContext, file: ScriptFile, key1: Int, key2: Int, memory m: inout DataSegment, hero: Int) {
        let chapter = m[context.base], block = m[context.base + 1]
        guard chapter != 0xFF else { return nil }
        guard let start = file.blockStart(chapter: chapter, block: block) else {
            m[context.base] = 0xFF
            return nil
        }
        guard let entry = file.find(start: start, key1: key1, key2: key2, limit: context.limit) else { return nil }
        self.context = context
        self.file = file
        self.start = start
        pc = entry
        let p = DS.person(hero)
        let base = (m.word(p + 0x26) + m[p + 0x24]) * m[DS.date + 1] * m[DS.date] + m[DS.date + 2]
            + (context == .hero ? m[DS.date + 3] : 0)
        seed = UInt32(truncatingIfNeeded: base << 8)
        m.setWord(context.vars + 2 * 63, 0)
    }

    // MARK: operands

    private func v(_ n: Int, _ m: DataSegment) -> Int { m.word(context.vars + 2 * (n & 63)) }
    private func setV(_ n: Int, _ x: Int, _ m: inout DataSegment) { m.setWord(context.vars + 2 * (n & 63), x & 0xFFFF) }
    private func f(_ n: Int, _ m: DataSegment) -> Bool { m[context.flags + (n & 63) >> 3] & (1 << (n & 7)) != 0 }
    private func setF(_ n: Int, _ on: Bool, _ m: inout DataSegment) {
        let a = context.flags + (n & 63) >> 3
        m[a] = on ? m[a] | 1 << (n & 7) : m[a] & ~(1 << (n & 7))
    }

    /// Source operand (0x322FE): 0 vN, 1 memory at vN, 2 flag, 3 immediate.
    private func src(_ mode: Int, _ n: Int, byte: Bool, _ m: DataSegment) -> Int {
        switch mode {
        case 0: return byte ? v(n, m) & 0xFF : v(n, m)
        case 1: return byte ? m[v(n, m)] : m.word(v(n, m))
        case 2: return f(n, m) ? (byte ? 0xFF : 0xFFFF) : 0
        default: return n
        }
    }

    private func b(_ k: Int) -> Int { Int(file.bytes[start + pc + k]) }
    private func w(_ k: Int) -> Int { b(k) << 8 | b(k + 1) }

    public var v63: Int { 0 }

    // MARK: running

    /// Runs until the script needs the player or ends.
    public mutating func run(_ voyage: inout Voyage, in world: World) {
        prompt = nil
        var guardSteps = 0
        while !finished && prompt == nil {
            guardSteps += 1
            if guardSteps > 100_000 { finished = true; break }
            step(&voyage, in: world)
        }
    }

    /// Answers the pending prompt: the menu index, 1/0 for yes/no, the duel result.
    public mutating func answer(_ value: Int, _ voyage: inout Voyage, in world: World) {
        guard let p = prompt else { return }
        switch p {
        case .menu: setV(promptTarget, value, &voyage.memory)
        case .yesNo: setF(promptTarget, value != 0, &voyage.memory)
        case .duel: voyage.memory.setWord(0xA538, value)
        case .ending: finished = true
        case .next: break
        }
        prompt = nil
        run(&voyage, in: world)
    }

    private mutating func step(_ voyage: inout Voyage, in world: World) {
        let op = b(0)
        switch op >> 6 {
        case 0: move(op, &voyage)
        case 1: arithmetic(op, &voyage.memory)
        case 2: branch(op, voyage.memory)
        default: command(op, &voyage, in: world)
        }
    }

    /// 0x00-0x3F `00DD SSAA` (0x323B1).
    private mutating func move(_ op: Int, _ voyage: inout Voyage) {
        let a = op & 3, s = (op >> 2) & 3, d = (op >> 4) & 3
        let d1 = b(1), s1 = b(2)
        if a == 3 {
            pc += 3
            if s1 == 0 {
                voyage.memory.setString(v(d1, voyage.memory), textBuffer, max: 64)
            } else {
                setV(d1, system(s1, voyage), &voyage.memory)
            }
            return
        }
        var size = 3
        let value: Int
        if d != 2 && a == 0 && s == 3 {
            value = w(2)
            size = 4
        } else {
            value = src(s, s1, byte: a == 1, voyage.memory)
        }
        pc += size
        switch d {
        case 0: setV(d1, value, &voyage.memory)
        case 1:
            if a == 1 { voyage.memory[v(d1, voyage.memory)] = value & 0xFF } else { voyage.memory.setWord(v(d1, voyage.memory), value) }
        default: setF(d1, value != 0, &voyage.memory)
        }
    }

    /// System values for MOV mode 3.
    private func system(_ k: Int, _ voyage: Voyage) -> Int {
        let m = voyage.memory
        switch k {
        case 1:
            let fx = m.word(DS.fleet(0)), fy = m.word(DS.fleet(0) + 2)
            return (fy / 24) * 90 + fx / 24
        case 2: return m[DS.date]
        case 3: return m[DS.date + 1]
        case 4: return m[DS.date + 2]
        case 5: return m[DS.currentPort]
        case 6: return m.word(0xA538)
        case 7: return m[DS.date + 3]
        default: return 0
        }
    }

    /// 0x40-0x7F `01oD SSoo` (0x325B1).
    private mutating func arithmetic(_ op: Int, _ m: inout DataSegment) {
        let o = op & 0x23, d = (op >> 4) & 1, s = (op >> 2) & 3
        let d1 = b(1), s1 = b(2)
        pc += 3
        let rhs = s == 0 ? v(s1, m) : src(s, s1, byte: true, m)
        let lhs = d == 0 ? v(d1, m) : m[v(d1, m)]
        let r: Int
        switch o {
        case 0: r = lhs + rhs
        case 1: r = lhs - rhs
        case 2: r = lhs * rhs
        case 3: r = rhs == 0 ? 0xFFFF : lhs / rhs
        case 0x20: r = lhs | rhs
        case 0x21: r = lhs & rhs
        case 0x22: r = lhs >> (rhs & 7)
        default: r = lhs << (rhs & 7)
        }
        if d == 0 { setV(d1, r, &m) } else { m[v(d1, m)] = r & 0xFF }
    }

    /// 0x80-0xBF `10LL RRcc` (0x326EB): jumps when the condition is false.
    private mutating func branch(_ op: Int, _ m: DataSegment) {
        let c = op & 3, r = (op >> 2) & 3, l = (op >> 4) & 3
        let holds: Bool
        let target: Int
        if l == 2 {
            if r == 2 {
                holds = f(b(1), m) == f(b(2), m)
                target = w(3)
                pc += 5
            } else {
                holds = f(b(1), m) == (c & 1 != 0)
                target = w(2)
                pc += 4
            }
        } else {
            let left = l == 0 ? v(b(1), m) : m.word(v(b(1), m))
            let right = r == 0 ? v(b(2), m) : r == 1 ? m.word(v(b(2), m)) : r == 2 ? (f(b(2), m) ? 0xFFFF : 0) : b(2)
            holds = [left == right, left != right, left >= right, left <= right][c]
            target = w(3)
            pc += 5
        }
        if !holds { pc = target }
    }

    /// 0xC0-0xFF (0x3287A).
    private mutating func command(_ op: Int, _ voyage: inout Voyage, in world: World) {
        switch op {
        case 0xC0: openWindow(b(1)); pc += 2
        case 0xC3: if !windows.isEmpty { windows.removeLast() }; pc += 1
        case 0xC4: windows.removeAll(); picture = nil; pc += 1
        case 0xC5:
            if let k = windows.firstIndex(where: { $0.id == b(1) }) { windows[k].text = "" }
            pc += 2
        case 0xC7:
            pc += 1
            prompt = .next
        case 0xC8:
            say(expand(w(1), voyage.memory))
            pc += 3
        case 0xC9:
            promptTarget = b(1)
            let choices = expand(w(2), voyage.memory).components(separatedBy: "\n")
            pc += 4
            prompt = .menu(choices)
        case 0xCA: music = b(1); pc += 2
        case 0xCB: picture = b(5); pc += 6
        case 0xCC: setFace(w(1)); pc += 3
        case 0xCD: setFace(v(b(1), voyage.memory)); pc += 2
        case 0xD0, 0xDC:
            let index = op == 0xD0 ? v(b(3), voyage.memory) : b(3)
            setV(b(1), address(table: b(2), index: index, field: b(4), &voyage, in: world), &voyage.memory)
            pc += 5
        case 0xD1: replans.append(v(b(1), voyage.memory)); pc += 2
        case 0xD4: textBuffer = expand(w(1), voyage.memory); pc += 3
        case 0xE2:
            ScriptCargo.add(good: v(b(1), voyage.memory) & 0xFF, amount: v(b(2), voyage.memory), &voyage.memory)
            pc += 3
        case 0xE3:
            let left = ScriptCargo.take(good: v(b(1), voyage.memory) & 0xFF, amount: v(b(2), voyage.memory), &voyage.memory)
            setV(b(2), left, &voyage.memory)
            pc += 3
        case 0xE4: setGold(Int(Int16(truncatingIfNeeded: v(b(1), voyage.memory))), &voyage.memory); pc += 2
        case 0xE6:
            setGold(voyage.memory.dword(DS.gold) + Int(Int16(truncatingIfNeeded: v(b(1), voyage.memory))), &voyage.memory)
            pc += 2
        case 0xE7:
            let g = voyage.memory.dword(DS.gold), x = v(b(1), voyage.memory)
            setGold(x >= g ? 0 : g - x, &voyage.memory)
            pc += 2
        case 0xE8:
            let who = b(1)
            pc += 2
            prompt = .duel(who)
        case 0xE9:
            promptTarget = b(1)
            pc += 2
            prompt = .yesNo
        case 0xEA: setV(b(1), voyage.memory.dword(DS.gold) / 10000, &voyage.memory); pc += 2
        case 0xEB:
            seed = seed &* 0x5D58_8B65 &+ 1
            let n = w(2)
            setV(b(1), n == 0 ? 0 : Int((seed >> 8) & 0x7FFF) % n, &voyage.memory)
            pc += 4
        case 0xEC: seed = UInt32(v(b(1), voyage.memory)) << 8; pc += 2
        case 0xED: setV(b(1), Int(seed >> 8) & 0xFFFF, &voyage.memory); pc += 2
        case 0xEE: setV(b(1), ScriptCargo.free(voyage.memory), &voyage.memory); pc += 2
        case 0xF0: nextBlock = true; pc += 1
        case 0xF1: nextChapter = true; pc += 1
        case 0xF2: finished = true
        case 0xF4:
            let code = b(1)
            pc += 2
            prompt = .ending(code)
        case 0xF8: leave = true; pc += 1
        case 0xF9:
            voyage.scriptOrderShip(class: b(1), in: world)
            pc += 3
        case 0xFA:
            voyage.scriptDeliverShip(named: expand(w(2), voyage.memory), in: world)
            pc += 4
        case 0xFB: join(b(1), &voyage.memory); pc += 2
        case 0xFC:
            let a = DS.woman + DS.womanSize * b(1) + 0x0D
            voyage.memory[a] = min(100, voyage.memory[a] + Int(Int8(truncatingIfNeeded: b(2))))
            pc += 3
        case 0xFE: pc = w(1)
        case 0xFF: pc += 1
        default: finished = true                                       // invalid: error dialog 0x3291E
        }
    }

    // MARK: commands

    private mutating func openWindow(_ id: Int) {
        current = id
        if let k = windows.firstIndex(where: { $0.id == id }) {
            windows[k].text = ""
            windows[k].speaker = nil
        } else {
            if windows.count == 2 { windows.removeFirst() }
            windows.append(ScriptWindow(id: id))
        }
    }

    private mutating func setFace(_ face: Int) {
        guard let k = windows.firstIndex(where: { $0.id == current }) else { return }
        windows[k].face = face
    }

    private mutating func say(_ line: String) {
        guard let k = windows.firstIndex(where: { $0.id == current }) else { return }
        var text = line
        if text.hasPrefix("§"), let end = text.dropFirst().firstIndex(of: "§") {
            windows[k].speaker = String(text[text.index(after: text.startIndex)..<end])
            text = String(text[text.index(after: end)...])
            if text.hasPrefix("\n") { text.removeFirst() }
        }
        windows[k].text += (windows[k].text.isEmpty ? "" : "\n") + text
    }

    private func setGold(_ g: Int, _ m: inout DataSegment) {
        m.setDword(DS.gold, max(0, min(Trade.goldCap, g)))
    }

    /// FB: the person joins in the first free officer slot (0x31E52).
    private func join(_ p: Int, _ m: inout DataSegment) {
        guard let k = (0..<30).first(where: { m[DS.officers + $0] == 0xFF }) else { return }
        m[DS.officers + k] = p
        let hero = DS.person(m[DS.heroID])
        m[DS.person(p) + 0x2E] = 6
        m[DS.person(p) + 0x2C] = m[hero + 0x2C]
        m[DS.person(p) + 0x2D] = m[hero + 0x2D]
    }

    /// D0/DC record tables (0x3162E).
    private func address(table t: Int, index i: Int, field f: Int, _ voyage: inout Voyage, in world: World) -> Int {
        let tables: [Int: (Int, Int)] = [0: (0x1106, 32), 1: (DS.family, DS.familySize), 2: (DS.gold, 0),
                                         3: (DS.person, DS.personSize), 4: (DS.npc, DS.npcSize), 5: (DS.woman, DS.womanSize),
                                         6: (DS.daysAtSea, 0), 8: (DS.fleet, DS.fleetSize), 9: (DS.cargo, DS.cargoSize),
                                         10: (DS.ship, DS.shipSize), 11: (0x5E28, 12), 12: (DS.port, DS.portSize),
                                         13: (DS.market, DS.marketSize), 14: (0x77F0, 128), 15: (0x7E70, 8),
                                         16: (0x7E88, 7), 17: (0x8144, 26), 19: (0xC0B6, 2)]
        if t == 7 { return i < 10 ? voyage.memory.word(0xC6DA) + 0x2B + 9 * i + f : 0x5666 + 9 * i + f }
        if t == 18 {
            world.loadDiscovery(i, into: &voyage.memory)
            return 0xBEF6 + f
        }
        guard let (base, size) = tables[t] else { return 0 }
        return base + size * i + f
    }

    /// MES line with `$` codes expanded (0x31FBE) and the particles fitted to the words.
    func expand(_ n: Int, _ m: DataSegment) -> String {
        let raw = file.lines.indices.contains(n) ? file.lines[n] : ""
        var out = ""
        var it = raw.makeIterator()
        let hero = DS.person(m[DS.heroID])
        while let ch = it.next() {
            guard ch == "$", let code = it.next() else {
                out.append(ch)
                continue
            }
            switch code {
            case "n": out += m.string(hero, max: 13)
            case "s": out += m.string(hero + 0x0D, max: 13)
            case "d", "r":
                let digits = String([it.next(), it.next()].compactMap { $0 })
                let k = Int(digits) ?? 0
                out += code == "d" ? "\(v(k, m))" : m.string(v(k, m))
            default: out.append(code)
            }
        }
        return Korean.particles(out)
    }

    /// Ends the run: block and chapter moves (0x32B8B steps 5–6). Returns false for `leave`.
    public mutating func finish(_ m: inout DataSegment) -> Bool {
        var chapter = m[context.base], block = m[context.base + 1]
        let before = chapter
        if nextChapter {
            chapter += 1
            block = 0
            for k in 0..<4 { m[context.flags + k] = 0 }                  // f0..f31
            if file.blockStart(chapter: chapter, block: 0) == nil { chapter = 0xFF }
        } else if nextBlock {
            block += 1
        }
        if context == .shared && chapter != before {
            chapter = chapter == 0xFF ? 0 : chapter
            if nextChapter { chapter = 0; block = 0 }
        }
        m[context.base] = chapter
        m[context.base + 1] = block
        return !leave
    }

    /// v63: the script did the talking, so the game skips its own line.
    public func spoke(_ m: DataSegment) -> Bool { v(63, m) != 0 }
}

/// Cargo opcodes over the player's ship slots in the data segment (0x317F8, 0x318FB, 0x31BFF).
enum ScriptCargo {
    static func slots(_ m: DataSegment) -> [Int] {
        let fleet = m.word(0xC6DA)
        return (0..<10).filter { m[fleet + 0x2B + 9 * $0 + 8] & 0x30 == 0x10 }
    }

    static func free(_ m: DataSegment, _ i: Int) -> Int {
        let c = DS.cargo + DS.cargoSize * i
        let ship = DS.ship + DS.shipSize * m[m.word(0xC6DA) + 0x2B + 9 * i + 7]
        var load = m.word(c) / 10 + m.word(c + 2) / 10 + m.word(c + 4) + m.word(c + 6)
        for k in 0..<5 where m[c + 0x16 + k] != 0xFF { load += m.word(c + 0xC + 2 * k) }
        return max(0, m.word(ship + 0x17) - load)
    }

    static func free(_ m: DataSegment) -> Int { slots(m).reduce(0) { $0 + free(m, $1) } }

    static func add(good: Int, amount: Int, _ m: inout DataSegment) {
        var left = amount
        for i in slots(m) where left > 0 {
            let c = DS.cargo + DS.cargoSize * i
            let room = free(m, i)
            guard room > 0 else { continue }
            let k = (0..<5).first { m[c + 0x16 + $0] == good } ?? (0..<5).first { m[c + 0x16 + $0] == 0xFF }
            guard let k else { continue }
            let n = min(room, left)
            m[c + 0x16 + k] = good
            m.setWord(c + 0xC + 2 * k, m.word(c + 0xC + 2 * k) + n)
            left -= n
        }
    }

    static func take(good: Int, amount: Int, _ m: inout DataSegment) -> Int {
        var left = amount
        var remaining = 0
        for i in slots(m) {
            let c = DS.cargo + DS.cargoSize * i
            for k in 0..<5 where m[c + 0x16 + k] == good {
                let n = min(left, m.word(c + 0xC + 2 * k))
                m.setWord(c + 0xC + 2 * k, m.word(c + 0xC + 2 * k) - n)
                left -= n
                if m.word(c + 0xC + 2 * k) == 0 { m[c + 0x16 + k] = 0xFF }
                remaining += m.word(c + 0xC + 2 * k)
            }
        }
        return remaining
    }
}

/// Korean particles: the text marks them as `(를)`, `(가)`, `(는)`... after a name or number,
/// and the printer picks the form that fits the last syllable (0x4184, 0x4240).
public enum Korean {
    static let pairs: [String: (String, String)] = [
        "를": ("을", "를"), "을": ("을", "를"), "가": ("이", "가"), "이": ("이", "가"), "는": ("은", "는"), "은": ("은", "는"),
        "야": ("아", "야"), "아": ("아", "야"), "와": ("과", "와"), "과": ("과", "와"), "로": ("으로", "로"),
        "으로": ("으로", "로"), "이냐": ("이냐", "냐"), "냐": ("이냐", "냐"), "라고": ("이라고", "라고"),
        "이라고": ("이라고", "라고"), "여": ("이여", "여"), "라": ("이라", "라"), "이라": ("이라", "라"),
    ]

    /// Final consonant of the syllable before a particle: nil for none, 8 for ㄹ.
    static func coda(_ c: Character) -> Int? {
        if let s = c.unicodeScalars.first?.value, (0xAC00...0xD7A3).contains(s) {
            let k = Int(s - 0xAC00) % 28
            return k == 0 ? nil : k
        }
        // 영 일 이 삼 사 오 육 칠 팔 구
        let digits: [Character: Int?] = ["0": 21, "1": 8, "2": nil, "3": 16, "4": nil, "5": nil, "6": 1, "7": 8, "8": 8, "9": nil]
        if let d = digits[c] { return d }
        return nil
    }

    public static func particles(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "(", let close = s[i...].firstIndex(of: ")") {
                let word = String(s[s.index(after: i)..<close])
                if let (withCoda, without) = pairs[word], let last = out.last {
                    let k = coda(last)
                    out += word.hasSuffix("로") || word == "로" ? (k == nil || k == 8 ? without : withCoda) : (k == nil ? without : withCoda)
                    i = s.index(after: close)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}

/// One game event's scripts: building entry runs the shared scripts first, then the hero's
/// story unless the shared script spoke (0x1B17F). `leave` and `spoke` are what the game
/// does with the results.
public struct ScriptSession {
    public let key1: Int, key2: Int
    let port: Int?
    var pending: [ScriptContext]
    public private(set) var run: ScriptRun?
    public private(set) var leave = false
    public private(set) var spoke = false
    public private(set) var done = false
    /// Endings reached (F4 codes).
    public private(set) var ending: Int?

    public init(key1: Int, key2: Int, port: Int?, contexts: [ScriptContext] = [.shared, .hero]) {
        self.key1 = key1
        self.key2 = key2
        self.port = port
        pending = contexts
    }

    public var prompt: ScriptPrompt? { run?.prompt }

    /// Runs scripts until one needs the player or all are done.
    public mutating func advance(_ voyage: inout Voyage, in world: World) {
        while !done {
            if let r = run {
                if r.prompt != nil { return }
                complete(r, &voyage, in: world)
                run = nil
                continue
            }
            guard let ctx = pending.first else {
                done = true
                return
            }
            pending.removeFirst()
            if ctx == .hero && (spoke || !voyage.storyOn) { continue }
            let file = ctx == .hero ? voyage.memory[DS.heroID] + 1 : 0
            guard world.scripts.indices.contains(file) else { continue }
            voyage.exportToMemory(port: port)
            guard var r = ScriptRun(ctx, file: world.scripts[file], key1: key1, key2: key2,
                                    memory: &voyage.memory, hero: voyage.memory[DS.heroID]) else { continue }
            r.run(&voyage, in: world)
            run = r
        }
    }

    public mutating func answer(_ value: Int, _ voyage: inout Voyage, in world: World) {
        guard var r = run else { return }
        if case .ending(let code)? = r.prompt { ending = code }
        r.answer(value, &voyage, in: world)
        run = r
        advance(&voyage, in: world)
    }

    private mutating func complete(_ r: ScriptRun, _ voyage: inout Voyage, in world: World) {
        var r = r
        if !r.finish(&voyage.memory) { leave = true }
        if r.spoke(voyage.memory) { spoke = true }
        voyage.importFromMemory(in: world)
    }
}
