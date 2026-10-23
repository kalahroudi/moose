// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import MooseKit

struct PendingSend: Identifiable, Equatable {
    let id = UUID()
    var draftID: String
    var account: String
    var to: String
    var subject: String
    var deadline: Date
    var byAgent: Bool
}

/// The mail brain of the app: owns the data file, Gmail clients, the outbox and the control API for agents.
/// Only the visible UI triggers refreshes; nothing here runs on a timer while the app is hidden.
@MainActor @Observable
final class MailModel {
    static let shared = MailModel()

    private(set) var data: MooseData
    private(set) var scored: [ScoredMessage] = []
    var syncing = false
    var signingIn = false
    var client: GoogleClient? = GoogleClient.load()
    var outbox: [PendingSend] = []
    var loadedOnce = false
    /// Screenshot mode: sample data only, nothing is read from or written to disk or the network.
    private(set) var demo = false
    var lastSync: Date? { data.syncedAt.values.max() }

    private let store = DataStore()
    private var clients: [String: GmailClient] = [:]
    private var saveTask: Task<Void, Never>?
    private var sentSamples: [String] = []
    private var control: ControlServer?

    private init() { data = store.load(); rescore() }

    var accounts: [MailAccount] { data.accounts }
    var favourites: Set<String> { Set(data.favourites) }
    var rules: [Rule] { data.rules }
    var access: AgentAccess { get { data.agentAccess } set { data.agentAccess = newValue; persistSoon() } }
    var hasAccount: Bool { !data.accounts.isEmpty }
    var userName: String { NSFullUserName() }

    func stacks(_ view: MailView, unreadOnly: Bool = false) -> [MailStack] {
        Stacker.stacks(for: view, messages: scored, favourites: favourites, unreadOnly: unreadOnly)
    }
    func count(_ view: MailView) -> Int { stacks(view, unreadOnly: view == .priority).count }
    func mutedSummary() -> [(MuteBucket, Int)] {
        var d: [MuteBucket: Int] = [:]
        for m in scored { if let b = m.muted { d[b, default: 0] += 1 } }
        return MuteBucket.allCases.compactMap { b in d[b].map { (b, $0) } }
    }
    func accountUnread(_ email: String) -> Int { scored.filter { $0.message.account == email && $0.message.unread && $0.muted == nil }.count }
    func accountColor(_ email: String) -> Color {
        let i = data.accounts.first { $0.email == email }?.colorIndex ?? 0
        return [Theme.accent, Theme.ok, Color(nsColor: Theme.rgb(0x7C93E8)), Theme.danger, Theme.warn][i % 5]
    }

    private func rescore() { scored = data.scored() }

    func persistSoon() {
        rescore()
        if demo { return }
        saveTask?.cancel()
        let snapshot = data
        saveTask = Task.detached { [store] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            do { try store.save(snapshot) } catch { AppLog.error(error, context: "save mail data") }
        }
    }

    /// Flushes right away: window close, resign active, quit.
    func flush() { if demo { return }; saveTask?.cancel(); do { try store.save(data) } catch { AppLog.error(error, context: "flush mail data") } }

    func loadDemo(_ d: MooseData, signedIn: Bool) {
        demo = true; data = d; rescore(); loadedOnce = true
        client = signedIn ? GoogleClient(clientID: "demo.apps.googleusercontent.com", clientSecret: "demo") : nil
    }

    // MARK: Google

    func importClient(_ c: GoogleClient) {
        do { try c.save(); client = c } catch { AppModel.shared.show(UserError.message(for: error, action: "Save your Google client"), error: true); AppLog.error(error, context: "save google client") }
    }

    /// Opens the browser for Google sign-in, stores the refresh token in the Keychain, adds the account.
    func addAccount() {
        guard let client, !signingIn else { return }
        signingIn = true
        Task {
            defer { signingIn = false }
            do {
                let t = try await GoogleAuth.signIn(client: client) { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
                guard let refresh = t.refresh else { throw GoogleAuthError.badResponse("no refresh token") }
                let probe = GmailClient(account: "pending", client: client)
                try GmailClient.storeRefreshToken(refresh, for: "pending")
                let email = try await probe.profileEmail()
                try GmailClient.storeRefreshToken(refresh, for: email)
                GmailClient.removeAccount("pending")
                if !data.accounts.contains(where: { $0.email == email }) { data.accounts.append(MailAccount(email: email, colorIndex: data.accounts.count)) }
                persistSoon()
                AppModel.shared.show("Connected \(email)")
                await sync()
            } catch {
                AppLog.error(error, context: "add account")
                AppModel.shared.show(error is GoogleAuthError ? "Google sign-in didn't finish. Try again and approve access in the browser." : UserError.message(for: error, action: "Connect your account"), error: true)
            }
        }
    }

    func removeAccount(_ email: String) {
        GmailClient.removeAccount(email); clients[email] = nil
        data.accounts.removeAll { $0.email == email }
        data.messages.removeAll { $0.account == email }
        persistSoon()
    }

    private func gmail(_ account: String) -> GmailClient? {
        if let c = clients[account] { return c }
        guard let client else { return nil }
        let c = GmailClient(account: account, client: client); clients[account] = c; return c
    }

    // MARK: Sync

    func sync() async {
        guard !syncing, let _ = client, hasAccount else { loadedOnce = true; return }
        syncing = true; defer { syncing = false; loadedOnce = true }
        var failed = 0
        for acct in data.accounts {
            guard let g = gmail(acct.email) else { continue }
            do {
                let fresh = try await g.recentInbox()
                data.messages.removeAll { $0.account == acct.email }
                data.messages += fresh
                if data.repliedTo.isEmpty || Date().timeIntervalSince(data.syncedAt[acct.email] ?? .distantPast) > 6 * 3600 {
                    let r = try await g.recentRecipients()
                    data.repliedTo = Array(Set(data.repliedTo).union(r))
                }
                data.syncedAt[acct.email] = Date()
            } catch { failed += 1; AppLog.error(error, context: "sync \(acct.email)") }
        }
        persistSoon()
        if failed > 0 { AppModel.shared.show("Couldn't refresh \(failed == 1 ? "one account" : "\(failed) accounts"). Check your connection; details are in the log.", error: true) }
    }

    // MARK: Organising (local-first, then Gmail)

    func setCompose(_ id: String, _ text: String) {
        if text.isEmpty { data.composeDrafts[id] = nil } else { data.composeDrafts[id] = text }
        persistSoon()
    }

    func setSignature(_ s: String) { data.sendSignature = s; persistSoon() }
    func setUndo(_ n: Int) { data.undoSeconds = n; persistSoon() }

    func toggleFavourite(_ email: String) {
        if favourites.contains(email) { data.favourites.removeAll { $0 == email } } else { data.favourites.append(email) }
        persistSoon()
    }

    func muteSender(_ email: String) {
        data.rules.append(Rule(senders: [email], action: .mute, source: "you")); persistSoon()
    }

    func addRule(_ rule: Rule) { data.rules.append(rule); persistSoon() }
    func removeRule(_ id: UUID) { data.rules.removeAll { $0.id == id }; persistSoon() }
    func setRule(_ id: UUID, enabled: Bool) { if let i = data.rules.firstIndex(where: { $0.id == id }) { data.rules[i].enabled = enabled; persistSoon() } }

    func markRead(_ m: MailMessage) {
        guard let i = data.messages.firstIndex(where: { $0.id == m.id }), data.messages[i].unread else { return }
        data.messages[i].unread = false; persistSoon()
        Task { do { try await gmail(m.account)?.markRead(m.id) } catch { AppLog.error(error, context: "mark read") } }
    }

    func archive(_ m: MailMessage) {
        data.messages.removeAll { $0.id == m.id }; persistSoon()
        Task { do { try await gmail(m.account)?.archive(m.id) } catch { AppLog.error(error, context: "archive") } }
    }

    func fullText(_ m: MailMessage) async -> String {
        do { return try await gmail(m.account)?.fullText(m.id) ?? m.snippet } catch { AppLog.error(error, context: "read message"); return m.snippet }
    }

    // MARK: Claude drafting and sending

    func draftWithClaude(_ m: MailMessage, tone: DraftTone, extra: String = "") async throws -> String {
        let text = await fullText(m)
        if sentSamples.isEmpty, let g = gmail(m.account) { sentSamples = await g.sentSamples() }
        let thread = "From: \(m.displayName) <\(m.fromEmail)>\nSubject: \(m.subject)\n\n\(text)"
        return try await ClaudeDrafter.draft(thread: thread, tone: tone, userName: userName, styleSamples: sentSamples, extra: extra)
    }

    /// Saves a Gmail draft, then sends it after the undo window. The window can be cancelled from the outbox banner.
    @discardableResult
    func queueReply(to m: MailMessage, body: String, undoSeconds: Int, byAgent: Bool) async throws -> PendingSend {
        guard let g = gmail(m.account) else { throw UserFacingError("That account isn't connected any more.") }
        let draft = try await g.createDraft(to: m.fromEmail, subject: MailText.replySubject(m.subject), body: body + (data.sendSignature.isEmpty ? "" : "\n\n" + data.sendSignature),
                                            threadId: m.threadId, inReplyTo: m.messageIDHeader, references: m.referencesHeader)
        let p = PendingSend(draftID: draft, account: m.account, to: m.fromEmail, subject: MailText.replySubject(m.subject), deadline: Date().addingTimeInterval(Double(undoSeconds)), byAgent: byAgent)
        outbox.append(p)
        Task {
            try? await Task.sleep(for: .seconds(undoSeconds))
            guard outbox.contains(p) else { return }
            outbox.removeAll { $0 == p }
            do { try await g.sendDraft(draft); markRead(m); AppModel.shared.show("Sent to \(p.to)") }
            catch { AppLog.error(error, context: "send draft"); AppModel.shared.show("Couldn't send. The draft is saved in Gmail so nothing is lost.", error: true) }
        }
        return p
    }

    func saveDraftOnly(to m: MailMessage, body: String) async throws -> String {
        guard let g = gmail(m.account) else { throw UserFacingError("That account isn't connected any more.") }
        return try await g.createDraft(to: m.fromEmail, subject: MailText.replySubject(m.subject), body: body, threadId: m.threadId, inReplyTo: m.messageIDHeader, references: m.referencesHeader)
    }

    func cancel(_ p: PendingSend) {
        outbox.removeAll { $0 == p }
        Task { try? await gmail(p.account)?.deleteDraft(p.draftID) }
        AppModel.shared.show("Send cancelled")
    }

    // MARK: Agent control API

    func startControl() {
        let server = ControlServer { tool, args in await MailModel.shared.handle(tool, args) }
        do { try server.start(); control = server } catch { AppLog.error(error, context: "start control server") }
    }
    func stopControl() { control?.stop() }

    private func message(_ id: String) -> MailMessage? { data.messages.first { $0.id == id } }

    func handle(_ tool: String, _ a: [String: Any]) async -> (ok: Bool, text: String) {
        func fail(_ s: String) -> (Bool, String) { (false, s) }
        func ok(_ s: String) -> (Bool, String) { (true, s) }
        func str(_ k: String) -> String? { (a[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch tool {
        case "sync": await sync(); return ok("Synced \(data.messages.count) messages.")
        case "read_message":
            guard let id = str("message_id"), let m = message(id) else { return fail("Unknown message_id. Use list_stacks to find ids.") }
            let body = await fullText(m)
            return ok("From: \(m.displayName) <\(m.fromEmail)>\nAccount: \(m.account)\nSubject: \(m.subject)\nDate: \(m.date.formatted())\n\n\(MailText.excerpt(body, 6000).isEmpty ? m.snippet : String(body.prefix(6000)))")
        case "mark_read": guard let id = str("message_id"), let m = message(id) else { return fail("Unknown message_id.") }; markRead(m); return ok("Marked read.")
        case "archive": guard let id = str("message_id"), let m = message(id) else { return fail("Unknown message_id.") }; archive(m); return ok("Archived.")
        case "set_favourite":
            guard let e = str("sender")?.lowercased() else { return fail("Missing sender.") }
            let on = (a["on"] as? Bool) ?? true
            if on != favourites.contains(e) { toggleFavourite(e) }
            return ok(on ? "\(e) is now a favourite." : "\(e) is no longer a favourite.")
        case "mute_sender": guard let e = str("sender")?.lowercased() else { return fail("Missing sender.") }; muteSender(e); return ok("Muted \(e). Undo with delete_rule.")
        case "create_rule":
            guard let t = str("text"), var r = RuleParser.parse(t) else { return fail("Couldn't understand that rule. Try: \"mute newsletters\", \"favourite maya@acme.com\" or \"boost invoice by 25\".") }
            r.source = "agent"; addRule(r); return ok("Rule added (\(r.id.uuidString)): \(r.actionText) \(r.title)")
        case "delete_rule": guard let s = str("rule_id"), let id = UUID(uuidString: s) else { return fail("Missing rule_id.") }; removeRule(id); return ok("Rule removed.")
        case "draft_reply":
            guard access.canDraft else { return fail("Agent access is read only. The user can change it in Moose → Settings → Agents.") }
            guard let id = str("message_id"), let m = message(id) else { return fail("Unknown message_id.") }
            do {
                let body: String
                if let b = str("body") { body = b } else { body = try await draftWithClaude(m, tone: DraftTone(rawValue: str("tone") ?? "") ?? .normal, extra: str("guidance") ?? "") }
                let d = try await saveDraftOnly(to: m, body: body)
                return ok("Draft saved in Gmail (draft_id \(d)):\n\n\(body)")
            } catch { AppLog.error(error, context: "agent draft"); return fail((error as? UserFacingError)?.message ?? "Couldn't write the draft.") }
        case "send_reply":
            guard let id = str("message_id"), let m = message(id), let body = str("body") else { return fail("Needs message_id and body.") }
            switch SendPolicy.decide(access) {
            case .refuse(let why): return fail(why)
            case .askUser:
                guard await Approval.ask(title: "An agent wants to send an email", detail: "To: \(m.fromEmail)\nSubject: \(MailText.replySubject(m.subject))\n\n\(String(body.prefix(1200)))") else {
                    return fail("The user declined, or didn't answer in time. Nothing was sent. The text is still available to save as a draft with draft_reply.")
                }
                do { _ = try await queueReply(to: m, body: body, undoSeconds: 5, byAgent: true); return ok("Approved by the user. Sending in 5 seconds.") }
                catch { AppLog.error(error, context: "agent send"); return fail("Couldn't send.") }
            case .sendAfterUndo:
                do { _ = try await queueReply(to: m, body: body, undoSeconds: data.undoSeconds, byAgent: true); AppLog.info("agent send queued to \(m.fromEmail)"); return ok("Queued. Sends in \(data.undoSeconds) s unless the user cancels.") }
                catch { AppLog.error(error, context: "agent send"); return fail("Couldn't send.") }
            }
        default: return fail("Unknown tool.")
        }
    }
}

/// A native approval dialog that denies when nobody answers.
@MainActor enum Approval {
    static func ask(title: String, detail: String, timeout: TimeInterval = 120) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "Send"); alert.addButton(withTitle: "Don't send")
        alert.buttons[1].keyEquivalent = "\r"; alert.buttons[0].keyEquivalent = ""   // Return = the safe choice
        let timer = Task { try? await Task.sleep(for: .seconds(timeout)); if !Task.isCancelled { NSApp.abortModal() } }
        let r = alert.runModal()
        timer.cancel()
        return r == .alertFirstButtonReturn
    }
}
