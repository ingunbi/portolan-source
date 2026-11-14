#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import PortolanCore

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ n: Notification) {
        guard ProcessInfo.processInfo.environment["PORTOLAN_PLAYTEST"] == nil else { return }
        // Windows saved at the old 1360×860 start size open at the new, screen-sized one once.
        let d = UserDefaults.standard
        if d.integer(forKey: "windowSizeVersion") < 3 {
            for key in d.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame") { d.removeObject(forKey: key) }
            d.set(3, forKey: "windowSizeVersion")
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if let dir = ProcessInfo.processInfo.environment["PORTOLAN_PLAYTEST"] {
            // The synchronous test driver spins native run loops. Start outside a GCD
            // main-queue block so those loops can also execute real delayed UI callbacks.
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { _ in
                let ok = PlaytestRunner.run(to: URL(fileURLWithPath: dir))
                exit(ok ? 0 : 1)
            }
            return
        }
        if let dir = ProcessInfo.processInfo.environment["PORTOLAN_SNAPSHOT"] {
            Snapshot.run(to: URL(fileURLWithPath: dir))
            exit(0)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        ProcessInfo.processInfo.environment["PORTOLAN_PLAYTEST"] == nil
    }
}

#endif

struct RootView: View {
    static let minSize = CGSize(width: 960, height: 600)
    @ObservedObject var game: Game
    var previewWorld: NSImage? = nil
    var body: some View {
        let policy = game.interaction
        ZStack {
            if let previewWorld {
                Image(nsImage: previewWorld).resizable().ignoresSafeArea()
                Canvas { context, size in WorldOverlay(game: game).draw(&context, size) }.allowsHitTesting(false)
            } else {
                WorldView(game: game).ignoresSafeArea().interactionSurface(policy.worldInputAllowed)
                WorldOverlay(game: game).ignoresSafeArea()
            }
            Group {
                if game.classicLayout && !game.title {
                    if let h = game.harbor { ClassicPortFrame(game: game, harbor: h) } else { ClassicSeaFrame(game: game) }
                } else {
                    if let h = game.harbor {
                        HarborView(game: game, harbor: h)
                    } else {
                        HUD(game: game)
                    }
                }
            }.interactionSurface(policy.allows(.world) || policy.allows(.service))
            if game.showFleet { FleetInfoView(game: game).interactionSurface(policy.allows(.fleet)) }
            if game.showVoyagePlan { VoyagePlanView(game: game).interactionSurface(policy.allows(.voyagePlan)) }
            if let s = game.landing { LandingView(game: game, site: s).interactionSurface(policy.allows(.landing)) }
            if let c = game.coast { CoastView(game: game, coast: c).interactionSurface(policy.allows(.coast)) }
            if let pages = game.seaEvent {
                Group {
                    if game.classicLayout {
                        ClassicMessageBox(game: game, text: pages.first ?? "") {
                            let rest = Array(pages.dropFirst())
                            game.seaEvent = rest.isEmpty ? nil : rest
                        }
                    } else {
                        SeaEventView(game: game, pages: pages)
                    }
                }.interactionSurface(policy.allows(.seaEvent))
            }
            if game.battle != nil {
                Group {
                    if game.classicLayout { ClassicBattleView(game: game) } else { BattleView(game: game) }
                }.interactionSurface(policy.allows(.battle) || policy.allows(.duel))
            }
            if let (e, o) = game.encounter { BattleIntroView(game: game, encounter: e, opening: o).interactionSurface(policy.allows(.encounter)) }
            if let r = game.battleResult { BattleResultView(game: game, result: r).interactionSurface(policy.allows(.battleResult)) }
            if let t = game.tabMenu {
                Group {
                    if game.classicLayout && !game.title { ClassicTabPopup(game: game, tab: t) } else { TabPopup(game: game, tab: t) }
                }.interactionSurface(policy.allows(.tabs))
            }
            if let c = game.command { CommandSheet(game: game, command: c).interactionSurface(policy.allows(.command)) }
            if let i = game.info { InfoView(game: game, screen: i).interactionSurface(policy.allows(.information)) }
            Group {
                if game.classicLayout && !game.title { ClassicDialogue(game: game) } else { DialogueView(game: game) }
            }.interactionSurface(policy.allows(.dialogue))
            if let text = game.portMessageText, game.session == nil {
                Group {
                    if game.classicLayout {
                        ClassicMessageBox(game: game, text: text) { game.dismissTownMessage() }
                    } else {
                        PortMessageView(game: game, text: text)
                    }
                }.interactionSurface(policy.allows(.message))
            }
            if game.title {
                ZStack(alignment: .topTrailing) {
                    TitleView(game: game)
                    Button("새 게임 규칙 · \(game.newGameRules.mode.title)") { game.openRules() }
                        .accessibilityIdentifier("portolan.rules.open")
                        .padding(20)
                }.interactionSurface(policy.allows(.title))
            }
            if let c = game.endingCode { EndingView(game: game, code: c).id(c).interactionSurface(policy.allows(.ending)) }
            if game.opening { OpeningView(game: game).interactionSurface(policy.allows(.opening)) }
            if let why = game.status.gameOver, game.battleResult == nil { GameOverView(game: game, reason: why).interactionSurface(policy.allows(.gameOver)) }
            if game.showRules { RulesView(game: game).interactionSurface(policy.allows(.rules)) }
            if game.showDiagnostics { DiagnosticsView(game: game).interactionSurface(policy.allows(.diagnostics)) }
            if let m = game.slotMode { SaveSlotsView(game: game, mode: m).interactionSurface(policy.allows(.slots)) }
            if let question = game.question { GameConfirmationView(game: game, question: question).id(question.id).interactionSurface(policy.allows(.confirmation)) }
        }
        .font(GameFont.body)
        .buttonStyle(GameButtonStyle())
        .tint(Theme.gold)
        .frame(minWidth: RootView.minSize.width, minHeight: RootView.minSize.height)
        .background(GameWindowRegistration(game: game).frame(width: 0, height: 0))
        .onAppear { game.installKeyMonitor() }
        .animation(.easeOut(duration: 0.2), value: game.harbor)
    }
}

private extension View {
    /// Blocking pointer input alone leaves hidden controls callable through native AX actions.
    func interactionSurface(_ enabled: Bool) -> some View {
        disabled(!enabled).allowsHitTesting(enabled).accessibilityHidden(!enabled)
    }
}

/// Game confirmations use the same readable type as the surrounding screen.
struct GameConfirmationView: View {
    @ObservedObject var game: Game
    let question: Question

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.65).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 22) {
                    Text("확인").font(GameFont.title2.bold())
                    ScrollView {
                        Text(question.text).font(.system(size: 22, weight: .medium))
                            .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 300).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Spacer()
                        Button(question.no) { game.answerQuestion(question.id, accepting: false) }
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("portolan.question.no")
                        Button(question.yes) { game.answerQuestion(question.id, accepting: true) }
                            .buttonStyle(GameButtonStyle(prominent: true))
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("portolan.question.yes")
                    }
                }
                .padding(28)
                .frame(width: min(660, geometry.size.width - 48))
                .frame(maxHeight: geometry.size.height - 40)
                .gamePanel(radius: 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.colorScheme, .dark)

    }
}

struct GameOverView: View {
    @ObservedObject var game: Game
    let reason: String

    /// Messages 1013–1016 with the date and the hero's name.
    private var epitaph: String? {
        let v = game.status
        guard let c = v.gameOverCode, let n = [0x1A: 1013, 0x18: 1014, 0x19: 1015, 0x10: 1016][c] else { return nil }
        let given = v.memory.string(DS.person(v.heroID), max: 13), family = v.memory.string(DS.person(v.heroID) + 0x0D, max: 13)
        let t = game.message(n).replacingOccurrences(of: "%w", with: "%d")
        return fillText(t, [String(format: "%02d", v.year % 100), "\(v.month + 1)", "\(v.dayOfMonth + 1)", given, family, given, family])
    }

    private func fillText(_ t: String, _ args: [String]) -> String {
        var t = t
        for a in args {
            guard let r = t.range(of: "%-?[0-9]*l?[sdu]", options: .regularExpression) else { break }
            t.replaceSubrange(r, with: a)
        }
        return Korean.particles(t)
    }
    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 14) {
                // GRAPH.DAT 61 above the message, except for the retirement (MAIN 0x17032).
                if let c = game.status.gameOverCode, c != 0x10, let img = game.image("images/graph_61.png") {
                    Image(nsImage: img).pixelated().aspectRatio(contentMode: .fit).frame(maxWidth: 360)
                }
                Text("항해 종료").font(.system(size: 36, weight: .bold, design: .serif))
                Text(epitaph ?? reason).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 560)
                HStack {
                    Button("불러오기") { game.load() }
                    Button("처음부터") { game.newGame() }.buttonStyle(GameButtonStyle(prominent: true))
                        .accessibilityIdentifier("portolan.gameover.restart")
                }
            }
            .padding(32)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 20))
            .environment(\.colorScheme, .dark)
        }
    }
}

struct MissingAssetsView: View {
    let details: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("게임 자료를 불러오지 못했습니다", systemImage: "shippingbox")
                .font(GameFont.title2.bold())
            Text("게임 자료 폴더를 확인하고 자료를 다시 준비한 뒤 앱을 실행해 주세요.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(details).font(GameFont.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 320).accessibilityIdentifier("portolan.assets.error")
            Button(copied ? "복사했습니다" : "오류 정보 복사") {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(details, forType: .string)
                #else
                UIPasteboard.general.string = details
                #endif
                copied = true
            }.accessibilityIdentifier("portolan.assets.copy")
        }
        .font(GameFont.body).padding(28).frame(maxWidth: 840)
        .frame(minWidth: 560, minHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(macOS)
private struct GameFileCommands: Commands {
    @ObservedObject var game: Game

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("저장") { game.save() }.keyboardShortcut("s")
                .disabled(!game.interaction.canOpenSave)
                .help(game.interaction.saveBlockReason ?? "현재 항해를 저장합니다.")
            Button("불러오기") { game.load() }.keyboardShortcut("o")
                .disabled(!game.interaction.canOpenLoad)
        }
        CommandMenu("항해 정보") {
            Button("규칙 정보…") { game.openRules() }
            Button("진단 기록…") { game.openDiagnostics() }
        }
    }
}

@main
struct PortolanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private let startup: (game: Game?, error: String) = {
        guard let assets = Game.findAssets() else {
            return (nil, "게임 자료 폴더 assets를 찾을 수 없습니다.\n개발 폴더에서는 tools/extract.py로 자료를 준비해 주세요.\n배포 앱에서는 앱 안의 자료 폴더가 포함되어 있는지 확인해 주세요.")
        }
        do { return (try Game(assets: assets), "") }
        catch { return (nil, "자료 위치: \(assets.path)\n\n\(error.localizedDescription)") }
    }()

    /// Use most of the visible screen. Minimum-size regression windows are test-only.
    static var startSize: CGSize {
        let v = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let w = (v.width * 0.94).rounded()
        let h = (v.height * 0.94).rounded()
        return CGSize(width: max(RootView.minSize.width, w), height: max(RootView.minSize.height, h))
    }

    var body: some Scene {
        WindowGroup("Portolan · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발판")") {
            if let game = startup.game { RootView(game: game) } else { MissingAssetsView(details: startup.error) }
        }
        .defaultSize(PortolanApp.startSize)
        .commands {
            if let game = startup.game { GameFileCommands(game: game) }
        }
    }
}

#endif
