// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How a sender lets you opt out of their mail, read from the List-Unsubscribe headers (RFC 2369 / RFC 8058).
public struct UnsubscribeOption: Equatable, Sendable {
    public enum Method: Equatable, Sendable {
        case oneClick(URL)                                   // HTTPS POST, no page and no browser
        case email(to: String, subject: String, body: String) // an email from the user's own account
        case browser(URL)                                    // a page the user has to finish themselves
    }
    public var https: URL?
    public var mailto: (to: String, subject: String, body: String)?
    public var oneClick: Bool

    public init(https: URL? = nil, mailto: (to: String, subject: String, body: String)? = nil, oneClick: Bool) { self.https = https; self.mailto = mailto; self.oneClick = oneClick }

    public static func == (a: Self, b: Self) -> Bool {
        a.https == b.https && a.oneClick == b.oneClick && a.mailto?.to == b.mailto?.to && a.mailto?.subject == b.mailto?.subject && a.mailto?.body == b.mailto?.body
    }

    /// The best way to unsubscribe, in order: one-click POST, then an email, then the sender's page.
    public var method: Method? {
        if oneClick, let u = https { return .oneClick(u) }
        if let m = mailto { return .email(to: m.to, subject: m.subject, body: m.body) }
        if let u = https { return .browser(u) }
        return nil
    }

    /// One short line for the confirmation dialog and for agents.
    public var summary: String {
        switch method {
        case .oneClick(let u)?: "one click, sent to \(MailText.linkLabel(u.absoluteString))"
        case .email(let to, _, _)?: "an unsubscribe email to \(to)"
        case .browser(let u)?: "the sender's page at \(MailText.linkLabel(u.absoluteString))"
        case nil: "not available"
        }
    }

    /// Parses `List-Unsubscribe` (e.g. `<mailto:u@x.com?subject=unsub>, <https://x.com/u?id=1>`) and `List-Unsubscribe-Post`.
    public static func parse(listUnsubscribe: String?, post: String? = nil) -> UnsubscribeOption? {
        guard let header = listUnsubscribe, !header.isEmpty else { return nil }
        var https: URL?, mailto: (String, String, String)?
        var rest = header[...]
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let entry = String(rest[rest.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: close)...]
            let lower = entry.lowercased()
            if lower.hasPrefix("https://"), https == nil, let u = URL(string: entry), safeHost(u) { https = u }
            else if lower.hasPrefix("mailto:"), mailto == nil, let m = parseMailto(entry) { mailto = m }
        }
        guard https != nil || mailto != nil else { return nil }
        let oneClick = https != nil && (post ?? "").lowercased().contains("list-unsubscribe=one-click")
        return UnsubscribeOption(https: https, mailto: mailto, oneClick: oneClick)
    }

    /// A fallback when a message has no header: an unsubscribe link in the body. Always a page for the user to finish.
    public static func fromBody(_ links: [MailLink]) -> UnsubscribeOption? {
        for l in links where l.url.lowercased().hasPrefix("https://") && (l.url.lowercased().contains("unsubscribe") || l.url.lowercased().contains("optout") || l.url.lowercased().contains("opt-out")) {
            if let u = URL(string: l.url), safeHost(u) { return UnsubscribeOption(https: u, mailto: nil, oneClick: false) }
        }
        return nil
    }

    static func parseMailto(_ s: String) -> (to: String, subject: String, body: String)? {
        guard let c = URLComponents(string: s), c.scheme?.lowercased() == "mailto" else { return nil }
        let to = c.path.removingPercentEncoding ?? c.path
        guard to.contains("@"), !to.contains(","), !to.contains(" "), !to.contains("\n") else { return nil }
        func q(_ n: String) -> String? { c.queryItems?.first { $0.name.lowercased() == n }?.value }
        let subject = (q("subject") ?? "unsubscribe").replacingOccurrences(of: "\n", with: " ")
        return (to, subject.isEmpty ? "unsubscribe" : subject, q("body") ?? "unsubscribe")
    }

    /// Never POST to this Mac or the local network, whatever a mail header says.
    static func safeHost(_ u: URL) -> Bool {
        guard u.scheme?.lowercased() == "https", let h = u.host?.lowercased(), !h.isEmpty else { return false }
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".localhost") { return false }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {   // a bare IPv4 address
            if parts[0] == 10 || parts[0] == 127 || parts[0] == 0 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254) || (parts[0] == 172 && (16...31).contains(parts[1])) { return false }
        }
        if h.contains(":") { return false }   // IPv6 literals
        return true
    }
}

/// Performs a one-click unsubscribe: one HTTPS POST with no cookies, no login and no redirects followed.
public enum Unsubscriber {
    public static func postOneClick(_ url: URL) async throws {
        guard UnsubscribeOption.safeHost(url) else { throw UserFacingError("That unsubscribe address isn't safe to contact, so Moose didn't.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.timeoutInterval = 20
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        req.httpShouldHandleCookies = false
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil; cfg.urlCache = nil
        let session = URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<400).contains(code) else { throw UserFacingError("The sender didn't accept the unsubscribe request (HTTP \(code)).") }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
