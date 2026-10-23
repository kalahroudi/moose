// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum RuleAction: Codable, Hashable, Sendable {
    case favourite
    case boost(Int)
    case mute
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

    public init(id: UUID = UUID(), senders: [String] = [], keywords: [String] = [], account: String? = nil, action: RuleAction,
                enabled: Bool = true, source: String = "you", hits: Int = 0) {
        self.id = id; self.senders = senders.map { $0.lowercased() }; self.keywords = keywords.map { $0.lowercased() }
        self.account = account; self.action = action; self.enabled = enabled; self.source = source; self.hits = hits
    }

    public func matches(_ m: MailMessage) -> Bool {
        if let a = account, a != m.account { return false }
        if senders.isEmpty && keywords.isEmpty { return false }
        let from = (m.fromEmail + " " + m.fromName).lowercased()
        let text = (m.subject + " " + m.snippet + " " + from).lowercased()   // plain words also match the sender's name
        let senderOK = senders.isEmpty || senders.contains { from.contains($0) }
        let wordOK = keywords.isEmpty || keywords.contains { text.contains($0) }
        return senderOK && wordOK
    }

    public var title: String {
        var parts: [String] = []
        if !senders.isEmpty { parts.append("from " + senders.joined(separator: ", ")) }
        if !keywords.isEmpty { parts.append("about " + keywords.joined(separator: ", ")) }
        if let a = account { parts.append("in " + a) }
        return parts.joined(separator: " ")
    }

    public var actionText: String {
        switch action { case .favourite: "always Priority"; case .boost(let n): "boost \(n >= 0 ? "+" : "")\(n)"; case .mute: "mute" }
    }
}

/// Turns one plain sentence into a rule. Deliberately small: "mute X", "favourite X", "boost X by 20".
/// Anything fancier is for an agent, which can create structured rules through MCP.
public enum RuleParser {
    public static func parse(_ text: String) -> Rule? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        func split(_ s: String) -> [String] {
            s.replacingOccurrences(of: " or ", with: ",").replacingOccurrences(of: " and ", with: ",")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”")) }.filter { !$0.isEmpty }
        }
        func target(_ rest: String) -> (senders: [String], keywords: [String]) {
            var r = rest
            for p in ["from ", "mail from ", "emails from "] where r.hasPrefix(p) { r.removeFirst(p.count) }
            if let range = r.range(of: "about ") ?? r.range(of: "containing ") {
                let kws = split(String(r[range.upperBound...]))
                let before = String(r[..<range.lowerBound]).replacingOccurrences(of: "from ", with: "")
                return (split(before), kws)
            }
            let items = split(r)
            // An address or domain is a sender; a plain word matches the sender name or the subject, so it is a keyword.
            return (items.filter { $0.contains("@") || $0.contains(".") }, items.filter { !($0.contains("@") || $0.contains(".")) })
        }
        for p in ["mute ", "silence ", "hide "] where lower.hasPrefix(p) {
            let tg = target(String(lower.dropFirst(p.count)))
            return tg.senders.isEmpty && tg.keywords.isEmpty ? nil : Rule(senders: tg.senders, keywords: tg.keywords, action: .mute)
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
}
