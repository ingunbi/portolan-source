import Foundation
import CoreFoundation

/// Stable vessel identity without changing the original DOS ship records.
/// The fallback is only for pre-envelope saves; v1 decoding verifies ID presence first.
@propertyWrapper
public struct ShipIdentity: Codable {
    public var wrappedValue: UUID
    public init() { wrappedValue = UUID() }
    public init(from decoder: Decoder) throws {
        wrappedValue = try decoder.singleValueContainer().decode(UUID.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    public func decode(_ type: ShipIdentity.Type, forKey key: Key) throws -> ShipIdentity {
        contains(key) ? try superDecoder(forKey: key).decodeShipIdentity() : ShipIdentity()
    }
}

private extension Decoder {
    func decodeShipIdentity() throws -> ShipIdentity { try ShipIdentity(from: self) }
}

/// A JSON value for versioned extension payloads. Unsupported payloads are
/// refused by the current reader, never silently discarded on load and save.
public enum SaveJSON: Codable, Equatable {
    case object([String: SaveJSON]), array([SaveJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let a = try? c.decode([SaveJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: SaveJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

public struct SaveExtension: Codable, Equatable {
    public var version: Int
    public var state: SaveJSON
    public init(version: Int, state: SaveJSON) { self.version = version; self.state = state }
}

/// Owned by a voyage in memory, encoded once by SaveEnvelope rather than in the DOS model.
public struct SaveContext {
    public var saveID = UUID()
    public var generation = 0
    public var rules = RulesProfile.original
    public var contentRevision = "legacy-unverified"
    public var extensionState: [String: SaveExtension] = [:]
    public init() {}
}

public enum SaveFailure: LocalizedError, Equatable {
    case invalidSlot, missing, busy, slotOccupied, corrupt(String), unsupportedVersion(Int), unsupportedExtension(String), unsupportedRulesMode(String)
    case cannotRead(String), cannotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSlot: return "저장 슬롯 번호가 올바르지 않습니다."
        case .missing: return "이 슬롯에 저장 파일이 없습니다."
        case .busy: return "같은 슬롯에 다른 저장 작업이 진행 중입니다. 잠시 후 다시 시도해 주세요."
        case .slotOccupied: return "선택한 슬롯에 저장 또는 복구 파일이 있습니다. 다른 빈 슬롯을 선택해 주세요."
        case .corrupt(let reason): return "저장 파일을 읽을 수 없습니다: \(reason)"
        case .unsupportedVersion(let n): return "이 앱에서 지원하지 않는 저장 버전입니다 (\(n)). 원본 파일은 유지됩니다."
        case .unsupportedExtension(let key): return "이 앱에서 지원하지 않는 확장 상태입니다 (\(key)). 원본 파일은 유지됩니다."
        case .unsupportedRulesMode(let mode): return "이 앱에서 지원하지 않는 규칙 모드입니다 (\(mode)). 원본 파일은 유지됩니다."
        case .cannotRead(let reason): return "저장 파일 읽기에 실패했습니다: \(reason)"
        case .cannotWrite(let reason): return "저장에 실패했습니다: \(reason)"
        }
    }
}

public struct SaveEnvelope: Codable {
    public static let currentVersion = 1
    public let schemaVersion: Int
    public let saveID: UUID
    public let generation: Int
    public let contentRevision: String
    public let rules: RulesProfile
    public let summary: SaveGame.Header
    public var voyage: Voyage
    public let extensionState: [String: SaveExtension]

    public init(voyage: Voyage, summary: SaveGame.Header, generation: Int) {
        schemaVersion = Self.currentVersion
        saveID = voyage.saveContext.saveID
        self.generation = generation
        contentRevision = voyage.saveContext.contentRevision
        rules = voyage.saveContext.rules
        self.summary = summary
        self.voyage = voyage
        extensionState = voyage.saveContext.extensionState
    }
}

enum SaveCodec {
    struct Decoded {
        var voyage: Voyage
        var header: SaveGame.Header?
        let legacy: Bool
    }

    static func decode(_ data: Data) throws -> Decoded {
        guard data.count <= 32 * 1024 * 1024 else { throw SaveFailure.corrupt("파일 크기가 너무 큽니다.") }
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SaveFailure.corrupt("저장 객체 형식이 아닙니다.")
            }
            if let version = json["schemaVersion"] {
                guard let numeric = version as? NSNumber,
                      CFGetTypeID(numeric) != CFBooleanGetTypeID(),
                      numeric.doubleValue == Double(numeric.intValue) else {
                    throw SaveFailure.corrupt("저장 버전 형식이 잘못되었습니다.")
                }
                let n = numeric.intValue
                guard n == SaveEnvelope.currentVersion else { throw SaveFailure.unsupportedVersion(n) }
                if let rules = json["rules"] as? [String: Any], let mode = rules["mode"] as? String,
                   RulesMode(rawValue: mode) == nil { throw SaveFailure.unsupportedRulesMode(mode) }
                guard let state = json["voyage"] as? [String: Any] else { throw SaveFailure.corrupt("항해 상태가 없습니다.") }
                try validateIdentityKeys(state)
                let e = try JSONDecoder().decode(SaveEnvelope.self, from: data)
                guard e.generation > 0, e.generation < Int.max, !e.contentRevision.isEmpty else { throw SaveFailure.corrupt("저장 세대 정보가 잘못되었습니다.") }
                try e.rules.validate()
                if let key = e.extensionState.keys.sorted().first { throw SaveFailure.unsupportedExtension(key) }
                var v = e.voyage
                try validate(v)
                guard e.summary.date == SaveGame.dateText(v), [0, 2, 3].contains(e.summary.type) else {
                    throw SaveFailure.corrupt("슬롯 정보와 본문이 일치하지 않습니다.")
                }
                v.saveContext.saveID = e.saveID
                v.saveContext.generation = e.generation
                v.saveContext.contentRevision = e.contentRevision
                v.saveContext.rules = e.rules
                v.saveContext.extensionState = e.extensionState
                return Decoded(voyage: v, header: e.summary, legacy: false)
            }
            // A damaged envelope must not be interpreted as a legacy Voyage.
            guard json["voyage"] == nil, json["rules"] == nil, json["extensionState"] == nil else {
                throw SaveFailure.corrupt("저장 버전 정보가 없습니다.")
            }
            let v = try JSONDecoder().decode(Voyage.self, from: data)
            try validate(v)
            return Decoded(voyage: v, header: nil, legacy: true)
        } catch let e as SaveFailure { throw e }
        catch let e as DecodingError {
            let path: String
            switch e {
            case .keyNotFound(let key, let c): path = (c.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".")
            case .dataCorrupted(let c), .typeMismatch(_, let c), .valueNotFound(_, let c): path = c.codingPath.map(\.stringValue).joined(separator: ".")
            @unknown default: path = ""
            }
            throw SaveFailure.corrupt(path.isEmpty ? "JSON 자료가 손상되었습니다." : "\(path) 항목이 없거나 잘못되었습니다.")
        } catch {
            // Preserve structured rule errors rather than calling every failure "file missing".
            if error is CocoaError { throw SaveFailure.corrupt("JSON 자료가 손상되었습니다.") }
            throw error
        }
    }

    static func encode(_ envelope: SaveEnvelope) throws -> Data {
        try validate(envelope.voyage)
        try envelope.rules.validate()
        if let key = envelope.extensionState.keys.sorted().first { throw SaveFailure.unsupportedExtension(key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        _ = try decode(data)
        return data
    }

    private static func validateIdentityKeys(_ state: [String: Any]) throws {
        let fleet = state["ships"] as? [[String: Any]] ?? []
        let dock = (state["dock"] as? [[String: Any]] ?? []).compactMap { $0["ship"] as? [String: Any] }
        let orders = (state["orders"] as? [[String: Any]] ?? []).compactMap { $0["ship"] as? [String: Any] }
        for ship in fleet + dock + orders {
            guard let id = ship["shipInstanceID"] as? String, UUID(uuidString: id) != nil else {
                throw SaveFailure.corrupt("선박 식별자가 없거나 잘못되었습니다.")
            }
        }
    }

    static func validate(_ v: Voyage) throws {
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw SaveFailure.corrupt(reason) }
        }
        try require(v.memory.bytes.count == 65536, "원작 메모리 크기가 잘못되었습니다.")
        try require(v.x.isFinite && v.y.isFinite && v.heading.isFinite
                    && (0..<Double(World.width)).contains(v.x) && (0..<Double(World.height)).contains(v.y), "항해 좌표가 잘못되었습니다.")
        try require((0..<12).contains(v.month) && (0..<31).contains(v.dayOfMonth)
                    && (0..<72).contains(v.tick) && (0...9999).contains(v.year), "게임 날짜가 잘못되었습니다.")
        try require((0...Int(UInt32.max)).contains(v.gold) && v.day >= 0, "금화 또는 경과일이 잘못되었습니다.")
        try require(v.fame.count == 3 && v.standing.count == 6, "명성 또는 국가 정보가 잘못되었습니다.")
        try require(v.ships.count <= 10 && v.officers.count <= 30 && v.items.count <= 20, "보유 한도를 초과했습니다.")
        try require(v.markets.isEmpty || v.markets.count == 100, "시장 수가 잘못되었습니다.")
        // Supply ports retain the last ordinary market; there are exactly 100 markets.
        try require((0..<100).contains(v.marketIndex), "시장 위치가 잘못되었습니다.")
        let w = v.weather
        try require((0..<8).contains(w.windDir) && (0..<8).contains(w.currentDir)
                    && (0...7).contains(w.windStrength) && (0...7).contains(w.currentStrength)
                    && [0, 0x40, 0x80, 0xC0].contains(w.windFlags)
                    && [0, 0x40, 0x80, 0xC0].contains(w.currentFlags), "풍향 또는 해류 정보가 잘못되었습니다.")
        try require(v.route.allSatisfy { $0.count == 2 && $0.allSatisfy { $0.isFinite && abs($0) < 10000 } }, "항로 좌표가 잘못되었습니다.")
        try require((0..<6).contains(v.memory[DS.heroID]), "주인공 정보가 잘못되었습니다.")
        try require(Set(v.officers.map(\.person)).count == v.officers.count
                    && v.officers.allSatisfy { (0..<120).contains($0.person) && $0.stats.count == 8 }, "항해사 정보가 잘못되었습니다.")
        for market in v.markets {
            try require(market.support.count == 6 && market.prices.count == 10
                        && (0..<13).contains(market.zone) && (0..<11).contains(market.shipRegion)
                        && (0..<14).contains(market.drink) && (0...6).contains(market.nation), "시장 참조 정보가 잘못되었습니다.")
        }
        let ships = v.ships + v.dock.map(\.ship) + v.orders.map(\.ship)
        try require(Set(ships.map(\.shipInstanceID)).count == ships.count, "중복된 선박 식별자가 있습니다.")
        for s in ships {
            try require((0..<25).contains(s.classIndex) && (0...7).contains(s.gunType)
                        && s.holds.count <= 5 && s.holds.allSatisfy { (0..<46).contains($0.good) && (0...65535).contains($0.amount) }, "선박 또는 화물 참조가 잘못되었습니다.")
            try require([s.crew, s.hull, s.maxHull, s.rudder, s.sail, s.guns, s.water, s.food,
                         s.lumber, s.shot, s.crewCapacity, s.cargoCapacity, s.gunCapacity].allSatisfy { (0...1_000_000).contains($0) }, "선박 수량이 잘못되었습니다.")
        }
        try require(v.dock.allSatisfy { (0..<100).contains($0.port) }
                    && v.orders.allSatisfy { (0..<100).contains($0.port) && $0.daysLeft >= 0 }, "보관 또는 건조 정보가 잘못되었습니다.")
        try require(v.shipyardStocks.allSatisfy { (0..<100).contains($0.port) && $0.classes.allSatisfy { (0..<25).contains($0) } }, "조선소 재고가 잘못되었습니다.")
    }
}
