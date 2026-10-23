// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import MooseKit

/// Panes of the Manager window. Named `Pane`, not `Section`: SwiftUI already has a `Section`.
enum Pane: String, CaseIterable, Identifiable {
    case priority, favourites, everything, muted, folder, folders, routing, muting, agents, settings, help
    var id: String { rawValue }
    var title: String {
        switch self {
        case .priority: "Priority"; case .favourites: "Favourites"; case .everything: "Everything else"; case .muted: "Muted"; case .folder: "Folder"; case .folders: "Folders"
        case .routing: "Routing"; case .muting: "Muting"; case .agents: "Agents"; case .settings: "Settings"; case .help: "Help"
        }
    }
    var symbol: String {
        switch self {
        case .priority: "bolt.fill"; case .favourites: "star.fill"; case .everything: "tray.full"; case .muted: "bell.slash"; case .folder: "folder"; case .folders: "folder.badge.gearshape"
        case .routing: "arrow.triangle.branch"; case .muting: "line.3.horizontal.decrease"; case .agents: "sparkles"; case .settings: "gearshape"; case .help: "questionmark.circle"
        }
    }
    var mailView: MailView? {
        switch self { case .priority: .priority; case .favourites: .favourites; case .everything: .everythingElse; case .muted: .muted; default: nil }
    }
    /// The panes that list messages (and open them in the thread view).
    var isMailList: Bool { mailView != nil || self == .folder }
}

@MainActor @Observable
final class Nav {
    static let shared = Nav()
    var pane: Pane = .priority
    var account: String?              // filter the stack views to one address
    var open: MailMessage?            // the message being read
    var settingsTab: SettingsPane.Tab = .general
    let list = ListState()            // filters, sort and selection of the stack lists
    var folder: String?               // the folder shown while `pane == .folder`
    var foldersExpanded = false       // the sidebar shows the first 5 folders; the rest are wrapped under "N more"
    var renaming: String?             // folder dialogs, shown by ManagerView
    var emptying: String?
    var deleting: String?

    func openFolder(_ name: String) {
        folder = name; pane = .folder; open = nil
        if let i = MailModel.shared.folderNames.firstIndex(where: { Folders.key($0) == Folders.key(name) }), i >= Folders.visibleCount { foldersExpanded = true }
    }
}

/// The Manager window: a fixed sidebar (collapsible to icons) and a main pane that uses the full width.
struct ManagerView: View {
    let model = AppModel.shared
    let mail = MailModel.shared
    let nav = Nav.shared

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            Divider()
            ZStack {
                Theme.pane
                VStack(spacing: 0) {
                    if let t = model.runningTask { TaskBanner(task: t) }
                    detail
                    OutboxBar()
                }
            }
            .overlay(alignment: .bottom) { ToastView() }
        }
        .folderDialogs()
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { model.setManagerVisible(true) }
    }

    @ViewBuilder private var detail: some View {
        if !model.loadedOnce {
            SkeletonList(rows: 9).frame(maxHeight: .infinity, alignment: .top).padding(.top, 40)   // never show a half-loaded page
        } else if model.needsSetup && nav.pane != .settings && nav.pane != .help {
            SetupView().padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 40)
        } else if let m = nav.open, nav.pane.isMailList {
            ThreadView(message: m)
        } else {
            switch nav.pane {
            case .priority, .favourites, .everything, .muted, .folder: StackListPane(pane: nav.pane)
            case .folders: FoldersPane()
            case .routing: RoutingPane()
            case .muting: MutingPane()
            case .agents: AgentsPane()
            case .settings: SettingsPane(initialTab: nav.settingsTab)
            case .help: HelpPane()
            }
        }
    }
}

struct Sidebar: View {
    let nav = Nav.shared
    let prefs = Prefs.shared
    let mail = MailModel.shared
    var collapsed: Bool { prefs.sidebarCollapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.18)) { prefs.sidebarCollapsed.toggle() } } label: {
                    Image(systemName: "sidebar.left").foregroundStyle(.secondary).padding(4).contentShape(Rectangle())
                }.buttonStyle(.plain).help(collapsed ? "Expand sidebar" : "Collapse to icons").accessibilityLabel(collapsed ? "Expand sidebar" : "Collapse sidebar")
            }.padding(.top, 14).padding(.bottom, 8).padding(.horizontal, collapsed ? 0 : 6)
            Button { AppDelegate.shared.showCompose() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.and.pencil").font(.system(size: 13.5)).frame(width: 20)
                    if !collapsed { Text("New email").font(.system(size: 13, weight: .semibold)); Spacer(minLength: 0) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
                .foregroundStyle(Theme.onAccent).background(Theme.accent, in: RoundedRectangle(cornerRadius: 7)).contentShape(RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).help("New email (⌘N)").accessibilityLabel("New email").disabled(!mail.hasAccount).dimWhenDisabled()
            if !collapsed { label("Stacks") }
            ForEach([Pane.priority, .favourites, .everything, .muted]) { item($0, count: mail.hasAccount ? mail.count($0.mailView!) : nil) }
            if mail.hasAccount { SidebarFolders(collapsed: collapsed) }
            if mail.hasAccount {
                if !collapsed { label("Accounts") }
                ForEach(mail.accounts) { account($0) }
            }
            if !collapsed { label("Brain") }
            ForEach([Pane.routing, .muting, .agents]) { item($0) }
            Spacer(minLength: 8)
            ForEach([Pane.settings, .help]) { item($0) }
            if !collapsed {
                Text("Moose \(BuildInfo.current.version) · \(AppMemory.footprint)").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 12)
        .padding(.top, 20)   // room for the traffic lights
        .frame(width: collapsed ? 62 : 212)
        .background(Theme.sidebar)
    }

    private func label(_ t: String) -> some View { SectionLabel(t).padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 3) }

    private func item(_ p: Pane, count: Int? = nil) -> some View {
        let on = nav.pane == p
        return Button { nav.pane = p; nav.open = nil; if p == .settings { nav.settingsTab = .general } } label: {
            HStack(spacing: 9) {
                Image(systemName: p.symbol).font(.system(size: 13.5)).frame(width: 20)
                if !collapsed {
                    Text(p.title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    if let c = count, c > 0 { Text("\(c)").font(.system(size: 11)).monospacedDigit().foregroundStyle(on ? Theme.accent : .secondary) }
                    if p == .settings, Updater.shared.available != nil { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .foregroundStyle(on ? Theme.accent : Color.primary.opacity(0.85))
            .background(on ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))   // whole row (incl. padding and empty space) is clickable, not just icon+text
        }
        .buttonStyle(.plain).help(p.title).accessibilityLabel(p.title)
    }

    private func account(_ a: MailAccount) -> some View {
        let on = nav.account == a.email
        return Button { nav.account = on ? nil : a.email; nav.open = nil; if !nav.pane.isMailList { nav.pane = .priority } } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 3).fill(mail.accountColor(a.email)).frame(width: 9, height: 9).frame(width: 20)
                if !collapsed {
                    Text(a.email).font(.system(size: 12.5, weight: on ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("\(mail.accountUnread(a.email))").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background(on ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).help(on ? "Showing \(a.email). Click to show all accounts" : "Show only \(a.email)")
    }
}

/// Shown while a send waits out its undo window.
struct OutboxBar: View {
    let mail = MailModel.shared
    var body: some View {
        if !mail.outbox.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(spacing: 6) {
                    ForEach(mail.outbox) { p in
                        HStack(spacing: 10) {
                            Image(systemName: "paperplane").foregroundStyle(Theme.accent)
                            Text("\(p.byAgent ? (p.isReply ? "Agent reply" : "Agent email") : (p.isReply ? "Reply" : "Email")) to \(p.to) sends in \(max(0, Int(p.deadline.timeIntervalSince(ctx.date).rounded(.up)))) s").font(.system(size: 12.5))
                            Spacer()
                            Button("Undo") { mail.cancel(p) }.buttonStyle(Pill())
                        }.padding(.horizontal, 12).padding(.vertical, 8).background(Theme.card, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.accent.opacity(0.5)))
                    }
                }.padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
    }
}
