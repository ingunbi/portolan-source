#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation
import PortolanCore

/// Session state shared by the renderer, overlay and HUD. The voyage advances from the
/// render loop. Published fields change only a few times a second, which keeps SwiftUI cheap.
final class Game: ObservableObject {
    let world: World
    let assets: URL
    var voyage: Voyage
    var camera: (x: Double, y: Double)
    var zoom = 12.0
    var viewSize = CGSize(width: 1280, height: 800)
    var held = Set<UInt16>()
    var keyMonitor: Any?
    private var _townTap: Int?
    let inputWindows = NSHashTable<NSWindow>.weakObjects()
    var inputWindow: NSWindow? {
        #if os(macOS)
        if let key = NSApp.keyWindow, inputWindows.contains(key) { return key }
        #endif
        return inputWindows.allObjects.first
    }
    var diagnostics: DiagnosticRecorder?
    var lastDiagnosticContext: DiagnosticContext?
    // Capture before publishing: disabling the covered SwiftUI field ends editing before onAppear.
    private let diagnosticsFocus = ModalFocusSnapshot()
    private let rulesFocus = ModalFocusSnapshot()
    private let slotsFocus = ModalFocusSnapshot()
    private let questionFocus = ModalFocusSnapshot()
    @Published var showDiagnostics = false {
        willSet {
            if newValue && !showDiagnostics { diagnosticsFocus.enter(in: inputWindow) }
            if !newValue && showDiagnostics { diagnosticsFocus.leave() }
        }
    }
    @Published var diagnosticExportStatus: String?
    @Published var showRules = false {
        willSet {
            if newValue && !showRules { rulesFocus.enter(in: inputWindow) }
            if !newValue && showRules { rulesFocus.leave() }
        }
    }
    @Published var newGameRules = RulesProfile.original
    @Published var rulesError: String?
    /// The walking town before the latest pass of the walk loop, and when that pass ran.
    var townBefore: TownFrame?
    var townPassAt = Date.distantPast
    var clock = 0.0
    private var hudClock = 0.0
    private var images: [String: NSImage?] = [:]

    @Published var status: Voyage
    @Published var dockable: Harbor?
    @Published var harbor: Harbor? { didSet { syncTown() } }
    /// The walking town: the hero's facing and step frame, the direction held on the map or
    /// the compass, a townsperson's or a locked door's words, and the walk loop's clock.
    @Published var townFace = 2
    @Published var townStepFrame = 0
    @Published var townMessage: String?
    /// The original sea view's top-left tile (classic layout).
    var seaOrigin: (x: Int, y: Int)?
    var townAim: Int?
    private var townWaiting = false
    private var walkClock = 0.0
    @Published var panel: HarborPanel?
    @Published var tavern: Tavern?
    @Published var shipyardTab = 0
    /// The scenario scripts of the event in progress, and the building being entered.
    @Published var session: ScriptSession?
    @Published var endingCode: Int?
    @Published private var sessionBuilding: HarborPanel?
    @Published private var messageBuilding: HarborPanel?
    /// Original door flow draws the interior before SNR dialogue, but only enables the
    /// service after the script and entry checks. Keep those two states distinct.
    var buildingScene: HarborPanel? { sessionBuilding ?? panel ?? messageBuilding }

    func buildingPicture(_ building: HarborPanel) -> NSImage? {
        let number = building == .church && harbor.map({ Town.mosques.contains($0.id) }) == true
            ? 20 : building.rawValue + 6
        return image(String(format: "images/graph_%02d.png", number))
    }
    private var lastDay = 0
    /// Sea battle: the encounter dialog, the battle itself, and its outcome.
    @Published var encounter: (Encounter, BattleOpening)?
    @Published var battle: Battle?
    @Published var battleResult: BattleResult?
    /// A village being visited ashore.
    @Published var landing: Int?
    /// A yes/no question outside the scripts (the informant's map 605, departure, deserters).
    @Published var question: Question? {
        willSet {
            if question == nil && newValue != nil { questionFocus.enter(in: inputWindow) }
            if question != nil && newValue == nil { questionFocus.leave() }
        }
    }
    /// A fleet command window (편성 · 지휘 · 항해 menus) and a landing on open coast (menu 36).
    @Published var command: FleetCommand?
    /// A screen of the 정보 menu (MENU 26).
    @Published var info: InfoScreen?
    @Published var coast: CoastLanding?
    /// The save/load slot window.
    @Published var slotMode: SlotMode? {
        willSet {
            if slotMode == nil && newValue != nil { slotsFocus.enter(in: inputWindow) }
            if slotMode != nil && newValue == nil { slotsFocus.leave() }
        }
    }
    @Published var saveError: String?
    @Published var transitioning = false
    var presentationGeneration = 0
    /// GRAPH.DAT 58 at (160,16) as a storm breaks (seamap.md §7), shown for a few seconds.
    @Published var stormPicture = false
    private var stormSeen = false
    /// A command tab pulled out from the keyboard (F1–F4, keypad / * - +).
    @Published var tabMenu: Int?
    /// A sea event's three message boxes (0x305DE: msg 1176, 510 + 2t, 511 + 2t), one at a time.
    @Published var seaEvent: [String]?
    /// Runs when the scripts of the current event are done.
    private var afterScripts: (() -> Void)?
    lazy var sfx = SoundEffects(assets: assets)
    lazy var music: MusicPlayer = {
        let m = MusicPlayer(assets: assets)
        m.finished = { [weak self] i in if i == MusicPlayer.fanfare { self?.fanfareDone = true } }
        return m
    }()
    /// The victory fanfare has played for this battle result.
    var fanfareDone = false
    lazy var faces = FaceComposer(assets: assets)
    /// OPEN.EXE plays before the title (KOEI.COM runs OPEN, then MAIN); skipped in snapshot runs.
    @Published var opening = ProcessInfo.processInfo.environment["PORTOLAN_SNAPSHOT"] == nil
    /// The song END.EXE is playing (19 for the homecoming, 22 for the diary and staff roll).
    var cinemaSong: Int?
    /// The title menu is up (0x16994); skipped in snapshot runs.
    @Published var title = ProcessInfo.processInfo.environment["PORTOLAN_SNAPSHOT"] == nil
    var loaded = false
    @Published var showFleet = false
    @Published var fleetTab = 0

    /// Opens the fleet sheet on one of its pages (정보 · 편성 · 지휘 menus).
    func showFleet(tab: Int) {
        fleetTab = tab
        showFleet = true
    }
    @Published var paused = false
    @Published var showHelp = false
    @Published var showVoyagePlan = false
    @Published var plannedPortID: Int?
    /// The original screen layout (frame.md): frame pictures, status panels, wheel and tabs.
    @Published var classicLayout = UserDefaults.standard.object(forKey: "classicLayout") as? Bool ?? false {
        didSet { UserDefaults.standard.set(classicLayout, forKey: "classicLayout") }
    }
    /// Draw the sea with the original's chips (docs/re/seamap.md) instead of the remaster's shader.
    @Published var classicMap = UserDefaults.standard.object(forKey: "classicMap") as? Bool ?? false {
        didSet { UserDefaults.standard.set(classicMap, forKey: "classicMap") }
    }
    @Published var notice: String?
    private var noticeClock = 0.0

    init(assets: URL) throws {
        self.assets = assets
        world = try World(assets: assets)
        let v = Voyage.newGame(in: world)
        let home = world.ports[world.navigation.newGame.heroes[0].port]
        voyage = v
        status = v
        camera = (v.x, v.y)
        harbor = home
        diagnostics = DiagnosticRecorder(contentRevision: world.contentRevision)
    }

    static func findAssets() -> URL? {
        // An explicitly selected or bundled folder must report its own validation failure;
        // silently falling back would hide a damaged package behind development assets.
        if let env = ProcessInfo.processInfo.environment["PORTOLAN_ASSETS"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("assets")) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("assets"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Pictures from the assets, kept once loaded (sprites are drawn every frame).
    func image(_ path: String) -> NSImage? {
        if let i = images[path] { return i }
        let i = NSImage(contentsOf: assets.appendingPathComponent(path))
        images[path] = i
        return i
    }

    /// A picture shrunk to `width` pixels, to be drawn large with smooth interpolation: a cheap,
    /// still blur for backdrops.
    func softImage(_ path: String, width: Int = 48) -> NSImage? {
        let key = "soft\(width):" + path
        if let i = images[key] { return i }
        var out: NSImage?
        if let src = image(path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // Down to `width` pixels, then smoothly back up tenfold, so it stays soft at any size.
            func resample(_ img: CGImage, _ w: Int) -> CGImage? {
                let h = max(1, img.height * w / max(1, img.width))
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return ctx.makeImage()
            }
            if let small = resample(src, width), let big = resample(small, width * 10) {
                out = NSImage(cgImage: big, size: NSSize(width: big.width, height: big.height))
            }
        }
        images[key] = out
        return out
    }

    var daylight: Double {
        let frac = (Double(voyage.day) + voyage.dayClock / Voyage.secondsPerDay).truncatingRemainder(dividingBy: 1)
        return 0.55 + 0.45 * max(0, min(1, 0.5 + 1.4 * sin(frac * 2 * .pi)))
    }

    var dateText: String {
        "\(status.year)년 \(status.month + 1)월 \(status.dayOfMonth + 1)일"
    }

    func update(dt: Double, viewSize: CGSize) {
        recordDiagnosticContext()
        self.viewSize = viewSize
        clock += dt
        if voyage.pendingBattle != nil && encounter == nil && battle == nil && session == nil && interaction.canPresentEncounter {
            let e = voyage.pendingBattle!
            encounter = (e, voyage.opening(e))
            status = voyage
        }
        if interaction.sailingTimeAllowed {
            let k = { (c: UInt16) in self.held.contains(c) }
            let turn = (k(KeyCode.right) || k(KeyCode.d) ? 1.0 : 0) - (k(KeyCode.left) || k(KeyCode.a) ? 1.0 : 0)
            observe(.advance(dt: dt, turn: turn, secondsPerDay: Voyage.secondsPerDay)) { v in
                if turn != 0 { v.steer(turn * 1.6 * dt) }
                v.tick(dt, in: world)
                return "applied"
            }
            if let t = voyage.seaAlarms.first {
                voyage.seaAlarms.removeFirst()
                seaEvent = [message(1176), message(510 + 2 * t), message(511 + 2 * t)]
                sfx.play("sea_event")                                              // two blasts (0x30615)
                status = voyage
            }
            if voyage.day != lastDay {
                lastDay = voyage.day
                runScripts(key1: ScriptKey.atSea, key2: voyage.daysAtSea, port: nil, contexts: [.hero])
            }
        }
        // The original layout shows 24×24 tiles in the map window at (96, 8), 16 dots a tile; the
        // window scrolls a tile at a time as the fleet leaves its dead zone (seamap.md §6). The
        // screen's centre is two tiles right of the window's.
        let classicSea = classicLayout && harbor == nil && !title
        var target = (x: voyage.x, y: voyage.y)
        if classicSea {
            zoom = 16 * classicScale
            let o = World.seaViewOrigin(from: seaOrigin, fleetX: voyage.x, fleetY: voyage.y, margin: voyage.memory[0xC35])
            seaOrigin = o
            target = (world.wrapX(Double(o.x) + 14), Double(o.y) + 12 - Double(Game.titleInset) / 2 / zoom)
        } else {
            seaOrigin = nil
        }
        let dx = world.deltaX(from: camera.x, to: target.x)
        let follow = min(1, dt * (classicSea ? 8 : 3.5))
        camera.x = world.wrapX(camera.x + dx * follow)
        camera.y += (target.y - camera.y) * follow
        let halfHeight = viewSize.height / 2 / zoom, fullHeight = Double(World.height)
        if !classicSea {
            camera.y = halfHeight * 2 >= fullHeight ? fullHeight / 2 : max(halfHeight, min(fullHeight - halfHeight, camera.y))
        }

        if voyage.log.count > 0 {
            notice = voyage.log.removeLast()
            voyage.log.removeAll()
            noticeClock = 4
        } else if noticeClock > 0 && harbor == nil {
            noticeClock -= dt
            if noticeClock <= 0 { notice = nil }
        }

        if interaction.townTimeAllowed {
            // One pass of the walk loop (0x1B337): at least 8 timer units, 4 without 표시효과.
            walkClock += dt
            if walkClock >= townStepTime {
                walkClock = 0
                townPass()
            }
        }

        let storm = voyage.event == .storm && voyage.eventAnnounced
        if storm && !stormSeen && harbor == nil {
            stormPicture = true
            let generation = presentationGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.presentationGeneration == generation else { return }
                self.stormPicture = false
            }
        }
        stormSeen = storm
        for cue in voyage.soundCues { sfx.play(cue, cut: cue == "level_up" ? 20 / 60.3 : nil) }
        voyage.soundCues.removeAll()
        // The storm voice, held at sea for the whole storm; music off silences it too (0x20DDA).
        sfx.storm(voyage.event == .storm && voyage.eventAnnounced && harbor == nil && battle == nil && encounter == nil
                  && !title && voyage.memory[0xC30] & 4 != 0)

        hudClock += dt
        if hudClock > 0.2 {
            hudClock = 0
            status = voyage
            music.play(sceneMusic)
            let near = harbor == nil ? world.nearestPort(x: voyage.x, y: voyage.y, within: 7) : nil
            if near != dockable { dockable = near }
        }
    }

    /// Shared policy for keyboard, pointer/AX surfaces, the simulation clock and save commands.
    var interaction: InteractionPolicy {
        var layers = Set<InteractionPolicy.Layer>()
        if harbor != nil && panel != nil { layers.insert(.service) }
        if showFleet { layers.insert(.fleet) }
        if showRules { layers.insert(.rules) }
        if showDiagnostics { layers.insert(.diagnostics) }
        if showVoyagePlan { layers.insert(.voyagePlan) }
        if landing != nil { layers.insert(.landing) }
        if coast != nil { layers.insert(.coast) }
        if seaEvent != nil { layers.insert(.seaEvent) }
        if battle != nil { layers.insert(.battle) }
        if battle?.phase == .duel { layers.insert(.duel) }
        if encounter != nil { layers.insert(.encounter) }
        if battleResult != nil { layers.insert(.battleResult) }
        if tabMenu != nil { layers.insert(.tabs) }
        if command != nil { layers.insert(.command) }
        if info != nil { layers.insert(.information) }
        if session != nil { layers.insert(.dialogue) }
        if portMessageText != nil && session == nil { layers.insert(.message) }
        if title { layers.insert(.title) }
        if endingCode != nil { layers.insert(.ending) }
        if opening { layers.insert(.opening) }
        if status.gameOver != nil { layers.insert(.gameOver) }
        if slotMode != nil { layers.insert(.slots) }
        if question != nil { layers.insert(.confirmation) }
        if transitioning { layers.insert(.transition) }
        return InteractionPolicy(layers: layers, inHarbor: harbor != nil, paused: paused,
                                 hasPendingEncounter: voyage.pendingBattle != nil,
                                 allowsSavingFromCommand: command == .system)
    }

    var keysDriveGame: Bool { interaction.worldInputAllowed }

    #if os(macOS)
    /// A key from anywhere in the window (the monitor below, or the map view itself): held keys
    /// steer and walk whatever control has the focus. Returns whether the game took it.
    @discardableResult
    func handleKey(_ e: NSEvent) -> Bool {
        if e.type == .keyUp {
            held.remove(e.keyCode)
            return false
        }
        guard e.type == .keyDown, e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        // The topmost confirmation owns Return/Escape even when a dialogue or text
        // field was previously focused underneath the custom large-type panel.
        if let q = question, interaction.allows(.confirmation), [KeyCode.returnKey, 53].contains(e.keyCode) {
            if !e.isARepeat {
                answerQuestion(q.id, accepting: e.keyCode == KeyCode.returnKey)
            }
            return true
        }
        // Dialogue owns these keys even after a SwiftUI button has taken keyboard focus.
        if interaction.allows(.dialogue), let prompt = session?.prompt {
            var answer: Int?
            switch prompt {
            case .next:
                if [KeyCode.returnKey, KeyCode.space, KeyCode.e].contains(e.keyCode) { answer = 0 }
            case .yesNo:
                if e.keyCode == KeyCode.returnKey { answer = 1 }
                if e.keyCode == 53 { answer = 0 }
            case .menu(let choices):
                if let key = e.charactersIgnoringModifiers, let n = Int(key), n > 0 && n <= choices.count { answer = n - 1 }
            default: break
            }
            if let answer {
                if !e.isARepeat { held.removeAll(); townAim = nil; scriptAnswer(answer) }
                return true
            }
        }
        if interaction.allows(.message) {
            if [KeyCode.returnKey, KeyCode.space, KeyCode.e, 53].contains(e.keyCode) {
                if !e.isARepeat { dismissTownMessage() }
                return true
            }
            if KeyCode.game.contains(e.keyCode) { return true }
        }
        if let t = KeyCode.tabs[e.keyCode], keysDriveGame || interaction.allows(.tabs) {
            if !e.isARepeat { tabMenu = tabMenu == t ? nil : t }
            return true
        }
        guard keysDriveGame, KeyCode.game.contains(e.keyCode) else { return false }
        if harbor != nil, !e.isARepeat {
            switch e.keyCode {
            case KeyCode.up, KeyCode.w, KeyCode.pad8: townTap = 0
            case KeyCode.right, KeyCode.d, KeyCode.pad6: townTap = 1
            case KeyCode.down, KeyCode.s, KeyCode.pad2: townTap = 2
            case KeyCode.left, KeyCode.a, KeyCode.pad4: townTap = 3
            default: break
            }
        }
        held.insert(e.keyCode)
        if !e.isARepeat { pressed(e.keyCode) }
        return true
    }

    /// Listens to the whole window, so the arrows and WASD work after a click on a button too;
    /// text fields keep their keys. Held keys are dropped when the app loses the focus.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            guard let self else { return e }
            guard let window = e.window ?? NSApp.keyWindow, self.inputWindows.contains(window) else { return e }
            if e.type == .keyDown, let t = e.window?.firstResponder as? NSTextView, t.isEditable { return e }
            return self.handleKey(e) ? nil : e
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.held.removeAll()
                self?.townAim = nil
            }
        }
    }
    #else
    func installKeyMonitor() {}
    #endif

    func pressed(_ code: UInt16) {
        // The four tabs (0x20A8A: F1–F4 → / * + =, keypad - → +), at sea and in town.
        if let t = KeyCode.tabs[code], keysDriveGame || interaction.allows(.tabs) {
            tabMenu = tabMenu == t ? nil : t
            return
        }
        guard keysDriveGame else { return }
        if harbor != nil { return }                                    // in town the keys walk
        switch code {
        case KeyCode.up, KeyCode.w: observe(.sail(1)) { $0.setSail(1); return "applied" }
        case KeyCode.down, KeyCode.s: observe(.sail(-1)) { $0.setSail(-1); return "applied" }
        case KeyCode.space: paused.toggle()
        case KeyCode.returnKey, KeyCode.e: dock()
        case KeyCode.plus: setZoom(zoom * 1.25)
        case KeyCode.minus: setZoom(zoom / 1.25)
        case KeyCode.h: showHelp.toggle()
        case KeyCode.i: showFleet.toggle()
        default: break
        }
    }

    func setZoom(_ z: Double) {
        guard !(classicLayout && harbor == nil) else { return }                // fixed in the original layout
        zoom = max(viewSize.height / Double(World.height), min(26, z))
    }

    func tileAt(viewPoint p: CGPoint) -> (x: Double, y: Double) {
        (world.wrapX(camera.x + (p.x - viewSize.width / 2) / zoom),
         camera.y + (p.y - viewSize.height / 2) / zoom)
    }

    func click(_ p: CGPoint) {
        guard harbor == nil, keysDriveGame else { return }
        if classicLayout && !classicMapRect.contains(p) { return }               // the panels, not the sea
        let t = tileAt(viewPoint: p)
        guard observe(.course(x: t.x, y: t.y), { $0.setSeaCourse(x: t.x, y: t.y, in: world) ? "accepted" : "rejected" }) == "accepted" else {
            say(world.isSea(x: t.x, y: t.y) ? "이 지점까지 항로를 찾지 못했습니다. 가까운 바다를 선택해 주세요." : "바다 위의 목적지를 선택해 주세요.")
            return
        }
        plannedPortID = nil
        status = voyage
    }

    func dock() {
        guard let p = dockable else { return }
        plannedPortID = nil
        voyage.arrive(at: p, in: world)
        status = voyage
        dockable = nil
        harbor = p
    }

    /// Leaving needs at least one sailor aboard.
    @discardableResult
    func setSail() -> Bool {
        guard voyage.crew > 0 else {
            notice = "선원이 한 사람도 없습니다. 주점에서 선원을 모으십시오."
            noticeClock = 4
            return false
        }
        if let h = harbor { voyage.logDeparture(from: h.id) }
        voyage.leaveTown()
        harbor = nil
        panel = nil
        tavern = nil
        status = voyage
        return true
    }

    var market: Market { voyage.market(in: world) }

    /// Entering a building takes an hour and runs its scripts first (0x1B08E). A script
    /// may keep the player outside; otherwise the building opens.
    func open(_ p: HarborPanel) {
        guard session == nil, let h = harbor else { return }
        if p == .tavern {
            tavern = Tavern(market: market, drinks: world.navigation.drinks, charm: voyage.captain.charm)
        }
        guard h.id < 100 || p == .harbor else { return }
        guard p.isOpen(tick: voyage.tick) else {
            townMessage = message(765)                                           // 문이 잠겨 있습니다.
            return
        }
        voyage.passTime(ticks: voyage.rng(3) + 2, in: world)                     // 0x1B150
        panel = nil
        sessionBuilding = p
        runScripts(key1: h.id, key2: p.rawValue, port: h.id)
    }

    func runScripts(key1: Int, key2: Int, port: Int?, contexts: [ScriptContext] = [.shared, .hero]) {
        var s = ScriptSession(key1: key1, key2: key2, port: port, contexts: contexts)
        s.advance(&voyage, in: world)
        session = s
        status = voyage
        closeSession()
    }

    private var lastSession: ScriptSession?

    // MARK: sea battles

    /// MESSAGE.DAT line with its %s filled in order.
    func fill(_ n: Int, _ args: String...) -> String {
        var t = message(n)
        for a in args {
            guard let r = t.range(of: "%-?[0-9]*l?[sdu]", options: .regularExpression) else { break }
            t.replaceSubrange(r, with: a)
        }
        return Korean.particles(t)
    }

    func itemName(_ id: Int) -> String { voyage.memory.string(0x8144 + 26 * id, max: 21) }

    /// The battle-start scripts may take over or call the battle off (event 0xA1, v60).
    func startBattle() {
        guard let (e, _) = encounter else { return }
        let enemy = e.attacker == voyage.heroID ? e.defender : e.attacker
        for ctx in [ScriptContext.hero, .shared] { voyage.memory.setWord(ctx.base + 0xA + 2 * 60, enemy) }
        afterScripts = { [weak self] in
            guard let self else { return }
            if self.lastSession?.leave == true {
                self.voyage.pendingBattle = nil
                self.encounter = nil
                self.status = self.voyage
                return
            }
            self.encounter = nil
            self.battle = self.voyage.beginBattle(e, in: self.world)
            if self.battle == nil { self.voyage.pendingBattle = nil }
            self.checkBattleOver()
            self.status = self.voyage
        }
        runScripts(key1: ScriptKey.battleStart, key2: enemy, port: nil, contexts: [.hero, .shared])
    }

    func flee() {
        if voyage.tryToFlee() {
            say(message(822))
            voyage.pendingBattle = nil
            encounter = nil
        } else {
            say(message(824))
            startBattle()
        }
        status = voyage
    }

    func surrender() {
        guard let (e, _) = encounter else { return }
        let pirate = voyage.memory.fleetOf(person: e.attacker) / 10 == 6
        say(message(voyage.surrender(toPirates: pirate)))
        let f = voyage.memory.fleetOf(person: e.attacker)
        if f < Fleets.count { voyage.sendToPort(f, mission: 0, port: voyage.memory.fb(f, FleetField.home)) }
        voyage.pendingBattle = nil
        encounter = nil
        status = voyage
    }

    /// The merchant pays up (815): code 2, pirate fame only — the original hands over nothing.
    func acceptMerchantOffer() {
        guard let (e, _) = encounter else { return }
        voyage.exportToMemory(port: nil)
        if var b = Battle(attacker: e.attacker, defender: e.defender, voyage: &voyage, world: world) {
            b.endCode = 2
            b.phase = .over
            battle = b
        }
        encounter = nil
        checkBattleOver()
    }

    func battleMove(_ x: Int, _ y: Int) { mutateBattle { b, v in b.playerMove(to: x, y, v) } }
    func battleTurn(_ d: Int) { mutateBattle { b, _ in b.playerTurn(d) } }
    func battleSignal(attack: Bool? = nil, gather: Bool? = nil) { mutateBattle { b, _ in b.signal(gather: gather, attack: attack) } }
    func battleOrder(_ k: Int, attack: Bool? = nil, gunnery: Bool? = nil, target: Int?? = nil) {
        mutateBattle { b, _ in b.order(k, attack: attack, gunnery: gunnery, target: target) }
    }
    func battlePass() { mutateBattle { b, v in b.endTurn(&v, world: self.world) } }
    func battleLeave() { mutateBattle { b, v in b.playerLeave(&v, world: self.world) } }
    func battleAttack(_ j: Int, challenge: Bool) { mutateBattle { b, v in b.playerAttack(j, challenge: challenge, &v, world: self.world) } }
    func duelMove(_ m: Int) { mutateBattle { b, v in b.duelMove(m, &v, world: self.world) } }

    private func mutateBattle(_ f: (inout Battle, inout Voyage) -> Void) {
        guard var b = battle,
              (b.phase == .command && interaction.allows(.battle)) ||
              (b.phase == .duel && interaction.allows(.duel)) else { return }
        diagnosticEvent("battle-command")
        let before = b.lastStrike?.serial
        f(&b, &voyage)
        battle = b
        if let s = b.lastStrike, s.serial != before {
            if s.boarding {
                sfx.play("boarding", cut: 48 / 60.3)                                // 0xCFF2, muted at 0xD0D9
            } else {
                sfx.play("cannon")                                                 // the shot leaves (0xC636)
                sfx.play("cannon", after: 0.35)                                    // and lands (0xCB72)
            }
        }
        checkBattleOver()
        status = voyage
    }

    private func checkBattleOver() {
        guard var b = battle, b.phase == .over, battleResult == nil else { return }
        battleResult = voyage.finishBattle(&b, in: world)
        battle = b
        status = voyage
    }

    /// Closes the result screen: prizes join, then the battle-end scripts run (event 0xA2).
    func closeBattle(taking picks: [Int]) {
        guard interaction.allows(.battleResult), let b = battle, let result = battleResult else { return }
        diagnosticEvent("battle-result:\(picks.sorted())")
        let selected = Array(Set(picks).intersection(result.capturable)).sorted().prefix(max(0, result.mayTake))
        if !selected.isEmpty { voyage.takePrizes(Array(selected), from: b, names: [], in: world) }
        let enemy = b.admirals[b.units[b.sides[0][0]].fleet == voyage.playerFleet ? 1 : 0] ?? 0xFF
        battle = nil
        battleResult = nil
        fanfareDone = false
        voyage.pendingBattle = nil
        status = voyage
        runScripts(key1: ScriptKey.battleEnd, key2: enemy, port: nil, contexts: [.shared, .hero])
    }

    /// The debtor's or the informant's scene when the player picks that person (§1.5 hooks).
    /// Returns true when it took the place of the normal talk.
    @discardableResult
    func patronScene(_ p: Int, treat: Bool = false) -> Bool {
        switch voyage.patronHook(person: p, treat: treat) {
        case .debtor?:
            let r = act { $0.meetDebtor() }
            say(townText(r.lines).joined(separator: "\n"))
            return true
        case .mapSeller?:
            let offer = voyage.mapOffer(in: world)
            let text = townText(offer.lines).joined(separator: "\n")
            if offer.forSale {
                question = Question(text: text, yes: "산다") { [weak self] in
                    guard let self else { return }
                    self.say(self.townText(self.act { $0.buyMap() }).joined(separator: "\n"))
                }
            } else {
                say(text)
            }
            return true
        case nil:
            return false
        }
    }

    func hailFleet(_ f: Int) {
        if patronScene(voyage.memory.fb(f, FleetField.admiral)) { return }       // 0x1FABD → 0x25AE0
        let (line, attacks) = voyage.hail(f)
        let m = voyage.memory
        let target = m.fb(f, FleetField.target)
        var text = message(line)
        if [153, 154].contains(line), target < 130 { text = fill(line, m.string(DS.port + DS.portSize * target + 4, max: 14)) }
        if line == 157, target < 120 {
            text = fill(line, ["포르투갈", "에스파니아", "투르크", "잉글랜드", "이탈리아", "네덜란드", "해적"][min(6, m.fleetOf(person: target) / 10)], m.person(target).name)
        }
        say(text)
        if attacks { voyage.pendingBattle = Encounter(attacker: m.fb(f, FleetField.admiral), defender: voyage.heroID) }
        status = voyage
    }

    func attackFleet(_ f: Int) {
        guard (15..<60).contains(voyage.tick) else {
            say(message(781))
            return
        }
        _ = voyage.attack(f)
        status = voyage
    }

    /// The player's answer to a script prompt.
    func scriptAnswer(_ value: Int) {
        guard interaction.allows(.dialogue), var s = session else { return }
        diagnosticEvent("script-answer:\(value)")
        s.answer(value, &voyage, in: world)
        session = s
        status = voyage
        closeSession()
    }

    private func closeSession() {
        guard let s = session, s.done else { return }
        session = nil
        if let next = afterScripts {
            afterScripts = nil
            lastSession = s
            next()
        }
        if let code = s.ending { endingCode = code }
        if let b = sessionBuilding {
            // The inn always opens (0x1B1B2); then the town's own checks: arrests, the palace door.
            panel = (s.leave && b != .inn) || !enterTown(b) ? nil : b
            messageBuilding = panel == nil && portMessageText != nil ? b : nil
            sessionBuilding = nil
            if panel == .harbor { act { $0.harbourDropsGuards() } }
            if panel == .harbor, let h = harbor, h.id < 100 {
                // The rumour of a summons, then the greeting (msg 56).
                say((voyage.harbourRumour(port: h.id, in: world).map { $0 + "\n" } ?? "") + message(56))
                askDeserters(voyage.desertersAtHarbour())
            }
        }
        status = voyage
    }

    @discardableResult
    func treat(bottles n: Int) -> Bool {
        guard var t = tavern, n > 0, n <= t.bottlesAffordable(gold: voyage.gold) else { return false }
        _ = voyage.pay(t.treat(bottles: n, charm: voyage.captain.charm))
        tavern = t
        let talk = townText(voyage.tavernTreatTalk() + (voyage.tavernJobHint(in: world) ?? []))
        if !talk.isEmpty { say(talk.joined(separator: "\n")) }
        status = voyage
        return true
    }

    @discardableResult
    func hire(_ n: Int) -> Bool {
        guard let t = tavern, voyage.hireCrew(n, at: t) else { return false }      // once a day
        status = voyage
        return true
    }

    @discardableResult
    func buy(_ o: Offer, amount: Int, ship: Int = 0, unitPrice: Int? = nil) -> Bool {
        guard interaction.allows(.service), panel == .market else { return false }
        guard observe(.buy(good: o.good, basePrice: o.basePrice, amount: amount, ship: ship, unitPrice: unitPrice), {
            $0.buy(o, amount: amount, ship: ship, in: world, unitPrice: unitPrice) ? "accepted" : "rejected"
        }) == "accepted" else { return false }
        status = voyage
        return true
    }

    @discardableResult
    func sell(hold: Int, amount: Int, ship: Int = 0) -> Bool {
        guard interaction.allows(.service), panel == .market else { return false }
        guard observe(.sell(hold: hold, amount: amount, ship: ship), {
            $0.sell(hold: hold, amount: amount, ship: ship, in: world) ? "accepted" : "rejected"
        }) == "accepted" else { return false }
        status = voyage
        return true
    }

    func buyShip(slot: Int, offer: Int, tradeIn: Int?, name: String) -> ShipDeal {
        let r = voyage.buyShip(slot: slot, offer: offer, tradeIn: tradeIn, name: name, in: world)
        status = voyage
        return r
    }

    func sellShip(_ i: Int) -> ShipDeal {
        let r = voyage.sellShip(i, in: world)
        status = voyage
        return r
    }

    @discardableResult
    func buyCannons(_ type: Int, count: Int, ship: Int) -> Bool {
        guard voyage.buyCannons(type, count: count, ship: ship, in: world) else { return false }
        status = voyage
        return true
    }

    @discardableResult
    func repair(_ i: Int) -> Bool {
        guard observe(.repair(ship: i), { $0.repair(i, in: world) ? "accepted" : "rejected" }) == "accepted" else { return false }
        status = voyage
        return true
    }

    /// Opens the slot window (0x16328): "Ｓａｖｅ Ｄａｔａ" or "Ｌｏａｄ Ｄａｔａ".
    func save() {
        guard interaction.canOpenSave else {
            saveError = interaction.saveBlockReason ?? "열려 있는 확인창을 닫은 뒤 저장해 주세요."
            return
        }
        saveError = nil
        held.removeAll()
        townAim = nil
        slotMode = .save
    }

    func load() {
        guard interaction.canOpenLoad else { return }
        saveError = nil
        held.removeAll()
        townAim = nil
        slotMode = .load
    }

    /// 저장 (0x1661A) into one of the ten slots.
    @discardableResult
    func save(slot: Int, ending: Bool = false) -> Bool {
        saveError = nil
        guard interaction.canStoreVoyage, slotMode != .load else {
            saveError = interaction.saveBlockReason ?? "불러오기 창을 닫은 뒤 저장해 주세요."
            return false
        }
        do {
            // A save made in port marks the town (0x170C7) so loading it keeps everyone in place.
            var copy = voyage
            if harbor != nil { copy.memory[0xC3B] = 0x82 }
            copy.saveContext.contentRevision = world.contentRevision
            try SaveGame.write(copy, slot: slot, port: harbor.map { portName($0.id) }, ending: ending)
            say("저장했습니다.")
            return true
        } catch {
            saveError = "저장하지 못했습니다.\n\(error.localizedDescription)"
            diagnosticEvent("save-failed")
            return false
        }
    }

    /// 로드 (0x16469) from a slot, with the story fix-up (0x16588).
    func load(slot: Int, recovery: Bool = false) {
        saveError = nil
        do {
            let v = try SaveGame.read(slot: slot, recovery: recovery)
            let slotInfo = SaveGame.inspect(slot)
            let savedPort = (recovery ? slotInfo.backupHeader : slotInfo.header)?.port
            // Prepare everything that can fail before replacing the active session.
            let destination = savedPort != nil ? world.ports.first(where: {
                let name = v.memory.string(DS.port + DS.portSize * $0.id + 4, max: 14)
                return (name.isEmpty ? $0.name : name) == savedPort
            })
                ?? world.nearestPort(x: v.x, y: v.y, within: 7) : nil
            transitioning = true
            defer { transitioning = false }
            resetPresentation()
            loaded = true
            voyage = v
            status = v
            camera = (v.x, v.y)
            panel = nil
            tavern = nil
            // A save made in port reopens the harbour screen.
            harbor = destination
            say(recovery ? "이전 정상 저장을 불러왔습니다. 현재 파일은 덮어쓰지 않았습니다." : "불러왔습니다.")
            title = false
            applyEnvironment()
        } catch {
            saveError = "불러오지 못했습니다.\n\(error.localizedDescription)"
            diagnosticEvent("load-failed")
        }
    }

    /// A new game with hero `h` from the select screen (0x168C0 → 0x1626B).
    func startNewGame(hero h: Int, given: String? = nil, family: String? = nil) {
        do { try newGameRules.validate() } catch { rulesError = error.localizedDescription; return }
        guard world.navigation.newGame.heroes.indices.contains(h) else {
            say("선택한 주인공 자료가 없습니다. 현재 항해를 유지합니다.")
            return
        }
        let options = voyage.memory[0xC30], speed = voyage.memory[0xC32]
        var next = Voyage.newGame(in: world, hero: h, given: given, family: family,
                                  seed: UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000)))
        guard world.ports.indices.contains(next.marketIndex) else {
            say("시작 항구 자료가 올바르지 않습니다. 현재 항해를 유지합니다.")
            return
        }
        next.memory[0xC30] = options
        next.memory[0xC32] = speed
        next.saveContext.rules = newGameRules
        next.saveContext.contentRevision = world.contentRevision
        transitioning = true
        defer { transitioning = false }
        resetPresentation()
        voyage = next
        loaded = false
        status = voyage
        camera = (voyage.x, voyage.y)
        harbor = world.ports[voyage.marketIndex]
        panel = nil
        tavern = nil
        session = nil
        endingCode = nil
        title = false
        applyEnvironment()
    }

    /// `[0xC30]` bit 0x04 is the music, `[0xC32]` the sea speed 0...10 (default 5).
    func applyEnvironment() {
        music.enabled = voyage.memory[0xC30] & 4 != 0 && ProcessInfo.processInfo.environment["PORTOLAN_SNAPSHOT"] == nil
        sfx.enabled = voyage.memory[0xC30] & 8 != 0 && ProcessInfo.processInfo.environment["PORTOLAN_SNAPSHOT"] == nil
        if !sfx.enabled { sfx.stopAll() }
        if !music.enabled { music.play(nil) }
        Voyage.secondsPerDay = 1.2 + 0.24 * Double(voyage.memory[0xC32])
    }

    func setOption(_ bit: Int, _ on: Bool) {
        voyage.memory[0xC30] = on ? voyage.memory[0xC30] | bit : voyage.memory[0xC30] & ~bit
        status = voyage
        applyEnvironment()
    }

    /// 해상이동치 `[0xC35]`: the sea view's dead zone, 0..10 tiles.
    func setScrollMargin(_ v: Int) {
        voyage.memory[0xC35] = max(0, min(10, v))
        status = voyage
    }

    func setSeaSpeed(_ v: Int) {
        voyage.memory[0xC32] = max(0, min(10, v))
        status = voyage
        applyEnvironment()
    }

    /// Back to the title menu.
    func newGame() {
        let next = Voyage.newGame(in: world)
        guard world.ports.indices.contains(next.marketIndex) else {
            say("시작 항구 자료가 올바르지 않습니다. 현재 항해를 유지합니다.")
            return
        }
        transitioning = true
        defer { transitioning = false }
        resetPresentation()
        title = true
        voyage = next
        loaded = false
        session = nil
        endingCode = nil
        status = voyage
        camera = (voyage.x, voyage.y)
        harbor = world.ports[next.marketIndex]
        panel = nil
        tavern = nil
    }

    /// Modal state belongs to a session, never to the next loaded or newly started voyage.
    func resetPresentation() {
        diagnosticEvent("presentation-reset")
        presentationGeneration &+= 1
        showDiagnostics = false
        showRules = false
        rulesError = nil
        held.removeAll()
        townAim = nil
        townMessage = nil
        townBefore = nil
        townWaiting = false
        walkClock = 0
        paused = false
        showFleet = false
        showVoyagePlan = false
        plannedPortID = nil
        encounter = nil
        battle = nil
        battleResult = nil
        landing = nil
        coast = nil
        command = nil
        info = nil
        tabMenu = nil
        slotMode = nil
        saveError = nil
        question = nil
        seaEvent = nil
        session = nil
        sessionBuilding = nil
        messageBuilding = nil
        afterScripts = nil
        lastSession = nil
        endingCode = nil
        opening = false
        stormPicture = false
        stormSeen = false
        notice = nil
        noticeClock = 0
        dockable = nil
        seaOrigin = nil
        lastDay = 0
    }

    /// Runs a change on the voyage and publishes the result.
    @discardableResult
    func act<T>(label: String = #function, _ change: (inout Voyage) -> T) -> T {
        diagnosticEvent("mutation:\(label)")
        let r = change(&voyage)
        status = voyage
        return r
    }

    func say(_ s: String) {
        notice = s
        noticeClock = 4
        if harbor != nil { held.removeAll(); townAim = nil }
    }

    /// A stale native/SwiftUI button must not resolve a newer question underneath it.
    func answerQuestion(_ id: UUID, accepting: Bool) {
        guard interaction.allows(.confirmation), let current = question, current.id == id else { return }
        question = nil
        if accepting { current.action() } else { current.refuse() }
    }

    /// Town speech and service replies are readable, acknowledged messages above the whole UI.
    var portMessageText: String? {
        guard harbor != nil, !title, !opening else { return nil }
        for text in [townMessage, notice] {
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    func dismissTownMessage() {
        if let text = townMessage, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            townMessage = nil
        } else {
            notice = nil
            noticeClock = 0
        }
        townWaiting = false
        held.removeAll()
        townAim = nil
        if portMessageText == nil { messageBuilding = nil }
    }

    func offerTerms(to p: Int) -> OfficerOffer {
        let r = voyage.offerTerms(to: p, in: world)
        status = voyage
        return r
    }

    func hireOfficer(_ p: Int, salary: Int) {
        voyage.hireOfficer(p, salary: salary, in: world)
        status = voyage
    }

    func dismissOfficer(_ k: Int) {
        voyage.dismissOfficer(k)
        status = voyage
    }

    /// MESSAGE.DAT lines, for the original shopkeepers' remarks.
    lazy var messages: [String] = {
        struct Text: Decodable { let message: [String] }
        guard let d = try? Data(contentsOf: assets.appendingPathComponent("text.json")),
              let t = try? JSONDecoder().decode(Text.self, from: d) else { return [] }
        return t.message
    }()

    func message(_ i: Int) -> String { messages.indices.contains(i) ? messages[i] : "" }

    /// ITEM.MES: one description per item id (0x28C9A).
    lazy var itemTexts: [String] = {
        struct Text: Decodable { let items: [String] }
        guard let d = try? Data(contentsOf: assets.appendingPathComponent("text.json")),
              let t = try? JSONDecoder().decode(Text.self, from: d) else { return [] }
        return t.items
    }()

    /// MENU.DAT items.
    lazy var menus: [[String]] = {
        struct Text: Decodable { let menus: [[String]] }
        guard let d = try? Data(contentsOf: assets.appendingPathComponent("text.json")),
              let t = try? JSONDecoder().decode(Text.self, from: d) else { return [] }
        return t.menus
    }()

    func menu(_ n: Int, _ i: Int) -> String { menus.indices.contains(n) && menus[n].indices.contains(i) ? menus[n][i] : "" }

    @discardableResult
    func buy(_ s: Supply, barrels: Int, ship: Int = 0) -> Bool {
        let currentMarket = market
        guard observe(.supply(kind: s.rawValue, barrels: barrels, ship: ship), {
            $0.buy(s, barrels: barrels, ship: ship, at: currentMarket) ? "accepted" : "rejected"
        }) == "accepted" else { return false }
        status = voyage
        return true
    }
}

/// Town buildings, numbered as the scripts know them (door table DS:0x88C). The harbour (3)
/// is the quay: supplies and departure.
enum HarborPanel: Int, CaseIterable {
    case market, tavern, shipyard, harbor, inn, palace, guild, residence, bank, itemShop, church, fortuneTeller

    /// Opening hours in ticks of the day (0x1B0C1; 3 ticks an hour).
    func isOpen(tick t: Int) -> Bool {
        switch self {
        case .market, .shipyard, .palace, .guild, .bank: return (12...59).contains(t)
        case .tavern: return !(12...23).contains(t)
        case .itemShop: return (24...59).contains(t) || (6...8).contains(t)
        case .church: return (12...71).contains(t)
        case .fortuneTeller: return (48...71).contains(t)
        case .harbor, .inn, .residence: return true
        }
    }

    var title: String {
        ["교역소", "주점", "조선소", "항구", "여관", "왕궁", "조합", "저택", "은행", "아이템", "교회", "점술가"][rawValue]
    }
}

enum KeyCode {
    static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, h: UInt16 = 4, i: UInt16 = 34
    static let w: UInt16 = 13, e: UInt16 = 14, plus: UInt16 = 24, minus: UInt16 = 27
    static let returnKey: UInt16 = 36, space: UInt16 = 49
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    static let pad2: UInt16 = 84, pad4: UInt16 = 86, pad6: UInt16 = 88, pad8: UInt16 = 91
    static let tabs: [UInt16: Int] = [122: 0, 120: 1, 99: 2, 118: 3, 75: 0, 67: 1, 78: 2, 69: 3]
    /// The keys the game itself uses while sailing or walking.
    static let game: Set<UInt16> = [a, s, d, w, e, h, i, plus, minus, returnKey, space, left, right, down, up, pad2, pad4, pad6, pad8]
}

/// A yes/no question shown in the large-type confirmation panel.
struct Question {
    let id = UUID()
    let text: String
    var yes = "예"
    var no = "아니오"
    let action: () -> Void
    var refuse: () -> Void = {}
}

extension Game {
    /// The harbour office's 출항 (0x273DA): the departure estimate first.
    func depart() {
        guard voyage.crew > 0 else {
            say("선원이 한 사람도 없습니다. 주점에서 선원을 모으십시오.")
            return
        }
        let c = voyage.departureCheck()
        guard c.ok else {
            say(c.line)
            return
        }
        question = Question(text: c.line, yes: "출항") { [weak self] in self?.setSail() }
    }

    /// 상륙 (0x34651): a sighted village, a port (기항), open coast, or msg 441.
    func goAshore() {
        if let t = voyage.landedAt, voyage.ashore {
            coast = CoastLanding(x: t[0], y: t[1], water: act { $0.landOnCoast(at: (t[0], t[1])) })
            return
        }
        if let s = voyage.landingSite {
            landing = s
            return
        }
        if dockable != nil {
            dock()
            return
        }
        guard let t = voyage.coastTile(in: world) else {
            say(message(441))
            return
        }
        question = Question(text: message(440)) { [weak self] in
            guard let self else { return }
            self.coast = CoastLanding(x: t.0, y: t.1, water: self.act { $0.landOnCoast(at: t) })
        }
    }

    /// Companions who want to stay in this port (0x280A3, msgs 798–801); a no lets them go.
    func askDeserters(_ list: [Int]) {
        guard let k = list.last else { return }
        let o = voyage.officers[k]
        let rest = Array(list.dropLast())
        question = Question(
            text: "\(o.name): \(message(798))\n\(fill(801, "\(o.salary + 10)"))",
            yes: "붙든다", no: "보낸다",
            action: { [weak self] in
                self?.act { $0.keepOfficer(k) }
                self?.askDeserters(rest)
            },
            refuse: { [weak self] in
                self?.dismissOfficer(k)
                self?.askDeserters(rest)
            })
    }

    /// A port's name as the hero knows it: supply ports can be renamed (명명).
    func portName(_ p: Int) -> String {
        let n = status.memory.string(DS.port + DS.portSize * p + 4, max: 14)
        return n.isEmpty ? world.ports[p].name : n
    }
}

extension Game {
    /// After END.EXE (MAIN 0x17032): the game is saved as post-ending data with story mode
    /// off (`[0xC30]` bit 0x02; bit 0x40 kept only after the duke ending), then the title.
    func finishEnding() {
        guard let code = endingCode else { return }
        voyage.memory[0xC30] &= ~0x02
        if code != 0x0F { voyage.memory[0xC30] &= ~0x40 }
        voyage.storyOn = false
        endingCode = nil
        slotMode = .ending                                 // msg 746, then the slot window
    }

    /// After the ending save (or skipping it), back to the title.
    func endingSaved() {
        newGame()
    }
}

extension Game {
    /// Town entry (0x8AB2) whenever the harbour screen comes up.
    func syncTown() {
        guard let h = harbor, let m = world.town(h.id) else { return }
        voyage.arriveInTown(port: h.id, map: m)
        townBefore = nil
        townFace = 2
        townMessage = nil
        status = voyage
    }

    /// The direction asked for: arrows, WASD or the numeric keypad, else the mouse or compass.
    private var townHeld: Int? {
        let k = { (c: UInt16) in self.held.contains(c) }
        if k(KeyCode.up) || k(KeyCode.w) || k(KeyCode.pad8) { _townTap = nil; return 0 }
        if k(KeyCode.right) || k(KeyCode.d) || k(KeyCode.pad6) { _townTap = nil; return 1 }
        if k(KeyCode.down) || k(KeyCode.s) || k(KeyCode.pad2) { _townTap = nil; return 2 }
        if k(KeyCode.left) || k(KeyCode.a) || k(KeyCode.pad4) { _townTap = nil; return 3 }
        if let d = townTap { townTap = nil; return d }          // a tap shorter than one pass still steps
        return townAim
    }

    /// A direction key pressed and released between two passes of the walk loop.
    var townTap: Int? {
        get { _townTap }
        set { _townTap = newValue }
    }

    /// One pass of the walk loop. The original waits at least 8 timer units (4 without 표시효과,
    /// 0x1B337); the remaster walks a little faster, 6 units, and draws the steps in between.
    var townStepTime: Double { (voyage.memory[0xC30] & 1 != 0 ? 6.0 : 4.0) / 60.3 }

    /// One pass of the walk loop: a step and the door check, or the townsfolk alone.
    func townPass() {
        guard let h = harbor, let m = world.town(h.id) else { return }
        // Where everything stood, so the window can draw the step as a glide (TownWalkView).
        townBefore = TownFrame(voyage)
        townPassAt = Date()
        guard let d = townHeld else {
            townWaiting = false
            voyage.townsfolkTick(port: h.id, map: m)
            status = voyage
            return
        }
        // A message waits for the key to come up, as the original's key wait does.
        if townWaiting { return }
        let before = voyage.townHero
        let r = voyage.townStep(d, port: h.id, map: m)
        townFace = Voyage.townFacing(from: before, to: voyage.townHero, tried: d)
        townStepFrame ^= 1
        switch r {
        case .talk(let t):
            townMessage = townText(voyage.townTalk(t, port: h.id, in: world)).joined(separator: "\n")
            held.removeAll()
            townAim = nil
            townWaiting = true
        case .moved:
            townMessage = nil
        case .stayed:
            break
        }
        status = voyage
        if let k = voyage.townDoor(map: m) { enterDoor(k) }
    }

    /// A door (0x1B08E): a locked one says so and costs nothing; an open one puts the hero a
    /// tile below it, facing down, and the building opens.
    func enterDoor(_ k: Int) {
        guard interaction.worldInputAllowed, let p = HarborPanel(rawValue: k), let h = harbor,
              h.id < 100 || p == .harbor, let map = world.town(h.id), voyage.townDoor(map: map) == k else { return }
        guard p.isOpen(tick: voyage.tick) else {
            townMessage = message(765)
            townWaiting = true
            return
        }
        townMessage = nil
        act { $0.townEnterDoor() }
        townFace = 2
        townAim = nil
        held.removeAll()
        open(p)
    }

    /// Back out into the street.
    func leaveBuilding() {
        townMessage = nil
        messageBuilding = nil
        panel = nil
        tavern = nil
        townFace = 2
    }
}

extension Game {
    /// Loads a slot of the original's KOUKAI2.DAT (newgame.md §8.1) as a remaster voyage.
    func loadDOS(_ save: DOSSave, slot: Int) {
        saveError = nil
        guard let v = save.voyage(slot: slot, in: world) else {
            saveError = "원작 저장을 불러오지 못했습니다. 선택한 슬롯의 자료를 확인해 주세요."
            return
        }
        transitioning = true
        defer { transitioning = false }
        resetPresentation()
        loaded = true
        voyage = v
        status = v
        camera = (v.x, v.y)
        panel = nil
        tavern = nil
        battle = nil
        battleResult = nil
        session = nil
        endingCode = nil
        let port = v.memory[DS.currentPort]
        harbor = port < world.ports.count ? world.ports[port] : nil
        title = false
        say("원작 세이브를 불러왔습니다.")
        applyEnvironment()
    }
}

/// The positions in the walking town at one moment: camera, hero and townsfolk by slot.
struct TownFrame {
    let camera: (x: Int, y: Int)
    let hero: (x: Int, y: Int)
    let folk: [Int: (x: Int, y: Int)]

    init(_ v: Voyage) {
        camera = v.townCamera
        hero = v.townHero
        folk = Dictionary(v.townsfolk.map { ($0.slot, ($0.x, $0.y)) }, uniquingKeysWith: { a, _ in a })
    }
}
