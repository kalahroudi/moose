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

/// Filter, sort and selection state for the stack lists. Lives outside the view so opening a message and coming back keeps your place.
@MainActor @Observable
final class ListState {
    enum Layout { case stacks, messages }
    var layout: Layout = .stacks
    var query = StackQuery()
    var unreadPanes: Set<Pane> = [.priority]
    var expandAll = false
    var expanded = Set<String>()
    var selection: String?             // message id
    var order: [MailMessage] = []      // rows as displayed, so the thread view can step to the next or previous message
    var selecting = false              // checkbox mode for bulk archive / delete
    var checked = Set<String>()        // message ids ticked in selecting mode
    var pinnedKeys: [String] = []      // stack order as last shown, so removing a message doesn't reshuffle the groups
    var pinnedSig = ""                 // what that order was for (pane, sort, filters); a different view starts afresh

    func toggle(_ ids: [String]) {
        if ids.allSatisfy(checked.contains) { checked.subtract(ids) } else { checked.formUnion(ids) }
    }
    /// Where the rows on screen live, so bulk actions hit the folder's mail rather than the inbox cache.
    var container: MailContainer { Nav.shared.pane == .folder ? Nav.shared.folder.map { .folder($0) } ?? .inbox : .inbox }
    func endSelecting() { selecting = false; checked = [] }

    func isUnreadOnly(_ p: Pane) -> Bool { unreadPanes.contains(p) }
    func setUnreadOnly(_ on: Bool, _ p: Pane) { if on { unreadPanes.insert(p) } else { unreadPanes.remove(p) } }
    func clearFilters() { let s = query.sort; query = StackQuery(); query.sort = s }

    /// Jumps the highlight to the first or last row, which scrolls the list with it.
    func jump(toEnd: Bool) { selection = (toEnd ? order.last : order.first)?.id }

    func move(_ d: Int) {
        guard !order.isEmpty else { return }
        let i = order.firstIndex { $0.id == selection }
        selection = order[max(0, min(order.count - 1, (i ?? (d > 0 ? -1 : order.count)) + d))].id
    }
    var selected: MailMessage? { order.first { $0.id == selection } }

    /// Opens the message `d` steps from the one being read (thread view).
    func step(from m: MailMessage, _ d: Int) {
        guard let i = order.firstIndex(where: { $0.id == m.id }), order.indices.contains(i + d) else { return }
        let n = order[i + d]
        selection = n.id; Nav.shared.open = n; MailModel.shared.markRead(n)
    }
    func hasStep(from m: MailMessage, _ d: Int) -> Bool {
        guard let i = order.firstIndex(where: { $0.id == m.id }) else { return false }
        return order.indices.contains(i + d)
    }
}

/// One of the four stack views: Priority, Favourites, Everything else, Muted.
struct StackListPane: View {
    let pane: Pane
    let mail = MailModel.shared
    let nav = Nav.shared
    var ls: ListState { nav.list }

    private var query: StackQuery { var q = ls.query; q.account = nav.account; return q }

    private var folderName: String? { pane == .folder ? nav.folder : nil }
    private var title: String { folderName ?? pane.title }

    /// Everything that decides stack order. While it stays the same, stacks keep their places.
    private var orderSig: String { "\(pane)|\(folderName ?? "")|\(ls.layout)|\(ls.isUnreadOnly(pane))|\(query)" }

    /// Deleting, archiving or filing a message lowers its stack's score; re-sorting then makes the groups jump under the highlight.
    /// Keep the order the user was looking at until the view, sort or filters change or a new stack appears.
    private var stacks: [MailStack] {
        let fresh = freshStacks
        guard ls.pinnedSig == orderSig, !ls.pinnedKeys.isEmpty else { return fresh }
        let rank = Dictionary(ls.pinnedKeys.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        guard fresh.allSatisfy({ rank[$0.key] != nil }) else { return fresh }   // a new stack appeared: show the natural order
        return fresh.sorted { rank[$0.key]! < rank[$1.key]! }
    }

    private var freshStacks: [MailStack] {
        if let f = folderName {
            let all = mail.folderStacks(f)
            return Stacker.refine(ls.isUnreadOnly(pane) ? all.compactMap { s in
                let u = s.messages.filter(\.message.unread)
                return u.isEmpty ? nil : MailStack(key: s.key, name: s.name, messages: u, favourite: s.favourite)
            } : all, query)
        }
        guard let view = pane.mailView else { return [] }
        return Stacker.refine(mail.stacks(view, unreadOnly: ls.isUnreadOnly(pane)), query)
    }
    private var flat: [ScoredMessage] { Stacker.flatten(stacks, sort: ls.query.sort) }

    private func isExpanded(_ s: MailStack) -> Bool { ls.expandAll || ls.expanded.contains(s.key) }

    /// Rows in the order they appear on screen.
    private func rows(_ stacks: [MailStack]) -> [ScoredMessage] {
        ls.layout == .messages ? flat : stacks.flatMap { isExpanded($0) ? $0.messages : Array($0.messages.prefix(3)) }
    }

    private func subtitle(_ stacks: [MailStack]) -> String {
        let n = stacks.count, c = stacks.reduce(0) { $0 + $1.messages.count }
        if let f = folderName {
            let u = mail.folderUnread(f), t = max(mail.folderTotal(f), c)
            return ["\(t) \(t == 1 ? "email" : "emails")", u > 0 ? "\(u) unread" : nil, nav.account].compactMap { $0 }.joined(separator: " · ")
        }
        let parts = ["\(n) \(n == 1 ? "stack" : "stacks")", "\(c) \(c == 1 ? "message" : "messages")", nav.account ?? "\(mail.accounts.count) \(mail.accounts.count == 1 ? "account" : "accounts")"]
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let stacks = self.stacks
        let visible = rows(stacks)
        VStack(spacing: 0) {
            PaneHeader(title: title, subtitle: subtitle(stacks)) {
                HStack(spacing: 8) {
                    SearchBox(prompt: "Search", text: Bindable(ls).query.text).frame(minWidth: 90, idealWidth: 170, maxWidth: 170)
                    Button("Stack") { AppDelegate.shared.openStack(source: folderName.map { .folder($0) } ?? .priority) }.buttonStyle(Pill())
                        .help(folderName == nil ? "Go through priority mail one card at a time  ⌘T" : "Go through this folder one card at a time  ⌘T")
                    if let f = folderName {
                        Menu { FolderMenu(name: f) } label: { Image(systemName: "ellipsis") }.buttonStyle(Pill()).menuIndicator(.hidden).fixedSize().help("Folder actions").accessibilityLabel("Folder actions")
                    }
                    Button { Task { await mail.sync() } } label: { Image(systemName: "arrow.clockwise").rotationEffect(.degrees(mail.syncing ? 180 : 0)) }
                        .buttonStyle(Pill()).disabled(mail.syncing).help("Check for new mail").accessibilityLabel("Check for new mail")
                }
            }
            if let f = folderName { FolderRuleBar(name: f) }
            filterBar
            if ls.selecting { selectionBar }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        Color.clear.frame(height: 0).id("list-top")
                        if ls.layout == .messages { flatList(visible) } else { ForEach(stacks) { StackCard(stack: $0, expanded: expandedBinding($0)) } }
                        if visible.isEmpty { empty }
                        Color.clear.frame(height: 0).id("list-end")
                    }.padding(16)
                }
                .overlay(alignment: .bottomTrailing) { if !visible.isEmpty { jumpButtons(proxy) } }
                .background { jumpKeys(proxy) }
                .onChange(of: ls.selection) { _, id in
                    // Wait a turn so a row that was just laid out (or just moved) is known to the proxy; animating here made lazy rows miss.
                    if let id { Task { @MainActor in proxy.scrollTo(id) } }
                }
            }
            if pane == .priority, !mail.mutedSummary().isEmpty {
                Divider()
                mutedLine.padding(.horizontal, 16)
            }
            keys
        }
        .task(id: folderName ?? "") { if let f = folderName { await mail.loadFolder(f) } }
        .onChange(of: stacks.map(\.key), initial: true) { _, keys in ls.pinnedKeys = keys; ls.pinnedSig = orderSig }
        .onChange(of: orderSig) { _, _ in ls.pinnedKeys = stacks.map(\.key); ls.pinnedSig = orderSig }
        .onChange(of: visible.map(\.id), initial: true) { _, _ in
            let was = ls.order.firstIndex { $0.id == ls.selection }
            ls.order = visible.map(\.message)
            if let s = ls.selection, !visible.contains(where: { $0.id == s }) {
                // The highlighted row went away (deleted, archived, filed): keep the highlight, on the row that took its place.
                ls.selection = was.flatMap { visible.isEmpty ? nil : visible[min($0, visible.count - 1)].id }
            }
            ls.checked.formIntersection(flat.map(\.id))
        }
    }

    private func jump(_ proxy: ScrollViewProxy, toEnd: Bool) {
        ls.jump(toEnd: toEnd)
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(toEnd ? "list-end" : "list-top", anchor: toEnd ? .bottom : .top) }
    }

    private func jumpButtons(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 6) {
            jumpButton("chevron.up.2", "Jump to the top  ⌘↑") { jump(proxy, toEnd: false) }
            jumpButton("chevron.down.2", "Jump to the bottom  ⌘↓") { jump(proxy, toEnd: true) }
        }.padding(14)
    }

    private func jumpButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28).background(Theme.card, in: Circle()).overlay(Circle().stroke(Theme.hairline))
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private func jumpKeys(_ proxy: ScrollViewProxy) -> some View {
        ZStack {
            Button("") { jump(proxy, toEnd: false) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("") { jump(proxy, toEnd: true) }.keyboardShortcut(.downArrow, modifiers: .command)
            Button("") { jump(proxy, toEnd: false) }.keyboardShortcut(.home, modifiers: [])
            Button("") { jump(proxy, toEnd: true) }.keyboardShortcut(.end, modifiers: [])
        }.opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
    }

    private func expandedBinding(_ s: MailStack) -> Binding<Bool> {
        Binding { isExpanded(s) } set: { on in
            if on { ls.expanded.insert(s.key) } else { ls.expanded.remove(s.key); ls.expandAll = false }
        }
    }

    private func flatList(_ rows: [ScoredMessage]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Divider().opacity(0.6) }
                MessageRow(item: m, showFrom: true, showAccount: mail.accounts.count > 1).id(m.id)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.hairline))
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            Segmented(options: [(ListState.Layout.stacks, "Stacks"), (.messages, "All messages")], selection: Bindable(ls).layout)
            Chip(title: "Unread", symbol: "circle.fill", active: ls.isUnreadOnly(pane)) { ls.setUnreadOnly(!ls.isUnreadOnly(pane), pane) }
            FilterMenu(symbol: "arrow.up.arrow.down", options: StackSort.allCases, label: \.label, selection: Bindable(ls).query.sort, active: ls.query.sort != .priority)
            DateFilter(query: Bindable(ls).query)
            FilterMenu(symbol: "person.2", options: Origin.allCases, label: \.label, selection: Bindable(ls).query.origin, active: ls.query.origin != .all)
            Spacer(minLength: 4)
            if ls.query.filtering { Button("Clear filters") { ls.clearFilters() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent) }
            Button(ls.selecting ? "Done" : "Select") { withAnimation(.easeOut(duration: 0.15)) { if ls.selecting { ls.endSelecting() } else { ls.selecting = true } } }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent).help("Pick messages to archive or delete")
            if ls.layout == .stacks {
                Button(ls.expandAll ? "Collapse all" : "Expand all") { withAnimation(.easeOut(duration: 0.15)) { ls.expandAll.toggle(); if !ls.expandAll { ls.expanded = [] } } }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent).help("Show every message in every stack")
            }
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// Shown in selecting mode: select everything in this view, then archive or delete it in one go.
    private var selectionBar: some View {
        let all = flat.map(\.id), n = ls.checked.count
        return HStack(spacing: 8) {
            Button { ls.toggle(all) } label: {
                Label(n == all.count && n > 0 ? "Deselect all" : "Select all \(all.count)", systemImage: n == all.count && n > 0 ? "checkmark.square.fill" : n > 0 ? "minus.square" : "square")
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent).disabled(all.isEmpty)
            Text(n == 0 ? "Tick messages, or select them all." : "\(n) selected").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button("Archive") { bulk(.archive) }.buttonStyle(Pill()).disabled(n == 0)
            Button("Delete") { bulk(.trash) }.buttonStyle(Pill(kind: .danger)).disabled(n == 0).help("Moves to Trash. Undo is offered right after.")
        }.padding(.horizontal, 16).padding(.vertical, 6).background(Theme.fill)
    }

    private func bulk(_ action: StackAction) {
        mail.apply(action, to: ls.order.filter { ls.checked.contains($0.id) }, container: ls.container)
        ls.checked = []
    }

    /// Invisible buttons that own the keyboard: ↑ ↓ move the highlight, ↩ opens, → ← expand and collapse the stack.
    private var keys: some View {
        ZStack {
            Button("") { ls.move(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { ls.move(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { if let m = ls.selected { nav.open = m; mail.markRead(m) } }.keyboardShortcut(.return, modifiers: [])
            Button("") { setExpanded(true) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { setExpanded(false) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { deleteHighlighted() }.keyboardShortcut(.delete, modifiers: [])
            Button("") { deleteHighlighted() }.keyboardShortcut(.deleteForward, modifiers: [])
            Button("") { deleteHighlighted() }.keyboardShortcut(.delete, modifiers: .command)
        }.opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
    }

    /// Moves the highlighted message to Trash (recoverable: Undo toast, ⌘Z, 30 days in Gmail) and highlights its neighbour so ⌫ can be pressed again.
    private func deleteHighlighted() {
        guard let m = ls.selected else { return }
        let i = ls.order.firstIndex { $0.id == m.id }
        let next = i.flatMap { ls.order.indices.contains($0 + 1) ? ls.order[$0 + 1] : $0 > 0 ? ls.order[$0 - 1] : nil }
        guard mail.apply(.trash, to: [m], container: ls.container) != nil else { return }
        ls.selection = next?.id
    }

    private func setExpanded(_ on: Bool) {
        guard ls.layout == .stacks, let m = ls.selected else { return }
        if on { ls.expanded.insert(m.fromEmail) } else { ls.expanded.remove(m.fromEmail); ls.expandAll = false }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: pane.symbol).font(.system(size: 22)).foregroundStyle(.secondary)
            Text(ls.query.filtering ? "Nothing matches these filters." : folderName != nil ? folderEmptyText : pane == .priority ? "Nothing needs you right now." : pane == .favourites ? "No favourites yet. Click the star on any sender." : "Nothing here.").font(.system(size: 13)).foregroundStyle(.secondary)
            if ls.query.filtering { Button("Clear filters") { ls.clearFilters() }.buttonStyle(Pill()) }
        }.frame(maxWidth: .infinity).padding(.top, 50)
    }

    private var folderEmptyText: String {
        guard let f = folderName else { return "" }
        if !mail.folderLoaded(f) { return "Loading “\(f)”…" }
        if ls.isUnreadOnly(pane) { return "Nothing unread in “\(f)”." }
        let rule = mail.folderRules(f).first
        return rule.map { "Nothing filed here yet. New mail \($0.title) will land here automatically." } ?? "Nothing filed here yet."
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

/// A tick box for selecting mode.
private struct Checkbox: View {
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 14)).foregroundStyle(on ? Theme.accent : .secondary).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(on ? "Selected" : "Not selected")
    }
}

/// A small toggle chip for the filter bar.
private struct Chip: View {
    let title: String
    let symbol: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 6))
                Text(title).font(.system(size: 12, weight: active ? .semibold : .regular))
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(active ? Theme.accent : .secondary)
            .background(active ? Theme.accentSoft : Theme.fill, in: Capsule())
            .contentShape(Capsule())
        }.buttonStyle(.plain)
    }
}

/// The date chip: presets plus a custom from/to range picked in a popover.
private struct DateFilter: View {
    @Binding var query: StackQuery
    @State private var picking = false

    private var label: String {
        guard query.range == .custom else { return query.range.label }
        let f = { (d: Date) in d.formatted(.dateTime.day().month(.abbreviated)) }
        switch (query.from, query.to) {
        case let (a?, b?): return "\(f(a)) – \(f(b))"
        case let (a?, nil): return "Since \(f(a))"
        case let (nil, b?): return "Until \(f(b))"
        default: return "Custom range"
        }
    }

    var body: some View {
        let active = query.range != .any
        Menu {
            ForEach(DateRange.allCases.filter { $0 != .custom }, id: \.self) { r in
                Button { query.range = r } label: { if r == query.range { Label(r.label, systemImage: "checkmark") } else { Text(r.label) } }
            }
            Divider()
            Button {
                if query.from == nil && query.to == nil { query.from = Calendar.current.date(byAdding: .day, value: -7, to: Date()); query.to = Date() }
                query.range = .custom; picking = true
            } label: { if query.range == .custom { Label("Custom range…", systemImage: "checkmark") } else { Text("Custom range…") } }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar").font(.system(size: 10.5))
                Text(label).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(active ? Theme.accent : .secondary)
            .background(active ? Theme.accentSoft : Theme.fill, in: Capsule())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .popover(isPresented: $picking, arrowEdge: .bottom) { picker }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom date range").font(.system(size: 13, weight: .semibold))
            bound("From", $query.from, fallback: Date())
            bound("To", $query.to, fallback: Date())
            HStack {
                Button("Clear") { query.range = .any; query.from = nil; query.to = nil; picking = false }.buttonStyle(Pill())
                Spacer()
                Button("Done") { picking = false }.buttonStyle(Pill())
            }
        }.padding(14).frame(width: 260)
    }

    /// A date picker with an on/off switch, so either end of the range can stay open.
    private func bound(_ title: String, _ date: Binding<Date?>, fallback: Date) -> some View {
        HStack {
            Toggle(title, isOn: Binding { date.wrappedValue != nil } set: { date.wrappedValue = $0 ? fallback : nil }).toggleStyle(.checkbox)
            Spacer()
            if date.wrappedValue != nil {
                DatePicker("", selection: Binding { date.wrappedValue ?? fallback } set: { date.wrappedValue = $0 }, displayedComponents: .date).labelsHidden()
            }
        }
    }
}

/// A menu chip that shows the current choice and lights up when it differs from the default.
private struct FilterMenu<T: Hashable>: View {
    let symbol: String
    let options: [T]
    let label: KeyPath<T, String>
    @Binding var selection: T
    let active: Bool
    var body: some View {
        Menu {
            ForEach(options, id: \.self) { o in
                Button { selection = o } label: {
                    if o == selection { Label(o[keyPath: label], systemImage: "checkmark") } else { Text(o[keyPath: label]) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5))
                Text(selection[keyPath: label]).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(active ? Theme.accent : .secondary)
            .background(active ? Theme.accentSoft : Theme.fill, in: Capsule())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

struct StackCard: View {
    let stack: MailStack
    @Binding var expanded: Bool
    let mail = MailModel.shared
    let nav = Nav.shared
    private var shown: [ScoredMessage] { expanded ? stack.messages : Array(stack.messages.prefix(3)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(shown) { m in
                Divider().opacity(0.6)
                MessageRow(item: m, showFrom: false, showAccount: mail.accounts.count > 1).id(m.id)
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
            if nav.list.selecting { Checkbox(on: stack.messages.allSatisfy { nav.list.checked.contains($0.id) }) { nav.list.toggle(stack.messages.map(\.id)) }.help("Select this stack") }
            Button { mail.toggleFavourite(stack.key) } label: {
                Image(systemName: stack.favourite ? "star.fill" : "star").foregroundStyle(stack.favourite ? Theme.accent : .secondary).padding(4).contentShape(Rectangle())
            }.buttonStyle(.plain).help(stack.favourite ? "Remove from favourites" : "Make a favourite").accessibilityLabel("Favourite")
            Text(stack.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text("\(stack.messages.count) \(stack.messages.count == 1 ? "message" : "messages")").font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(nav.pane == .folder ? "latest \(Fmt.time(stack.latest))" : stack.why).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if stack.messages.count > 3 {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { if stack.messages.count > 3 { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } }
    }
}

struct MessageRow: View {
    let item: ScoredMessage
    var showFrom = true
    var showAccount = false
    let mail = MailModel.shared
    @State private var hover = false
    private var container: MailContainer { Nav.shared.list.container }

    var body: some View {
        let m = item.message
        let selected = Nav.shared.list.selection == m.id
        let ls = Nav.shared.list
        Button { if ls.selecting { ls.toggle([m.id]) } else { ls.selection = m.id; Nav.shared.open = m; mail.markRead(m) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if ls.selecting { Checkbox(on: ls.checked.contains(m.id)) { ls.toggle([m.id]) } }
                if Nav.shared.pane != .folder { Text("\(item.score)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Fmt.scoreColor(item.score)).frame(width: 26, alignment: .trailing) }
                if showFrom { Text(m.displayName).font(.system(size: 13, weight: m.unread ? .semibold : .regular)).lineLimit(1).frame(width: 110, alignment: .leading) }
                (Text(m.subject).fontWeight(m.unread ? .semibold : .regular) + Text("  " + MailText.excerpt(m.snippet, 140)).foregroundColor(.secondary))
                    .font(.system(size: 13)).lineLimit(1).foregroundStyle(m.unread ? Color.primary : .secondary)
                Spacer(minLength: 8)
                if showAccount { Circle().fill(mail.accountColor(m.account)).frame(width: 6, height: 6) }
                Text(Fmt.time(m.date)).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(selected ? Theme.accentSoft : hover ? Theme.fill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)   // a clicked row must not hold keyboard focus: when ⌫ removes it, the ↑ ↓ shortcuts would die with it
        .onHover { hover = $0 }
        .contextMenu {
            Button("Mark as read") { mail.markRead(m) }
            if case .folder = container {
                Button("Move to inbox") { mail.apply(.unfile, to: [m], container: container) }
                Button("Remove from folder (keep in All Mail)") { mail.archive(m) }
            } else { Button("Archive") { mail.archive(m) } }
            Button("Delete") { mail.apply(.trash, to: [m], container: container) }
            Divider()
            Button("File everything from \(m.displayName) in a folder") { mail.fileSender(m) }
            Divider()
            Button("Mute \(m.fromEmail)") { mail.muteSender(m.fromEmail) }
            Button("Mute for a week") { mail.muteSender(m.fromEmail, days: 7) }
            Button("Mute everyone at this domain") { mail.muteDomain(of: m.fromEmail) }
        }
    }
}
