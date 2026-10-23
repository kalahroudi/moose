// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import MooseKit

/// The actions on one folder. The same menu is used by the sidebar (right-click and the ⋯ button), the folder's header and the Folders pane.
struct FolderMenu: View {
    let name: String
    let mail = MailModel.shared
    let nav = Nav.shared

    var body: some View {
        Button { AppDelegate.shared.openStack(source: .folder(name)) } label: { Label("Open in stack window", systemImage: "rectangle.stack") }
        Button { Task { await mail.folderBulk(.markRead, in: name) } } label: { Label("Mark all read", systemImage: "checkmark.circle") }
        Button { Task { await mail.folderBulk(.unfile, in: name) } } label: { Label("Move all to inbox", systemImage: "tray.and.arrow.down") }
        Button { Task { await mail.folderBulk(.archive, in: name) } } label: { Label("Clear folder (keep in All Mail)", systemImage: "archivebox") }
        Divider()
        Button { nav.renaming = name } label: { Label("Rename…", systemImage: "pencil") }
        Button { nav.pane = .routing; nav.open = nil } label: { Label("Show rule…", systemImage: "arrow.triangle.branch") }
        Button { mail.setFolderFiling(name, enabled: mail.folderPaused(name)) } label: {
            Label(mail.folderPaused(name) ? "Resume filing" : "Pause filing", systemImage: mail.folderPaused(name) ? "play" : "pause")
        }
        Divider()
        Button(role: .destructive) { nav.emptying = name } label: { Label("Empty folder…", systemImage: "trash") }
        Button(role: .destructive) { nav.deleting = name } label: { Label("Delete folder…", systemImage: "xmark.bin") }
    }
}

/// Drag a folder onto another to put it before that one. Used by the sidebar and the Folders pane.
private struct FolderReorder: ViewModifier {
    let name: String
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .draggable(name)
            .dropDestination(for: String.self) { items, _ in
                guard let moved = items.first, Folders.key(moved) != Folders.key(name) else { return false }
                MailModel.shared.moveFolder(moved, before: name); return true
            } isTargeted: { targeted = $0 }
            .overlay(alignment: .top) { if targeted { Capsule().fill(Theme.accent).frame(height: 2).padding(.horizontal, 6) } }
    }
}
extension View { fileprivate func folderReorder(_ name: String) -> some View { modifier(FolderReorder(name: name)) } }

/// The sidebar's Folders section: the first five folders, the rest wrapped under "N more".
struct SidebarFolders: View {
    let nav = Nav.shared
    let mail = MailModel.shared
    let collapsed: Bool

    private var names: [String] { mail.folderNames }

    var body: some View {
        let names = self.names
        let shown = nav.foldersExpanded ? names : Array(names.prefix(Folders.visibleCount))
        let hidden = names.count > Folders.visibleCount && !nav.foldersExpanded ? names.dropFirst(Folders.visibleCount) : []
        VStack(alignment: .leading, spacing: 2) {
            if !collapsed {
                HStack {
                    SectionLabel("Folders")
                    Spacer()
                    Menu {
                        Button("New filing rule…") { nav.pane = .routing; nav.open = nil }
                        if !names.isEmpty { Button("Manage folders…") { nav.pane = .folders; nav.open = nil } }
                    } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(3).contentShape(Rectangle()) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("New filing rule, or manage folders")
                }.padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 3)
                if names.isEmpty {
                    Text("Mail you file with a routing rule shows up here.").font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.horizontal, 10).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(shown, id: \.self) { FolderRow(name: $0, collapsed: collapsed) }
            if names.count > Folders.visibleCount { moreRow(hidden: Array(hidden), total: names.count - Folders.visibleCount) }
            reorderKeys
        }
    }

    private func moreRow(hidden: [String], total: Int) -> some View {
        let unread = hidden.reduce(0) { $0 + mail.folderUnread($1) }
        return Button { withAnimation(.easeOut(duration: 0.15)) { nav.foldersExpanded.toggle() } } label: {
            HStack(spacing: 9) {
                Image(systemName: nav.foldersExpanded ? "chevron.up" : "chevron.down").font(.system(size: 10)).frame(width: 20)
                if !collapsed {
                    Text(nav.foldersExpanded ? "Show fewer" : "\(total) more").font(.system(size: 12.5))
                    Spacer(minLength: 4)
                    if unread > 0 { Text("\(unread)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.onAccent).padding(.horizontal, 5).background(Theme.accent, in: Capsule()) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help(nav.foldersExpanded ? "Show only the first \(Folders.visibleCount) folders" : "Show all folders")
    }

    /// ⌥↑ and ⌥↓ move the folder being viewed up and down the list.
    @ViewBuilder private var reorderKeys: some View {
        if nav.pane == .folder, nav.open == nil, let f = nav.folder {
            ZStack {
                Button("") { mail.shiftFolder(f, by: -1) }.keyboardShortcut(.upArrow, modifiers: .option)
                Button("") { mail.shiftFolder(f, by: 1) }.keyboardShortcut(.downArrow, modifiers: .option)
            }.opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
        }
    }
}

struct FolderRow: View {
    let name: String
    let collapsed: Bool
    let nav = Nav.shared
    let mail = MailModel.shared
    @State private var hover = false

    var body: some View {
        let on = nav.pane == .folder && nav.folder.map { Folders.key($0) == Folders.key(name) } == true
        let unread = mail.folderUnread(name)
        Button { nav.openFolder(name) } label: {
            HStack(spacing: 9) {
                Image(systemName: on ? "folder.fill" : "folder").font(.system(size: 13)).frame(width: 20)
                if !collapsed {
                    Text(name).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    if unread > 0, !hover { Text("\(unread)").font(.system(size: 11)).monospacedDigit().foregroundStyle(on ? Theme.accent : .secondary) }
                    if mail.folderPaused(name), !hover { Image(systemName: "pause.circle").font(.system(size: 10.5)).foregroundStyle(.secondary).help("Filing is paused") }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .foregroundStyle(on ? Theme.accent : Color.primary.opacity(0.85))
            .background(on ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if hover, !collapsed {
                Menu { FolderMenu(name: name) } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.trailing, 4).accessibilityLabel("Folder actions")
            }
        }
        .onHover { hover = $0 }
        .contextMenu { FolderMenu(name: name) }
        .folderReorder(name)
        .help(collapsed ? name : "\(name) · drag to reorder, right-click for actions")
        .accessibilityLabel("\(name) folder")
    }
}

// MARK: Folder pane pieces

/// Under a folder's header: which rule fills it, and a way to the rule.
struct FolderRuleBar: View {
    let name: String
    let mail = MailModel.shared
    var body: some View {
        let rules = mail.folderRules(name)
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            if let r = rules.first {
                Text("Filed by rule").foregroundStyle(.secondary)
                Text(r.title).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.accent).lineLimit(1)
                if rules.count > 1 { Text("+\(rules.count - 1) more").foregroundStyle(.secondary) }
                Badge(text: "Gmail label")
                if mail.folderPaused(name) { Badge(text: "paused", kind: .warn) }
            } else { Text("No rule files mail here any more.").foregroundStyle(.secondary) }
            Spacer()
            Button { Nav.shared.pane = .routing; Nav.shared.open = nil } label: { Text("Edit rule →").foregroundStyle(Theme.accent).contentShape(Rectangle()) }.buttonStyle(.plain)
        }
        .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
        .padding(.horizontal, 16).padding(.top, 10)
    }
}

/// The Folders pane: every folder in order, with the line after the fifth where the sidebar starts wrapping.
struct FoldersPane: View {
    let mail = MailModel.shared
    let nav = Nav.shared

    var body: some View {
        let names = mail.folderNames
        VStack(spacing: 0) {
            PaneHeader(title: "Folders", subtitle: "\(names.count) \(names.count == 1 ? "folder" : "folders") · drag to reorder. The first \(Folders.visibleCount) show in the sidebar.") {
                Button("New filing rule") { nav.pane = .routing }.buttonStyle(Pill(kind: .primary))
            }
            ScrollView {
                VStack(spacing: 8) {
                    if names.isEmpty {
                        Text("No folders yet. Describe a rule in Routing, like “move emails from stripe.com to Receipts”.").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.top, 20)
                    }
                    ForEach(Array(names.enumerated()), id: \.element) { i, name in
                        if i == Folders.visibleCount {
                            Text("shown in the sidebar above · wrapped under “more” below").font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4])))
                        }
                        row(i, name)
                    }
                }.padding(16)
            }
        }
        .task { await mail.refreshFolders(force: true) }
    }

    private func row(_ i: Int, _ name: String) -> some View {
        let unread = mail.folderUnread(name), total = mail.folderTotal(name)
        return HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.7))
            Button { nav.openFolder(name) } label: {
                HStack(spacing: 10) {
                    Text("\(i + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(minWidth: 12)
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(total) \(total == 1 ? "email" : "emails")" + (unread > 0 ? " · \(unread) unread" : "")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    if mail.folderPaused(name) { Badge(text: "paused", kind: .warn) }
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu { FolderMenu(name: name) } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Folder actions")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        .contextMenu { FolderMenu(name: name) }
        .folderReorder(name)
    }
}

// MARK: Dialogs

/// Rename, empty and delete. Shown over the Manager window, whichever pane starts them.
struct FolderDialogs: ViewModifier {
    let nav = Nav.shared
    let mail = MailModel.shared
    @State private var newName = ""
    @State private var deletion = FolderDeletion.keepMail

    func body(content: Content) -> some View {
        content
            .alert("Rename folder", isPresented: Binding(get: { nav.renaming != nil }, set: { if !$0 { nav.renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") { if let old = nav.renaming { Task { await mail.renameFolder(old, to: newName) } } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Renames the label in Gmail and keeps the filing rule pointing at it. Use “Work/Clients” for a nested folder.") }
            .onChange(of: nav.renaming) { _, v in if let v { newName = v } }
            .alert("Empty “\(nav.emptying ?? "")”?", isPresented: Binding(get: { nav.emptying != nil }, set: { if !$0 { nav.emptying = nil } })) {
                Button("Move to Trash", role: .destructive) { if let f = nav.emptying { Task { await mail.folderBulk(.trash, in: f) } } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Moves \(nav.emptying.map { mail.folderTotal($0) } ?? 0) emails to Gmail Trash, where they stay for 30 days. You can undo it right after.") }
            .sheet(isPresented: Binding(get: { nav.deleting != nil }, set: { if !$0 { nav.deleting = nil } })) {
                if let f = nav.deleting { DeleteFolderSheet(name: f, mode: $deletion) }
            }
    }
}

extension View { func folderDialogs() -> some View { modifier(FolderDialogs()) } }

private struct DeleteFolderSheet: View {
    let name: String
    @Binding var mode: FolderDeletion
    let mail = MailModel.shared
    @State private var busy = false

    var body: some View {
        let total = mail.folderTotal(name)
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete the “\(name)” folder?").font(.system(size: 15, weight: .semibold))
            Text("\(total) \(total == 1 ? "email is" : "emails are") labelled “\(name)”." + (mail.folderRules(name).first.map { " The rule \($0.title) files into it." } ?? "") + " The Gmail label and the rule are removed.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            option(.keepMail, "Delete folder, keep the emails", "They stay in All Mail.")
            option(.toInbox, "Delete folder, return emails to the inbox", "The rule is removed too, so they stay there.")
            option(.trashMail, "Delete folder and trash the emails", "Moves them to Gmail Trash (30 days to recover).")
            HStack {
                Spacer()
                Button("Cancel") { Nav.shared.deleting = nil }.buttonStyle(Pill()).keyboardShortcut(.cancelAction)
                Button(busy ? "Deleting…" : "Delete folder") {
                    busy = true
                    Task { await mail.deleteFolder(name, mode: mode); Nav.shared.deleting = nil }
                }.buttonStyle(Pill(kind: .danger)).disabled(busy)
            }.padding(.top, 6)
        }.padding(22).frame(width: 440)
    }

    private func option(_ m: FolderDeletion, _ title: String, _ detail: String) -> some View {
        Button { mode = m } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode == m ? "largecircle.fill.circle" : "circle").foregroundStyle(mode == m ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
            .background(mode == m ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(mode == m ? Theme.accent : Theme.hairline))
        }.buttonStyle(.plain)
    }
}
