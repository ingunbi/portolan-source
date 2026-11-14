import XCTest
@testable import PortolanCore

final class SaveRecoveryTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    static var cachedWorld: World?
    var world: World!
    var dir: URL!

    override func setUpWithError() throws {
        if Self.cachedWorld == nil { Self.cachedWorld = try World(assets: WorldTests.assets) }
        world = Self.cachedWorld
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("portolan-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SaveGame.override = dir
        SaveGame.failureInjector = nil
    }
    override func tearDown() {
        SaveGame.failureInjector = nil
        SaveGame.override = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }
    func voyage(_ gold: Int = 1234) -> Voyage {
        var v = Voyage.joanAfterPrologue(in: world)
        v.gold = gold
        v.saveContext.contentRevision = world.contentRevision
        return v
    }
    func legacyData(_ v: Voyage) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as? [String: Any])
        func strip(_ ship: [String: Any]) -> [String: Any] {
            var s = ship; s.removeValue(forKey: "shipInstanceID"); return s
        }
        root["ships"] = (root["ships"] as? [[String: Any]])?.map(strip)
        for key in ["dock", "orders"] {
            root[key] = (root[key] as? [[String: Any]])?.map { value -> [String: Any] in
                var item = value
                if let s = item["ship"] as? [String: Any] { item["ship"] = strip(s) }
                return item
            }
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
    func mutateCurrent(_ body: (inout [String: Any]) -> Void) throws {
        let path = SaveGame.url(0)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        body(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: path)
    }

    func testLegacyConversionPreservesCoreStateAndDoesNotWriteOnRead() throws {
        var v = voyage()
        v.memory[0xC3B] = 0x82
        v.memory[DS.currentPort] = 0
        let data = try legacyData(v)
        let file = SaveGame.url(0)
        try data.write(to: file)
        let migrated = try SaveGame.read(from: file)
        XCTAssertEqual(migrated.saveContext.rules, .original)
        XCTAssertEqual(migrated.memory.bytes, v.memory.bytes)
        XCTAssertEqual(migrated.rng.seed, v.rng.seed)
        XCTAssertEqual(migrated.ships[0].holds, v.ships[0].holds)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(SaveGame.header(0)?.port, "리스본")
        let id = migrated.ships[0].shipInstanceID
        try SaveGame.write(migrated, slot: 0, port: "리스본")
        let restored = try SaveGame.read(from: file)
        XCTAssertEqual(restored.ships[0].shipInstanceID, id)
        XCTAssertEqual(restored.saveContext.saveID, migrated.saveContext.saveID)
        XCTAssertEqual(restored.saveContext.generation, 1)
        XCTAssertEqual(restored.memory.bytes, v.memory.bytes)
        XCTAssertTrue(SaveGame.inspect(0).backupHeader != nil)
        let archived = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains(".legacy-") })
        XCTAssertEqual(try Data(contentsOf: archived), data)
    }

    func testBodySummarySurvivesMissingOrStaleHeader() throws {
        try SaveGame.write(voyage(), slot: 0, port: "리스본")
        try FileManager.default.removeItem(at: SaveGame.headerURL(0))
        XCTAssertEqual(SaveGame.header(0)?.port, "리스본")
        let stale = SaveGame.Header(date: "old", port: "잘못된 항구", type: 3)
        try JSONEncoder().encode(stale).write(to: SaveGame.headerURL(0))
        XCTAssertEqual(SaveGame.header(0)?.port, "리스본")
        XCTAssertTrue(SaveGame.inspect(0).canLoad)
    }

    func testUnreadableHeaderCacheDoesNotFailSuccessfulSave() throws {
        try FileManager.default.createDirectory(at: SaveGame.headerURL(0), withIntermediateDirectories: true)
        try SaveGame.write(voyage(), slot: 0, port: "리스본")
        XCTAssertEqual(try SaveGame.read(slot: 0).gold, 1234)
        XCTAssertEqual(SaveGame.header(0)?.port, "리스본")
    }

    func testCorruptCurrentRequiresExplicitRecoveryAndKeepsBackup() throws {
        var v = voyage(1000)
        try SaveGame.write(v, slot: 0, port: "리스본")
        v.gold = 2000
        try SaveGame.write(v, slot: 0, port: "세빌리아")
        let backupBytes = try Data(contentsOf: SaveGame.backupURL(SaveGame.url(0)))
        try Data("{broken".utf8).write(to: SaveGame.url(0))
        let info = SaveGame.inspect(0)
        XCTAssertFalse(info.canLoad)
        XCTAssertNotNil(info.problem)
        XCTAssertEqual(info.backupHeader?.port, "리스본")
        XCTAssertThrowsError(try SaveGame.read(slot: 0))
        XCTAssertEqual(try SaveGame.read(slot: 0, recovery: true).gold, 1000)
        v.gold = 3000
        try SaveGame.write(v, slot: 0, port: "리스본")
        XCTAssertEqual(try Data(contentsOf: SaveGame.backupURL(SaveGame.url(0))), backupBytes)
        XCTAssertEqual(try SaveGame.read(slot: 0).gold, 3000)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains(".damaged-") })
    }

    func testEveryInterruptedWriteRetainsAtLeastOneNormalGeneration() throws {
        for stage in SaveGame.WriteStage.allCases {
            let sub = dir.appendingPathComponent("\(stage)")
            SaveGame.override = sub
            var v = voyage(1000)
            try SaveGame.write(v, slot: 0, port: "리스본")
            v.gold = 2000
            SaveGame.failureInjector = { if $0 == stage { throw CocoaError(.fileWriteUnknown) } }
            XCTAssertThrowsError(try SaveGame.write(v, slot: 0, port: "세빌리아"))
            SaveGame.failureInjector = nil
            let loaded = try SaveGame.read(slot: 0)
            XCTAssertTrue([1000, 2000].contains(loaded.gold))
            if stage != .staged {
                XCTAssertEqual(try SaveGame.read(slot: 0, recovery: true).gold, 1000)
                XCTAssertEqual(SaveGame.inspect(0).backupHeader?.port, "리스본")
            }
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: sub.path).contains { $0.hasSuffix(".pending") })
        }
    }

    func testUnknownVersionAndExpansionAreRefusedWithoutMutation() throws {
        let v = voyage()
        try SaveGame.write(v, slot: 0, port: nil)
        try mutateCurrent { $0["schemaVersion"] = 99 }
        let bytes = try Data(contentsOf: SaveGame.url(0))
        XCTAssertThrowsError(try SaveGame.read(slot: 0)) { XCTAssertEqual($0 as? SaveFailure, .unsupportedVersion(99)) }
        XCTAssertThrowsError(try SaveGame.write(v, slot: 0, port: nil))
        XCTAssertEqual(try Data(contentsOf: SaveGame.url(0)), bytes)
        try FileManager.default.removeItem(at: SaveGame.url(0))
        try SaveGame.write(v, slot: 0, port: nil)
        try mutateCurrent { $0["extensionState"] = ["future": ["version": 1, "state": ["money": 5]]] }
        let extensionBytes = try Data(contentsOf: SaveGame.url(0))
        XCTAssertThrowsError(try SaveGame.read(slot: 0)) { XCTAssertEqual($0 as? SaveFailure, .unsupportedExtension("future")) }
        XCTAssertThrowsError(try SaveGame.write(v, slot: 0, port: nil))
        XCTAssertEqual(try Data(contentsOf: SaveGame.url(0)), extensionBytes)
    }

    func testMissingCurrentStillOffersSlotBackupAlongsideLegacyFile() throws {
        try legacyData(voyage(50)).write(to: SaveGame.defaultURL)
        try SaveGame.write(voyage(100), slot: 0, port: "리스본")
        try SaveGame.write(voyage(200), slot: 0, port: "세빌리아")
        try FileManager.default.removeItem(at: SaveGame.url(0))
        XCTAssertEqual(try SaveGame.read(slot: 0).gold, 50)
        XCTAssertEqual(SaveGame.inspect(0).backupHeader?.port, "리스본")
        XCTAssertEqual(try SaveGame.read(slot: 0, recovery: true).gold, 100)
    }

    func testUnknownRulesNeverReplaceCurrentOrBackup() throws {
        for (key, value) in [("rulesRevision", 99 as Any), ("mode", "future" as Any), ("enabledFeatures", ["future"] as Any)] {
            SaveGame.override = dir.appendingPathComponent(key)
            try SaveGame.write(voyage(100), slot: 0, port: nil)
            try SaveGame.write(voyage(200), slot: 0, port: nil)
            try mutateCurrent { root in
                var rules = root["rules"] as! [String: Any]
                rules[key] = value
                root["rules"] = rules
            }
            let current = try Data(contentsOf: SaveGame.url(0))
            let backup = try Data(contentsOf: SaveGame.backupURL(SaveGame.url(0)))
            XCTAssertThrowsError(try SaveGame.write(voyage(300), slot: 0, port: nil))
            XCTAssertEqual(try Data(contentsOf: SaveGame.url(0)), current)
            XCTAssertEqual(try Data(contentsOf: SaveGame.backupURL(SaveGame.url(0))), backup)
        }
    }

    func testExistingUnreadablePathIsNotReplaced() throws {
        try FileManager.default.createDirectory(at: SaveGame.url(0), withIntermediateDirectories: true)
        let marker = SaveGame.url(0).appendingPathComponent("preserve")
        try Data("existing".utf8).write(to: marker)
        XCTAssertThrowsError(try SaveGame.write(voyage(), slot: 0, port: nil))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "existing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: SaveGame.backupURL(SaveGame.url(0)).path))
    }

    func testMalformedStateAndMissingIdentityAreRefusedBeforeGameAccess() throws {
        for key in ["memory", "ships", "month", "fame"] {
            try SaveGame.write(voyage(), slot: 0, port: nil)
            try mutateCurrent { root in
                var v = root["voyage"] as! [String: Any]
                switch key {
                case "memory": v[key] = Data([0]).base64EncodedString()
                case "month": v[key] = 12
                case "fame": v[key] = []
                default:
                    var ships = v["ships"] as! [[String: Any]]
                    ships[0].removeValue(forKey: "shipInstanceID")
                    v["ships"] = ships
                }
                root["voyage"] = v
            }
            XCTAssertThrowsError(try SaveGame.read(slot: 0), key)
        }
    }

    func testBooleanSchemaAndGenerationOverflowAreRejected() throws {
        try SaveGame.write(voyage(), slot: 0, port: nil)
        try mutateCurrent { $0["schemaVersion"] = true }
        XCTAssertThrowsError(try SaveGame.read(slot: 0))
        try SaveGame.write(voyage(), slot: 0, port: nil)
        try mutateCurrent { $0["generation"] = Int.max }
        XCTAssertThrowsError(try SaveGame.read(slot: 0))
        var v = voyage()
        v.saveContext.generation = Int.max
        XCTAssertThrowsError(try SaveGame.write(v, slot: 1, port: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SaveGame.url(1).path))
    }

    func testInvalidWeatherAndMarketAreRejectedBeforeSimulation() throws {
        for field in ["marketIndex", "windDir", "currentDir", "windStrength", "currentStrength", "windFlags"] {
            try SaveGame.write(voyage(), slot: 0, port: nil)
            try mutateCurrent { root in
                var v = root["voyage"] as! [String: Any]
                if field == "marketIndex" { v[field] = 100 }
                else {
                    var weather = v["weather"] as! [String: Any]
                    weather[field] = 8
                    v["weather"] = weather
                }
                root["voyage"] = v
            }
            XCTAssertFalse(SaveGame.inspect(0).canLoad, field)
            XCTAssertThrowsError(try SaveGame.read(slot: 0), field)
        }
    }

    func testEmptySlotDoesNotFallBackToLegacySlotZero() throws {
        try legacyData(voyage()).write(to: SaveGame.defaultURL)
        XCTAssertTrue(SaveGame.inspect(0).canLoad)
        XCTAssertFalse(SaveGame.inspect(4).canLoad)
        XCTAssertThrowsError(try SaveGame.read(slot: 4)) { XCTAssertEqual($0 as? SaveFailure, .missing) }
        XCTAssertThrowsError(try SaveGame.write(voyage(), slot: -1, port: nil))
    }

    func testVesselIdentitySurvivesRenameDockAndReorder() throws {
        var v = voyage()
        let first = v.ships[0].shipInstanceID
        v.ships[0].name = "새 이름"
        var second = Ship.built(class: 2, named: "부함", in: world.navigation)
        let secondID = second.shipInstanceID
        second.crew = 5
        v.dock.append(DockedShip(port: 0, ship: second))
        try SaveGame.write(v, slot: 0, port: "리스본")
        var restored = try SaveGame.read(slot: 0)
        XCTAssertEqual(restored.ships[0].shipInstanceID, first)
        XCTAssertEqual(restored.dock[0].ship.shipInstanceID, secondID)
        _ = restored.exchangeShip(0, with: 0, at: 0)
        XCTAssertEqual(restored.ships[0].shipInstanceID, secondID)
        XCTAssertEqual(restored.dock[0].ship.shipInstanceID, first)
        restored.ships.append(restored.ships[0])
        XCTAssertThrowsError(try SaveGame.write(restored, slot: 1, port: nil))
    }
}
