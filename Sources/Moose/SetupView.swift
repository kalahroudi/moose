// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import MooseKit

/// First-run guide: your own Google client, one account, optional Claude. Does everything Google allows by itself;
/// the one step with no API (creating the Desktop client) opens the exact page and Moose picks the file up from Downloads.
struct SetupView: View {
    let model = AppModel.shared
    let mail = MailModel.shared
    var compact = false
    @State private var watching = false
    @State private var started = Date()
    @State private var manualID = ""
    @State private var manualSecret = ""
    @State private var showManual = false
    private var links: (credentials: URL, consent: URL) { GoogleClient.consoleLinks(project: nil) }
    private var hasClaude: Bool { Shell.find("claude") != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mail.client == nil ? "Your Google, your keys" : "Connect your Gmail").font(.system(size: compact ? 15 : 20, weight: .semibold))
                Text("Moose is open source, so it signs in with a Google client that you own. Nothing about your mail passes through anyone else.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                step("Google client", mail.client == nil ? "Create it once in Google Cloud (about two minutes)." : "Saved in your Keychain.", done: mail.client != nil, running: mail.client == nil && watching)
                Divider()
                step("Gmail account", mail.hasAccount ? mail.accounts.map(\.email).joined(separator: " · ") : "Sign in once in your browser. Add more addresses later.", done: mail.hasAccount, running: mail.signingIn)
                Divider()
                step("Claude for drafting (optional)", hasClaude ? "Found. Moose can draft replies in your voice." : "Install Claude Code to draft replies. No API key is stored.", done: hasClaude, running: false)
            }.padding(.horizontal, 12).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))

            if mail.client == nil { clientGuide } else if !mail.hasAccount {
                Button { mail.addAccount() } label: { HStack(spacing: 6) { if mail.signingIn { ProgressView().controlSize(.small) }; Text(mail.signingIn ? "Waiting for Google…" : "Sign in with Google") } }
                    .buttonStyle(Pill(kind: .primary)).disabled(mail.signingIn)
                if mail.signingIn { Button("Cancel") { mail.cancelSignIn() }.buttonStyle(Pill(kind: .primary)) }
            }
            if !hasClaude, Shell.find("brew") != nil {
                HStack(spacing: 8) {
                    Button("Install Claude Code") { installClaude() }.buttonStyle(Pill()).disabled(model.busy)
                    CopyButton(text: "brew install --cask claude-code", label: "Copy command")
                    Text("brew install --cask claude-code").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Button("I did it, check again") { Task { await model.refresh(); await mail.sync() } }.buttonStyle(Pill())
        }.frame(maxWidth: 560, alignment: .leading)
        .onAppear { if mail.client == nil { startWatching() } }
    }

    private var clientGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Three clicks in Google Cloud").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label("Open the page, create a project if asked, and enable the Gmail API.", systemImage: "1.circle")
                Label("Create an OAuth client of type “Desktop app”, then press Download JSON.", systemImage: "2.circle")
                Label("On the consent screen choose “Publish app”, otherwise Google blocks sign-in (403 access_denied) or expires it every 7 days. Personal use needs no review; on the “unverified app” warning choose Advanced, then Continue.", systemImage: "3.circle")
            }.font(.system(size: 12)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            HStack(spacing: 8) {
                Link(destination: URL(string: "https://console.cloud.google.com/apis/library/gmail.googleapis.com")!) { Text("1 · Enable Gmail API") }.buttonStyle(.plain).modifier(LinkPill())
                Link(destination: links.credentials) { Text("2 · Create client") }.buttonStyle(.plain).modifier(LinkPill())
                Link(destination: links.consent) { Text("3 · Publish app") }.buttonStyle(.plain).modifier(LinkPill())
            }
            HStack(spacing: 6) {
                if watching { ProgressView().controlSize(.small) }
                Text("Moose is watching your Downloads folder for client_secret_….json and will import it by itself.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            DisclosureGroup("Or paste the client ID and secret", isExpanded: $showManual) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Client ID  (…apps.googleusercontent.com)", text: $manualID).textFieldStyle(.roundedBorder)
                    SecureField("Client secret", text: $manualSecret).textFieldStyle(.roundedBorder)
                    Button("Save") { saveManual() }.buttonStyle(Pill(kind: .primary)).disabled(manualID.isEmpty || manualSecret.isEmpty)
                }.padding(.top, 6)
            }.font(.system(size: 12))
        }.card()
    }

    private func step(_ title: String, _ detail: String, done: Bool, running: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if running { ProgressView().controlSize(.small) } else { Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Theme.ok : .secondary).font(.system(size: 15)) }
            }.frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }.padding(.vertical, 9)
    }

    private func saveManual() {
        let c = GoogleClient(clientID: manualID.trimmingCharacters(in: .whitespaces), clientSecret: manualSecret.trimmingCharacters(in: .whitespaces))
        guard c.clientID.hasSuffix(".apps.googleusercontent.com") else { model.show("That doesn't look like a Google client ID. It ends in .apps.googleusercontent.com.", error: true); return }
        mail.importClient(c); manualSecret = ""
    }

    /// Polls ~/Downloads (only while this screen is visible) for the file Google downloads, imports it, moves it to the Trash.
    private func startWatching() {
        guard !watching else { return }
        watching = true; started = Date().addingTimeInterval(-300)
        Task {
            while mail.client == nil, !Task.isCancelled {
                if let found = GoogleClient.findDownloaded(since: started) {
                    mail.importClient(found.client)
                    try? FileManager.default.trashItem(at: found.url, resultingItemURL: nil)
                    model.show("Google client imported. Now sign in.")
                    break
                }
                try? await Task.sleep(for: .seconds(2))
            }
            watching = false
        }
    }

    private func installClaude() {
        model.runTask("Installing Claude Code") { log in
            let status = try await Shell.stream("brew", ["install", "--cask", "claude-code"], env: ["HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_ANALYTICS": "1"], onLine: log)
            if status != 0 { throw ShellError.failed(command: "brew install --cask claude-code", status: status, stderr: "") }
        }
    }
}

struct LinkPill: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 12.5)).foregroundStyle(Theme.accent).padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8)).contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
