import SwiftUI
import PortolanCore

/// The duel's fighting box (sprites.md §7): a 192×120 window on the sea or port backdrop that
/// slides with the meter, the hero (IAP) on the right and the opponent (IAE1) on the left, each
/// a body strip plus the weapon overlay of its weapon type, and the rigging in front at sea.
struct DuelStage: View {
    @ObservedObject var game: Game
    let duel: DuelState
    @State private var started = Date.distantPast
    @State private var seenTurn = -1

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { t in
            box(t.date.timeIntervalSince(started), t.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: 384, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear { seenTurn = duel.turn }
        .onChange(of: duel.turn) { _, t in
            if t != seenTurn {
                seenTurn = t
                started = Date()
                // Step 3 of the exchange (0x11FF1 / 0x11FF7).
                game.sfx.play(duel.lastDamage > 0 ? "duel_hit" : "duel_miss", after: 3 * 0.09)
            }
        }
    }

    private var atSea: Bool { game.harbor == nil }

    /// Camera k (0x11208): `(200 − meter)/20` when the hero challenged, else `meter/20`.
    private var camera: Int {
        let k = duel.playerIsA ? (200 - duel.meter) / 20 : duel.meter / 20
        return max(0, min(10, k))
    }

    /// The frame of each side now: (group, frame, back steps).
    private func pose(_ age: TimeInterval, _ clock: TimeInterval) -> (hero: (Int, Int, Int), enemy: (Int, Int, Int)) {
        let ready = Int(clock / 0.3) % 2
        if duel.finished {
            let heroWon = duel.playerIsA ? duel.meter >= 100 : duel.meter < 100
            let victory = 4 + Int(clock / 0.3) % 2
            return heroWon ? ((0, victory, 0), (0, 3, 0)) : ((0, 3, 0), (0, victory, 0))
        }
        guard duel.turn > 0, age < 6 * 0.09 + (duel.lastDamage > 0 ? 0.5 : 0) else { return ((0, ready, 0), (0, ready, 0)) }
        // The last exchange (0x11E80): the attacker's and defender's moves from the histories.
        let aAttacked = (duel.turn - 1) % 2 == 0
        let m = (aAttacked ? duel.histA : duel.histB) & 3, dm = (aAttacked ? duel.histB : duel.histA) & 3
        let heroAttacked = aAttacked == duel.playerIsA
        let step = min(5, Int(age / 0.09))
        let steps: [[(Int, Int)]] = [[(6, 0), (1, 0), (7, 0), (8, 0), (0, 0), (1, 0)], [(6, 0), (7, 0), (8, 0), (9, 0), (0, 0), (1, 0)],
                                     [(6, 0), (7, 0), (8, 0), (8, 0), (0, 0), (1, 0)], [(1, 0), (6, 1), (7, 1), (7, 1), (8, 1), (1, 1)],
                                     [(1, 0), (6, 1), (7, 1), (7, 1), (8, 1), (1, 1)], [(6, 0), (7, 1), (7, 2), (8, 2), (8, 2), (1, 2)]]
        func frame(_ group: Int, _ s: (Int, Int)) -> (Int, Int, Int) { s.0 >= 6 ? (group, s.0 - 6, s.1) : (0, s.0, s.1) }
        let att = frame(1 + min(2, m), steps[min(2, m)][step])
        var def = frame(4 + min(2, dm), steps[3 + min(2, dm)][step])
        if duel.lastDamage > 0 && age >= 3 * 0.09 { def = (0, 2, 0) }                 // hit: stance frame 2
        return heroAttacked ? (att, def) : (def, att)
    }

    private func box(_ age: TimeInterval, _ clock: TimeInterval) -> some View {
        let k = camera
        let p = pose(age, clock)
        let hero = min(5, game.status.heroID)
        let heroWeapon = (duel.playerIsA ? duel.weaponA : duel.weaponB).2
        let enemyWeapon = (duel.playerIsA ? duel.weaponB : duel.weaponA).2
        return ZStack(alignment: .topLeading) {
            if let bg = game.image("sprites/duel/backdrop_\(atSea ? "sea" : "port").png") {
                Image(nsImage: bg).pixelated().frame(width: 384, height: 120).offset(x: -CGFloat(8 * (7 + k)))
            }
            fighter("hero\(hero)", p.hero, weapon: heroWeapon, shift: -8 + 8 * p.hero.2)
            fighter("enemy", p.enemy, weapon: enemyWeapon, shift: 8 - 8 * p.enemy.2)
            if atSea {
                if let l = game.image("sprites/duel/overlay_left.png") {
                    Image(nsImage: l).pixelated().frame(width: 72, height: 120).offset(x: -CGFloat(8 * (7 + k)))
                }
                if let r = game.image("sprites/duel/overlay_right.png") {
                    Image(nsImage: r).pixelated().frame(width: 72, height: 120).offset(x: CGFloat(312 - 8 * (7 + k)))
                }
            }
        }
        .frame(width: 192, height: 120, alignment: .topLeading)
        .clipped()
        .scaleEffect(2, anchor: .topLeading)
        .frame(width: 384, height: 240, alignment: .topLeading)
    }

    /// Frame n of a strip sits at x = 192·n, already placed in the box.
    private func fighter(_ who: String, _ pose: (Int, Int, Int), weapon: Int, shift: Int) -> some View {
        let (g, f, _) = pose
        return ZStack(alignment: .topLeading) {
            ForEach(["body", "weapon\(max(0, min(3, weapon)))"], id: \.self) { part in
                if let img = game.image("sprites/duel/\(who)_g\(g)_\(part).png") {
                    Image(nsImage: img).pixelated()
                        .frame(width: img.size.width, height: 120)
                        .offset(x: -CGFloat(192 * f))
                        .frame(width: 192, height: 120, alignment: .topLeading)
                        .clipped()
                }
            }
        }
        .offset(x: CGFloat(shift))
    }
}
