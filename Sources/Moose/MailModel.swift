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
    var isReply = true
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
    private var signInServer: LoopbackServer?
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
    private var pendingOps = 0

    /// What "Undo" restores. One entry per action; ⌘Z walks back through the last few.
    struct UndoEntry: Identifiable {
        let id = UUID()
        let action: StackAction
        let messages: [MailMessage]      // exactly as they were
        let text: String
        var folder: String? = nil        // for .file: where the messages went
    }
    private(set) var undoStack: [UndoEntry] = []
    private(set) var undoToast: UndoEntry?

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
        let server = LoopbackServer(); signInServer = server
        Task {
            defer { signingIn = false; signInServer = nil }
            do {
                let t = try await GoogleAuth.signIn(client: client, open: { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }, server: server)
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
            } catch GoogleAuthError.cancelled {
                AppModel.shared.show("Sign-in cancelled")
            } catch GmailError.http(403, let body) where body.contains("has not been used") || body.contains("SERVICE_DISABLED") {
                AppLog.error(GmailError.http(403, body), context: "add account")
                let project = client.clientID.split(separator: "-").first.map(String.init) ?? ""
                if let url = URL(string: "https://console.developers.google.com/apis/api/gmail.googleapis.com/overview?project=\(project)") { NSWorkspace.shared.open(url) }
                AppModel.shared.show("Signed in, but the Gmail API isn't enabled in your Google project. Click Enable on the page that just opened, wait a minute, then sign in again.", error: true)
            } catch {
                AppLog.error(error, context: "add account")
                AppModel.shared.show(error is GoogleAuthError ? "Google sign-in didn't finish. Try again and approve access in the browser." : UserError.message(for: error, action: "Connect your account"), error: true)
            }
        }
    }

    func cancelSignIn() { signInServer?.cancel() }

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
        guard !syncing, pendingOps == 0, let _ = client, hasAccount else { loadedOnce = true; return }
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
        let filed = autoFile(data.messages)
        persistSoon()
        if filed > 0 { AppModel.shared.show("Filed \(filed) new \(filed == 1 ? "email" : "emails") into your folders") }
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

    /// Mutes one sender, for good or for a number of days.
    func muteSender(_ email: String, days: Int? = nil) {
        let until = days.map { Date().addingTimeInterval(Double($0) * 86400) }
        data.rules.append(Rule(senders: [email], action: .mute, source: "you", until: until)); persistSoon()
        AppModel.shared.show(days.map { "Muted \(email) for \($0 == 7 ? "a week" : "\($0) days")" } ?? "Muted \(email)")
    }

    /// Mutes everyone at the sender's domain ("@news.club.com"), e.g. all of a company's marketing addresses.
    func muteDomain(of email: String) {
        guard let at = email.lastIndex(of: "@") else { return }
        let domain = String(email[email.index(after: at)...])
        data.rules.append(Rule(senders: ["@" + domain], action: .mute, source: "you")); persistSoon()
        AppModel.shared.show("Muted everything from @\(domain)")
    }

    /// Files everything from this sender in a Gmail label named after them.
    func fileSender(_ m: MailMessage) {
        let name = m.fromName.isEmpty ? m.fromEmail : m.fromName
        AppModel.shared.show(addRule(Rule(senders: [m.fromEmail], action: .file(name), source: "you")))
    }

    /// Adds a rule and says in one sentence what it did. A folder rule also files the matching mail already in the inbox.
    @discardableResult
    func addRule(_ rule: Rule) -> String {
        data.rules.append(rule)
        let matching = data.messages.filter { rule.matches($0) }
        defer { persistSoon() }
        switch rule.action {
        case .file(let folder):
            guard !matching.isEmpty else { return "Rule added. Nothing in your inbox matches yet; new mail \(rule.title) will be filed in “\(folder)”." }
            apply(.file, to: matching, folder: folder)
            return "Rule added. Filed \(matching.count) \(matching.count == 1 ? "email" : "emails") in “\(folder)” and the rest will follow."
        case .mute: return "Rule added. \(matching.count) \(matching.count == 1 ? "email is" : "emails are") muted now."
        default: return "Rule added."
        }
    }

    /// Files mail that matches a folder rule: label in Gmail, out of the inbox. Quiet (no undo toast); used on every sync.
    private func autoFile(_ messages: [MailMessage]) -> Int {
        let fileRules = data.rules.filter { $0.isActive() && $0.folder != nil }
        guard !fileRules.isEmpty else { return 0 }
        var byFolder: [String: [MailMessage]] = [:]
        for m in messages { if let f = fileRules.first(where: { $0.matches(m) })?.folder { byFolder[f, default: []].append(m) } }
        for (folder, msgs) in byFolder { mutateLocal(.file, msgs, inverse: false); remote(.file, msgs, inverse: false, folder: folder) }
        return byFolder.values.reduce(0) { $0 + $1.count }
    }
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

    // MARK: Bulk actions with undo (no confirmation dialogs: every action has an exact inverse)

    /// Applies an action to many messages at once. The local cache changes immediately; Gmail follows.
    @discardableResult
    func apply(_ action: StackAction, to messages: [MailMessage], sender: String? = nil, folder: String? = nil) -> UndoEntry? {
        let present = Set(data.messages.map(\.id))
        let targets = messages.filter { present.contains($0.id) }
        guard !targets.isEmpty else { return nil }
        let text = folder.map { "\(action.verb()) \(targets.count) in “\($0)”" } ?? action.summary(count: targets.count, sender: sender)
        let entry = UndoEntry(action: action, messages: targets, text: text, folder: folder)
        mutateLocal(action, targets, inverse: false)
        remote(action, targets, inverse: false, folder: folder)
        undoStack.append(entry); if undoStack.count > 20 { undoStack.removeFirst() }
        undoToast = entry
        Task { try? await Task.sleep(for: .seconds(10)); if undoToast?.id == entry.id { undoToast = nil } }
        return entry
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        mutateLocal(entry.action, entry.messages, inverse: true)
        remote(entry.action, entry.messages, inverse: true, folder: entry.folder)
        undoToast = nil
        AppModel.shared.show("Undone: \(entry.text)")
    }
    var canUndo: Bool { !undoStack.isEmpty }

    private func mutateLocal(_ action: StackAction, _ msgs: [MailMessage], inverse: Bool) {
        let ids = Set(msgs.map(\.id))
        switch (action, inverse) {
        case (.archive, false), (.trash, false), (.file, false): data.messages.removeAll { ids.contains($0.id) }
        case (.archive, true), (.trash, true), (.file, true): data.messages += msgs.filter { m in !data.messages.contains { $0.id == m.id } }
        case (.markRead, false): for i in data.messages.indices where ids.contains(data.messages[i].id) { data.messages[i].unread = false }
        case (.markRead, true):
            let wasUnread = Set(msgs.filter(\.unread).map(\.id))
            for i in data.messages.indices where wasUnread.contains(data.messages[i].id) { data.messages[i].unread = true }
        }
        persistSoon()
    }

    private func remote(_ action: StackAction, _ msgs: [MailMessage], inverse: Bool, folder: String? = nil) {
        if demo { return }
        pendingOps += 1
        Task {
            defer { pendingOps -= 1 }
            var failed = false
            for (account, group) in Deck.group(msgs) {
                guard let g = gmail(account) else { continue }
                let ids = group.map(\.id)
                do {
                    switch (action, inverse) {
                    case (.archive, false): try await g.batchModify(ids, remove: ["INBOX"])
                    case (.archive, true): try await g.batchModify(ids, add: ["INBOX"])
                    case (.markRead, false): try await g.batchModify(ids, remove: ["UNREAD"])
                    case (.markRead, true): try await g.batchModify(group.filter(\.unread).map(\.id), add: ["UNREAD"])
                    case (.trash, _): try await g.trash(ids, undo: inverse)
                    case (.file, _):
                        guard let folder else { break }
                        let label = try await g.labelID(named: folder)
                        if inverse { try await g.batchModify(ids, add: ["INBOX"], remove: [label]) } else { try await g.batchModify(ids, add: [label], remove: ["INBOX"]) }
                    }
                } catch { failed = true; AppLog.error(error, context: "bulk \(action.rawValue)") }
            }
            if failed { AppModel.shared.show("Couldn't update Gmail for some messages. They'll reappear on the next refresh if so.", error: true) }
        }
    }

    func messages(ids: [String]) -> [MailMessage] { let set = Set(ids); return data.messages.filter { set.contains($0.id) } }

    // MARK: Claude drafting and sending

    func draftWithClaude(_ m: MailMessage, tone: DraftTone, extra: String = "") async throws -> String {
        let text = await fullText(m)
        if sentSamples.isEmpty, let g = gmail(m.account) { sentSamples = await g.sentSamples() }
        let thread = "From: \(m.displayName) <\(m.fromEmail)>\nSubject: \(m.subject)\n\n\(text)"
        return try await ClaudeDrafter.draft(thread: thread, tone: tone, userName: userName, styleSamples: sentSamples, extra: extra)
    }

    /// Saves a Gmail draft, then sends it after the undo window. The window can be cancelled from the outbox banner.
    @discardableResult
    func queueReply(to m: MailMessage, body: String, cc: String = "", undoSeconds: Int, byAgent: Bool) async throws -> PendingSend {
        try await queueSend(account: m.account, to: m.fromEmail, cc: cc, subject: MailText.replySubject(m.subject), body: body, threadId: m.threadId,
                            inReplyTo: m.messageIDHeader, references: m.referencesHeader, undoSeconds: undoSeconds, byAgent: byAgent) { self.markRead(m) }
    }

    /// A brand-new email (not a reply), sent the same way: draft first, then sent after the undo window.
    @discardableResult
    func queueNew(account: String, to: String, cc: String = "", bcc: String = "", subject: String, body: String, attachments: [MailAttachment] = [], undoSeconds: Int, byAgent: Bool) async throws -> PendingSend {
        try await queueSend(account: account, to: to, cc: cc, bcc: bcc, subject: subject, body: body, attachments: attachments, threadId: nil, inReplyTo: nil, references: nil, undoSeconds: undoSeconds, byAgent: byAgent, onSent: nil)
    }

    private func queueSend(account: String, to: String, cc: String = "", bcc: String = "", subject: String, body: String, attachments: [MailAttachment] = [], threadId: String?, inReplyTo: String?, references: String?,
                           undoSeconds: Int, byAgent: Bool, onSent: (() -> Void)?) async throws -> PendingSend {
        guard let g = gmail(account) else { throw UserFacingError("That account isn't connected any more.") }
        let draft = try await g.createDraft(to: to, subject: subject, body: body + (data.sendSignature.isEmpty ? "" : "\n\n" + data.sendSignature),
                                            threadId: threadId, inReplyTo: inReplyTo, references: references, attachments: attachments, cc: cc, bcc: bcc)
        let p = PendingSend(draftID: draft, account: account, to: to, subject: subject, deadline: Date().addingTimeInterval(Double(undoSeconds)), byAgent: byAgent, isReply: threadId != nil)
        outbox.append(p)
        Task {
            try? await Task.sleep(for: .seconds(undoSeconds))
            guard outbox.contains(p) else { return }
            outbox.removeAll { $0 == p }
            do { try await g.sendDraft(draft); onSent?(); AppModel.shared.show("Sent to \(p.to)") }
            catch { AppLog.error(error, context: "send draft"); AppModel.shared.show("Couldn't send. The draft is saved in Gmail so nothing is lost.", error: true) }
        }
        return p
    }

    func saveNewDraft(account: String, to: String, cc: String = "", bcc: String = "", subject: String, body: String, attachments: [MailAttachment] = []) async throws -> String {
        guard let g = gmail(account) else { throw UserFacingError("That account isn't connected any more.") }
        return try await g.createDraft(to: to, subject: subject, body: body, threadId: nil, inReplyTo: nil, references: nil, attachments: attachments, cc: cc, bcc: bcc)
    }

    func composeWithClaude(account: String, to: String, subject: String, body: String, brief: String) async throws -> ComposedEmail {
        if sentSamples.isEmpty, let g = gmail(account) { sentSamples = await g.sentSamples() }
        return try await ClaudeDrafter.compose(brief: brief, to: to, subject: subject, body: body, userName: userName, styleSamples: sentSamples)
    }

    func saveDraftOnly(to m: MailMessage, body: String, cc: String = "") async throws -> String {
        guard let g = gmail(m.account) else { throw UserFacingError("That account isn't connected any more.") }
        return try await g.createDraft(to: m.fromEmail, subject: MailText.replySubject(m.subject), body: body, threadId: m.threadId, inReplyTo: m.messageIDHeader, references: m.referencesHeader, cc: cc)
    }

    /// Everyone else the message went to, as a Cc line for reply-all.
    func replyAllCc(for m: MailMessage) async throws -> String {
        guard let g = gmail(m.account) else { throw UserFacingError("That account isn't connected any more.") }
        let h = try await g.recipientHeaders(m.id)
        return MailText.replyAllCc(to: h.to, cc: h.cc, replyingTo: m.fromEmail, me: m.account).joined(separator: ", ")
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

    /// The named account, or the first one when none is named.
    func pickAccount(_ email: String?) -> String? {
        guard let e = email?.lowercased() else { return data.accounts.first?.email }
        return data.accounts.first { $0.email.lowercased() == e }?.email
    }

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
        case "archive_many", "trash_many":
            guard let ids = a["message_ids"] as? [String], !ids.isEmpty else { return fail("Missing message_ids.") }
            let msgs = messages(ids: Array(ids.prefix(500)))
            guard !msgs.isEmpty else { return fail("None of those message ids are in the inbox.") }
            let act: StackAction = tool == "trash_many" ? .trash : .archive
            apply(act, to: msgs); return ok("\(act.summary(count: msgs.count, sender: nil)). The user can press Undo in Moose; \(act == .trash ? "Trash keeps mail for 30 days." : "mail stays in All Mail.")")
        case "undo": guard canUndo else { return fail("Nothing to undo.") }; undo(); return ok("Undone.")
        case "mark_read": guard let id = str("message_id"), let m = message(id) else { return fail("Unknown message_id.") }; markRead(m); return ok("Marked read.")
        case "archive": guard let id = str("message_id"), let m = message(id) else { return fail("Unknown message_id.") }; archive(m); return ok("Archived.")
        case "set_favourite":
            guard let e = str("sender")?.lowercased() else { return fail("Missing sender.") }
            let on = (a["on"] as? Bool) ?? true
            if on != favourites.contains(e) { toggleFavourite(e) }
            return ok(on ? "\(e) is now a favourite." : "\(e) is no longer a favourite.")
        case "mute_sender": guard let e = str("sender")?.lowercased() else { return fail("Missing sender.") }; muteSender(e); return ok("Muted \(e). Undo with delete_rule.")
        case "create_rule":
            guard let t = str("text"), var r = RuleParser.parse(t) else { return fail("Couldn't understand that rule. Try: \"mute newsletters\", \"favourite maya@acme.com\", \"boost invoice by 25\" or \"move emails from stripe.com to Receipts\".") }
            r.source = "agent"; let what = addRule(r); return ok("\(what) (\(r.id.uuidString)): \(r.actionText) \(r.title)")
        case "delete_rule": guard let s = str("rule_id"), let id = UUID(uuidString: s) else { return fail("Missing rule_id.") }; removeRule(id); return ok("Rule removed.")
        case "draft_reply":
            guard access.canDraft else { return fail("Agent access is read only. The user can change it in Moose → Settings → Agents.") }
            guard let id = str("message_id"), let m = message(id) else { return fail("Unknown message_id.") }
            do {
                let cc = (a["reply_all"] as? Bool) == true ? try await replyAllCc(for: m) : ""
                let body: String
                if let b = str("body") { body = b } else { body = try await draftWithClaude(m, tone: DraftTone(rawValue: str("tone") ?? "") ?? .normal, extra: str("guidance") ?? "") }
                let d = try await saveDraftOnly(to: m, body: body, cc: cc)
                return ok("Draft saved in Gmail (draft_id \(d))\(cc.isEmpty ? "" : ", Cc: \(cc)"):\n\n\(body)")
            } catch { AppLog.error(error, context: "agent draft"); return fail((error as? UserFacingError)?.message ?? "Couldn't write the draft.") }
        case "send_reply":
            guard let id = str("message_id"), let m = message(id), let body = str("body") else { return fail("Needs message_id and body.") }
            let cc = (a["reply_all"] as? Bool) == true ? ((try? await replyAllCc(for: m)) ?? "") : ""
            switch SendPolicy.decide(access) {
            case .refuse(let why): return fail(why)
            case .askUser:
                guard await Approval.ask(title: "An agent wants to send an email", detail: "To: \(m.fromEmail)\(cc.isEmpty ? "" : "\nCc: \(cc)")\nSubject: \(MailText.replySubject(m.subject))\n\n\(String(body.prefix(1200)))") else {
                    return fail("The user declined, or didn't answer in time. Nothing was sent. The text is still available to save as a draft with draft_reply.")
                }
                do { _ = try await queueReply(to: m, body: body, cc: cc, undoSeconds: 5, byAgent: true); return ok("Approved by the user. Sending in 5 seconds.") }
                catch { AppLog.error(error, context: "agent send"); return fail("Couldn't send.") }
            case .sendAfterUndo:
                do { _ = try await queueReply(to: m, body: body, cc: cc, undoSeconds: data.undoSeconds, byAgent: true); AppLog.info("agent send queued to \(m.fromEmail)"); return ok("Queued. Sends in \(data.undoSeconds) s unless the user cancels.") }
                catch { AppLog.error(error, context: "agent send"); return fail("Couldn't send.") }
            }
        case "draft_email":
            guard access.canDraft else { return fail("Agent access is read only. The user can change it in Moose → Settings → Agents.") }
            guard let to = str("to") else { return fail("Missing to.") }
            guard let account = pickAccount(str("account")) else { return fail("Unknown account. Use get_status to see the connected accounts.") }
            do {
                var subject = str("subject") ?? "", body = str("body") ?? ""
                if body.isEmpty {
                    guard let brief = str("brief") else { return fail("Give either body, or brief so Moose can write it with the user's Claude.") }
                    let c = try await composeWithClaude(account: account, to: to, subject: subject, body: "", brief: brief)
                    body = c.body; if subject.isEmpty { subject = c.subject }
                }
                let d = try await saveNewDraft(account: account, to: to, cc: str("cc") ?? "", bcc: str("bcc") ?? "", subject: subject, body: body)
                return ok("Draft saved in Gmail (draft_id \(d)), not sent.\nTo: \(to)\(str("cc").map { "\nCc: \($0)" } ?? "")\(str("bcc").map { "\nBcc: \($0)" } ?? "")\nSubject: \(subject)\n\n\(body)")
            } catch { AppLog.error(error, context: "agent compose"); return fail((error as? UserFacingError)?.message ?? "Couldn't write the email.") }
        case "send_email":
            guard let to = str("to"), let subject = str("subject"), let body = str("body") else { return fail("Needs to, subject and body.") }
            guard let account = pickAccount(str("account")) else { return fail("Unknown account. Use get_status to see the connected accounts.") }
            switch SendPolicy.decide(access) {
            case .refuse(let why): return fail(why)
            case .askUser:
                guard await Approval.ask(title: "An agent wants to send an email", detail: "From: \(account)\nTo: \(to)\(str("cc").map { "\nCc: \($0)" } ?? "")\(str("bcc").map { "\nBcc: \($0)" } ?? "")\nSubject: \(subject)\n\n\(String(body.prefix(1200)))") else {
                    return fail("The user declined, or didn't answer in time. Nothing was sent. The text can still be saved with draft_email.")
                }
                do { _ = try await queueNew(account: account, to: to, cc: str("cc") ?? "", bcc: str("bcc") ?? "", subject: subject, body: body, undoSeconds: 5, byAgent: true); return ok("Approved by the user. Sending in 5 seconds.") }
                catch { AppLog.error(error, context: "agent send new"); return fail("Couldn't send.") }
            case .sendAfterUndo:
                do { _ = try await queueNew(account: account, to: to, cc: str("cc") ?? "", bcc: str("bcc") ?? "", subject: subject, body: body, undoSeconds: data.undoSeconds, byAgent: true); AppLog.info("agent send queued to \(to)"); return ok("Queued. Sends in \(data.undoSeconds) s unless the user cancels.") }
                catch { AppLog.error(error, context: "agent send new"); return fail("Couldn't send.") }
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
