import SwiftUI
import PortolanCore

/// A 640×400 stage for the opening (OPEN.EXE) and the endings (END.EXE): pictures at screen
/// positions, typed text, dialogue windows and fades, run by an async script.
/// docs/re/endings.md. One tick is a count of the FMDRV timer, 60.3 Hz.
@MainActor
final class Stage: ObservableObject {
    struct Layer: Identifiable {
        let id: String
        var image: String
        var x: Double
        var y: Double
        var opacity = 1.0
        /// Shown only inside this rectangle (the pans).
        var clip: CGRect?
        /// Drawn over the dialogue windows (faces).
        var top = false
        /// Shown only through this picture's opaque pixels, the image slid by `inner` (the title's
        /// water inside the kanji, 0x2AB4).
        var mask: String?
        var inner = 0.0
    }

    struct TextBox: Identifiable {
        let id: String
        var text: String
        var shown: Int
        var x: Double, y: Double, width: Double
        var color = Color.white
    }

    @Published var layers: [Layer] = []
    @Published var boxes: [CGRect] = []
    @Published var texts: [TextBox] = []
    @Published var black = 1.0
    @Published var white = 0.0
    @Published var band: CGRect?
    private var keyHit = false
    let assets: URL
    private var images: [String: NSImage] = [:]

    init(assets: URL) { self.assets = assets }

    func image(_ path: String) -> NSImage? {
        if let i = images[path] { return i }
        let i = NSImage(contentsOf: assets.appendingPathComponent(path))
        images[path] = i
        return i
    }

    func key() { keyHit = true }

    /// A timer wait; `breakable` waits end early on a key.
    func wait(_ ticks: Double, breakable: Bool = false) async {
        if breakable { keyHit = false }
        let end = Date().addingTimeInterval(ticks / 60.3)
        while Date() < end && !Task.isCancelled && !(breakable && keyHit) {
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    /// Waits for Enter, a click or Esc (0xE1C).
    func waitKey() async {
        keyHit = false
        while !keyHit && !Task.isCancelled { try? await Task.sleep(nanoseconds: 15_000_000) }
    }

    func put(_ id: String, _ image: String, _ x: Double, _ y: Double, opacity: Double = 1, clip: CGRect? = nil, top: Bool = false) {
        let l = Layer(id: id, image: image, x: x, y: y, opacity: opacity, clip: clip, top: top)
        if let k = layers.firstIndex(where: { $0.id == id }) { layers[k] = l } else { layers.append(l) }
    }

    func remove(_ id: String) { layers.removeAll { $0.id == id } }
    func clear() {
        layers = []
        texts = []
        boxes = []
        band = nil
    }

    func set(_ id: String, _ change: (inout Layer) -> Void) {
        if let k = layers.firstIndex(where: { $0.id == id }) { change(&layers[k]) }
    }

    /// A palette fade, one channel step per `ticks`: sixteen steps at most.
    func fade(to value: Double, ticksPerStep: Double = 4, white w: Bool = false) async {
        let t = 16 * ticksPerStep / 60.3
        withAnimation(.linear(duration: t)) { if w { white = value } else { black = value } }
        await wait(16 * ticksPerStep)
    }

    /// The plane-by-plane dissolve (0x4FB3, END 0x2DA4): 16 steps.
    func dissolve(_ id: String, _ image: String, _ x: Double, _ y: Double, ticksPerStep: Double = 3) async {
        put(id, image, x, y, opacity: 0)
        withAnimation(.linear(duration: 16 * ticksPerStep / 60.3)) { set(id) { $0.opacity = 1 } }
        await wait(16 * ticksPerStep)
    }

    /// Text typed a byte at a time (Hangul are two bytes).
    func type(_ id: String, _ text: String, x: Double, y: Double, width: Double, ticksPerByte: Double = 1,
              color: Color = .white) async {
        texts.removeAll { $0.id == id }
        texts.append(TextBox(id: id, text: text, shown: 0, x: x, y: y, width: width, color: color))
        for n in 1...max(1, text.count) {
            if let k = texts.firstIndex(where: { $0.id == id }) { texts[k].shown = n }
            let c = text[text.index(text.startIndex, offsetBy: n - 1)]
            await wait(ticksPerByte * (c.isASCII ? 1 : 2), breakable: true)
            if keyHit {
                if let k = texts.firstIndex(where: { $0.id == id }) { texts[k].shown = text.count }
                keyHit = false
                return
            }
        }
    }

    /// Eye blinks or a lamp flame: frames shown in `order` (index into frames, −1 = none), each
    /// for its ticks, until the task is cancelled.
    func animate(_ id: String, frames: [String], at p: (Double, Double), order: [Int], ticks: [Double]) -> Task<Void, Never> {
        Task { @MainActor in
            var k = 0
            while !Task.isCancelled {
                let f = order[k % order.count]
                if f < 0 { remove(id) } else { put(id, frames[f], p.0, p.1) }
                await wait(ticks[k % ticks.count])
                k += 1
            }
            remove(id)
        }
    }
}

/// Draws a stage scaled to the window.
struct StageView: View {
    @ObservedObject var stage: Stage

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width / 640, g.size.height / 400)
            ZStack(alignment: .topLeading) {
                Color.black
                if let b = stage.band { Color.white.frame(width: b.width, height: b.height).offset(x: b.minX, y: b.minY) }
                ForEach(stage.layers.filter { !$0.top }) { l in layer(l) }
                ForEach(Array(stage.boxes.enumerated()), id: \.offset) { _, r in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 0.05, green: 0.08, blue: 0.2).opacity(0.92))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.8), lineWidth: 2))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
                ForEach(stage.layers.filter { $0.top }) { l in layer(l) }
                ForEach(stage.texts) { t in
                    Text(String(t.text.prefix(t.shown)))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(t.color)
                        .lineSpacing(4)
                        .frame(width: t.width, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: t.x, y: t.y)
                }
                Color.white.opacity(stage.white).allowsHitTesting(false)
                Color.black.opacity(stage.black).allowsHitTesting(false)
            }
            .frame(width: 640, height: 400, alignment: .topLeading)
            .clipped()
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: 640 * s, height: 400 * s, alignment: .topLeading)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func layer(_ l: Stage.Layer) -> some View {
        if let m = l.mask, let img = stage.image(l.image), let mk = stage.image(m) {
            #if os(macOS)
            let w = Double(mk.representations.first?.pixelsWide ?? Int(mk.size.width))
            let h = Double(mk.representations.first?.pixelsHigh ?? Int(mk.size.height))
            #else
            let w = Double(mk.size.width * mk.scale), h = Double(mk.size.height * mk.scale)
            #endif
            HStack(spacing: 0) {
                Image(nsImage: img).pixelated().frame(width: w, height: h)
                Image(nsImage: img).pixelated().frame(width: w, height: h)
            }
            .offset(x: -l.inner.truncatingRemainder(dividingBy: w))
            .frame(width: w, height: h, alignment: .leading)
            .clipped()
            .mask(Image(nsImage: mk).pixelated().frame(width: w, height: h))
            .offset(x: l.x, y: l.y)
            .opacity(l.opacity)
        } else if let img = stage.image(l.image) {
            let w = Double(img.representations.first?.pixelsWide ?? Int(img.size.width))
            let h = Double(img.representations.first?.pixelsHigh ?? Int(img.size.height))
            if let c = l.clip {
                Image(nsImage: img).pixelated().frame(width: w, height: h)
                    .offset(x: l.x - c.minX, y: l.y - c.minY)
                    .frame(width: c.width, height: c.height, alignment: .topLeading)
                    .clipped()
                    .offset(x: c.minX, y: c.minY)
                    .opacity(l.opacity)
            } else {
                Image(nsImage: img).pixelated().frame(width: w, height: h)
                    .offset(x: l.x, y: l.y)
                    .opacity(l.opacity)
            }
        }
    }
}

// MARK: opening

/// OPEN.EXE (12 scenes, song 21). A key or click ends it, as Enter/Space/Esc do (0x4CEE).
struct OpeningView: View {
    @ObservedObject var game: Game
    @StateObject private var stage: Stage

    init(game: Game) {
        self.game = game
        _stage = StateObject(wrappedValue: Stage(assets: game.assets))
    }

    var body: some View {
        StageView(stage: stage)
            .contentShape(Rectangle())
            .onTapGesture { finish() }
            .background(KeyCatcher { finish() })
            .task {
                game.music.play(0)
                await play()
                finish()
            }
    }

    private func finish() {
        guard game.opening else { return }
        game.opening = false
    }

    private func op(_ e: Int, _ p: Int) -> String { String(format: "opening/op%02d_%02d.png", e, p) }

    /// Character scenes 3–10: picture (88,48), then portrait, caption and blinking eyes.
    private struct Character {
        let picture: (Int, Int)
        let portrait: (Int, Int, Double, Double)?
        let caption: (Int, Double, Double)
        let eyes: [(Int, [Int], Double, Double)]
    }

    private static let characters: [Character] = [
        Character(picture: (3, 6), portrait: (3, 7, 152, 64), caption: (1, 288, 64), eyes: [(3, [8, 9, 10], 184, 104)]),
        Character(picture: (4, 3), portrait: (4, 4, 192, 48), caption: (2, 48, 64), eyes: [(4, [5, 6, 7], 432, 120)]),
        Character(picture: (5, 3), portrait: (5, 4, 184, 64), caption: (3, 288, 64), eyes: [(5, [5, 6, 7], 208, 112)]),
        Character(picture: (6, 3), portrait: (6, 4, 360, 80), caption: (4, 48, 64), eyes: [(6, [5, 6, 7], 376, 128)]),
        Character(picture: (7, 3), portrait: (7, 4, 160, 48), caption: (5, 288, 64), eyes: [(7, [5, 6, 7], 200, 88)]),
        Character(picture: (8, 5), portrait: nil, caption: (6, 48, 176),
                  eyes: [(8, [6, 7, 8], 344, 120), (8, [9, 10, 11], 368, 192), (8, [12, 13, 14], 440, 112)]),
        Character(picture: (9, 10), portrait: nil, caption: (7, 288, 128), eyes: []),
        Character(picture: (10, 0), portrait: (10, 4, 304, 72), caption: (8, 48, 64), eyes: [(10, [1, 2, 3], 368, 120)]),
    ]

    /// The emblem of character scene `n` (0x28BB / 0x2A77): a turning pistol, quill, coin or
    /// dagger (four 1-bit plane frames per picture) flying in to its place, stars or coins.
    /// The flight paths (OPEN DS:0x518..) are not traced; the emblem glides in from the right.
    private func emblem(_ n: Int) async {
        let s = stage
        switch n {
        case 0, 7:                                                           // Otto, João: stars
            for k in 0..<12 {
                s.put("emblem\(k % 5)", op(3, k % 5), 120 + 70 * Double(k % 5), 80 + 40 * Double((k * 3) % 5))
                await s.wait(8)
            }
        case 1, 2, 3, 4:                                                     // pistol, quill, coin, dagger
            let e = [4, 5, 6, 7][n - 1]
            let end: (Double, Double) = [(168, 56), (56, 232), (464, 176), (144, 232)][n - 1]
            let frames = (1...2).flatMap { p in (0..<4).map { "opening/op0\(e)_0\(p)_f\($0).png" } }
            for k in 0..<32 {
                let t = Double(k) / 31
                s.put("emblem", frames[k % 8], 640 - (640 - end.0) * t, end.1)
                await s.wait(3)
                if Task.isCancelled { return }
            }
            s.put("emblem", op(e, 0), end.0, end.1)
            await s.wait(40)
        case 5:                                                              // the heroines: three coins
            for k in 0..<20 {
                for (j, p) in [(336.0, 96.0), (360.0, 176.0), (424.0, 88.0)].enumerated() {
                    s.put("emblem\(j)", op(8, (k + j) % 5), p.0, p.1)
                }
                await s.wait(5)
            }
        default:
            break
        }
    }

    private func play() async {
        let s = stage
        // 0. credits (0x5152)
        s.put("logo", op(0, 0), 216, 96)
        await s.fade(to: 0)
        await s.wait(60)
        s.put("presents", op(0, 1), 216, 224)
        await s.wait(120)
        await s.fade(to: 1)
        s.clear()
        s.put("eiji", op(0, 3), 120, 174)
        await s.fade(to: 0)
        await s.wait(120)
        await s.fade(to: 1)
        s.clear()
        s.put("from", op(0, 4), 248, 132)
        s.put("series", op(0, 2), 128, 188)
        await s.fade(to: 0)
        await s.wait(120)
        await s.fade(to: 1)
        s.clear()
        await s.wait(60)
        if Task.isCancelled { return }

        // 1. title (0x5390): water moving inside the kanji mask (the palette cycle 0x49DC), white
        // flashes of the kanji, 'II', sparkles along the title, then the title at sunset.
        var water = Stage.Layer(id: "water", image: op(0, 6), x: 40, y: 120)
        water.mask = op(0, 5)
        s.layers.append(water)
        await s.fade(to: 0)
        for k in 0..<90 {
            s.set("water") { $0.inner = Double(k) * 4 }
            await s.wait(2)
            if Task.isCancelled { return }
        }
        await s.fade(to: 1, ticksPerStep: 2, white: true)
        s.clear()
        for k in 0..<4 {
            s.put("kanji", op(0, 7 + k % 2), 40, 120)
            s.white = k % 2 == 0 ? 0.6 : 0
            await s.wait(6)
        }
        s.white = 0
        s.put("ii", op(0, 9), 528, 112)
        await s.wait(60)
        for k in 0..<10 {
            s.put("spark", op(0, 11 + k % 5), 40 + 52 * Double(k), 120 + Double((k * 37) % 96))
            await s.wait(6)
        }
        s.clear()
        s.put("title", op(0, 10), 0, 120)
        await s.fade(to: 0, ticksPerStep: 2, white: true)
        await s.wait(240)
        await s.fade(to: 1)
        s.clear()
        if Task.isCancelled { return }

        // 2. the prologue caption on a white band, then the fleet panning right (0x588D).
        await s.wait(120)
        s.band = CGRect(x: 0, y: 100, width: 640, height: 200)
        s.put("cap", op(13, 0), 32, 180)
        await s.fade(to: 0, ticksPerStep: 4)
        await s.wait(180)
        await s.fade(to: 1)
        s.clear()
        let ships = CGRect(x: 0, y: 100, width: 640, height: 200)
        s.put("pan", "opening/pan_ships_0.png", 0, 100, clip: ships)
        let waves = Task { @MainActor in
            var f = 0
            while !Task.isCancelled {
                s.set("pan") { $0.image = "opening/pan_ships_\(f % 2).png" }
                f += 1
                await s.wait(30)
            }
        }
        await s.fade(to: 0, ticksPerStep: 8)
        withAnimation(.linear(duration: 40 * 16 / 60.3)) { s.set("pan") { $0.x = -320 } }
        await s.wait(40 * 16 - 64)
        await s.fade(to: 1)
        waves.cancel()
        s.clear()
        if Task.isCancelled { return }

        // 3–10. the characters.
        for (n, c) in Self.characters.enumerated() {
            await s.fade(to: 0, ticksPerStep: 1)
            await emblem(n)
            await s.dissolve("pic", op(c.picture.0, c.picture.1), 88, 48)
            s.layers.removeAll { $0.id.hasPrefix("emblem") }
            let flames = n == 6 ? [s.animate("flameA", frames: (0..<5).map { op(9, $0) }, at: (216, 72), order: [0, 1, 2, 3, 4], ticks: [6]),
                                   s.animate("flameB", frames: (5..<10).map { op(9, $0) }, at: (136, 200), order: [0, 1, 2, 3, 4], ticks: [6])] : []
            await s.wait(120)
            if let p = c.portrait {
                s.remove("pic")
                await s.dissolve("portrait", op(p.0, p.1), p.2, p.3)
            }
            s.put("caption", op(13, c.caption.0), c.caption.1, c.caption.2)
            let blinks = c.eyes.map { e in
                s.animate("eyes\(e.2)", frames: e.1.map { op(e.0, $0) }, at: (e.2, e.3), order: [-1, 0, 1, 0], ticks: [100, 6, 6, 6])
            }
            await s.wait(c.eyes.isEmpty ? 240 : 360)
            blinks.forEach { $0.cancel() }
            flames.forEach { $0.cancel() }
            await s.fade(to: 1)
            s.clear()
            if Task.isCancelled { return }
        }

        // 11. finale (0x7B2C): the deck pans right, then the closing caption on white.
        let deck = CGRect(x: 0, y: 100, width: 640, height: 200)
        s.put("pan", "opening/pan_finale_0.png", 0, 100, clip: deck)
        await s.fade(to: 0, ticksPerStep: 8)
        withAnimation(.linear(duration: 32 * 16 / 60.3)) { s.set("pan") { $0.x = -256 } }
        await s.wait(32 * 16)
        await s.fade(to: 1, ticksPerStep: 4, white: true)
        s.clear()
        s.band = CGRect(x: 0, y: 100, width: 640, height: 200)
        s.black = 0
        s.put("cap", op(13, 9), 128, 180)
        await s.fade(to: 0, ticksPerStep: 4, white: true)
        await s.wait(240)
        await s.fade(to: 1)
        s.clear()
    }
}

// MARK: endings

/// END.EXE: the homecoming, the diary (story endings) and the staff roll. Code 0..5 is a hero's
/// story ending, 0x0F the duke ending of hero `hero`.
struct EndingView: View {
    @ObservedObject var game: Game
    let code: Int
    @StateObject private var stage: Stage

    init(game: Game, code: Int) {
        self.game = game
        self.code = code
        _stage = StateObject(wrappedValue: Stage(assets: game.assets))
    }

    var body: some View {
        StageView(stage: stage)
            .contentShape(Rectangle())
            .onTapGesture { stage.key() }
            .background(KeyCatcher { stage.key() })
            .task {
                await play()
                game.finishEnding()
            }
    }

    private var data: [String: Any] {
        guard let d = try? Data(contentsOf: game.assets.appendingPathComponent("endings/endings.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }

    private func names() -> (given: String, family: String) {
        let m = game.status.memory, h = game.status.heroID
        return (m.string(DS.person(h), max: 13), m.string(DS.person(h) + 0x0D, max: 13))
    }

    private func fill(_ t: String) -> String {
        let n = names()
        return Korean.particles(t.replacingOccurrences(of: "{given}", with: n.given).replacingOccurrences(of: "{family}", with: n.family))
    }

    private func play() async {
        let s = stage
        let j = data
        let hero = code == 0x0F ? game.status.heroID : code
        guard let all = j["endings"] as? [[String: Any]], all.indices.contains(hero) else { return }
        let e = all[hero]
        let duke = code == 0x0F
        let windows = j["windows"] as? [String: [String: [Double]]] ?? [:]

        // 1. Homecoming (0x14E8), song 19.
        game.cinemaSong = 1
        game.music.play(1)
        s.put("frame", "endings/endgrp_56.png", 0, 0)
        await s.fade(to: 0, ticksPerStep: 1)
        let steps = (duke ? (j["dukeEnding"] as? [String: Any])?["homecoming"] : e["homecoming"]) as? [[String: Any]] ?? []
        var open: Set<String> = []
        for step in steps {
            if let say = step["say"] as? [String: Any], let w = say["window"] as? String, let win = windows[w] {
                let f = win["frame"] ?? [0, 0, 0, 0], face = win["face"] ?? [0, 0], text = win["text"] ?? [0, 0]
                if !open.contains(w) {
                    s.boxes.append(CGRect(x: f[0], y: f[1], width: f[2], height: f[3]))
                    open.insert(w)
                }
                var id = 0
                if let n = say["face"] as? Int { id = n } else if let who = say["face"] as? String {
                    id = who == "ruler" ? 6 + min(5, game.status.captain.nation) : hero
                }
                s.put("face-" + w, String(format: "endings/face_%02d.png", id), face[0], face[1], top: true)
                await s.type("text-" + w, fill(say["text"] as? String ?? ""), x: text[0], y: text[1],
                             width: f[0] + f[2] - text[0] - 12)
                await s.waitKey()
            } else if step["closeWindows"] != nil {
                s.boxes = []
                s.texts = []
                s.remove("face-top")
                s.remove("face-bottom")
                open = []
            } else if let p = step["picture"] as? [String: Any] {
                let file = p["file"] as? String ?? ((e["diary"] as? [[String: Any]])?.last?["picture"] as? String ?? "")
                s.put("event", "endings/" + file, p["x"] as? Double ?? 224, p["y"] as? Double ?? 96)
            } else if let n = step["narration"] as? [String: Any] {
                let x = n["x"] as? Double ?? 192, right = n["right"] as? Double ?? 432
                await s.type("narration", fill(n["text"] as? String ?? ""), x: x, y: n["y"] as? Double ?? 248, width: right - x + 16)
                await s.waitKey()
            }
            if Task.isCancelled { return }
        }
        await s.fade(to: 1, ticksPerStep: 1)
        s.clear()

        // 2. Diary (story endings only, 0x566 / 0x598), song 22.
        game.cinemaSong = 2
        game.music.play(2)
        if !duke, let pages = e["diary"] as? [[String: Any]] {
            s.put("desk", "endings/endgrp_07.png", 0, 30)
            let lamp = s.animate("lamp", frames: ["endings/endgrp_08.png", "endings/endgrp_09.png"], at: (480, 30), order: [0, 1], ticks: [24, 24])
            await s.fade(to: 0, ticksPerStep: 2)
            await s.wait(300)
            for p in pages {
                let pic = p["picture"] as? String ?? "", sepia = p["sepia"] as? String ?? ""
                await s.dissolve("page", "endings/" + pic, 8, 100, ticksPerStep: 1)
                await s.wait(120)
                await s.dissolve("sepia", "endings/" + sepia, 8, 100, ticksPerStep: 6)
                s.remove("page")
                await s.wait(60)
                let lines = (p["lines"] as? [String] ?? []).map(fill)
                await s.type("diary", lines.joined(separator: "\n"), x: 208, y: 100, width: 272, ticksPerByte: 3, color: .white)
                await s.wait(Double(p["holdTicks"] as? Int ?? 120), breakable: true)
                withAnimation(.linear(duration: 1)) { s.texts = [] }
                await s.wait(60)
                if Task.isCancelled { return }
            }
            await s.fade(to: 1, ticksPerStep: 5)
            lamp.cancel()
            s.clear()
        }

        // 3. Staff roll (0x6AA..0xB09).
        let portrait = e["portrait"] as? [String: Any] ?? [:]
        let at = portrait["drawAt"] as? [Double] ?? [256, 30], to = portrait["slideTo"] as? [Double] ?? [0, 30]
        s.put("portrait", "endings/" + (portrait["file"] as? String ?? "endgrp_10.png"), at[0], at[1])
        await s.fade(to: 0, ticksPerStep: 2)
        await s.wait(20)
        withAnimation(.linear(duration: (at[0] - to[0]) / 8 / 60.3)) { s.set("portrait") { $0.x = to[0] } }
        await s.wait((at[0] - to[0]) / 8)
        var loops: [Task<Void, Never>] = []
        if let eyes = e["eyes"] as? [String: Any], let frames = eyes["frames"] as? [String], let p = eyes["at"] as? [Double] {
            loops.append(s.animate("eyes", frames: frames.map { "endings/" + $0 }, at: (p[0], p[1]),
                                   order: [-1, 0, 1, 0], ticks: [240, 6, 6, 6]))
        }
        if let sp = e["sprite"] as? [String: Any], let frames = sp["frames"] as? [String], let p = sp["at"] as? [Double] {
            loops.append(s.animate("sprite", frames: frames.map { "endings/" + $0 }, at: (p[0], p[1]),
                                   order: sp["order"] as? [Int] ?? [0, 1], ticks: (sp["frameTicks"] as? [Int] ?? [12]).map(Double.init)))
        }
        // The epilogue panels scroll up through (384,210,240x160), a line every 6 ticks.
        let window = CGRect(x: 384, y: 210, width: 240, height: 160)
        s.put("epilogue1", "endings/endgrp_54.png", 384, 370, clip: window)
        s.put("epilogue2", "endings/endgrp_55.png", 384, 370 + 640, clip: window)
        let scroll = 640.0 * 2 + 160
        withAnimation(.linear(duration: scroll * 6 / 60.3)) {
            s.set("epilogue1") { $0.y -= scroll }
            s.set("epilogue2") { $0.y -= scroll }
        }
        for k in 0..<6 {
            await s.dissolve("roll", String(format: "endings/endgrp_%02d.png", k), 392, 50, ticksPerStep: 6)
            await s.wait(480)
            if Task.isCancelled { return }
        }
        await s.wait(max(0, scroll * 6 - 6 * (96 + 480)))
        loops.forEach { $0.cancel() }
        if let f = portrait["final"] as? String, let p = portrait["finalAt"] as? [Double] {
            await s.dissolve("final", "endings/" + f, p[0], p[1], ticksPerStep: 5)
        } else if let eyes = e["eyes"] as? [String: Any], let frames = eyes["frames"] as? [String], let p = eyes["at"] as? [Double] {
            s.put("eyes", "endings/" + frames[0], p[0], p[1])
            await s.wait(6)
            s.put("eyes", "endings/" + frames[1], p[0], p[1])
        }
        await s.wait(60)
        await s.dissolve("roll", "endings/endgrp_06.png", 392, 50, ticksPerStep: 5)
        await s.wait(60)
        for id in ["portrait", "final", "eyes", "sprite", "epilogue1", "epilogue2"] { s.remove(id) }
        await s.dissolve("fin", "endings/endgrp_53.png", 424, 250, ticksPerStep: 5)
        await s.wait(60)
        game.cinemaSong = nil
        game.music.play(nil)
        await s.fade(to: 1, ticksPerStep: 11)
        s.clear()
        s.put("koei", "endings/endgrp_57.png", 216, 80)
        s.put("copy", "endings/endgrp_58.png", 184, 200)
        await s.fade(to: 0)
        await s.waitKey()
        await s.fade(to: 1)
    }
}

#if os(macOS)
/// Return, space and Esc for the stage (the views take no focus of their own).
struct KeyCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = KeyView()
        v.action = action
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { (v as? KeyView)?.action = action }

    final class KeyView: NSView {
        var action: () -> Void = {}
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with e: NSEvent) {
            if [36, 49, 53, 76].contains(e.keyCode) { action() } else { super.keyDown(with: e) }
        }
    }
}
#else
/// Touch needs no key catcher.
struct KeyCatcher: View {
    let action: () -> Void
    var body: some View { Color.clear.frame(width: 0, height: 0) }
}
#endif
