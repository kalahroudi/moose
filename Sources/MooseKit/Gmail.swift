// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum GmailError: Error { case notSignedIn(String), http(Int, String), decode }

/// Thin Gmail REST client for one account. Text only: it asks for metadata and plain-text parts, never attachments or images.
public actor GmailClient {
    public let account: String
    private let client: GoogleClient
    private var token: TokenSet?
    private var labelCache: [String: String] = [:]
    private let base = "https://gmail.googleapis.com/gmail/v1/users/me"

    public init(account: String, client: GoogleClient) { self.account = account; self.client = client }

    public static func storeRefreshToken(_ t: String, for account: String) throws { try Keychain.set(t, for: "refresh-\(account)") }
    public static func removeAccount(_ account: String) { Keychain.remove("refresh-\(account)") }

    // MARK: Plumbing

    private func accessToken() async throws -> String {
        if let t = token, t.expires > Date() { return t.access }
        guard let r = Keychain.get("refresh-\(account)") else { throw GmailError.notSignedIn(account) }
        let t = try await GoogleAuth.refresh(client: client, refreshToken: r)
        token = t
        return t.access
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        var c = URLComponents(string: base + path)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw GmailError.http(code, String(decoding: data.prefix(300), as: UTF8.self)) }
        if data.isEmpty { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Reading

    public func profileEmail() async throws -> String {
        guard let e = try await request("/profile")["emailAddress"] as? String else { throw GmailError.decode }
        return e.lowercased()
    }

    /// Recent inbox messages as light metadata + Gmail's own text snippet.
    public func recentInbox(days: Int = 30, limit: Int = 150) async throws -> [MailMessage] {
        let ids = try await listIDs(query: "in:inbox newer_than:\(days)d", limit: limit)
        return try await metadata(ids)
    }

    /// Addresses the user has written to recently: the strongest "this person matters" signal.
    public func recentRecipients(days: Int = 90, limit: Int = 150) async throws -> Set<String> {
        let ids = try await listIDs(query: "in:sent newer_than:\(days)d", limit: limit)
        var out = Set<String>()
        await withTaskGroup(of: [String].self) { group in
            var it = ids.makeIterator(); var running = 0
            func next() { if let id = it.next() { running += 1; group.addTask { [self] in await self.recipients(of: id) } } }
            for _ in 0..<6 { next() }
            while let r = await group.next() { running -= 1; out.formUnion(r); next() }
        }
        return out
    }

    private func recipients(of id: String) async -> [String] {
        guard let m = try? await request("/messages/\(id)", query: [.init(name: "format", value: "metadata"), .init(name: "metadataHeaders", value: "To"), .init(name: "metadataHeaders", value: "Cc")]),
              let headers = (m["payload"] as? [String: Any])?["headers"] as? [[String: Any]] else { return [] }
        return headers.compactMap { $0["value"] as? String }.flatMap { $0.split(separator: ",").map { MailText.parseAddress(String($0)).email } }
    }

    func listIDs(query: String, limit: Int, labelID: String? = nil) async throws -> [String] {
        var ids: [String] = []
        var page: String?
        repeat {
            var q: [URLQueryItem] = [.init(name: "maxResults", value: String(min(limit - ids.count, 500)))]
            if !query.isEmpty { q.append(.init(name: "q", value: query)) }
            if let labelID { q.append(.init(name: "labelIds", value: labelID)) }
            if let page { q.append(.init(name: "pageToken", value: page)) }
            let r = try await request("/messages", query: q)
            ids += ((r["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            page = r["nextPageToken"] as? String
        } while page != nil && ids.count < limit
        return ids
    }

    func metadata(_ ids: [String]) async throws -> [MailMessage] {
        var out: [MailMessage] = []
        try await withThrowingTaskGroup(of: MailMessage?.self) { group in
            var it = ids.makeIterator()
            func next() { if let id = it.next() { group.addTask { [self] in try await self.fetchMetadata(id) } } }
            for _ in 0..<8 { next() }
            while let m = try await group.next() { if let m { out.append(m) }; next() }
        }
        return out.sorted { $0.date > $1.date }
    }

    /// The To and Cc headers of one message, for reply-all.
    public func recipientHeaders(_ id: String) async throws -> (to: String, cc: String) {
        let r = try await request("/messages/\(id)", query: [.init(name: "format", value: "metadata"), .init(name: "metadataHeaders", value: "To"), .init(name: "metadataHeaders", value: "Cc")])
        let hs = ((r["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
        func h(_ n: String) -> String { hs.first { ($0["name"] as? String)?.lowercased() == n.lowercased() }?["value"] as? String ?? "" }
        return (h("To"), h("Cc"))
    }

    func fetchMetadata(_ id: String) async throws -> MailMessage? {
        let headers = ["From", "Subject", "List-Unsubscribe", "Precedence", "Message-ID", "References"]
        let r = try await request("/messages/\(id)", query: [.init(name: "format", value: "metadata")] + headers.map { .init(name: "metadataHeaders", value: $0) })
        return Self.message(from: r, account: account)
    }

    public static func message(from r: [String: Any], account: String) -> MailMessage? {
        guard let id = r["id"] as? String, let tid = r["threadId"] as? String else { return nil }
        let hs = ((r["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
        func h(_ n: String) -> String? { hs.first { ($0["name"] as? String)?.lowercased() == n.lowercased() }?["value"] as? String }
        let from = MailText.parseAddress(h("From") ?? "")
        let ms = Double(r["internalDate"] as? String ?? "") ?? Date().timeIntervalSince1970 * 1000
        let labels = (r["labelIds"] as? [String]) ?? []
        let snippet = ((r["snippet"] as? String) ?? "").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
        return MailMessage(id: id, threadId: tid, account: account, fromName: from.name, fromEmail: from.email, subject: h("Subject") ?? "(no subject)",
                           snippet: snippet, date: Date(timeIntervalSince1970: ms / 1000), unread: labels.contains("UNREAD"), labels: labels,
                           bulkHeader: h("List-Unsubscribe") != nil || (h("Precedence")?.lowercased() == "bulk"),
                           messageIDHeader: h("Message-ID"), referencesHeader: h("References"))
    }

    /// The full text of one message (quoted replies trimmed).
    public func fullText(_ id: String) async throws -> String {
        let r = try await request("/messages/\(id)", query: [.init(name: "format", value: "full")])
        return MailText.body(from: (r["payload"] as? [String: Any]) ?? [:])
    }

    /// A few of the user's own recent sent messages, so drafts can match their voice.
    public func sentSamples(count: Int = 4) async -> [String] {
        guard let ids = try? await listIDs(query: "in:sent newer_than:60d", limit: count * 2) else { return [] }
        var out: [String] = []
        for id in ids {
            if let t = try? await fullText(id), t.count > 20 { out.append(t) }
            if out.count >= count { break }
        }
        return out
    }

    // MARK: Organising

    public func modify(_ id: String, add: [String] = [], remove: [String] = []) async throws {
        _ = try await request("/messages/\(id)/modify", method: "POST", body: ["addLabelIds": add, "removeLabelIds": remove])
    }
    /// Up to 1000 messages in one request (Gmail's batchModify). Used for archive / mark read on many messages.
    public func batchModify(_ ids: [String], add: [String] = [], remove: [String] = []) async throws {
        for chunk in stride(from: 0, to: ids.count, by: 1000).map({ Array(ids[$0..<min($0 + 1000, ids.count)]) }) {
            _ = try await request("/messages/batchModify", method: "POST", body: ["ids": chunk, "addLabelIds": add, "removeLabelIds": remove])
        }
    }

    /// Moves to Trash (recoverable for 30 days). Moose never permanently deletes.
    public func trash(_ id: String) async throws { _ = try await request("/messages/\(id)/trash", method: "POST") }
    public func untrash(_ id: String) async throws { _ = try await request("/messages/\(id)/untrash", method: "POST") }

    /// Trash many at once, a few in flight at a time.
    public func trash(_ ids: [String], undo: Bool = false) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var it = ids.makeIterator()
            func next() { if let id = it.next() { group.addTask { [self] in undo ? try await self.untrash(id) : try await self.trash(id) } } }
            for _ in 0..<6 { next() }
            while try await group.next() != nil { next() }
        }
    }

    /// The id of a user label (Gmail's "folder") by name, creating it when it doesn't exist. Nested names like "Work/Clients" work.
    public func labelID(named name: String) async throws -> String {
        if let id = labelCache[name.lowercased()] { return id }
        let existing = ((try await request("/labels")["labels"] as? [[String: Any]]) ?? [])
        for l in existing { if let n = l["name"] as? String, let id = l["id"] as? String { labelCache[n.lowercased()] = id } }
        if let id = labelCache[name.lowercased()] { return id }
        let made = try await request("/labels", method: "POST", body: ["name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"])
        guard let id = made["id"] as? String else { throw GmailError.decode }
        labelCache[name.lowercased()] = id
        return id
    }

    private var labelsListedAt = Date.distantPast

    /// The id of a label if it exists. Unlike `labelID(named:)` this never creates one, so looking at a folder is harmless.
    public func existingLabelID(named name: String) async throws -> String? {
        if let id = labelCache[name.lowercased()] { return id }
        guard Date().timeIntervalSince(labelsListedAt) > 60 else { return nil }   // just looked: it isn't there
        let existing = ((try await request("/labels")["labels"] as? [[String: Any]]) ?? [])
        labelsListedAt = Date()
        for l in existing { if let n = l["name"] as? String, let id = l["id"] as? String { labelCache[n.lowercased()] = id } }
        return labelCache[name.lowercased()]
    }

    /// How many messages carry a label, and how many of those are unread.
    public func labelStats(_ id: String) async throws -> (total: Int, unread: Int) {
        let r = try await request("/labels/\(id)")
        return ((r["messagesTotal"] as? Int) ?? 0, (r["messagesUnread"] as? Int) ?? 0)
    }

    /// The newest messages under a label. Messages whose ids are in `skip` are not fetched again; the caller already has them.
    public func labelMessages(labelID: String, limit: Int, skip: Set<String>) async throws -> (ids: [String], fresh: [MailMessage]) {
        let ids = try await listIDs(query: "", limit: limit, labelID: labelID)
        return (ids, try await metadata(ids.filter { !skip.contains($0) }))
    }

    /// Every message id under a label, up to `limit`.
    public func labelIDs(_ labelID: String, limit: Int = 2000) async throws -> [String] { try await listIDs(query: "", limit: limit, labelID: labelID) }

    public func renameLabel(_ id: String, from old: String, to name: String) async throws {
        _ = try await request("/labels/\(id)", method: "PATCH", body: ["name": name])
        labelCache[old.lowercased()] = nil
        labelCache[name.lowercased()] = id
    }

    /// Deleting a label never deletes mail: the messages simply lose it and stay in All Mail.
    public func deleteLabel(_ id: String, named name: String) async throws {
        _ = try await request("/labels/\(id)", method: "DELETE")
        labelCache[name.lowercased()] = nil
    }

    public func markRead(_ id: String) async throws { try await modify(id, remove: ["UNREAD"]) }
    public func archive(_ id: String) async throws { try await modify(id, remove: ["INBOX"]) }

    // MARK: Writing

    public func createDraft(to: String, subject: String, body: String, threadId: String?, inReplyTo: String?, references: String?, attachments: [MailAttachment] = [], cc: String = "", bcc: String = "") async throws -> String {
        var msg: [String: Any] = ["raw": MailText.rawMessage(from: account, to: to, subject: subject, body: body, inReplyTo: inReplyTo, references: references, attachments: attachments, cc: cc, bcc: bcc)]
        if let t = threadId { msg["threadId"] = t }
        let r = try await request("/drafts", method: "POST", body: ["message": msg])
        guard let id = r["id"] as? String else { throw GmailError.decode }
        return id
    }

    public func sendDraft(_ draftID: String) async throws { _ = try await request("/drafts/send", method: "POST", body: ["id": draftID]) }
    public func deleteDraft(_ draftID: String) async throws { _ = try await request("/drafts/\(draftID)", method: "DELETE") }
}
