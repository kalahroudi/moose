// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A mass or single action in the Stack window. Every one has an exact inverse, which is what makes "Undo" instead of "Are you sure?" safe.
public enum StackAction: String, Codable, Sendable {
    case archive, markRead, trash, file

    public func verb(past: Bool = true) -> String {
        switch self { case .archive: "Archived"; case .markRead: "Marked read"; case .trash: "Deleted"; case .file: "Filed" }
    }

    /// "Archived 2 from Stripe", "Deleted 7", "Marked read 1".
    public func summary(count: Int, sender: String?) -> String {
        var s = "\(verb()) \(count)"
        if self == .markRead { s = count == 1 ? "Marked 1 read" : "Marked \(count) read" }
        if let sender, !sender.isEmpty { s += " from \(sender)" }
        return s
    }
}

/// One card in the deck: a sender and the messages (best first) that were unread and important when the deck was built.
public struct DeckItem: Identifiable, Hashable, Sendable {
    public var key: String
    public var name: String
    public var ids: [String]
    public var id: String { key }

    /// The message to show: the first one that still exists and has not been handled in this session.
    public func current(present: Set<String>, handled: Set<String>) -> String? {
        ids.first { present.contains($0) && !handled.contains($0) }
    }
    public func remaining(present: Set<String>, handled: Set<String>) -> [String] {
        ids.filter { present.contains($0) && !handled.contains($0) }
    }
}

public enum Deck {
    /// The Stack window's deck: the unread Priority stacks, best first. The order is frozen when built so cards
    /// do not jump around while you work through them.
    public static func build(_ messages: [ScoredMessage], favourites: Set<String>) -> [DeckItem] {
        Stacker.stacks(for: .priority, messages: messages, favourites: favourites, unreadOnly: true)
            .map { DeckItem(key: $0.key, name: $0.name, ids: $0.messages.map(\.id)) }
    }

    /// Splits ids by account, because Gmail calls are per account.
    public static func group(_ messages: [MailMessage]) -> [String: [MailMessage]] { Dictionary(grouping: messages, by: \.account) }
}
