import Foundation

/// Presentation-only ownership. None of this transient state is part of a Voyage save.
public struct InteractionPolicy: Equatable {
    /// Matches the application's existing overlay order; a duel lives inside the battle view.
    public enum Layer: Int, CaseIterable, Hashable {
        case world, service, fleet, voyagePlan, landing, coast, seaEvent
        case battle, duel, encounter, battleResult, tabs, command, information
        case dialogue, message, title, ending, opening, gameOver, rules, diagnostics, slots, confirmation, transition
    }

    public let layers: Set<Layer>
    public let inHarbor: Bool
    public let paused: Bool
    public let hasPendingEncounter: Bool
    public let allowsSavingFromCommand: Bool

    public init(layers: Set<Layer> = [], inHarbor: Bool = false, paused: Bool = false,
                hasPendingEncounter: Bool = false, allowsSavingFromCommand: Bool = false) {
        var visible = layers
        // Fatal damage is published before its result is acknowledged. The result still owns input.
        if visible.contains(.battleResult) { visible.remove(.gameOver) }
        if visible.contains(.dialogue) { visible.remove(.message) }
        self.layers = visible
        self.inHarbor = inHarbor
        self.paused = paused
        self.hasPendingEncounter = hasPendingEncounter
        self.allowsSavingFromCommand = allowsSavingFromCommand
    }

    public var inputOwner: Layer { layers.max(by: { $0.rawValue < $1.rawValue }) ?? .world }
    public func allows(_ layer: Layer) -> Bool { inputOwner == layer }
    public var worldInputAllowed: Bool { allows(.world) }
    public var sailingTimeAllowed: Bool { worldInputAllowed && !inHarbor && !paused && !hasPendingEncounter }
    public var townTimeAllowed: Bool { worldInputAllowed && inHarbor }
    public var canPresentEncounter: Bool { worldInputAllowed && !inHarbor }

    /// Stable invariants for diagnostics; valid nesting is not treated as an error.
    public var invalidCombinations: [String] {
        var problems: [String] = []
        if layers.contains(.duel) && !layers.contains(.battle) { problems.append("duel_without_battle") }
        if layers.contains(.battleResult) && !layers.contains(.battle) { problems.append("result_without_battle") }
        if layers.contains(.service) && !inHarbor { problems.append("service_outside_harbor") }
        if layers.contains(.title) && !layers.isDisjoint(with: [.battle, .dialogue]) {
            problems.append("title_with_active_session")
        }
        return problems
    }

    /// Saving stores Voyage only, not script stacks, battle state, or partially edited commands.
    /// Slot/confirmation overlays do not invalidate an otherwise safe snapshot at commit time.
    public var saveBlockReason: String? {
        if layers.contains(.transition) { return "화면 전환이 끝난 뒤 저장해 주세요." }
        if !layers.isDisjoint(with: [.title, .opening, .gameOver]) { return "플레이 중인 항해만 저장할 수 있습니다." }
        if !layers.isDisjoint(with: [.dialogue, .ending, .message]) { return "대화를 마친 뒤 저장해 주세요." }
        if hasPendingEncounter || !layers.isDisjoint(with: [.battle, .duel, .encounter, .battleResult]) {
            return "해전과 결과 확인을 마친 뒤 저장해 주세요."
        }
        if !layers.isDisjoint(with: [.seaEvent, .landing, .coast]) || (layers.contains(.command) && !allowsSavingFromCommand) {
            return "진행 중인 사건이나 편성 창을 닫은 뒤 저장해 주세요."
        }
        return nil
    }

    public var canStoreVoyage: Bool { saveBlockReason == nil }
    public var canOpenSave: Bool { canStoreVoyage && layers.isDisjoint(with: [.slots, .confirmation]) }
    public var canOpenLoad: Bool { layers.isDisjoint(with: [.transition, .opening, .ending, .slots, .confirmation]) }
}
