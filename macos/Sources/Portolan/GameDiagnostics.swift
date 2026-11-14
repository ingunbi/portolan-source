#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import PortolanCore

extension Game {
    func adjustSail(_ delta: Int) {
        observe(.sail(delta)) { $0.setSail(delta); return "applied" }
        status = voyage
    }
    func toggleAnchor() -> String {
        var line = ""
        observe(.anchor) { line = $0.toggleAnchor(); return "applied" }
        status = voyage
        return line
    }
    func registerInputWindow(_ window: NSWindow?) {
        if let window { inputWindows.add(window) }
    }

    var diagnosticContext: DiagnosticContext {
        DiagnosticContext(screen: String(describing: interaction.inputOwner), generation: presentationGeneration,
            scriptLocation: session?.run?.diagnosticLocation,
            battleLocation: battle.map { "\($0.phase):tick=\(voyage.tick),active=\(String(describing: $0.active)),result=\($0.endCode),units=\($0.units.count)" },
            violations: interaction.invalidCombinations)
    }
    func diagnosticEvent(_ label: String) {
        diagnostics?.event(label, voyage: voyage, context: diagnosticContext)
    }
    func recordDiagnosticContext() {
        guard diagnostics?.enabled == true else { return }
        let context = diagnosticContext
        if context != lastDiagnosticContext {
            diagnostics?.event("screen-transition", voyage: voyage, context: context)
            lastDiagnosticContext = context
        }
    }
    /// Execute the original mutation exactly once. Observation is optional and cannot reject it.
    @discardableResult
    func observe(_ command: DiagnosticCommand, _ change: (inout Voyage) -> String) -> String {
        let supported = diagnostics?.enabled == true && diagnostics?.isStopped == false && session == nil && battle == nil
        let before = supported ? DiagnosticSnapshot(voyage) : nil
        let context = diagnosticContext
        let result = change(&voyage)
        if let before {
            diagnostics?.record(command, before: before, after: DiagnosticSnapshot(voyage), result: result, context: context)
        } else if diagnostics?.enabled == true {
            diagnosticEvent("core-command-inside-unsupported-context")
        }
        return result
    }
    func openDiagnostics() {
        guard question == nil, !transitioning, !opening else { return }
        held.removeAll(); townAim = nil; showRules = false
        showDiagnostics = true; diagnosticExportStatus = nil
    }
    func restartDiagnostics() {
        diagnostics = DiagnosticRecorder(contentRevision: world.contentRevision)
        lastDiagnosticContext = nil; diagnosticExportStatus = "새 진단 기록을 시작했습니다."
    }
    @discardableResult
    func exportDiagnostics(to destination: URL) -> Bool {
        guard let recorder = diagnostics else { return false }
        do {
            let validation = ContentValidation.validate(assets: assets, scope: .runtime)
            try validation.requireValid()
            try DiagnosticExport.write(recorder.bundle, content: validation.manifest, to: destination)
            diagnosticExportStatus = "진단 묶음을 이 컴퓨터에 저장했습니다. 자동 전송하지 않았습니다."
            return true
        } catch {
            diagnosticExportStatus = "진단 내보내기에 실패했습니다. 플레이는 계속할 수 있습니다.\n\(error.localizedDescription)"
            return false
        }
    }
    func chooseDiagnosticDestination() {
        if ProcessInfo.processInfo.environment["PORTOLAN_PLAYTEST"] != nil,
           let path = ProcessInfo.processInfo.environment["PORTOLAN_DIAGNOSTIC_EXPORT"] {
            _ = exportDiagnostics(to: URL(fileURLWithPath: path)); return
        }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "진단 묶음 저장"
        panel.nameFieldStringValue = "Portolan-진단-\(String(UUID().uuidString.prefix(8))).portolandiag"
        panel.message = "게임 내 이름과 상태가 포함됩니다. 저장할 새 폴더 이름을 선택하세요."
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { _ = exportDiagnostics(to: url) }
        #else
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        _ = exportDiagnostics(to: dir.appendingPathComponent("Portolan-진단-\(String(UUID().uuidString.prefix(8))).portolandiag"))
        #endif
    }

    func openRules() {
        guard question == nil, !transitioning, !opening else { return }
        held.removeAll(); townAim = nil; showDiagnostics = false
        showRules = true; rulesError = nil
    }
    @discardableResult
    func selectNewGameRules(_ profile: RulesProfile) -> Bool {
        guard title, interaction.allows(.rules) else { return false }
        do { try profile.validate(); newGameRules = profile; rulesError = nil; return true }
        catch { rulesError = error.localizedDescription; return false }
    }
    @discardableResult
    func createExpandedCopy(slot: Int) -> Bool {
        rulesError = nil
        guard !title, interaction.allows(.rules), interaction.canStoreVoyage, session == nil, battle == nil else {
            rulesError = "대화와 사건을 마친 안전한 항해에서 사본을 만들어 주세요."; return false
        }
        guard (0..<SaveGame.slots).contains(slot), !SaveGame.inspect(slot).hasCurrent,
              SaveGame.inspect(slot).backupHeader == nil else {
            rulesError = "기존 저장을 보존하도록 비어 있는 슬롯을 선택해 주세요."; return false
        }
        do {
            let target = RulesProfile(mode: .expanded)
            guard voyage.saveContext.rules.mode == .original else { throw DiagnosticError.invalid("이미 확장 규칙입니다.") }
            try voyage.saveContext.rules.validateTransition(to: target, context: .init(destination: .newSaveCopy))
            var copy = voyage
            copy.saveContext.saveID = UUID(); copy.saveContext.generation = 0
            copy.saveContext.rules = target; copy.saveContext.contentRevision = world.contentRevision
            if harbor != nil { copy.memory[0xC3B] = 0x82 }
            try SaveGame.write(copy, slot: slot, port: harbor.map { portName($0.id) }, requireEmpty: true)
            // Preserve the live interpreter-independent state; only metadata changes after a verified write.
            voyage.saveContext = copy.saveContext
            voyage.saveContext.generation = 1
            status = voyage
            diagnosticEvent("rules-new-copy:\(slot)")
            return true
        } catch { rulesError = error.localizedDescription; return false }
    }
}
