#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import MetalKit
import SwiftUI
import PortolanCore

/// Scripted offscreen capture: PORTOLAN_SNAPSHOT=<dir> Portolan. Plays a short voyage through the
/// real game objects and writes composited PNGs, with no window on the user's screen.
enum Snapshot {
    static let size = CGSize(width: 1360, height: 860)

    static func run(to dir: URL) {
        guard let assets = Game.findAssets(), let game = try? Game(assets: assets),
              let device = MTLCreateSystemDefaultDevice() else {
            print("snapshot: setup failed")
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        let renderer: WorldRenderer
        do {
            renderer = try WorldRenderer(view: view, game: game)
        } catch {
            print("snapshot: renderer failed: \(error)")
            return
        }

        func step(_ seconds: Double) {
            for _ in 0..<Int(seconds * 60) { game.update(dt: 1.0 / 60, viewSize: size) }
        }
        func shot(_ name: String, at size: CGSize = Snapshot.size) {
            guard let world = renderer.renderOffscreen(width: Int(size.width * 2), height: Int(size.height * 2), scale: 2) else { return }
            let bg = NSImage(cgImage: world, size: size)
            let root = ZStack {
                Image(nsImage: bg).resizable()
                OverlayFrame(game: game)
                if game.classicLayout {
                    if let h = game.harbor { ClassicPortFrame(game: game, harbor: h) } else { ClassicSeaFrame(game: game) }
                } else {
                    HUD(game: game)
                    if let h = game.harbor { HarborView(game: game, harbor: h) }
                }
                if game.showVoyagePlan { VoyagePlanView(game: game) }
                if game.battle != nil {
                    if game.classicLayout { ClassicBattleView(game: game) } else { BattleView(game: game) }
                }
                if let (e, o) = game.encounter { BattleIntroView(game: game, encounter: e, opening: o) }
                if let r = game.battleResult { BattleResultView(game: game, result: r) }
                if let c = game.coast { CoastView(game: game, coast: c) }
                if let c = game.command { CommandSheet(game: game, command: c) }
                if let i = game.info { InfoView(game: game, screen: i) }
                if let t = game.tabMenu { if game.classicLayout { ClassicTabPopup(game: game, tab: t) } else { TabPopup(game: game, tab: t) } }
                if let pages = game.seaEvent, game.classicLayout { ClassicMessageBox(game: game, text: pages.first ?? "") {} }
                if game.classicLayout { ClassicDialogue(game: game) } else { DialogueView(game: game) }
            }.font(GameFont.body).buttonStyle(GameButtonStyle()).tint(Theme.gold).frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            let v = game.voyage
            print("\(name): x=\(Int(v.x)) y=\(Int(v.y)) day=\(v.day) speed=\(String(format: "%.1f", v.speed)) sea=\(game.world.isSea(x: v.x, y: v.y)) dock=\(game.dockable?.name ?? "-")")
        }

        /// Clicks through the scripts that are running, answering menus with the first choice.
        func finishScripts() {
            var n = 0
            while let p = game.session?.prompt, n < 400 {
                if case .yesNo = p { game.scriptAnswer(1) } else { game.scriptAnswer(0) }
                n += 1
            }
        }
        // Focused modern layout verification: deterministic preview state, no save-file writes.
        if ProcessInfo.processInfo.environment["PORTOLAN_MODERN_PREVIEW"] != nil {
            let previousLayout = game.classicLayout
            let previousMap = game.classicMap
            defer { game.classicLayout = previousLayout; game.classicMap = previousMap }
            game.classicMap = false
            game.classicLayout = false
            game.voyage = Voyage.joanAfterPrologue(in: game.world)
            game.voyage.tick = 30
            game.voyage.gold = 4000
            game.voyage.ships[0].crew = 20
            game.voyage.ships[0].water = 300
            game.voyage.ships[0].food = 300
            game.status = game.voyage
            game.harbor = game.world.ports[game.voyage.marketIndex]
            game.camera = (game.voyage.x, game.voyage.y)
            let small = CGSize(width: 960, height: 600)
            shot("modern_01_harbor", at: small)
            game.panel = .market
            shot("modern_02_market", at: small)
            game.panel = .harbor
            shot("modern_03_supplies", at: small)
            game.panel = nil
            game.openVoyagePlan()
            shot("modern_04_plan", at: small)
            game.showVoyagePlan = false
            game.setSail()
            game.session = nil
            game.voyage.heading = .pi
            game.voyage.sail = 1
            game.voyage.x -= 15
            game.camera = (game.voyage.x, game.voyage.y)
            game.status = game.voyage
            shot("modern_05_sea", at: small)
            shot("modern_06_sea_large")
            game.openVoyagePlan()
            shot("modern_07_plan_sea", at: small)
            game.showVoyagePlan = false
            checkInput(game)
            return
        }
        // Title and hero select, rendered on their own.
        Motion.instant = true
        let small = CGSize(width: 960, height: 600)                              // RootView.minSize
        for (name, view, at) in [("0_title", AnyView(TitleView(game: game)), size),
                                 ("0b_heroes", AnyView(TitleView(previewHero: 1, game: game, choosing: true)), size),
                                 ("0c_title_small", AnyView(TitleView(game: game)), small)] {
            let host = NSHostingView(rootView: view.frame(width: at.width, height: at.height))
            host.frame = CGRect(origin: .zero, size: at)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            }
        }
        shot("1_harbor")
        shot("1i_harbor_small", at: small)
        // A walk along the quay: hold → for a second, then ↑ (the walk loop runs in update).
        let walkStart = game.voyage.townHero
        game.held.insert(KeyCode.right)
        step(1.2)
        game.held.remove(KeyCode.right)
        game.held.insert(KeyCode.up)
        step(0.6)
        game.held.remove(KeyCode.up)
        shot("1h_town_walk")
        print("walk: from \(walkStart) to \(game.voyage.townHero) face \(game.townFace) message \(game.townMessage ?? "-") panel \(String(describing: game.panel))")
        game.leaveBuilding()
        // Joan's prologue: the father's audience, Carlotta's money, the Hermes II.
        game.open(.residence)
        for _ in 0..<6 { game.scriptAnswer(0) }
        shot("1a_story")
        let plain = game.classicLayout
        game.classicLayout = true
        BlinkClock.steady = true
        shot("1a2_classic_story")
        game.classicLayout = plain
        finishScripts()
        game.open(.tavern)
        finishScripts()
        game.open(.shipyard)
        finishScripts()
        print("prologue: ships=\(game.voyage.ships.map(\.name)) gold=\(game.voyage.gold) officers=\(game.voyage.officers.map(\.name))")
        // The Lisbon tavern turns Joan away until she has said goodbye to her mother at 22:00.
        game.act { $0.passTime(ticks: max(0, 66 - $0.tick), in: game.world) }
        game.open(.residence)
        finishScripts()
        game.open(.tavern)
        finishScripts()
        game.treat(bottles: 4)
        game.hire(15)
        _ = game.offerTerms(to: 96)
        shot("1b_tavern")
        game.open(.market)
        finishScripts()
        if let wine = game.voyage.offers(in: game.world).first(where: { game.world.navigation.goods[$0.good].name == "와인" }) {
            game.buy(wine, amount: 2)
        }
        shot("1d_trade")
        game.open(.shipyard)
        finishScripts()
        shot("1e_shipyard")
        game.shipyardTab = 1
        shot("1f_build")
        game.shipyardTab = 2
        shot("1g_refit")
        game.shipyardTab = 0
        game.open(.harbor)
        finishScripts()
        game.buy(.water, barrels: 30)
        game.buy(.food, barrels: game.voyage.maxPurchase(.food, ship: 0, at: game.market))
        shot("1c_supplies")
        game.openVoyagePlan()
        shot("1j_voyage_plan")
        shot("1k_voyage_plan_small", at: small)
        game.showVoyagePlan = false
        game.setSail()
        finishScripts()
        game.showHelp = true
        game.voyage.heading = .pi
        game.voyage.sail = Voyage.maxSail
        step(6)
        finishScripts()
        game.showHelp = false
        shot("2_atlantic")
        shot("2e_sea_small", at: small)
        game.openVoyagePlan()
        shot("2f_sea_plan")
        game.showVoyagePlan = false
        game.voyage.event = .storm
        game.voyage.eventAnnounced = true
        game.voyage.log.append(SeaEvent.storm.announcement)
        step(0.3)
        shot("2b_storm")
        game.voyage.event = nil
        // A sea battle with the nearest fleet afloat.
        let here = game.voyage
        if let f = (1..<70).filter({ here.memory.fleetActive($0) && !here.memory.fleetInPort($0) }).min(by: { a, b in
            let pa = here.memory.fleetAt(a), pb = here.memory.fleetAt(b)
            return abs(game.world.deltaX(from: here.x, to: Double(pa.x))) + abs(Double(pa.y) - here.y)
                < abs(game.world.deltaX(from: here.x, to: Double(pb.x))) + abs(Double(pb.y) - here.y)
        }) {
            let p = here.memory.fleetAt(f)
            game.voyage.x = Double(p.x) + 0.5
            game.voyage.y = Double(p.y) + 0.5
            game.voyage.tick = 20
            game.voyage.ships[0].crew = 30
            game.voyage.ships[0].guns = 10
            game.voyage.ships[0].gunType = 4
            game.voyage.ships[0].shot = 30
            game.camera = (game.voyage.x, game.voyage.y)
            game.status = game.voyage
            game.attackFleet(f)
            game.update(dt: 1.0 / 60, viewSize: size)
            shot("2c_encounter")
            game.startBattle()
            finishScripts()
            shot("2d_battle")
            let plainBattle = game.classicLayout
            game.classicLayout = true
            BlinkClock.steady = true
            shot("2d2_classic_battle")
            game.classicLayout = plainBattle
            var n = 0
            while game.battle != nil && game.battleResult == nil && n < 400 {
                if let b = game.battle, b.phase == .duel { game.duelMove(n % 3) }
                else if let b = game.battle, b.active != nil {
                    if let t = b.targets(game.status).first { game.battleAttack(t, challenge: false) } else { game.battlePass() }
                }
                n += 1
            }
            shot("2e_battle_result")
            print("battle: code=\(game.battleResult?.code ?? -1) gold=\(game.voyage.gold)")
            game.closeBattle(taking: [])
            finishScripts()
            if game.voyage.gameOver != nil {
                // A lost battle ends the game; the rest of the tour goes on from before it.
                game.voyage = here
                game.status = here
            }
        }

        // Sail south around Cape St Vincent, then east toward Seville.
        guard let seville = game.world.ports.first(where: { $0.name == "세빌리아" }),
              let berth = game.world.berth(of: seville) else { return }
        // Start from the farthest point within 14 tiles that has open water all the way in.
        let w = game.world
        func clear(_ x: Double, _ y: Double) -> Bool {
            (0...40).allSatisfy { i in
                let t = Double(i) / 40
                return w.isSea(x: x + (berth.x - x) * t, y: y + (berth.y - y) * t)
            }
        }
        var start = (x: berth.x, y: berth.y)
        for dy in -14...14 {
            for dx in -14...14 where clear(berth.x + Double(dx), berth.y + Double(dy)) {
                if dx * dx + dy * dy > Int(pow(start.x - berth.x, 2) + pow(start.y - berth.y, 2)) {
                    start = (berth.x + Double(dx), berth.y + Double(dy))
                }
            }
        }
        game.voyage.x = start.x
        game.voyage.y = start.y
        game.camera = (game.voyage.x, game.voyage.y)
        game.voyage.setCourse(x: berth.x, y: berth.y)
        step(4)
        shot("3_arrival")
        game.dock()
        step(0.5)
        shot("4_seville")
        game.panel = .harbor
        shot("4b_harbour_office")
        game.panel = nil
        game.info = .portMap
        shot("4c_portmap")
        game.info = nil
        game.setSail()
        game.setZoom(0.1)
        step(0.5)
        shot("5_world")
        game.setZoom(7)
        step(0.5)
        finishScripts()                                       // the stowaway found at sea
        for (name, screen) in [("6a_info_fleet", InfoScreen.fleet), ("6b_info_ship", .ship), ("6c_info_person", .person),
                               ("6d_info_hero", .hero), ("6e_info_chart", .chart), ("6f_info_logbook", .logbook)] {
            game.info = screen
            shot(name)
        }
        game.info = nil
        for (name, c) in [("7a_cmd_shares", FleetCommand.shares), ("7b_cmd_cargo", .cargo), ("7c_cmd_items", .items)] {
            game.command = c
            shot(name)
        }
        game.command = nil
        game.tabMenu = 3
        shot("7d_tab_menu")
        game.tabMenu = nil
        // The original screen layout at sea and in Seville (the setting is put back afterwards).
        let layout = game.classicLayout
        game.classicLayout = true
        step(0.5)
        shot("10a_classic_sea")
        BlinkClock.steady = true
        game.tabMenu = 0
        shot("10c_classic_tab_menu")
        game.tabMenu = nil
        game.seaEvent = ["바다 상태가 심상치 않습니다."]
        shot("10d_classic_message")
        game.seaEvent = nil
        if let p = game.world.ports.first(where: { $0.name == "세빌리아" }) {
            game.voyage.arrive(at: p, in: game.world)
            game.harbor = p
            game.voyage.tick = 30
            game.status = game.voyage
            step(0.3)
            shot("10b_classic_port")
            game.open(.tavern)
            finishScripts()
            shot("10e_classic_building")
            game.leaveBuilding()
            game.setSail()
        }
        game.classicLayout = layout
        MainActor.assumeIsolated { stageShots(game, to: dir) }
        checkInput(game)
        // An original save (KOUKAI2.DAT slot 0) loaded and shown on the fleet screen.
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let d = DOSSave(url: project.appendingPathComponent("original/GAME/SAVE/KOUKAI2.DAT")) {
            game.loadDOS(d, slot: 0)
            game.info = .fleet
            shot("9b_dos_fleet")
            game.info = nil
        }
    }
}

extension Snapshot {
    /// Sends real AppKit events through the view tree that the live window uses.
    static func checkInput(_ game: Game) {
        // A real window that is never ordered front, so hit testing matches the live app.
        let host = NSHostingView(rootView: RootView(game: game))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        func topView(at p: CGPoint) -> NSView? {
            guard let frame = host.superview else { return nil }
            return frame.hitTest(frame.convert(host.convert(p, to: nil), from: nil))
        }
        let spots = [CGPoint(x: size.width / 2, y: size.height / 2), CGPoint(x: 700, y: 120), CGPoint(x: 500, y: 600)]
        for p in spots where !(topView(at: p) is GameMTKView) {
            print("input: FAIL, click at \(p) lands on \(String(describing: topView(at: p)))")
        }
        guard let hit = topView(at: spots[0]) as? GameMTKView else { return }
        func key(_ code: UInt16, _ type: NSEvent.EventType) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        game.voyage.sail = 0
        hit.keyDown(with: key(KeyCode.up, .keyDown))
        hit.keyUp(with: key(KeyCode.up, .keyUp))
        let sail = game.voyage.sail
        let before = game.voyage.heading
        hit.keyDown(with: key(KeyCode.right, .keyDown))
        for _ in 0..<30 { game.update(dt: 1.0 / 60, viewSize: size) }
        hit.keyUp(with: key(KeyCode.right, .keyUp))
        let turned = game.voyage.heading != before
        game.click(CGPoint(x: 200, y: 400))
        let modalGame = try! Game(assets: game.assets)
        modalGame.voyage = Voyage.joanAfterPrologue(in: modalGame.world)
        modalGame.status = modalGame.voyage
        modalGame.harbor = nil
        modalGame.title = false
        modalGame.opening = false
        let startDay = modalGame.voyage.day
        let startTick = modalGame.voyage.tick
        for mode in 0..<5 {
            modalGame.showFleet = mode == 0
            modalGame.showVoyagePlan = mode == 1
            modalGame.slotMode = mode == 2 ? .save : nil
            modalGame.question = mode == 3 ? Question(text: "test", action: {}) : nil
            modalGame.title = mode == 4
            for _ in 0..<180 { modalGame.update(dt: 1.0 / 60, viewSize: size) }
            precondition(modalGame.voyage.day == startDay && modalGame.voyage.tick == startTick, "Time advanced under a modal")
        }
        modalGame.startNewGame(hero: 0)
        precondition(!modalGame.paused && !modalGame.showFleet && !modalGame.showVoyagePlan && modalGame.slotMode == nil && modalGame.question == nil)
        print("modern: modal time freeze and new-game reset passed")
        print("input: map hit-test ok, sail=\(sail), steering=\(turned), course=\(game.voyage.waypoint != nil)")
    }
}

/// Non-animated overlay for snapshots. TimelineView does not tick inside cacheDisplay.
private struct OverlayFrame: View {
    let game: Game
    var body: some View {
        Canvas { ctx, size in WorldOverlay(game: game).draw(&ctx, size) }
    }
}

extension Snapshot {
    /// Frames of the opening and an ending, set up by hand (the scripts run on timers).
    @MainActor
    static func stageShots(_ game: Game, to dir: URL) {
        do {
            func shot(_ name: String, _ setup: (Stage) -> Void) {
                let s = Stage(assets: game.assets)
                s.black = 0
                setup(s)
                let host = NSHostingView(rootView: StageView(stage: s).frame(width: 1280, height: 800))
                host.frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
                print("\(name): stage")
            }
            // The duel box at sea, after a first exchange.
            var d = Duel.start(hero: game.status.heroID, against: 72, game.status)
            Duel.step(&d, move: 1, &game.voyage)
            let duelHost = NSHostingView(rootView: DuelBoard(game: game, duel: d) { _ in }.padding(20).background(Color.black).environment(\.colorScheme, .dark))
            duelHost.frame = CGRect(x: 0, y: 0, width: 520, height: 400)
            duelHost.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            if let rep = duelHost.bitmapImageRepForCachingDisplay(in: duelHost.bounds) {
                duelHost.cacheDisplay(in: duelHost.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("9_duel.png"))
            }
            shot("8a_opening_title") { $0.put("t", "opening/op00_10.png", 0, 120) }
            shot("8f_opening_water") { s in
                var w = Stage.Layer(id: "w", image: "opening/op00_06.png", x: 40, y: 120)
                w.mask = "opening/op00_05.png"
                w.inner = 100
                s.layers.append(w)
                s.put("e", "opening/op04_01_f2.png", 300, 240)
            }
            shot("8b_opening_otto") { s in
                s.put("p", "opening/op03_07.png", 152, 64)
                s.put("c", "opening/op13_01.png", 288, 64)
            }
            shot("8c_ending_homecoming") { s in
                s.put("frame", "endings/endgrp_56.png", 0, 0)
                s.boxes = [CGRect(x: 104, y: 16, width: 312, height: 144), CGRect(x: 160, y: 176, width: 312, height: 144)]
                s.put("f1", "endings/face_12.png", 120, 32, top: true)
                s.put("f2", "endings/face_00.png", 176, 192, top: true)
                s.texts = [Stage.TextBox(id: "a", text: "긴 항해였소. 수고했소.", shown: 99, x: 192, y: 32, width: 212),
                           Stage.TextBox(id: "b", text: "항해 결과를 보고하겠습니다.", shown: 99, x: 248, y: 192, width: 212)]
            }
            shot("8d_ending_diary") { s in
                s.put("desk", "endings/endgrp_07.png", 0, 30)
                s.put("lamp", "endings/endgrp_08.png", 480, 30)
                s.put("page", "endings/event1_0_sepia.png", 8, 100)
                s.texts = [Stage.TextBox(id: "d", text: "해적의 손에서 왕자를\n구해낸 이는 바로,", shown: 99, x: 208, y: 100, width: 272)]
            }
            shot("8e_ending_staff") { s in
                s.put("portrait", "endings/endgrp_10.png", 0, 30)
                s.put("roll", "endings/endgrp_00.png", 392, 50)
                s.put("e1", "endings/endgrp_54.png", 384, 210, clip: CGRect(x: 384, y: 210, width: 240, height: 160))
            }
        }
    }
}
