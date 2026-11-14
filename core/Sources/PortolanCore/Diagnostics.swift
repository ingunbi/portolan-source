import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct DiagnosticRuntime: Codable, Equatable {
    public var pending: Double
    public var stuckDays: Int
    public var dayTile: [Int]
    public var replanned: Bool
    public var seaAlarms: [Int]
    public var soundCues: [String]
    public var log: [String]
}

public enum DiagnosticError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): return "재현 기록을 사용할 수 없습니다: " + reason }
    }
}

public enum DiagnosticCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func hash(_ data: Data) -> String {
        #if canImport(CryptoKit)
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        PortableHash.sha256Hex(data)
        #endif
    }
    public static var platform: String {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "\(arch)/\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}

public struct DiagnosticSnapshot: Codable {
    public let envelope: SaveEnvelope
    public let savedGeneration: Int
    public let runtime: DiagnosticRuntime
    public let secondsPerDay: Double

    public init(_ voyage: Voyage) {
        envelope = SaveEnvelope(voyage: voyage,
            summary: SaveGame.Header(date: SaveGame.dateText(voyage), port: nil, type: 0),
            generation: max(1, voyage.saveContext.generation))
        savedGeneration = voyage.saveContext.generation
        runtime = voyage.diagnosticRuntime
        secondsPerDay = Voyage.secondsPerDay
    }
    public func restore() throws -> Voyage {
        guard envelope.schemaVersion == SaveEnvelope.currentVersion,
              secondsPerDay.isFinite, (0.1...60).contains(secondsPerDay),
              runtime.pending.isFinite, runtime.pending >= 0, runtime.pending < 100_000,
              (0...1).contains(runtime.stuckDays), runtime.dayTile.count <= 2,
              runtime.seaAlarms.count <= 128, runtime.soundCues.count <= 128, runtime.log.count <= 256 else {
            throw DiagnosticError.invalid("체크포인트의 시간 또는 배열 범위가 잘못되었습니다.")
        }
        var v = envelope.voyage
        try SaveCodec.validate(v); try envelope.rules.validate()
        guard v.day <= 1_000_000, abs(v.heading) < 10000,
              savedGeneration >= 0, savedGeneration < Int.max else { throw DiagnosticError.invalid("체크포인트 수치 범위 초과") }
        guard envelope.extensionState.isEmpty else { throw DiagnosticError.invalid("지원하지 않는 확장 체크포인트입니다.") }
        v.saveContext.saveID = envelope.saveID; v.saveContext.generation = savedGeneration
        v.saveContext.rules = envelope.rules; v.saveContext.contentRevision = envelope.contentRevision
        v.diagnosticRuntime = runtime
        return v
    }
    public func hash() throws -> String {
        // Set encoding order is unspecified across processes. Canonicalize its one array.
        var root = try JSONSerialization.jsonObject(with: DiagnosticCodec.encode(self)) as! [String: Any]
        var envelope = root["envelope"] as! [String: Any]
        var v = envelope["voyage"] as! [String: Any]
        if let developing = v["developing"] as? [Int] { v["developing"] = developing.sorted() }
        envelope["voyage"] = v; root["envelope"] = envelope
        return DiagnosticCodec.hash(try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
}

/// These operations have a complete Voyage+runtime checkpoint. Battle and SNR interpreter
/// stacks are intentionally diagnostic-only; no fake command replay is claimed for them.
public enum DiagnosticCommand: Codable, Equatable {
    case advance(dt: Double, turn: Double, secondsPerDay: Double)
    case sail(Int)
    case course(x: Double, y: Double)
    case anchor
    case buy(good: Int, basePrice: Int, amount: Int, ship: Int, unitPrice: Int? = nil)
    case sell(hold: Int, amount: Int, ship: Int)
    case supply(kind: Int, barrels: Int, ship: Int)
    case repair(ship: Int)

    public var consumedDelta: Double { if case .advance(let dt, _, _) = self { return dt }; return 0 }
    public var isSimulationStep: Bool { if case .advance = self { return true }; return false }

    @discardableResult
    public func apply(to v: inout Voyage, in world: World) throws -> String {
        func bound(_ values: Int...) throws {
            guard values.allSatisfy({ abs(Double($0)) <= 1_000_000 }) else { throw DiagnosticError.invalid("명령 수량 범위 초과") }
        }
        switch self {
        case .advance(let dt, let turn, let seconds):
            guard dt.isFinite, (0...1).contains(dt), turn.isFinite, (-1...1).contains(turn),
                  seconds.isFinite, (0.1...60).contains(seconds) else { throw DiagnosticError.invalid("시간 진행 입력 범위 초과") }
            let previous = Voyage.secondsPerDay; Voyage.secondsPerDay = seconds
            defer { Voyage.secondsPerDay = previous }
            if turn != 0 { v.steer(turn * 1.6 * dt) }
            v.tick(dt, in: world)
            return "applied"
        case .sail(let delta):
            guard (-1...1).contains(delta) else { throw DiagnosticError.invalid("돛 입력 범위 초과") }
            v.setSail(delta); return "applied"
        case .course(let x, let y):
            return v.setSeaCourse(x: x, y: y, in: world) ? "accepted" : "rejected"
        case .anchor: _ = v.toggleAnchor(); return "applied"
        case .buy(let good, let price, let amount, let ship, let unitPrice):
            try bound(good, price, amount, ship)
            if let unitPrice { try bound(unitPrice) }
            return v.buy(Offer(good: good, basePrice: price), amount: amount, ship: ship, in: world, unitPrice: unitPrice) ? "accepted" : "rejected"
        case .sell(let hold, let amount, let ship):
            try bound(hold, amount, ship)
            return v.sell(hold: hold, amount: amount, ship: ship, in: world) ? "accepted" : "rejected"
        case .supply(let kind, let barrels, let ship):
            try bound(barrels, ship)
            guard let supply = Supply(rawValue: kind) else { throw DiagnosticError.invalid("보급 종류 오류") }
            return v.buy(supply, barrels: barrels, ship: ship, at: v.market(in: world)) ? "accepted" : "rejected"
        case .repair(let ship):
            try bound(ship)
            guard v.ships.indices.contains(ship) else { throw DiagnosticError.invalid("수리 대상 함선이 없습니다.") }
            return v.repair(ship, in: world) ? "accepted" : "rejected"
        }
    }
}

public struct DiagnosticContext: Codable, Equatable {
    public var screen: String
    public var generation: Int
    public var scriptLocation: String?
    public var battleLocation: String?
    public var violations: [String]
    public init(screen: String, generation: Int = 0, scriptLocation: String? = nil,
                battleLocation: String? = nil, violations: [String] = []) {
        self.screen = screen; self.generation = generation; self.scriptLocation = scriptLocation
        self.battleLocation = battleLocation; self.violations = violations
    }
}

public struct DiagnosticRecord: Codable {
    public var commandSequence: Int
    public var simulationStep: Int
    public var gameTick: Int
    public var consumedDelta: Double
    public var command: DiagnosticCommand
    public var result: String
    public var beforeHash: String
    public var afterHash: String
    public var context: DiagnosticContext
}
public struct DiagnosticSegment: Codable {
    public var checkpoint: DiagnosticSnapshot
    public var firstSequence: Int
    public var firstSimulationStep: Int
    public var lastSequence: Int
    public var records: [DiagnosticRecord]
    public var finalHash: String
}
public struct DiagnosticEvent: Codable {
    public let sequence: Int
    public let label: String
    public let gameTick: Int
    public let rng: UInt32
    public let context: DiagnosticContext
}
public struct DiagnosticBundle: Codable {
    public var schemaVersion = 1
    public var runID = UUID()
    public var identity: BuildIdentity
    public var platform = DiagnosticCodec.platform
    public var contentRevision: String
    public var segments: [DiagnosticSegment] = []
    public var diagnosticOnlyEvents: [DiagnosticEvent] = []
    public var incompleteReasons: [String] = []
    public var safeCheckpointsDiscarded = 0
    public var recordingStopped = false
    public var disabledIntervals = 0
    public private(set) var supportedPaths = ["sailing-dt-steering", "sail", "chart-course", "anchor", "trade-buy-sell", "supply", "repair"]
    public private(set) var diagnosticOnlyPaths = ["SNR dialogue/interpreter", "battle/duel/result", "other generic mutations", "town movement"]
}

/// Bounded in-memory observation. It cannot modify Voyage, consume its RNG, or write a save.
public final class DiagnosticRecorder {
    public private(set) var bundle: DiagnosticBundle
    public var enabled = true {
        didSet {
            guard enabled != oldValue else { return }
            needsCheckpoint = true
            if !enabled {
                if bundle.disabledIntervals < Int.max { bundle.disabledIntervals += 1 }
                addReason("진단 기록이 꺼진 구간이 있어 전체 세션을 재현할 수 없습니다.")
            }
        }
    }
    public let maxRecords: Int
    public let maxBytes: Int
    public let maxEvents: Int
    private var sequence = 0
    private var simulationStep = 0
    private var needsCheckpoint = true
    private var stopped = false
    private var headerBytes = 0
    private var segmentBytes: [Int] = []
    private var eventBytes: [Int] = []
    /// Space for bounded interruption/context messages, including a final stop reason.
    private let metadataReserve = 512

    public init(identity: BuildIdentity = .current, contentRevision: String,
                maxRecords: Int = 300, maxBytes: Int = 4 * 1024 * 1024, maxEvents: Int = 1024) {
        bundle = DiagnosticBundle(identity: identity, contentRevision: contentRevision)
        self.maxRecords = max(1, maxRecords); self.maxBytes = max(1024, maxBytes); self.maxEvents = max(1, maxEvents)
        refreshHeaderBytes()
        if encodedByteCount > self.maxBytes { stop("기록 기본 정보가 용량 한도를 초과했습니다.") }
    }
    public var recordCount: Int { bundle.segments.reduce(0) { $0 + $1.records.count } }
    public var isStopped: Bool { stopped }
    /// Exact compact JSON size. Cached components avoid re-encoding all checkpoints per frame.
    var encodedByteCount: Int {
        headerBytes + segmentBytes.reduce(0, +) + max(0, segmentBytes.count - 1)
            + eventBytes.reduce(0, +) + max(0, eventBytes.count - 1)
    }

    private func refreshHeaderBytes() {
        var header = bundle
        header.segments = []; header.diagnosticOnlyEvents = []
        headerBytes = (try? DiagnosticCodec.encode(header).count) ?? maxBytes
    }
    private func tick(_ v: Voyage) -> Int? {
        let (days, overflow) = v.day.multipliedReportingOverflow(by: 72)
        let (value, sumOverflow) = days.addingReportingOverflow(v.tick)
        return overflow || sumOverflow ? nil : value
    }
    private func bounded(_ text: String, bytes: Int) -> String {
        String(decoding: text.utf8.prefix(bytes), as: UTF8.self)
    }
    private func bounded(_ context: DiagnosticContext) -> DiagnosticContext {
        let value = DiagnosticContext(screen: bounded(context.screen, bytes: 120), generation: context.generation,
            scriptLocation: context.scriptLocation.map { bounded($0, bytes: 240) },
            battleLocation: context.battleLocation.map { bounded($0, bytes: 240) },
            violations: context.violations.prefix(8).map { bounded($0, bytes: 120) })
        if value != context { addReason("긴 진단 문맥 일부를 기록 한도에 맞춰 줄였습니다.") }
        return value
    }
    private func discardFirstSegment() {
        bundle.segments.removeFirst(); segmentBytes.removeFirst()
        bundle.safeCheckpointsDiscarded += 1
        refreshHeaderBytes()
    }

    public func record(_ command: DiagnosticCommand, before: DiagnosticSnapshot, after: DiagnosticSnapshot,
                       result: String, context: DiagnosticContext) {
        guard enabled, !stopped else { return }
        do {
            guard sequence < Int.max - 1, simulationStep < Int.max - 1,
                  let gameTick = tick(before.envelope.voyage), result.utf8.count <= 256 else {
                stop("명령의 순서 또는 결과가 기록 범위를 벗어났습니다."); return
            }
            let beforeHash = try before.hash(), afterHash = try after.hash()
            if let last = bundle.segments.last, last.finalHash != beforeHash {
                needsCheckpoint = true
                addReason("기록되지 않은 상태 변경 경계에서 새 코어 체크포인트를 시작했습니다.")
            }
            let nextSequence = sequence + 1
            let nextStep = simulationStep + (command.isSimulationStep ? 1 : 0)
            let record = DiagnosticRecord(commandSequence: nextSequence, simulationStep: nextStep,
                gameTick: gameTick,
                consumedDelta: command.consumedDelta, command: command, result: result,
                beforeHash: beforeHash, afterHash: afterHash, context: bounded(context))
            let recordBytes = try DiagnosticCodec.encode(record).count
            let newSegment = needsCheckpoint || (bundle.segments.last?.records.count ?? 0) >= maxRecords
            var proposed: DiagnosticSegment?
            let proposedSize: Int
            if newSegment {
                let segment = DiagnosticSegment(checkpoint: before, firstSequence: nextSequence,
                    firstSimulationStep: simulationStep, lastSequence: nextSequence, records: [record], finalHash: afterHash)
                proposed = segment
                proposedSize = try DiagnosticCodec.encode(segment).count
            } else {
                let last = bundle.segments.last!
                proposedSize = segmentBytes.last! + recordBytes + (last.records.isEmpty ? 0 : 1)
                    + String(nextSequence).utf8.count - String(last.lastSequence).utf8.count
            }
            // Preflight before evicting anything: an oversized new snapshot must not erase
            // the last usable checkpoint. Context/stop messages retain their reserved space.
            let minimumBytes = headerBytes + proposedSize + eventBytes.reduce(0, +) + max(0, eventBytes.count - 1)
            guard minimumBytes <= maxBytes - metadataReserve else {
                stop("체크포인트가 기록 용량을 초과하여 마지막 정상 구간을 보존했습니다."); return
            }
            if let proposed {
                bundle.segments.append(proposed); segmentBytes.append(proposedSize)
            } else {
                let i = bundle.segments.count - 1
                bundle.segments[i].records.append(record); bundle.segments[i].finalHash = afterHash
                bundle.segments[i].lastSequence = nextSequence; segmentBytes[i] = proposedSize
            }
            sequence = nextSequence; simulationStep = nextStep; needsCheckpoint = false
            // Only whole, independently replayable checkpoints are evicted.
            while bundle.segments.count > 1 && (recordCount > maxRecords || encodedByteCount > maxBytes - metadataReserve) {
                discardFirstSegment()
            }
        } catch { stop("상태 해시를 만들지 못해 기록을 중단했습니다.") }
    }
    public func event(_ label: String, voyage: Voyage, context: DiagnosticContext) {
        guard enabled, !stopped else { return }
        needsCheckpoint = true
        guard bundle.diagnosticOnlyEvents.count < maxEvents else {
            stop("완전한 체크포인트가 없는 구간의 사건 기록 한도에 도달했습니다."); return
        }
        guard sequence < Int.max - 1, let gameTick = tick(voyage) else {
            stop("사건의 순서 또는 시간이 기록 범위를 벗어났습니다."); return
        }
        let event = DiagnosticEvent(sequence: sequence + 1, label: bounded(label, bytes: 180),
            gameTick: gameTick, rng: voyage.rng.seed, context: bounded(context))
        guard let size = try? DiagnosticCodec.encode(event).count,
              encodedByteCount + size + (eventBytes.isEmpty ? 0 : 1) <= maxBytes - metadataReserve else {
            stop("사건 기록 용량 한도에 도달하여 마지막 정상 구간을 보존했습니다."); return
        }
        sequence += 1
        bundle.diagnosticOnlyEvents.append(event); eventBytes.append(size)
    }
    private func addReason(_ reason: String) {
        let reason = bounded(reason, bytes: 180)
        guard !bundle.incompleteReasons.contains(reason) else { refreshHeaderBytes(); return }
        bundle.incompleteReasons.append(reason)
        refreshHeaderBytes()
        // An extremely small custom budget may have no room for prose. The stopped/disabled
        // flags still communicate incompleteness, and retained commands remain untouched.
        if encodedByteCount > maxBytes { bundle.incompleteReasons.removeLast(); refreshHeaderBytes() }
    }
    private func stop(_ reason: String) {
        stopped = true; bundle.recordingStopped = true; addReason(reason)
    }
}

public struct DiagnosticReplayResult: Codable {
    public let matchedSegments: Int
    public let matchedCommands: Int
    public let diagnosticOnlyEvents: Int
    public let incompleteReasons: [String]
    public let safeCheckpointsDiscarded: Int
    public let disabledIntervals: Int
    public let recordingStopped: Bool
    public var entireSessionReplayed: Bool {
        diagnosticOnlyEvents == 0 && incompleteReasons.isEmpty && safeCheckpointsDiscarded == 0
            && disabledIntervals == 0 && !recordingStopped
    }
}
public enum DiagnosticReplay {
    public static func run(_ bundle: DiagnosticBundle, in world: World,
                           identity: BuildIdentity = .current) throws -> DiagnosticReplayResult {
        guard bundle.schemaVersion == 1, bundle.identity == identity,
              bundle.platform == DiagnosticCodec.platform, bundle.contentRevision == world.contentRevision else {
            throw DiagnosticError.invalid("앱·소스·자료·플랫폼 버전이 다릅니다.")
        }
        guard !bundle.segments.isEmpty, bundle.segments.count <= 4096 else {
            throw DiagnosticError.invalid("재생 가능한 코어 구간이 없습니다.")
        }
        let previousSpeed = Voyage.secondsPerDay; defer { Voyage.secondsPerDay = previousSpeed }
        var count = 0
        for (index, segment) in bundle.segments.enumerated() {
            guard !segment.records.isEmpty, segment.records.count <= 4096 else { throw DiagnosticError.invalid("구간 \(index)의 명령 개수 오류") }
            guard segment.firstSequence > 0, segment.firstSequence <= Int.max - segment.records.count,
                  segment.firstSimulationStep >= 0, segment.firstSimulationStep <= Int.max - segment.records.count,
                  segment.lastSequence >= segment.firstSequence else { throw DiagnosticError.invalid("구간 \(index)의 순서 범위 오류") }
            guard segment.records.last?.commandSequence == segment.lastSequence else { throw DiagnosticError.invalid("마지막 명령이 없습니다.") }
            var v = try segment.checkpoint.restore()
            Voyage.secondsPerDay = segment.checkpoint.secondsPerDay
            var sequence = segment.firstSequence, step = segment.firstSimulationStep
            for record in segment.records {
                if record.command.isSimulationStep { step += 1 }
                guard record.commandSequence == sequence, record.simulationStep == step,
                      record.gameTick == v.day * 72 + v.tick,
                      record.consumedDelta == record.command.consumedDelta,
                      try DiagnosticSnapshot(v).hash() == record.beforeHash else {
                    throw DiagnosticError.invalid("구간 \(index) 명령 \(sequence): 입력 누락 또는 시작 상태 불일치")
                }
                let result = try record.command.apply(to: &v, in: world)
                guard result == record.result, try DiagnosticSnapshot(v).hash() == record.afterHash else {
                    throw DiagnosticError.invalid("구간 \(index) 명령 \(sequence): 최초 결과 불일치")
                }
                sequence += 1; count += 1
            }
            guard try DiagnosticSnapshot(v).hash() == segment.finalHash else { throw DiagnosticError.invalid("구간 \(index)의 끝이 잘렸습니다.") }
        }
        return DiagnosticReplayResult(matchedSegments: bundle.segments.count, matchedCommands: count,
            diagnosticOnlyEvents: bundle.diagnosticOnlyEvents.count, incompleteReasons: bundle.incompleteReasons,
            safeCheckpointsDiscarded: bundle.safeCheckpointsDiscarded, disabledIntervals: bundle.disabledIntervals,
            recordingStopped: bundle.recordingStopped)
    }
}

public struct DiagnosticExportManifest: Codable {
    public let schemaVersion: Int
    public let runID: UUID
    public let files: [String: String]
    public let privacy: String
}

public enum DiagnosticExport {
    public static let privacy = "게임 주인공·선박 이름, 게임 저장 상태, RNG, 입력과 오류 문맥이 포함됩니다. 컴퓨터 계정·절대 경로·외부 계정·인증 정보는 수집하지 않습니다. 자동 전송하지 않습니다."

    /// New local directory only. Partial exports are never accepted as valid bundles.
    public static func write(_ bundle: DiagnosticBundle, content: ContentManifest, to destination: URL) throws {
        let fm = FileManager.default
        guard bundle.contentRevision == content.contentRevision else { throw DiagnosticError.invalid("자료 목록과 재현 기록이 다릅니다.") }
        guard !fm.fileExists(atPath: destination.path) else { throw DiagnosticError.invalid("내보낼 폴더가 이미 있습니다. 새 이름을 선택해 주세요.") }
        let data = try DiagnosticCodec.encode(bundle), assets = try DiagnosticCodec.encode(content)
        guard data.count <= 8 * 1024 * 1024, assets.count <= 4 * 1024 * 1024 else { throw DiagnosticError.invalid("내보내기 용량 한도 초과") }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".portolan-diagnostic-\(UUID().uuidString)")
        try fm.createDirectory(at: staged, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staged) }
        let files = ["diagnostic.json": data, "content-manifest.json": assets,
                     "README.txt": Data((privacy + "\n\n지원 코어 구간만 PortolanReplay로 비교합니다. 대화·해전 문맥은 진단 전용이며, 사용자 저장 슬롯으로 불러오지 마세요.\n").utf8)]
        for (name, bytes) in files {
            let file = staged.appendingPathComponent(name)
            try bytes.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let manifest = DiagnosticExportManifest(schemaVersion: 1, runID: bundle.runID,
            files: files.mapValues { DiagnosticCodec.hash($0) }, privacy: privacy)
        try DiagnosticCodec.encode(manifest).write(to: staged.appendingPathComponent("manifest.json"), options: .atomic)
        _ = try read(from: staged)
        try fm.moveItem(at: staged, to: destination)
    }

    public static func read(from directory: URL) throws -> DiagnosticBundle {
        func read(_ name: String, limit: Int) throws -> Data {
            let url = directory.appendingPathComponent(name)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= limit else {
                throw DiagnosticError.invalid("\(name)의 파일 종류 또는 크기 오류")
            }
            return try Data(contentsOf: url)
        }
        let manifest = try JSONDecoder().decode(DiagnosticExportManifest.self, from: read("manifest.json", limit: 32_768))
        guard manifest.schemaVersion == 1, Set(manifest.files.keys) == ["diagnostic.json", "content-manifest.json", "README.txt"] else {
            throw DiagnosticError.invalid("내보내기 목록이 없거나 잘못되었습니다.")
        }
        var files: [String: Data] = [:]
        for (name, hash) in manifest.files {
            let data = try read(name, limit: name == "diagnostic.json" ? 8 * 1024 * 1024 : 4 * 1024 * 1024)
            guard DiagnosticCodec.hash(data) == hash else { throw DiagnosticError.invalid("\(name)이 변경되거나 잘렸습니다.") }
            files[name] = data
        }
        let bundle = try JSONDecoder().decode(DiagnosticBundle.self, from: files["diagnostic.json"]!)
        let content = try JSONDecoder().decode(ContentManifest.self, from: files["content-manifest.json"]!)
        guard bundle.runID == manifest.runID, bundle.contentRevision == content.contentRevision else {
            throw DiagnosticError.invalid("진단 묶음의 식별 정보 불일치")
        }
        return bundle
    }
}
