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
    case newsletter, notification, promo, rule
    public var label: String {
        switch self { case .newsletter: "newsletters"; case .notification: "notifications"; case .promo: "promos"; case .rule: "by your rules" }
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
