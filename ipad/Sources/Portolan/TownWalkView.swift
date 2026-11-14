import SwiftUI
import PortolanCore

/// The walking town (docs/re/town_walk.md §2): a 24×24-tile window over the port map, the hero,
/// the townsfolk and the compass rose. Arrows, WASD and the keypad walk; so does holding the
/// mouse on the map (toward the pointer) or on the compass.
struct TownWalkView: View {
    @ObservedObject var game: Game
    let harbor: Harbor
    /// The window's height on screen; 384 is one pixel a dot (24 tiles).
    var side: CGFloat = 480
    /// The window's width; nil keeps the original square of 24×24 tiles, wider shows more of the
    /// town to the sides around the original window.
    var width: CGFloat? = nil
    /// Only the map window (the original screen layout draws the compass in its frame).
    var windowOnly = false

    var body: some View {
        let v = game.status
        if windowOnly, let m = game.world.town(harbor.id) {
            window(v, m)
        } else {
            layout(v)
        }
    }

    /// The town filling its frame, the direction pad over its lower right corner and a line of
    /// key hints over its lower left.
    /// The pad's size: the thumb needs room on a tablet.
    private var padScale: CGFloat {
        #if os(macOS)
        0.72
        #else
        1.0
        #endif
    }

    private func layout(_ v: Voyage) -> some View {
        #if os(macOS)
        let padSide = Alignment.bottomTrailing
        #else
        let padSide = Alignment.bottomLeading                     // the left thumb on a tablet
        #endif
        return ZStack(alignment: padSide) {
            if let m = game.world.town(harbor.id) {
                window(v, m)
            }
            DirectionPad(facing: game.townFace & 3, active: game.townAim) { game.townAim = $0 }
                .scaleEffect(padScale)
                .frame(width: 176 * padScale, height: 176 * padScale)
                .padding(8)
                .opacity(0.92)
        }
        #if os(macOS)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 10) {
                KeyHint(keys: "WASD · ↑←↓→", text: "걷기", width: nil)
                KeyHint(keys: "마우스", text: "누른 채 끌기", width: nil)
                Text("문에 닿으면 들어갑니다").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.navy.opacity(0.78), in: Capsule())
            .padding(10)
            .allowsHitTesting(false)
        }
        #endif
    }

    /// Tiles across the window, and its left edge in tiles: the original 24-tile window stays in
    /// the middle and the rest of the width shows the town to either side (kept on the 96-tile map).
    private func across(_ scale: CGFloat) -> Double { windowOnly ? 24 : min(96, Double((width ?? side) / scale / 16)) }
    private func left(_ camX: Double, _ tiles: Double) -> Double { max(0, min(96 - tiles, camX + 12 - tiles / 2)) }

    private func window(_ v: Voyage, _ m: TownMap) -> some View {
        let cam = v.townCamera
        let scale = side / 384
        let tiles = across(scale)
        let x0 = left(Double(cam.x), tiles)
        return TimelineView(.animation) { tl in
            // How far into the latest step (one pass of the walk loop) we are: the camera and
            // everyone who moved one tile slide there; frames switch at once, so nothing smears.
            let p = min(1, max(0, tl.date.timeIntervalSince(game.townPassAt) / game.townStepTime))
            let before = game.townBefore
            let g = glide(before?.camera, cam, p)
            let c = (x: left(g.x, tiles), y: g.y)
            ZStack(alignment: .topLeading) {
                if let img = game.image(String(format: "portmaps/%03d.png", m.map)) {
                    Image(nsImage: img).pixelated().frame(width: 1536, height: 1536)
                        .offset(x: -c.x * 16, y: -c.y * 16)
                }
                sprite(heroFrame(v), glide(before?.hero, v.townHero, p), c)
                ForEach(v.townsfolk.filter { !$0.walker }, id: \.slot) { f in sprite(standingFrame(f), (Double(f.x), Double(f.y)), c) }
                ForEach(v.townsfolk.filter(\.walker), id: \.slot) { f in
                    sprite(walkerFrame(f), glide(before?.folk[f.slot], (f.x, f.y), p), c)
                }
                phaseTint(v.tick, width: tiles * 16).allowsHitTesting(false)
            }
        }
        .frame(width: tiles * 16, height: 384, alignment: .topLeading)
        .clipped()
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: tiles * 16 * scale, height: side, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: windowOnly ? 0 : 10))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                // Toward the pointer from the hero's middle, along the longer axis.
                let h = v.townHero
                let hx = (CGFloat(Double(h.x) - x0) * 16 + 16) * scale, hy = (CGFloat(h.y - cam.y) * 16 + 16) * scale
                let dx = g.location.x - hx, dy = g.location.y - hy
                guard max(abs(dx), abs(dy)) > 12 else { return }
                game.townAim = abs(dx) > abs(dy) ? (dx > 0 ? 1 : 3) : (dy > 0 ? 2 : 0)
            }
            .onEnded { _ in game.townAim = nil })
        .onContinuousHover { phase in
            // The town's arrow cursors (0x1B337: cursors[aim]).
            guard case .active(let at) = phase else { NSCursor.arrow.set(); return }
            let h = v.townHero
            let hx = (CGFloat(Double(h.x) - x0) * 16 + 16) * scale, hy = (CGFloat(h.y - cam.y) * 16 + 16) * scale
            let dx = at.x - hx, dy = at.y - hy
            let name = max(abs(dx), abs(dy)) < 16 ? "cursor_centre" : abs(dx) > abs(dy) ? (dx > 0 ? "cursor_E" : "cursor_W") : (dy > 0 ? "cursor_S" : "cursor_N")
            GameMTKView.cursor(name, assets: game.assets).set()
        }
    }

    /// From `from` toward `to` by p, for a move of at most one tile a side; a jump lands at once.
    private func glide(_ from: (x: Int, y: Int)?, _ to: (x: Int, y: Int), _ p: Double) -> (x: Double, y: Double) {
        guard let f = from, abs(f.x - to.x) <= 1, abs(f.y - to.y) <= 1 else { return (Double(to.x), Double(to.y)) }
        return (Double(f.x) + Double(to.x - f.x) * p, Double(f.y) + Double(to.y - f.y) * p)
    }

    private func sprite(_ name: String, _ at: (x: Double, y: Double), _ cam: (x: Double, y: Double)) -> some View {
        Group {
            if (cam.x - 2...cam.x + 98).contains(at.x), (cam.y - 2...cam.y + 24).contains(at.y),
               let img = game.image("townchars/" + name) {
                Image(nsImage: img).pixelated().frame(width: 32, height: 32)
                    .offset(x: (at.x - cam.x) * 16, y: (at.y - cam.y) * 16)
            }
        }
    }

    private static let dirNames = ["up", "right", "down", "left"]

    private func heroFrame(_ v: Voyage) -> String {
        "hero\(min(5, v.heroID))_\(Self.dirNames[game.townFace & 3])_\(game.townStepFrame).png"
    }

    /// Walkers: A in slots 0 and 2, B in 1 and 3; the step frame follows the tile parity (0x6147).
    private func walkerFrame(_ p: Townsperson) -> String {
        "walker_\(p.slot & 1 == 0 ? "a" : "b")_\(Self.dirNames[p.k & 3])_\((p.x + p.y) % 2 == 0 ? 1 : 0).png"
    }

    /// Standing figures flicker between their two frames.
    private func standingFrame(_ p: Townsperson) -> String {
        let kind = ["man", "dog", "guard", "merchant"][min(3, p.k)]
        return "stand_\(kind)_\((game.townStepFrame + p.slot + Int(game.clock * 3)) % 2).png"
    }

    /// The time-of-day palette (DS:0xAD22 + 0x30·phase): only the town tiles change colour in
    /// the original; here the whole window is tinted.
    private func phaseTint(_ tick: Int, width: Double = 384) -> some View {
        let phase = [0, 1, 2, 2, 3, 0][min(5, tick / 12)]
        let colors: [Color] = [Color(red: 0.05, green: 0.08, blue: 0.3).opacity(0.45), Color(red: 0.9, green: 0.6, blue: 0.4).opacity(0.12),
                               .clear, Color(red: 0.95, green: 0.45, blue: 0.2).opacity(0.18)]
        return colors[phase].blendMode(.multiply).frame(width: width, height: 384)
    }
}

/// The town's direction pad: four keys around a ring, the way the hero faces lit in gold; hold one
/// to walk (the original compass rose, DS:0xAE14 rects 0–3).
struct DirectionPad: View {
    let facing: Int
    let active: Int?
    let aim: (Int?) -> Void

    private static let symbols = ["chevron.up", "chevron.right", "chevron.down", "chevron.left"]
    private static let offsets: [(CGFloat, CGFloat)] = [(0, -52), (52, 0), (0, 52), (-52, 0)]

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.13, green: 0.17, blue: 0.27), Color(red: 0.05, green: 0.07, blue: 0.12)],
                                     center: .center, startRadius: 4, endRadius: 86))
                .overlay(Circle().strokeBorder(Theme.gold.opacity(0.35), lineWidth: 1.5))
                .overlay(Circle().inset(by: 8).strokeBorder(.white.opacity(0.06), lineWidth: 1))
                .frame(width: 168, height: 168)
                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
            Image(systemName: "figure.walk")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            ForEach(0..<4, id: \.self) { d in key(d).allowsHitTesting(false) }
        }
        .frame(width: 176, height: 176)
        .contentShape(Circle())
        #if os(macOS)
        // One stick over the whole disc: the pointer may slide from key to key, and the direction
        // follows the longer axis (with a little hysteresis, so it does not flutter on diagonals).
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                let dx = g.location.x - 88, dy = g.location.y - 88
                guard hypot(dx, dy) > 12 else { return }
                var d = abs(dx) > abs(dy) ? (dx > 0 ? 1 : 3) : (dy > 0 ? 2 : 0)
                if let a = active, a != d {
                    let along = (a == 1 || a == 3) ? abs(dx) : abs(dy), across = (a == 1 || a == 3) ? abs(dy) : abs(dx)
                    if across < along * 1.25 { d = a }
                }
                if d != active { aim(d) }
            }
            .onEnded { _ in aim(nil) })
        #else
        // Every finger counts: hold one direction and touch another with a second finger, and the
        // newest touch steers; lifting it goes back to the one still held.
        .overlay(MultiTouchPad(aim: aim))
        #endif
    }

    private func key(_ d: Int) -> some View {
        let lit = active == d || (active == nil && facing == d)
        let pressed = active == d
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(pressed ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Color.white.opacity(lit ? 0.16 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(lit ? Theme.gold.opacity(0.9) : .white.opacity(0.12), lineWidth: lit ? 1.5 : 1))
            .overlay(Image(systemName: Self.symbols[d]).font(.system(size: 18, weight: .bold))
                .foregroundStyle(pressed ? Color.black.opacity(0.8) : lit ? Theme.gold : .white.opacity(0.75)))
            .frame(width: 46, height: 46)
            .scaleEffect(pressed ? 0.94 : 1)
            .offset(x: Self.offsets[d].0, y: Self.offsets[d].1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

/// A key cap and what it does.
struct KeyHint: View {
    let keys: String
    let text: String
    /// A fixed width lines several hints up; nil hugs the text.
    var width: CGFloat? = 160
    var body: some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.18)))
            Text(text).font(GameFont.caption).foregroundStyle(.secondary)
            if width != nil { Spacer(minLength: 0) }
        }
        .frame(width: width)
    }
}

#if !os(macOS)
/// Tracks all touches on the pad; the direction is the newest touch's, by the longer axis. It is a
/// gesture recognizer that nothing can pre-empt, so a slide is not cut off when a parent view's
/// gesture would otherwise claim the touch.
struct MultiTouchPad: UIViewRepresentable {
    let aim: (Int?) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        let r = PadRecognizer()
        r.aim = aim
        r.cancelsTouchesInView = false
        r.delaysTouchesBegan = false
        r.delaysTouchesEnded = false
        v.addGestureRecognizer(r)
        context.coordinator.recognizer = r
        return v
    }
    func updateUIView(_ v: UIView, context: Context) { context.coordinator.recognizer?.aim = aim }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var recognizer: PadRecognizer? }

    final class PadRecognizer: UIGestureRecognizer {
        var aim: (Int?) -> Void = { _ in }
        private var order: [UITouch] = []          // oldest first
        private var current: Int?
        private let feedback = UISelectionFeedbackGenerator()

        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }

        private func direction(_ t: UITouch) -> Int? {
            guard let v = view else { return nil }
            let p = t.location(in: v)
            let dx = p.x - v.bounds.midX, dy = p.y - v.bounds.midY
            guard hypot(dx, dy) > 12 else { return nil }
            return abs(dx) > abs(dy) ? (dx > 0 ? 1 : 3) : (dy > 0 ? 2 : 0)
        }

        private func update() {
            let d = order.reversed().lazy.compactMap { self.direction($0) }.first
            guard d != current else { return }
            current = d
            aim(d)
            if d != nil { feedback.selectionChanged() }
        }

        private func finish() {
            order.removeAll()
            if current != nil { current = nil; aim(nil) }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            order.append(contentsOf: touches)
            if state == .possible { state = .began } else { state = .changed }
            update()
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { state = .changed; update() }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            order.removeAll { touches.contains($0) }
            update()
            if order.isEmpty { state = .ended }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            order.removeAll { touches.contains($0) }
            update()
            if order.isEmpty { state = .cancelled }
        }
        override func reset() { finish() }
    }
}
#endif
