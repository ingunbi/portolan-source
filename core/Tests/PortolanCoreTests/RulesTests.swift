import XCTest
@testable import PortolanCore

final class RulesTests: XCTestCase {
    // Available fixtures exercise future policies without making planned campaign features usable.
    private var fixtureRegistry: [String: RulesFeature] {
        let features = [
            RulesFeature(id: "HELPER", title: "조작 보조", allowedModes: [.original, .expanded],
                         kind: .assistance, availability: .available, disablePolicy: .anytime),
            RulesFeature(id: "EXPANSION", title: "확장 사건", allowedModes: [.expanded],
                         kind: .expandedContent, availability: .available),
            RulesFeature(id: "BASE", title: "기반 기능", allowedModes: [.expanded],
                         kind: .expandedContent, availability: .available),
            RulesFeature(id: "DEPENDENT", title: "의존 기능", requiredFeatures: ["BASE"],
                         allowedModes: [.expanded], kind: .expandedContent, availability: .available),
            RulesFeature(id: "TRAINING", title: "독립 훈련", allowedModes: [],
                         kind: .standaloneTraining, availability: .available),
            RulesFeature(id: "PLANNED", title: "미구현 기능", allowedModes: [.original, .expanded],
                         kind: .assistance)
        ]
        return Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0) })
    }

    private func assertError(_ expected: RulesValidationError, file: StaticString = #filePath,
                             line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? RulesValidationError, expected, file: file, line: line)
        }
    }

    func testLegacyDefaultIsOriginalWithNoFeatures() throws {
        XCTAssertEqual(RulesProfile.original.mode, .original)
        XCTAssertEqual(RulesProfile.original.rulesRevision, 1)
        XCTAssertEqual(RulesProfile.original.enabledFeatures, [])
        XCTAssertEqual(RulesProfile.original, RulesProfile())
        try RulesProfile.original.validate()
        try RulesProfile(mode: .expanded).validate()
    }

    func testCodableMatchesEnvelopeContractAndContainsNoPresentationSettings() throws {
        let data = try JSONEncoder().encode(RulesProfile.original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["mode", "rulesRevision", "enabledFeatures"])
        XCTAssertEqual(object["mode"] as? String, "original")
        XCTAssertEqual(object["rulesRevision"] as? Int, 1)
        XCTAssertEqual(object["enabledFeatures"] as? [String], [])
        for profile in [RulesProfile.original, RulesProfile(mode: .expanded)] {
            XCTAssertEqual(try JSONDecoder().decode(RulesProfile.self, from: JSONEncoder().encode(profile)), profile)
        }
    }

    func testMissingProfileFieldsAndUnknownModesDoNotSilentlyDefault() {
        for json in [#"{}"#, #"{"mode":"original","rulesRevision":1}"#,
                     #"{"mode":"unknown","rulesRevision":1,"enabledFeatures":[]}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(RulesProfile.self, from: Data(json.utf8)))
        }
    }

    func testUnknownDecodedFeaturesArePreservedAndRejectedBeforeUse() throws {
        let data = Data(#"{"mode":"expanded","rulesRevision":1,"enabledFeatures":["FUTURE"]}"#.utf8)
        let profile = try JSONDecoder().decode(RulesProfile.self, from: data)
        XCTAssertEqual(profile.enabledFeatures, ["FUTURE"])
        assertError(.unknownFeature("FUTURE")) { try profile.validate() }
    }

    func testUnsupportedRuleRevisionsAreNotReinterpreted() {
        for revision in [Int.min, -1, 0, 2, Int.max] {
            assertError(.unsupportedRevision(revision)) {
                try RulesProfile(rulesRevision: revision).validate()
            }
        }
    }

    func testUnknownAndMalformedFeatureIDsAreRejectedWithoutNormalization() {
        for id in ["UNKNOWN", "A01", "", "b01", " B01", "B01 "] {
            assertError(.unknownFeature(id)) {
                try RulesProfile(mode: .expanded, enabledFeatures: [id]).validate()
            }
        }
    }

    func testDuplicateFeaturesAreRejectedRatherThanCollapsed() {
        assertError(.duplicateFeature("B01")) {
            try RulesProfile(enabledFeatures: ["B01", "B01"]).validate()
        }
    }

    func testEveryPlannedProductionFeatureIsUnavailableInBothModes() {
        XCTAssertFalse(RulesRegistry.features.isEmpty)
        for feature in RulesRegistry.features {
            XCTAssertEqual(feature.availability, .planned, feature.id)
            for mode in RulesMode.allCases {
                assertError(.featureUnavailable(feature.id)) {
                    try RulesProfile(mode: mode, enabledFeatures: [feature.id]).validate()
                }
            }
        }
    }

    func testRegistryDistinguishesOriginalCompatibleAndExpandedContent() throws {
        let ids = RulesRegistry.features.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for feature in RulesRegistry.features {
            XCTAssertGreaterThan(feature.stateVersion, 0)
            XCTAssertTrue(feature.requiredFeatures.allSatisfy { RulesRegistry.feature($0) != nil })
        }
        for id in ["B01", "B02", "B05", "F01"] {
            let feature = try XCTUnwrap(RulesRegistry.feature(id))
            XCTAssertEqual(feature.allowedModes, [.original, .expanded])
        }
        for id in ["B03", "B04", "F02", "F03", "F04", "F05", "F06", "F07"] {
            let feature = try XCTUnwrap(RulesRegistry.feature(id))
            XCTAssertEqual(feature.allowedModes, [.expanded])
            XCTAssertEqual(feature.disablePolicy, .whenIdle)
        }
        XCTAssertEqual(RulesRegistry.feature("F08")?.kind, .standaloneTraining)
        XCTAssertEqual(RulesRegistry.feature("F08")?.allowedModes, [])
    }

    func testAvailableAssistanceCanPreserveOriginalRulesButRewardsCannot() throws {
        try RulesProfile(enabledFeatures: ["HELPER"]).validate(using: fixtureRegistry)
        assertError(.incompatibleMode(featureID: "EXPANSION", mode: .original)) {
            try RulesProfile(enabledFeatures: ["EXPANSION"]).validate(using: fixtureRegistry)
        }
        try RulesProfile(mode: .expanded, enabledFeatures: ["HELPER", "EXPANSION"]).validate(using: fixtureRegistry)
    }

    func testUnavailableMetadataCannotBeUsedEvenIfItsModeIsAllowed() {
        assertError(.featureUnavailable("PLANNED")) {
            try RulesProfile(enabledFeatures: ["PLANNED"]).validate(using: fixtureRegistry)
        }
    }

    func testCampaignRejectsStandaloneTrainingEvenWhenImplemented() {
        assertError(.standaloneFeature("TRAINING")) {
            try RulesProfile(mode: .expanded, enabledFeatures: ["TRAINING"]).validate(using: fixtureRegistry)
        }
    }

    func testEnabledDependenciesAreRequiredRegardlessOfListOrder() throws {
        assertError(.missingDependency(featureID: "DEPENDENT", requiredID: "BASE")) {
            try RulesProfile(mode: .expanded, enabledFeatures: ["DEPENDENT"]).validate(using: fixtureRegistry)
        }
        for ids in [["BASE", "DEPENDENT"], ["DEPENDENT", "BASE"]] {
            try RulesProfile(mode: .expanded, enabledFeatures: ids).validate(using: fixtureRegistry)
        }
    }

    func testExpandedConversionRequiresANewSaveCopy() throws {
        let target = RulesProfile(mode: .expanded)
        assertError(.newSaveCopyRequired) {
            try RulesProfile.original.validateTransition(to: target)
        }
        try RulesProfile.original.validateTransition(to: target, context: .init(destination: .newSaveCopy))
        XCTAssertEqual(RulesProfile.original, RulesProfile())
    }

    func testExpandedCannotReturnToOriginalEvenWithoutActiveFeatures() {
        for destination in [RulesTransitionDestination.currentSave, .newSaveCopy] {
            assertError(.reverseModeChangeUnsupported) {
                try RulesProfile(mode: .expanded).validateTransition(to: .original,
                                                                    context: .init(destination: destination))
            }
        }
    }

    func testUnchangedProfilesDoNotNeedANewCopyOrFeatureState() throws {
        try RulesProfile.original.validateTransition(to: .original)
        let profile = RulesProfile(mode: .expanded, enabledFeatures: ["EXPANSION"])
        try profile.validateTransition(to: profile, context: .init(), using: fixtureRegistry)
    }

    func testDisablingStatefulFeatureRequiresExplicitIdleEvidence() throws {
        let source = RulesProfile(mode: .expanded, enabledFeatures: ["EXPANSION"])
        let target = RulesProfile(mode: .expanded)
        for activity in [[:], ["EXPANSION": RulesFeatureActivity.unknown]] {
            assertError(.featureStateUnknown("EXPANSION")) {
                try source.validateTransition(to: target, context: .init(featureActivity: activity), using: fixtureRegistry)
            }
        }
        try source.validateTransition(to: target, context: .init(featureActivity: ["EXPANSION": .idle]),
                                      using: fixtureRegistry)
    }

    func testContractsAssetsRewardsAndActiveEventsEachBlockDisabling() {
        let source = RulesProfile(mode: .expanded, enabledFeatures: ["EXPANSION"])
        for activity in [RulesFeatureActivity.activeContract, .storedAssets, .unclaimedReward, .activeEvent] {
            assertError(.featureInUse(featureID: "EXPANSION", activity: activity)) {
                try source.validateTransition(to: RulesProfile(mode: .expanded),
                                              context: .init(featureActivity: ["EXPANSION": activity]),
                                              using: fixtureRegistry)
            }
        }
        XCTAssertEqual(source.enabledFeatures, ["EXPANSION"])
    }

    func testAssistanceMayBeDisabledWithoutCampaignObligations() throws {
        let source = RulesProfile(enabledFeatures: ["HELPER"])
        try source.validateTransition(to: .original, context: .init(), using: fixtureRegistry)
    }

    func testReportedActiveInteractionBlocksEvenAnOtherwiseSafeToggle() {
        let source = RulesProfile(enabledFeatures: ["HELPER"])
        assertError(.featureInUse(featureID: "HELPER", activity: .activeEvent)) {
            try source.validateTransition(to: .original, context: .init(featureActivity: ["HELPER": .activeEvent]),
                                          using: fixtureRegistry)
        }
    }

    func testRemovingAStillRequiredDependencyIsRejected() {
        let source = RulesProfile(mode: .expanded, enabledFeatures: ["BASE", "DEPENDENT"])
        let target = RulesProfile(mode: .expanded, enabledFeatures: ["DEPENDENT"])
        assertError(.missingDependency(featureID: "DEPENDENT", requiredID: "BASE")) {
            try source.validateTransition(to: target, context: .init(featureActivity: ["BASE": .idle]),
                                          using: fixtureRegistry)
        }
    }

    func testTransitionCannotSilentlyDiscardUnknownSourceState() {
        let source = RulesProfile(mode: .expanded, enabledFeatures: ["FUTURE"])
        assertError(.unknownFeature("FUTURE")) {
            try source.validateTransition(to: RulesProfile(mode: .expanded))
        }
    }

    func testErrorsProvideKoreanRecoveryGuidance() {
        XCTAssertTrue(RulesValidationError.newSaveCopyRequired.localizedDescription.contains("사본"))
        XCTAssertTrue(RulesValidationError.featureStateUnknown("F02").localizedDescription.contains("상태"))
        XCTAssertTrue(RulesValidationError.featureUnavailable("F02").localizedDescription.contains("호송"))
        XCTAssertTrue(RulesValidationError.reverseModeChangeUnsupported.localizedDescription.contains("원작 사본"))
    }
}
