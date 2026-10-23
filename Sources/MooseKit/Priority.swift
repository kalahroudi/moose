// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the scorer knows about the user. Built from cached mail, never from the network.
public struct PriorityContext: Sendable {
    public var favourites: Set<String>
    public var repliedTo: Set<String>      // addresses the user has written to
    public var rules: [Rule]
    public var now: Date
    public init(favourites: Set<String> = [], repliedTo: Set<String> = [], rules: [Rule] = [], now: Date = Date()) {
        self.favourites = favourites; self.repliedTo = repliedTo; self.rules = rules; self.now = now
    }
}

/// On-device priority assessment: a transparent 0–100 score plus the reasons behind it.
/// An agent can add judgement on top through MCP; this part needs no network and no key.
public enum Priority {
    static let deadlineWords = ["asap", "urgent", "deadline", "due ", "by friday", "by monday", "by tomorrow", "tomorrow", "today", "tonight", "eod", "this week", "reminder"]
    static let moneyWords = ["payment", "invoice", "overdue", "past due", "failed", "declined", "refund", "charge", "bill ", "unpaid"]
    static let securityWords = ["security alert", "verification code", "sign-in", "new login", "password reset", "2-step", "one-time"]
    static let noReplyHints = ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications@", "notification@", "mailer-daemon", "newsletter", "digest", "updates@", "marketing@", "news@", "hello@"]

    public static func muteBucket(for m: MailMessage) -> MuteBucket? {
        if m.labels.contains("CATEGORY_PROMOTIONS") { return .promo }
        if m.labels.contains("CATEGORY_SOCIAL") || m.labels.contains("CATEGORY_FORUMS") { return .notification }
        let from = m.fromEmail
        if m.bulkHeader { return from.contains("noreply") || from.contains("notification") ? .notification : .newsletter }
        if m.labels.contains("CATEGORY_UPDATES") && noReplyHints.contains(where: from.contains) { return .notification }
        return nil
    }

    public static func score(_ m: MailMessage, _ ctx: PriorityContext) -> ScoredMessage {
        var s = 35, why: [String] = []
        let text = (m.subject + " " + m.snippet).lowercased()
        let favourite = ctx.favourites.contains(m.fromEmail)
        func add(_ n: Int, _ reason: String?) { s += n; if let r = reason { why.append(r) } }

        if favourite { add(40, "favourite") }
        if ctx.repliedTo.contains(m.fromEmail) { add(18, "you write to them") }
        let bucket = muteBucket(for: m)
        if let b = bucket { add(-38, b == .promo ? "promo" : b == .newsletter ? "newsletter" : "automated") }
        if m.subject.contains("?") || m.snippet.contains("?") { add(8, "asks a question") }
        if deadlineWords.contains(where: text.contains) { add(12, "deadline") }
        if moneyWords.contains(where: text.contains) { add(14, "money") }
        if securityWords.contains(where: text.contains) { add(10, "security") }
        if m.unread { add(6, nil) } else { add(-22, nil) }
        let age = ctx.now.timeIntervalSince(m.date)
        if age < 6 * 3600 { add(5, nil) } else if age > 7 * 86400 { add(-10, nil) }
        if m.subject.lowercased().hasPrefix("re:") { add(6, "in a reply thread") }

        var muted = bucket
        for rule in ctx.rules where rule.isActive(at: ctx.now) && rule.matches(m) {
            switch rule.action {
            case .favourite: add(40, "rule: \(rule.title)")
            case .boost(let n): add(n, "rule: \(rule.title)")
            case .mute, .block: muted = .rule; add(-50, "muted: \(rule.title)")
            case .file: break   // filing happens in Gmail (see MailModel); it does not change the score
            }
        }
        // A favourite is never auto-muted by headers; only an explicit rule can silence them.
        if favourite, muted != nil, muted != .rule { muted = nil }
        return ScoredMessage(message: m, score: max(0, min(100, s)), reasons: why, muted: muted)
    }

    public static func scoreAll(_ messages: [MailMessage], _ ctx: PriorityContext) -> [ScoredMessage] { messages.map { score($0, ctx) } }
}
