// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import MooseKit

/// The alarm button in the reader: snooze this message, or be reminded if nobody replies.
struct RemindMenu: View {
    let message: MailMessage
    var afterSnooze: () -> Void = {}
    let mail = MailModel.shared
    @State private var picking: FollowUpKind?
    @State private var date = FollowUps.dueAfter(days: 1)

    private var existing: FollowUp? {
        mail.data.followUps.first { $0.message.id == message.id || ($0.kind == .awaitingReply && $0.message.threadId == message.threadId && $0.message.account == message.account) }
    }

    var body: some View {
        Menu {
            Section("Snooze until") {
                ForEach(FollowUps.presets()) { p in Button("\(p.label)  ·  \(FollowUps.describe(p.date))") { snooze(p.date) } }
                Button("Pick a date…") { date = FollowUps.dueAfter(days: 1); picking = .snooze }
            }
            Section("Remind me if no reply in") {
                ForEach(FollowUps.replyDays, id: \.self) { d in Button(d == 1 ? "1 day" : "\(d) days") { remindIfQuiet(FollowUps.dueAfter(days: d)) } }
                Button("Pick a date…") { date = FollowUps.dueAfter(days: 3); picking = .awaitingReply }
            }
            if let f = existing {
                Divider()
                Button("Clear reminder (\(f.kind == .snooze ? "snoozed" : "waiting for a reply"), \(FollowUps.describe(f.due)))") { mail.completeFollowUp(f.id) }
            }
        } label: { Image(systemName: existing == nil ? "alarm" : "alarm.fill") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Snooze, or remind me if nobody replies").accessibilityLabel("Remind me")
            .popover(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } })) { picker }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(picking == .snooze ? "Snooze until" : "Remind me if no reply by").font(.system(size: 13, weight: .semibold))
            DatePicker("", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute]).datePickerStyle(.graphical).labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { picking = nil }.buttonStyle(Pill())
                Button("Set reminder") {
                    let kind = picking; picking = nil
                    if kind == .snooze { snooze(date) } else { remindIfQuiet(date) }
                }.buttonStyle(Pill(kind: .primary))
            }
        }.padding(14).frame(width: 280)
    }

    private func snooze(_ when: Date) {
        let f = mail.snooze(message, until: when)
        AppModel.shared.show("Snoozed until \(FollowUps.describe(when))", actionTitle: "Undo") { mail.completeFollowUp(f.id) }
        afterSnooze()
    }

    private func remindIfQuiet(_ when: Date) {
        let f = mail.remindIfNoReply(message, at: when)
        AppModel.shared.show("I'll remind you \(FollowUps.describe(when)) if nobody has replied", actionTitle: "Undo") { mail.completeFollowUp(f.id) }
    }
}

/// Everything with a reminder: what is due now, then what is still ahead.
struct FollowUpsPane: View {
    let mail = MailModel.shared
    let nav = Nav.shared

    private var items: [FollowUp] { mail.data.followUps.filter { nav.account == nil || $0.message.account == nav.account } }

    var body: some View {
        let due = FollowUps.due(items), ahead = FollowUps.waiting(items)
        VStack(spacing: 0) {
            PaneHeader(title: "Follow up", subtitle: subtitle(due.count, ahead.count))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if items.isEmpty { empty }
                    if !due.isEmpty { section("Needs you now", due) }
                    if !ahead.isEmpty { section("Coming up", ahead) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { nav.list.order = [] }   // no previous / next stepping through a list that is not on screen
    }

    private func subtitle(_ due: Int, _ ahead: Int) -> String {
        if due + ahead == 0 { return nav.account ?? "Nothing to chase" }
        return [due > 0 ? "\(due) due" : nil, ahead > 0 ? "\(ahead) coming up" : nil, nav.account].compactMap { $0 }.joined(separator: " · ")
    }

    private func section(_ title: String, _ list: [FollowUp]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title).padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { Divider().opacity(0.6) }
                    FollowUpRow(item: f)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.hairline))
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "alarm").font(.system(size: 22)).foregroundStyle(.secondary)
            Text("No reminders.").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Open a message and press the alarm to snooze it, or to be reminded if nobody replies.").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.top, 50)
    }
}

private struct FollowUpRow: View {
    let item: FollowUp
    let mail = MailModel.shared
    @State private var hover = false

    private var what: String {
        switch (item.kind, item.isDue()) {
        case (.snooze, true): "Snoozed, back now"
        case (.snooze, false): "Snoozed until \(FollowUps.describe(item.due))"
        case (.awaitingReply, true): "No reply since \(Fmt.time(item.created))"
        case (.awaitingReply, false): "Waiting for a reply, reminds you \(FollowUps.describe(item.due))"
        }
    }

    var body: some View {
        let m = item.message
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: item.kind == .snooze ? "moon.zzz" : "arrowshape.turn.up.left").font(.system(size: 13)).foregroundStyle(item.isDue() ? Theme.accent : .secondary).frame(width: 20)
            Button { Nav.shared.open = m; mail.markRead(m) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(m.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if mail.accounts.count > 1 { Circle().fill(mail.accountColor(m.account)).frame(width: 6, height: 6) }
                    }
                    Text(m.subject).font(.system(size: 13)).lineLimit(1)
                    Text(what).font(.system(size: 11.5)).foregroundStyle(item.isDue() ? Theme.warn : .secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                ForEach(FollowUps.presets()) { p in Button("\(p.label)  ·  \(FollowUps.describe(p.date))") { mail.reschedule(item.id, to: p.date) } }
                ForEach([1, 3, 7], id: \.self) { d in Button("In \(d == 1 ? "1 day" : "\(d) days")") { mail.reschedule(item.id, to: FollowUps.dueAfter(days: d)) } }
            } label: { Text("Later") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Move this reminder")
            Button(item.isDue() ? "Done" : "Clear") { mail.completeFollowUp(item.id) }.buttonStyle(Pill(kind: item.isDue() ? .primary : .plain))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(hover ? Theme.fill : .clear)
        .onHover { hover = $0 }
    }
}
