// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import MooseKit

/// The menu bar popover: the few messages that need you, a way into the window. Nothing runs while it is closed.
struct PopoverView: View {
    let model = AppModel.shared
    let mail = MailModel.shared
    var openManager: (Pane) -> Void

    private var top: [ScoredMessage] {
        Array(mail.stacks(.priority, unreadOnly: true).compactMap(\.messages.first).prefix(5))
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            if model.loadedOnce, model.needsSetup { SetupView(compact: true) }
            else if !model.loadedOnce { SkeletonList(rows: 4).frame(height: 140) }
            else { list }
            footer
        }
        .padding(14)
        .frame(width: 380)
        .background(Theme.pane)                                   // an opaque themed background: the popover must follow the app theme
        .overlay(alignment: .bottom) { ToastView() }
        .onAppear { model.setPopoverVisible(true) }
        .onDisappear { model.setPopoverVisible(false) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Priority").font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(mail.syncing ? "Checking…" : "\(mail.count(.priority)) stacks · \(mail.accounts.count) \(mail.accounts.count == 1 ? "account" : "accounts")").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(top) { m in
                Button { openManager(.priority); Nav.shared.open = m.message; mail.markRead(m.message) } label: {
                    HStack(spacing: 8) {
                        Text("\(m.score)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Fmt.scoreColor(m.score)).frame(width: 24, alignment: .trailing)
                        Text(m.message.displayName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).frame(width: 88, alignment: .leading)
                        Text(m.message.subject).font(.system(size: 12.5)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Fmt.time(m.message.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.vertical, 7).padding(.horizontal, 6).frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if m.id != top.last?.id { Divider().opacity(0.6) }
            }
            if top.isEmpty { Text("Nothing needs you right now.").font(.system(size: 12.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12).padding(.horizontal, 6) }
        }.card(padding: 6)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Open Moose") { openManager(.priority) }.buttonStyle(Pill(kind: .primary))
            let muted = mail.mutedSummary().reduce(0) { $0 + $1.1 }
            if muted > 0 { Button { openManager(.muted) } label: { Label("\(muted) muted", systemImage: "bell.slash").font(.system(size: 12)).foregroundStyle(.secondary).contentShape(Rectangle()) }.buttonStyle(.plain) }
            Spacer()
            Button { openManager(.settings) } label: { Image(systemName: "gearshape").padding(4).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Settings").accessibilityLabel("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power").padding(4).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Quit Moose").accessibilityLabel("Quit")
        }
    }
}
