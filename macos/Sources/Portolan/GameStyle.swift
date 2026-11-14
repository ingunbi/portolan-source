import SwiftUI
import PortolanCore

/// Readable desktop sizes shared by every modern game screen. Keep secondary
/// information legible at the minimum 960×600 window without shrinking text to fit.
enum GameFont {
    static let body = Font.system(size: 18)
    static let callout = Font.system(size: 17)
    static let subheadline = Font.system(size: 17)
    static let footnote = Font.system(size: 16)
    static let caption = Font.system(size: 15)
    static let caption2 = Font.system(size: 15)
    static let headline = Font.system(size: 19, weight: .semibold)
    static let title3 = Font.system(size: 24)
    static let title2 = Font.system(size: 28)
    static let title = Font.system(size: 32)
    static let largeTitle = Font.system(size: 36)
}

// The remaster's game look for buttons and the four command menus: navy plates with a gold rim,
// gold when chosen, instead of the system's push buttons and pull-down menus.

/// Buttons: navy plates with a gold rim; `prominent` ones are gold. They light up under the
/// pointer, sink when pressed and fade when disabled.
struct GameButtonStyle: ButtonStyle {
    var prominent = false
    var fontSize: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        GameButtonBody(configuration: configuration, prominent: prominent, fontSize: fontSize)
    }
}

private struct GameButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let fontSize: CGFloat
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        let lit = hover && enabled
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : .white.opacity(lit ? 1 : 0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Theme.goldGradient)
                                    : AnyShapeStyle(LinearGradient(colors: [Theme.navyLight.opacity(lit ? 1 : 0.85), Theme.navy.opacity(0.95)],
                                                                   startPoint: .top, endPoint: .bottom)))
                    .brightness(prominent && lit ? 0.06 : 0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(prominent ? Color.white.opacity(0.45) : Color.white.opacity(lit ? 0.35 : 0.13), lineWidth: 1)
            }
            .shadow(color: lit ? Theme.gold.opacity(0.25) : .black.opacity(0.25), radius: lit ? 8 : 3, y: 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// The four commands (정보, 편성, 지휘, 항해) as plates with an icon and their key; a click opens
/// the command's menu (TabPopup), as F1–F4 and the keypad do.
struct CommandBar: View {
    @ObservedObject var game: Game
    static let symbols = ["book.closed.fill", "person.3.fill", "flag.fill", "sailboat.fill"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { t in
                CommandTile(title: Game.tabTitles[t], symbol: Self.symbols[t], key: "F\(t + 1)", open: game.tabMenu == t) {
                    game.tabMenu = game.tabMenu == t ? nil : t
                }
            }
        }
        .padding(6)
        .background(Theme.navy.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
    }
}

private struct CommandTile: View {
    let title: String
    let symbol: String
    let key: String
    let open: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                Text(title).font(.system(size: 17, weight: .bold))
            }
            .foregroundStyle(open ? Color.black.opacity(0.85) : hover ? Theme.gold : .white.opacity(0.88))
            .frame(width: 80, height: 64)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(open ? AnyShapeStyle(Theme.goldGradient)
                               : AnyShapeStyle(LinearGradient(colors: [Theme.navyLight.opacity(hover ? 1 : 0.7), Theme.navy],
                                                              startPoint: .top, endPoint: .bottom)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(open ? Color.white.opacity(0.5) : Color.white.opacity(hover ? 0.35 : 0.08), lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                Text(key).font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(open ? Color.black.opacity(0.55) : .white.opacity(0.35))
                    .padding(4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .scaleEffect(hover && !open ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.12), value: open)
    }
}

/// A command's menu (MENU 26–29) over the command bar: a gold-titled list; an entry with a list
/// (교섭, 전투, 항구이동) turns the panel to that list with a way back. The mouse, ↑↓, Return,
/// ← (back) and Esc work it. Rows are kept by position, so the menu stays put while the game runs.
struct TabPopup: View {
    @ObservedObject var game: Game
    let tab: Int
    @State private var sub: Int?
    @State private var sel: Int?

    var body: some View {
        let entries = game.tabEntries(tab)
        let rows = sub.flatMap { entries.indices.contains($0) ? entries[$0].children : nil } ?? entries
        ZStack(alignment: .bottomTrailing) {
            Color.black.opacity(0.3).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { game.tabMenu = nil }
            VStack(alignment: .leading, spacing: 0) {
                header(sub.map { entries[$0].title })
                Rectangle().fill(LinearGradient(colors: [Theme.gold.opacity(0.8), Theme.gold.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
                    .padding(.bottom, 6)
                if rows.isEmpty {
                    Text("고를 것이 없습니다.").font(GameFont.callout).foregroundStyle(.secondary).padding(12)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(rows.indices, id: \.self) { i in row(rows[i], i) }
                        }
                    }
                    .frame(maxHeight: sub == nil ? 420 : 340)
                    .fixedSize(horizontal: false, vertical: rows.count <= 9)
                }
            }
            .padding(10)
            .frame(width: 300)
            .background(LinearGradient(colors: [Theme.navyLight, Theme.navy], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.gold.opacity(0.45)))
            .shadow(color: .black.opacity(0.55), radius: 20, y: 8)
            .padding(.trailing, game.harbor != nil ? 38 : 16)
            .padding(.bottom, game.harbor != nil ? 120 : 98)
            .background(keys(rows))
            .transition(.opacity.combined(with: .offset(y: 8)))
        }
        .environment(\.colorScheme, .dark)
        .id(tab)
    }

    private func header(_ subTitle: String?) -> some View {
        HStack(spacing: 8) {
            if let subTitle {
                Button { back() } label: {
                    Label(subTitle, systemImage: "chevron.left").font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.gold)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: CommandBar.symbols[tab]).foregroundStyle(Theme.gold)
                Text(Game.tabTitles[tab]).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.gold)
            }
            Spacer()
            Text(subTitle == nil ? "esc" : "←").font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.2)))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func row(_ e: TabEntry, _ i: Int) -> some View {
        let lit = sel == i && e.enabled
        return Button { choose(e, i) } label: {
            HStack(spacing: 10) {
                Capsule().fill(Theme.goldGradient).frame(width: 3, height: 18).opacity(lit ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title).font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(lit ? .white : .white.opacity(0.85))
                        .opacity(e.enabled ? 1 : 0.38)
                        .lineLimit(1)
                    if !e.enabled, let note = e.note {
                        Text(note).font(.system(size: 15)).foregroundStyle(Theme.gold.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if !e.children.isEmpty, e.enabled {
                    Text("\(e.children.count)").font(GameFont.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.gold.opacity(0.8))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, e.note != nil && !e.enabled ? 6 : 0)
            .frame(minHeight: sub == nil ? 46 : 42)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(lit ? AnyShapeStyle(LinearGradient(colors: [Theme.gold.opacity(0.28), Theme.gold.opacity(0.06)],
                                                             startPoint: .leading, endPoint: .trailing))
                              : AnyShapeStyle(Color.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!e.enabled)
        .onHover { if $0 { sel = i } }
        .accessibilityIdentifier("portolan.command.entry.\(tab).\(i)")
    }

    private func choose(_ e: TabEntry, _ i: Int) {
        guard e.enabled else { return }
        if e.children.isEmpty {
            game.tabMenu = nil
            e.action?()
        } else {
            sub = i
            sel = nil
        }
    }

    private func back() {
        if sub != nil {
            sel = sub
            sub = nil
        } else {
            game.tabMenu = nil
        }
    }

    private func move(_ d: Int, _ rows: [TabEntry]) {
        guard rows.contains(where: \.enabled) else { return }
        var i = sel ?? (d > 0 ? -1 : rows.count)
        repeat { i = (i + d + rows.count) % rows.count } while !rows[i].enabled
        sel = i
    }

    private func keys(_ rows: [TabEntry]) -> some View {
        Group {
            Button("") { move(-1, rows) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { move(1, rows) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { if let s = sel, rows.indices.contains(s) { choose(rows[s], s) } }.keyboardShortcut(.defaultAction)
            Button("") { back() }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { back() }.keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

extension View {
    /// A section inside a window: a lighter navy plate with a faint gold rim.
    func gameSection(radius: CGFloat = 14) -> some View {
        background(LinearGradient(colors: [Theme.navyLight.opacity(0.6), Theme.navyLight.opacity(0.32)], startPoint: .top, endPoint: .bottom),
                   in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    /// A window over the game: navy with a gold rim and a shadow under it.
    func gamePanel(radius: CGFloat = 20) -> some View {
        background(LinearGradient(colors: [Theme.navyLight.opacity(0.97), Theme.navy.opacity(0.98)], startPoint: .top, endPoint: .bottom),
                   in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }

    /// A gold-lettered section title with a fading gold rule under it.
    func gameTitle() -> some View {
        self.font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.gold)
    }
}
