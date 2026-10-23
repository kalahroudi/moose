// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import MooseKit

/// Email text you can select, with long links shown as short labels. A native text view, because SwiftUI's `Text` cannot say what is selected,
/// and "reply to this passage" needs exactly that.
struct SelectableText: NSViewRepresentable {
    let paragraphs: [String]
    var mono = false
    var muted = false
    var size: CGFloat = 14
    /// Called with the selected text and where it is (in this view's own coordinates); nil when nothing is selected.
    var onSelect: ((String, CGRect)?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView(frame: .zero)
        tv.isEditable = false; tv.isSelectable = true; tv.drawsBackground = false
        tv.textContainerInset = .zero; tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = false; tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.isAutomaticLinkDetectionEnabled = false
        tv.linkTextAttributes = [:]
        tv.delegate = context.coordinator
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        let c = context.coordinator
        c.onSelect = onSelect
        let key = "\(paragraphs.joined(separator: "\u{1}"))|\(mono)|\(muted)|\(size)"
        if c.key != key {
            c.key = key
            tv.textStorage?.setAttributedString(attributed())
            tv.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NSTextView, context: Context) -> CGSize? {
        let w = max(proposal.width ?? 600, 80)
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        tc.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return CGSize(width: w, height: ceil(lm.usedRect(for: tc).height))
    }

    private func attributed() -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = mono ? 2 : 4; para.paragraphSpacing = mono ? 0 : 11
        let color: NSColor = muted ? .secondaryLabelColor : .labelColor
        let font: NSFont = mono ? .monospacedSystemFont(ofSize: size - 1.5, weight: .regular) : .systemFont(ofSize: size)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let out = NSMutableAttributedString()
        for (i, p) in paragraphs.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: base)) }
            if mono { out.append(NSAttributedString(string: p, attributes: base)); continue }
            var rest = p[...]
            while let r = rest.range(of: MailText.urlPattern, options: .regularExpression) {
                out.append(NSAttributedString(string: String(rest[..<r.lowerBound]), attributes: base))
                var url = String(rest[r]), tail = ""
                while let l = url.last, ".,;:!?".contains(l) { tail.insert(l, at: tail.startIndex); url.removeLast() }
                var attrs = base
                attrs[.foregroundColor] = NSColor(Theme.accent)
                attrs[.toolTip] = url
                if let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased()) { attrs[.link] = u }
                out.append(NSAttributedString(string: "↗ " + MailText.linkLabel(url), attributes: attrs))
                if !tail.isEmpty { out.append(NSAttributedString(string: tail, attributes: base)) }
                rest = rest[r.upperBound...]
            }
            out.append(NSAttributedString(string: String(rest), attributes: base))
        }
        return out
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var key = ""
        var onSelect: ((String, CGRect)?) -> Void = { _ in }

        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv = n.object as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let range = tv.selectedRange()
            guard range.length > 0 else { DispatchQueue.main.async { self.onSelect(nil) }; return }
            let text = (tv.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tc)
            DispatchQueue.main.async { self.onSelect(text.isEmpty ? nil : (text, rect)) }
        }

        /// Only web and mail links open; anything else in an email is ignored.
        func textView(_ tv: NSTextView, clickedOnLink link: Any, at index: Int) -> Bool {
            if let u = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)), ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(u) }
            return true
        }
    }
}
