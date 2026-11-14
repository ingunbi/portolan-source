#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import MetalKit
import SwiftUI
import PortolanCore

/// Native-window integration runner. Dialogues use the actual SwiftUI button accessibility
/// action; the run fails if that button is absent or cannot advance the script.
enum PlaytestRunner {
    static func run(to directory: URL) -> Bool {
        setbuf(stdout, nil)
        let env = ProcessInfo.processInfo.environment
        let suite = env["PORTOLAN_PLAYTEST_SUITE"] ?? "dialogue"
        let runID = env["PORTOLAN_RELEASE_RUN_ID"] ?? "unbound"
        let previousSaveRoot = SaveGame.override
        SaveGame.override = directory.appendingPathComponent("saves", isDirectory: true)
        var passed = false
        func emit(_ prefix: String, _ fields: [String: String]) {
            if let bytes = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
               let line = String(data: bytes, encoding: .utf8) { print(prefix + " " + line) }
        }
        let identity = BuildIdentity.current
        emit("PORTOLAN_RELEASE_IDENTITY", ["buildID": identity.buildID, "sourceRevision": identity.sourceRevision,
            "contentRevision": identity.contentRevision, "runID": runID, "suite": suite,
            "saveRoot": SaveGame.directory.path,
            "width": env["PORTOLAN_PLAYTEST_WIDTH"] ?? "960", "height": env["PORTOLAN_PLAYTEST_HEIGHT"] ?? "600",
            "layoutCheck": env["PORTOLAN_LAYOUT_CHECK"] ?? "0", "home": NSHomeDirectory()])
        defer {
            emit("PORTOLAN_RELEASE_RESULT", ["status": passed ? "pass" : "fail", "suite": suite, "runID": runID])
            SaveGame.override = previousSaveRoot
        }
        func success() -> Bool { passed = true; return true }
        var captureFailure: (() -> Void)?
        do {
            guard let assets = Game.findAssets(), let device = MTLCreateSystemDefaultDevice() else {
                throw Playthrough.Failure(message: "Missing assets or Metal device")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let game = try Game(assets: assets)
            let previousLayout = game.classicLayout
            defer { game.classicLayout = previousLayout }
            game.classicLayout = false
            let size = CGSize(width: Double(env["PORTOLAN_PLAYTEST_WIDTH"] ?? "960") ?? 960,
                              height: Double(env["PORTOLAN_PLAYTEST_HEIGHT"] ?? "600") ?? 600)
            let metal = MTKView(frame: .zero, device: device)
            metal.colorPixelFormat = .bgra8Unorm
            let renderer = try WorldRenderer(view: metal, game: game)
            let host = NSHostingView(rootView: RootView(game: game, previewWorld: NSImage(size: size)))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Portolan · 실제 플레이 경로 검증"
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: size)
            NSApp.setActivationPolicy(.regular)
            // SwiftUI lazily builds its AX tree. Enable it for this in-process UI test
            // even when no external accessibility client is currently connected.
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            window.center()
            // SwiftUI creates its normal startup window first. This process is a test;
            // keep only the isolated driver window visible and eligible for keyboard focus.
            for other in NSApp.windows where other !== window { other.orderOut(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer { window.orderOut(nil) }
            var nativePresses = 0
            var keyboardAdvances = 0
            func settle() {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.04))
                host.layoutSubtreeIfNeeded()
            }
            func capture(_ name: String, _ current: Game) {
                if let cg = renderer.renderOffscreen(width: Int(size.width * 2), height: Int(size.height * 2), scale: 2) {
                    host.rootView = RootView(game: current, previewWorld: NSImage(cgImage: cg, size: size))
                }
                settle()
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
            }
            captureFailure = {
                print("failure-state: position \(game.status.x),\(game.status.y); day \(game.status.daysAtSea); heading \(game.status.heading); waypoint \(String(describing: game.status.waypoint)); route \(game.status.route)")
                game.diagnosticEvent("playtest-failure")
                let exported = game.exportDiagnostics(to: directory.appendingPathComponent("failure.portolandiag"))
                print("failure-diagnostics: \(exported ? "exported locally" : (game.diagnosticExportStatus ?? "unavailable"))")
                capture("FAILED", game)
            }
            func objectValue(_ object: NSObject, _ method: String) -> Any? {
                let selector = NSSelectorFromString(method)
                guard object.responds(to: selector) else { return nil }
                return object.perform(selector)?.takeUnretainedValue()
            }
            func textTree(_ element: NSObject, depth: Int = 0) -> String {
                guard depth < 40 else { return "" }
                let own = ["accessibilityLabel", "accessibilityValue"].compactMap { objectValue(element, $0) as? String }
                let children = (objectValue(element, "accessibilityChildren") as? [NSObject] ?? [])
                    .map { textTree($0, depth: depth + 1) }
                return (own + children).joined(separator: "\n")
            }
            func find(_ identifier: String, in item: Any, depth: Int = 0) -> NSObject? {
                guard depth < 40, let element = item as? NSObject else { return nil }
                if objectValue(element, "accessibilityIdentifier") as? String == identifier { return element }
                // A few established buttons (such as 기능 > 저장) predate stable IDs.
                // Foundation checks still press their real AX action, by exact visible label.
                if identifier.hasPrefix("label:"),
                   objectValue(element, "accessibilityRole") as? String == "AXButton",
                   objectValue(element, "accessibilityLabel") as? String == String(identifier.dropFirst(6)) {
                    return element
                }
                for child in objectValue(element, "accessibilityChildren") as? [Any] ?? [] {
                    if let found = find(identifier, in: child, depth: depth + 1) { return found }
                }
                return nil
            }
            func dump(_ item: Any, depth: Int = 0) {
                guard depth < 12, let element = item as? NSObject else { return }
                print("AX \(depth) \(type(of: element)) id=\(objectValue(element, "accessibilityIdentifier") ?? "-") label=\(objectValue(element, "accessibilityLabel") ?? "-")")
                for child in objectValue(element, "accessibilityChildren") as? [Any] ?? [] { dump(child, depth: depth + 1) }
            }
            func frame(of element: NSObject) -> CGRect {
                let selector = NSSelectorFromString("accessibilityFrame")
                guard element.responds(to: selector) else { return .zero }
                typealias FrameAction = @convention(c) (AnyObject, Selector) -> CGRect
                return unsafeBitCast(element.method(for: selector), to: FrameAction.self)(element, selector)
            }
            func scrollViews(in view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
            }
            func scrollParents(of element: NSObject) -> [NSObject] {
                var result: [NSObject] = [], current = objectValue(element, "accessibilityParent") as? NSObject
                for _ in 0..<40 {
                    guard let parent = current else { break }
                    if objectValue(parent, "accessibilityRole") as? String == "AXScrollArea" { result.append(parent) }
                    current = objectValue(parent, "accessibilityParent") as? NSObject
                }
                return result
            }
            func reveal(_ element: NSObject, identifier: String) throws {
                let selector = NSSelectorFromString("accessibilityPerformScrollToVisible")
                if element.responds(to: selector) {
                    typealias ScrollAction = @convention(c) (AnyObject, Selector) -> Bool
                    if unsafeBitCast(element.method(for: selector), to: ScrollAction.self)(element, selector) { settle() }
                }
                for parent in scrollParents(of: element) {
                    let clip = frame(of: parent), target = frame(of: element)
                    guard !clip.isEmpty, !target.isEmpty, !clip.insetBy(dx: -2, dy: -2).contains(target) else { continue }
                    // Scroll the native document, then verify its real clipped viewport.
                    if let scroll = scrollViews(in: host).first(where: { scroll in
                        let bounds = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                        return abs(bounds.midX - clip.midX) < 8 && abs(bounds.midY - clip.midY) < 8
                    }), let document = scroll.documentView {
                        let rect = document.convert(window.convertFromScreen(target), from: nil)
                        document.scrollToVisible(rect)
                        scroll.reflectScrolledClipView(scroll.contentView)
                        settle()
                    }
                    guard frame(of: parent).insetBy(dx: -2, dy: -2).contains(frame(of: element)) else {
                        throw Playthrough.Failure(message: "Control is clipped by its scroll viewport: \(identifier), control \(frame(of: element)), viewport \(frame(of: parent))")
                    }
                }
                let target = frame(of: element), viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
                if !target.isEmpty && !viewport.insetBy(dx: -2, dy: -2).contains(target) {
                    throw Playthrough.Failure(message: "Control is outside the visible game window: \(identifier), frame \(target), viewport \(viewport)")
                }
            }
            func press(_ identifier: String) throws {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                settle()
                // Never let an accessibility action reach controls covered by a modal.
                if game.question != nil && !identifier.hasPrefix("portolan.question.") {
                    throw Playthrough.Failure(message: "Confirmation covers requested control: \(identifier)")
                }
                if game.interaction.allows(.message) && identifier != "portolan.portMessage.dismiss" {
                    throw Playthrough.Failure(message: "Port dialogue covers requested control: \(identifier)")
                }
                if identifier.hasPrefix("portolan.question.") {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                }
                func lookup() -> NSObject? {
                    window.sheets.compactMap({ find(identifier, in: $0) }).first
                        ?? find(identifier, in: host) ?? find(identifier, in: window)
                        ?? NSApp.windows.compactMap({ find(identifier, in: $0) }).first
                }
                var found = lookup()
                if found == nil {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    for _ in 0..<12 where found == nil { settle(); found = lookup() }
                }
                guard let element = found else {
                    dump(host)
                    throw Playthrough.Failure(message: "Native UI button not found: \(identifier)")
                }
                if env["PORTOLAN_LAYOUT_CHECK"] == "1" { try reveal(element, identifier: identifier) }
                let selector = NSSelectorFromString("accessibilityPerformPress")
                guard element.responds(to: selector) else { throw Playthrough.Failure(message: "Button has no native press action") }
                typealias PressAction = @convention(c) (AnyObject, Selector) -> Bool
                let action = unsafeBitCast(element.method(for: selector), to: PressAction.self)
                if !action(element, selector) {
                    if let button = (element as? NSButton) ?? ((element as? NSCell)?.controlView as? NSButton), button.isEnabled {
                        button.performClick(nil)
                    } else {
                        print("native-ui: refused \(type(of: element)), sheets \(window.sheets.count), key \(window.isKeyWindow)")
                        for sheet in window.sheets { dump(sheet) }
                        throw Playthrough.Failure(message: "Native UI button refused press: \(identifier)")
                    }
                }
                nativePresses += 1
                settle()
            }
            func setValue(_ identifier: String, _ value: Double) throws {
                settle()
                guard let element = find(identifier, in: host) else {
                    dump(host)
                    throw Playthrough.Failure(message: "Native value control not found: \(identifier)")
                }
                let selector = NSSelectorFromString("setAccessibilityValue:")
                guard element.responds(to: selector) else {
                    throw Playthrough.Failure(message: "Control has no native value action: \(identifier)")
                }
                typealias SetValueAction = @convention(c) (AnyObject, Selector, AnyObject) -> Void
                let action = unsafeBitCast(element.method(for: selector), to: SetValueAction.self)
                action(element, selector, NSNumber(value: value))
                settle()
                print("native-ui: set \(identifier) to \(value), observed \(objectValue(element, "accessibilityValue") ?? "nil")")
                // SwiftUI's slider AX value setter may be read-only on some macOS versions.
                // Use the same visible one-unit buttons a player uses for exact quantities.
                if let counter = find(identifier + ".count", in: host),
                   let text = objectValue(counter, "accessibilityValue") as? String, let current = Int(text) {
                    let target = Int(value)
                    for _ in 0..<abs(target - current) {
                        try press(identifier + (target > current ? ".increase" : ".decrease"))
                    }
                    guard let updated = find(identifier + ".count", in: host),
                          objectValue(updated, "accessibilityValue") as? String == String(target) else {
                        throw Playthrough.Failure(message: "Quantity buttons failed to reach \(target)")
                    }
                }
            }
            if suite == "foundation" || suite == "m0" || suite == "focus" || suite == "m0-tail" {
                func event(_ code: UInt16, _ characters: String, _ repeated: Bool = false) throws -> NSEvent {
                    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: repeated, keyCode: code) else {
                        throw Playthrough.Failure(message: "Could not construct a foundation key event")
                    }
                    return event
                }
                func nativeChecks() -> FoundationPlaythrough.NativeChecks {
                    FoundationPlaythrough.NativeChecks(
                        sendKey: { code, characters, repeated in
                            NSApp.activate(ignoringOtherApps: true)
                            window.makeKeyAndOrderFront(nil)
                            settle()
                            NSApp.sendEvent(try event(code, characters, repeated))
                            settle()
                        }, repeatKey: { code, characters in
                            _ = game.handleKey(try event(code, characters, true))
                            settle()
                        }, retainPress: { identifier in
                            settle()
                            guard let element = find(identifier, in: host) else {
                                throw Playthrough.Failure(message: "Cannot retain AX button: \(identifier)")
                            }
                            try reveal(element, identifier: identifier)
                            let selector = NSSelectorFromString("accessibilityPerformPress")
                            guard element.responds(to: selector) else { throw Playthrough.Failure(message: "No retained AX press action") }
                            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
                            let action = unsafeBitCast(element.method(for: selector), to: Action.self)
                            return {
                                // Intentionally bypass the driver's modal guard: this tests the app's
                                // own stale-control guard, including two actions before a render pass.
                                _ = action(element, selector)
                                nativePresses += 1
                            }
                        }, choose: { identifier, title in
                            settle()
                            func popup(_ view: NSView) -> NSPopUpButton? {
                                if let button = view as? NSPopUpButton,
                                   objectValue(button, "accessibilityIdentifier") as? String == identifier { return button }
                                return view.subviews.compactMap { popup($0) }.first
                            }
                            guard let button = popup(host), let item = button.itemArray.first(where: { $0.title == title }),
                                  button.isEnabled, item.isEnabled, let action = button.action else {
                                throw Playthrough.Failure(message: "Native popup item unavailable: \(identifier) / \(title)")
                            }
                            try reveal(button, identifier: identifier)
                            button.selectItem(withTitle: title)
                            guard button.sendAction(action, to: button.target) else { throw Playthrough.Failure(message: "Native popup refused selection") }
                            settle()
                        }, focus: { identifier in
                            settle()
                            guard let element = find(identifier, in: host) else { throw Playthrough.Failure(message: "Focus control missing: \(identifier)") }
                            try reveal(element, identifier: identifier)
                            let selector = NSSelectorFromString("setAccessibilityFocused:")
                            guard element.responds(to: selector) else { throw Playthrough.Failure(message: "Control has no native focus action") }
                            typealias Focus = @convention(c) (AnyObject, Selector, Bool) -> Void
                            unsafeBitCast(element.method(for: selector), to: Focus.self)(element, selector, true)
                            settle()
                            if (window.firstResponder as? NSTextView)?.isEditable != true {
                                // SwiftUI's AX focus can select an accessibility proxy without
                                // beginning editing. Click the visible field with native events.
                                let rect = frame(of: element)
                                let point = window.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY))
                                window.makeKeyAndOrderFront(nil)
                                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                    guard let event = NSEvent.mouseEvent(with: type, location: point,
                                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                                        throw Playthrough.Failure(message: "Native focus click could not be constructed")
                                    }
                                    NSApp.sendEvent(event)
                                }
                                settle()
                            }
                        }, hasEditableFocus: { (window.firstResponder as? NSTextView)?.isEditable == true },
                        wait: { seconds in RunLoop.current.run(until: Date().addingTimeInterval(seconds)); settle() },
                        assetsFailure: {
                            let broken = SaveGame.directory.appendingPathComponent("broken-assets", isDirectory: true)
                            // Corrupt one real input. An otherwise empty folder produces
                            // hundreds of missing-file errors whose first-page summary
                            // need not include this particular path.
                            try FileManager.default.copyItem(at: assets.resolvingSymlinksInPath(), to: broken)
                            try Data([0]).write(to: broken.appendingPathComponent("world_mask.bin"))
                            var details: String?
                            do { _ = try Game(assets: broken) }
                            catch { details = "자료 위치: \(broken.path)\n\n\(error.localizedDescription)" }
                            guard let details, details.contains("world_mask.bin") else {
                                throw Playthrough.Failure(message: "Broken asset fixture did not produce an exact startup error")
                            }
                            let pasteboard = NSPasteboard.general
                            let priorItems = (pasteboard.pasteboardItems ?? []).map { item in
                                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
                            }
                            guard zip(pasteboard.pasteboardItems ?? [], priorItems).allSatisfy({ $0.0.types.count == $0.1.count }) else {
                                throw Playthrough.Failure(message: "Clipboard contains a format that cannot be preserved; copy test did not modify it")
                            }
                            func restoreClipboard() {
                                pasteboard.clearContents()
                                let restored = priorItems.map { entries -> NSPasteboardItem in
                                    let item = NSPasteboardItem()
                                    for (type, data) in entries { item.setData(data, forType: type) }
                                    return item
                                }
                                if !restored.isEmpty { pasteboard.writeObjects(restored) }
                            }
                            var restoredClipboard = false
                            defer { if !restoredClipboard { restoreClipboard() } }
                            let errorHost = NSHostingView(rootView: MissingAssetsView(details: details))
                            let errorWindow = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                            errorWindow.title = "Portolan · 격리 자료 오류 검증"
                            errorWindow.contentView = errorHost
                            errorHost.frame = CGRect(origin: .zero, size: size)
                            errorWindow.center(); errorWindow.makeKeyAndOrderFront(nil)
                            defer { errorWindow.orderOut(nil); window.makeKeyAndOrderFront(nil) }
                            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                            errorHost.layoutSubtreeIfNeeded()
                            guard let label = find("portolan.assets.error", in: errorHost), textTree(label).contains("world_mask.bin"),
                                  let button = find("portolan.assets.copy", in: errorHost) else {
                                throw Playthrough.Failure(message: "Startup error or copy button is absent from actual AX tree")
                            }
                            let viewport = errorWindow.convertToScreen(errorHost.convert(errorHost.bounds, to: nil))
                            guard viewport.insetBy(dx: -2, dy: -2).contains(frame(of: button)) else { throw Playthrough.Failure(message: "Startup error copy button is clipped") }
                            let selector = NSSelectorFromString("accessibilityPerformPress")
                            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
                            guard button.responds(to: selector), unsafeBitCast(button.method(for: selector), to: Action.self)(button, selector),
                                  pasteboard.string(forType: .string) == details else {
                                throw Playthrough.Failure(message: "Actual startup copy button did not copy the complete diagnostic")
                            }
                            nativePresses += 1
                            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                            guard let rep = errorHost.bitmapImageRepForCachingDisplay(in: errorHost.bounds) else { throw Playthrough.Failure(message: "Cannot capture startup failure") }
                            errorHost.cacheDisplay(in: errorHost.bounds, to: rep)
                            try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("m0_assets_error.png"))
                            restoreClipboard()
                            let restoredItems = (pasteboard.pasteboardItems ?? []).map { item in
                                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
                            }
                            guard restoredItems == priorItems else { throw Playthrough.Failure(message: "Clipboard formats did not restore exactly") }
                            restoredClipboard = true
                            print("m0: PASS — isolated broken assets rejected before Game creation; actual error-view AX copy preserves exact details; prior clipboard item formats and bytes restored and verified")
                        })
                }
                try FoundationPlaythrough.run(game: game, directory: directory, size: size,
                    capture: capture, press: press, text: { identifier in
                        settle()
                        guard let element = find(identifier, in: host) ?? find(identifier, in: window) else { return nil }
                        return textTree(element)
                    }, key: { code, characters in
                        let consumed = game.handleKey(try event(code, characters))
                        settle()
                        return consumed
                    }, native: suite == "m0" || suite == "focus" || suite == "m0-tail" ? nativeChecks() : nil, selection: suite == "focus" ? "focus" : suite == "m0-tail" ? "tail" : "all")
                print("native-ui: PASS — foundation fixture integration, \(nativePresses) actual AX button presses at \(Int(size.width))×\(Int(size.height)); not a campaign or VoiceOver run")
                return success()
            }
            if env["PORTOLAN_PLAYTEST_SUITE"] == "layout" {
                // Layout fixtures are separate from the untouched trade/battle playthroughs.
                // They stress dense menus without claiming these resources were earned.
                game.voyage = Voyage.joanAfterPrologue(in: game.world)
                game.voyage.gold = 120000
                game.voyage.tick = 30
                game.status = game.voyage
                game.title = false
                game.harbor = game.world.ports[game.voyage.marketIndex]
                game.camera = (game.voyage.x, game.voyage.y)
                if env["PORTOLAN_LAYOUT_FOCUS"] == "menus" {
                    func choose(_ id: String, _ index: Int) throws {
                        settle()
                        func popup(in view: NSView) -> NSPopUpButton? {
                            if let button = view as? NSPopUpButton,
                               objectValue(button, "accessibilityIdentifier") as? String == id { return button }
                            return view.subviews.compactMap { popup(in: $0) }.first
                        }
                        guard let popup = popup(in: host), let action = popup.action else {
                            throw Playthrough.Failure(message: "Native action menu missing: \(id)")
                        }
                        try reveal(popup, identifier: id)
                        precondition(popup.font?.pointSize == 18 && popup.bounds.height >= 32)
                        for item in popup.itemArray.dropFirst() {
                            precondition((item.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18)
                        }
                        precondition(popup.item(at: index)?.isEnabled == true)
                        popup.selectItem(at: index)
                        precondition(popup.sendAction(action, to: popup.target))
                        settle()
                    }
                    var stored = game.voyage.ships[0]
                    stored.name = "메뉴 검증선"
                    game.voyage.ships.append(stored)
                    _ = game.voyage.storeShip(1, at: game.voyage.marketIndex)
                    game.status = game.voyage
                    game.panel = .harbor
                    try press("portolan.harbor.tab.dock")
                    capture("menu_dock_before", game)
                    try choose("portolan.dock.exchange.0", 1)
                    precondition(game.status.ships[0].name == "메뉴 검증선")
                    capture("menu_dock_exchanged", game)
                    try press("portolan.building.leave")
                    game.harbor = nil
                    game.voyage.leaveTown()
                    game.voyage.ships[0].crew = 30
                    let enemy = game.voyage.memory.fb(22, FleetField.admiral)
                    game.battle = game.voyage.beginBattle(Encounter(attacker: game.voyage.heroID, defender: enemy), in: game.world)
                    game.status = game.voyage
                    precondition(game.battle != nil)
                    capture("menu_battle", game)
                    try choose("portolan.battle.info.menu", 1)
                    precondition(game.info == .fleet)
                    capture("menu_battle_information", game)
                    try press("portolan.info.close")
                    print("native-ui: PASS — 18pt action menu items, native dock exchange and battle information actions; prepared layout fixture only")
                    return success()
                }
                if env["PORTOLAN_LAYOUT_FOCUS"] == "pickers" {
                    func popups(in view: NSView) -> [NSPopUpButton] {
                        ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap { popups(in: $0) }
                    }
                    for command in [FleetCommand.captain, .cargo] {
                        game.command = command
                        settle()
                        for popup in popups(in: host) {
                            precondition(popup.font?.pointSize == 18 && popup.bounds.height >= 32)
                            for item in popup.itemArray {
                                precondition((item.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18)
                            }
                            if popup.numberOfItems > 1, let action = popup.action {
                                let before = popup.indexOfSelectedItem, next = (before + 1) % popup.numberOfItems
                                popup.selectItem(at: next)
                                precondition(popup.sendAction(action, to: popup.target))
                                settle()
                                precondition(popup.indexOfSelectedItem == next)
                                popup.selectItem(at: before)
                                precondition(popup.sendAction(action, to: popup.target))
                                settle()
                            }
                        }
                        capture("picker_command_\(command.rawValue)", game)
                        try press("portolan.command.close")
                    }
                    for screen in [InfoScreen.ship, .person] {
                        game.info = screen
                        capture("picker_info_\(screen.title)", game)
                        try press("portolan.info.close")
                    }
                    game.panel = .shipyard
                    try press("portolan.shipyard.tab.1")
                    capture("picker_shipyard", game)
                    try press("portolan.building.leave")
                    print("native-ui: PASS — 18pt native popup control/menu fonts, next/restore target actions, and captured picker screenshots")
                    return success()
                }
                capture("layout_00_harbor", game)
                for panel in HarborPanel.allCases {
                    game.panel = panel
                    if panel == .tavern {
                        game.tavern = Tavern(market: game.market, drinks: game.world.navigation.drinks, charm: game.status.captain.charm)
                    }
                    settle()
                    if game.portMessageText != nil && game.session == nil {
                        capture("layout_building_\(panel.rawValue)_greeting", game)
                        try press("portolan.portMessage.dismiss")
                    }
                    capture("layout_building_\(panel.rawValue)", game)
                    if panel == .harbor {
                        let shot = game.status.ships[0].shot, gold = game.status.gold
                        try press("portolan.supply.3.quantity.increase")
                        try press("portolan.supply.3.buy")
                        precondition(game.status.ships[0].shot == shot + 1 && game.status.gold < gold)
                        capture("layout_supply_bottom_purchased", game)
                        print("native-ui: scrolled to the final supply row and bought one shot barrel")
                    }
                    if panel == .shipyard {
                        for tab in 0..<6 {
                            try press("portolan.shipyard.tab.\(tab)")
                            capture("layout_shipyard_\(tab)", game)
                        }
                    }
                    try press("portolan.building.leave")
                    if game.portMessageText != nil && game.session == nil { try press("portolan.portMessage.dismiss") }
                }
                for service in HarborPanel.allCases {
                    guard find("portolan.harbor.visit.\(service.rawValue)", in: host) == nil else {
                        throw Playthrough.Failure(message: "Removed facility teleport button is still exposed")
                    }
                }
                capture("layout_town_walking", game)
                game.openVoyagePlan()
                capture("layout_plan", game)
                try press("portolan.plan.close")
                for command in [FleetCommand.captain, .crew, .shares, .scuttle, .cargo, .formation, .pay, .items, .system] {
                    game.command = command
                    capture("layout_command_\(command.rawValue)", game)
                    try press("portolan.command.close")
                }
                game.showFleet(tab: 0)
                for tab in 0..<4 {
                    try press("portolan.fleet.tab.\(tab)")
                    capture("layout_fleet_\(tab)", game)
                }
                game.showFleet = false
                for screen in [InfoScreen.fleet, .ship, .person, .hero, .cargo, .cargoList, .discoveries, .chart, .logbook, .portMap] {
                    game.info = screen
                    capture("layout_info_\(screen.title)", game)
                    game.info = nil
                }
                game.save()
                capture("layout_save_slots", game)
                if let lastSlot = find("portolan.slots.slot.9", in: host) {
                    try reveal(lastSlot, identifier: "portolan.slots.slot.9")
                    capture("layout_save_slots_bottom", game)
                }
                try press("portolan.slots.close")
                game.question = Question(text: "리스본에서 출항합니다.\n식수와 식량, 선원 배치를 확인해 주세요.\n이 확인창의 본문과 예·아니오 버튼도 큰 글씨로 표시됩니다.") {}
                capture("layout_confirmation", game)
                try press("portolan.question.no")
                game.panel = nil
                game.harbor = nil
                game.voyage.leaveTown()
                game.status = game.voyage
                capture("layout_sea", game)
                game.showHelp = true
                capture("layout_sea_help", game)
                print("native-ui: PASS — layout fixture gallery and \(nativePresses) actual close/confirmation buttons at \(Int(size.width))×\(Int(size.height)); no save slots written")
                return success()
            }
            if env["PORTOLAN_PLAYTEST_SUITE"] == "heroes" {
                game.newGame()
                try press("portolan.title.menu.0")
                for h in 0..<6 {
                    try press("portolan.hero.pick.\(h)")
                    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                    guard let selected = find("portolan.hero.selected", in: host),
                          objectValue(selected, "accessibilityValue") as? String == String(h) else {
                        throw Playthrough.Failure(message: "Hero portrait did not select the matching biography")
                    }
                    capture("hero_\(h)", game)
                }
                try press("portolan.hero.pick.0")
                try press("portolan.hero.confirm")
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                guard find("portolan.hero.given", in: host) != nil && find("portolan.hero.family", in: host) != nil else {
                    throw Playthrough.Failure(message: "Hero name entry is missing")
                }
                capture("hero_naming", game)
                try press("portolan.hero.cancel")
                try press("portolan.hero.confirm")
                try press("portolan.hero.confirm")
                guard !game.title, game.status.heroID == 0,
                      game.status.memory.person(0).name == game.world.memory?.person(0).name else {
                    throw Playthrough.Failure(message: "Larger hero controls changed the new-game selection or name")
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                capture("hero_new_game", game)
                print("native-ui: PASS — 6 hero biographies, name entry/back/confirmation and untouched default name; \(nativePresses) native button presses at \(Int(size.width))×\(Int(size.height))")
                return success()
            }
            // Reproduce the screenshot's hidden town line and the vanished service notice.
            game.startNewGame(hero: 0)
            game.townMessage = "제독님! 저택으로 가시면 아버님을 만날 수 있습니다.\n주민의 말이 조작 안내 위에 가려지지 않아야 합니다."
            capture("00_town_dialogue_regression", game)
            let before = game.status.townHero
            for _ in 0..<60 { game.update(dt: 1.0 / 60, viewSize: size) }
            precondition(game.portMessageText != nil && game.status.townHero == before)
            try press("portolan.portMessage.dismiss")
            precondition(game.townMessage == nil)
            game.say("항구에서 준비를 마치고 출항하세요.\n이 안내는 확인할 때까지 사라지지 않습니다.")
            for _ in 0..<360 { game.update(dt: 1.0 / 60, viewSize: size) }
            precondition(game.portMessageText != nil, "Port service reply expired unread")
            capture("00_service_dialogue_regression", game)
            try press("portolan.portMessage.dismiss")
            precondition(game.notice == nil)
            print("native-ui: town and service dialogues displayed, remain readable, and dismiss through their real buttons")
            var confirmed = false
            game.question = Question(text: "출항 확인 버튼 검증") { confirmed = true }
            try press("portolan.question.yes")
            precondition(confirmed && game.question == nil, "Native confirmation did not confirm")
            for key: UInt16 in [36, 53] {
                var accepted = false, refused = false
                game.question = Question(text: "큰 글씨 확인창 키 입력 검사", action: { accepted = true }, refuse: { refused = true })
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: key == 36 ? "\r" : "\u{1b}",
                    charactersIgnoringModifiers: key == 36 ? "\r" : "\u{1b}", isARepeat: false, keyCode: key)!
                precondition(game.handleKey(event) && game.question == nil && (key == 36 ? accepted && !refused : refused && !accepted),
                             "Confirmation Return/Escape did not preserve yes/no actions")
            }
            if ProcessInfo.processInfo.environment["PORTOLAN_PLAYTEST_SUITE"] == "controls" { return success() }
            let answer: (Game, Int) throws -> Void = { current, value in
                let beforePrompt = current.session?.prompt
                let beforeWindows = current.session?.run?.windows
                let identifier: String
                switch beforePrompt {
                case .next?: identifier = "portolan.dialogue.continue"
                case .yesNo?: identifier = value == 1 ? "portolan.dialogue.yes" : "portolan.dialogue.no"
                case .menu?: identifier = "portolan.dialogue.choice.\(value)"
                default: throw Playthrough.Failure(message: "Unsupported native dialogue input")
                }
                if beforePrompt == .next && (nativePresses + keyboardAdvances) % 11 == 0 {
                    let code = keyboardAdvances % 2 == 0 ? KeyCode.returnKey : KeyCode.space
                    let characters = code == KeyCode.returnKey ? "\r" : " "
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
                    guard current.handleKey(event) else { throw Playthrough.Failure(message: "Dialogue did not accept Return/Space") }
                    keyboardAdvances += 1
                    settle()
                } else {
                    try press(identifier)
                }
                guard current.session?.prompt != beforePrompt || current.session?.run?.windows != beforeWindows else {
                    throw Playthrough.Failure(message: "Native dialogue button did not change the visible prompt: \(identifier)")
                }
            }
            if suite != "battle" {
                try Playthrough.run(game: game, capture: capture, press: press, answer: answer)
            }
            if suite == "trade" || suite == "all" {
                try TradePlaythrough.run(game: game, capture: capture, press: press, setValue: setValue, answer: answer)
            }
            if suite == "battle" || suite == "all" {
                try BattlePlaythrough.run(game: game, capture: capture, press: press, setValue: setValue, answer: answer)
            }
            print("native-ui: PASS — \(nativePresses) actual SwiftUI button presses and \(keyboardAdvances) Return/Space events at 960×600")
            return success()
        } catch {
            print("PLAYTEST FAILED: \(error.localizedDescription)")
            captureFailure?()
            return false
        }
    }
}
