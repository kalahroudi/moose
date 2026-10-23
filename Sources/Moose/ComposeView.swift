// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MooseKit

/// A new email. Kept for the life of the app, so closing the window never loses what you typed.
@MainActor @Observable
final class ComposeModel {
    static let shared = ComposeModel()
    var account = ""
    var to = ""
    var cc = ""
    var bcc = ""
    var showCc = false
    var subject = ""
    var body = ""
    var brief = ""
    var files: [URL] = []
    var drafting = false
    var dropping = false
    var note = ""
    /// What the last send held, so Undo can put it back.
    var sent: (pending: PendingSend, to: String, cc: String, bcc: String, subject: String, body: String, files: [URL])?

    private let mail = MailModel.shared

    var canSend: Bool { !to.trimmingCharacters(in: .whitespaces).isEmpty && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !drafting }
    var sender: String { mail.accounts.contains { $0.email == account } ? account : (mail.accounts.first?.email ?? "") }

    func clear() { to = ""; cc = ""; bcc = ""; showCc = false; subject = ""; body = ""; brief = ""; note = ""; files = [] }

    func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
    var totalSize: Int { files.reduce(0) { $0 + size($1) } }

    /// Adds files (folders and duplicates are skipped) while the total stays under what Gmail accepts.
    func attach(_ urls: [URL]) {
        var skipped = 0
        for u in urls {
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            guard v?.isRegularFile == true, !files.contains(u) else { skipped += 1; continue }
            guard totalSize + size(u) <= MailAttachment.maxTotalBytes else { AppModel.shared.show("\(u.lastPathComponent) is too big. Gmail allows about 18 MB of attachments per email.", error: true); continue }
            files.append(u)
        }
        if skipped > 0 { AppModel.shared.show("Folders can't be attached. Zip them first.", error: true) }
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.message = "Choose files to attach"
        if panel.runModal() == .OK { attach(panel.urls) }
    }

    private func loadAttachments() throws -> [MailAttachment] {
        do { return try files.map { try MailAttachment.load($0) } }
        catch { throw UserFacingError("Couldn't read an attached file. It may have been moved or deleted.") }
    }

    func writeWithClaude() {
        drafting = true; note = ""
        let (acct, t, s, b, br) = (sender, to, subject, body, brief)
        Task {
            defer { drafting = false }
            do {
                let c = try await mail.composeWithClaude(account: acct, to: t, subject: s, body: b, brief: br)
                body = c.body; if !c.subject.isEmpty { subject = c.subject }
                brief = ""; note = "Written by Claude. Edit before sending."
            } catch { AppLog.error(error, context: "claude compose"); AppModel.shared.show(UserError.message(for: error, action: "Write the email"), error: true) }
        }
    }

    func saveDraft() {
        let (acct, t, s, b, c, bc) = (sender, to, subject, body, cc, bcc)
        Task {
            do { _ = try await mail.saveNewDraft(account: acct, to: t, cc: c, bcc: bc, subject: s, body: b, attachments: loadAttachments()); note = "Saved in your Gmail drafts." }
            catch { AppLog.error(error, context: "save new draft"); AppModel.shared.show(UserError.message(for: error, action: "Save the draft"), error: true) }
        }
    }

    func send() {
        let (acct, t, s, b, f, c, bc) = (sender, to, subject, body, files, cc, bcc)
        Task {
            do {
                let p = try await mail.queueNew(account: acct, to: t, cc: c, bcc: bc, subject: s, body: b, attachments: loadAttachments(), undoSeconds: 5, byAgent: false)
                sent = (p, t, c, bc, s, b, f); clear()
            } catch { AppLog.error(error, context: "send new"); AppModel.shared.show(UserError.message(for: error, action: "Send the email"), error: true) }
        }
    }

    func undoSend() {
        guard let s = sent else { return }
        mail.cancel(s.pending)
        to = s.to; cc = s.cc; bcc = s.bcc; showCc = !(s.cc + s.bcc).isEmpty; subject = s.subject; body = s.body; files = s.files; sent = nil
    }
}

struct ComposeView: View {
    @Bindable var model = ComposeModel.shared
    let mail = MailModel.shared
    var close: () -> Void

    private var undoable: Bool { model.sent.map { s in mail.outbox.contains(s.pending) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New email").font(.system(size: 19, weight: .bold)).padding(.top, 8)
            if mail.accounts.count > 1 {
                row("From") {
                    Picker("", selection: Binding(get: { model.sender }, set: { model.account = $0 })) {
                        ForEach(mail.accounts) { Text($0.email).tag($0.email) }
                    }.labelsHidden().fixedSize()
                }
            }
            row("To") {
                TextField("name@example.com, …", text: $model.to).textFieldStyle(.plain)
                if !model.showCc && model.cc.isEmpty && model.bcc.isEmpty { Button("Cc Bcc") { model.showCc = true }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent) }
            }
            if model.showCc || !model.cc.isEmpty || !model.bcc.isEmpty {
                row("Cc") { TextField("Copied", text: $model.cc).textFieldStyle(.plain) }
                row("Bcc") { TextField("Hidden copy", text: $model.bcc).textFieldStyle(.plain) }
            }
            row("Subject") { TextField("Subject", text: $model.subject).textFieldStyle(.plain) }
            if ClaudeDrafter.available { claudeBar }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.body).font(.system(size: 14.5)).scrollContentBackground(.hidden).padding(8)
                if model.body.isEmpty { Text(model.drafting ? "Claude is writing…" : "Write your email, or tell Claude what it should say.").foregroundStyle(.secondary).padding(.top, 16).padding(.leading, 13).allowsHitTesting(false) }
            }
            .frame(minHeight: 160, maxHeight: .infinity).background(Theme.fill, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6])).opacity(model.dropping ? 1 : 0))
            if !model.files.isEmpty { attachmentList }
            HStack(spacing: 10) {
                if undoable {
                    Image(systemName: "paperplane").foregroundStyle(Theme.accent)
                    Text("Sending to \(model.sent?.to ?? "")…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Button("Undo") { model.undoSend() }.buttonStyle(Pill())
                } else if !model.note.isEmpty { Text(model.note).font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button { model.pickFiles() } label: { Label("Attach", systemImage: "paperclip") }.buttonStyle(Pill()).disabled(model.drafting).help("Attach files, or drop them anywhere in this window")
                Button("Discard") { model.clear(); close() }.buttonStyle(Pill()).disabled(model.drafting)
                Button("Save draft") { model.saveDraft() }.buttonStyle(Pill()).disabled(model.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Send") { model.send() }.buttonStyle(Pill(kind: .primary)).keyboardShortcut(.return, modifiers: .command).disabled(!model.canSend)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 18).padding(.top, 14)
        .frame(minWidth: 520, minHeight: 460)
        .background(Theme.pane)
        .overlay(alignment: .bottom) { ToastView() }
        .onDrop(of: [.fileURL], isTargeted: $model.dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.attach([url]) } }
                }
            }
            return true
        }
    }

    private var attachmentList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.files, id: \.self) { u in
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(u.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .leading)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(model.size(u)), countStyle: .file)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Button { model.files.removeAll { $0 == u } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Remove \(u.lastPathComponent)")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.fill, in: Capsule())
                }
            }
        }
    }

    private var claudeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            TextField(model.body.isEmpty ? "Tell Claude what to write: ask Maya to move Friday's meeting to Monday" : "Tell Claude how to change it (or leave empty to polish)", text: $model.brief)
                .textFieldStyle(.plain).font(.system(size: 13)).onSubmit { if !model.drafting { model.writeWithClaude() } }
            Button(model.body.isEmpty ? "Write with Claude" : "Rewrite") { model.writeWithClaude() }
                .buttonStyle(Pill(kind: .primary)).disabled(model.drafting || (model.body.isEmpty && model.brief.trimmingCharacters(in: .whitespaces).isEmpty))
        }
        .padding(.horizontal, 10).padding(.vertical, 6).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9))
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            content().font(.system(size: 13.5))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7).background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
    }
}
