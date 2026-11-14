#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation
import PortolanCore

/// Faces of minor characters, assembled from parts as MAIN.EXE does (0x7A4E,
/// docs/re/faces.md): per nation a set of tops, bottoms, eyes, noses and mouths picked by the
/// bits of person +0x1A. Eyes, nose and mouth are OR-ed into the palette indices below them.
final class FaceComposer {
    private struct Layer: Decodable {
        let name: String, shift: Int, mask: Int, x: Int, y: Int, width: Int, height: Int, blend: String
    }
    private struct Set_: Decodable { let parts: [String: [String]] }
    private struct File: Decodable {
        let width: Int, height: Int
        let palette: [[Int]]
        let layers: [Layer]
        let sets: [Set_]
    }

    private let dir: URL
    private var file: File?
    /// Part pictures as palette indices, 255 for transparent.
    private var parts: [String: [UInt8]] = [:]
    private var cache: [Int: NSImage] = [:]

    init(assets: URL) {
        dir = assets.appendingPathComponent("faces")
        if let d = try? Data(contentsOf: dir.appendingPathComponent("faces.json")) {
            file = try? JSONDecoder().decode(File.self, from: d)
        }
    }

    private func indices(_ name: String, _ w: Int, _ h: Int) -> [UInt8]? {
        if let p = parts[name] { return p }
        guard let f = file, let img = NSImage(contentsOf: dir.appendingPathComponent(name)),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [UInt8](repeating: 255, count: w * h)
        for i in 0..<(w * h) where rgba[i * 4 + 3] > 127 {
            let c = (Int(rgba[i * 4]), Int(rgba[i * 4 + 1]), Int(rgba[i * 4 + 2]))
            let k = f.palette.indices.min { a, b in
                let pa = f.palette[a], pb = f.palette[b]
                return abs(pa[0] - c.0) + abs(pa[1] - c.1) + abs(pa[2] - c.2) < abs(pb[0] - c.0) + abs(pb[1] - c.1) + abs(pb[2] - c.2)
            } ?? 0
            out[i] = UInt8(k)
        }
        parts[name] = out
        return out
    }

    /// The face for a 14-bit value in nation set `set` (0...6).
    func face(_ value: Int, set: Int) -> NSImage? {
        guard let f = file, f.sets.indices.contains(set) else { return nil }
        let key = set << 16 | (value & 0x3FFF)
        if let c = cache[key] { return c }
        var pix = [UInt8](repeating: 0, count: f.width * f.height)
        for l in f.layers {
            let k = (value >> l.shift) & l.mask
            guard let names = f.sets[set].parts[l.name], names.indices.contains(k),
                  let p = indices(names[k], l.width, l.height) else { continue }
            for y in 0..<l.height {
                for x in 0..<l.width {
                    let v = p[y * l.width + x]
                    let at = (l.y + y) * f.width + l.x + x
                    guard at < pix.count else { continue }
                    if l.blend == "copy" {
                        if v != 255 { pix[at] = v }
                    } else if v != 255 && v != 0 {
                        pix[at] |= v
                    }
                }
            }
        }
        var rgba = [UInt8](repeating: 255, count: pix.count * 4)
        for (i, v) in pix.enumerated() {
            let c = f.palette[Int(v) & 7]
            rgba[i * 4] = UInt8(c[0]); rgba[i * 4 + 1] = UInt8(c[1]); rgba[i * 4 + 2] = UInt8(c[2])
        }
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.width * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: f.width, height: f.height))
        cache[key] = img
        return img
    }
}

extension Game {
    /// A portrait by its person +0x1A value: KAO pictures, or a face assembled from parts.
    func portrait(face value: Int, nation: Int = 0) -> NSImage? {
        if value & 0xC000 != 0 { return faces.face(value & 0x3FFF, set: min(6, nation)) }
        return value < 128 ? image(String(format: "portraits/%03d.png", value)) : nil
    }

    func portrait(person p: Int) -> NSImage? {
        let m = status.memory
        return portrait(face: m.word(DS.person(p) + 0x1A), nation: m[DS.person(p) + 0x31] & 0xF)
    }
}
