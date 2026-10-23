// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import MooseKit

/// Reading one message and replying to it. Brief first, details on demand, and the reply dock never leaves the bottom.
/// The reply text is saved as you type, so a quit or crash never loses it.
struct ThreadView: View {
    let message: MailMessage
    let mail = MailModel.shared
    @State private var raw = ""
    @State private var cleaned: CleanedMail?
    @State private var brief: MailBrief?
    @State private var briefLoading = false
    @State private var showDetails = false
    @State private var briefOpen = true
    @State private var showRaw = false
    @State private var showFooter = false
    @State private var selection: (text: String, rect: CGRect)?
    @State private var quotes: [String] = []
    @State private var composing = false
    @State private var reply = ""
    @State private var drafting = false
    @State private var note: String?
    @State private var cc = ""
    @State private var gettingCc = false
    @State private var dictation = Dictation()
    @State private var tidying = false
    @State private var unsub: UnsubscribeOption?
    @State private var unsubBusy = false
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let c = cleaned { content(c) } else { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 40) }
                    }.padding(.horizontal, 22).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                }
                if dictation.active { dictationPill.padding(.bottom, 14).transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            dock
            keys
        }
        .animation(.easeOut(duration: 0.15), value: dictation.active)
        .task(id: message.id) { await load() }
        .onChange(of: dictation.error) { _, e in if let e { AppModel.shared.show(e, error: true) } }
        .onDisappear { dictation.cancel() }
    }

    // MARK: Header

    private var header: some View {
        PaneHeader(title: message.subject, subtitle: "\(message.displayName) · \(message.account) · \(Fmt.time(message.date))") {
            HStack(spacing: 8) {
                let ls = Nav.shared.list
                if cleaned != nil {
                    Button { toggleDetails() } label: { Text("Details") }.buttonStyle(Pill(kind: showDetails ? .primary : .plain)).help("Show or hide the full text  D")
                    if showDetails { Button { showRaw.toggle() } label: { Text("Raw") }.buttonStyle(Pill(kind: showRaw ? .primary : .plain)).help("The text exactly as it arrived") }
                }
                Button { ls.step(from: message, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(Pill()).disabled(!ls.hasStep(from: message, -1))
                    .keyboardShortcut(.upArrow, modifiers: .option).help("Previous message  ⌥↑").accessibilityLabel("Previous message")
                Button { ls.step(from: message, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(Pill()).disabled(!ls.hasStep(from: message, 1))
                    .keyboardShortcut(.downArrow, modifiers: .option).help("Next message  ⌥↓").accessibilityLabel("Next message")
                Button { mail.toggleFavourite(message.fromEmail) } label: { Image(systemName: mail.favourites.contains(message.fromEmail) ? "star.fill" : "star") }.buttonStyle(Pill()).help("Favourite sender")
                Menu {
                    Button("Mute for a week") { mail.muteSender(message.fromEmail, days: 7) }
                    Button("Mute for good") { mail.muteSender(message.fromEmail) }
                    Button("Mute everyone at this domain") { mail.muteDomain(of: message.fromEmail) }
                    Divider()
                    Button("Block \(message.displayName): mute and archive everything") { mail.blockSender(message.fromEmail); Nav.shared.open = nil }.disabled(mail.isBlocked(message.fromEmail))
                    Button("File everything from \(message.displayName) in a folder") { mail.fileSender(message) }
                } label: { Image(systemName: "bell.slash") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Mute or file this sender")
                Button { archive() } label: { Image(systemName: "archivebox") }.buttonStyle(Pill()).help("Archive  E")
                Button { Nav.shared.open = nil; mail.apply(.trash, to: [message], container: ls.container) } label: { Image(systemName: "trash") }.buttonStyle(Pill()).help("Delete (moves to Trash, can be undone)").accessibilityLabel("Delete")
                Button("Back") { back() }.buttonStyle(Pill()).keyboardShortcut(.escape, modifiers: [])
            }
        }
    }

    /// Keys that only work while you are not typing a reply, so they can never eat a letter.
    @ViewBuilder private var keys: some View {
        Group {
            if !composing {
                Button("") { openComposer() }.keyboardShortcut("r", modifiers: [])
                Button("") { toggleDetails() }.keyboardShortcut("d", modifiers: [])
                Button("") { archive() }.keyboardShortcut("e", modifiers: [])
            }
            Button("") { toggleDictation() }.keyboardShortcut("d", modifiers: .control)
        }.frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    // MARK: Content

    @ViewBuilder private func content(_ c: CleanedMail) -> some View {
        if let b = brief {
            if briefOpen { briefCard(b, c) } else { briefStrip(b) }
        } else if !c.isShort {
            briefPlaceholder
        }
        if briefOpen, brief != nil { quickRow }
        if c.isShort && brief == nil && !briefLoading && ClaudeDrafter.available {
            Button { Task { await makeBrief(c, force: true) } } label: { Label("Brief this", systemImage: "sparkles") }.buttonStyle(Pill()).help("Summarise this message with Claude")
        }
        if showDetails { details(c) } else if brief != nil {
            Button { toggleDetails() } label: {
                HStack(spacing: 6) {
                    Text("Details").fontWeight(.semibold)
                    Text(detailNote(c)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Show  D").foregroundStyle(Theme.accent)
                }.font(.system(size: 12.5)).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    private func detailNote(_ c: CleanedMail) -> String {
        var parts = ["original text, cleaned"]
        if c.blankLinesRemoved > 0 { parts.append("\(c.blankLinesRemoved) blank lines removed") }
        if !c.footer.isEmpty { parts.append("footer folded") }
        return parts.joined(separator: " · ")
    }

    private func details(_ c: CleanedMail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if brief != nil {
                HStack(spacing: 8) {
                    Text("Details").font(.system(size: 12.5, weight: .semibold))
                    Text(showRaw ? "exactly as it arrived" : detailNote(c)).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
            }
            ZStack(alignment: .topLeading) {
                SelectableText(paragraphs: showRaw ? [raw] : c.paragraphs.isEmpty ? [message.snippet] : c.paragraphs, mono: showRaw) { s in selection = s.map { ($0.0, $0.1) } }
                    .frame(maxWidth: 700, alignment: .leading)
                if let s = selection { selectionPopover(s).offset(x: min(max(0, s.rect.minX), 420), y: s.rect.maxY + 6) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !showRaw && !c.footer.isEmpty {
                Button { showFooter.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(showFooter ? 90 : 0))
                        Text(showFooter ? "Hide footer" : "Footer folded · \(c.footer.count) \(c.footer.count == 1 ? "block" : "blocks")")
                    }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }.buttonStyle(.plain)
                if showFooter { SelectableText(paragraphs: c.footer, muted: true, size: 12.5).frame(maxWidth: 700, alignment: .leading) }
            }
        }
    }

    private func selectionPopover(_ s: (text: String, rect: CGRect)) -> some View {
        QuotePopover(text: s.text, reply: { addQuote(s.text) }, done: { selection = nil })
    }

    // MARK: Brief

    private var briefPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Claude is reading this…").font(.system(size: 12.5)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 14)
    }

    private func briefCard(_ b: MailBrief, _ c: CleanedMail) -> some View {
        let real = c.links.filter { !$0.tracker }, hidden = c.links.count - real.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                Text("BRIEF").font(.system(size: 11, weight: .bold)).tracking(0.8)
                Spacer()
                if briefLoading { ProgressView().controlSize(.mini); Text("Claude is reading…") }
                else { Text(b.byAgent ? "by Claude · on this Mac" : "quick look"); if b.byAgent || ClaudeDrafter.available { Button { Task { await makeBrief(c, force: true) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Make a fresh brief") } }
            }.foregroundStyle(Theme.accent).font(.system(size: 11.5))
            Text(b.summary).font(.system(size: 16.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !b.points.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(b.points, id: \.self) { p in
                        HStack(alignment: .firstTextBaseline, spacing: 8) { Circle().fill(.secondary).frame(width: 4, height: 4).offset(y: -2); Text(p).font(.system(size: 13.5)) }
                    }
                }
            }
            FlowChips {
                if b.urgency == "high" { chip("Urgent", "exclamationmark.circle", warn: true) }
                ForEach(b.dates, id: \.self) { chip($0, "calendar", warn: b.urgency == "high") }
                if !real.isEmpty { chip("\(real.count) \(real.count == 1 ? "link" : "links")", "link") }
                if hidden > 0 { chip("\(hidden) tracker\(hidden == 1 ? "" : "s") hidden", "eye.slash") }
                if !b.replyNeeded { chip("No reply needed", "checkmark") }
                chip("Images & pixels blocked", "shield")
                if let u = unsub { chip("Unsubscribe: \(u.summary)", "envelope.badge.shield.half.filled") }
                if mail.isBlocked(message.fromEmail) { chip("Sender blocked", "nosign", warn: true) }
            }
            if !b.asks.isEmpty || b.replyNeeded {
                Divider().opacity(0.6)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Asks of you:").fontWeight(.semibold)
                    Text(b.asks.isEmpty ? "a reply" : b.asks).foregroundStyle(.secondary)
                }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        .overlay(alignment: .leading) { UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12).fill(Theme.accent).frame(width: 3) }
    }

    private func briefStrip(_ b: MailBrief) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { briefOpen = true } } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("BRIEF").font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(Theme.accent)
                Text(b.summary).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    private func chip(_ text: String, _ icon: String, warn: Bool = false) -> some View { BriefChip(text: text, icon: icon, warn: warn) }

    private var quickRow: some View {
        HStack(spacing: 8) {
            Text("Quick:").font(.system(size: 12)).foregroundStyle(.secondary)
            Button { archive() } label: { Text("Archive  E") }.buttonStyle(Pill())
            Button { mail.muteSender(message.fromEmail, days: 7); AppModel.shared.show("Muted \(message.displayName) for a week.", error: false) } label: { Text("Mute for a week") }.buttonStyle(Pill())
            if unsub != nil || message.bulkHeader, !mail.isBlocked(message.fromEmail) {
                if unsub != nil { Button { Task { await unsubscribe() } } label: { Text(unsubBusy ? "Unsubscribing…" : "Unsubscribe") }.buttonStyle(Pill()).disabled(unsubBusy).help("Ask the sender to stop, then block them") }
                Button { mail.blockSender(message.fromEmail); Nav.shared.open = nil } label: { Text("Block") }.buttonStyle(Pill()).help("Mute this sender and archive their mail, now and on every sync")
            }
            Button { openComposer() } label: { Text("Reply  R") }.buttonStyle(Pill(kind: .primary))
        }
    }

    private func unsubscribe() async {
        guard let o = unsub, !unsubBusy else { return }
        guard await mail.confirmUnsubscribe(message, o) else { return }
        unsubBusy = true; defer { unsubBusy = false }
        do {
            _ = try await mail.unsubscribe(message, o)
            if case .browser? = o.method {} else { Nav.shared.open = nil }
        } catch { AppLog.error(error, context: "unsubscribe"); AppModel.shared.show(UserError.message(for: error, action: "Unsubscribe"), error: true) }
    }

    // MARK: Dock

    @ViewBuilder private var dock: some View {
        VStack(spacing: 0) {
            Divider()
            Group { if composing { composer } else { replyBar } }.padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 14)
        }.background(Theme.pane)
    }

    private var replyBar: some View {
        HStack(spacing: 10) {
            Button { openComposer() } label: {
                Text(reply.isEmpty ? "Reply to \(message.displayName)…" : "Draft: \(MailText.excerpt(reply, 70))").foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if ClaudeDrafter.available {
                Button { openComposer(); draft(.normal) } label: { Text("Draft with Claude") }.buttonStyle(Pill()).disabled(drafting)
            }
            Button { toggleDictation() } label: { Image(systemName: "mic") }.buttonStyle(Pill()).help("Dictate a reply  ⌃D").accessibilityLabel("Dictate")
            Button { openComposer() } label: { Text("Reply  R") }.buttonStyle(Pill(kind: .primary))
        }
        .font(.system(size: 13.5)).padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(cc.isEmpty ? "Reply" : "Reply all").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("to \(message.displayName)").font(.system(size: 12.5)).foregroundStyle(.secondary)
                Button(cc.isEmpty ? "Reply all" : "Just \(message.displayName)") { toggleReplyAll() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent).disabled(gettingCc)
                Spacer()
                if ClaudeDrafter.available {
                    ForEach(DraftTone.allCases.prefix(3), id: \.self) { tone in
                        Button(tone.label == "Draft" ? "Draft with Claude" : tone.label) { draft(tone) }.buttonStyle(Pill(kind: tone == .normal ? .primary : .plain)).disabled(drafting)
                    }
                } else { Text("Install Claude Code in Settings to draft replies").font(.system(size: 12)).foregroundStyle(.secondary) }
                Button { composing = false; replyFocused = false } label: { Image(systemName: "chevron.down") }.buttonStyle(Pill()).help("Collapse. Your draft is kept.  Esc").accessibilityLabel("Collapse reply")
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Divider().opacity(0.6)
            ForEach(Array(quotes.enumerated()), id: \.offset) { i, q in
                HStack(alignment: .top, spacing: 8) {
                    Rectangle().fill(Theme.accent).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("REFERENCING").font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                        Text(MailText.excerpt(q, 220)).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button { quotes.remove(at: i) } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Remove this reference")
                }.padding(.horizontal, 12).padding(.top, 8)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $reply).font(.system(size: 14)).scrollContentBackground(.hidden).focused($replyFocused)
                    .frame(minHeight: 64, maxHeight: 140)
                    .onChange(of: reply) { _, v in mail.setCompose(message.id, v) }
                if reply.isEmpty { Text(drafting ? "Claude is writing…" : "Write a reply, dictate it, or let Claude draft one.").foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
            }.padding(.horizontal, 8).padding(.vertical, 4)
            if !cc.isEmpty { Text("Cc: \(cc)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 12).padding(.bottom, 4) }
            Divider().opacity(0.6)
            HStack(spacing: 8) {
                Button { toggleDictation() } label: { Label("Dictate", systemImage: "mic") }.buttonStyle(Pill()).help("Dictate  ⌃D")
                Text(note ?? "Saved as you type").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Save draft") { saveDraft() }.buttonStyle(Pill()).disabled(blank)
                Button("Send  ⌘↩") { send() }.buttonStyle(Pill(kind: .primary)).keyboardShortcut(.return, modifiers: .command).disabled(blank)
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.7)))
        .shadow(color: .black.opacity(0.08), radius: 10, y: -3)
    }

    private var blank: Bool { reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: Dictation

    private var dictationPill: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dictation.text.isEmpty ? "Listening…" : dictation.text).font(.system(size: 14.5)).opacity(dictation.text.isEmpty ? 0.55 : 1).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { i in
                        Capsule().fill(Theme.accent).frame(width: 3, height: 4 + CGFloat(dictation.level) * 14 * [0.5, 0.9, 1, 0.7, 0.95, 0.6, 0.8][i])
                    }
                }.frame(height: 18).animation(.easeOut(duration: 0.08), value: dictation.level)
                Text(tidying ? "Tidying…" : "Listening · on this Mac").font(.system(size: 12)).opacity(0.7)
                Spacer()
                Button("Cancel") { dictation.cancel() }.buttonStyle(.plain).font(.system(size: 12)).opacity(0.7)
                if ClaudeDrafter.available { Button("Tidy with Claude") { finishDictation(tidy: true) }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 4).overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.35))) }
                Button { finishDictation(tidy: false) } label: { Text("Done  ⌃D").font(.system(size: 12.5, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 4).background(Theme.accent, in: RoundedRectangle(cornerRadius: 7)).foregroundStyle(Theme.onAccent) }.buttonStyle(.plain)
            }
        }
        .padding(14).frame(width: 560).foregroundStyle(Color(nsColor: .windowBackgroundColor))
        .background(Color(nsColor: .labelColor), in: RoundedRectangle(cornerRadius: 16)).shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private func toggleDictation() {
        if dictation.active { finishDictation(tidy: false) } else { Task { await dictation.start() } }
    }

    private func finishDictation(tidy: Bool) {
        let heard = dictation.stop()
        guard !heard.isEmpty else { return }
        openComposer()
        guard tidy else { insert(heard); return }
        tidying = true
        Task {
            defer { tidying = false }
            do { insert(try await ClaudeDrafter.tidy(heard)) }
            catch { AppLog.error(error, context: "tidy dictation"); insert(heard); note = "Couldn't tidy it, so this is the plain dictation." }
        }
    }

    private func insert(_ s: String) {
        reply = reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? s : reply.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + s
    }

    // MARK: Actions

    private func load() async {
        unsub = nil; unsubBusy = false
        raw = ""; cleaned = nil; brief = nil; briefLoading = false; selection = nil; quotes = []; showRaw = false; showFooter = false
        note = nil; cc = ""; dictation.cancel()
        reply = mail.data.composeDrafts[message.id] ?? ""
        composing = !reply.isEmpty
        raw = await mail.fullText(message)
        let c = MailText.clean(raw)
        cleaned = c
        showDetails = c.isShort
        briefOpen = true
        unsub = await mail.unsubscribeOption(for: message)
        if c.isShort { brief = mail.cachedBrief(message.id) } else { await makeBrief(c, force: false) }
    }

    /// Shows the cached or instant local brief at once, then swaps in Claude's when it arrives.
    private func makeBrief(_ c: CleanedMail, force: Bool) async {
        if !force, let b = mail.cachedBrief(message.id) { brief = b; return }
        if brief == nil || force { brief = brief ?? MailText.localBrief(c) }
        briefLoading = true
        defer { briefLoading = false }
        do { let b = try await mail.brief(for: message, cleaned: c, force: force); if !Task.isCancelled { brief = b } }
        catch { AppLog.error(error, context: "brief"); if force { AppModel.shared.show(UserError.message(for: error, action: "Make the brief"), error: true) } }
    }

    private func toggleDetails() {
        withAnimation(.easeOut(duration: 0.15)) {
            showDetails.toggle()
            if brief != nil { briefOpen = !showDetails }
        }
    }

    private func openComposer() {
        if let s = selection { addQuote(s.text); return }
        composing = true
        DispatchQueue.main.async { replyFocused = true }
    }

    private func addQuote(_ text: String) {
        if !quotes.contains(text) { quotes.append(text) }
        selection = nil
        composing = true
        DispatchQueue.main.async { replyFocused = true }
    }

    private func back() {
        if dictation.active { dictation.cancel() } else if composing { composing = false } else { Nav.shared.open = nil }
    }

    private func archive() { mail.archive(message); Nav.shared.open = nil }

    private var fullReply: String { MailText.withQuotes(reply, quotes: quotes, sender: message.displayName, date: message.date) }

    private func toggleReplyAll() {
        if !cc.isEmpty { cc = ""; return }
        gettingCc = true
        Task {
            defer { gettingCc = false }
            do { cc = try await mail.replyAllCc(for: message); if cc.isEmpty { note = "Nobody else was on this message." } }
            catch { AppLog.error(error, context: "reply all"); AppModel.shared.show(UserError.message(for: error, action: "Find the other recipients"), error: true) }
        }
    }

    private func draft(_ tone: DraftTone) {
        drafting = true; note = nil
        let extra = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { drafting = false }
            do { reply = try await mail.draftWithClaude(message, tone: tone, extra: extra, quotes: quotes); note = "Drafted by Claude. Edit before sending." }
            catch { AppLog.error(error, context: "claude draft"); AppModel.shared.show(UserError.message(for: error, action: "Draft the reply"), error: true) }
        }
    }

    private func saveDraft() {
        let body = fullReply
        Task {
            do { _ = try await mail.saveDraftOnly(to: message, body: body, cc: cc); note = "Saved in your Gmail drafts." }
            catch { AppLog.error(error, context: "save draft"); AppModel.shared.show(UserError.message(for: error, action: "Save the draft"), error: true) }
        }
    }

    private func send() {
        let body = fullReply
        Task {
            do { _ = try await mail.queueReply(to: message, body: body, cc: cc, undoSeconds: 5, byAgent: false); reply = ""; cc = ""; quotes = []; mail.setCompose(message.id, ""); Nav.shared.open = nil }
            catch { AppLog.error(error, context: "send reply"); AppModel.shared.show(UserError.message(for: error, action: "Send the reply"), error: true) }
        }
    }
}

/// Chips that wrap onto more lines when the window is narrow.
struct FlowChips: Layout {
    var spacing: CGFloat = 7

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        var pos: [CGPoint] = []
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            pos.append(CGPoint(x: x, y: y))
            x += s.width + spacing; rowH = max(rowH, s.height); maxW = max(maxW, x - spacing)
        }
        return (pos, CGSize(width: maxW, height: y + rowH))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { rows(proposal.width ?? 600, subviews).size }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = rows(bounds.width, subviews)
        for (v, p) in zip(subviews, r.positions) { v.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified) }
    }
}
