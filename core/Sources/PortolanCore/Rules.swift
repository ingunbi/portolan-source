import Foundation

/// Campaign rules are independent of classicLayout, classicMap and other presentation settings.
public enum RulesMode: String, Codable, CaseIterable, Equatable {
    case original, expanded

    public var title: String { self == .original ? "원작" : "확장" }
}

public enum RulesFeatureKind: String, Equatable {
    case originalCommands, assistance, expandedContent, standaloneTraining
}

/// Planned metadata describes a future feature; it does not make that feature executable.
public enum RulesFeatureAvailability: String, Equatable {
    case planned, available
}

public enum RulesFeatureDisablePolicy: String, Equatable {
    /// No campaign obligations are created. Explicitly reported active interactions still block changes.
    /// Disabling may hide, but must not erase, saved settings.
    case anytime
    /// A feature-specific adapter must explicitly confirm that obligations have been settled.
    case whenIdle
}

public struct RulesFeature: Equatable {
    public let id: String
    public let title: String
    public let stateVersion: Int
    public let requiredFeatures: [String]
    public let allowedModes: [RulesMode]
    public let kind: RulesFeatureKind
    public let availability: RulesFeatureAvailability
    public let disablePolicy: RulesFeatureDisablePolicy

    public init(id: String, title: String, stateVersion: Int = 1, requiredFeatures: [String] = [],
                allowedModes: [RulesMode], kind: RulesFeatureKind,
                availability: RulesFeatureAvailability = .planned,
                disablePolicy: RulesFeatureDisablePolicy = .whenIdle) {
        self.id = id
        self.title = title
        self.stateVersion = stateVersion
        self.requiredFeatures = requiredFeatures
        self.allowedModes = allowedModes
        self.kind = kind
        self.availability = availability
        self.disablePolicy = disablePolicy
    }
}

/// Runtime feature flags only. Implementation prerequisites such as A01/D04 are not flags.
/// Every entry remains planned until its implementation and save-state adapter are available.
public enum RulesRegistry {
    public static let features: [RulesFeature] = [
        RulesFeature(id: "B01", title: "다중 기항 항로 계획", allowedModes: [.original, .expanded],
                     kind: .assistance, disablePolicy: .anytime),
        RulesFeature(id: "B02", title: "함대 운용 편성 저장", allowedModes: [.original, .expanded],
                     kind: .assistance, disablePolicy: .anytime),
        RulesFeature(id: "B03", title: "항구 화물 창고", allowedModes: [.expanded], kind: .expandedContent),
        RulesFeature(id: "B04", title: "해상보험과 사고 정산", allowedModes: [.expanded], kind: .expandedContent),
        RulesFeature(id: "B05", title: "도시 목적지 클릭 이동", allowedModes: [.original, .expanded],
                     kind: .assistance, disablePolicy: .anytime),
        RulesFeature(id: "F01", title: "배별 전술 지휘와 전투 연출", allowedModes: [.original, .expanded],
                     kind: .originalCommands, disablePolicy: .anytime),
        RulesFeature(id: "F02", title: "움직이는 상선의 호송 계약", allowedModes: [.expanded], kind: .expandedContent),
        RulesFeature(id: "F03", title: "물자 납품과 항구 개발 사업", allowedModes: [.expanded], kind: .expandedContent),
        RulesFeature(id: "F04", title: "단계별 육상 탐험", allowedModes: [.expanded], kind: .expandedContent),
        RulesFeature(id: "F05", title: "동료 개인 이야기", allowedModes: [.expanded], kind: .expandedContent),
        RulesFeature(id: "F06", title: "선택형 해상 사건", allowedModes: [.expanded], kind: .expandedContent),
        RulesFeature(id: "F07", title: "기억하는 라이벌", allowedModes: [.expanded], kind: .expandedContent),
        RulesFeature(id: "F08", title: "해전 훈련과 도전", allowedModes: [],
                     kind: .standaloneTraining, disablePolicy: .anytime)
    ]

    static let byID = Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0) })

    public static func feature(_ id: String) -> RulesFeature? { byID[id] }
}

public enum RulesFeatureActivity: String, Equatable {
    case unknown, idle, activeContract, storedAssets, unclaimedReward, activeEvent

    public var detail: String {
        switch self {
        case .unknown: return "진행 상태를 확인하지 못했습니다"
        case .idle: return "진행 중인 의무가 없습니다"
        case .activeContract: return "진행 중인 계약이 있습니다"
        case .storedAssets: return "보관 중인 물품이나 자산이 있습니다"
        case .unclaimedReward: return "아직 받지 않은 보상이 있습니다"
        case .activeEvent: return "진행 중인 사건이 있습니다"
        }
    }
}

public enum RulesTransitionDestination: Equatable {
    case currentSave, newSaveCopy
}

/// This is evidence supplied by save/feature adapters, not serialized user preferences.
/// A successful policy check does not create a file; the caller must commit the new copy atomically.
public struct RulesTransitionContext: Equatable {
    public var destination: RulesTransitionDestination
    public var featureActivity: [String: RulesFeatureActivity]

    public init(destination: RulesTransitionDestination = .currentSave,
                featureActivity: [String: RulesFeatureActivity] = [:]) {
        self.destination = destination
        self.featureActivity = featureActivity
    }
}

/// Pure save-envelope metadata. Decoding preserves supplied values; call validate() before use.
/// Missing legacy profiles are migrated by the save codec to .original, never by dropping flags.
public struct RulesProfile: Codable, Equatable {
    public static let currentRevision = 1
    public static let original = RulesProfile()

    public var mode: RulesMode
    public var rulesRevision: Int
    public var enabledFeatures: [String]

    public init(mode: RulesMode = .original, rulesRevision: Int = RulesProfile.currentRevision,
                enabledFeatures: [String] = []) {
        self.mode = mode
        self.rulesRevision = rulesRevision
        self.enabledFeatures = enabledFeatures
    }

    public func validate() throws { try validate(using: RulesRegistry.byID) }

    /// Checks only. In particular, no Voyage values, original RNG or files are changed.
    public func validateTransition(to target: RulesProfile,
                                   context: RulesTransitionContext = RulesTransitionContext()) throws {
        try validateTransition(to: target, context: context, using: RulesRegistry.byID)
    }

    // Internal injection permits policy boundary tests without enabling unreleased production flags.
    func validate(using registry: [String: RulesFeature]) throws {
        guard rulesRevision == Self.currentRevision else {
            throw RulesValidationError.unsupportedRevision(rulesRevision)
        }
        var enabled = Set<String>()
        for id in enabledFeatures {
            guard enabled.insert(id).inserted else { throw RulesValidationError.duplicateFeature(id) }
        }
        for id in enabledFeatures {
            guard let feature = registry[id] else { throw RulesValidationError.unknownFeature(id) }
            guard feature.availability == .available else { throw RulesValidationError.featureUnavailable(id) }
            guard feature.kind != .standaloneTraining else { throw RulesValidationError.standaloneFeature(id) }
            guard feature.allowedModes.contains(mode) else {
                throw RulesValidationError.incompatibleMode(featureID: id, mode: mode)
            }
            for dependency in feature.requiredFeatures where !enabled.contains(dependency) {
                throw RulesValidationError.missingDependency(featureID: id, requiredID: dependency)
            }
        }
    }

    func validateTransition(to target: RulesProfile, context: RulesTransitionContext,
                            using registry: [String: RulesFeature]) throws {
        // Invalid source profiles cannot be repaired by silently removing unknown/future features.
        try validate(using: registry)
        try target.validate(using: registry)
        if mode == .expanded && target.mode == .original {
            throw RulesValidationError.reverseModeChangeUnsupported
        }
        if mode == .original && target.mode == .expanded && context.destination != .newSaveCopy {
            throw RulesValidationError.newSaveCopyRequired
        }
        let removed = Set(enabledFeatures).subtracting(target.enabledFeatures)
        for id in removed.sorted() {
            if let activity = context.featureActivity[id] {
                guard activity != .unknown else { throw RulesValidationError.featureStateUnknown(id) }
                guard activity == .idle else {
                    throw RulesValidationError.featureInUse(featureID: id, activity: activity)
                }
            } else if registry[id]?.disablePolicy == .whenIdle {
                throw RulesValidationError.featureStateUnknown(id)
            }
        }
    }
}

public enum RulesValidationError: Error, LocalizedError, Equatable {
    case unsupportedRevision(Int)
    case duplicateFeature(String)
    case unknownFeature(String)
    case featureUnavailable(String)
    case incompatibleMode(featureID: String, mode: RulesMode)
    case standaloneFeature(String)
    case missingDependency(featureID: String, requiredID: String)
    case newSaveCopyRequired
    case reverseModeChangeUnsupported
    case featureStateUnknown(String)
    case featureInUse(featureID: String, activity: RulesFeatureActivity)

    public var errorDescription: String? {
        switch self {
        case .unsupportedRevision(let revision):
            return "지원하지 않는 규칙 버전(\(revision))입니다. 현재 지원 버전은 \(RulesProfile.currentRevision)입니다."
        case .duplicateFeature(let id):
            return "기능 \(id)이 중복 지정되어 있습니다. 저장의 기능 목록을 확인해 주세요."
        case .unknownFeature(let id):
            return "알 수 없는 기능 \(id)이 포함되어 있습니다. 원본 저장을 보존하고 지원하는 앱 버전을 확인해 주세요."
        case .featureUnavailable(let id):
            return "\(featureName(id)) 기능은 아직 사용할 수 없습니다. 개발 계획에 등록된 기능은 구현 전까지 켤 수 없습니다."
        case .incompatibleMode(let id, let mode):
            return "\(featureName(id)) 기능은 \(mode.title) 규칙에서 사용할 수 없습니다."
        case .standaloneFeature(let id):
            return "\(featureName(id)) 기능은 별도 훈련 세션용이므로 캠페인 규칙에 추가할 수 없습니다."
        case .missingDependency(let id, let dependency):
            return "\(featureName(id)) 기능에는 \(featureName(dependency)) 기능이 필요합니다."
        case .newSaveCopyRequired:
            return "확장 규칙으로 바꾸려면 원작 저장을 보존하고 별도 슬롯에 사본을 만들어야 합니다."
        case .reverseModeChangeUnsupported:
            return "확장 저장을 원작 규칙으로 되돌리는 기능은 지원하지 않습니다. 확장 전의 원작 사본을 불러와 주세요."
        case .featureStateUnknown(let id):
            return "\(featureName(id)) 기능의 진행 상태를 확인하지 못해 끌 수 없습니다. 계약·보관품·보상 상태를 확인해 주세요."
        case .featureInUse(let id, let activity):
            return "\(featureName(id)) 기능을 끌 수 없습니다. \(activity.detail)."
        }
    }

    private func featureName(_ id: String) -> String {
        RulesRegistry.feature(id).map { "\($0.title)(\(id))" } ?? id
    }
}
