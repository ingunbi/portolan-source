import Foundation
import XCTest
@testable import PortolanCore

final class ContentValidationTests: XCTestCase {
    override func setUp() async throws { try WorldTests.skipUnlessAssets() }
    // Resolved first: a copy of a symlinked assets/ must be a copy of the folder, never of the link (the tests damage their copies).
    private var source: URL { WorldTests.assets.resolvingSymlinksInPath() }

    private func withAssets(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PortolanContentValidation-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func changeJSON(_ path: String, at root: URL, _ edit: (inout [String: Any]) -> Void) throws {
        let url = root.appendingPathComponent(path)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&object)
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: url, options: .atomic)
    }

    private func report(_ root: URL) -> ContentValidationReport {
        ContentValidation.validate(assets: root, scope: .runtime)
    }

    func testRealAssetsPassFullValidationAndKeepScenarioIndices() throws {
        let full = ContentValidation.validate(assets: source)
        XCTAssertTrue(full.isValid, full.errors.map(\.description).joined(separator: "\n"))
        XCTAssertEqual(full.contentRevision.count, 64)
        XCTAssertFalse(full.manifest.entries.isEmpty)
        XCTAssertEqual(Set(full.manifest.entries.map(\.path)).count, full.manifest.entries.count)
        let world = try World(assets: source)
        XCTAssertEqual(world.contentRevision, full.contentRevision, "Runtime/full must fingerprint identical registered content.")
        XCTAssertEqual(world.scripts.count, 7)
        for n in 0..<7 {
            let expected = try Data(contentsOf: source.appendingPathComponent("scenario/SNR\(n).DAT"))
            XCTAssertEqual(world.scripts[n].bytes, [UInt8](expected))
        }
    }

    func testMissingMiddleScenarioFailsInsteadOfShiftingHeroIndices() throws {
        try withAssets { root in
            try FileManager.default.removeItem(at: root.appendingPathComponent("scenario/SNR3.DAT"))
            let result = report(root)
            XCTAssertTrue(result.errors.contains { $0.path == "scenario/SNR3.DAT" && $0.code == "missing_file" && $0.logicalID == "SNR3" })
            XCTAssertThrowsError(try World(assets: root)) { error in
                XCTAssertTrue(error is ContentValidationError)
                XCTAssertTrue(error.localizedDescription.contains("SNR3"))
            }
        }
    }

    func testWrongMaskSizeThrowsBeforeWorldPrecondition() throws {
        try withAssets { root in
            try Data([0, 1, 2]).write(to: root.appendingPathComponent("world_mask.bin"), options: .atomic)
            XCTAssertThrowsError(try World(assets: root)) { error in
                let failure = error as? ContentValidationError
                XCTAssertTrue(failure?.issues.contains { $0.path == "world_mask.bin" && $0.code == "invalid_size" } == true)
                XCTAssertNotNil(failure?.recoverySuggestion)
            }
        }
    }

    func testMalformedNavigationJSONAndShortDSHaveSpecificDiagnostics() throws {
        try withAssets { root in
            try Data("{ broken".utf8).write(to: root.appendingPathComponent("navigation.json"), options: .atomic)
            try Data([0]).write(to: root.appendingPathComponent("ds.bin"), options: .atomic)
            let result = report(root)
            XCTAssertTrue(result.errors.contains { $0.path == "navigation.json" && $0.code == "invalid_json" })
            XCTAssertTrue(result.errors.contains { $0.path == "ds.bin" && $0.code == "invalid_size" })
            XCTAssertThrowsError(try result.requireValid())
        }
    }

    func testMissingPortraitAndReferencedFacePartAreRequired() throws {
        try withAssets { root in
            try FileManager.default.removeItem(at: root.appendingPathComponent("portraits/000.png"))
            try changeJSON("faces/faces.json", at: root) { object in
                var sets = object["sets"] as! [[String: Any]]
                var parts = sets[0]["parts"] as! [String: [String]]
                parts["top"]![0] = "does-not-exist.png"
                sets[0]["parts"] = parts
                object["sets"] = sets
            }
            let result = report(root)
            XCTAssertTrue(result.errors.contains { $0.path == "portraits/000.png" && $0.code == "missing_file" })
            XCTAssertTrue(result.errors.contains { $0.path == "faces/does-not-exist.png" && $0.code == "missing_file" })
        }
    }

    func testBrokenPictureHeaderFailsRuntimeValidation() throws {
        try withAssets { root in
            try Data(repeating: 0, count: 32).write(to: root.appendingPathComponent("portraits/002.png"), options: .atomic)
            XCTAssertTrue(report(root).errors.contains { $0.path == "portraits/002.png" && $0.code == "invalid_image" })
        }
    }

    func testDuelStripMetadataMustMatchItsFramesAndImageSize() throws {
        try withAssets { root in
            try changeJSON("sprites/duel/index.json", at: root) { object in
                var files = object["files"] as! [[String: Any]]
                files[0]["frames"] = 5 // Original rects/image contain six frames.
                object["files"] = files
            }
            XCTAssertTrue(report(root).errors.contains { $0.path == "sprites/duel/index.json" && $0.logicalID == "files[0]" })
        }
    }

    func testNewReplacementCharactersAreNotCoveredByOriginalItemAllowlist() throws {
        try withAssets { root in
            try changeJSON("text.json", at: root) { object in
                var items = object["items"] as! [String]
                items[103] += "�"
                items[0] = "새 손상 �"
                object["items"] = items
            }
            let result = report(root)
            XCTAssertTrue(result.errors.contains { $0.logicalID == "items[103]" && $0.code == "invalid_text" })
            XCTAssertTrue(result.errors.contains { $0.logicalID == "items[0]" && $0.code == "invalid_text" })
            XCTAssertFalse(result.warnings.contains { $0.logicalID == "items[103]" })
        }
    }

    func testTownWalkTableAndPortIDsAreValidatedBeforeUnsafeIndexing() throws {
        try withAssets { root in
            try changeJSON("portmaps/portmaps.json", at: root) { object in
                var walk = object["walk"] as! [[Int]]
                walk[0] = [0]
                object["walk"] = walk
            }
            try changeJSON("ports.json", at: root) { object in
                var ports = object["ports"] as! [[String: Any]]
                ports[1]["id"] = 0
                object["ports"] = ports
            }
            let result = report(root)
            XCTAssertTrue(result.errors.contains { $0.path == "portmaps/portmaps.json" })
            XCTAssertTrue(result.errors.contains { $0.path == "ports.json" && $0.logicalID == "ports[1].id" })
            XCTAssertThrowsError(try World(assets: root))
        }
    }

    func testMissingScenarioTextReferenceHasExactLineID() throws {
        try withAssets { root in
            // One valid chapter/block/trigger containing SAY #65535 then END.
            var bytes = Array("SNDT".utf8) + [UInt8](repeating: 0, count: 12)
            bytes += [0, 0, 0, 24, 255, 255, 255, 255]
            bytes += [0, 4, 255, 255]
            bytes += [0, 0, 0, 8, 255, 255, 255, 255]
            bytes += [0xC8, 255, 255, 0xF2]
            try Data(bytes).write(to: root.appendingPathComponent("scenario/SNR1.DAT"), options: .atomic)
            let result = report(root)
            XCTAssertTrue(result.errors.contains { $0.path == "text.json" && $0.logicalID.contains("scenario1[65535]") })
        }
    }

    func testTruncatedScenarioAndBadRouteReferenceDoNotCrashValidator() throws {
        try withAssets { root in
            try Data("SNDT".utf8).write(to: root.appendingPathComponent("scenario/SNR2.DAT"), options: .atomic)
            var route = try Data(contentsOf: root.appendingPathComponent("routes.bin"))
            route[4] = 0xFE; route[5] = 0x7F
            try route.write(to: root.appendingPathComponent("routes.bin"), options: .atomic)
            let result = report(root)
            XCTAssertTrue(result.errors.contains { $0.path == "scenario/SNR2.DAT" && $0.code == "invalid_scenario" })
            XCTAssertTrue(result.errors.contains { $0.path == "routes.bin" && $0.logicalID == "node[0].next[0]" })
        }
    }

    func testMissingOptionalAudioWarnsWithoutBlockingWorld() throws {
        try withAssets { root in
            try FileManager.default.removeItem(at: root.appendingPathComponent("music/song01.m4a"))
            let result = report(root)
            XCTAssertTrue(result.isValid, result.errors.map(\.description).joined(separator: "\n"))
            XCTAssertTrue(result.warnings.contains { $0.path == "music/song01.m4a" && $0.code == "missing_file" })
            XCTAssertNoThrow(try result.requireValid())
        }
    }

    func testManifestRevisionIsIndependentOfLocationAndFileDates() throws {
        let original = report(source)
        try withAssets { root in
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1234)],
                                                 ofItemAtPath: root.appendingPathComponent("text.json").path)
            let copied = report(root)
            XCTAssertEqual(copied.manifest, original.manifest)
            var text = try Data(contentsOf: root.appendingPathComponent("text.json"))
            text.append(contentsOf: [10, 32])
            try text.write(to: root.appendingPathComponent("text.json"), options: .atomic)
            let changed = report(root)
            XCTAssertTrue(changed.isValid, changed.errors.map(\.description).joined(separator: "\n"))
            XCTAssertNotEqual(changed.contentRevision, original.contentRevision, "Revision uses bytes, not just parse results or dates.")
        }
    }
}
