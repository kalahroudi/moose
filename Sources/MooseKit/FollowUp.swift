// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum FollowUpKind: String, Codable, Sendable {
    /// Hide the message now, bring it back (unread, high priority) at the due time.
    case snooze
    /// Remind me at the due time if nobody has answered the thread by then.
    case awaitingReply
}

/// A reminder about one message. Holds a copy of the message so it can still be opened after it has left the inbox.
public struct FollowUp: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: FollowUpKind
    public var message: MailMessage
    public var created: Date
    public var due: Date
    /// True once the reminder was shown to the user, so a notification is never repeated.
    public var notified: Bool

    public init(id: UUID = UUID(), kind: FollowUpKind, message: MailMessage, created: Date = Date(), due: Date, notified: Bool = false) {
        self.id = id; self.kind = kind; self.message = message; self.created = created; self.due = due; self.notified = notified
    }

    public func isDue(_ now: Date = Date()) -> Bool { due <= now }
}

/// A named moment offered in menus: "Tomorrow morning", "Next week".
public struct FollowUpPreset: Identifiable, Hashable, Sendable {
    public var label: String
    public var date: Date
    public var id: String { label }
}

/// Pure logic for follow-ups: no clock, network or disk, so every rule here is unit tested.
public enum FollowUps {
    /// Reminders for this message or thread are replaced, never stacked.
    public static func add(_ f: FollowUp, to list: inout [FollowUp]) {
        list.removeAll { $0.kind == f.kind && (f.kind == .snooze ? $0.message.id == f.message.id : $0.message.threadId == f.message.threadId && $0.message.account == f.message.account) }
        list.append(f)
        list.sort { $0.due < $1.due }
    }

    /// Message ids that are hidden right now, with when they come back.
    public static func snoozed(_ list: [FollowUp], now: Date = Date()) -> [String: Date] {
        Dictionary(list.filter { $0.kind == .snooze && !$0.isDue(now) }.map { ($0.message.id, $0.due) }, uniquingKeysWith: max)
    }

    /// Message ids whose snooze has run out and that the user has not dealt with yet.
    public static func resurfaced(_ list: [FollowUp], now: Date = Date()) -> Set<String> {
        Set(list.filter { $0.kind == .snooze && $0.isDue(now) }.map(\.message.id))
    }

    public static func due(_ list: [FollowUp], now: Date = Date()) -> [FollowUp] { list.filter { $0.isDue(now) }.sorted { $0.due < $1.due } }
    public static func waiting(_ list: [FollowUp], now: Date = Date()) -> [FollowUp] { list.filter { !$0.isDue(now) }.sorted { $0.due < $1.due } }

    /// The next moment a reminder needs announcing. May be in the past (then announce now).
    public static func nextWake(_ list: [FollowUp]) -> Date? { list.filter { !$0.notified }.map(\.due).min() }

    /// Reminders that came due and have not been announced yet.
    public static func toAnnounce(_ list: [FollowUp], now: Date = Date()) -> [FollowUp] { list.filter { $0.isDue(now) && !$0.notified } }

    // MARK: When

    /// "Later today", "Tomorrow morning", "This weekend", "Next week". Evenings skip "later today" because it would be minutes away.
    public static func presets(now: Date = Date(), calendar: Calendar = .current) -> [FollowUpPreset] {
        func at(_ hour: Int, daysAhead: Int = 0, from base: Date) -> Date {
            let day = calendar.date(byAdding: .day, value: daysAhead, to: base) ?? base
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        var out: [FollowUpPreset] = []
        let evening = at(18, from: now)
        if calendar.component(.hour, from: now) < 15 { out.append(.init(label: "Later today", date: evening)) }
        out.append(.init(label: "Tomorrow morning", date: at(9, daysAhead: 1, from: now)))
        let weekday = calendar.component(.weekday, from: now)               // 1 = Sunday … 7 = Saturday
        let toSaturday = (7 - weekday + 7) % 7
        if weekday != 7 && weekday != 1 && toSaturday > 1 { out.append(.init(label: "This weekend", date: at(9, daysAhead: toSaturday, from: now))) }
        let toMonday = ((2 - weekday + 7) % 7) == 0 ? 7 : (2 - weekday + 7) % 7
        out.append(.init(label: "Next week", date: at(9, daysAhead: toMonday, from: now)))
        return out
    }

    /// How long to wait for a reply, offered in menus.
    public static let replyDays = [1, 2, 3, 5, 7, 14]

    /// The due time for "if no reply in N days": 9:00 on that day, so the reminder is there when the day starts.
    public static func dueAfter(days: Int, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let day = calendar.date(byAdding: .day, value: max(1, days), to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    /// An absolute ISO 8601 time, or an offset in days and hours from now (agents pass either). Nil when nothing usable was given
    /// or the time is not in the future.
    public static func when(until: String?, days: Int?, hours: Int?, now: Date = Date()) -> Date? {
        var date: Date?
        if let until, !until.isEmpty {
            let f = ISO8601DateFormatter()
            date = f.date(from: until)
            if date == nil { f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; date = f.date(from: until) }
            if date == nil { f.formatOptions = [.withFullDate]; date = f.date(from: until).flatMap { Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: $0) } }
        } else if days != nil || hours != nil {
            date = now.addingTimeInterval(Double(days ?? 0) * 86400 + Double(hours ?? 0) * 3600)
        }
        guard let d = date, d > now else { return nil }
        return d
    }

    /// "Today 18:00", "Tomorrow 09:00", "Fri 09:00", "12 Nov".
    public static func describe(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = d.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(d, inSameDayAs: now) { return "today \(time)" }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: t) { return "tomorrow \(time)" }
        if d > now, d < now.addingTimeInterval(6 * 86400) { return d.formatted(.dateTime.weekday(.abbreviated)) + " \(time)" }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: Replies

    /// Whether anyone other than the user wrote in a Gmail thread after `since`. Takes the thread as Gmail returns it
    /// (format=metadata with the From header), so it can be tested without the network.
    public static func hasReply(in thread: [String: Any], account: String, since: Date) -> Bool {
        let me = account.lowercased()
        for m in (thread["messages"] as? [[String: Any]]) ?? [] {
            let labels = (m["labelIds"] as? [String]) ?? []
            guard !labels.contains("SENT"), !labels.contains("DRAFT") else { continue }
            guard let ms = Double(m["internalDate"] as? String ?? ""), Date(timeIntervalSince1970: ms / 1000) > since else { continue }
            let headers = ((m["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
            let from = headers.first { ($0["name"] as? String)?.lowercased() == "from" }?["value"] as? String ?? ""
            if MailText.parseAddress(from).email != me { return true }
        }
        return false
    }
}
