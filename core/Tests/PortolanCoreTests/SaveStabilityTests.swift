import XCTest
import CryptoKit
import Darwin
@testable @_spi(SaveProbe) import PortolanCore

/// Deterministic regression tests. Actual SIGKILL/ENOSPC evidence comes from
/// scripts/test_save_stability.py, not from these in-process checks.
final class SaveStabilityTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    var directory: URL!
    static var cachedWorld: World?
    var world: World!
    static let fixtures = WorldTests.assets.deletingLastPathComponent().appendingPathComponent("fixtures/saves")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("portolan-stability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SaveGame.override = directory
        SaveGame.failureInjector = nil
        SaveGame.checkpointObserver = nil
        if Self.cachedWorld == nil { Self.cachedWorld = try World(assets: WorldTests.assets) }
        world = Self.cachedWorld
    }

    override func tearDown() {
        SaveGame.override = nil
        SaveGame.failureInjector = nil
        SaveGame.checkpointObserver = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func voyage(_ gold: Int) -> Voyage {
        var v = Voyage.joanAfterPrologue(in: world)
        v.gold = gold
        v.saveContext.contentRevision = world.contentRevision
        return v
    }

    func encodedState(_ v: Voyage) throws -> Data {
        let encoded = try JSONEncoder().encode(v)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        // Set order is not gameplay state; all ordered arrays remain order-sensitive.
        object["developing"] = v.developing.sorted()
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func expectFailure(_ expected: SaveFailure, _ operation: () throws -> Void) {
        do { try operation(); XCTFail("expected \(expected)") }
        catch { XCTAssertEqual(error as? SaveFailure, expected) }
    }
    func expectSuccess(_ operation: () throws -> Void) {
        do { try operation() }
        catch { XCTFail("unexpected error: \(error)") }
    }

    func testActualLegacyFixtureMigratesAllCodableStateAndKeepsExactOriginal() throws {
        let source = Self.fixtures.appendingPathComponent("legacy-025.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "fixture not in the open-source tree")
        let bytes = try Data(contentsOf: source)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(root["schemaVersion"], "must be a fixed raw 0.2.5 file")
        let file = SaveGame.url(0)
        try bytes.write(to: file)
        let legacy = try SaveGame.read(from: file)
        XCTAssertEqual(legacy.saveContext.rules, .original)
        XCTAssertEqual(legacy.gold, root["gold"] as? Int)
        let state = try encodedState(legacy)
        try SaveGame.write(legacy, slot: 0, port: nil)
        let loaded = try SaveGame.read(from: file)
        XCTAssertEqual(try encodedState(loaded), state, "all stored Voyage fields, including RNG and DS memory")
        XCTAssertEqual(loaded.saveContext.saveID, legacy.saveContext.saveID)
        XCTAssertEqual(loaded.saveContext.generation, 1)
        try SaveGame.write(loaded, slot: 0, port: nil)
        XCTAssertEqual(try encodedState(SaveGame.read(from: file)), state)
        let archives = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".legacy-") }
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archives.first)), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testEveryOccupiedOriginalDATSlotSurvivesEnvelopeRoundTrip() throws {
        let source = Self.fixtures.appendingPathComponent("original-KOUKAI2.DAT")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "needs a save file from your own copy of the original game")
        let bytes = try Data(contentsOf: source)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "d25af7b2949af28206dfce7ebd63da59d803dfcb602724719b35854b50c8a45b")
        let dos = try XCTUnwrap(DOSSave(url: source))
        var occupied = 0
        for slot in 0..<DOSSave.slots {
            guard let header = dos.header(slot) else { continue }
            let v = try XCTUnwrap(dos.voyage(slot: slot, in: world))
            occupied += 1
            XCTAssertEqual(SaveGame.dateText(v), header.date)
            try SaveGame.write(v, slot: slot, port: header.port.map { world.ports[$0].name }, ending: header.type != 0)
            let restored = try SaveGame.read(from: SaveGame.url(slot))
            XCTAssertEqual(try encodedState(restored), try encodedState(v), "original slot \(slot)")
            XCTAssertTrue(SaveGame.inspect(slot).canLoad)
        }
        XCTAssertEqual(occupied, 7)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testSameDestinationIsBusyButOtherSlotCanSaveAndLockRemainsReusable() throws {
        try SaveGame.write(voyage(100), slot: 0, port: nil)
        let before = try Data(contentsOf: SaveGame.url(0))
        var checked = false
        SaveGame.checkpointObserver = { stage in
            guard stage == .staged, !checked else { return }
            checked = true
            self.expectFailure(.busy) { try SaveGame.write(self.voyage(900), slot: 0, port: nil) }
            XCTAssertEqual(try? Data(contentsOf: SaveGame.url(0)), before)
            self.expectSuccess { try SaveGame.write(self.voyage(700), slot: 1, port: nil) }
        }
        try SaveGame.write(voyage(200), slot: 0, port: nil)
        SaveGame.checkpointObserver = nil
        XCTAssertTrue(checked)
        XCTAssertEqual(try SaveGame.read(slot: 0).gold, 200)
        XCTAssertEqual(try SaveGame.read(slot: 1).gold, 700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SaveGame.url(0).appendingPathExtension("lock").path))
        try SaveGame.write(voyage(300), slot: 0, port: nil)
    }

    func testParentSymlinkAliasUsesSameLockAndDestinationSymlinkIsRefused() throws {
        try SaveGame.write(voyage(100), slot: 0, port: nil)
        let alias = directory.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        var checked = false
        SaveGame.checkpointObserver = { stage in
            guard stage == .staged, !checked else { return }
            checked = true
            self.expectFailure(.busy) { try SaveGame.write(self.voyage(800), to: alias.appendingPathComponent("slot0.json")) }
        }
        try SaveGame.write(voyage(200), slot: 0, port: nil)
        SaveGame.checkpointObserver = nil
        XCTAssertTrue(checked)
        let linked = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: SaveGame.url(0))
        let before = try Data(contentsOf: SaveGame.url(0))
        XCTAssertThrowsError(try SaveGame.write(voyage(900), to: linked)) {
            guard let failure = $0 as? SaveFailure, case .cannotWrite = failure else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: SaveGame.url(0)), before)
    }

    func testHeaderCacheIsInsideExclusiveBoundaryAndPendingJunkIsNeverLoaded() throws {
        var stages: [SaveCheckpoint] = []
        SaveGame.checkpointObserver = { stage in
            stages.append(stage)
            if stage == .headerCached {
                XCTAssertNotNil(SaveGame.header(0))
                self.expectFailure(.busy) { try SaveGame.write(self.voyage(900), slot: 0, port: nil) }
            }
        }
        try SaveGame.write(voyage(100), slot: 0, port: nil)
        SaveGame.checkpointObserver = nil
        XCTAssertEqual(stages, [.lockAcquired, .staged, .backupVerified, .committed, .headerCached])
        try Data("broken unfinished save".utf8).write(to: directory.appendingPathComponent(".slot0.json.old.pending"))
        XCTAssertTrue(SaveGame.inspect(0).canLoad)
        XCTAssertEqual(try SaveGame.read(slot: 0).gold, 100)
    }

    func testRequireEmptyProtectsCurrentBackupAndBothLegacyPaths() throws {
        let v = voyage(200)
        let occupied = ["slot0.json", "slot0.json.backup", "save.json", "save.json.backup"]
        for name in occupied {
            let file = directory.appendingPathComponent(name)
            let bytes = Data("existing file must be preserved even if corrupt".utf8)
            try bytes.write(to: file)
            XCTAssertThrowsError(try SaveGame.write(v, slot: 0, port: nil, requireEmpty: true)) {
                XCTAssertEqual($0 as? SaveFailure, .slotOccupied, name)
            }
            XCTAssertEqual(try Data(contentsOf: file), bytes, name)
            try FileManager.default.removeItem(at: file)
        }
        // A header cache alone is not recoverable gameplay state and may be replaced.
        try Data("stale cache".utf8).write(to: SaveGame.headerURL(0))
        try SaveGame.write(v, slot: 0, port: nil, requireEmpty: true)
        XCTAssertEqual(try SaveGame.read(slot: 0).gold, 200)
        let before = try Data(contentsOf: SaveGame.url(0))
        XCTAssertThrowsError(try SaveGame.write(voyage(300), slot: 0, port: nil, requireEmpty: true)) {
            XCTAssertEqual($0 as? SaveFailure, .slotOccupied)
        }
        XCTAssertEqual(try Data(contentsOf: SaveGame.url(0)), before)
    }

    func testRequireEmptyRechecksAfterLockAndLegacyAliasSharesSlotZeroLock() throws {
        let bytes = Data("file appeared after the empty-slot preview".utf8)
        SaveGame.checkpointObserver = { stage in
            guard stage == .lockAcquired else { return }
            self.expectFailure(.busy) { try SaveGame.write(self.voyage(800), to: SaveGame.defaultURL) }
            self.expectSuccess { try bytes.write(to: SaveGame.url(0)) }
        }
        XCTAssertThrowsError(try SaveGame.write(voyage(300), slot: 0, port: nil, requireEmpty: true)) {
            XCTAssertEqual($0 as? SaveFailure, .slotOccupied)
        }
        SaveGame.checkpointObserver = nil
        XCTAssertEqual(try Data(contentsOf: SaveGame.url(0)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SaveGame.backupURL(SaveGame.url(0)).path))
    }

}
