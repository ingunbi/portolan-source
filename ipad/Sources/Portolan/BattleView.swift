import SwiftUI
import PortolanCore

/// The encounter dialog before a sea battle (0xF9CA; MENU 54 교전 / 도망 / 항복).
struct BattleIntroView: View {
    @ObservedObject var game: Game
    let encounter: Encounter
    let opening: BattleOpening

    var body: some View {
        let m = game.status.memory
        let other = encounter.attacker == m[DS.heroID] ? encounter.defender : encounter.attacker
        let them = m.person(other)
        let fleet = m.fleetOf(person: other)
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        if let img = game.portrait(person: other) {
                            Image(nsImage: img).pixelated().frame(width: 64, height: 80).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(them.name).font(GameFont.title2.bold())
                            Text("\(["포르투갈", "에스파니아", "오스만 투르크", "잉글랜드", "이탈리아", "네덜란드", "해적"][min(6, fleet / 10)]) 함대 · 전투력 \(opening.theirs) (아군 \(opening.ours))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(opening.lines, id: \.self) { n in
                                Text(game.fill(n, them.name, m.person(m[DS.heroID]).name)).fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 240)
                    HStack {
                        if opening.defending {
                            Button("교전") { game.startBattle() }.accessibilityIdentifier("portolan.battle.start").buttonStyle(GameButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                            Button("도망") { game.flee() }.accessibilityIdentifier("portolan.battle.flee")
                            Button("항복") { game.surrender() }.accessibilityIdentifier("portolan.battle.surrender")
                        } else if opening.merchantOffer {
                            Button("받아들인다") { game.acceptMerchantOffer() }.buttonStyle(GameButtonStyle(prominent: true))
                            Button("거절한다") { game.startBattle() }.accessibilityIdentifier("portolan.battle.start")
                        } else {
                            Button("전투 개시") { game.startBattle() }.accessibilityIdentifier("portolan.battle.start").buttonStyle(GameButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                        }
                    }
                }
                .padding(24)
                .frame(width: min(720, geometry.size.width - 40), height: min(500, geometry.size.height - 40))
                .gamePanel(radius: 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .environment(\.colorScheme, .dark)
        }
    }
}

/// The battle on its hex map: the player's flagship takes orders (MENU 50), the rest is AI.
struct BattleView: View {
    @ObservedObject var game: Game
    @State private var askDuel: Int?
    /// MENU 51 items 3–6 (타함대, 타함대인물, 타함대선박, 작전일람).
    @State private var report: Int?

    var body: some View {
        if let b = game.battle {
            let v = game.status
            ZStack {
                Color(red: 0.04, green: 0.1, blue: 0.18).ignoresSafeArea()
                HStack(alignment: .top, spacing: 16) {
                    BattleMap(game: game, battle: b, voyage: v, view: window(b, v), tap: tap)
                    side(b, v)
                        .disabled(b.phase != .command)
                        .frame(width: 320)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(14)
                        .gamePanel(radius: 16)
                }
                .padding(16)
                .disabled(askDuel != nil)
                if let r = report {
                    BattleReport(game: game, battle: b, kind: r) { report = nil }
                }
                if b.phase == .duel, let d = b.duel {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack {
                        Spacer()
                        DuelBoard(game: game, duel: d) { game.duelMove($0) }
                            .padding(20)
                            .gamePanel(radius: 16)
                        Spacer()
                    }
                }
                if let target = askDuel { boardingChoice(target) }
            }
            .environment(\.colorScheme, .dark)
        }
    }

    private func boardingChoice(_ target: Int) -> some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                Text(game.message(770))
                    .font(.system(size: 22, weight: .medium)).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("취소") { askDuel = nil }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("portolan.battle.board.cancel")
                    Spacer()
                    Button("일기토") {
                        askDuel = nil
                        game.battleAttack(target, challenge: true)
                    }.accessibilityIdentifier("portolan.battle.challenge")
                    Button("백병전") {
                        askDuel = nil
                        game.battleAttack(target, challenge: false)
                    }
                    .buttonStyle(GameButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("portolan.battle.board")
                }
            }
            .padding(24)
            .frame(width: 620)
            .gamePanel(radius: 18)
        }
    }

    /// The side panel's minimap (0xC2B6): the whole 52×48 field in 4×4 dots on colour 5, land
    /// black, own ships white, allies orange, the enemy red, its reinforcements pink.
    private func minimap(_ b: Battle, _ v: Voyage) -> some View {
        let pal: [Int: Color] = [0: .black, 2: Color(red: 221 / 255, green: 68 / 255, blue: 0), 3: Color(red: 1, green: 68 / 255, blue: 204 / 255),
                                 5: Color(red: 0, green: 170 / 255, blue: 1), 6: Color(red: 1, green: 170 / 255, blue: 0), 7: Color(red: 1, green: 238 / 255, blue: 221 / 255)]
        return Canvas { ctx, size in
            let d = size.width / CGFloat(Battle.width)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(pal[5]!))
            for y in 0..<Battle.height {
                for x in 0..<Battle.width where b.map[y * Battle.width + x] & 0x80 != 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * d, y: CGFloat(y) * d, width: d, height: d)), with: .color(pal[0]!))
                }
            }
            for (k, u) in b.units.enumerated() where b.alive(k, v) {
                let c = u.owner & 0x80 != 0 ? (u.fleet == v.playerFleet ? 7 : 6) : (u.owner & 0x40 != 0 ? 3 : 2)
                ctx.fill(Path(roundedRect: CGRect(x: CGFloat(u.x) * d - d / 2, y: CGFloat(u.y) * d - d / 2, width: 2 * d, height: 2 * d), cornerRadius: d / 2),
                         with: .color(pal[c]!))
            }
        }
        .frame(width: 156, height: 144)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.gold.opacity(0.4)))
    }

    /// The flagship's lines of the panel (0xC13B): hull, crew, rudder, sails and shot.
    @ViewBuilder
    private func flagshipStatus(_ b: Battle, _ v: Voyage) -> some View {
        if let k = b.units.indices.first(where: { b.units[$0].fleet == v.playerFleet && b.isFlagship($0) }) {
            let cls = b.shipClass(k, v)
            let c = game.world.navigation.classes.indices.contains(cls) ? game.world.navigation.classes[cls] : nil
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                GridRow { Text(b.shipName(k, v) + "호").fontWeight(.semibold).foregroundStyle(Theme.gold).gridCellColumns(2) }
                GridRow { Text("내구도").foregroundStyle(.secondary); Text("\(b.hull(k, v))/\(b.maxHull(k, v))") }
                GridRow { Text("승무원").foregroundStyle(.secondary); Text("\(b.crew(k, v))/\(b.maxCrew(k, v))") }
                GridRow { Text("조타").foregroundStyle(.secondary); Text("\(b.rudder(k, v))/\(c?.rudder ?? 0)") }
                GridRow { Text("돛").foregroundStyle(.secondary); Text("\(b.sails(k, v))/\(c?.sail ?? 0)") }
                GridRow { Text("포탄").foregroundStyle(.secondary); Text("\(b.units[k].shot)") }
            }
            .font(GameFont.body.monospacedDigit())
        }
    }

    /// The part of the sea with ships on it, at least 24×18 hexes (the original shows 13×12).
    private func window(_ b: Battle, _ v: Voyage) -> (x: Int, y: Int, w: Int, h: Int) {
        let live = b.units.indices.filter { b.alive($0, v) }
        let reachable = b.active.flatMap { b.moved ? nil : b.reach($0, v) } ?? [:]
        let xs = live.map { b.units[$0].x } + reachable.keys.map { $0 % Battle.width }
        let ys = live.map { b.units[$0].y } + reachable.keys.map { $0 / Battle.width }
        var x0 = (xs.min() ?? 0) - 4, x1 = (xs.max() ?? Battle.width) + 4
        var y0 = (ys.min() ?? 0) - 4, y1 = (ys.max() ?? Battle.height) + 4
        if x1 - x0 < 24 { let c = (x0 + x1) / 2; x0 = c - 12; x1 = c + 12 }
        if y1 - y0 < 18 { let c = (y0 + y1) / 2; y0 = c - 9; y1 = c + 9 }
        x0 = max(0, x0); y0 = max(0, y0); x1 = min(Battle.width, x1); y1 = min(Battle.height, y1)
        return (x0, y0, x1 - x0, y1 - y0)
    }

    private func tap(_ x: Int, _ y: Int) {
        guard let b = game.battle, b.active != nil else { return }
        if let j = b.targets(game.status).first(where: { b.units[$0].x == x && b.units[$0].y == y }) {
            if b.duelOffered(j) { askDuel = j } else { game.battleAttack(j, challenge: false) }
        } else {
            game.battleMove(x, y)
        }
    }

    @ViewBuilder
    private func side(_ b: Battle, _ v: Voyage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("해전", systemImage: "flag.2.crossed.fill").font(.system(size: 22, weight: .bold, design: .serif)).foregroundStyle(Theme.goldGradient)
            HStack(spacing: 10) {
                // The wind dial of the side panel (0xC2B6): the needle points where the wind blows.
                if let img = game.image("sprites/battle/wind_\(b.windDir % 6).png") {
                    Image(nsImage: img).pixelated().frame(width: 40, height: 40)
                }
                Text("\(v.tick / 3)시 · 바람 \(["북", "북동", "남동", "남", "남서", "북서"][b.windDir]) \(b.windStrength)")
                    .foregroundStyle(.secondary)
            }
            HStack {
                GameActionMenu("정보", actions: [                                     // MENU 51, 0xB089
                    GameMenuAction(game.menu(51, 0)) { game.info = .fleet },
                    GameMenuAction(game.menu(51, 1)) { game.info = .person },
                    GameMenuAction(game.menu(51, 2)) { game.info = .ship },
                    GameMenuAction(game.menu(51, 3)) { report = 3 },
                    GameMenuAction(game.menu(51, 4)) { report = 4 },
                    GameMenuAction(game.menu(51, 5), isEnabled: !b.otherSides(v).allSatisfy { s in !b.sides[s].contains { b.alive($0, v) } }) { report = 5 },
                    GameMenuAction(game.menu(51, 6), isEnabled: !(b.sides.first { $0.contains { b.units[$0].fleet == v.playerFleet } }.map { $0.filter { b.alive($0, v) }.count <= 1 } ?? true)) { report = 6 },
                ], accessibilityIdentifier: "portolan.battle.info.menu")
                    .frame(width: 100)
                Menu("작전") {                                                          // 0xB503
                    ForEach(b.units.indices.filter { $0 != b.active && b.units[$0].owner == 0x80 && b.alive($0, v) }, id: \.self) { k in
                        Menu(b.shipName(k, v)) {
                            Button(b.units[k].flags & 2 != 0 ? "퇴각 방침으로" : "공격 방침으로") { game.battleOrder(k, attack: b.units[k].flags & 2 == 0) }
                            Button(b.units[k].flags & 0x10 != 0 ? "돌격 중심으로" : "포격 중심으로") { game.battleOrder(k, gunnery: b.units[k].flags & 0x10 == 0) }
                            Button("대상 해제 (위임)") { game.battleOrder(k, target: .some(nil)) }
                            ForEach(b.units.indices.filter { b.units[$0].owner != 0x80 && b.alive($0, v) }, id: \.self) { j in
                                Button("대상: " + b.shipName(j, v)) { game.battleOrder(k, target: .some(j)) }
                            }
                        }
                    }
                }.fixedSize()
                Button("아이템") { game.command = .items }.disabled(v.items.isEmpty)            // 0xB543
            }
            if let i = b.active {
                Text(b.moved ? "공격할 적을 선택하거나 턴을 마치세요." : "이동할 칸을 누르세요. 이동 후 포격할 수 있습니다.")
                    .font(GameFont.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("◀ 선회") { game.battleTurn(-1) }.disabled(b.moved).accessibilityIdentifier("portolan.battle.turn.left")
                    Button("선회 ▶") { game.battleTurn(1) }.disabled(b.moved).accessibilityIdentifier("portolan.battle.turn.right")
                }
                HStack {
                    Button(b.units[i].flags & 1 != 0 ? "신호: 수세" : "신호: 공세") { game.battleSignal(attack: b.units[i].flags & 1 == 0) }
                    Button(b.units[i].flags & 4 != 0 ? "분산" : "집결") { game.battleSignal(gather: b.units[i].flags & 4 == 0) }
                }.font(GameFont.caption)
                HStack {
                    Button("정선 · 턴 종료") { game.battlePass() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("portolan.battle.pass")
                    Button("이탈") { game.battleLeave() }.disabled(!b.canLeave(v)).accessibilityIdentifier("portolan.battle.leave")
                }
            }
            // Orders stay visible at the minimum window size; the field report scrolls.
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        flagshipStatus(b, v)
                        minimap(b, v)
                    }
                    Text("교전 함대").font(GameFont.caption.bold()).foregroundStyle(Theme.gold)
                    ForEach(b.units.indices, id: \.self) { k in
                        let u = b.units[k]
                        HStack(alignment: .top) {
                            Circle().fill(u.owner & 0x80 != 0 ? Color.blue : Color.red).frame(width: 8, height: 8).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 4) {
                            Text(b.shipName(k, v)).font(GameFont.callout).fixedSize(horizontal: false, vertical: true)
                            Text(u.flags & 0x40 != 0 ? "이탈" : b.hull(k, v) <= 0 ? "격침" : b.crew(k, v) <= 0 ? "전투 불능" : "\(b.hull(k, v))/\(b.maxHull(k, v)) · \(b.crew(k, v))명")
                                .monospacedDigit().foregroundStyle(u.flags & 0x40 != 0 ? Theme.gold : b.alive(k, v) ? Color.secondary : Color.red)
                            }
                        }.font(GameFont.caption)
                    }
                    Divider()
                    Text("전투 기록").font(GameFont.caption.bold()).foregroundStyle(Theme.gold)
                    ForEach(Array(b.log.lines.suffix(12).enumerated()), id: \.offset) {
                        Text($0.element).font(GameFont.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("portolan.battle.report")
        }
    }
}

/// The battle sea as HDAT.PUT draws it (sprites.md §6): 32-px chips on a square grid with odd
/// columns half a cell lower, ships by side, rig and heading, the cell markers, and the burst,
/// spout and sabre frames of the latest attack. Colours 9, 11, 14 and 15 of the sea cycle.
struct BattleMap: View {
    @ObservedObject var game: Game
    let battle: Battle
    let voyage: Voyage
    let view: (x: Int, y: Int, w: Int, h: Int)
    let tap: (Int, Int) -> Void
    /// The cell under the pointer, for the path arrows (0xBB5D bl 0x80 + heading).
    @State private var hover: (x: Int, y: Int)?

    var body: some View {
        GeometryReader { g in
            let c = min(g.size.width / CGFloat(view.w), g.size.height / (CGFloat(view.h) + 0.5))
            TimelineView(.periodic(from: .now, by: 0.12)) { t in
                Canvas { ctx, _ in draw(&ctx, c, t.date.timeIntervalSinceReferenceDate) }
            }
            .frame(width: c * CGFloat(view.w), height: c * (CGFloat(view.h) + 0.5))
            .overlay(alignment: .topLeading) {
                ForEach(actionCells, id: \.self) { key in
                    let x = key % Battle.width, y = key / Battle.width
                    let r = rect(x, y, c)
                    Button { tap(x, y) } label: {
                        Color.clear.frame(width: c, height: c).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(cellLabel(x, y))
                    .accessibilityIdentifier("portolan.battle.hex.\(x).\(y)")
                    .position(x: r.midX, y: r.midY)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let at) = phase { hover = cell(at: at, c) } else { hover = nil }
            }
        }
    }

    private var actionCells: [Int] {
        guard battle.phase == .command, let active = battle.active else { return [] }
        var cells = Set(battle.moved ? [] : Array(battle.reach(active, voyage).keys))
        for j in battle.targets(voyage) { cells.insert(battle.units[j].y * Battle.width + battle.units[j].x) }
        return cells.sorted().filter {
            (view.x..<(view.x + view.w)).contains($0 % Battle.width)
                && (view.y..<(view.y + view.h)).contains($0 / Battle.width)
        }
    }

    private func cellLabel(_ x: Int, _ y: Int) -> String {
        if let j = battle.targets(voyage).first(where: { battle.units[$0].x == x && battle.units[$0].y == y }), let i = battle.active {
            return "\(battle.shipName(j, voyage)) \(battle.canFire(i, at: j) ? "포격" : "백병전")"
        }
        return "해전 좌표 \(x), \(y)로 이동"
    }

    private func cell(at p: CGPoint, _ c: CGFloat) -> (x: Int, y: Int) {
        let col = Int(p.x / c)
        let row = Int(floor((p.y - (((view.x + col) & 1) == 1 ? c / 2 : 0)) / c))
        return (view.x + col, view.y + row)
    }

    private func rect(_ x: Int, _ y: Int, _ c: CGFloat) -> CGRect {
        CGRect(x: CGFloat(x - view.x) * c, y: CGFloat(y - view.y) * c + (x & 1 == 1 ? c / 2 : 0), width: c, height: c)
    }

    private func put(_ ctx: inout GraphicsContext, _ name: String, _ r: CGRect) {
        guard let img = game.image("sprites/battle/" + name) else { return }
        ctx.draw(Image(nsImage: img).interpolation(.none), in: r)
    }

    private func draw(_ ctx: inout GraphicsContext, _ c: CGFloat, _ now: TimeInterval) {
        let b = battle, v = voyage
        // The sea cycle: every 17 ticks of 18.2 Hz the four water colours move on (0xBB18).
        let phase = Int(now / (17 / 18.2)) % 4
        for y in (view.y - 1)..<(view.y + view.h + 1) where (0..<Battle.height).contains(y) {
            for x in view.x..<(view.x + view.w) {
                let chip = b.map[y * Battle.width + x] & 0x1F
                let base = String(format: "chip_%02d", min(12, chip))
                let name = phase > 0 && game.image("sprites/battle/\(base)_p\(phase).png") != nil ? "\(base)_p\(phase).png" : base + ".png"
                put(&ctx, name, rect(x, y, c))
            }
        }
        // Markers (0xBB5D): reachable cells, enemies in gun range, enemies alongside.
        if let a = b.active {
            if !b.moved {
                let reach = b.reach(a, v)
                for (cell, _) in reach { put(&ctx, "mark_ship.png", rect(cell % Battle.width, cell / Battle.width, c)) }
                // The way to the hex under the pointer, one arrow a step (DS:0xA4F2).
                if let h = hover, (0..<Battle.width).contains(h.x), (0..<Battle.height).contains(h.y), let way = reach[h.y * Battle.width + h.x] {
                    var p = (b.units[a].x, b.units[a].y)
                    for d in way.path {
                        p = Battle.neighbour(p.0, p.1, d)
                        put(&ctx, "stamp_arrow_\(d % 6).png", rect(p.0, p.1, c))
                    }
                }
            }
            for j in b.targets(v) {
                put(&ctx, b.canBoard(a, j) ? "mark_board.png" : "mark_fire.png", rect(b.units[j].x, b.units[j].y, c))
            }
        }
        for (k, u) in b.units.enumerated() where b.hull(k, v) > 0 && b.units[k].flags & 0x40 == 0
            && (view.x..<(view.x + view.w)).contains(u.x) && (view.y..<(view.y + view.h)).contains(u.y) {
            let set = (u.owner & 0x80 != 0 ? 0 : 1) + (b.sailOnly(k, v) ? 0 : 2)
            let r = rect(u.x, u.y, c)
            put(&ctx, "ship_\(set)_\(u.heading % 6).png", r)
            if k == b.active { ctx.stroke(Path(r.insetBy(dx: 1, dy: 1)), with: .color(.yellow), lineWidth: 2) }
            if b.crew(k, v) > 0, let n = b.sides.first(where: { $0.contains(k) })?.firstIndex(of: k) {
                // The ship's number, white on a side's flagship (DS:0xA5B4 / 0xA5BB).
                let label = Text("\(n)").font(.system(size: c * 0.32, weight: .bold, design: .monospaced))
                    .foregroundColor(b.isFlagship(k) ? .white : Color(red: 0, green: 0.27, blue: 0.87))
                ctx.draw(label, at: CGPoint(x: r.minX + c * 0.18, y: r.minY + c * 0.2))
            }
        }
        // The latest attack: four burst frames (and spouts), or the boarding sabres.
        if let s = b.lastStrike, b.units.indices.contains(s.target) {
            let flight = s.boarding ? 0.0 : 0.25
            let age = now - strikeStart(s) - flight
            let u = b.units[s.target], r = rect(u.x, u.y, c)
            if age < 0, b.units.indices.contains(s.attacker) {
                // The cannonball (0xC583): an 8×8 ball on an arc from the attacker to the target.
                let t = 1 + age / flight
                let a = rect(b.units[s.attacker].x, b.units[s.attacker].y, c)
                let x = a.midX + (r.midX - a.midX) * t, y = a.midY + (r.midY - a.midY) * t - sin(t * .pi) * c * 0.8
                put(&ctx, "ball.png", CGRect(x: x - c / 8, y: y - c / 8, width: c / 4, height: c / 4))
            } else if age < 0.6 {
                let f = min(3, Int(age / 0.15))
                if s.boarding {
                    put(&ctx, "board_\([0, 1, 2, 3, 1, 3, 0, 2][Int(age / 0.075) % 8]).png", r)
                } else {
                    put(&ctx, "hit_\(f).png", r)
                    put(&ctx, "splash_\(f).png", CGRect(x: r.minX + (s.serial & 1 == 0 ? 0 : c / 2), y: r.minY + c * 0.375, width: c / 2, height: c * 0.625))
                }
            }
        }
    }

    private static var strikeTimes: [Int: TimeInterval] = [:]

    /// When the strike was first drawn, so its frames play once.
    private func strikeStart(_ s: BattleStrike) -> TimeInterval {
        if let t = Self.strikeTimes[s.serial] { return t }
        let t = Date().timeIntervalSinceReferenceDate
        Self.strikeTimes = [s.serial: t]
        return t
    }
}

struct BattleResultView: View {
    @ObservedObject var game: Game
    let result: BattleResult
    @State private var picks: Set<Int> = []

    var body: some View {
        GeometryReader { geometry in
            let victory = [4, 6].contains(result.code)
            let hasPrizes = !result.capturable.isEmpty
            ZStack {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(victory ? "해전 승리" : "해전 종료").font(GameFont.title2.bold())
                        Spacer()
                        if result.gold > 0 {
                            Label("+\(result.gold.formatted())닢", systemImage: "circle.circle.fill")
                                .foregroundStyle(Theme.gold).monospacedDigit()
                        }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            let pic = [4: 53, 6: 53, 8: 53, 2: 54, 3: 54, 9: 54, 1: 55, 5: 56, 7: 56][result.code]
                            if let n = pic, let img = game.image("sprites/battle/result_\(n).png") {
                                Image(nsImage: img).pixelated().aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity, maxHeight: hasPrizes ? 120 : 310)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            ForEach(result.lines, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                            if let item = result.item {
                                Text(Korean.particles("전리품으로 \(game.itemName(item))(를) 손에 넣었습니다."))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: hasPrizes ? 185 : 380)
                    if let battle = game.battle, hasPrizes {
                        Divider()
                        Text("함대에 편입할 배를 선택하세요")
                            .font(GameFont.headline)
                        Text("나포 가능한 배 \(result.capturable.count)척 · 선장 가능 동료 \(max(0, game.status.spareCaptains))명 · 편입 한도 \(result.mayTake)척")
                            .font(GameFont.caption).foregroundStyle(.secondary)
                        if result.mayTake == 0 {
                            Text(game.status.ships.count >= 10 ? "함대가 10척으로 가득 차 편입할 수 없습니다." : "배를 맡길 항해자가 없어 편입할 수 없습니다.")
                                .foregroundStyle(Theme.gold)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(result.capturable, id: \.self) { j in
                                        let unit = battle.units[j]
                                        let slot = game.status.memory.slot(unit.fleet, unit.slot)
                                        Toggle(isOn: Binding(get: { picks.contains(j) }, set: { on in
                                            if on { if picks.count < result.mayTake { picks.insert(j) } }
                                            else { picks.remove(j) }
                                        })) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(battle.shipName(j, game.status)).fontWeight(.semibold)
                                                Text("내구 \(game.status.memory[slot + 2])/\(game.status.memory[slot + 3]) · 대포 \(game.status.memory[slot + 6])문 · 편입 선원 \(game.status.memory.word(slot) / 10)명")
                                                    .font(GameFont.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        .disabled(!picks.contains(j) && picks.count >= result.mayTake)
                                        .accessibilityIdentifier("portolan.battle.prize.\(j)")
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 150)
                            Text("동료가 선장이 되면 기존 직책은 해제됩니다. 편성(F2)의 승무원편성·적하편성에서 선원과 보급품을 배분하세요.")
                                .font(GameFont.caption).foregroundStyle(.secondary)
                        }
                    } else if victory {
                        Text("주변에 나포할 수 있는 적선이 없습니다.").font(GameFont.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if hasPrizes { Text("선택 \(picks.count) / \(result.mayTake)척").monospacedDigit() }
                        Spacer()
                        Button(picks.isEmpty ? "확인" : "나포 확정 · \(picks.count)척") {
                            game.closeBattle(taking: picks.sorted())
                        }
                        .accessibilityIdentifier("portolan.battle.result.close")
                        .buttonStyle(GameButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    }
                }
                .padding(24)
                .frame(width: min(760, geometry.size.width - 40))
                .frame(maxHeight: geometry.size.height - 40)
                .gamePanel(radius: 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Fleets within two tiles: hail (교섭) or attack (전투) (sea menu 28).
struct NearbyFleets: View {
    @ObservedObject var game: Game

    var body: some View {
        let v = game.status
        let near = v.fleetsNearby()
        if !near.isEmpty && game.harbor == nil {
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(near, id: \.self) { f in
                        let adm = v.memory.fb(f, FleetField.admiral)
                        HStack {
                            Circle().fill(WorldOverlay.nationColors[min(6, f / 10)]).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(adm < 120 ? v.memory.person(adm).name : "함대").font(GameFont.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    Text("\((0..<10).filter { v.memory.slotUsed(f, $0) }.count)척").font(GameFont.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("교섭") { game.hailFleet(f) }.accessibilityIdentifier("portolan.fleet.hail.\(f)")
                                    Button("전투") { game.attackFleet(f) }.accessibilityIdentifier("portolan.fleet.attack.\(f)")
                                }
                            }
                        }
                    }
                }.frame(width: 320)
            }
        }
    }
}

/// Battle 정보 items 3–6 (0xAC8E, 0xACF5, 0xAD6D, 0xAEF7): the other fleets, their admirals and
/// ships, and the orders of the player's ships.
struct BattleReport: View {
    @ObservedObject var game: Game
    let battle: Battle
    let kind: Int
    let close: () -> Void

    var body: some View {
        let v = game.status
        let b = battle
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(game.menu(51, kind)).font(GameFont.title3.bold())
                    Spacer()
                    Button { close() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        switch kind {
                        case 3: ForEach(b.otherSides(v), id: \.self) { s in fleet(b, v, s) }
                        case 4: ForEach(b.otherSides(v), id: \.self) { s in if let p = b.admirals[s] { admiral(v, p) } }
                        case 5: ForEach(b.otherSides(v).flatMap { b.sides[$0] }.filter { b.alive($0, v) }, id: \.self) { k in ship(b, v, k) }
                        default:
                            let own = b.units.indices.filter { b.units[$0].fleet == v.playerFleet && b.alive($0, v) }
                            ForEach(Array(own.enumerated()), id: \.offset) { n, k in
                                HStack {
                                    Text(String(format: "%2d: ", n + 1) + b.shipName(k, v)).frame(width: 200, alignment: .leading)
                                    Text(b.ordersText(k, v)).foregroundStyle(.secondary)
                                }.font(GameFont.callout)
                            }
                        }
                    }
                }.frame(maxHeight: 420)
            }
            .padding(20)
            .frame(width: min(760, geometry.size.width - 40), height: min(560, geometry.size.height - 32))
            .gamePanel(radius: 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fleet(_ b: Battle, _ v: Voyage, _ s: Int) -> some View {
        let sum = b.fleetSummary(side: s, v)
        let adm = b.admirals[s] ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(v.memory.person(adm).name) 제독").font(GameFont.headline)
            Text("항해 레벨: \(v.memory.pb(adm, 0x24))   전투 레벨: \(v.memory.pb(adm, 0x25))").monospacedDigit()
            Text("함대선회력: \(sum.rudder)  선원 총수: \(sum.crew)명").monospacedDigit()
            Text("함대추진력: \(sum.sail)  총포문수 : \(sum.guns)").monospacedDigit()
            Text("함대내구력: \(sum.hull)  전투력   : \(sum.power)").monospacedDigit()
        }
    }

    /// 0x1C215 with own = 0: no ship, role, pay or title.
    private func admiral(_ v: Voyage, _ p: Int) -> some View {
        let m = v.memory
        return HStack(alignment: .top, spacing: 14) {
            if let img = game.portrait(person: p) {
                Image(nsImage: img).pixelated().frame(width: 64, height: 80).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(m.person(p).name).font(GameFont.headline)
                Text("연령: \(m.pb(p, 0x2A))세   국적／ \(m.name(0x866, min(6, m.pb(p, 0x31) & 0xF)))")
                Text((0..<7).map { "\(m.name(0x87E, $0)) \(m.pb(p, 0x1C + $0))" }.joined(separator: "  ")).font(GameFont.caption)
                Text("항해 레벨: \(m.pb(p, 0x24))   전투 레벨: \(m.pb(p, 0x25))")
            }.monospacedDigit().font(GameFont.callout)
        }
    }

    /// 0x1C02E: class, 기함 or N호선, armament and four bars.
    private func ship(_ b: Battle, _ v: Voyage, _ k: Int) -> some View {
        let cls = b.shipClass(k, v)
        let c = game.world.navigation.classes.indices.contains(cls) ? game.world.navigation.classes[cls] : nil
        let idx = b.sides.first { $0.contains(k) }?.firstIndex(of: k) ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(v.memory.person(b.units[k].captain).name) 함대 · " + (b.isFlagship(k) ? "기함" : "\(idx)호선") + " · \(c?.name ?? "")")
                .font(GameFont.headline)
            Text("무장 \(v.memory.name(0x808, b.gunType(k, v)))  \(b.guns(k, v))문")
            Text("HULL \(b.hull(k, v))/\(b.maxHull(k, v))  RUDDER \(b.rudder(k, v))/\(c?.rudder ?? 0)  SAILS \(b.sails(k, v))/\(c?.sail ?? 0)  CREW \(b.crew(k, v))/\(b.maxCrew(k, v))")
                .font(GameFont.caption.monospaced())
        }
    }
}
