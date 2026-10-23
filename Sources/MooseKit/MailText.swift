// SPDX-License-Identifier: Apache-2.0

import Foundation
import UniformTypeIdentifiers

/// Everything that turns raw mail into plain text and back. Pure, so it is unit tested.
public enum MailText {
    /// "Maya Chen <maya@acme.com>" → ("Maya Chen", "maya@acme.com")
    public static func parseAddress(_ raw: String) -> (name: String, email: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let email = String(s[s.index(after: lt)..<gt]).lowercased()
            let name = s[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return (name, email)
        }
        return ("", s.lowercased())
    }

    /// Bare, lowercased addresses from a header like `Maya <m@a.com>, "Chen, Li" <li@b.com>`. Commas inside quotes or <> don't split.
    public static func splitAddresses(_ raw: String) -> [String] {
        var parts: [String] = [], cur = "", quoted = false, angle = false
        for ch in raw {
            switch ch {
            case "\"": quoted.toggle(); cur.append(ch)
            case "<": angle = true; cur.append(ch)
            case ">": angle = false; cur.append(ch)
            case "," where !quoted && !angle, ";" where !quoted && !angle: parts.append(cur); cur = ""
            default: cur.append(ch)
            }
        }
        parts.append(cur)
        var seen = Set<String>()
        return parts.map { parseAddress($0).email }.filter { $0.contains("@") && !$0.contains(" ") && seen.insert($0).inserted }
    }

    /// Who to copy on a reply-all: everyone the message went to, except you and the person you are replying to.
    public static func replyAllCc(to: String, cc: String, replyingTo: String, me: String) -> [String] {
        let skip: Set<String> = [me.lowercased(), replyingTo.lowercased()]
        return splitAddresses(to + "," + cc).filter { !skip.contains($0) }
    }

    public static func stripHTML(_ html: String) -> String {
        var s = html
        for tag in ["style", "script", "head"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</tr>|</h[1-6]>|</li>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " ?\\n ?", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finds the best readable body in a Gmail `payload` tree: text/plain first, else stripped text/html.
    public static func body(from payload: [String: Any]) -> String {
        var plain: [String] = [], html: [String] = []
        func walk(_ p: [String: Any]) {
            let mime = (p["mimeType"] as? String) ?? ""
            if let body = p["body"] as? [String: Any], let data = body["data"] as? String, let d = Data(base64URL: data), let text = String(data: d, encoding: .utf8) {
                if mime == "text/plain" { plain.append(text) } else if mime == "text/html" { html.append(text) }
            }
            for child in (p["parts"] as? [[String: Any]]) ?? [] { walk(child) }
        }
        walk(payload)
        let text = plain.isEmpty ? html.map(stripHTML).joined(separator: "\n\n") : plain.joined(separator: "\n\n")
        return trimQuotedReply(text)
    }

    /// Drops the long "On Tue, X wrote:" tail so a thread reads as the new text only.
    public static func trimQuotedReply(_ text: String) -> String {
        var out: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix(">") { continue }
            if line.range(of: "^On .{5,80} wrote:$", options: .regularExpression) != nil { break }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func replySubject(_ subject: String) -> String {
        subject.lowercased().hasPrefix("re:") ? subject : "Re: " + subject
    }

    /// Builds an RFC 822 message, base64url encoded as Gmail wants. Header values are stripped of line breaks (no header injection).
    public static func rawMessage(from: String, to: String, subject: String, body: String, inReplyTo: String? = nil, references: String? = nil, attachments: [MailAttachment] = [], cc: String = "", bcc: String = "") -> String {
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }
        let crlfBody = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let boundary = "moose-" + UUID().uuidString
        var h = ["From: \(clean(from))", "To: \(clean(to))", "Subject: \(encodeHeader(clean(subject)))", "MIME-Version: 1.0"]
        if !cc.trimmingCharacters(in: .whitespaces).isEmpty { h.insert("Cc: \(clean(cc))", at: 2) }
        if !bcc.trimmingCharacters(in: .whitespaces).isEmpty { h.insert("Bcc: \(clean(bcc))", at: 2) }
        if let r = inReplyTo { h.append("In-Reply-To: \(clean(r))") }
        if let r = references ?? inReplyTo { h.append("References: \(clean(r))") }
        if attachments.isEmpty {
            h += ["Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: 8bit"]
            return Data((h.joined(separator: "\r\n") + "\r\n\r\n" + crlfBody).utf8).base64URL
        }
        h.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        var msg = h.joined(separator: "\r\n") + "\r\n\r\n--\(boundary)\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(crlfBody)\r\n"
        for a in attachments {
            let name = encodeHeader(clean(a.filename).replacingOccurrences(of: "\"", with: "'"))
            let type = clean(a.mimeType)
            msg += "--\(boundary)\r\nContent-Type: \(type); name=\"\(name)\"\r\nContent-Disposition: attachment; filename=\"\(name)\"\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            msg += a.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n"
        }
        msg += "--\(boundary)--\r\n"
        return Data(msg.utf8).base64URL
    }

    static func encodeHeader(_ s: String) -> String {
        s.unicodeScalars.allSatisfy({ $0.isASCII }) ? s : "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    public static func excerpt(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return flat.count <= n ? flat : String(flat.prefix(n - 1)) + "…"
    }
}

/// A file attached to an outgoing email.
public struct MailAttachment: Equatable, Sendable {
    public var filename: String
    public var mimeType: String
    public var data: Data
    public init(filename: String, mimeType: String, data: Data) { self.filename = filename; self.mimeType = mimeType; self.data = data }

    /// Gmail refuses messages over 25 MB; base64 adds a third, so stay well under.
    public static let maxTotalBytes = 18 * 1024 * 1024

    public static func load(_ url: URL) throws -> MailAttachment {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.preferredMIMEType ?? "application/octet-stream"
        return MailAttachment(filename: url.lastPathComponent, mimeType: type, data: try Data(contentsOf: url))
    }
}
