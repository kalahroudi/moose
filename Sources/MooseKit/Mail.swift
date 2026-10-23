// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A connected Gmail address. Tokens live in the Keychain, never here.
public struct MailAccount: Codable, Identifiable, Hashable, Sendable {
    public var email: String
    public var colorIndex: Int
    public var id: String { email }
    public init(email: String, colorIndex: Int) { self.email = email; self.colorIndex = colorIndex }
}

/// One message, text only. HTML is stripped before it is stored and images are never fetched.
public struct MailMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: String              // Gmail message id
    public var threadId: String
    public var account: String         // MailAccount.email
    public var fromName: String
    public var fromEmail: String
    public var subject: String
    public var snippet: String
    public var date: Date
    public var unread: Bool
    public var labels: [String]
    public var bulkHeader: Bool        // List-Unsubscribe or Precedence: bulk
    public var messageIDHeader: String?
    public var referencesHeader: String?
    public init(id: String, threadId: String, account: String, fromName: String, fromEmail: String, subject: String, snippet: String,
                date: Date, unread: Bool, labels: [String] = [], bulkHeader: Bool = false, messageIDHeader: String? = nil, referencesHeader: String? = nil) {
        self.id = id; self.threadId = threadId; self.account = account; self.fromName = fromName; self.fromEmail = fromEmail.lowercased()
        self.subject = subject; self.snippet = snippet; self.date = date; self.unread = unread; self.labels = labels
        self.bulkHeader = bulkHeader; self.messageIDHeader = messageIDHeader; self.referencesHeader = referencesHeader
    }
    public var displayName: String { fromName.isEmpty ? fromEmail : fromName }
}

public enum MuteBucket: String, Codable, Sendable, CaseIterable {
    case newsletter, notification, promo, rule, snoozed
    public var label: String {
        switch self { case .newsletter: "newsletters"; case .notification: "notifications"; case .promo: "promos"; case .rule: "by your rules"; case .snoozed: "snoozed" }
    }
}

public struct ScoredMessage: Identifiable, Hashable, Sendable {
    public var message: MailMessage
    public var score: Int
    public var reasons: [String]
    public var muted: MuteBucket?
    public var id: String { message.id }
}

/// Messages from one sender (across accounts), ranked together.
public struct MailStack: Identifiable, Hashable, Sendable {
    public var key: String                    // sender address
    public var name: String
    public var messages: [ScoredMessage]      // highest score first
    public var favourite: Bool
    public init(key: String, name: String, messages: [ScoredMessage], favourite: Bool) { self.key = key; self.name = name; self.messages = messages; self.favourite = favourite }
    public var score: Int { messages.first?.score ?? 0 }
    public var unreadCount: Int { messages.filter(\.message.unread).count }
    public var accounts: [String] { Array(Set(messages.map(\.message.account))).sorted() }
    public var latest: Date { messages.map(\.message.date).max() ?? .distantPast }
    /// One short line explaining the rank, e.g. "favourite · asked a question".
    public var why: String {
        var seen = Set<String>(); var out: [String] = []
        for r in messages.prefix(3).flatMap(\.reasons) where seen.insert(r).inserted { out.append(r) }
        return out.prefix(3).joined(separator: " · ")
    }
    public var id: String { key }
}

public enum MailView: String, CaseIterable, Sendable { case priority, favourites, everythingElse, muted }

public enum Stacker {
    public static let priorityThreshold = 60

    /// Builds stacks for a view. Pure and fast: runs on the cached messages, never on the network.
    public static func stacks(for view: MailView, messages: [ScoredMessage], favourites: Set<String>, unreadOnly: Bool = false) -> [MailStack] {
        var groups: [String: [ScoredMessage]] = [:]
        for m in messages {
            if unreadOnly && !m.message.unread { continue }
            groups[m.message.fromEmail, default: []].append(m)
        }
        var out: [MailStack] = []
        for (key, msgs) in groups {
            let sorted = msgs.sorted { ($0.score, $0.message.date) > ($1.score, $1.message.date) }
            let fav = favourites.contains(key)
            let stack = MailStack(key: key, name: sorted.first?.message.displayName ?? key, messages: sorted, favourite: fav)
            let allMuted = sorted.allSatisfy { $0.muted != nil }
            switch view {
            case .muted: if sorted.contains(where: { $0.muted != nil }) { out.append(MailStack(key: key, name: stack.name, messages: sorted.filter { $0.muted != nil }, favourite: fav)) }
            case .favourites: if fav { out.append(stack) }
            case .priority:
                let live = sorted.filter { $0.muted == nil }
                if !allMuted, (live.first?.score ?? 0) >= priorityThreshold { out.append(MailStack(key: key, name: stack.name, messages: live, favourite: fav)) }
            case .everythingElse:
                let live = sorted.filter { $0.muted == nil }
                if !allMuted, (live.first?.score ?? 0) < priorityThreshold { out.append(MailStack(key: key, name: stack.name, messages: live, favourite: fav)) }
            }
        }
        // Favourites float within their score band; ties break on recency.
        return out.sorted { ($0.score + ($0.favourite ? 3 : 0), $0.latest) > ($1.score + ($1.favourite ? 3 : 0), $1.latest) }
    }
}

// MARK: Sorting and filtering

public enum StackSort: String, CaseIterable, Sendable {
    case priority, newest, oldest, sender, size
    public var label: String {
        switch self { case .priority: "Priority"; case .newest: "Newest first"; case .oldest: "Oldest first"; case .sender: "Sender A–Z"; case .size: "Most messages" }
    }
}

public enum DateRange: String, CaseIterable, Sendable {
    case any, today, week, month, custom
    public var label: String {
        switch self { case .any: "Any time"; case .today: "Today"; case .week: "Past week"; case .month: "Past month"; case .custom: "Custom range…" }
    }
    public func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .any, .custom: nil
        case .today: calendar.startOfDay(for: now)
        case .week: now.addingTimeInterval(-7 * 86400)
        case .month: now.addingTimeInterval(-30 * 86400)
        }
    }
}

/// Who the mail is from: real people, or lists and notifications (anything with a bulk header).
public enum Origin: String, CaseIterable, Sendable {
    case all, people, automated
    public var label: String { switch self { case .all: "Everyone"; case .people: "People"; case .automated: "Newsletters & notifications" } }
}

public struct StackQuery: Equatable, Sendable {
    public var sort: StackSort = .priority
    public var range: DateRange = .any
    /// Used when `range` is `.custom`; either end may be open. `to` is inclusive of the whole day.
    public var from: Date?
    public var to: Date?
    public var origin: Origin = .all
    public var text = ""
    public var account: String?
    public init() {}
    /// True when anything narrows the list (sort does not).
    public var filtering: Bool { range != .any || origin != .all || !text.isEmpty || account != nil }
}

public extension Stacker {
    /// Narrows and orders already-built stacks. A stack whose name or address matches the text keeps all its messages;
    /// otherwise only the messages that match survive. Stacks left empty are dropped.
    static func refine(_ stacks: [MailStack], _ q: StackQuery, now: Date = Date()) -> [MailStack] {
        let needle = q.text.lowercased()
        var cutoff = q.range.cutoff(now: now)
        var ceiling: Date?
        if q.range == .custom {
            let cal = Calendar.current
            cutoff = q.from.map { cal.startOfDay(for: $0) }
            ceiling = q.to.flatMap { cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: $0)) }
        }
        var out: [MailStack] = []
        for s in stacks {
            let senderHit = !needle.isEmpty && (s.name.lowercased().contains(needle) || s.key.contains(needle))
            let kept = s.messages.filter { sm in
                let m = sm.message
                if let a = q.account, m.account != a { return false }
                if let c = cutoff, m.date < c { return false }
                if let c = ceiling, m.date >= c { return false }
                switch q.origin { case .all: break; case .people: if m.bulkHeader { return false }; case .automated: if !m.bulkHeader { return false } }
                return needle.isEmpty || senderHit || m.subject.lowercased().contains(needle) || m.snippet.lowercased().contains(needle)
            }
            if kept.isEmpty { continue }
            let ordered: [ScoredMessage]
            switch q.sort {
            case .newest: ordered = kept.sorted { $0.message.date > $1.message.date }
            case .oldest: ordered = kept.sorted { $0.message.date < $1.message.date }
            default: ordered = kept
            }
            out.append(MailStack(key: s.key, name: s.name, messages: ordered, favourite: s.favourite))
        }
        switch q.sort {
        case .priority: return out
        case .newest: return out.sorted { $0.latest > $1.latest }
        case .oldest: return out.sorted { ($0.messages.map(\.message.date).min() ?? .distantFuture) < ($1.messages.map(\.message.date).min() ?? .distantFuture) }
        case .sender: return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size: return out.sorted { ($0.messages.count, $0.latest) > ($1.messages.count, $1.latest) }
        }
    }

    /// Every message of the stacks as one list, for the flat "Messages" layout.
    static func flatten(_ stacks: [MailStack], sort: StackSort) -> [ScoredMessage] {
        let all = stacks.flatMap(\.messages)
        switch sort {
        case .priority: return all.sorted { ($0.score, $0.message.date) > ($1.score, $1.message.date) }
        case .newest, .size: return all.sorted { $0.message.date > $1.message.date }
        case .oldest: return all.sorted { $0.message.date < $1.message.date }
        case .sender:
            return all.sorted {
                let a = $0.message.displayName.lowercased(), b = $1.message.displayName.lowercased()
                return a == b ? $0.message.date > $1.message.date : a < b
            }
        }
    }
}
