import SwiftUI
import PortolanCore

// The original screen layout (docs/re/frame.md): the 640×400 frame pictures GRAPH.DAT 2/4 (sea)
// and 3/5 (port) with the map window at (96, 8, 384×384), the status panels printed in the
// original fonts, the ship's wheel or the port compass, and the four menu tabs on the right.

/// The original fonts (frame.md §5): HANKAKU ASCII 8×16, the DATA1[14] digits 8×16 and ALL_FONT
/// Hangul 16×14, drawn colour 0 on colour 7 opaque cells.
final class PixelFont {
    private let ascii: CGImage, digits: CGImage, hangul: CGImage
    private let leadRows: [Int]
    private var cache: [Int: CGImage] = [:]
    static let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))

    init?(assets: URL) {
        let dir = assets.appendingPathComponent("frame")
        func load(_ n: String) -> CGImage? {
            NSImage(contentsOf: dir.appendingPathComponent(n))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let a = load("font_ascii.png"), let d = load("font_digits.png"), let h = load("font_hangul.png") else { return nil }
        ascii = a
        digits = d
        hangul = h
        leadRows = Array(0xA1...0xAC) + Array(0xB0...0xC8)
    }

    /// One glyph a cell: its picture (nil for a blank) and its cell width.
    func glyphs(_ s: String) -> [(image: CGImage?, width: Int, height: Int)] {
        guard let bytes = s.data(using: PixelFont.encoding, allowLossyConversion: true).map([UInt8].init) else { return [] }
        var out: [(CGImage?, Int, Int)] = []
        var i = 0
        while i < bytes.count {
            let (g, n) = glyph(bytes, i)
            out.append(g)
            i += n
        }
        return out
    }

    /// The glyph at byte i and the bytes it takes: ALL_FONT Hangul for the lead bytes A1..AC and
    /// B0..C8 (other double-byte codes print blank), the DATA1 digits, HANKAKU for the rest.
    func glyph(_ bytes: [UInt8], _ i: Int) -> (glyph: (image: CGImage?, width: Int, height: Int), bytes: Int) {
        let b = Int(bytes[i])
        if b >= 0xA1, i + 1 < bytes.count {
            guard let row = leadRows.firstIndex(of: b) else { return ((nil, 16, 14), 2) }
            let t = Int(bytes[i + 1]) - 0xA1
            let key = 0x10000 + row * 256 + t
            if cache[key] == nil { cache[key] = hangul.cropping(to: CGRect(x: 16 * t, y: 14 * row, width: 16, height: 14)) }
            return ((cache[key], 16, 14), 2)
        }
        if (0x30...0x39).contains(b) {
            let key = 0x20000 + b
            if cache[key] == nil { cache[key] = digits.cropping(to: CGRect(x: 8 * (b - 0x30), y: 0, width: 8, height: 16)) }
            return ((cache[key], 8, 16), 1)
        }
        let k = (0x20...0x7F).contains(b) ? b - 0x20 : 0
        if cache[b] == nil { cache[b] = ascii.cropping(to: CGRect(x: 8 * (k % 16), y: 16 * (k / 16), width: 8, height: 16)) }
        return ((b == 0x20 ? nil : cache[b], 8, 16), 1)
    }
}

/// Palette colours 0..7 of the frames (identical in every time-of-day palette).
enum FrameColor {
    static let black = Color.black
    static let blue = Color(red: 0, green: 68 / 255, blue: 221 / 255)
    static let red = Color(red: 221 / 255, green: 68 / 255, blue: 0)
    static let cream = Color(red: 1, green: 238 / 255, blue: 221 / 255)
}

extension GraphicsContext {
    /// `ESC C0 ESC B7` text at (x, y) of the 640×400 screen.
    mutating func pixelText(_ s: String, _ x: Double, _ y: Double, font: PixelFont?) {
        guard let font else { return }
        var cx = x
        for g in font.glyphs(s) {
            fill(Path(CGRect(x: cx, y: y, width: Double(g.width), height: 16)), with: .color(FrameColor.cream))
            if let img = g.image {
                var r = resolve(Image(decorative: img, scale: 1).renderingMode(.template))
                r.shading = .color(FrameColor.black)
                draw(r, in: CGRect(x: cx, y: y + (g.height == 14 ? 1 : 0), width: Double(g.width), height: Double(g.height)))
            }
            cx += Double(g.width)
        }
    }

    /// The gauge 0x913F: a 50×4 bar at x 26..75, y+2..y+5, red as far as `v / 2`, blue after.
    mutating func gauge(_ v: Int, y: Double) {
        let w = Double(max(0, min(100, v)) / 2)
        fill(Path(CGRect(x: 26, y: y + 2, width: w, height: 4)), with: .color(FrameColor.red))
        fill(Path(CGRect(x: 26 + w, y: y + 2, width: 50 - w, height: 4)), with: .color(FrameColor.blue))
    }
}

extension Game {
    /// The original fonts, read once.
    var pixelFont: PixelFont? {
        if let f = Game.fonts[assets] { return f }
        let f = PixelFont(assets: assets)
        Game.fonts[assets] = f
        return f
    }
    private static var fonts: [URL: PixelFont?] = [:]

    /// The 640×400 screen's scale and origin in this window, and the map window on it.
    /// The title bar's height over the content (the window draws under it); the 640×400 screen
    /// sits below it.
    nonisolated(unsafe) static var titleInset: CGFloat = 0
    var classicScale: CGFloat { min(viewSize.width / 640, (viewSize.height - Game.titleInset) / 400) }
    var classicOrigin: CGPoint {
        CGPoint(x: (viewSize.width - 640 * classicScale) / 2, y: Game.titleInset + (viewSize.height - Game.titleInset - 400 * classicScale) / 2)
    }
    var classicMapRect: CGRect {
        let s = classicScale, o = classicOrigin
        return CGRect(x: o.x + 96 * s, y: o.y + 8 * s, width: 384 * s, height: 384 * s)
    }
    /// The layout option `[0xC30] & 0x80`: TYPE 1 (English labels) when set.
    var frameType: Int { status.memory[0xC30] & 0x80 != 0 ? 1 : 2 }
}

/// The 640×400 screen placed in the window, black around it and over the world except in the
/// map window.
struct ClassicScreen<Content: View>: View {
    @ObservedObject var game: Game
    let picture: String
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { g in
            let top = Game.titleInset
            let s = min(g.size.width / 640, (g.size.height - top) / 400)
            let o = CGPoint(x: (g.size.width - 640 * s) / 2, y: top + (g.size.height - top - 400 * s) / 2)
            let hole = CGRect(x: o.x + 96 * s, y: o.y + 8 * s, width: 384 * s, height: 384 * s)
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: g.size))
                    p.addRect(hole)
                }
                .fill(Color.black, style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                ZStack(alignment: .topLeading) {
                    if let img = game.image(picture) {
                        Image(nsImage: img).pixelated().frame(width: 640, height: 400)
                            .mask(Path { p in
                                p.addRect(CGRect(x: 0, y: 0, width: 640, height: 400))
                                p.addRect(CGRect(x: 96, y: 8, width: 384, height: 384))
                            }.fill(style: FillStyle(eoFill: true)))
                            .allowsHitTesting(false)
                    }
                    content
                }
                .frame(width: 640, height: 400, alignment: .topLeading)
                .scaleEffect(s, anchor: .topLeading)
                .frame(width: 640 * s, height: 400 * s, alignment: .topLeading)
                .offset(x: o.x, y: o.y)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

/// The four menu tabs (DS:0xAE14 rects 8–11): a click pulls the tab out; the open one shows the
/// TRANSIT.DAT highlight at (616, 72 + 80t).
struct ClassicTabs: View {
    @ObservedObject var game: Game
    var body: some View {
        ForEach(0..<4, id: \.self) { t in
            Group {
                if game.tabMenu == t, let img = game.image("sprites/ui/tab_type\(game.frameType)_\(t).png") {
                    Image(nsImage: img).pixelated().frame(width: 24, height: 80)
                } else {
                    Color.white.opacity(0.001).frame(width: 24, height: 80)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { game.tabMenu = game.tabMenu == t ? nil : t }
            .offset(x: 616, y: CGFloat(72 + 80 * t))
            .help(Game.tabTitles[t])
        }
    }
}

/// The sea screen (frame.md §2): the State bars, Cargos, the date, wind, current and heading
/// dials, speed and days, and the ship's wheel.
struct ClassicSeaFrame: View {
    @ObservedObject var game: Game
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let dials = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    private var font: PixelFont? { game.pixelFont }

    var body: some View {
        let v = game.status
        ClassicScreen(game: game, picture: "frame/frame_sea_type\(game.frameType).png") {
            Canvas { ctx, _ in panel(&ctx, v) }
                .frame(width: 640, height: 400)
                .allowsHitTesting(false)
            dial(v.weather.windStrength == 0 ? nil : v.weather.windDir, y: 64)
            dial(v.weather.currentStrength == 0 ? nil : v.weather.currentDir, y: 112)
            dial(v.sail > 0 && !v.anchored ? v.heading8 : nil, y: 160)
            wheel(v)
            ClassicTabs(game: game)
        }
    }

    private func panel(_ ctx: inout GraphicsContext, _ v: Voyage) {
        // 0x6D03: the date, the dial forces, speed; 0x7F00: the bars, cargo and days.
        ctx.pixelText("\(v.year)", 536, 16, font: font)
        ctx.pixelText(Self.months[v.month], 576, 16, font: font)
        ctx.pixelText(String(format: "%2d", v.dayOfMonth + 1), 608, 16, font: font)
        ctx.pixelText("\(v.weather.windStrength)", 536, 88, font: font)
        ctx.pixelText("\(v.weather.currentStrength)", 536, 136, font: font)
        ctx.pixelText(String(format: "%2d", (v.speedUnits + 1) / 2), 552, 208, font: font)
        ctx.pixelText(String(format: "%3d", min(999, v.daysAtSea)), 552, 240, font: font)
        guard !v.ships.isEmpty else { return }
        let sum = v.fleetSummary(in: game.world)
        let crew = v.ships.reduce(0) { $0 + $1.crew }, berths = v.ships.reduce(0) { $0 + $1.crewCapacity }
        let morale = v.ships.reduce(0) { $0 + $1.crew * $1.morale } / max(1, crew)
        let bars = [sum.rudder, sum.sail, sum.hull, v.loadPercent(sum.slowest, in: game.world),
                    100 * v.sightRange / 24, 100 * crew / max(1, berths), morale]
        for (k, b) in bars.enumerated() { ctx.gauge(b, y: Double(72 + 24 * k)) }
        let stores = [v.ships.reduce(0) { $0 + $1.water } / 10, v.ships.reduce(0) { $0 + $1.food } / 10,
                      v.ships.reduce(0) { $0 + $1.lumber }, v.ships.reduce(0) { $0 + $1.shot }]
        for (k, n) in stores.enumerated() { ctx.pixelText(String(format: "%5d", min(99999, n)), 48, Double(264 + 32 * k), font: font) }
    }

    /// A 40×40 dial at (568, y): the needle the way it blows, or calm.
    private func dial(_ dir: Int?, y: CGFloat) -> some View {
        let name = dir.map { Self.dials[$0 & 7] } ?? "calm"
        return Group {
            if let img = game.image("sprites/ui/wind_dial_\(name).png") {
                Image(nsImage: img).pixelated().frame(width: 40, height: 40)
            }
        }
        .offset(x: 568, y: y)
        .allowsHitTesting(false)
    }

    /// The wheel (DATA1[7]): the heading's piece lit; a click heads that way, the centre stops.
    private func wheel(_ v: Voyage) -> some View {
        let at: [(Int?, CGFloat, CGFloat)] = [(7, 496, 272), (0, 536, 272), (1, 576, 272), (6, 496, 312), (nil, 536, 312),
                                              (2, 576, 312), (5, 496, 352), (4, 536, 352), (3, 576, 352)]
        let moving = v.sail > 0 && !v.anchored
        return ForEach(at.indices, id: \.self) { k in
            let (dir, x, y) = at[k]
            let lit = dir.map { moving && $0 == v.heading8 } ?? false
            let name = dir.map { Self.dials[$0] } ?? "centre"
            Group {
                if let img = game.image("sprites/ui/helm_\(lit ? "lit" : "off")_\(name).png") {
                    Image(nsImage: img).pixelated().frame(width: 32, height: 32)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let d = dir { game.act { $0.steer(toward: d) } } else { game.act { $0.sail = 0 } }
            }
            .offset(x: x, y: y)
        }
    }
}

/// The port screen (frame.md §3): the date and clock, fame and money, the region and port, the
/// market block, the town window and the compass; a building's counter opens over it.
struct ClassicPortFrame: View {
    @ObservedObject var game: Game
    let harbor: Harbor
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private var font: PixelFont? { game.pixelFont }

    var body: some View {
        let v = game.status
        ZStack {
            ClassicScreen(game: game, picture: "frame/frame_port_type\(game.frameType).png") {
                if let building = game.buildingScene, let image = game.buildingPicture(building) {
                    Image(nsImage: image).pixelated().aspectRatio(contentMode: .fit)
                        .frame(width: 384, height: 384)
                        .background(.black)
                        .offset(x: 96, y: 8)
                } else {
                    TownWalkView(game: game, harbor: harbor, side: 384, windowOnly: true)
                        .offset(x: 96, y: 8)
                }
                Canvas { ctx, _ in panel(&ctx, v) }
                    .frame(width: 640, height: 400)
                    .allowsHitTesting(false)
                compass
                ClassicTabs(game: game)
            }
            if let p = game.panel {
                // A building (0x8D4B): its picture at (104, 16) and the keeper's window (240, 8,
                // 240×128) with the name, in the original look; the counter sits below them.
                Color.black.opacity(0.45).ignoresSafeArea()
                ClassicStage {
                    if let img = game.image(String(format: "images/graph_%02d.png", p.rawValue + 6)) {
                        Image(nsImage: img).pixelated().frame(width: 136, height: 112).offset(x: 104, y: 16)
                    }
                    Canvas { ctx, _ in
                        guard let pieces = game.framePieces else { return }
                        ctx.classicWindow(col: 30, y: 8, cols: 30, h: 128, shadow: true, pieces: pieces)
                        var cur = PixelCursor(col: 32, y: 24, right: 57)
                        ctx.pixelCells(font?.layout(p.title + "\n" + game.portName(harbor.id) + "항", &cur) ?? [])
                    }
                    .frame(width: 640, height: 400)
                    .allowsHitTesting(false)
                }
                GeometryReader { g in
                    let top = game.classicOrigin.y + 150 * game.classicScale
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("카운터").gameTitle()
                            Spacer()
                            Button { game.leaveBuilding() } label: { Label("나가기", systemImage: "door.left.hand.open") }
                                .keyboardShortcut(.cancelAction)
                        }
                        ScrollView { BuildingContent(game: game, panel: p).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    .padding(16)
                    .frame(maxWidth: min(860, g.size.width - 32), maxHeight: max(160, g.size.height - top - 16))
                    .gamePanel(radius: 14)
                    .position(x: g.size.width / 2, y: top + max(160, g.size.height - top - 16) / 2)
                    .environment(\.colorScheme, .dark)
                }
            }
        }
    }

    private func panel(_ ctx: inout GraphicsContext, _ v: Voyage) {
        ctx.pixelText(String(format: "15%2d", v.year - 1500), 48, 16, font: font)          // "15 1" for 1501..1509
        ctx.pixelText(String(format: "%@.%2d", Self.months[v.month], v.dayOfMonth + 1), 24, 40, font: font)
        let h = (v.tick / 3 + 11) % 12 + 1, m = 20 * (v.tick % 3)
        ctx.pixelText(String(format: "%2d:%02d %@.M", h, m, v.tick < 36 ? "A" : "P"), 8, 144, font: font)
        ctx.pixelText(String(format: "%5d", min(99999, v.fame.max() ?? 0)), 48, 248, font: font)
        ctx.pixelText(String(format: "%5d", v.gold % 10000), 40, 320, font: font)
        ctx.pixelText(String(format: "%5d", min(99999, v.gold / 10000)), 40, 360, font: font)
        let p = harbor.id
        if p < 100 {
            let zone = game.world.navigation.markets[p].zone
            ctx.pixelText(game.message(385 + zone) + "지방 ", 488, 8, font: font)
        } else {
            ctx.pixelText("보급항", 488, 8, font: font)
        }
        ctx.fill(Path(CGRect(x: 488, y: 24, width: 144, height: 16)), with: .color(FrameColor.cream))
        ctx.pixelText(game.portName(p) + "항", 488, 24, font: font)
        guard p < 100, v.markets.indices.contains(p) else { return }
        let mk = v.markets[p]
        let values = [mk.economy, v.investment(.economy, port: p), mk.industry, v.investment(.industry, port: p)]
        for (k, n) in values.enumerated() { ctx.pixelText(String(format: "%5d", min(99999, n)), 560, Double(96 + 32 * k), font: font) }
        ctx.pixelText(String(format: "%4d", mk.prices.reduce(0, +) / 10 + 50), 560, 224, font: font)
    }

    /// The compass (DATA1[6]): the facing arrow lit; hold an arrow to walk.
    private var compass: some View {
        let at: [(CGFloat, CGFloat)] = [(528, 304), (552, 336), (528, 368), (504, 336)]
        let names = ["N", "E", "S", "W"]
        return ForEach(0..<4, id: \.self) { d in
            let lit = (game.townFace & 3) == d
            Group {
                if let img = game.image("sprites/ui/compass_\(lit ? "lit" : "off")_\(names[d]).png") {
                    Image(nsImage: img).pixelated().frame(width: 40, height: 24)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in game.townAim = d }
                .onEnded { _ in game.townAim = nil })
            .offset(x: at[d].0, y: at[d].1)
        }
    }
}
