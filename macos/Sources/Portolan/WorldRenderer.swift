import Metal
import MetalKit
import PortolanCore

struct WorldUniforms {
    var center: SIMD2<Float>
    var viewport: SIMD2<Float>
    var tilesPerPixel: Float
    var time: Float
    var daylight: Float
}

struct ClassicUniforms {
    var center: SIMD2<Float>
    var viewport: SIMD2<Float>
    var tilesPerPixel: Float
    // Three floats, not a SIMD3 (16-byte aligned), so the palette sits at offset 32 as in Metal.
    var pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
    var palette: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                  SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
}

/// The original chip map (assets/seamap): chips.bin, the colour indices of the 128 chips, the five
/// palettes, and the port and village chips shown once known (seamap.md "For the remaster").
final class ClassicMap {
    struct Marker {
        let kind: String
        let id: Int
        let x: Int, y: Int
        let chips: [Int]
        let hidden: Int
    }
    let chips: MTLTexture
    let atlas: MTLTexture
    let phases: [[SIMD3<Float>]]
    var markers: [Marker] = []
    var shown: [Bool] = []
    /// chips.bin as loaded, to undo a window's overrides.
    private let base: [UInt8]
    /// windowOverrides (seamap.md §6): tiles [x, y, chip] that differ while the fleet's 72×72
    /// window is the keyed one, where the game's desert fill restarts at the window edge.
    private var overrides: [[Int]: [[Int]]] = [:]
    private var window: [Int]?
    /// The palette on screen, 0..15 per channel, stepping one unit a tick toward the target (0x983F).
    var current: [SIMD3<Float>]
    private var stepClock = 0.0

    init?(device: MTLDevice, assets: URL) {
        let dir = assets.appendingPathComponent("seamap")
        guard let map = try? [UInt8](Data(contentsOf: dir.appendingPathComponent("chips.bin"))), map.count == World.width * World.height,
              let pix = try? [UInt8](Data(contentsOf: dir.appendingPathComponent("chips_indexed.bin"))), pix.count == 128 * 256,
              let d = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let pal = (j["palettes"] as? [String: Any])?["phases"] as? [[[Int]]] else { return nil }
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: World.width, height: World.height, mipmapped: false)
        cd.usage = .shaderRead
        let ad = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: 16, height: 128 * 16, mipmapped: false)
        ad.usage = .shaderRead
        guard let c = device.makeTexture(descriptor: cd), let a = device.makeTexture(descriptor: ad) else { return nil }
        c.replace(region: MTLRegionMake2D(0, 0, World.width, World.height), mipmapLevel: 0, withBytes: map, bytesPerRow: World.width)
        a.replace(region: MTLRegionMake2D(0, 0, 16, 128 * 16), mipmapLevel: 0, withBytes: pix, bytesPerRow: 16)
        chips = c
        atlas = a
        base = map
        for w in (j["windowOverrides"] as? [String: Any])?["windows"] as? [[String: Any]] ?? [] {
            guard let t = w["third"] as? Int, let col = w["blockCol"] as? Int, let row = w["blockRow"] as? Int,
                  let tiles = w["tiles"] as? [[Int]] else { continue }
            overrides[[t, col, row]] = tiles
        }
        phases = pal.map { $0.map { SIMD3(Float($0[0]) / 17, Float($0[1]) / 17, Float($0[2]) / 17) } }
        current = phases[2]
        for m in j["markers"] as? [[String: Any]] ?? [] {
            guard let kind = m["kind"] as? String, let id = m["id"] as? Int, let x = m["x"] as? Int, let y = m["y"] as? Int,
                  let cs = m["chips"] as? [Int], let h = m["hidden"] as? Int else { continue }
            markers.append(Marker(kind: kind, id: id, x: x, y: y, chips: cs, hidden: h))
        }
        shown = markers.map { _ in false }
    }

    /// The fleet's window (0x69DA): its 720-tile third, block column `clamp((x/24) % 30 − 1, 0, 27)`,
    /// block row `clamp(y/24 − 1, 0, 42)`; its overrides replace the plain chips while it lasts.
    func follow(x: Double, y: Double) {
        let tx = Int(x) % World.width, ty = max(0, min(World.height - 1, Int(y)))
        let key = [tx / 720, max(0, min(27, (tx / 24) % 30 - 1)), max(0, min(42, ty / 24 - 1))]
        guard key != window else { return }
        if let old = window, let tiles = overrides[old] {
            for t in tiles { put(t[0], t[1], base[t[1] * World.width + t[0]]) }
        }
        if let tiles = overrides[key] {
            for t in tiles { put(t[0], t[1], UInt8(t[2])) }
        }
        window = key
    }

    private func put(_ x: Int, _ y: Int, _ chip: UInt8) {
        var b = chip
        chips.replace(region: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0, withBytes: &b, bytesPerRow: 1)
    }

    /// Ports show once known (port +0x13 & 0x10), villages once sighted (site +6 & 0x40).
    func reveal(_ memory: DataSegment) {
        for (k, m) in markers.enumerated() {
            let on = m.kind == "site" ? memory[Discovery.site(m.id) + 6] & 0x40 != 0 : memory[DS.port + DS.portSize * m.id + 0x13] & 0x10 != 0
            guard on != shown[k] else { continue }
            shown[k] = on
            let tiles = on ? m.chips : [m.hidden, m.hidden, m.hidden, m.hidden]
            for (i, t) in tiles.enumerated() {
                var b = UInt8(t)
                chips.replace(region: MTLRegionMake2D((m.x + i % 2) % World.width, m.y + i / 2, 1, 1), mipmapLevel: 0, withBytes: &b, bytesPerRow: 1)
            }
        }
    }

    /// Phase `[0,1,2,2,3,0][tick/12]`; a storm keeps the night palette, fog its own (§8).
    func step(_ dt: Double, voyage v: Voyage) {
        let target: Int
        if v.eventAnnounced && v.event == .fog { target = 4 } else if v.eventAnnounced && v.event == .storm { target = 0 } else {
            target = [0, 1, 2, 2, 3, 0][min(5, v.tick / 12)]
        }
        stepClock += dt
        while stepClock >= 1 / 60.3 {
            stepClock -= 1 / 60.3
            for i in 0..<16 {
                let t = phases[target][i], c = current[i]
                current[i] = SIMD3(c.x + max(-1, min(1, t.x - c.x)), c.y + max(-1, min(1, t.y - c.y)), c.z + max(-1, min(1, t.z - c.z)))
            }
        }
    }
}

final class WorldRenderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let classicPipeline: MTLRenderPipelineState?
    private let classic: ClassicMap?
    private let mask: MTLTexture
    private let sampler: MTLSamplerState
    private let start = Date()
    private var last = CACurrentMediaTime()
    let game: Game

    init(view: MTKView, game: Game) throws {
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            throw NSError(domain: "Portolan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal을 초기화할 수 없습니다"])
        }
        self.game = game
        self.queue = queue

        let library = try device.makeLibrary(source: worldShader, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "worldVertex")
        desc.fragmentFunction = library.makeFunction(name: "worldFragment")
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        let classicLibrary = try device.makeLibrary(source: classicShader, options: nil)
        let cdesc = MTLRenderPipelineDescriptor()
        cdesc.vertexFunction = classicLibrary.makeFunction(name: "classicVertex")
        cdesc.fragmentFunction = classicLibrary.makeFunction(name: "classicFragment")
        cdesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        classicPipeline = try? device.makeRenderPipelineState(descriptor: cdesc)
        classic = ClassicMap(device: device, assets: game.assets)

        let w = World.width, h = World.height
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: w, height: h, mipmapped: true)
        td.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: td) else {
            throw NSError(domain: "Portolan", code: 2)
        }
        var rg = [UInt8](repeating: 0, count: w * h * 2)
        for (i, t) in game.world.tiles.enumerated() {
            rg[i * 2] = t == World.Terrain.sea.rawValue ? 0 : 255
            rg[i * 2 + 1] = t == World.Terrain.rough.rawValue ? 255 : 0
        }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: rg, bytesPerRow: w * 2)
        if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        mask = texture

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .repeat
        sd.tAddressMode = .clampToEdge
        guard let state = device.makeSamplerState(descriptor: sd) else {
            throw NSError(domain: "Portolan", code: 3)
        }
        sampler = state
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(now - last, 0.05)
        last = now
        #if os(macOS)
        if let w = view.window, let c = w.contentView {
            Game.titleInset = max(0, c.bounds.height - w.contentLayoutRect.height)      // the title bar over the content
        }
        #endif
        game.update(dt: dt, viewSize: view.bounds.size)

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        encode(cmd, pass, viewport: view.drawableSize, scale: Self.backingScale(view))
        cmd.present(drawable)
        cmd.commit()
    }

    private func encode(_ cmd: MTLCommandBuffer, _ pass: MTLRenderPassDescriptor, viewport: CGSize, scale: CGFloat) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if game.classicMap, let c = classic, let cp = classicPipeline {
            c.reveal(game.voyage.memory)
            c.follow(x: game.voyage.x, y: game.voyage.y)
            c.step(1.0 / 60, voyage: game.voyage)
            let p = c.current.map { SIMD4<Float>($0.x / 15, $0.y / 15, $0.z / 15, 1) }
            var u = ClassicUniforms(center: SIMD2(Float(game.camera.x), Float(game.camera.y)),
                                    viewport: SIMD2(Float(viewport.width), Float(viewport.height)),
                                    tilesPerPixel: Float(1 / (game.zoom * Double(scale))),
                                    palette: (p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9], p[10], p[11], p[12], p[13], p[14], p[15]))
            enc.setRenderPipelineState(cp)
            enc.setFragmentBytes(&u, length: MemoryLayout<ClassicUniforms>.stride, index: 0)
            enc.setFragmentTexture(c.chips, index: 0)
            enc.setFragmentTexture(c.atlas, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            return
        }
        var u = WorldUniforms(
            center: SIMD2(Float(game.camera.x), Float(game.camera.y)),
            viewport: SIMD2(Float(viewport.width), Float(viewport.height)),
            tilesPerPixel: Float(1 / (game.zoom * Double(scale))),
            time: Float(Date().timeIntervalSince(start)),
            daylight: Float(game.daylight))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 0)
        enc.setFragmentTexture(mask, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Renders one frame without a window. Used by the snapshot mode.
    func renderOffscreen(width: Int, height: Int, scale: CGFloat) -> CGImage? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let tex = queue.device.makeTexture(descriptor: td), let cmd = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        encode(cmd, pass, viewport: CGSize(width: width, height: height), scale: scale)
        cmd.commit()
        cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        tex.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

extension WorldRenderer {
    static func backingScale(_ view: MTKView) -> CGFloat {
        #if os(macOS)
        view.window?.backingScaleFactor ?? 2
        #else
        view.contentScaleFactor
        #endif
    }
}
