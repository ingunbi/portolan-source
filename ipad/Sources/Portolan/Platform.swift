import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// A thin layer so the game's views run on iPadOS as well as macOS: the AppKit image types map to
// UIKit ones, and mac-only pieces (cursors, the key monitor, the window) are fenced with #if.
#if canImport(UIKit) && !os(macOS)
import UIKit

typealias NSImage = UIImage
typealias NSSize = CGSize
typealias NSWindow = UIWindow
typealias NSFont = UIFont
/// Mouse cursors do not exist on iPadOS; calls to them do nothing.
struct NSCursor { static let arrow = NSCursor(); func set() {} }

extension UIImage {
    convenience init?(contentsOf url: URL) { self.init(contentsOfFile: url.path) }
    convenience init(cgImage: CGImage, size: CGSize) { self.init(cgImage: cgImage, scale: 1, orientation: .up) }
    func cgImage(forProposedRect rect: UnsafeMutablePointer<CGRect>?, context: Any?, hints: [AnyHashable: Any]?) -> CGImage? { cgImage }
}

struct PixelRepresentation { let pixelsWide: Int; let pixelsHigh: Int }
extension UIImage {
    var representations: [PixelRepresentation] { [PixelRepresentation(pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale))] }
}

extension Image {
    init(nsImage: UIImage) { self.init(uiImage: nsImage) }
}
#endif

/// Leaves the game (on iPadOS leaving is the home gesture, so the title menu has no 종료 there).
func quitGame() {
    #if os(macOS)
    NSApp.terminate(nil)
    #endif
}
