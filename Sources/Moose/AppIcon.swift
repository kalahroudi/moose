// SPDX-License-Identifier: Apache-2.0

import AppKit

/// The moose mark in a 100×100 design space: two antlers over a muzzle that doubles as an envelope flap.
/// Shared by the app icon and the menu bar glyph so they always match.
enum MooseMark {
    static func antlers() -> NSBezierPath {
        let left = NSBezierPath()
        left.move(to: NSPoint(x: 41, y: 63)); left.curve(to: NSPoint(x: 13, y: 21), controlPoint1: NSPoint(x: 35, y: 46), controlPoint2: NSPoint(x: 23, y: 40))   // main beam
        left.move(to: NSPoint(x: 29, y: 41)); left.curve(to: NSPoint(x: 11, y: 46), controlPoint1: NSPoint(x: 22, y: 36), controlPoint2: NSPoint(x: 15, y: 38))   // brow tine
        left.move(to: NSPoint(x: 22, y: 32)); left.line(to: NSPoint(x: 19, y: 11))                                                                               // upper tine
        left.move(to: NSPoint(x: 37, y: 53)); left.curve(to: NSPoint(x: 27, y: 60), controlPoint1: NSPoint(x: 32, y: 51), controlPoint2: NSPoint(x: 29, y: 54))     // low tine
        let both = NSBezierPath()
        both.append(left)
        let mirror = AffineTransform(translationByX: 100, byY: 0)
        var flip = AffineTransform(scaleByX: -1, byY: 1); flip.append(mirror)
        let right = left.copy() as! NSBezierPath
        right.transform(using: flip)
        both.append(right)
        both.lineCapStyle = .round; both.lineJoinStyle = .round
        return both
    }

    static func muzzle() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 37, y: 66)); p.line(to: NSPoint(x: 63, y: 66))
        p.line(to: NSPoint(x: 57, y: 88)); p.curve(to: NSPoint(x: 43, y: 88), controlPoint1: NSPoint(x: 54, y: 95), controlPoint2: NSPoint(x: 46, y: 95))
        p.close(); p.lineJoinStyle = .round
        return p
    }

    /// The envelope-flap "V" cut into the muzzle.
    static func flap() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 40, y: 70)); p.line(to: NSPoint(x: 50, y: 79)); p.line(to: NSPoint(x: 60, y: 70))
        p.lineCapStyle = .round; p.lineJoinStyle = .round
        return p
    }
}

/// The app icon, drawn in code so the build needs no image tools and stays crisp at every size.
enum AppIcon {
    /// - padded: leave the transparent margin macOS expects around Dock icons (824 of 1024).
    static func image(size: CGFloat, padded: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let s = size / 1024
            let inset: CGFloat = padded ? 100 : 0
            let tile = NSRect(x: inset * s, y: inset * s, width: (1024 - 2 * inset) * s, height: (1024 - 2 * inset) * s)
            let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2246, yRadius: tile.width * 0.2246)
            NSGradient(starting: NSColor(srgbRed: 0.169, green: 0.322, blue: 0.278, alpha: 1), ending: NSColor(srgbRed: 0.063, green: 0.149, blue: 0.122, alpha: 1))?.draw(in: shape, angle: -90)

            // Place the 100-unit mark in the middle of the tile.
            let k = tile.width * 0.78 / 100
            var t = AffineTransform(translationByX: tile.minX + tile.width * 0.11, byY: tile.minY + tile.width * 0.11)
            t.scale(x: k, y: k)

            let antlers = MooseMark.antlers(); antlers.lineWidth = 8.6; antlers.transform(using: t)
            NSGraphicsContext.saveGraphicsState()
            let stroked = antlers.cgPath.copy(strokingWithWidth: antlers.lineWidth * 1, lineCap: .round, lineJoin: .round, miterLimit: 10)
            NSBezierPath(cgPath: stroked).addClip()
            NSGradient(starting: NSColor(srgbRed: 0.984, green: 0.851, blue: 0.651, alpha: 1), ending: NSColor(srgbRed: 0.89, green: 0.6, blue: 0.29, alpha: 1))?.draw(in: tile, angle: -90)
            NSGraphicsContext.restoreGraphicsState()

            let muzzle = MooseMark.muzzle(); muzzle.transform(using: t)
            NSColor(srgbRed: 0.965, green: 0.906, blue: 0.812, alpha: 1).setFill(); muzzle.fill()
            let flap = MooseMark.flap(); flap.transform(using: t); flap.lineWidth = 3.2 * k
            NSColor(srgbRed: 0.063, green: 0.149, blue: 0.122, alpha: 1).setStroke(); flap.stroke()
            return true
        }
    }

    /// Writes an .iconset folder for `iconutil -c icns`.
    static func writeIconset(to dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sizes: [(String, CGFloat)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                                          ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
        for (name, px) in sizes {
            guard let tiff = image(size: px, padded: true).tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("icon_\(name).png"))
        }
    }
}

extension NSBezierPath {
    /// Bridge for clipping to a stroked outline.
    var cgPath: CGPath {
        let path = CGMutablePath(); var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo: path.move(to: pts[0])
            case .lineTo: path.addLine(to: pts[0])
            case .curveTo, .cubicCurveTo: path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .closePath: path.closeSubpath()
            default: break
            }
        }
        return path
    }
}
