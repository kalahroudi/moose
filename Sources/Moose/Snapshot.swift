// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import MooseKit

/// `Moose --snapshot <dir>` renders the app's screens to PNG files for the docs, then exits.
/// It uses made-up sample data, never the user's real data. Add a Shot per screen/theme you want in the README.
enum SnapshotMode {
    nonisolated(unsafe) static var dir: String?

    @MainActor static func run() {
        guard let dir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.accessory)
        Demo.install()
        Task { @MainActor in
            for shot in shots { await render(shot, to: dir) }
            NSApp.terminate(nil)
        }
    }

    struct Shot { let name: String; let dark: Bool; let size: CGSize; let make: @MainActor () -> AnyView }

    @MainActor static var shots: [Shot] {
        func manager(_ name: String, _ p: Pane, dark: Bool = false, setup: Bool = false, open: Bool = false, tab: SettingsPane.Tab = .general) -> Shot {
            Shot(name: name + (dark ? "-dark" : ""), dark: dark, size: CGSize(width: 1100, height: 720)) {
                let d = Demo.data()
                MailModel.shared.loadDemo(setup ? MooseData() : d, signedIn: !setup)
                Nav.shared.pane = p; Nav.shared.settingsTab = tab; Nav.shared.account = nil
                Nav.shared.open = open ? MailModel.shared.scored.first { $0.message.fromEmail == "maya@acme.com" }?.message : nil
                return AnyView(ManagerView())
            }
        }
        func pop(dark: Bool = false) -> Shot {
            Shot(name: "popover\(dark ? "-dark" : "")", dark: dark, size: CGSize(width: 800, height: 520)) {
                MailModel.shared.loadDemo(Demo.data(), signedIn: true)
                return AnyView(PopoverShot())
            }
        }
        return [pop(), pop(dark: true),
                manager("priority", .priority), manager("priority", .priority, dark: true),
                manager("thread", .priority, open: true), manager("routing", .routing), manager("muting", .muting, dark: true),
                manager("agents", .agents, dark: true), manager("setup", .priority, dark: true, setup: true), manager("settings", .settings, tab: .accounts),
                manager("help", .help)]
    }

    @MainActor static func render(_ shot: Shot, to dir: String) async {
        let host = NSHostingView(rootView: shot.make().frame(width: shot.size.width, height: shot.size.height))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: shot.size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -4000, y: 0))   // off screen, but still laid out and drawn
        win.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(shot.name + ".png")) }
        win.orderOut(nil)
    }
}

/// A menu bar with the popover hanging from the icon, on a soft backdrop. Used only for screenshots.
struct PopoverShot: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color(red: 0.62, green: 0.71, blue: 0.78), Color(red: 0.29, green: 0.37, blue: 0.49)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text("Finder").bold(); Text("File"); Text("Edit"); Text("View")
                    Spacer()
                    Image(nsImage: StatusIcon.image(.active)).renderingMode(.template).padding(.horizontal, 6).padding(.vertical, 2).background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    Text("Tue 20 Oct  9:41")
                }.font(.system(size: 13)).foregroundStyle(.primary).padding(.horizontal, 14).frame(height: 28).background(.regularMaterial)
                PopoverView(openManager: { _ in })
                    .clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.15)))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12).padding(.top, 8).padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Spacer()
            }
        }
    }
}

/// Made-up data that looks like a typical day. Never real mail.
@MainActor enum Demo {
    static func install() { AppModel.shared.demo = true; AppModel.shared.status = "3 stacks need you"; AppModel.shared.loadedOnce = true; AppModel.shared.updatedAt = .now }

    static func data() -> MooseData {
        var d = MooseData()
        d.accounts = [MailAccount(email: "me@gmail.com", colorIndex: 0), MailAccount(email: "work@acme.com", colorIndex: 1), MailAccount(email: "studio@me.dev", colorIndex: 2)]
        d.favourites = ["maya@acme.com", "mum@family.example"]
        d.repliedTo = ["ahmad@example.com", "billing@stripe.com"]
        d.rules = [Rule(senders: ["club.example"], action: .mute, source: "you"), Rule(keywords: ["invoice", "payment"], action: .boost(25), source: "Claude")]
        func at(_ h: Int, _ m: Int, daysAgo: Int = 0) -> Date {
            let c = Calendar.current
            return c.date(byAdding: .day, value: -daysAgo, to: c.date(bySettingHour: h, minute: m, second: 0, of: Date())!)!
        }
        func msg(_ id: String, _ acct: String, _ name: String, _ from: String, _ subj: String, _ snip: String, _ date: Date, unread: Bool = true, labels: [String] = ["INBOX"], bulk: Bool = false) -> MailMessage {
            MailMessage(id: id, threadId: id, account: acct, fromName: name, fromEmail: from, subject: subj, snippet: snip, date: date, unread: unread, labels: labels, bulkHeader: bulk)
        }
        d.messages = [
            msg("1", "work@acme.com", "Maya Chen", "maya@acme.com", "Contract redlines: can you sign off by Friday?", "Hi, I've addressed Legal's note on §4 and the termination clause is now 30 days. Can you sign off by Friday so we can send it over? Happy to hop on a call if that's easier. Maya", at(9, 41)),
            msg("2", "work@acme.com", "Maya Chen", "maya@acme.com", "Re: Q4 budget", "Numbers attached, only the headcount line is open.", at(8, 12)),
            msg("3", "work@acme.com", "Maya Chen", "maya@acme.com", "Lunch Thursday?", "Same place as last time?", at(12, 0, daysAgo: 3), unread: false),
            msg("4", "studio@me.dev", "Stripe", "billing@stripe.com", "Payment of $240.00 failed", "Update your card to avoid interruption of your subscription.", at(7, 30)),
            msg("5", "studio@me.dev", "Stripe", "billing@stripe.com", "Your weekly summary", "Gross volume is up 8% from last week.", at(10, 0, daysAgo: 4), unread: false),
            msg("6", "me@gmail.com", "Mum", "mum@family.example", "Sunday?", "Are you coming for dinner? I need to know how much to cook.", at(18, 20, daysAgo: 1)),
            msg("7", "me@gmail.com", "Ahmad R.", "ahmad@example.com", "Re: flat viewing", "Works for me, 6pm. Bring the deposit form?", at(16, 5, daysAgo: 1)),
            msg("8", "me@gmail.com", "Substack Digest", "digest@substack.example", "Your weekly reads", "Ten stories picked for you this week.", at(6, 0), labels: ["INBOX", "CATEGORY_UPDATES"], bulk: true),
            msg("9", "me@gmail.com", "Shoply", "deals@shoply.example", "48 hours only: 30% off", "Don't miss out on our biggest sale.", at(5, 10), labels: ["INBOX", "CATEGORY_PROMOTIONS"], bulk: true),
            msg("10", "work@acme.com", "GitHub", "noreply@github.com", "[acme/api] Run failed: CI", "The workflow run failed on main.", at(9, 5), labels: ["INBOX", "CATEGORY_UPDATES"], bulk: true),
            msg("11", "me@gmail.com", "Bob", "bob@example.com", "fyi", "Saw this and thought of you.", at(10, 0, daysAgo: 9), unread: false),
        ]
        d.syncedAt = ["me@gmail.com": Date()]
        return d
    }
}
