#if os(macOS)
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Keep a covered text field from consuming modal keys, then restore a still-valid parent.
final class ModalFocusSnapshot {
    private weak var window: NSWindow?
    private weak var responder: NSResponder?

    func enter(in target: NSWindow?) {
        guard let window = target ?? NSApp.keyWindow else { return }
        self.window = window
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSView {
            responder = field
        } else {
            responder = window.firstResponder
        }
        if ProcessInfo.processInfo.environment["PORTOLAN_FOCUS_TRACE"] != nil {
            print("focus-enter: first=\(String(describing: window.firstResponder)), saved=\(String(describing: responder)), delegate=\(String(describing: (window.firstResponder as? NSTextView)?.delegate))")
        }
        window.makeFirstResponder(nil)
    }

    func leave() {
        if ProcessInfo.processInfo.environment["PORTOLAN_FOCUS_TRACE"] != nil {
            print("focus-leave: window=\(window != nil), saved=\(String(describing: responder)), current=\(String(describing: window?.firstResponder))")
        }
        guard let window, let responder else { return }
        // Wait for SwiftUI to re-enable the parent. A replacement modal or a user click
        // must retain its focus, and removed/new-game fields must never be resurrected.
        DispatchQueue.main.async { [weak window, weak responder] in
            if ProcessInfo.processInfo.environment["PORTOLAN_FOCUS_TRACE"] != nil {
                let view = responder as? NSView
                print("focus-restore: key=\(NSApp.keyWindow === window), attached=\(view?.window === window), hidden=\(String(describing: view?.isHiddenOrHasHiddenAncestor)), accepts=\(String(describing: view?.acceptsFirstResponder)), enabled=\(String(describing: (view as? NSControl)?.isEnabled)), current=\(String(describing: window?.firstResponder))")
            }
            // Restoring this window's first responder does not activate it. Preserve
            // its editing target even if macOS has temporarily focused another app.
            guard let window,
                  (window.firstResponder as? NSTextView)?.isEditable != true,
                  let view = responder as? NSView, view.window === window,
                  !view.isHiddenOrHasHiddenAncestor, view.acceptsFirstResponder else { return }
            if let control = view as? NSControl, !control.isEnabled { return }
            window.makeFirstResponder(view)
        }
    }
}

struct GameWindowRegistration: NSViewRepresentable {
    let game: Game
    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.game = game
        return view
    }
    func updateNSView(_ view: RegistrationView, context: Context) {
        view.game = game
        if let window = view.window { game.registerInputWindow(window) }
    }
    final class RegistrationView: NSView {
        weak var game: Game?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { game?.registerInputWindow(window) }
        }
    }
}

#else
import SwiftUI

final class ModalFocusSnapshot {
    func enter(in target: UIWindow?) {}
    func leave() {}
}

struct GameWindowRegistration: View {
    let game: Game
    var body: some View { Color.clear.frame(width: 0, height: 0) }
}
#endif
