// SPDX-License-Identifier: Apache-2.0

import Foundation

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
    public static func rawMessage(from: String, to: String, subject: String, body: String, inReplyTo: String? = nil, references: String? = nil) -> String {
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }
        var h = ["From: \(clean(from))", "To: \(clean(to))", "Subject: \(encodeHeader(clean(subject)))", "MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: 8bit"]
        if let r = inReplyTo { h.append("In-Reply-To: \(clean(r))") }
        if let r = references ?? inReplyTo { h.append("References: \(clean(r))") }
        let msg = h.joined(separator: "\r\n") + "\r\n\r\n" + body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
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
