import SwiftUI
import PortolanCore

/// Ship, course line and port labels, drawn on top of the Metal world every frame.
struct WorldOverlay: View {
    let game: Game

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { ctx, size in draw(&ctx, size) }
        }
        .allowsHitTesting(false)
    }

    private func screen(_ x: Double, _ y: Double, _ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + game.world.deltaX(from: game.camera.x, to: x) * game.zoom,
                y: size.height / 2 + (y - game.camera.y) * game.zoom)
    }

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let v = game.voyage
        for p in game.world.ports where !game.classicLayout && v.memory[DS.port + DS.portSize * p.id + 0x13] & 0x10 != 0 {             // the original marks no ports
            let s = screen(Double(p.x), Double(p.y), size)
            guard s.x > -80, s.x < size.width + 80, s.y > -30, s.y < size.height + 30 else { continue }
            let r = game.zoom > 3 ? 4.5 : 2.5
            let dot = Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2))
            ctx.fill(dot, with: .color(Color(red: 0.97, green: 0.78, blue: 0.36)))
            ctx.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1)
            if game.zoom > 2.2 {
                let text = Text(p.name).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundColor(.white)
                ctx.drawLayer { c in
                    c.addFilter(.shadow(color: .black.opacity(0.9), radius: 2))
                    c.draw(text, at: CGPoint(x: s.x, y: s.y + 14))
                }
            }
        }
        if let w = v.waypoint {
            let start = screen(v.x, v.y, size)
            var line = Path()
            line.move(to: start)
            var previous = start
            let points = [[w.x, w.y]] + v.route
            for point in points where point.count == 2 {
                let next = screen(point[0], point[1], size)
                if abs(next.x - previous.x) > Double(World.width) * game.zoom / 2 { line.move(to: next) }
                else { line.addLine(to: next) }
                previous = next
            }
            ctx.stroke(line, with: .color(Theme.current.opacity(0.85)), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
            ctx.stroke(Path(ellipseIn: CGRect(x: previous.x - 7, y: previous.y - 7, width: 14, height: 14)), with: .color(Theme.gold), lineWidth: 2)
        }
        for f in v.fleetsInSight() {
            let at = v.memory.fleetAt(f)
            drawFleet(&ctx, at: screen(Double(at.x) + 0.5, Double(at.y) + 0.5, size), fleet: f, voyage: v)
        }
        drawShip(&ctx, at: screen(v.x, v.y, size), voyage: v)
    }

    /// Nation colours (Portugal, Spain, Turkey, England, Italy, Netherlands, pirates).
    static let nationColors: [Color] = [
        Color(red: 0.2, green: 0.55, blue: 0.95), Color(red: 0.95, green: 0.8, blue: 0.2), Color(red: 0.2, green: 0.75, blue: 0.4),
        Color(red: 0.92, green: 0.92, blue: 0.95), Color(red: 0.6, green: 0.35, blue: 0.85), Color(red: 0.98, green: 0.55, blue: 0.2),
        Color(red: 0.85, green: 0.15, blue: 0.15)]

    /// The world-map fleet sprites (DATA1[11] 0x4000, sprites.md §2): player or other fleet,
    /// oared or sail-only, four directions from the eight-way heading, two bob frames.
    private func sprite(_ ctx: inout GraphicsContext, at p: CGPoint, player: Bool, sail: Bool, heading8: Int, order: Int) {
        let row = (player ? 0 : 2) + (sail ? 1 : 0)
        let dir = [0, 1, 1, 1, 2, 3, 3, 3][heading8 & 7]
        let frame = (Int(game.clock * 72 / Voyage.secondsPerDay) + order) & 1
        guard let img = game.image("sprites/ships/world_\(row)_\(dir)_\(frame).png") else { return }
        let side = max(24, game.zoom * 2)
        ctx.draw(Image(nsImage: img).interpolation(.none), in: CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side))
    }

    /// Another fleet, with a pennant in its nation's colour (a remaster aid).
    private func drawFleet(_ ctx: inout GraphicsContext, at p: CGPoint, fleet f: Int, voyage v: Voyage) {
        let cls = v.memory.shipClass(f, 0)
        let sail = game.world.navigation.classes.indices.contains(cls) ? !game.world.navigation.classes[cls].oars : true
        sprite(&ctx, at: p, player: false, sail: sail, heading8: v.memory.fb(f, FleetField.heading), order: f)
        let side = max(24, game.zoom * 2)
        let pennant = Path(roundedRect: CGRect(x: p.x - 3, y: p.y - side / 2 - 6, width: 9, height: 5), cornerRadius: 1)
        ctx.fill(pennant, with: .color(WorldOverlay.nationColors[min(6, f / 10)]))
        ctx.stroke(pennant, with: .color(.black.opacity(0.6)), lineWidth: 0.5)
    }

    /// The player's fleet: the flagship decides oared or sail-only (0x6D89).
    private func drawShip(_ ctx: inout GraphicsContext, at p: CGPoint, voyage v: Voyage) {
        let cls = v.ships.first?.classIndex ?? 0
        let sail = game.world.navigation.classes.indices.contains(cls) ? !game.world.navigation.classes[cls].oars : true
        sprite(&ctx, at: p, player: true, sail: sail, heading8: v.heading8, order: 0)
    }
}
