import SwiftUI
import PortolanCore

/// The sea battle in the original screen layout (sprites.md §6.3, battle.md §10): the 13×12-cell view
/// at (0, 0) centred on the player's flagship, the side panel GRAPH.DAT 26 at (416, 0) with the minimap,
/// the wind dial, the flagship's lines and the message box, and the flagship's command menu MENU 50,
/// which the original pops up at the pointer (0x13ECB) every time the flagship's turn comes.
struct ClassicBattleView: View {
    @ObservedObject var game: Game
    /// What the map clicks do once a command was picked (nil: the menu is up).
    @State private var mode: Mode?
    @State private var menuAt = CGPoint(x: 208, y: 192)
    @State private var pointer = CGPoint(x: 208, y: 192)
    /// The MENU 50 entry whose own menu is open (정보, 신호).
    @State private var sub: Int?
    @State private var report: Int?
    @State private var askDuel: Int?

    enum Mode { case move, attack, orderShip, orderTarget }
    /// The own ship an order is being given to.
    @State private var ordered: Int?

    private var font: PixelFont? { game.pixelFont }

    var body: some View {
        if let b = game.battle {
            let v = game.status
            ZStack {
                Color.black.ignoresSafeArea()
                ClassicStage {
                    BattleMap(game: game, battle: b, voyage: v, view: Self.window(b, v), tap: tap)
                        .frame(width: 416, height: 400)
                        .onContinuousHover { phase in
                            if case .active(let at) = phase { pointer = at }
                        }
                    if let img = game.image("sprites/battle/panel.png") {
                        Image(nsImage: img).pixelated().frame(width: 224, height: 400).offset(x: 416)
                    }
                    Canvas { ctx, _ in panel(&ctx, b, v) }
                        .frame(width: 640, height: 400)
                        .allowsHitTesting(false)
                    // A click on the panel calls the menu back.
                    Color.white.opacity(0.001).frame(width: 224, height: 400).offset(x: 416)
                        .onTapGesture { if b.active != nil, b.phase == .command { openMenu() } }
                    menus(b, v)
                }
                if let r = report {
                    BattleReport(game: game, battle: b, kind: r) { report = nil }
                        .environment(\.colorScheme, .dark)
                }
                if b.phase == .duel, let d = b.duel {
                    DuelBoard(game: game, duel: d) { game.duelMove($0) }
                        .padding(20)
                        .gamePanel(radius: 16)
                        .environment(\.colorScheme, .dark)
                }
            }
            .onChange(of: v.tick) { _, _ in openMenu() }
            .onAppear { openMenu() }
        }
    }

    /// The 13×12 window (battle.md §11.6): x−6..x+6, y−6..y+5 around the player's flagship, kept on
    /// the 52×48 field.
    static func window(_ b: Battle, _ v: Voyage) -> (x: Int, y: Int, w: Int, h: Int) {
        let k = b.active ?? b.units.indices.first { b.units[$0].fleet == v.playerFleet && b.isFlagship($0) }
        let c = k.map { (b.units[$0].x, b.units[$0].y) } ?? (Battle.width / 2, Battle.height / 2)
        return (max(0, min(Battle.width - 13, c.0 - 6)), max(0, min(Battle.height - 12, c.1 - 6)), 13, 12)
    }

    private func openMenu() {
        mode = nil
        sub = nil
        menuAt = pointer
    }

    private func tap(_ x: Int, _ y: Int) {
        guard let b = game.battle, b.active != nil, mode != nil else { return }
        let hit = b.units.indices.first { b.units[$0].x == x && b.units[$0].y == y && b.alive($0, game.status) }
        if mode == .orderShip {
            // 773: pick one of your own other ships.
            if let k = hit, k != b.active, b.units[k].owner == 0x80 { ordered = k; mode = nil }
            return
        }
        if mode == .orderTarget {
            // 774: pick the enemy it is to go for.
            if let k = hit, let o = ordered, b.units[k].owner != 0x80 { game.battleOrder(o, target: .some(k)); mode = nil; ordered = nil }
            return
        }
        if let j = b.units.indices.first(where: { b.units[$0].x == x && b.units[$0].y == y }), b.targets(game.status).contains(j) {
            if b.duelOffered(j) { askDuel = j } else { game.battleAttack(j, challenge: false) }
        } else if mode == .move {
            game.battleMove(x, y)
        }
    }

    // MARK: the panel (0xC2B6, 0xC13B, 0xC102)

    private func panel(_ ctx: inout GraphicsContext, _ b: Battle, _ v: Voyage) {
        minimap(&ctx, b, v)
        if let img = game.image("sprites/battle/wind_\(b.windDir % 6).png") {
            ctx.draw(Image(nsImage: img).interpolation(.none), in: CGRect(x: 440, y: 230, width: 40, height: 40))
        }
        ctx.pixelText(String(format: "%2d", v.tick / 3), 448, 296, font: font)
        ctx.pixelText(String(format: "%02d", 20 * (v.tick % 3)), 472, 296, font: font)
        if let k = b.units.indices.first(where: { b.units[$0].fleet == v.playerFleet && b.isFlagship($0) }) {
            let cls = b.shipClass(k, v)
            let c = game.world.navigation.classes.indices.contains(cls) ? game.world.navigation.classes[cls] : nil
            ctx.pixelText(b.shipName(k, v) + "호", 496, 216, font: font)
            let lines = [(b.hull(k, v), b.maxHull(k, v)), (b.crew(k, v), b.maxCrew(k, v)),
                         (b.rudder(k, v), c?.rudder ?? 0), (b.sails(k, v), c?.sail ?? 0)]
            for (i, l) in lines.enumerated() {
                ctx.pixelText(String(format: "%3d/%3d", l.0, l.1), 560, Double(232 + 16 * i), font: font)
            }
            ctx.pixelText(String(format: "%3d", b.units[k].shot), 600, 296, font: font)
        }
        // The message box: black, the latest line in colour 7.
        ctx.fill(Path(CGRect(x: 424, y: 328, width: 192, height: 56)), with: .color(.black))
        var cur = PixelCursor(col: 54, y: 336, right: 75)
        let cells = font?.layout(message(b), &cur).filter { $0.y < 384 } ?? []
        ctx.pixelCells(cells, fg: FrameColor.cream, bg: nil)
    }

    private func message(_ b: Battle) -> String {
        if b.active != nil, b.phase == .command, let m = mode {
            if m == .orderShip { return game.message(773) }
            if m == .orderTarget { return game.message(774) }
            if m == .attack || b.moved { return game.message(772) }                  // 공격할 배를 고르십시오
            return game.message(767)
        }
        return b.log.lines.last ?? ""
    }

    /// The whole 52×48 field in 4×4 round dots (DS:0xA50C) on colour 5: land 0, own 7, ally 6,
    /// enemy 2, its reinforcements 3.
    private func minimap(_ ctx: inout GraphicsContext, _ b: Battle, _ v: Voyage) {
        let pal: [Int: Color] = [0: .black, 2: FrameColor.red, 3: Color(red: 1, green: 68 / 255, blue: 204 / 255),
                                 5: Color(red: 0, green: 170 / 255, blue: 1), 6: Color(red: 1, green: 170 / 255, blue: 0), 7: FrameColor.cream]
        ctx.fill(Path(CGRect(x: 424, y: 8, width: 208, height: 192)), with: .color(pal[5]!))
        func dot(_ p: inout Path, _ x: Int, _ y: Int) {
            let px = 424 + 4 * x, py = 8 + 4 * y
            p.addRect(CGRect(x: px + 1, y: py, width: 2, height: 1))
            p.addRect(CGRect(x: px, y: py + 1, width: 4, height: 2))
            p.addRect(CGRect(x: px + 1, y: py + 3, width: 2, height: 1))
        }
        var land = Path()
        for y in 0..<Battle.height {
            for x in 0..<Battle.width where b.map[y * Battle.width + x] & 0x80 != 0 { dot(&land, x, y) }
        }
        ctx.fill(land, with: .color(pal[0]!))
        for (k, u) in b.units.enumerated() where b.alive(k, v) {
            let c = u.owner & 0x80 != 0 ? (u.fleet == v.playerFleet ? 7 : 6) : (u.owner & 0x40 != 0 ? 3 : 2)
            var p = Path()
            dot(&p, u.x, u.y)
            ctx.fill(p, with: .color(pal[c]!))
        }
    }

    // MARK: the menus

    @ViewBuilder
    private func menus(_ b: Battle, _ v: Voyage) -> some View {
        if let j = askDuel {
            // Msg 770: the enemy admiral offers a duel.
            ClassicPopup(game: game, col: 18, y: 160, items: ["일기토", "백병전"], cancel: { askDuel = nil }) { i in
                askDuel = nil
                game.battleAttack(j, challenge: i == 0)
            }
        } else if let o = ordered, mode == nil, b.units.indices.contains(o) {
            let f = b.units[o].flags
            let items = [f & 2 != 0 ? "방침: 공격→퇴각" : "방침: 퇴각→공격", f & 0x10 != 0 ? "방법: 돌격중심으로" : "방법: 포격중심으로", "대상 지정", "위임"]
            let size = ClassicPopup.size(items)
            ClassicPopup(game: game, col: max(0, (80 - size.cols) / 2), y: 120, items: items, cancel: { ordered = nil }) { i in
                switch i {
                case 0: game.battleOrder(o, attack: f & 2 == 0); ordered = nil
                case 1: game.battleOrder(o, gunnery: f & 0x10 == 0); ordered = nil
                case 2: mode = .orderTarget
                default: game.battleOrder(o, target: .some(nil)); ordered = nil
                }
            }
        } else if b.active != nil, b.phase == .command, mode == nil, report == nil {
            let items = (0..<8).map { game.menu(50, $0) }
            let size = ClassicPopup.size(items)
            // 0x13ECB: centred on the pointer, 24 px above it, kept on the screen.
            let col = max(0, min(79 - size.cols, (Int(menuAt.x) - 4 * size.cols) / 8))
            let y = max(0, min(396 - size.h, Int(menuAt.y) - 24))
            Color.white.opacity(0.001).frame(width: 640, height: 400)
                .onTapGesture { mode = .move }
            ClassicPopup(game: game, col: col, y: y, items: items, disabled: disabled(b, v),
                         cancel: { mode = .move }, active: sub == nil) { i in choose(i, b, v) }
            if let s = sub {
                let kids = subItems(s, b)
                let ks = ClassicPopup.size(kids)
                ClassicPopup(game: game, col: col + size.cols - 2 + ks.cols < 80 ? col + size.cols - 2 : max(0, col - ks.cols + 2),
                             y: max(0, min(396 - ks.h, y + 24 * s)), items: kids,
                             disabled: s == 2 ? subDisabled(b, v) : [], cancel: { sub = nil }) { k in pickSub(s, k) }
                    .id(s)
            }
        } else if b.active != nil, b.phase == .command, mode != nil {
            // While picking cells: ←/→ turn the bow before moving, Return passes, Esc calls the menu.
            Group {
                Button("") { game.battleTurn(-1) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(b.moved)
                Button("") { game.battleTurn(1) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(b.moved)
                Button("") { game.battlePass() }.keyboardShortcut(.defaultAction)
                Button("") { openMenu() }.keyboardShortcut(.cancelAction)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    /// MENU 50's greyed items (0xB579): 공격 with no enemy in reach, 신호 with no other own ship,
    /// 작전 (not available here), 아이템 with no items, 이탈 off the edge.
    private func disabled(_ b: Battle, _ v: Voyage) -> Set<Int> {
        var d: Set<Int> = []
        if !b.units.indices.contains(where: { $0 != b.active && b.units[$0].owner == 0x80 && b.alive($0, v) }) { d.insert(4) }
        if b.targets(v).isEmpty { d.insert(1) }
        let own = b.sides.first { $0.contains { b.units[$0].fleet == v.playerFleet } } ?? []
        if own.filter({ b.alive($0, v) }).count <= 1 { d.insert(3) }
        if v.items.isEmpty { d.insert(6) }
        if !b.canLeave(v) { d.insert(7) }
        if b.moved { d.insert(0) }
        return d
    }

    private func choose(_ i: Int, _ b: Battle, _ v: Voyage) {
        switch i {
        case 0: mode = .move
        case 1: mode = .attack
        case 2, 3: sub = i
        case 4: mode = .orderShip
        case 5: game.battlePass()
        case 6: game.command = .items
        case 7: game.battleLeave()
        default: break
        }
    }

    private func subItems(_ s: Int, _ b: Battle) -> [String] {
        if s == 2 { return (0..<7).map { game.menu(51, $0) } }
        guard let a = b.active else { return [] }
        let f = b.units[a].flags
        return [f & 1 != 0 ? "수  세" : "공  세", f & 4 != 0 ? "분  산" : "집  결"]
    }

    private func subDisabled(_ b: Battle, _ v: Voyage) -> Set<Int> {
        var d: Set<Int> = []
        if b.otherSides(v).allSatisfy({ s in !b.sides[s].contains { b.alive($0, v) } }) { d.insert(5) }
        if b.sides.first(where: { $0.contains { b.units[$0].fleet == v.playerFleet } }).map({ $0.filter { b.alive($0, v) }.count <= 1 }) ?? true {
            d.insert(6)
        }
        return d
    }

    private func pickSub(_ s: Int, _ k: Int) {
        sub = nil
        if s == 2 {
            switch k {
            case 0: game.info = .fleet
            case 1: game.info = .person
            case 2: game.info = .ship
            default: report = k
            }
        } else if let b = game.battle, let a = b.active {
            let f = b.units[a].flags
            if k == 0 { game.battleSignal(attack: f & 1 == 0) } else { game.battleSignal(gather: f & 4 == 0) }
        }
    }
}
