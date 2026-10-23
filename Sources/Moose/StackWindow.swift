// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import MooseKit

/// State of the Stack window: a frozen deck of unread priority senders, one card at a time.
@MainActor @Observable
final class StackModel {
    static let shared = StackModel()
    enum Mode { case browse, reading, replying }
    enum Scope { case sender, whole }

    private(set) var items: [DeckItem] = []
    var index = 0
    var mode: Mode = .browse
    var showAll = false
    var scope: Scope = .sender
    var reply = ""
    var cc = ""
    var drafting = false
    private var handled = Set<String>()
    private var bodies: [String: String] = [:]
    private let mail = MailModel.shared

    func rebuild() {
        items = Deck.build(mail.scored, favourites: mail.favourites)
        handled = []; bodies = [:]; index = 0; reset()
    }

    func release() { items = []; handled = []; bodies = [:]; reply = ""; cc = ""; reset() }
    private func reset() { mode = .browse; showAll = false; scope = .sender }

    private var present: Set<String> { Set(mail.data.messages.map(\.id)) }
    var live: [DeckItem] { let p = present; return items.filter { !$0.remaining(present: p, handled: handled).isEmpty } }
    var position: Int { min(index, max(0, live.count - 1)) }
    var item: DeckItem? { live.isEmpty ? nil : live[position] }
    var message: MailMessage? {
        guard let it = item, let id = it.current(present: present, handled: handled) else { return nil }
        return mail.data.messages.first { $0.id == id }
    }
    var senderCount: Int { item?.remaining(present: present, handled: handled).count ?? 0 }
    var wholeCount: Int { let p = present; return live.reduce(0) { $0 + $1.remaining(present: p, handled: handled).count } }
    func body(for m: MailMessage) -> String? { bodies[m.id] }

    func loadBody(_ m: MailMessage) async {
        guard bodies[m.id] == nil else { return }
        let t = await mail.fullText(m)
        if bodies.count > 12 { bodies.removeAll() }
        bodies[m.id] = t
    }

    // MARK: Navigation

    func step(_ d: Int) { guard !live.isEmpty else { return }; index = max(0, min(live.count - 1, position + d)); reset() }

    // MARK: Reading, replying

    func read() { guard let m = message else { return }; mode = .reading; mail.markRead(m) }

    func startReply() {
        guard let m = message else { return }
        mode = .replying; showAll = false; cc = ""
        reply = mail.data.composeDrafts[m.id] ?? ""
        if reply.isEmpty, ClaudeDrafter.available { draft(.normal) }
    }

    func draft(_ tone: DraftTone) {
        guard let m = message else { return }
        drafting = true
        let extra = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { drafting = false }
            do { reply = try await mail.draftWithClaude(m, tone: tone, extra: extra); mail.setCompose(m.id, reply) }
            catch { AppLog.error(error, context: "stack draft"); AppModel.shared.show(UserError.message(for: error, action: "Draft the reply"), error: true) }
        }
    }

    func cancelReply() { mode = .browse }

    func toggleReplyAll() {
        guard let m = message else { return }
        if !cc.isEmpty { cc = ""; return }
        Task {
            do { cc = try await mail.replyAllCc(for: m); if cc.isEmpty { AppModel.shared.show("Nobody else was on this message.") } }
            catch { AppLog.error(error, context: "stack reply all"); AppModel.shared.show(UserError.message(for: error, action: "Find the other recipients"), error: true) }
        }
    }

    func send() {
        guard let m = message else { return }
        let body = reply
        Task {
            do {
                _ = try await mail.queueReply(to: m, body: body, cc: cc, undoSeconds: 5, byAgent: false)
                mail.setCompose(m.id, ""); reply = ""; cc = ""; handled.insert(m.id); mode = .browse
            } catch { AppLog.error(error, context: "stack send"); AppModel.shared.show(UserError.message(for: error, action: "Send the reply"), error: true) }
        }
    }

    // MARK: Delete and mass actions

    func deleteCurrent() { guard let m = message else { return }; mode = .browse; mail.apply(.trash, to: [m]) }

    func applyAll(_ action: StackAction) {
        let p = present
        let ids: [String]
        var sender: String?
        switch scope {
        case .sender: ids = item?.remaining(present: p, handled: handled) ?? []; sender = item?.name
        case .whole: ids = live.flatMap { $0.remaining(present: p, handled: handled) }
        }
        mail.apply(action, to: mail.messages(ids: ids), sender: sender)
        reset()
    }
}

/// Mouse support for the Stack window: back/forward buttons and the scroll wheel or trackpad flip cards.
/// While reading, scrolling is left to the card's own text.
@MainActor
final class StackMouse {
    static let shared = StackMouse()
    private var monitor: Any?
    private var travel: CGFloat = 0
    private var fired = false
    private var last = Date.distantPast

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .scrollWheel, .swipe]) { [weak self] e in
            guard let self, e.window?.frameAutosaveName == "MooseStack" else { return e }
            return MainActor.assumeIsolated { self.handle(e) ? nil : e }
        }
    }

    func remove() { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }

    private func handle(_ e: NSEvent) -> Bool {
        let st = StackModel.shared
        guard st.mode == .browse, !st.showAll else { return false }
        if e.type == .swipe {   // some mouse drivers turn back/forward into a horizontal swipe
            if e.deltaX == 0 { return false }
            st.step(e.deltaX > 0 ? -1 : 1); return true
        }
        if e.type == .otherMouseDown {
            switch e.buttonNumber {
            case 3: st.step(-1); return true
            case 4: st.step(1); return true
            default: return false
            }
        }
        if e.phase.contains(.began) || e.phase.contains(.mayBegin) { travel = 0; fired = false }
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        travel += abs(dx) > abs(dy) ? dx : dy
        let gesture = !e.phase.isEmpty
        if gesture ? !fired : Date().timeIntervalSince(last) > 0.12, abs(travel) > (e.hasPreciseScrollingDeltas ? 40 : 1) {
            st.step(travel < 0 ? 1 : -1)
            fired = true; last = Date(); travel = 0
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) { travel = 0; fired = false }
        return true
    }
}

struct StackView: View {
    let st = StackModel.shared
    let mail = MailModel.shared
    let model = AppModel.shared

    var body: some View {
        ZStack(alignment: .top) {
            Theme.pane.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if let m = st.message { content(m) } else { empty }
            }
            if let u = mail.undoToast { UndoBar(entry: u).padding(.top, 3).transition(.move(edge: .top).combined(with: .opacity)) }
            shortcuts
        }
        .animation(.easeOut(duration: 0.18), value: mail.undoToast?.id)
        .frame(minWidth: 520, minHeight: 460)
        .overlay(alignment: .bottom) { ToastView() }
        .onAppear { model.setStackVisible(true); StackMouse.shared.install() }
        .onChange(of: mail.lastSync) { _, _ in if st.live.isEmpty { st.rebuild() } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Spacer()
            if !st.live.isEmpty {
                Button { st.step(-1) } label: { Image(systemName: "chevron.left").padding(6).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(st.position == 0).help("Previous  ←")
                Text("\(st.position + 1) / \(st.live.count)").font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                Button { st.step(1) } label: { Image(systemName: "chevron.right").padding(6).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(st.position >= st.live.count - 1).help("Next  →")
            }
        }.foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 38)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(mail.hasAccount ? "Nothing needs you." : "Connect an account first.").font(.system(size: 24, weight: .bold))
            Text(mail.hasAccount ? "Priority mail will stack up here." : "Open Moose to finish setup.").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ m: MailMessage) -> some View {
        VStack(spacing: 0) {
            ZStack {
                if st.live.count > 2 { layer(scale: 0.93, y: 30, opacity: 0.55) }
                if st.live.count > 1 { layer(scale: 0.965, y: 15, opacity: 1) }
                Card(m: m, st: st)
            }.padding(.horizontal, 40).padding(.top, 8).padding(.bottom, 34)
            actions.padding(.bottom, 26)
        }
        .task(id: m.id) { await st.loadBody(m) }
    }

    private func layer(scale: CGFloat, y: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 14).fill(Theme.sidebar).overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
            .scaleEffect(scale).offset(y: y).opacity(opacity)
            .onTapGesture { if st.mode == .browse { st.step(1) } }
    }

    @ViewBuilder private var actions: some View {
        if st.mode == .replying {
            HStack(spacing: 10) {
                Button { st.cancelReply() } label: { key("Cancel", "Esc") }.buttonStyle(Pill())
                Button { st.send() } label: { key("Send", "⌘↩") }.buttonStyle(Pill(kind: .primary)).keyboardShortcut(.return, modifiers: .command)
                    .disabled(st.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || st.drafting)
            }
        } else if st.showAll {
            VStack(spacing: 10) {
                Segmented(options: [(StackModel.Scope.sender, "This sender · \(st.senderCount)"), (.whole, "Whole stack · \(st.wholeCount)")], selection: Bindable(st).scope)
                Text("Applies to").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { st.applyAll(.archive) } label: { key("Archive all", "⇧E") }.buttonStyle(Pill(kind: .primary))
                    Button { st.applyAll(.markRead) } label: { key("Mark all read", "⇧U") }.buttonStyle(Pill())
                    Button { st.applyAll(.trash) } label: { key("Delete all", "⇧⌫") }.buttonStyle(Pill(kind: .danger))
                }
            }
        } else {
            HStack(spacing: 10) {
                if st.mode == .browse { Button { st.read() } label: { key("Read", "Space") }.buttonStyle(Pill()) }
                Button { st.startReply() } label: { key("Reply", "R") }.buttonStyle(Pill(kind: .primary))
                Button { st.deleteCurrent() } label: { key("Delete", "⌫") }.buttonStyle(Pill(kind: .danger))
                Button { st.showAll = true } label: { key("All ▾", "A") }.buttonStyle(Pill()).foregroundStyle(.secondary)
            }
        }
    }

    private func key(_ t: String, _ k: String) -> some View {
        HStack(spacing: 7) { Text(t).fontWeight(.semibold); Text(k).font(.system(size: 10.5, design: .monospaced)).opacity(0.55) }.padding(.horizontal, 6).padding(.vertical, 2)
    }

    /// Invisible buttons that own the keyboard. Single-key shortcuts are off while typing a reply.
    @ViewBuilder private var shortcuts: some View {
        let typing = st.mode == .replying
        ZStack {
            if !typing {
                Button("") { st.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { st.step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { st.step(-1) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { st.step(1) }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") { st.step(-1) }.keyboardShortcut("[", modifiers: .command)   // drivers that map back/forward to ⌘[ ⌘]
                Button("") { st.step(1) }.keyboardShortcut("]", modifiers: .command)
                Button("") { st.step(-1) }.keyboardShortcut("k", modifiers: [])
                Button("") { st.step(1) }.keyboardShortcut("j", modifiers: [])
                Button("") { st.read() }.keyboardShortcut(.space, modifiers: [])
                Button("") { st.read() }.keyboardShortcut(.return, modifiers: [])
                Button("") { st.startReply() }.keyboardShortcut("r", modifiers: [])
                // Backspace arrives as U+007F from a real keyboard; register both spellings so it always fires.
                ForEach(["\u{7F}", "\u{8}"], id: \.self) { c in
                    Button("") { st.deleteCurrent() }.keyboardShortcut(KeyEquivalent(Character(c)), modifiers: [])
                    Button("") { st.applyAll(.trash) }.keyboardShortcut(KeyEquivalent(Character(c)), modifiers: .shift)
                }
                Button("") { st.showAll.toggle() }.keyboardShortcut("a", modifiers: [])
                Button("") { st.applyAll(.archive) }.keyboardShortcut("e", modifiers: .shift)
                Button("") { st.applyAll(.markRead) }.keyboardShortcut("u", modifiers: .shift)
                Button("") { mail.undo() }.keyboardShortcut("z", modifiers: .command)
            }
            Button("") { if st.mode == .replying { st.cancelReply() } else { st.showAll = false } }.keyboardShortcut(.escape, modifiers: [])
        }.opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
    }
}

private struct Card: View {
    let m: MailMessage
    let st: StackModel
    private var text: String { st.body(for: m) ?? m.snippet }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(m.displayName).font(.system(size: 16, weight: .semibold))
                Text(m.fromEmail).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if st.senderCount > 1 { Text("1 of \(st.senderCount)").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                Text(Fmt.time(m.date)).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Text(m.subject).font(.system(size: st.mode == .replying ? 16 : 19, weight: .bold)).padding(.top, 8).padding(.bottom, st.mode == .replying ? 8 : 14).fixedSize(horizontal: false, vertical: true)
            if st.mode == .replying { replying } else {
                ScrollView { Text(text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .scrollDisabled(st.mode == .browse)
                    .overlay(alignment: .bottom) {
                        if st.mode == .browse { LinearGradient(colors: [Theme.card.opacity(0), Theme.card], startPoint: .top, endPoint: .bottom).frame(height: 56).allowsHitTesting(false) }
                    }
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
    }

    private var replying: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(3)
            Divider()
            HStack {
                Text(st.drafting ? "Claude is writing…" : ClaudeDrafter.available ? "Reply · drafted by Claude in your voice · edit freely" : "Reply").font(.system(size: 12)).foregroundStyle(.secondary)
                Button(st.cc.isEmpty ? "Reply all" : "Just reply") { st.toggleReplyAll() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                Spacer()
                if ClaudeDrafter.available && !st.drafting {
                    ForEach([DraftTone.shorter, .warmer, .decline, .askForCall], id: \.self) { t in Button(t.label) { st.draft(t) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent) }
                }
            }
            if !st.cc.isEmpty { Text("Cc: \(st.cc)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
            TextEditor(text: Bindable(st).reply).font(.system(size: 14.5)).scrollContentBackground(.hidden).padding(8).frame(minHeight: 120, maxHeight: 240)
                .background(Theme.pane, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent))
                .onChange(of: st.reply) { _, v in MailModel.shared.setCompose(m.id, v) }
        }
    }
}

private struct UndoBar: View {
    let entry: MailModel.UndoEntry
    var body: some View {
        HStack(spacing: 16) {
            Text(entry.text).font(.system(size: 13))
            Button { MailModel.shared.undo() } label: { Text("Undo  ⌘Z").underline().contentShape(Rectangle()) }.buttonStyle(.plain).font(.system(size: 13))
        }
        .foregroundStyle(Color(nsColor: .windowBackgroundColor)).padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.primary.opacity(0.88), in: RoundedRectangle(cornerRadius: 11)).shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }
}
