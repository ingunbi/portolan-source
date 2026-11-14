import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

/// Observable boundaries for a separate-process crash probe; not a gameplay API.
@_spi(SaveProbe) public enum SaveCheckpoint: String, CaseIterable {
    case lockAcquired, staged, backupVerified, committed, headerCached
}

/// Versioned saves with a self-contained summary and one verified recovery generation.
public enum SaveGame {
    public static let slots = 10

    public struct Header: Codable, Equatable {
        public let date: String
        public let port: String?
        public let type: Int
        public init(date: String, port: String?, type: Int) {
            self.date = date; self.port = port; self.type = type
        }
    }

    public struct SlotInfo {
        public let header: Header?
        public let hasCurrent: Bool
        public let canLoad: Bool
        public let problem: String?
        public let backupHeader: Header?
    }

    public static var override: URL?
    public static var directory: URL {
        if let o = override { return o }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Portolan", isDirectory: true)
    }
    public static var defaultURL: URL { directory.appendingPathComponent("save.json") }
    static func url(_ slot: Int) -> URL { directory.appendingPathComponent("slot\(slot).json") }
    static func headerURL(_ slot: Int) -> URL { directory.appendingPathComponent("slot\(slot).header.json") }
    static func backupURL(_ file: URL) -> URL { file.appendingPathExtension("backup") }

    /// Test-only failure points, after each durable boundary. Never used by gameplay.
    enum WriteStage: CaseIterable { case staged, backupVerified, committed }
    static var failureInjector: ((WriteStage) throws -> Void)?
    @_spi(SaveProbe) public static var checkpointObserver: ((SaveCheckpoint) -> Void)?

    public static func dateText(_ v: Voyage) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return String(format: "%2d/%@/15%02d", v.dayOfMonth + 1, months[v.month], v.year % 100)
    }
    public static func type(of v: Voyage, ending: Bool) -> Int {
        guard ending else { return 0 }
        let c = v.memory[0xC30]
        return c & 0x40 == 0 ? 2 : c & 0x02 == 0 ? 3 : 2
    }
    private static func checkSlot(_ slot: Int) throws {
        guard (0..<slots).contains(slot) else { throw SaveFailure.invalidSlot }
    }
    private static func currentURL(_ slot: Int) -> URL {
        let file = url(slot)
        if slot == 0 && !FileManager.default.fileExists(atPath: file.path)
            && FileManager.default.fileExists(atPath: defaultURL.path) { return defaultURL }
        return file
    }
    private static func recoveryURL(_ slot: Int) -> URL {
        let backup = backupURL(url(slot))
        if FileManager.default.fileExists(atPath: backup.path) { return backup }
        return backupURL(currentURL(slot))
    }
    private static func readData(_ file: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: file.path) else { throw SaveFailure.missing }
        do { return try Data(contentsOf: file) }
        catch { throw SaveFailure.cannotRead(error.localizedDescription) }
    }
    private static func cachedHeader(_ slot: Int) -> Header? {
        guard let data = try? Data(contentsOf: headerURL(slot)),
              let h = try? JSONDecoder().decode(Header.self, from: data), [0, 2, 3].contains(h.type) else { return nil }
        return h
    }
    private static func inferredHeader(_ v: Voyage) -> Header {
        let p = v.memory[DS.currentPort]
        // Raw 0.2.5 files did not contain a summary. Read the original DS port name,
        // only when it is consistent with the harbor marker written by Game.save.
        let inPort = v.memory[0xC3B] == 0x82 && (0..<130).contains(p)
        let name = inPort ? v.memory.string(DS.port + DS.portSize * p + 4, max: 14) : ""
        return Header(date: dateText(v), port: name.isEmpty ? nil : name, type: type(of: v, ending: false))
    }
    private static func decoded(_ file: URL, slot: Int? = nil) throws -> SaveCodec.Decoded {
        var d = try SaveCodec.decode(readData(file))
        if d.header == nil {
            let h = slot.flatMap { cachedHeader($0) }
            d.header = h?.date == dateText(d.voyage) ? h : inferredHeader(d.voyage)
        }
        return d
    }
    public static func inspect(_ slot: Int) -> SlotInfo {
        guard (0..<slots).contains(slot) else {
            return SlotInfo(header: nil, hasCurrent: false, canLoad: false, problem: SaveFailure.invalidSlot.localizedDescription, backupHeader: nil)
        }
        let file = currentURL(slot)
        let exists = FileManager.default.fileExists(atPath: file.path)
        let backup = try? decoded(recoveryURL(slot))
        do {
            let d = try decoded(file, slot: slot)
            return SlotInfo(header: d.header, hasCurrent: true, canLoad: true, problem: nil, backupHeader: backup?.header)
        } catch {
            return SlotInfo(header: nil, hasCurrent: exists, canLoad: false,
                            problem: exists ? error.localizedDescription : nil, backupHeader: backup?.header)
        }
    }
    public static func header(_ slot: Int) -> Header? { inspect(slot).header }

    public static func read(slot: Int, recovery: Bool = false) throws -> Voyage {
        try checkSlot(slot)
        let file = currentURL(slot)
        var v = try decoded(recovery ? recoveryURL(slot) : file, slot: recovery ? nil : slot).voyage
        v.afterLoad()
        return v
    }
    public static func read(from file: URL = defaultURL) throws -> Voyage {
        try decoded(file).voyage
    }
    public static func write(_ v: Voyage, slot: Int, port: String?, ending: Bool = false, requireEmpty: Bool = false) throws {
        try checkSlot(slot)
        try SaveCodec.validate(v)
        let h = Header(date: dateText(v), port: port, type: type(of: v, ending: ending))
        let occupied = requireEmpty ? [url(slot), backupURL(url(slot))]
            + (slot == 0 ? [defaultURL, backupURL(defaultURL)] : []) : []
        try writeVerified(v, summary: h, to: url(slot), legacyHeader: cachedHeader(slot),
                          cache: headerURL(slot), mustBeAbsent: occupied)
    }
    public static func write(_ v: Voyage, to file: URL = defaultURL) throws {
        try SaveCodec.validate(v)
        try writeVerified(v, summary: inferredHeader(v), to: file, legacyHeader: nil)
    }

    private static func acquireWriteLock(_ file: URL) throws -> Int32 {
        // Never unlink this file: a second inode at the same path would permit two writers.
        let lock = file.appendingPathExtension("lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw SaveFailure.cannotWrite(String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { throw SaveFailure.busy }
            throw SaveFailure.cannotWrite(String(cString: strerror(code)))
        }
        return fd
    }

    private static func writeVerified(_ v: Voyage, summary: Header, to requested: URL,
                                      legacyHeader: Header?, cache: URL? = nil, mustBeAbsent: [URL] = []) throws {
        // Resolve parent aliases so two spellings of one slot use the same lock inode.
        let parent = requested.deletingLastPathComponent().resolvingSymlinksInPath()
        let file = parent.appendingPathComponent(requested.lastPathComponent)
        let staged = parent.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).pending")
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            // save.json is the legacy alias of slot zero. Its direct-write API must
            // participate in the same lock as a new empty-slot copy to slot0.json.
            let legacyAlias = parent.path == directory.resolvingSymlinksInPath().path
                && file.lastPathComponent.caseInsensitiveCompare("save.json") == .orderedSame
            let fd = try acquireWriteLock(legacyAlias ? parent.appendingPathComponent("slot0.json") : file)
            defer { _ = flock(fd, LOCK_UN); close(fd) }
            checkpointObserver?(.lockAcquired)
            // The UI's empty-slot preview is advisory: this check is authoritative and
            // runs while the slot lock is held, before creating a stage or backup.
            for candidate in mustBeAbsent {
                var info = stat()
                if lstat(candidate.path, &info) == 0 { throw SaveFailure.slotOccupied }
                let code = errno
                if code != ENOENT { throw SaveFailure.cannotRead(String(cString: strerror(code))) }
            }
            // A destination symlink would read another file but replace the link on commit.
            // Refuse it, including dangling links, instead of silently changing its meaning.
            if (try? FileManager.default.attributesOfItem(atPath: file.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                throw SaveFailure.cannotWrite("기호 링크인 저장 경로에는 쓸 수 없습니다.")
            }
            // Read the previous generation only after acquiring the inter-process lock.
            let oldData = FileManager.default.fileExists(atPath: file.path) ? try readData(file) : nil
            var old: SaveCodec.Decoded?
            if let oldData {
                do { old = try SaveCodec.decode(oldData) }
                catch SaveFailure.corrupt { /* Preserve damaged bytes before replacement. */ }
                catch { throw error } // Future formats and unreadable files remain untouched.
            }
            let previous = old?.voyage.saveContext
            let baseGeneration = previous?.saveID == v.saveContext.saveID
                ? max(previous?.generation ?? 0, v.saveContext.generation) : max(0, v.saveContext.generation)
            guard baseGeneration >= 0 && baseGeneration < Int.max - 1 else { throw SaveFailure.corrupt("저장 세대가 너무 큽니다.") }
            let data = try SaveCodec.encode(SaveEnvelope(voyage: v, summary: summary, generation: baseGeneration + 1))
            defer { try? FileManager.default.removeItem(at: staged) }
            try data.write(to: staged, options: .atomic)
            _ = try SaveCodec.decode(Data(contentsOf: staged))
            checkpointObserver?(.staged)
            try failureInjector?(.staged)
            if let old, let oldData {
                let preserved: Data
                if old.legacy {
                    let archive = file.appendingPathExtension("legacy-\(UUID().uuidString)")
                    try oldData.write(to: archive, options: .atomic)
                    guard try Data(contentsOf: archive) == oldData else {
                        throw SaveFailure.cannotWrite("구버전 원본 사본 검증에 실패했습니다.")
                    }
                    let h = legacyHeader?.date == dateText(old.voyage) ? legacyHeader! : inferredHeader(old.voyage)
                    preserved = try SaveCodec.encode(SaveEnvelope(voyage: old.voyage, summary: h, generation: 1))
                } else { preserved = oldData }
                try preserved.write(to: backupURL(file), options: .atomic)
                _ = try SaveCodec.decode(Data(contentsOf: backupURL(file)))
            } else if let oldData {
                let damaged = file.appendingPathExtension("damaged-\(UUID().uuidString)")
                try oldData.write(to: damaged, options: .atomic)
            }
            checkpointObserver?(.backupVerified)
            try failureInjector?(.backupVerified)
            // Atomic sibling replacement protects complete generations from process death.
            // This is not an assertion of durability against sudden hardware power loss.
            try Data(contentsOf: staged).write(to: file, options: .atomic)
            _ = try SaveCodec.decode(Data(contentsOf: file))
            checkpointObserver?(.committed)
            try failureInjector?(.committed)
            if let cache, let bytes = try? JSONEncoder().encode(summary) {
                // Cache failure cannot hide a committed, self-contained save.
                try? bytes.write(to: cache, options: .atomic)
            }
            checkpointObserver?(.headerCached)
        } catch let e as SaveFailure { throw e }
        catch let e as RulesValidationError { throw e }
        catch { throw SaveFailure.cannotWrite(error.localizedDescription) }
    }

}

extension Voyage {
    /// The post-load fix-up (0x16588): with neither story bit the hero's script is over; with
    /// only the rank bit the shared script starts again; otherwise both bits are set.
    public mutating func afterLoad() {
        let c = memory[0xC30]
        if c & 0x42 == 0 {
            memory[ScriptContext.hero.base] = 0xFF
            memory[ScriptContext.hero.base + 1] = 0
            storyOn = false
        } else if c & 0x02 == 0 {
            memory[0xC30] = (c | 0x40) & ~0x02
            memory[0xCEA] = 0
            memory[0xCEB] = 0
        } else {
            memory[0xC30] = c | 0x42
        }
    }
}
