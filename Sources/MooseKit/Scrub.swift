// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Removes anything personal before text is shown, copied, logged or put in a bug report.
public enum Scrub {
    public static func text(_ input: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> String {
        var s = input
        if !home.isEmpty { s = s.replacingOccurrences(of: home, with: "~") }
        if user.count > 2 { s = s.replacingOccurrences(of: user, with: "<user>") }
        let patterns: [(String, String)] = [
            ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<email>"),
            ("(?i)bearer\\s+[A-Za-z0-9._~+/=-]{8,}", "Bearer <token>"),
            ("ya29\\.[A-Za-z0-9._-]+", "<token>"),
            ("1//[A-Za-z0-9._-]{20,}", "<token>"),
            ("GOCSPX-[A-Za-z0-9_-]+", "<secret>"),
            ("[0-9]+-[a-z0-9]+\\.apps\\.googleusercontent\\.com", "<client-id>"),
            ("sk-[A-Za-z0-9_-]{16,}", "<key>"),
            ("(?i)(token|secret|password|api[_-]?key|code)=([^&\\s]+)", "$1=<redacted>"),
            ("https?://[^\\s/]*:[^\\s/@]*@[^\\s]+", "<url>"),
            ("(https?://[^\\s?]+)\\?[^\\s]*", "$1"),
            ("\\b\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\b", "<ip>"),
        ]
        for (p, r) in patterns { s = s.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        return s
    }

    /// A prefilled "new issue" link. No token needed; the user reviews the text before submitting.
    public static func issueURL(repo: String, category: String, message: String, logTail: String, version: String, commit: String?) -> URL? {
        var arch = "unknown"
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #endif
        var body = "**\(text(category))**: \(text(message))\n\n- Moose \(version)\(commit.map { " (\(String($0.prefix(7))))" } ?? "")\n- macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n- \(arch)\n\n<details><summary>Log</summary>\n\n```\n\(text(logTail))\n```\n</details>\n"
        if body.utf8.count > 6000 { body = String(body.prefix(6000)) }
        var c = URLComponents(string: "https://github.com/\(repo)/issues/new")
        c?.queryItems = [.init(name: "title", value: "[\(category)] \(text(message).prefix(70))"), .init(name: "body", value: body)]
        return c?.url
    }

    /// The last lines of app.log, scrubbed.
    public static func logTail(lines: Int = 40) -> String {
        guard let s = try? String(contentsOf: AppLog.fileURL, encoding: .utf8) else { return "" }
        return text(s.split(separator: "\n").suffix(lines).joined(separator: "\n"))
    }
}
