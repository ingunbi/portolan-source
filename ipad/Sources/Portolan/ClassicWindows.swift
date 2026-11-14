import SwiftUI
import PortolanCore

// The original windows (docs/re/frame.md §4–5) for the original screen layout: framed windows built
// from the DATA1[14] pieces, the message window's checker shadow, the face windows of the scripts,
// the blinking ▼ key-wait marker and the popup menu, all with text in the original fonts.

/// The DATA1[14] window pieces (frame.md §4.1): the corners, the three edge styles, the ▼ marker and
/// the dither stamp that greys disabled menu items.
final class FramePieces {
    let corners: [CGImage]          // TL, TR, BL, BR
    let edges: [[CGImage]]          // style 0..2: top, left, right, bottom
    let more: CGImage, dither: CGImage

    init?(assets: URL) {
        let dir = assets.appendingPathComponent("sprites/ui")
        func load(_ n: String) -> CGImage? {
            NSImage(contentsOf: dir.appendingPathComponent(n + ".png"))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let c = ["TL", "TR", "BL", "BR"].compactMap { load("frame_corner_" + $0) }
        let e = (0..<3).map { s in ["top", "left", "right", "bottom"].compactMap { load("frame_\(s)_" + $0) } }
        guard c.count == 4, e.allSatisfy({ $0.count == 4 }), let m = load("stamp_more"), let d = load("stamp_dither") else { return nil }
        corners = c
        edges = e
        more = m
        dither = d
    }
}

/// The text cursor of 0x4970 (frame.md §5): column and y, the margins and the line pitch.
struct PixelCursor {
    var col: Int, y: Int
    var left: Int, right: Int
    var pitch = 24
    /// The lowest line; the original keeps y on the screen, a scrolling window lays out unbounded.
    var bottom = 400

    init(col: Int, y: Int, right: Int, pitch: Int = 24, bottom: Int = 400) {
        self.col = col
        self.y = y
        left = col
        self.right = right
        self.pitch = pitch
        self.bottom = bottom
    }

    /// LF (0x490E): back to the left margin a line lower, a no-op at the left margin.
    mutating func newline() {
        guard col != left else { return }
        col = left
        if y + pitch <= bottom { y += pitch }
    }
}

/// One printed glyph cell.
struct PixelCell {
    let image: CGImage?
    var x: Int, y: Int
    let width: Int, height: Int
}

extension PixelFont {
    /// Prints `s` from the cursor as 0x4970 does: CR to the left margin, LF a new line, and after a
    /// glyph past the right margin a new line (frame.md §5).
    func layout(_ s: String, _ cur: inout PixelCursor) -> [PixelCell] {
        guard let bytes = s.data(using: PixelFont.encoding, allowLossyConversion: true).map([UInt8].init) else { return [] }
        var out: [PixelCell] = []
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case 0x0A: cur.newline(); i += 1; continue
            case 0x0D: cur.col = cur.left; i += 1; continue
            default: break
            }
            let (g, n) = glyph(bytes, i)
            i += n
            let cols = g.width / 8
            if cur.col > (cols == 2 ? 77 : 78) { cur.newline() }
            out.append(PixelCell(image: g.image, x: 8 * cur.col, y: cur.y, width: g.width, height: g.height))
            cur.col += cols
            if cur.col > cur.right { cur.newline() }
        }
        return out
    }
}

extension GraphicsContext {
    /// Printed cells: opaque `bg` cells (none when nil) with the glyphs in `fg`.
    mutating func pixelCells(_ cells: [PixelCell], fg: Color = FrameColor.black, bg: Color? = FrameColor.cream) {
        for c in cells {
            if let bg { fill(Path(CGRect(x: c.x, y: c.y, width: c.width, height: 16)), with: .color(bg)) }
            guard let img = c.image else { continue }
            var r = resolve(Image(decorative: img, scale: 1).renderingMode(.template).interpolation(.none))
            r.shading = .color(fg)
            draw(r, in: CGRect(x: c.x, y: c.y + (c.height == 14 ? 1 : 0), width: c.width, height: c.height))
        }
    }

    /// 0x71FA, and with `shadow` 0x76EB: the window at column `col`, y px, `cols` columns wide and
    /// `h` px high — corners, the style's edges, the colour-7 interior, and the 4-px 50 % checker
    /// drop shadow (pixels where x + y is odd go black) right and below.
    mutating func classicWindow(col: Int, y: Int, cols: Int, h: Int, style: Int = 0, shadow: Bool = false, pieces p: FramePieces) {
        let x = 8 * col, w = 8 * cols
        let e = p.edges[max(0, min(2, style))]
        func put(_ img: CGImage, _ px: Int, _ py: Int) {
            draw(Image(decorative: img, scale: 1).interpolation(.none), in: CGRect(x: px, y: py, width: 8, height: 8))
        }
        fill(Path(CGRect(x: x + 8, y: y + 8, width: w - 16, height: h - 16)), with: .color(FrameColor.cream))
        for c in 1..<max(1, cols - 1) {
            put(e[0], x + 8 * c, y)
            put(e[3], x + 8 * c, y + h - 8)
        }
        var sides = self
        sides.clip(to: Path(CGRect(x: x, y: y + 8, width: w, height: max(0, h - 16))))
        for yy in stride(from: y + 8, to: y + h - 8, by: 8) {
            sides.draw(Image(decorative: e[1], scale: 1).interpolation(.none), in: CGRect(x: x, y: yy, width: 8, height: 8))
            sides.draw(Image(decorative: e[2], scale: 1).interpolation(.none), in: CGRect(x: x + w - 8, y: yy, width: 8, height: 8))
        }
        put(p.corners[0], x, y)
        put(p.corners[1], x + w - 8, y)
        put(p.corners[2], x, y + h - 8)
        put(p.corners[3], x + w - 8, y + h - 8)
        guard shadow else { return }
        var dots = Path()
        for py in (y + 4)..<(y + h + 4) {
            for px in (x + w)..<(x + w + 4) where (px + py) & 1 == 1 { dots.addRect(CGRect(x: px, y: py, width: 1, height: 1)) }
        }
        for py in (y + h)..<(y + h + 4) {
            for px in (x + 4)..<(x + w) where (px + py) & 1 == 1 { dots.addRect(CGRect(x: px, y: py, width: 1, height: 1)) }
        }
        fill(dots, with: .color(.black))
    }

    /// 0x140EA: the ▼ in colour 2 at the margins' middle column, on the cursor's line when it is at
    /// the left margin, else a line lower.
    mutating func moreMark(_ cur: PixelCursor, pieces p: FramePieces) {
        let col = min(78, cur.left + (cur.right - cur.left) / 2)
        let y = min(0x180, cur.col == cur.left ? cur.y : cur.y + 24)
        var r = resolve(Image(decorative: p.more, scale: 1).renderingMode(.template).interpolation(.none))
        r.shading = .color(FrameColor.red)
        draw(r, in: CGRect(x: 8 * col, y: y, width: 16, height: 16))
    }
}

extension Game {
    /// The window pieces, read once.
    var framePieces: FramePieces? {
        if let p = Game.pieces[assets] { return p }
        let p = FramePieces(assets: assets)
        Game.pieces[assets] = p
        return p
    }
    private static var pieces: [URL: FramePieces?] = [:]
}

/// A 640×400 screen scaled into the window like the frames, for windows drawn over them.
struct ClassicStage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { g in
            let top = Game.titleInset
            let s = min(g.size.width / 640, (g.size.height - top) / 400)
            ZStack(alignment: .topLeading) { content }
                .frame(width: 640, height: 400, alignment: .topLeading)
                .scaleEffect(s, anchor: .topLeading)
                .frame(width: 640 * s, height: 400 * s, alignment: .topLeading)
                .offset(x: (g.size.width - 640 * s) / 2, y: top + (g.size.height - top - 400 * s) / 2)
        }
        .ignoresSafeArea()
    }
}

/// Holds the ▼ on (the snapshot harness).
enum BlinkClock {
    nonisolated(unsafe) static var steady = false
}

/// A ▼ that blinks 4 ticks on, 4 off (about 0.22 s each).
struct Blink<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.22)) { tl in
            content(BlinkClock.steady || Int(tl.date.timeIntervalSinceReferenceDate / 0.22) % 2 == 0)
        }
    }
}

/// The popup menu 0x13CA3 (frame.md §4.4) at column `col`, y px: the message window
/// (mw + 4 columns, 24·(n + 1) px, with shadow), items centred 24 px apart, the chosen one inverted
/// (XOR colour 7 over its hot rect) and disabled ones dithered. The mouse, the arrows, the number
/// keys and Return choose; Esc cancels when it may.
struct ClassicPopup: View {
    @ObservedObject var game: Game
    let col: Int, y: Int
    let items: [String]
    var disabled: Set<Int> = []
    var cancel: (() -> Void)? = nil
    /// Whether the keys go to this menu (not while a menu opened from it is up).
    var active = true
    let pick: (Int) -> Void
    @State private var sel: Int?

    /// An item's width in columns (bytes of its DOS text).
    static func width(_ s: String) -> Int {
        s.data(using: PixelFont.encoding, allowLossyConversion: true)?.count ?? s.count
    }

    /// The widest item, in columns.
    static func mw(_ items: [String]) -> Int { items.map(width).max() ?? 0 }

    /// The window's size in columns and px.
    static func size(_ items: [String]) -> (cols: Int, h: Int) { (mw(items) + 4, 24 * (items.count + 1)) }

    var body: some View {
        let mw = Self.mw(items)
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                guard let p = game.framePieces else { return }
                ctx.classicWindow(col: col, y: y, cols: mw + 4, h: 24 * (items.count + 1), shadow: true, pieces: p)
                for (i, s) in items.enumerated() {
                    let yy = y + 16 + 24 * i
                    var cur = PixelCursor(col: col + 2 + (mw - Self.width(s)) / 2, y: yy, right: 79)
                    let cells = game.pixelFont?.layout(s, &cur) ?? []
                    if sel == i {
                        ctx.fill(Path(CGRect(x: 8 * (col + 1), y: yy, width: 8 * (mw + 2), height: 16)), with: .color(.black))
                        ctx.pixelCells(cells, fg: FrameColor.cream, bg: .black)
                    } else {
                        ctx.pixelCells(cells)
                    }
                    if disabled.contains(i) {
                        for c in 0..<mw {
                            var r = ctx.resolve(Image(decorative: p.dither, scale: 1).renderingMode(.template).interpolation(.none))
                            r.shading = .color(FrameColor.cream)
                            ctx.draw(r, in: CGRect(x: 8 * (col + 2 + c), y: yy, width: 8, height: 16))
                        }
                    }
                }
            }
            .frame(width: 640, height: 400)
            .allowsHitTesting(false)
            ForEach(items.indices, id: \.self) { i in
                Color.white.opacity(0.001)
                    .frame(width: CGFloat(8 * (mw + 2)), height: 24)
                    .contentShape(Rectangle())
                    .onHover { if $0 { sel = i } }
                    .onTapGesture { choose(i) }
                    .offset(x: CGFloat(8 * (col + 1)), y: CGFloat(y + 12 + 24 * i))
            }
            if active { keys }
        }
    }

    private func choose(_ i: Int) {
        guard items.indices.contains(i), !disabled.contains(i) else { return }
        pick(i)
    }

    private func move(_ d: Int) {
        guard !items.isEmpty else { return }
        var i = sel ?? (d > 0 ? -1 : items.count)
        for _ in items.indices {
            i = (i + d + items.count) % items.count
            if !disabled.contains(i) { break }
        }
        sel = i
    }

    private var keys: some View {
        Group {
            Button("") { move(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { move(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { choose(sel ?? 0) }.keyboardShortcut(.defaultAction)
            ForEach(0..<min(9, items.count), id: \.self) { i in
                Button("") { choose(i) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
            }
            if let cancel { Button("") { cancel() }.keyboardShortcut(.cancelAction) }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

/// The scripts' speech windows in the original layout: window b of `C0 b` at DS:0xBBBA + 24b
/// (scenario.md), framed by 0x71FA, with the portrait, the `§name§` first line and the text in the
/// original fonts, the blinking ▼ while it waits for a key, and the menus as original popups.
struct ClassicDialogue: View {
    @ObservedObject var game: Game

    /// DS:0xBBBA records 0..3: the window (col, y, cols, h), the portrait (col, y) and the text
    /// area (col, y, cols, h). 0 narration, 1 the upper face window, 2 the lower one, 3 the picture.
    struct Geometry {
        let win: (col: Int, y: Int, cols: Int, h: Int)
        let face: (col: Int, y: Int)
        let text: (col: Int, y: Int, cols: Int, h: Int)
    }
    static let geometry: [Geometry] = [
        Geometry(win: (30, 8, 30, 128), face: (13, 16), text: (32, 16, 26, 112)),
        Geometry(win: (13, 16, 39, 144), face: (15, 32), text: (24, 32, 26, 112)),
        Geometry(win: (20, 176, 39, 144), face: (22, 192), text: (31, 192, 26, 112)),
        Geometry(win: (13, 16, 26, 160), face: (0, 0), text: (14, 24, 24, 144)),
    ]

    var body: some View {
        if let s = game.session, let run = s.run, let prompt = s.prompt {
            ZStack {
                Color.white.opacity(0.001).ignoresSafeArea()
                    .onTapGesture { if Self.waits(prompt) { game.scriptAnswer(0) } }
                ClassicStage {
                    Blink { on in
                        Canvas { ctx, _ in draw(&ctx, run, mark: on && Self.waits(prompt)) }
                    }
                    .frame(width: 640, height: 400)
                    .allowsHitTesting(false)
                    controls(run, prompt)
                }
                if case .duel(let who) = prompt {
                    VStack {
                        Spacer()
                        DuelPrompt(game: game, opponent: who).padding(.bottom, 40)
                    }
                    .environment(\.colorScheme, .dark)
                }
            }
        }
    }

    /// The prompts that wait for a key (the ▼).
    static func waits(_ p: ScriptPrompt) -> Bool {
        switch p {
        case .next, .ending: return true
        default: return false
        }
    }

    /// Window w's printed text, scrolled so the last line shows, and the cursor after it.
    private func text(_ w: ScriptWindow) -> (cells: [PixelCell], cursor: PixelCursor) {
        let g = Self.geometry[max(0, min(3, w.id))]
        var cur = PixelCursor(col: g.text.col, y: g.text.y, right: g.text.col + g.text.cols - 1, bottom: .max)
        let body = (w.speaker.map { "§\($0)§\n" } ?? "") + w.text
        var cells = game.pixelFont?.layout(body, &cur) ?? []
        let last = g.text.y + g.text.h - 16
        let low = max(cur.col == cur.left ? cur.y - cur.pitch : cur.y, cells.map(\.y).max() ?? 0)
        if low > last {
            let shift = (low - last + cur.pitch - 1) / cur.pitch * cur.pitch
            cells = cells.compactMap { c in
                var c = c
                c.y -= shift
                return c.y >= g.text.y ? c : nil
            }
            cur.y -= shift
        }
        return (cells, cur)
    }

    private func draw(_ ctx: inout GraphicsContext, _ run: ScriptRun, mark: Bool) {
        guard let p = game.framePieces else { return }
        var shown = run.windows.filter { $0.id != 3 }
        if run.picture != nil || run.windows.contains(where: { $0.id == 3 }) {
            shown.insert(run.windows.first { $0.id == 3 } ?? ScriptWindow(id: 3), at: 0)
        }
        for w in shown {
            let g = Self.geometry[max(0, min(3, w.id))]
            ctx.classicWindow(col: g.win.col, y: g.win.y, cols: g.win.cols, h: g.win.h, pieces: p)
            if w.id == 3 {
                if let pic = run.picture, let img = game.image("images/event\(game.status.memory[DS.heroID] + 1)_\(pic).png") {
                    ctx.draw(Image(nsImage: img).interpolation(.none),
                             in: CGRect(x: 8 * g.text.col, y: g.text.y, width: 8 * g.text.cols, height: g.text.h))
                }
                continue
            }
            if let f = w.face, let img = game.portrait(face: f) {
                ctx.draw(Image(nsImage: img).interpolation(.none), in: CGRect(x: 8 * g.face.col, y: g.face.y, width: 64, height: 80))
            }
            let t = text(w)
            ctx.pixelCells(t.cells)
            if mark, w.id == run.current { ctx.moreMark(t.cursor, pieces: p) }
        }
    }

    @ViewBuilder
    private func controls(_ run: ScriptRun, _ prompt: ScriptPrompt) -> some View {
        switch prompt {
        case .menu(let choices):
            // C9: the popup at column 60, y 80 (kept on the screen).
            let size = ClassicPopup.size(choices)
            ClassicPopup(game: game, col: min(60, 79 - size.cols), y: 80, items: choices) { game.scriptAnswer($0) }
                .id(choices)
        case .yesNo:
            // E9 (0x13FDB): with the keyboard the box opens at the text cursor, 5 columns left of
            // the margins' middle; the original draws a picture there, here a two-item popup.
            let items = ["예", "아니오"]
            let size = ClassicPopup.size(items)
            let cur = run.windows.first { $0.id == run.current }.map { text($0).cursor }
            let col = cur.map { ($0.left + $0.right - 10) / 2 } ?? 30
            let y = cur.map { $0.col == $0.left ? $0.y : $0.y + 24 } ?? 160
            ClassicPopup(game: game, col: max(0, min(col, 79 - size.cols)), y: max(0, min(y, 396 - size.h)), items: items,
                         cancel: { game.scriptAnswer(0) }) { game.scriptAnswer($0 == 0 ? 1 : 0) }
        case .next, .ending:
            Button("") { game.scriptAnswer(0) }
                .keyboardShortcut(.defaultAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        case .duel:
            EmptyView()
        }
    }
}

/// A message window 0x76EB (frame.md §4.2) with shadow: the sea-event and townsfolk-talk box at
/// (128, 160, 288 × 128); `next` shows the ▼ and goes on with a click or Return.
struct ClassicMessageBox: View {
    @ObservedObject var game: Game
    let text: String
    var col = 16, y = 160, cols = 36, h = 128
    var next: (() -> Void)? = nil

    var body: some View {
        ZStack {
            if let next {
                Color.white.opacity(0.001).ignoresSafeArea().onTapGesture { next() }
            }
            ClassicStage {
                Blink { on in
                    Canvas { ctx, _ in
                        guard let p = game.framePieces else { return }
                        ctx.classicWindow(col: col, y: y, cols: cols, h: h, shadow: true, pieces: p)
                        var cur = PixelCursor(col: col + 2, y: y + 16, right: col + cols - 3)
                        ctx.pixelCells(game.pixelFont?.layout(text, &cur) ?? [])
                        if on, next != nil { ctx.moreMark(cur, pieces: p) }
                    }
                }
                .frame(width: 640, height: 400)
                .allowsHitTesting(false)
                if let next {
                    Button("") { next() }.keyboardShortcut(.defaultAction).opacity(0).frame(width: 0, height: 0)
                }
            }
        }
    }
}

/// A command tab's menu in the original layout (0x204A2): the popup right-aligned at column
/// 0x4A − mw next to the tabs, at y 48 (정보), 136 (편성) and 224 (지휘, 항해); an entry with a list
/// (교섭, 전투, 항구이동) opens a second popup beside it.
struct ClassicTabPopup: View {
    @ObservedObject var game: Game
    let tab: Int
    @State private var sub: Int?
    static let ys = [48, 136, 224, 224]

    var body: some View {
        let entries = game.tabEntries(tab)
        let items = entries.map(\.title)
        let col = 0x4A - ClassicPopup.mw(items)
        let y = Self.ys[max(0, min(3, tab))]
        ZStack {
            Color.white.opacity(0.001).ignoresSafeArea().onTapGesture { game.tabMenu = nil }
            ClassicStage {
                ClassicPopup(game: game, col: col, y: y, items: items,
                             disabled: Set(entries.indices.filter { !entries[$0].enabled }),
                             cancel: { game.tabMenu = nil }, active: sub == nil) { i in
                    if entries[i].children.isEmpty {
                        game.tabMenu = nil
                        entries[i].action?()
                    } else {
                        sub = i
                    }
                }
                if let s = sub, entries.indices.contains(s) {
                    let kids = Array(entries[s].children.prefix(15))
                    let size = ClassicPopup.size(kids.map(\.title))
                    ClassicPopup(game: game, col: max(0, col - size.cols + 2), y: max(8, min(y + 24 * s, 392 - size.h)),
                                 items: kids.map(\.title), cancel: { sub = nil }) { k in
                        game.tabMenu = nil
                        kids[k].action?()
                    }
                    .id(s)
                }
            }
        }
        .id(tab)
    }
}
