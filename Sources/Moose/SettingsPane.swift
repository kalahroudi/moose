// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import MooseKit

/// RULES: every tab has content (no empty pages); every control writes straight to Prefs and takes effect at once
/// ("Settings save automatically", no Apply button); every option has a one-line explanation.
struct SettingsPane: View {
    let prefs = Prefs.shared
    @State private var tab: Tab
    enum Tab: Hashable { case general, accounts, updates, about }
    init(initialTab: Tab = .general) { _tab = State(initialValue: initialTab) }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Settings") {
                EmptyView()
            } tabs: {
                TabBar(tabs: [(Tab.general, "General"), (Tab.accounts, "Accounts"), (Tab.updates, "Updates"), (Tab.about, "About")], selection: $tab)
            }
            ScrollView {
                Group {
                    switch tab {
                    case .general: general
                    case .updates: UpdatesView()
                    case .accounts: AccountsView()
                    case .about: about
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack { Text("Moose \(BuildInfo.current.version) · github.com/kalahroudi/moose"); Spacer(); Text("Settings save automatically") }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 8)
        }
    }

    private var general: some View {
        @Bindable var p = prefs
        return HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 18) {
                SettingsGroup("Startup") {
                    SettingRow("Launch at login", "Adds the app to Login Items. Turn it off any time.", error: prefs.launchAtLoginError) { Toggle("", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) })).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }
                }
                SettingsGroup("Appearance") {
                    SettingRow("Theme", "Applies to the Manager window and the menu bar popover.") { Segmented(options: ThemeChoice.allCases.map { ($0, $0.label) }, selection: $p.theme) }
                    SettingRow("Dock icon", "Keep the app in the Dock as well as the menu bar.") { Toggle("", isOn: $p.showDockIcon).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }
                }
            }.frame(maxWidth: .infinity)
            VStack(spacing: 18) {
                SettingsGroup("Performance") {
                    SettingRow("Check mail only when visible", "Moose never polls in the background. It checks when you open the popover or window.") { Badge(text: "always on", kind: .ok) }
                    SettingRow("Check at most every", "While a window is open, Moose rechecks this often.") { Segmented(options: [(60, "1 min"), (300, "5 min"), (900, "15 min")], selection: $p.refreshSeconds) }
                }
                SettingsGroup("Dictation") {
                    SettingRow("Microphone", "Automatic uses your Mac's microphone, and your iPhone when the lid is closed and the Mac is docked. The iPhone must be nearby, signed in to the same Apple Account, with Wi-Fi and Bluetooth on.") { MicrophonePicker() }
                }
                SettingsGroup("Notifications") {
                    SettingRow("Notify when tasks finish", "For longer jobs such as installing Claude Code.") { Toggle("", isOn: $p.notify).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }
                }
            }.frame(maxWidth: .infinity)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: AppIcon.image(size: 72)).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Moose").font(.system(size: 18, weight: .semibold))
                    Text("Version \(BuildInfo.current.version) · \(BuildInfo.current.shortCommit)").foregroundStyle(.secondary)
                    Text("An agentic, text-only Gmail client for people who want less noise.").font(.system(size: 12.5))
                }
            }
            HStack(spacing: 10) {
                Link("Source on GitHub", destination: URL(string: "https://github.com/kalahroudi/moose")!)
                Link("Report an issue", destination: URL(string: "https://github.com/kalahroudi/moose/issues")!)
                Button("Show log") { NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL]) }.buttonStyle(.link)
            }.font(.system(size: 13))
        }
    }
}

struct SettingsGroup<C: View>: View {
    let title: String
    @ViewBuilder var content: C
    init(_ t: String, @ViewBuilder content: () -> C) { title = t; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title).padding(.leading, 4)
            VStack(spacing: 0) { content }.padding(.horizontal, 14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    var error: String?
    @ViewBuilder var control: Control
    init(_ title: String, _ detail: String?, error: String? = nil, @ViewBuilder _ control: () -> Control) { self.title = title; self.detail = detail; self.error = error; self.control = control() }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let d = detail { Text(d).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let e = error { Text(e).font(.system(size: 11.5)).foregroundStyle(Theme.danger) }
            }
            Spacer(minLength: 8)
            control
        }.padding(.vertical, 10).overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

/// Connected Gmail addresses, the Google client, and the sending signature.
struct AccountsView: View {
    let mail = MailModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup("Gmail accounts") {
                ForEach(mail.accounts) { a in
                    SettingRow(a.email, "Connected. Tokens are kept in your Keychain.") { Button("Disconnect") { mail.removeAccount(a.email) }.buttonStyle(Pill(kind: .danger)) }
                }
                SettingRow("Add an address", mail.client == nil ? "Create your Google client first (see the setup screen)." : "Opens Google in your browser.") {
                    if mail.signingIn {
                        Button("Cancel") { mail.cancelSignIn() }.buttonStyle(Pill(kind: .primary))
                    } else {
                        Button { mail.addAccount() } label: { Text("Add account") }.buttonStyle(Pill(kind: .primary)).disabled(mail.client == nil)
                    }
                }
            }
            SettingsGroup("Sending") {
                SettingRow("Signature", "Added under every reply you send from Moose.") {
                    TextField("None", text: Binding(get: { mail.data.sendSignature }, set: { mail.setSignature($0) })).textFieldStyle(.roundedBorder).frame(width: 220)
                }
                SettingRow("Undo window for agent sends", "Only used when an agent has Full access. A reply you send yourself waits 5 seconds.") {
                    Segmented(options: [(10, "10 s"), (30, "30 s"), (60, "60 s")], selection: Binding(get: { mail.data.undoSeconds }, set: { mail.setUndo($0) }))
                }
            }
        }.frame(maxWidth: 640)
    }
}

/// Lists the inputs the Mac currently sees. Re-read each time the menu opens, because a phone comes and goes.
private struct MicrophonePicker: View {
    @State private var mics = Microphones.all()
    var body: some View {
        @Bindable var p = Prefs.shared
        Picker("", selection: $p.microphone) {
            Text("Automatic").tag(Microphones.automatic)
            ForEach(mics) { Text($0.isPhone ? "\($0.name) (iPhone)" : $0.name).tag($0.uid) }
            if p.microphone != Microphones.automatic, !mics.contains(where: { $0.uid == p.microphone }) { Text("Chosen microphone (not connected)").tag(p.microphone) }
        }.labelsHidden().frame(width: 220).onAppear { mics = Microphones.all() }
    }
}
