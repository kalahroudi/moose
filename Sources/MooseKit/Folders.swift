// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Folders are Gmail labels that a filing rule moves mail into. This is the pure part: names, order and the stacks inside a folder.
public enum Folders {
    /// The sidebar shows this many folders; the rest are wrapped under "N more".
    public static let visibleCount = 5

    /// Folders are matched without regard to case, like Gmail labels.
    public static func key(_ name: String) -> String { name.lowercased() }

    /// Every folder a filing rule points at, in the user's order, then the rest in the order their rules were made.
    public static func names(rules: [Rule], order: [String]) -> [String] {
        var byKey: [String: String] = [:]
        var firstSeen: [String] = []
        for case let f? in rules.map(\.folder) where byKey[key(f)] == nil { byKey[key(f)] = f; firstSeen.append(key(f)) }
        var out: [String] = []
        var used = Set<String>()
        for name in order where byKey[key(name)] != nil && used.insert(key(name)).inserted { out.append(byKey[key(name)]!) }
        for k in firstSeen where used.insert(k).inserted { out.append(byKey[k]!) }
        return out
    }

    /// The order after moving `name` to sit before `target` (or last when `target` is nil).
    public static func moved(_ name: String, before target: String?, in names: [String]) -> [String] {
        var list = names.filter { key($0) != key(name) }
        guard names.contains(where: { key($0) == key(name) }) else { return names }
        let at = target.flatMap { t in list.firstIndex { key($0) == key(t) } } ?? list.count
        list.insert(names.first { key($0) == key(name) } ?? name, at: at)
        return list
    }

    /// The order after moving `name` up (negative) or down (positive) by `offset` places.
    public static func shifted(_ name: String, by offset: Int, in names: [String]) -> [String] {
        guard let i = names.firstIndex(where: { key($0) == key(name) }) else { return names }
        var list = names
        let item = list.remove(at: i)
        list.insert(item, at: max(0, min(list.count, i + offset)))
        return list
    }

    /// One stack per sender, newest sender first; inside a stack the newest message first.
    public static func stacks(_ messages: [MailMessage], favourites: Set<String>) -> [MailStack] {
        var groups: [String: [MailMessage]] = [:]
        for m in messages { groups[m.fromEmail, default: []].append(m) }
        return groups.map { key, msgs in
            let sorted = msgs.sorted { $0.date > $1.date }.map { ScoredMessage(message: $0, score: 0, reasons: [], muted: nil) }
            return MailStack(key: key, name: sorted.first?.message.displayName ?? key, messages: sorted, favourite: favourites.contains(key))
        }.sorted { $0.latest > $1.latest }
    }

    /// The Stack window's deck for a folder: every message, senders with unread mail first, unread first inside a sender.
    public static func deck(_ messages: [MailMessage], favourites: Set<String>) -> [DeckItem] {
        stacks(messages, favourites: favourites)
            .map { s -> (MailStack, [ScoredMessage]) in
                (s, s.messages.sorted { ($0.message.unread ? 1 : 0, $0.message.date) > ($1.message.unread ? 1 : 0, $1.message.date) })
            }
            .sorted { a, b in
                let ua = a.0.unreadCount > 0, ub = b.0.unreadCount > 0
                return ua != ub ? ua : a.0.latest > b.0.latest
            }
            .map { DeckItem(key: $0.0.key, name: $0.0.name, ids: $0.1.map(\.id)) }
    }
}
