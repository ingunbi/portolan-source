#if os(macOS)
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// macOS's SwiftUI menu Picker ignores the game's font. Set the native control
/// and every menu item explicitly, while retaining keyboard and VoiceOver use.
struct GamePicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var accessibilityIdentifier: String?

    init(_ title: String = "", selection: Binding<Value>, options: [(Value, String)], accessibilityIdentifier: String? = nil) {
        self.title = title
        _selection = selection
        self.options = options
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = GamePopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .large
        // The standard rounded bezel draws at a fixed small control height,
        // even when AppKit lays out our 18-point title in a 36-point view.
        button.bezelStyle = .roundRect
        button.autoenablesItems = false
        button.focusRingType = .exterior
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let font = NSFont.systemFont(ofSize: 18, weight: .medium)
        button.font = font
        button.menu?.font = font
        button.isEnabled = context.environment.isEnabled && !options.isEmpty
        button.setAccessibilityLabel(title)
        if let accessibilityIdentifier { button.setAccessibilityIdentifier(accessibilityIdentifier) }
        if context.coordinator.options.map({ $0.0 }) != options.map({ $0.0 })
            || context.coordinator.options.map({ $0.1 }) != options.map({ $0.1 }) {
            button.removeAllItems()
            for (_, label) in options {
                // Add separately so duplicate visible labels retain distinct values.
                let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                item.attributedTitle = NSAttributedString(string: label, attributes: [.font: font])
                button.menu?.addItem(item)
            }
        }
        context.coordinator.options = options
        context.coordinator.selection = $selection
        button.selectItem(at: options.firstIndex(where: { $0.0 == selection }) ?? -1)
        button.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? max(100, size.width), height: max(36, size.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject {
        var selection: Binding<Value>
        var options: [(Value, String)] = []

        init(selection: Binding<Value>) { self.selection = selection }

        @objc func choose(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard options.indices.contains(index) else { return }
            selection.wrappedValue = options[index].0
        }
    }
}

struct GameMenuAction {
    let title: String
    let isEnabled: Bool
    let perform: () -> Void

    init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        perform = action
    }
}

/// Action menus use the same readable control and native 18-point popup items.
struct GameActionMenu: NSViewRepresentable {
    let title: String
    let actions: [GameMenuAction]
    let accessibilityIdentifier: String

    init(_ title: String, actions: [GameMenuAction], accessibilityIdentifier: String) {
        self.title = title
        self.actions = actions
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = GamePopUpButton(frame: .zero, pullsDown: true)
        button.controlSize = .large
        button.bezelStyle = .roundRect
        button.autoenablesItems = false
        button.focusRingType = .exterior
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let font = NSFont.systemFont(ofSize: 18, weight: .medium)
        button.font = font
        button.menu?.font = font
        (button as? GamePopUpButton)?.displayTitle = title
        button.isEnabled = context.environment.isEnabled && actions.contains(where: { $0.isEnabled })
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        if button.numberOfItems != actions.count + 1 || context.coordinator.actions.map({ $0.title }) != actions.map({ $0.title }) {
            button.removeAllItems()
            // A pull-down button's first item is its title and is not selectable.
            button.addItem(withTitle: title)
            for action in actions {
                let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
                item.attributedTitle = NSAttributedString(string: action.title, attributes: [.font: font])
                button.menu?.addItem(item)
            }
        }
        for (index, action) in actions.enumerated() {
            button.item(at: index + 1)?.isEnabled = action.isEnabled
        }
        context.coordinator.actions = actions
        button.selectItem(at: 0)
        button.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? max(90, nsView.intrinsicContentSize.width), height: 36)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var actions: [GameMenuAction] = []

        @objc func choose(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem - 1
            guard actions.indices.contains(index), actions[index].isEnabled else { return }
            actions[index].perform()
        }
    }
}

/// NSPopUpButtonCell fixes its bezel and title baseline to the small system
/// control. Draw the closed button at the game's size; AppKit still owns the
/// popup menu, keyboard navigation, action delivery, and accessibility.
private final class GamePopUpButton: NSPopUpButton {
    var displayTitle: String?

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width, height: 36)
    }

    override func draw(_ dirtyRect: NSRect) {
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        let lit = isHighlighted && isEnabled
        NSColor(calibratedRed: lit ? 0.13 : 0.07, green: lit ? 0.20 : 0.12,
                blue: lit ? 0.25 : 0.16, alpha: 1).setFill()
        plate.fill()
        NSColor.white.withAlphaComponent(isEnabled ? 0.22 : 0.1).setStroke()
        plate.lineWidth = 1
        plate.stroke()

        let color = NSColor.white.withAlphaComponent(isEnabled ? 0.94 : 0.38)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let title = (displayTitle ?? selectedItem?.title ?? "") as NSString
        let textHeight = title.size(withAttributes: attributes).height
        title.draw(in: NSRect(x: 12, y: (bounds.height - textHeight) / 2,
                             width: max(0, bounds.width - 42), height: textHeight),
                   withAttributes: attributes)

        let x = bounds.maxX - 17
        let y = bounds.midY
        let arrows = NSBezierPath()
        arrows.move(to: NSPoint(x: x - 3, y: y + 2))
        arrows.line(to: NSPoint(x: x, y: y + 5))
        arrows.line(to: NSPoint(x: x + 3, y: y + 2))
        arrows.move(to: NSPoint(x: x - 3, y: y - 2))
        arrows.line(to: NSPoint(x: x, y: y - 5))
        arrows.line(to: NSPoint(x: x + 3, y: y - 2))
        arrows.lineWidth = 1.6
        arrows.lineCapStyle = .round
        arrows.lineJoinStyle = .round
        color.setStroke()
        arrows.stroke()

        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
            focus.lineWidth = 2
            focus.stroke()
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }
}

#else
import SwiftUI

struct GameMenuAction {
    let title: String
    let isEnabled: Bool
    let perform: () -> Void

    init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        perform = action
    }
}

struct GameActionMenu: View {
    let title: String
    let actions: [GameMenuAction]
    let accessibilityIdentifier: String

    init(_ title: String, actions: [GameMenuAction], accessibilityIdentifier: String) {
        self.title = title
        self.actions = actions
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        Menu(title) {
            ForEach(actions.indices, id: \.self) { i in
                Button(actions[i].title) { actions[i].perform() }.disabled(!actions[i].isEnabled)
            }
        }
        .buttonStyle(GameButtonStyle())
    }
}

/// On iPadOS the system menu picker is used.
struct GamePicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var accessibilityIdentifier: String?

    init(_ title: String = "", selection: Binding<Value>, options: [(Value, String)], accessibilityIdentifier: String? = nil) {
        self.title = title
        _selection = selection
        self.options = options
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options.indices, id: \.self) { Text(options[$0].1).tag(options[$0].0) }
        }
        .pickerStyle(.menu)
    }
}
#endif
