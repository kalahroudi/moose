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

struct FolderStats: Equatable { var total = 0; var unread = 0 }

/// What happens to the mail in a folder when the folder is deleted.
enum FolderDeletion { case keepMail, toInbox, trashMail }

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
    private let briefStore = BriefStore()
    private var briefs: [String: MailBrief] = [:]
    private var briefsLoaded = false
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
        var container: MailContainer = .inbox   // where they were taken from
        var ruleID: UUID? = nil          // a block rule made with this action: undoing removes it too
    }
    private var unsubCache: [String: UnsubscribeOption] = [:]
    private(set) var undoStack: [UndoEntry] = []
    /// Mail that filing rules moved out of the inbox, by `Folders.key`. Loaded from the Gmail label when a folder is opened; not saved to disk.
    private(set) var folderMessages: [String: [MailMessage]] = [:]
    private(set) var folderStats: [String: FolderStats] = [:]
    private(set) var folderLoading: Set<String> = []
    private var folderStatsAt = Date.distantPast
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

    func loadDemo(_ d: MooseData, signedIn: Bool, folders: [String: [MailMessage]] = [:]) {
        demo = true; data = d; rescore(); loadedOnce = true
        folderMessages = Dictionary(uniqueKeysWithValues: folders.map { (Folders.key($0.key), $0.value.sorted { $0.date > $1.date }) })
        folderStats = folderMessages.mapValues { FolderStats(total: $0.count, unread: $0.filter(\.unread).count) }
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
            } catch { failed += 1; AppLog.error(error, context: "sync") }
        }
        let filed = autoFile(data.messages)
        _ = autoBlock(data.messages)
        persistSoon()
        await refreshFolders()
        if Nav.shared.pane == .folder, let f = Nav.shared.folder { await loadFolder(f) }
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
        announce(addRule(Rule(senders: [m.fromEmail], action: .file(name), source: "you")), folder: name)
    }

    /// Says what a new filing rule did, with a button that opens the folder it files into.
    func announce(_ text: String, folder: String?) {
        AppModel.shared.show(text, actionTitle: folder == nil ? nil : "Open folder") { if let f = folder { AppDelegate.shared.showManager(); Nav.shared.openFolder(f) } }
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

    /// Archives new mail from blocked senders so it never reaches the inbox. Quiet; runs on every sync.
    private func autoBlock(_ messages: [MailMessage]) -> Int {
        let rules = data.rules.filter { $0.action == .block && $0.isActive() }
        guard !rules.isEmpty else { return 0 }
        let hit = messages.filter { m in rules.contains { $0.matches(m) } }
        guard !hit.isEmpty else { return 0 }
        mutateLocal(.archive, hit, inverse: false); remote(.archive, hit, inverse: false)
        return hit.count
    }

    // MARK: Unsubscribe and block

    func isBlocked(_ email: String) -> Bool { data.rules.contains { $0.action == .block && $0.isActive() && $0.senders.contains(email.lowercased()) } }

    /// Blocks a sender: their mail is archived now and on every sync after. One Undo puts it all back.
    @discardableResult
    func blockSender(_ email: String, said: String? = nil) -> Int {
        let e = email.lowercased()
        var ruleID: UUID?
        if !isBlocked(e) { let r = Rule(senders: [e], action: .block, source: "you"); data.rules.append(r); ruleID = r.id }
        let msgs = data.messages.filter { $0.fromEmail == e }
        let text = said ?? "Blocked \(e)" + (msgs.isEmpty ? "" : " and archived \(msgs.count)")
        if apply(.archive, to: msgs, sender: e, ruleID: ruleID, text: text) == nil {
            persistSoon()
            AppModel.shared.show(said ?? "Blocked \(e)", actionTitle: ruleID == nil ? nil : "Undo") { [self] in if let ruleID { removeRule(ruleID) } }
        } else { persistSoon() }
        return msgs.count
    }

    /// How the sender lets you opt out: the List-Unsubscribe header, or failing that an unsubscribe link in the text. Nil when there is none.
    func unsubscribeOption(for m: MailMessage) async -> UnsubscribeOption? {
        if let o = unsubCache[m.id] { return o }
        if demo { return m.bulkHeader ? UnsubscribeOption(https: URL(string: "https://news.example/unsubscribe"), mailto: nil, oneClick: true) : nil }
        var o: UnsubscribeOption?
        if m.bulkHeader { o = try? await gmail(m.account)?.unsubscribeOption(m.id) }
        if o == nil { o = UnsubscribeOption.fromBody(MailText.links(in: await fullText(m))) }
        if let o { unsubCache[m.id] = o }
        return o
    }

    /// Asks the user in a native dialog, saying plainly what will be sent and to whom.
    func confirmUnsubscribe(_ m: MailMessage, _ o: UnsubscribeOption, byAgent: Bool = false) async -> Bool {
        let what: String = switch o.method {
        case .oneClick?: "Moose will send the sender's own one-click unsubscribe request. No email is sent and no page opens."
        case .email(let to, _, _)?: "Moose will send a short unsubscribe email from \(m.account) to \(to)."
        case .browser?: "Moose will open the sender's unsubscribe page in your browser. You finish it there."
        case nil: ""
        }
        let after = { if case .browser? = o.method { return "" }; return "\n\nThen \(m.fromEmail) is blocked and their mail here is archived. Undo restores it." }()
        return await Approval.ask(title: "\(byAgent ? "An agent wants to unsubscribe" : "Unsubscribe") from \(m.displayName)?", detail: what + after, confirm: "Unsubscribe", decline: "Cancel")
    }

    /// Unsubscribes by the best method the sender offers, then blocks them. The caller has already confirmed.
    func unsubscribe(_ m: MailMessage, _ o: UnsubscribeOption) async throws -> String {
        switch o.method {
        case .oneClick(let u)?:
            if !demo { try await Unsubscriber.postOneClick(u) }
            blockSender(m.fromEmail, said: "Unsubscribed from \(m.displayName) and blocked them")
            return "Unsubscribed with one click. \(m.fromEmail) is blocked and their mail archived."
        case .email(let to, let subject, let body)?:
            if !demo { try await queueNew(account: m.account, to: to, subject: subject, body: body, undoSeconds: data.undoSeconds, byAgent: false, signature: false) }
            blockSender(m.fromEmail, said: "Unsubscribe email to \(m.displayName) goes out in \(data.undoSeconds) s. Blocked them")
            return "Unsubscribe email queued (sends in \(data.undoSeconds) s, cancel it from the outbox banner). \(m.fromEmail) is blocked."
        case .browser(let u)?:
            if !demo { NSWorkspace.shared.open(u) }
            AppModel.shared.show("Opened \(MailText.linkLabel(u.absoluteString)) in your browser. Finish there, then block the sender if you like.")
            return "Opened the sender's page at \(MailText.linkLabel(u.absoluteString)) in the user's browser. The user has to finish it there; nothing was blocked."
        case nil: throw UserFacingError("This sender doesn't offer an unsubscribe option.")
        }
    }

    /// Files mail that matches a folder rule: label in Gmail, out of the inbox. Quiet (no undo toast); used on every sync.
    private func autoFile(_ messages: [MailMessage]) -> Int {
        let fileRules = data.rules.filter { $0.isActive() && $0.folder != nil }
        guard !fileRules.isEmpty else { return 0 }
        var byFolder: [String: [MailMessage]] = [:]
        let kept = Set(data.keepInInbox)
        for m in messages where !kept.contains(m.id) { if let f = fileRules.first(where: { $0.matches(m) })?.folder { byFolder[f, default: []].append(m) } }
        for (folder, msgs) in byFolder { mutateLocal(.file, msgs, inverse: false, folder: folder); remote(.file, msgs, inverse: false, folder: folder) }
        return byFolder.values.reduce(0) { $0 + $1.count }
    }
    func removeRule(_ id: UUID) { data.rules.removeAll { $0.id == id }; persistSoon() }
    func setRule(_ id: UUID, enabled: Bool) { if let i = data.rules.firstIndex(where: { $0.id == id }) { data.rules[i].enabled = enabled; persistSoon() } }

    func markRead(_ m: MailMessage) {
        if let i = data.messages.firstIndex(where: { $0.id == m.id }) {
            guard data.messages[i].unread else { return }
            data.messages[i].unread = false; persistSoon()
        } else if let k = folderKey(containing: m.id), let i = folderMessages[k]?.firstIndex(where: { $0.id == m.id }), folderMessages[k]?[i].unread == true {
            folderMessages[k]?[i].unread = false
            if var s = folderStats[k] { s.unread = max(0, s.unread - 1); folderStats[k] = s }
        } else { return }
        if demo { return }
        Task { do { try await gmail(m.account)?.markRead(m.id) } catch { AppLog.error(error, context: "mark read") } }
    }

    /// Takes a message out of where it is: out of the inbox, or (for filed mail) out of its folder. It stays in All Mail.
    func archive(_ m: MailMessage) {
        if data.messages.contains(where: { $0.id == m.id }) {
            data.messages.removeAll { $0.id == m.id }; persistSoon()
            if demo { return }
            Task { do { try await gmail(m.account)?.archive(m.id) } catch { AppLog.error(error, context: "archive") } }
        } else if let k = folderKey(containing: m.id), let name = folderNames.first(where: { Folders.key($0) == k }) {
            apply(.archive, to: [m], container: .folder(name))
        }
    }

    /// Folder names and Gmail error bodies can hold personal words, so the log gets the failure kind and nothing else.
    private func logFolderError(_ error: Error, _ context: String) {
        if case GmailError.http(let code, _) = error { AppLog.info("\(context) failed: Gmail HTTP \(code)") }
        else if let e = error as? URLError { AppLog.info("\(context) failed: network error \(e.code.rawValue)") }
        else { AppLog.info("\(context) failed: \(type(of: error))") }
    }

    private func folderKey(containing id: String) -> String? { folderMessages.first { $0.value.contains { $0.id == id } }?.key }

    func fullText(_ m: MailMessage) async -> String {
        if demo { return Demo.bodies[m.id] ?? m.snippet }
        do { return try await gmail(m.account)?.fullText(m.id) ?? m.snippet } catch { AppLog.error(error, context: "read message"); return m.snippet }
    }

    // MARK: Bulk actions with undo (no confirmation dialogs: every action has an exact inverse)

    /// Applies an action to many messages at once. The local cache changes immediately; Gmail follows.
    @discardableResult
    func apply(_ action: StackAction, to messages: [MailMessage], sender: String? = nil, folder: String? = nil, container: MailContainer = .inbox, ruleID: UUID? = nil, text customText: String? = nil) -> UndoEntry? {
        let present: Set<String>
        switch container {
        case .inbox: present = Set(data.messages.map(\.id))
        case .folder(let f): present = Set((folderMessages[Folders.key(f)] ?? []).map(\.id))
        }
        let targets = messages.filter { present.contains($0.id) }
        guard !targets.isEmpty else { return nil }
        var text = folder.map { "\(action.verb()) \(targets.count) in “\($0)”" } ?? action.summary(count: targets.count, sender: sender)
        if case .folder(let f) = container, action == .archive { text = "Cleared \(targets.count) from “\(f)”" + (sender.map { " (\($0))" } ?? "") }
        if let customText { text = customText }
        let entry = UndoEntry(action: action, messages: targets, text: text, folder: folder, container: container, ruleID: ruleID)
        mutateLocal(action, targets, inverse: false, container: container, folder: folder)
        remote(action, targets, inverse: false, folder: folder, container: container)
        undoStack.append(entry); if undoStack.count > 20 { undoStack.removeFirst() }
        undoToast = entry
        Task { try? await Task.sleep(for: .seconds(10)); if undoToast?.id == entry.id { undoToast = nil } }
        return entry
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        mutateLocal(entry.action, entry.messages, inverse: true, container: entry.container, folder: entry.folder)
        remote(entry.action, entry.messages, inverse: true, folder: entry.folder, container: entry.container)
        if let r = entry.ruleID { removeRule(r) }
        undoToast = nil
        AppModel.shared.show("Undone: \(entry.text)")
    }
    var canUndo: Bool { !undoStack.isEmpty }

    private func mutateLocal(_ action: StackAction, _ msgs: [MailMessage], inverse: Bool, container: MailContainer = .inbox, folder: String? = nil) {
        let ids = Set(msgs.map(\.id))
        let wasUnread = Set(msgs.filter(\.unread).map(\.id))
        func restoreToInbox() { data.messages += msgs.filter { m in !data.messages.contains { $0.id == m.id } } }
        switch container {
        case .inbox:
            switch (action, inverse) {
            case (.archive, false), (.trash, false): data.messages.removeAll { ids.contains($0.id) }
            case (.file, false): data.messages.removeAll { ids.contains($0.id) }; if let f = folder { folderAdd(f, msgs) }
            case (.archive, true), (.trash, true): restoreToInbox()
            case (.file, true): restoreToInbox(); if let f = folder { folderRemove(f, msgs) }
            case (.markRead, false): for i in data.messages.indices where ids.contains(data.messages[i].id) { data.messages[i].unread = false }
            case (.markRead, true): for i in data.messages.indices where wasUnread.contains(data.messages[i].id) { data.messages[i].unread = true }
            case (.unfile, _): break
            }
        case .folder(let f):
            let k = Folders.key(f)
            switch (action, inverse) {
            case (.archive, false), (.trash, false): folderRemove(f, msgs)
            case (.archive, true), (.trash, true): folderAdd(f, msgs)
            case (.unfile, false):
                folderRemove(f, msgs); restoreToInbox()
                data.keepInInbox += ids.filter { !data.keepInInbox.contains($0) }
                if data.keepInInbox.count > 1000 { data.keepInInbox.removeFirst(data.keepInInbox.count - 1000) }
            case (.unfile, true):
                data.messages.removeAll { ids.contains($0.id) }; folderAdd(f, msgs)
                data.keepInInbox.removeAll { ids.contains($0) }
            case (.markRead, false):
                if let list = folderMessages[k] { folderMessages[k] = list.map { var m = $0; if ids.contains(m.id) { m.unread = false }; return m } }
                adjustStats(k, unread: -wasUnread.count)
            case (.markRead, true):
                if let list = folderMessages[k] { folderMessages[k] = list.map { var m = $0; if wasUnread.contains(m.id) { m.unread = true }; return m } }
                adjustStats(k, unread: wasUnread.count)
            case (.file, _): break
            }
        }
        persistSoon()
    }

    private func adjustStats(_ k: String, total: Int = 0, unread: Int = 0) {
        guard var s = folderStats[k] else { return }
        s.total = max(0, s.total + total); s.unread = max(0, s.unread + unread); folderStats[k] = s
    }

    private func folderAdd(_ f: String, _ msgs: [MailMessage]) {
        let k = Folders.key(f)
        if var list = folderMessages[k] {
            let have = Set(list.map(\.id))
            list += msgs.filter { !have.contains($0.id) }
            folderMessages[k] = list.sorted { $0.date > $1.date }
        }
        adjustStats(k, total: msgs.count, unread: msgs.filter(\.unread).count)
    }

    private func folderRemove(_ f: String, _ msgs: [MailMessage]) {
        let k = Folders.key(f), ids = Set(msgs.map(\.id))
        folderMessages[k]?.removeAll { ids.contains($0.id) }
        adjustStats(k, total: -msgs.count, unread: -msgs.filter(\.unread).count)
    }

    private func remote(_ action: StackAction, _ msgs: [MailMessage], inverse: Bool, folder: String? = nil, container: MailContainer = .inbox) {
        if demo { return }
        pendingOps += 1
        Task {
            defer { pendingOps -= 1 }
            var failed = false
            for (account, group) in Deck.group(msgs) {
                guard let g = gmail(account) else { continue }
                let ids = group.map(\.id)
                do {
                    switch (container, action, inverse) {
                    case (_, .markRead, false): try await g.batchModify(ids, remove: ["UNREAD"])
                    case (_, .markRead, true): try await g.batchModify(group.filter(\.unread).map(\.id), add: ["UNREAD"])
                    case (_, .trash, _): try await g.trash(ids, undo: inverse)
                    case (.inbox, .archive, false): try await g.batchModify(ids, remove: ["INBOX"])
                    case (.inbox, .archive, true): try await g.batchModify(ids, add: ["INBOX"])
                    case (.inbox, .file, _):
                        guard let folder else { break }
                        let label = try await g.labelID(named: folder)
                        if inverse { try await g.batchModify(ids, add: ["INBOX"], remove: [label]) } else { try await g.batchModify(ids, add: [label], remove: ["INBOX"]) }
                    case (.folder(let f), .archive, _):
                        let label = try await g.labelID(named: f)
                        if inverse { try await g.batchModify(ids, add: [label]) } else { try await g.batchModify(ids, remove: [label]) }
                    case (.folder(let f), .unfile, _):
                        let label = try await g.labelID(named: f)
                        if inverse { try await g.batchModify(ids, add: [label], remove: ["INBOX"]) } else { try await g.batchModify(ids, add: ["INBOX"], remove: [label]) }
                    default: break
                    }
                } catch { failed = true; AppLog.error(error, context: "bulk \(action.rawValue)") }
            }
            if failed { AppModel.shared.show("Couldn't update Gmail for some messages. They'll reappear on the next refresh if so.", error: true) }
        }
    }

    func messages(ids: [String], in container: MailContainer = .inbox) -> [MailMessage] {
        let set = Set(ids)
        switch container {
        case .inbox: return data.messages.filter { set.contains($0.id) }
        case .folder(let f): return (folderMessages[Folders.key(f)] ?? []).filter { set.contains($0.id) }
        }
    }

    // MARK: Folders (Gmail labels that filing rules move mail into)

    var folderNames: [String] { Folders.names(rules: data.rules, order: data.folderOrder) }
    func folderStacks(_ name: String) -> [MailStack] { Folders.stacks(folderMessages[Folders.key(name)] ?? [], favourites: favourites) }
    func folderLoaded(_ name: String) -> Bool { folderMessages[Folders.key(name)] != nil }
    func folderUnread(_ name: String) -> Int {
        let k = Folders.key(name)
        return folderStats[k]?.unread ?? folderMessages[k]?.filter(\.unread).count ?? 0
    }
    func folderTotal(_ name: String) -> Int {
        let k = Folders.key(name)
        return folderStats[k]?.total ?? folderMessages[k]?.count ?? 0
    }
    func folderRules(_ name: String) -> [Rule] { data.rules.filter { $0.folder.map { Folders.key($0) == Folders.key(name) } ?? false } }
    func folderPaused(_ name: String) -> Bool { let r = folderRules(name); return !r.isEmpty && r.allSatisfy { !$0.enabled } }

    func setFolderFiling(_ name: String, enabled: Bool) {
        let k = Folders.key(name)
        for i in data.rules.indices where data.rules[i].folder.map({ Folders.key($0) == k }) ?? false { data.rules[i].enabled = enabled }
        persistSoon()
        AppModel.shared.show(enabled ? "Filing into “\(name)” resumed" : "Filing into “\(name)” paused. Mail already there stays.")
    }

    /// Puts `name` before `target` (or last when nil). The order is saved with the rest of the data.
    func moveFolder(_ name: String, before target: String?) {
        data.folderOrder = Folders.moved(name, before: target, in: folderNames); persistSoon()
    }
    func shiftFolder(_ name: String, by offset: Int) {
        data.folderOrder = Folders.shifted(name, by: offset, in: folderNames); persistSoon()
    }

    /// Counts for the sidebar: one cheap Gmail call per folder and account, at most every five minutes unless forced.
    func refreshFolders(force: Bool = false) async {
        let names = folderNames
        guard !demo, hasAccount, !names.isEmpty, force || Date().timeIntervalSince(folderStatsAt) > 300 else { return }
        folderStatsAt = Date()
        for _ in 0..<20 where pendingOps > 0 { try? await Task.sleep(for: .milliseconds(500)) }   // let filing finish so the counts include it
        var next: [String: FolderStats] = [:]
        for name in names {
            let k = Folders.key(name)
            var s = FolderStats(), ok = true
            for acct in data.accounts {
                guard let g = gmail(acct.email) else { continue }
                do { if let id = try await g.existingLabelID(named: name) { let c = try await g.labelStats(id); s.total += c.total; s.unread += c.unread } }
                catch { ok = false; logFolderError(error, "folder stats") }
            }
            next[k] = ok ? s : (folderStats[k] ?? s)
        }
        folderStats = next
    }

    /// Reads the newest `limit` messages per account under the folder's label. What is already here is kept, not fetched again.
    func loadFolder(_ name: String, limit: Int = 100) async {
        let k = Folders.key(name)
        guard !demo, hasAccount, !folderLoading.contains(k) else { return }
        folderLoading.insert(k); defer { folderLoading.remove(k) }
        let old = folderMessages[k] ?? []
        var all: [MailMessage] = []
        var stats = FolderStats(), statsOK = true
        for acct in data.accounts {
            let mine = old.filter { $0.account == acct.email }
            guard let g = gmail(acct.email) else { all += mine; continue }
            do {
                guard let id = try await g.existingLabelID(named: name) else { continue }
                let r = try await g.labelMessages(labelID: id, limit: limit, skip: Set(mine.map(\.id)))
                let still = Set(r.ids)
                all += mine.filter { still.contains($0.id) } + r.fresh
                let c = try await g.labelStats(id); stats.total += c.total; stats.unread += c.unread
            } catch { all += mine; statsOK = false; logFolderError(error, "load folder") }
        }
        folderMessages[k] = all.sorted { $0.date > $1.date }
        if statsOK { folderStats[k] = stats }
    }

    /// An action on everything in a folder (the newest 300 per account). Undoable like any other bulk action.
    @discardableResult
    func folderBulk(_ action: StackAction, in name: String) async -> Int {
        let k = Folders.key(name)
        for _ in 0..<50 where folderLoading.contains(k) { try? await Task.sleep(for: .milliseconds(200)) }
        await loadFolder(name, limit: 300)
        let all = folderMessages[k] ?? []
        let targets = action == .markRead ? all.filter(\.unread) : all
        guard !targets.isEmpty else { AppModel.shared.show(action == .markRead ? "Nothing unread in “\(name)”" : "“\(name)” is empty"); return 0 }
        apply(action, to: targets, container: .folder(name))
        return targets.count
    }

    @discardableResult
    func renameFolder(_ old: String, to raw: String) async -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines), ok = Folders.key(old), nk = Folders.key(name)
        guard !name.isEmpty, name.count <= 100 else { AppModel.shared.show("Give the folder a name of up to 100 characters.", error: true); return false }
        if name == old { return true }
        if nk != ok, folderNames.contains(where: { Folders.key($0) == nk }) { AppModel.shared.show("There is already a folder called “\(name)”.", error: true); return false }
        if !demo {
            do {
                for acct in data.accounts {
                    guard let g = gmail(acct.email), let id = try await g.existingLabelID(named: old) else { continue }
                    try await g.renameLabel(id, from: old, to: name)
                }
            } catch {
                logFolderError(error, "rename folder")
                AppModel.shared.show("Couldn't rename the folder in Gmail. Is there already a label with that name?", error: true); return false
            }
        }
        for i in data.rules.indices where data.rules[i].folder.map({ Folders.key($0) == ok }) ?? false { data.rules[i].action = .file(name) }
        data.folderOrder = Folders.names(rules: data.rules, order: data.folderOrder.map { Folders.key($0) == ok ? name : $0 })
        if nk != ok {
            folderMessages[nk] = folderMessages.removeValue(forKey: ok)
            folderStats[nk] = folderStats.removeValue(forKey: ok)
        }
        if Nav.shared.folder.map({ Folders.key($0) == ok }) ?? false { Nav.shared.folder = name }
        StackModel.shared.folderRenamed(from: old, to: name)
        persistSoon()
        AppModel.shared.show("Renamed to “\(name)”")
        return true
    }

    /// Deletes the folder's Gmail label and the rules that fill it. What happens to the mail is the caller's choice. This cannot be undone.
    func deleteFolder(_ name: String, mode: FolderDeletion) async {
        let k = Folders.key(name)
        if !demo {
            do {
                for acct in data.accounts {
                    guard let g = gmail(acct.email), let id = try await g.existingLabelID(named: name) else { continue }
                    switch mode {
                    case .keepMail: break
                    case .toInbox: let ids = try await g.labelIDs(id); try await g.batchModify(ids, add: ["INBOX"], remove: [id])
                    case .trashMail: try await g.trash(try await g.labelIDs(id))
                    }
                    try await g.deleteLabel(id, named: name)
                }
            } catch {
                logFolderError(error, "delete folder")
                AppModel.shared.show("Couldn't finish deleting “\(name)”. Nothing else was changed; try again.", error: true); return
            }
        }
        data.rules.removeAll { $0.folder.map { Folders.key($0) == k } ?? false }
        data.folderOrder.removeAll { Folders.key($0) == k }
        folderMessages[k] = nil; folderStats[k] = nil
        if Nav.shared.pane == .folder, Nav.shared.folder.map({ Folders.key($0) == k }) ?? false { Nav.shared.pane = .priority; Nav.shared.open = nil }
        StackModel.shared.folderDeleted(name)
        persistSoon()
        let said: String
        switch mode {
        case .keepMail: said = "Deleted “\(name)”. The emails are still in All Mail."
        case .toInbox: said = "Deleted “\(name)” and returned its emails to the inbox."
        case .trashMail: said = "Deleted “\(name)” and moved its emails to Trash."
        }
        AppModel.shared.show(said)
        if mode == .toInbox { await sync() }
    }

    // MARK: Reading: cleaned text and briefs

    func cleanedText(_ m: MailMessage) async -> CleanedMail { MailText.clean(await fullText(m)) }

    func cachedBrief(_ id: String) -> MailBrief? {
        if !briefsLoaded { briefsLoaded = true; if !demo { briefs = briefStore.load() } }
        return briefs[id]
    }

    /// One brief per message, made only when asked for (opening a longer message), then kept on this Mac.
    func brief(for m: MailMessage, cleaned: CleanedMail, force: Bool = false) async throws -> MailBrief {
        if !force, let b = cachedBrief(m.id) { return b }
        if demo { return Demo.briefs[m.id] ?? MailText.localBrief(cleaned) }
        if !ClaudeDrafter.available { return MailText.localBrief(cleaned) }
        let thread = "From: \(m.displayName) <\(m.fromEmail)>\nSubject: \(m.subject)\n\n\(cleaned.plain)"
        var b = try await ClaudeDrafter.brief(thread: thread)
        if b.dates.isEmpty { b.dates = MailText.detectDates(cleaned.plain) }
        briefs[m.id] = b
        try? briefStore.save(briefs)
        return b
    }

    // MARK: Claude drafting and sending

    func draftWithClaude(_ m: MailMessage, tone: DraftTone, extra: String = "", quotes: [String] = []) async throws -> String {
        let extra = quotes.isEmpty ? extra : (extra.isEmpty ? "" : extra + "\n\n") + "The user is replying to these passages in particular, so address them directly:\n" + quotes.map { "\"" + MailText.excerpt($0, 600) + "\"" }.joined(separator: "\n")
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
    func queueNew(account: String, to: String, cc: String = "", bcc: String = "", subject: String, body: String, attachments: [MailAttachment] = [], undoSeconds: Int, byAgent: Bool, signature: Bool = true) async throws -> PendingSend {
        try await queueSend(account: account, to: to, cc: cc, bcc: bcc, subject: subject, body: body, attachments: attachments, threadId: nil, inReplyTo: nil, references: nil, undoSeconds: undoSeconds, byAgent: byAgent, signature: signature, onSent: nil)
    }

    private func queueSend(account: String, to: String, cc: String = "", bcc: String = "", subject: String, body: String, attachments: [MailAttachment] = [], threadId: String?, inReplyTo: String?, references: String?,
                           undoSeconds: Int, byAgent: Bool, signature: Bool = true, onSent: (() -> Void)?) async throws -> PendingSend {
        guard let g = gmail(account) else { throw UserFacingError("That account isn't connected any more.") }
        let draft = try await g.createDraft(to: to, subject: subject, body: body + (!signature || data.sendSignature.isEmpty ? "" : "\n\n" + data.sendSignature),
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


    /// A message from the inbox, or from any folder that has been loaded.
    private func message(_ id: String) -> MailMessage? {
        data.messages.first { $0.id == id } ?? folderMessages.values.lazy.compactMap { $0.first { $0.id == id } }.first
    }

    /// Splits message ids by where they live, so one bulk action can cover the inbox and folders alike.
    private func located(_ ids: [String]) -> [(container: MailContainer, messages: [MailMessage])] {
        var out: [(MailContainer, [MailMessage])] = []
        let inbox = messages(ids: ids)
        if !inbox.isEmpty { out.append((.inbox, inbox)) }
        for name in folderNames {
            let msgs = messages(ids: ids, in: .folder(name))
            if !msgs.isEmpty { out.append((.folder(name), msgs)) }
        }
        return out
    }

    private struct FolderOut: Encodable { let name: String; let position: Int; let inSidebar: Bool; let emails: Int; let unread: Int; let filingPaused: Bool; let rules: [String] }
    private struct FolderMsgOut: Encodable { let id, subject, snippet, account, date: String; let unread: Bool }
    private struct FolderStackOut: Encodable { let sender, name: String; let unread: Int; let messages: [FolderMsgOut] }

    private func jsonText<T: Encodable>(_ v: T) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? e.encode(v)) ?? Data(), as: UTF8.self)
    }

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
        case "get_clean_text":
            guard let id = str("message_id"), let m = message(id) else { return fail("Unknown message_id. Use list_stacks to find ids.") }
            let c = await cleanedText(m)
            return ok("From: \(m.displayName) <\(m.fromEmail)>\nSubject: \(m.subject)\n\n\(String(c.plain.prefix(6000)))\(c.footer.isEmpty ? "" : "\n\n[footer folded: \(c.footer.count) blocks]")\(await unsubscribeOption(for: m).map { "\n\nUnsubscribe available: \($0.summary). Use unsubscribe or block_sender." } ?? "")\(c.links.isEmpty ? "" : "\n\nLinks:\n" + c.links.prefix(10).map { "- \($0.label)\($0.tracker ? " (tracking)" : ""): \($0.url)" }.joined(separator: "\n"))")
        case "get_brief":
            guard let id = str("message_id"), let m = message(id) else { return fail("Unknown message_id. Use list_stacks to find ids.") }
            let c = await cleanedText(m)
            do { return ok(try await brief(for: m, cleaned: c, force: (a["refresh"] as? Bool) == true).text) }
            catch { AppLog.error(error, context: "agent brief"); return fail((error as? UserFacingError)?.message ?? "Couldn't write the brief.") }
        case "archive_many", "trash_many":
            guard let ids = a["message_ids"] as? [String], !ids.isEmpty else { return fail("Missing message_ids.") }
            let groups = located(Array(ids.prefix(500)))
            guard !groups.isEmpty else { return fail("None of those message ids are in the inbox or in a loaded folder.") }
            let act: StackAction = tool == "trash_many" ? .trash : .archive
            let count = groups.reduce(0) { $0 + $1.messages.count }
            for g in groups { apply(act, to: g.messages, container: g.container) }
            return ok("\(act.summary(count: count, sender: nil)). The user can press Undo in Moose; \(act == .trash ? "Trash keeps mail for 30 days." : "mail stays in All Mail (mail in a folder leaves that folder).")")
        case "unfile_many":
            guard let ids = a["message_ids"] as? [String], !ids.isEmpty else { return fail("Missing message_ids.") }
            let groups = located(Array(ids.prefix(500))).filter { if case .folder = $0.container { true } else { false } }
            guard !groups.isEmpty else { return fail("None of those message ids are in a loaded folder. Use list_folder first.") }
            let count = groups.reduce(0) { $0 + $1.messages.count }
            for g in groups { apply(.unfile, to: g.messages, container: g.container) }
            return ok("Moved \(count) to the inbox. Filing rules will leave them there. The user can press Undo in Moose.")
        case "list_microphones":
            struct MicOut: Encodable { let name: String; let uid: String; let iPhone: Bool; let builtIn: Bool; let selected: Bool }
            let chosen = Prefs.shared.microphone
            let used = Microphones.resolve(chosen)
            return ok(jsonText(["setting": chosen.isEmpty ? "automatic" : chosen, "lidClosed": Microphones.lidClosed() ? "true" : "false", "dictationWillUse": used?.name ?? "the system default microphone"]) + "\n" +
                      jsonText(Microphones.all().map { MicOut(name: $0.name, uid: $0.uid, iPhone: $0.isPhone, builtIn: $0.isBuiltIn, selected: $0.uid == used?.uid) }))
        case "set_microphone":
            let want = str("microphone") ?? "automatic"
            if want.lowercased() == "automatic" { Prefs.shared.microphone = Microphones.automatic; return ok("Dictation microphone: automatic (the system choice, or a nearby iPhone when the lid is closed).") }
            guard let m = Microphones.all().first(where: { $0.uid == want || $0.name.caseInsensitiveCompare(want) == .orderedSame }) else { return fail("No such microphone right now. Use list_microphones; a phone must be nearby to appear.") }
            Prefs.shared.microphone = m.uid
            return ok("Dictation will use \(m.name).")
        case "list_folders":
            await refreshFolders(force: true)
            let names = folderNames
            return ok(jsonText(names.enumerated().map { i, n in
                FolderOut(name: n, position: i + 1, inSidebar: i < Folders.visibleCount, emails: folderTotal(n), unread: folderUnread(n), filingPaused: folderPaused(n), rules: folderRules(n).map(\.title))
            }))
        case "list_folder":
            guard let n = str("name"), let name = folderNames.first(where: { Folders.key($0) == Folders.key(n) }) else { return fail("Unknown folder. Use list_folders to see the names.") }
            await loadFolder(name, limit: min(max((a["limit"] as? Int) ?? 50, 1), 100))
            let unreadOnly = (a["unread_only"] as? Bool) ?? false
            let stacks = folderStacks(name).prefix(min(max((a["max_stacks"] as? Int) ?? 20, 1), 50)).map { s -> FolderStackOut in
                let msgs = s.messages.map(\.message).filter { !unreadOnly || $0.unread }
                return FolderStackOut(sender: s.key, name: s.name, unread: s.unreadCount, messages: msgs.prefix(10).map {
                    FolderMsgOut(id: $0.id, subject: $0.subject, snippet: MailText.excerpt($0.snippet, 200), account: $0.account, date: ISO8601DateFormatter().string(from: $0.date), unread: $0.unread) })
            }.filter { !$0.messages.isEmpty }
            return ok(jsonText(Array(stacks)))
        case "folder_action":
            guard let n = str("name"), let name = folderNames.first(where: { Folders.key($0) == Folders.key(n) }) else { return fail("Unknown folder. Use list_folders to see the names.") }
            let act: StackAction
            switch str("action") {
            case "mark_read": act = .markRead
            case "move_to_inbox": act = .unfile
            case "clear": act = .archive
            case "empty": act = .trash
            default: return fail("action must be mark_read, move_to_inbox, clear or empty.")
            }
            let n2 = await folderBulk(act, in: name)
            guard n2 > 0 else { return ok("Nothing to do in “\(name)”.") }
            let what = ["mark_read": "Marked \(n2) read", "move_to_inbox": "Moved \(n2) to the inbox", "clear": "Removed \(n2) from the folder (still in All Mail)", "empty": "Moved \(n2) to Gmail Trash (30 days)"][str("action") ?? ""] ?? "Done"
            return ok("\(what) in “\(name)”. Acts on the newest 300 per account; call again if the folder has more. The user can press Undo in Moose.")
        case "rename_folder":
            guard let n = str("name"), let name = folderNames.first(where: { Folders.key($0) == Folders.key(n) }), let new = str("new_name") else { return fail("Needs name (an existing folder) and new_name.") }
            return await renameFolder(name, to: new) ? ok("Renamed “\(name)” to “\(new)”. The filing rule now files into the new name.") : fail("Couldn't rename it. The new name may already exist in Gmail.")
        case "move_folder":
            guard let n = str("name"), let name = folderNames.first(where: { Folders.key($0) == Folders.key(n) }) else { return fail("Unknown folder. Use list_folders to see the names.") }
            if let b = str("before") {
                guard let target = folderNames.first(where: { Folders.key($0) == Folders.key(b) }) else { return fail("Unknown folder in `before`.") }
                moveFolder(name, before: target)
            } else if let p = a["position"] as? Int {
                let rest = folderNames.filter { Folders.key($0) != Folders.key(name) }
                moveFolder(name, before: p - 1 < rest.count ? rest[max(0, p - 1)] : nil)
            } else { return fail("Give `before` (a folder name) or `position` (1 = first).") }
            return ok("Folder order: " + folderNames.joined(separator: ", ") + ". The first \(Folders.visibleCount) show in the sidebar; the rest are wrapped under “more”.")
        case "set_folder_filing":
            guard let n = str("name"), let name = folderNames.first(where: { Folders.key($0) == Folders.key(n) }), let on = a["on"] as? Bool else { return fail("Needs name and on (true to resume filing, false to pause).") }
            setFolderFiling(name, enabled: on)
            return ok(on ? "Filing into “\(name)” resumed." : "Filing into “\(name)” paused. Mail already there stays.")
        case "delete_folder":
            guard let n = str("name"), let name = folderNames.first(where: { Folders.key($0) == Folders.key(n) }) else { return fail("Unknown folder. Use list_folders to see the names.") }
            let mode: FolderDeletion
            switch str("mode") {
            case "keep_mail": mode = .keepMail
            case "to_inbox": mode = .toInbox
            case "trash_mail": mode = .trashMail
            default: return fail("mode must be keep_mail, to_inbox or trash_mail.")
            }
            let effect = ["keep_mail": "The emails stay in All Mail.", "to_inbox": "The emails return to the inbox.", "trash_mail": "The emails move to Gmail Trash."][str("mode") ?? ""] ?? ""
            guard await Approval.ask(title: "An agent wants to delete the folder “\(name)”", detail: "\(folderTotal(name)) emails are labelled “\(name)”. The Gmail label and the filing rule are removed and this cannot be undone. \(effect)", confirm: "Delete folder", decline: "Don't delete") else {
                return fail("The user declined, or didn't answer in time. Nothing was deleted.")
            }
            await deleteFolder(name, mode: mode)
            return ok("Deleted “\(name)”. \(effect)")
        case "undo": guard canUndo else { return fail("Nothing to undo.") }; undo(); return ok("Undone.")
        case "mark_read": guard let id = str("message_id"), let m = message(id) else { return fail("Unknown message_id.") }; markRead(m); return ok("Marked read.")
        case "archive": guard let id = str("message_id"), let m = message(id) else { return fail("Unknown message_id.") }; archive(m); return ok("Archived.")
        case "set_favourite":
            guard let e = str("sender")?.lowercased() else { return fail("Missing sender.") }
            let on = (a["on"] as? Bool) ?? true
            if on != favourites.contains(e) { toggleFavourite(e) }
            return ok(on ? "\(e) is now a favourite." : "\(e) is no longer a favourite.")
        case "unsubscribe_info":
            guard let id = str("message_id"), let m = message(id) else { return fail("Unknown message_id.") }
            guard let o = await unsubscribeOption(for: m) else { return ok("No unsubscribe option. This sender doesn't offer one; use block_sender to silence them.") }
            return ok("Unsubscribe is available: \(o.summary).\nSender: \(m.fromEmail)\(isBlocked(m.fromEmail) ? "\nAlready blocked." : "")")
        case "unsubscribe":
            guard let id = str("message_id"), let m = message(id) else { return fail("Unknown message_id.") }
            guard let o = await unsubscribeOption(for: m) else { return fail("This sender offers no unsubscribe option. Use block_sender instead.") }
            switch SendPolicy.decide(access) {
            case .refuse(let why): return fail(why)
            case .askUser:
                guard await confirmUnsubscribe(m, o, byAgent: true) else { return fail("The user declined, or didn't answer in time. Nothing was sent.") }
            case .sendAfterUndo: break
            }
            do { return ok(try await unsubscribe(m, o)) }
            catch { AppLog.error(error, context: "agent unsubscribe"); return fail((error as? UserFacingError)?.message ?? "Couldn't unsubscribe.") }
        case "block_sender":
            guard let e = (str("sender") ?? str("message_id").flatMap { message($0)?.fromEmail })?.lowercased(), e.contains("@") else { return fail("Give a sender email address, or a message_id.") }
            let n = blockSender(e)
            return ok("Blocked \(e)\(n > 0 ? " and archived \(n) in the inbox" : ""). New mail from them is archived on every sync. Undo with undo_last, or remove the block with delete_rule.")
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
                if let b = str("body") { body = b } else { body = try await draftWithClaude(m, tone: DraftTone(rawValue: str("tone") ?? "") ?? .normal, extra: str("guidance") ?? "", quotes: str("quote").map { [$0] } ?? []) }
                let quoted = str("quote").map { MailText.withQuotes(body, quotes: [$0], sender: m.displayName, date: m.date) } ?? body
                let d = try await saveDraftOnly(to: m, body: quoted, cc: cc)
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
                do { _ = try await queueReply(to: m, body: body, cc: cc, undoSeconds: data.undoSeconds, byAgent: true); AppLog.info("agent send queued"); return ok("Queued. Sends in \(data.undoSeconds) s unless the user cancels.") }
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
    static func ask(title: String, detail: String, confirm: String = "Send", decline: String = "Don't send", timeout: TimeInterval = 120) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: confirm); alert.addButton(withTitle: decline)
        alert.buttons[1].keyEquivalent = "\r"; alert.buttons[0].keyEquivalent = ""   // Return = the safe choice
        let timer = Task { try? await Task.sleep(for: .seconds(timeout)); if !Task.isCancelled { NSApp.abortModal() } }
        let r = alert.runModal()
        timer.cancel()
        return r == .alertFirstButtonReturn
    }
}
