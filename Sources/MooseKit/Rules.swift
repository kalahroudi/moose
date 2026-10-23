// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum RuleAction: Codable, Hashable, Sendable {
    case favourite
    case boost(Int)
    case mute
    case file(String)      // move to a Gmail label (shown as a folder) and out of the inbox
}

/// A routing or muting rule. Matches on sender fragments and/or subject/body keywords, optionally one account.
public struct Rule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var senders: [String]       // substrings of the sender address or name
    public var keywords: [String]      // substrings of subject + snippet
    public var account: String?
    public var action: RuleAction
    public var enabled: Bool
    public var source: String          // "you", "learned" or the agent's name
    public var hits: Int
    public var until: Date?            // a temporary mute: the rule switches itself off after this

    public init(id: UUID = UUID(), senders: [String] = [], keywords: [String] = [], account: String? = nil, action: RuleAction,
                enabled: Bool = true, source: String = "you", hits: Int = 0, until: Date? = nil) {
        self.id = id; self.senders = senders.map { $0.lowercased() }; self.keywords = keywords.map { $0.lowercased() }
        self.account = account; self.action = action; self.enabled = enabled; self.source = source; self.hits = hits; self.until = until
    }

    /// Enabled, and not past its end date.
    public func isActive(at now: Date = Date()) -> Bool { enabled && (until.map { $0 > now } ?? true) }

    public func matches(_ m: MailMessage) -> Bool {
        if let a = account, a != m.account { return false }
        if senders.isEmpty && keywords.isEmpty { return false }
        let from = (m.fromEmail + " " + m.fromName).lowercased()
        let text = (m.subject + " " + m.snippet + " " + from).lowercased()   // plain words also match the sender's name
        let senderOK = senders.isEmpty || senders.contains { from.contains($0) }
        let wordOK = keywords.isEmpty || keywords.contains { k in k.split(separator: " ").allSatisfy { text.contains($0) } }   // a phrase matches when all its words appear, in any order
        return senderOK && wordOK
    }

    public var title: String {
        var parts: [String] = []
        if !senders.isEmpty { parts.append("from " + senders.joined(separator: ", ")) }
        if !keywords.isEmpty { parts.append("about " + keywords.joined(separator: ", ")) }
        if let a = account { parts.append("in " + a) }
        if parts.isEmpty { return "(no conditions)" }
        return parts.joined(separator: " ")
    }

    public var actionText: String {
        switch action { case .favourite: "always Priority"; case .boost(let n): "boost \(n >= 0 ? "+" : "")\(n)"; case .mute: until.map { "mute until " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "mute"; case .file(let f): "file in “\(f)”" }
    }

    public var folder: String? { if case .file(let f) = action { f } else { nil } }
}

/// Turns one plain sentence into a rule. Deliberately small: "mute X", "favourite X", "boost X by 20",
/// "move X to Folder". Anything fancier is for an agent, which can create structured rules through MCP.
public enum RuleParser {
    static let fillers: Set<String> = ["all", "every", "any", "the", "my", "emails", "email", "mail", "mails", "messages", "message", "from"]
    static let folderVerbs = ["group ", "move ", "file ", "put ", "route ", "send ", "sort ", "organise ", "organize ", "label ", "store ", "keep "]
    static let quotes = CharacterSet(charactersIn: "\"“”'‘’")

    static func split(_ s: String) -> [String] {
        s.replacingOccurrences(of: " or ", with: ",").replacingOccurrences(of: " and ", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quotes) }.filter { !$0.isEmpty }
    }

    /// Who or what a rule is about. "all emails from stripe.com" and "from news@club.com about sale" both work.
    static func target(_ rest: String) -> (senders: [String], keywords: [String]) {
        var words = rest.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let w = words.first, fillers.contains(w.lowercased()), words.count > 1 { words.removeFirst() }
        let r = words.joined(separator: " ")
        if let range = r.range(of: "about ") ?? r.range(of: "containing ") {
            let kws = split(String(r[range.upperBound...]))
            let before = String(r[..<range.lowerBound]).replacingOccurrences(of: "from ", with: "")
            return (split(before), kws)
        }
        let items = split(r)
        // An address or domain is a sender; a plain word matches the sender name or the subject, so it is a keyword.
        return (items.filter { $0.contains("@") || $0.contains(".") }, items.filter { !($0.contains("@") || $0.contains(".")) })
    }

    /// "for 3 days", "for a week", "for 2 hours" at the end of a sentence. Returns the text without it, and the end date.
    static func duration(_ text: String, now: Date) -> (rest: String, until: Date?) {
        let units: [(String, TimeInterval)] = [("hour", 3600), ("day", 86400), ("week", 7 * 86400), ("month", 30 * 86400)]
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 3 else { return (text, nil) }
        let unitWord = words[words.count - 1].lowercased(), amountWord = words[words.count - 2].lowercased(), forWord = words[words.count - 3].lowercased()
        guard forWord == "for", let unit = units.first(where: { unitWord == $0.0 || unitWord == $0.0 + "s" }) else { return (text, nil) }
        guard let n = Int(amountWord) ?? (["a": 1, "an": 1, "one": 1, "two": 2, "three": 3][amountWord]) else { return (text, nil) }
        return (words.dropLast(3).joined(separator: " "), now.addingTimeInterval(Double(n) * unit.1))
    }

    public static func parse(_ text: String, now: Date = Date()) -> Rule? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if let r = parseFolder(t) { return r }
        for p in ["mute ", "silence ", "hide ", "ignore ", "snooze ", "stop "] where lower.hasPrefix(p) {
            var rest = String(lower.dropFirst(p.count))
            if p == "stop " { guard rest.hasPrefix("emails ") || rest.hasPrefix("mail ") else { return nil } }
            var (body, until) = duration(rest, now: now)
            if until == nil, p == "snooze " { until = now.addingTimeInterval(7 * 86400) }
            rest = body
            let tg = target(rest)
            return tg.senders.isEmpty && tg.keywords.isEmpty ? nil : Rule(senders: tg.senders, keywords: tg.keywords, action: .mute, until: until)
        }
        for p in ["favourite ", "favorite ", "always priority from ", "prioritise ", "prioritize ", "star "] where lower.hasPrefix(p) {
            let tg = target(String(lower.dropFirst(p.count)))
            return tg.senders.isEmpty && tg.keywords.isEmpty ? nil : Rule(senders: tg.senders, keywords: tg.keywords, action: .favourite)
        }
        if lower.hasPrefix("boost ") {
            var rest = String(lower.dropFirst(6)); var n = 20
            if let r = rest.range(of: " by ") ?? rest.range(of: " +"), let v = Int(rest[r.upperBound...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "+"))) {
                n = v; rest = String(rest[..<r.lowerBound])
            }
            let tg = target(rest)
            return tg.senders.isEmpty && tg.keywords.isEmpty ? nil : Rule(senders: tg.senders, keywords: tg.keywords, action: .boost(n))
        }
        return nil
    }

    /// "group all emails from stripe.com into one folder called Receipts", "move invoices to Billing",
    /// "file mail from stripe.com in folder Receipts". The folder name keeps the case the user typed.
    static func parseFolder(_ t: String) -> Rule? {
        let lower = t.lowercased()
        guard let verb = folderVerbs.first(where: { lower.hasPrefix($0) }) else { return nil }
        let body = String(t.dropFirst(verb.count))
        // The last " into " / " to " (or " in folder ") splits what from where, so "…about trips to Spain into Travel" still works.
        let split = [" into ", " in folder ", " in label "].compactMap { body.range(of: $0, options: [.caseInsensitive, .backwards]) }.max { $0.lowerBound < $1.lowerBound }
            ?? body.range(of: " to ", options: [.caseInsensitive, .backwards])
        guard let split else { return nil }
        let what = String(body[..<split.lowerBound])
        // Drop "one folder called", "a label named", "the folder" ahead of the name, but keep a name like "The Hub".
        var words = String(body[split.upperBound...]).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let markers: Set<String> = ["folder", "label", "group", "called", "named"]
        if let last = words.prefix(4).lastIndex(where: { markers.contains($0.lowercased()) }), words.prefix(last + 1).allSatisfy({ markers.contains($0.lowercased()) || ["one", "a", "an", "the", "my", "new", "single"].contains($0.lowercased()) }) {
            words.removeFirst(last + 1)
        }
        var name = words.joined(separator: " ").trimmingCharacters(in: quotes).trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        let tg = target(what.lowercased())
        guard !tg.senders.isEmpty || !tg.keywords.isEmpty else { return nil }
        if name.isEmpty {
            // "move emails from cassiobury school to a folder": name it after what they have in common.
            name = (tg.keywords.first ?? tg.senders.first ?? "").split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        guard !name.isEmpty, name.count <= 100 else { return nil }
        return Rule(senders: tg.senders, keywords: tg.keywords, action: .file(name))
    }
}
