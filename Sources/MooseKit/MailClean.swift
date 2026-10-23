// SPDX-License-Identifier: Apache-2.0

import Foundation

/// An email body made readable: broken sentences re-joined, blank runs collapsed, footer boilerplate set apart.
public struct CleanedMail: Equatable, Sendable {
    public var paragraphs: [String]
    public var footer: [String]
    public var blankLinesRemoved: Int
    public var links: [MailLink]
    public init(paragraphs: [String] = [], footer: [String] = [], blankLinesRemoved: Int = 0, links: [MailLink] = []) {
        self.paragraphs = paragraphs; self.footer = footer; self.blankLinesRemoved = blankLinesRemoved; self.links = links
    }
    public var plain: String { paragraphs.joined(separator: "\n\n") }
    /// Short enough that a summary would only add noise.
    public var isShort: Bool { MailText.wordCount(plain) < 60 || paragraphs.count <= 1 && plain.count < 300 }
}

public struct MailLink: Equatable, Hashable, Sendable {
    public var url: String
    public var label: String
    public var tracker: Bool
}

public extension MailText {
    static func wordCount(_ s: String) -> Int { s.split { $0.isWhitespace }.count }

    static let urlPattern = "https?://[^\\s<>\"')\\]]+"

    /// "https://www.example.com/a?b" → "example.com"
    static func linkLabel(_ url: String) -> String {
        guard let host = URL(string: url)?.host?.lowercased() else { return "link" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Tracking and unsubscribe style links: long, signed, or carrying campaign parameters.
    static func isTracker(_ url: String) -> Bool {
        let u = url.lowercased()
        if u.count > 140 { return true }
        return ["signature=", "utm_", "campaign", "notrack", "tid=", "/track", "/click", "unsubscribe", "list-manage", "sendgrid", "mailchi.mp"].contains { u.contains($0) }
    }

    /// Every distinct http(s) link in the text, in order.
    static func links(in text: String) -> [MailLink] {
        var seen = Set<String>(), out: [MailLink] = []
        var rest = text[...]
        while let r = rest.range(of: urlPattern, options: .regularExpression) {
            var url = String(rest[r])
            while let l = url.last, ".,;:!?".contains(l) { url.removeLast() }
            if seen.insert(url).inserted { out.append(MailLink(url: url, label: linkLabel(url), tracker: isTracker(url))) }
            rest = rest[r.upperBound...]
        }
        return out
    }

    private static let footerMarkers = [
        "unsubscribe", "view in browser", "view this email", "you are receiving this", "you're receiving this", "you received this",
        "manage preferences", "manage your preferences", "privacy policy", "terms of service", "sent from my", "all rights reserved",
        "©", "(c) 20", "this email was sent to", "do not reply to this", "update your preferences", "opt out", "opt-out",
    ]
    private static let connectors: Set<String> = ["to", "of", "the", "a", "an", "and", "or", "for", "in", "on", "at", "by", "with", "from", "until", "that", "your", "our", "is", "are", "be"]

    private static func endsSentence(_ s: String) -> Bool {
        guard let l = s.last else { return true }
        return ".!?:;)\"”’…".contains(l)
    }

    /// Re-joins text the HTML stripper split into fragments ("You now have 100" / "days left" / "to" / "2026 tax year.").
    private static func mergeFragments(_ paras: [String]) -> [String] {
        var out: [String] = []
        for p in paras {
            if let prev = out.last, !endsSentence(prev), let first = p.first, !prev.contains("\n"),
               first.isLowercase || first.isNumber || connectors.contains(String(prev.split(separator: " ").last ?? "").lowercased()) {
                out[out.count - 1] = prev + " " + p
            } else { out.append(p) }
        }
        return out
    }

    /// Turns raw text into readable paragraphs. Pure and quick, so it can run on every open.
    static func clean(_ raw: String) -> CleanedMail {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{00A0}", with: " ")
        let rawLines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let blanks = rawLines.filter(\.isEmpty).count

        // Group lines into blocks separated by blank lines; inside a block, soft-wrapped lines become one paragraph.
        var blocks: [[String]] = [[]]
        for l in rawLines { if l.isEmpty { if !blocks[blocks.count - 1].isEmpty { blocks.append([]) } } else { blocks[blocks.count - 1].append(l) } }
        var paras: [String] = []
        for b in blocks where !b.isEmpty {
            var cur = b[0], lines: [String] = []
            for l in b.dropFirst() {
                let listy = l.hasPrefix("•") || l.hasPrefix("- ") || l.hasPrefix("* ") || l.range(of: "^\\d+[.)] ", options: .regularExpression) != nil
                let signoff = cur.hasSuffix(",") && wordCount(cur) <= 3
                if listy || signoff || (endsSentence(cur) && !(l.first?.isLowercase ?? false)) { lines.append(cur); cur = l } else { cur += " " + l }
            }
            lines.append(cur)
            paras.append(lines.joined(separator: "\n"))
        }
        paras = mergeFragments(paras)

        // Fold everything from the first footer marker onward, but never the opening of the message.
        var split = paras.count
        for (i, p) in paras.enumerated() where i >= 1 {
            let l = p.lowercased()
            if footerMarkers.contains(where: { l.contains($0) }) || p == "--" || p.hasPrefix("-- \n") { split = i; break }
        }
        // A marker in the first half of a long text is more likely content than a footer.
        if split < paras.count, Double(split) < Double(paras.count) * 0.4, paras.count > 4 { split = paras.count }
        let body = Array(paras[..<split]), footer = Array(paras[split...])
        let removed = max(0, blanks - body.count - footer.count)
        return CleanedMail(paragraphs: body, footer: footer, blankLinesRemoved: removed, links: links(in: text))
    }

    /// The reply followed by the passages it refers to, quoted the way mail clients do.
    static func withQuotes(_ reply: String, quotes: [String], sender: String, date: Date) -> String {
        let q = quotes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !q.isEmpty else { return reply }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM yyyy 'at' HH:mm"; f.locale = Locale(identifier: "en_GB")
        let quoted = q.map { $0.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") }.joined(separator: "\n>\n")
        return reply.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\nOn \(f.string(from: date)), \(sender) wrote:\n" + quoted
    }
}
