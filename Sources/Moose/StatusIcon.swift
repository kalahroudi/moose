// SPDX-License-Identifier: Apache-2.0

import AppKit

/// The menu bar glyph: the moose mark as a template image, so macOS tints it for light and dark bars.
/// State lives in the SHAPE, not colour: filled muzzle = priority mail waiting, outline = all clear, dashed antlers = checking.
enum StatusIcon {
    enum State { case active, idle, busy }

    static func image(_ state: State) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            let k: CGFloat = 0.185
            var t = AffineTransform(translationByX: 1.1, byY: 0.3); t.scale(x: k, y: k)
            let antlers = MooseMark.antlers(); antlers.transform(using: t); antlers.lineWidth = 2.0
            let muzzle = MooseMark.muzzle(); muzzle.transform(using: t); muzzle.lineWidth = 1.5
            NSColor.black.setFill(); NSColor.black.setStroke()
            if state == .busy { antlers.setLineDash([2.2, 1.6], count: 2, phase: 0) }
            antlers.stroke()
            if state == .active { muzzle.fill() } else { muzzle.stroke() }
            return true
        }
        img.isTemplate = true
        return img
    }
}
