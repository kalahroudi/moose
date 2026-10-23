// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import MooseKit

enum Fmt {
    static func time(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if d > Date().addingTimeInterval(-6 * 86400) { return d.formatted(.dateTime.weekday(.abbreviated)) }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
    static func scoreColor(_ s: Int) -> Color { s >= 80 ? Theme.danger : s >= 60 ? Theme.warn : .secondary }
}

/// One of the four stack views: Priority, Favourites, Everything else, Muted.
struct StackListPane: View {
    let pane: Pane
    let mail = MailModel.shared
    let nav = Nav.shared
    @State private var unreadOnly = true
    @State private var query = ""

    private var stacks: [MailStack] {
        var s = mail.stacks(pane.mailView!, unreadOnly: unreadOnly && pane == .priority)
        if let a = nav.account { s = s.compactMap { st in let m = st.messages.filter { $0.message.account == a }; return m.isEmpty ? nil : MailStack(key: st.key, name: st.name, messages: m, favourite: st.favourite) } }
        let q = query.lowercased()
        if !q.isEmpty { s = s.filter { $0.name.lowercased().contains(q) || $0.key.contains(q) || $0.messages.contains { $0.message.subject.lowercased().contains(q) } } }
        return s
    }

    private var subtitle: String {
        let n = stacks.count
        let parts = ["\(n) \(n == 1 ? "stack" : "stacks")", nav.account ?? "\(mail.accounts.count) \(mail.accounts.count == 1 ? "account" : "accounts")"]
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: pane.title, subtitle: subtitle) {
                HStack(spacing: 8) {
                    if pane == .priority { Segmented(options: [(true, "Unread"), (false, "All")], selection: $unreadOnly) }
                    SearchBox(prompt: "Search", text: $query).frame(minWidth: 90, idealWidth: 170, maxWidth: 170)
                    Button("Stack") { AppDelegate.shared.showStack() }.buttonStyle(Pill()).help("Go through priority mail one card at a time  ⌘T")
                    Button { Task { await mail.sync() } } label: { Image(systemName: "arrow.clockwise").rotationEffect(.degrees(mail.syncing ? 180 : 0)) }
                        .buttonStyle(Pill()).disabled(mail.syncing).help("Check for new mail").accessibilityLabel("Check for new mail")
                }
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(stacks) { StackCard(stack: $0) }
                    if stacks.isEmpty { empty }
                }.padding(16)
            }
            if pane == .priority, !mail.mutedSummary().isEmpty {
                Divider()
                mutedLine.padding(.horizontal, 16)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: pane.symbol).font(.system(size: 22)).foregroundStyle(.secondary)
            Text(pane == .priority ? "Nothing needs you right now." : pane == .favourites ? "No favourites yet. Click the star on any sender." : "Nothing here.").font(.system(size: 13)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.top, 50)
    }

    private var mutedLine: some View {
        let s = mail.mutedSummary()
        return Button { nav.pane = .muted } label: {
            HStack(spacing: 8) {
                Image(systemName: "bell.slash").foregroundStyle(.secondary)
                Text("\(s.reduce(0) { $0 + $1.1 }) muted · " + s.map { "\($0.1) \($0.0.label)" }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(); Text("Review").font(.system(size: 12)).foregroundStyle(Theme.accent)
            }.padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct StackCard: View {
    let stack: MailStack
    let mail = MailModel.shared
    let nav = Nav.shared
    @State private var expanded = false
    private var shown: [ScoredMessage] { expanded ? stack.messages : Array(stack.messages.prefix(3)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(shown) { m in
                Divider().opacity(0.6)
                MessageRow(item: m, showFrom: false, showAccount: mail.accounts.count > 1)
            }
            if stack.messages.count > 3 {
                Divider().opacity(0.6)
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Text(expanded ? "Show less" : "\(stack.messages.count - 3) more").font(.system(size: 12)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 7).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.hairline))
        .background(alignment: .bottom) {   // the "stack": a second card peeking out underneath
            if stack.messages.count > 1 {
                RoundedRectangle(cornerRadius: 11).fill(Theme.card).overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.hairline)).padding(.horizontal, 10).offset(y: 5)
            }
        }
        .padding(.bottom, stack.messages.count > 1 ? 5 : 0)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { mail.toggleFavourite(stack.key) } label: {
                Image(systemName: stack.favourite ? "star.fill" : "star").foregroundStyle(stack.favourite ? Theme.accent : .secondary).padding(4).contentShape(Rectangle())
            }.buttonStyle(.plain).help(stack.favourite ? "Remove from favourites" : "Make a favourite").accessibilityLabel("Favourite")
            Text(stack.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text("\(stack.messages.count) \(stack.messages.count == 1 ? "message" : "messages")").font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(stack.why).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }.padding(.horizontal, 10).padding(.vertical, 7)
    }
}

struct MessageRow: View {
    let item: ScoredMessage
    var showFrom = true
    var showAccount = false
    let mail = MailModel.shared
    @State private var hover = false

    var body: some View {
        let m = item.message
        Button { Nav.shared.open = m; mail.markRead(m) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(item.score)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Fmt.scoreColor(item.score)).frame(width: 26, alignment: .trailing)
                if showFrom { Text(m.displayName).font(.system(size: 13, weight: m.unread ? .semibold : .regular)).lineLimit(1).frame(width: 110, alignment: .leading) }
                (Text(m.subject).fontWeight(m.unread ? .semibold : .regular) + Text("  " + MailText.excerpt(m.snippet, 140)).foregroundColor(.secondary))
                    .font(.system(size: 13)).lineLimit(1).foregroundStyle(m.unread ? Color.primary : .secondary)
                Spacer(minLength: 8)
                if showAccount { Circle().fill(mail.accountColor(m.account)).frame(width: 6, height: 6) }
                Text(Fmt.time(m.date)).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(hover ? Theme.fill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Mark as read") { mail.markRead(m) }
            Button("Archive") { mail.archive(m) }
            Divider()
            Button("Mute \(m.fromEmail)") { mail.muteSender(m.fromEmail) }
        }
    }
}

/// Reading one message and replying to it. The reply text is saved as you type, so a quit or crash never loses it.
struct ThreadView: View {
    let message: MailMessage
    let mail = MailModel.shared
    @State private var text: String = ""
    @State private var reply: String = ""
    @State private var drafting = false
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: message.subject, subtitle: "\(message.displayName) · \(message.account) · \(Fmt.time(message.date))") {
                HStack(spacing: 8) {
                    Button { mail.toggleFavourite(message.fromEmail) } label: { Image(systemName: mail.favourites.contains(message.fromEmail) ? "star.fill" : "star") }.buttonStyle(Pill()).help("Favourite sender")
                    Button { mail.muteSender(message.fromEmail); Nav.shared.open = nil } label: { Image(systemName: "bell.slash") }.buttonStyle(Pill()).help("Mute sender")
                    Button { mail.archive(message); Nav.shared.open = nil } label: { Image(systemName: "archivebox") }.buttonStyle(Pill()).help("Archive")
                    Button("Back") { Nav.shared.open = nil }.buttonStyle(Pill()).keyboardShortcut(.escape, modifiers: [])
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(text.isEmpty ? message.snippet : text).font(.system(size: 13.5)).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).card(padding: 16)
                    replyBox
                }.padding(16)
            }
        }
        .task(id: message.id) {
            reply = mail.data.composeDrafts[message.id] ?? ""
            text = await mail.fullText(message)
        }
    }

    private var replyBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Reply").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                Spacer()
                if ClaudeDrafter.available {
                    ForEach(DraftTone.allCases, id: \.self) { tone in
                        Button(tone.label == "Draft" ? "Draft with Claude" : tone.label) { draft(tone) }.buttonStyle(Pill(kind: tone == .normal ? .primary : .plain)).disabled(drafting)
                    }
                } else {
                    Text("Install Claude Code in Settings to draft replies").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $reply).font(.system(size: 13.5)).scrollContentBackground(.hidden).frame(minHeight: 120)
                    .onChange(of: reply) { _, v in mail.setCompose(message.id, v) }
                if reply.isEmpty { Text(drafting ? "Claude is writing…" : "Write a reply, or let Claude draft one.").foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
            }.padding(8).background(Theme.pane, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
            HStack {
                if let n = note { Text(n).font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button("Save draft") { saveDraft() }.buttonStyle(Pill()).disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Send  ⌘↩") { send() }.buttonStyle(Pill(kind: .primary)).keyboardShortcut(.return, modifiers: .command)
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.card(padding: 14)
    }

    private func draft(_ tone: DraftTone) {
        drafting = true; note = nil
        let extra = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { drafting = false }
            do { reply = try await mail.draftWithClaude(message, tone: tone, extra: extra); note = "Drafted by Claude. Edit before sending." }
            catch { AppLog.error(error, context: "claude draft"); AppModel.shared.show(UserError.message(for: error, action: "Draft the reply"), error: true) }
        }
    }

    private func saveDraft() {
        Task {
            do { _ = try await mail.saveDraftOnly(to: message, body: reply); note = "Saved in your Gmail drafts." }
            catch { AppLog.error(error, context: "save draft"); AppModel.shared.show(UserError.message(for: error, action: "Save the draft"), error: true) }
        }
    }

    private func send() {
        let body = reply
        Task {
            do { _ = try await mail.queueReply(to: message, body: body, undoSeconds: 5, byAgent: false); reply = ""; mail.setCompose(message.id, ""); Nav.shared.open = nil }
            catch { AppLog.error(error, context: "send reply"); AppModel.shared.show(UserError.message(for: error, action: "Send the reply"), error: true) }
        }
    }
}
