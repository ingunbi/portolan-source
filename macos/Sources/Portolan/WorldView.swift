import MetalKit
import SwiftUI
#if os(macOS)

final class GameMTKView: MTKView {
    var game: Game?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// The direction cursors around the fleet (DATA1[14] 0x2570, chosen by 0x1B412): an arrow
    /// toward the pointer, the wheel over the fleet itself.
    override func mouseMoved(with e: NSEvent) {
        guard let g = game, g.harbor == nil, g.battle == nil else { return }
        let p = convert(e.locationInWindow, from: nil)
        let dx = g.world.deltaX(from: g.camera.x, to: g.voyage.x) * g.zoom + bounds.width / 2
        let dy = bounds.height / 2 - (g.voyage.y - g.camera.y) * g.zoom
        let vx = p.x - dx, vy = p.y - dy
        let name: String
        if hypot(vx, vy) < max(14, g.zoom) {
            name = "cursor_centre"
        } else {
            let a = atan2(vy, vx)                                      // 0 = east, counter-clockwise
            let k = Int(((a / (.pi / 4)).rounded() + 8)) % 8
            name = "cursor_" + ["E", "NE", "N", "NW", "W", "SW", "S", "SE"][k]
        }
        GameMTKView.cursor(name, assets: g.assets).set()
    }

    override func mouseExited(with e: NSEvent) { NSCursor.arrow.set() }

    private static var cursors: [String: NSCursor] = [:]

    static func cursor(_ name: String, assets: URL) -> NSCursor {
        if let c = cursors[name] { return c }
        guard let img = NSImage(contentsOf: assets.appendingPathComponent("sprites/ui/\(name).png")) else { return .arrow }
        img.size = NSSize(width: 24, height: 24)
        let c = NSCursor(image: img, hotSpot: NSPoint(x: 12, y: 12))
        cursors[name] = c
        return c
    }

    // The window's key monitor (Game.installKeyMonitor) normally takes the game's keys first.
    override func keyDown(with e: NSEvent) {
        if game?.handleKey(e) != true { super.keyDown(with: e) }
    }

    override func keyUp(with e: NSEvent) { game?.handleKey(e) }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        game?.click(CGPoint(x: p.x, y: bounds.height - p.y))
    }

    override func scrollWheel(with e: NSEvent) {
        guard let g = game else { return }
        g.setZoom(g.zoom * pow(1.02, e.scrollingDeltaY))
    }

    override func magnify(with e: NSEvent) {
        guard let g = game else { return }
        g.setZoom(g.zoom * (1 + e.magnification))
    }
}

struct WorldView: NSViewRepresentable {
    let game: Game

    final class Coordinator { var renderer: WorldRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GameMTKView {
        let v = GameMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.game = game
        v.colorPixelFormat = .bgra8Unorm
        v.preferredFramesPerSecond = 60
        do {
            let r = try WorldRenderer(view: v, game: game)
            context.coordinator.renderer = r
            v.delegate = r
        } catch {
            NSLog("Portolan renderer failed: \(error)")
        }
        return v
    }

    func updateNSView(_ nsView: GameMTKView, context: Context) {}
}

#else
import UIKit

/// The map on iPadOS: a tap sets a course, a pinch zooms (the mac view's mouse and scroll wheel).
final class GameMTKView: MTKView {
    var game: Game?

    @objc func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        game?.click(CGPoint(x: p.x, y: p.y))
    }

    private var startZoom = 1.0
    @objc func pinched(_ g: UIPinchGestureRecognizer) {
        guard let game else { return }
        if g.state == .began { startZoom = game.zoom }
        game.setZoom(startZoom * Double(g.scale))
    }

    /// Cursors are a mouse idea; the shared views ask for one by name and get nothing here.
    static func cursor(_ name: String, assets: URL) -> NSCursor { NSCursor() }
}

struct WorldView: UIViewRepresentable {
    let game: Game

    final class Coordinator { var renderer: WorldRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> GameMTKView {
        let v = GameMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.game = game
        v.colorPixelFormat = .bgra8Unorm
        v.preferredFramesPerSecond = 60
        v.addGestureRecognizer(UITapGestureRecognizer(target: v, action: #selector(GameMTKView.tapped(_:))))
        v.addGestureRecognizer(UIPinchGestureRecognizer(target: v, action: #selector(GameMTKView.pinched(_:))))
        do {
            let r = try WorldRenderer(view: v, game: game)
            context.coordinator.renderer = r
            v.delegate = r
        } catch {
            NSLog("Portolan renderer failed: \(error)")
        }
        return v
    }

    func updateUIView(_ view: GameMTKView, context: Context) {}
}
#endif
