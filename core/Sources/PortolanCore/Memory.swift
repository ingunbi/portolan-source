import Foundation

/// The game's data segment as a new game starts (assets/ds.bin: MAIN.EXE DS with the new-game
/// data DATA1[15] laid over DS:0xC30). The scenario scripts address game records through it
/// exactly as the original does; `ScriptSync` keeps it in step with the voyage model.
public struct DataSegment: Codable {
    public var bytes: [UInt8]

    public init(contentsOf url: URL) throws {
        bytes = [UInt8](try Data(contentsOf: url))
        if bytes.count < 0x10000 { bytes += [UInt8](repeating: 0, count: 0x10000 - bytes.count) }
    }

    public init(from decoder: Decoder) throws {
        bytes = [UInt8](try decoder.singleValueContainer().decode(Data.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Data(bytes))
    }

    public subscript(_ a: Int) -> Int {
        get { Int(bytes[a & 0xFFFF]) }
        set { bytes[a & 0xFFFF] = UInt8(truncatingIfNeeded: newValue) }
    }

    public func word(_ a: Int) -> Int { self[a] | self[a + 1] << 8 }

    public mutating func setWord(_ a: Int, _ v: Int) {
        self[a] = v & 0xFF
        self[a + 1] = (v >> 8) & 0xFF
    }

    public func dword(_ a: Int) -> Int { word(a) | word(a + 2) << 16 }

    public mutating func setDword(_ a: Int, _ v: Int) {
        setWord(a, v & 0xFFFF)
        setWord(a + 2, (v >> 16) & 0xFFFF)
    }

    #if canImport(Darwin)
    static let korean = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
    #endif

    /// CP949 bytes as text (nil when they do not decode).
    static func decodeKorean(_ raw: [UInt8]) -> String? {
        #if canImport(Darwin)
        return String(data: Data(raw), encoding: korean)
        #else
        return PortableKorean.decode(raw)
        #endif
    }

    /// NUL-terminated CP949 string.
    public func string(_ a: Int, max: Int = 64) -> String {
        var raw: [UInt8] = []
        for k in 0..<max {
            let b = bytes[(a + k) & 0xFFFF]
            if b == 0 { break }
            raw.append(b)
        }
        #if canImport(Darwin)
        return String(data: Data(raw), encoding: DataSegment.korean) ?? ""
        #else
        return PortableKorean.decode(raw)
        #endif
    }

    public mutating func setString(_ a: Int, _ s: String, max: Int) {
        #if canImport(Darwin)
        let raw = [UInt8](s.data(using: DataSegment.korean) ?? Data()).prefix(max - 1)
        #else
        let raw = PortableKorean.encode(s).prefix(max - 1)
        #endif
        for k in 0..<max { self[a + k] = k < raw.count ? Int(raw[raw.startIndex + k]) : 0 }
    }
}

/// Record layouts in the data segment (accessors 0x5ADC..0x5BD2).
public enum DS {
    public static let family = 0x11E6, familySize = 14
    public static let gold = 0x123A, heroID = 0x1241
    public static let person = 0x1242, personSize = 50
    public static let npc = 0x29B2, npcSize = 21
    public static let woman = 0x2B56, womanSize = 17
    public static let daysAtSea = 0x2D54, waterRation = 0x2D55, foodRation = 0x2D56
    public static let officers = 0x2D57, salaries = 0x2D75, items = 0x2D93
    public static let fleet = 0x2DB2, fleetSize = 0x85
    public static let cargo = 0x5210, cargoSize = 30
    public static let ship = 0x57CE, shipSize = 25
    public static let port = 0x5F54, portSize = 20
    public static let market = 0x697C, marketSize = 37
    public static let date = 0x56E, currentPort = 0xC3A

    public static func person(_ i: Int) -> Int { person + personSize * i }
    public static func fleet(_ i: Int) -> Int { fleet + fleetSize * i }
    public static func family(_ i: Int) -> Int { family + familySize * i }
}
