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
        func manager(_ name: String, _ p: Pane, dark: Bool = false, setup: Bool = false, open: Bool = false, id: String = "1", tab: SettingsPane.Tab = .general, folder: String? = nil) -> Shot {
            Shot(name: name + (dark ? "-dark" : ""), dark: dark, size: CGSize(width: 1100, height: 830)) {
                let d = Demo.data()
                MailModel.shared.loadDemo(setup ? MooseData() : d, signedIn: !setup, folders: Demo.folders())
                Nav.shared.folder = folder
                Nav.shared.pane = p; Nav.shared.settingsTab = tab; Nav.shared.account = nil
                Nav.shared.open = open ? MailModel.shared.scored.first { $0.message.id == id }?.message : nil
                return AnyView(ManagerView())
            }
        }
        func pop(dark: Bool = false) -> Shot {
            Shot(name: "popover\(dark ? "-dark" : "")", dark: dark, size: CGSize(width: 800, height: 520)) {
                MailModel.shared.loadDemo(Demo.data(), signedIn: true)
                return AnyView(PopoverShot())
            }
        }
        func stack(_ name: String, dark: Bool, _ configure: @escaping @MainActor (StackModel) -> Void) -> Shot {
            Shot(name: name, dark: dark, size: CGSize(width: 680, height: 620)) {
                MailModel.shared.loadDemo(Demo.data(), signedIn: true, folders: Demo.folders())
                let st = StackModel.shared; st.rebuild(); configure(st)
                return AnyView(StackView())
            }
        }
        return [stack("stack", dark: true) { st in st.index = 1 },
                stack("stack-reading", dark: false) { st in st.index = 0; st.read() },
                stack("stack-reply", dark: false) { st in
                    st.index = 0; st.mode = .replying
                    st.reply = "Hi Maya, thanks. 30 days works for me. I'll sign off Thursday, no call needed.\nBest, M." },
                stack("stack-folder", dark: true) { st in st.setSource(.folder("Work/Clients")) },
                stack("stack-all", dark: true) { st in st.index = 1; st.showAll = true },
                stack("stack-undone", dark: false) { st in
                    st.index = 2; MailModel.shared.apply(.archive, to: MailModel.shared.messages(ids: ["4", "5"]), sender: "Stripe") },
                pop(), pop(dark: true),
                manager("priority", .priority), manager("priority", .priority, dark: true),
                manager("thread", .priority, open: true), manager("thread-brief", .priority, open: true, id: "12"), manager("thread-reply", .priority, dark: true, open: true), manager("routing", .routing), manager("muting", .muting, dark: true),
                manager("agents", .agents, dark: true), manager("setup", .priority, dark: true, setup: true), manager("settings", .settings, tab: .accounts),
                manager("help", .help),
                manager("folder", .folder, folder: "Receipts"), manager("folder", .folder, dark: true, folder: "Work/Clients"), manager("folders", .folders)]
    }

    @MainActor static func render(_ shot: Shot, to dir: String) async {
        AppModel.shared.toast = nil   // a toast from the previous screen must never leak into this one
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

    /// Mail that filing rules moved out of the inbox, for the folder screens. Every folder has mail so no screen shows an empty gap.
    static func folders() -> [String: [MailMessage]] {
        func at(_ h: Int, daysAgo: Int = 0) -> Date {
            let c = Calendar.current
            return c.date(byAdding: .day, value: -daysAgo, to: c.date(bySettingHour: h, minute: 12, second: 0, of: Date())!)!
        }
        var n = 0
        func m(_ name: String, _ from: String, _ subj: String, _ snip: String, _ date: Date, unread: Bool = false) -> MailMessage {
            n += 1
            return MailMessage(id: "f\(n)", threadId: "f\(n)", account: "me@gmail.com", fromName: name, fromEmail: from, subject: subj, snippet: snip, date: date, unread: unread)
        }
        return [
            "Receipts": [
                m("Stripe", "receipts@stripe.com", "Your receipt from Acme Ltd #2041", "Amount paid $48.00. Paid with Visa ending 4242.", at(7), unread: true),
                m("Stripe", "receipts@stripe.com", "Your receipt from Figma #1190", "Amount paid $15.00.", at(7, daysAgo: 3)),
                m("Stripe", "receipts@stripe.com", "Your receipt from Notion #8842", "Amount paid $10.00.", at(7, daysAgo: 9)),
                m("Figma", "billing@figma.example", "Invoice for October", "Your invoice for the Professional plan is ready.", at(9, daysAgo: 2), unread: true),
                m("Cloudhost", "billing@cloudhost.example", "Payment received", "Thanks, we received your payment of $22.00.", at(10, daysAgo: 5))],
            "Travel": [
                m("SkyAir", "bookings@skyair.example", "Your booking is confirmed", "Flight to Madrid on 3 November, seat 14A.", at(13, daysAgo: 4), unread: true),
                m("SkyAir", "checkin@skyair.example", "Check-in opens in 24 hours", "Check in online to choose your seat.", at(8, daysAgo: 1), unread: true),
                m("Stayly", "reservations@stayly.example", "Reservation confirmed: Hotel Alba", "3 nights from 3 November.", at(16, daysAgo: 6))],
            "Banking": [
                m("Northbank", "statements@northbank.example", "Your October statement is ready", "Your statement for account ending 0192 is available.", at(6, daysAgo: 1), unread: true),
                m("Northbank", "alerts@northbank.example", "Large payment alert", "A payment of $240.00 left your account.", at(14, daysAgo: 3)),
                m("Northbank", "statements@northbank.example", "Your September statement is ready", "Your statement for account ending 0192 is available.", at(6, daysAgo: 31))],
            "Work/Clients": [
                m("Dana Reyes", "dana@orbit.example", "Mockups for review", "Attached are the latest mockups. Feedback by Thursday?", at(11), unread: true),
                m("Dana Reyes", "dana@orbit.example", "Re: Scope of work", "Happy with the revised scope. Sending the contract today.", at(15, daysAgo: 2)),
                m("Sam Okafor", "sam@harbor.example", "Invoice 1043 approved", "We approved the invoice, payment goes out on the 28th.", at(9, daysAgo: 4)),
                m("Sam Okafor", "sam@harbor.example", "Kick-off call", "Does Tuesday at 10 work for the kick-off?", at(12, daysAgo: 8))],
            "Health": [
                m("Greenfield Clinic", "appointments@greenfield.example", "Appointment reminder", "Your appointment is on Monday at 09:30.", at(8, daysAgo: 1), unread: true),
                m("Greenfield Clinic", "appointments@greenfield.example", "Your test results", "Your results are ready to view in the patient portal.", at(10, daysAgo: 6)),
                m("PharmaPlus", "orders@pharmaplus.example", "Your prescription is ready", "Collect from the counter within 7 days.", at(13, daysAgo: 12))],
            "Reading list": [
                m("The Long Read", "editor@longread.example", "The quiet rise of tiny software", "This week: how small teams build products people love.", at(6), unread: true),
                m("Weekly Digest", "hello@digest.example", "Ten ideas worth your time", "Our picks for the week.", at(6, daysAgo: 4)),
                m("The Long Read", "editor@longread.example", "Why we stopped using meetings", "A field report from three remote teams.", at(6, daysAgo: 11))],
            "Home": [
                m("Cityline Utilities", "bills@cityline.example", "Your energy bill is ready", "Your bill of $86.40 is due on 5 November.", at(7, daysAgo: 2), unread: true),
                m("Cityline Utilities", "bills@cityline.example", "Meter reading reminder", "Please submit a meter reading this month.", at(7, daysAgo: 10)),
                m("Pat Morgan", "pat@lettings.example", "Re: Boiler service", "The engineer can visit on Friday between 8 and 12.", at(17, daysAgo: 5))],
        ]
    }

    static func data() -> MooseData {
        var d = MooseData()
        d.accounts = [MailAccount(email: "me@gmail.com", colorIndex: 0), MailAccount(email: "work@acme.com", colorIndex: 1), MailAccount(email: "studio@me.dev", colorIndex: 2)]
        d.favourites = ["maya@acme.com", "mum@family.example"]
        d.repliedTo = ["ahmad@example.com", "billing@stripe.com"]
        d.rules = [Rule(senders: ["club.example"], action: .mute, source: "you"), Rule(keywords: ["invoice", "payment"], action: .boost(25), source: "Claude"),
                   Rule(senders: ["stripe.com", "billing@"], action: .file("Receipts"), source: "you"), Rule(keywords: ["flight", "booking", "reservation"], action: .file("Travel"), source: "you"),
                   Rule(senders: ["northbank.example"], action: .file("Banking"), source: "you"), Rule(senders: ["orbit.example", "harbor.example"], action: .file("Work/Clients"), source: "you"),
                   Rule(senders: ["greenfield.example", "pharmaplus.example"], action: .file("Health"), source: "you"), Rule(senders: ["longread.example", "digest.example"], action: .file("Reading list"), source: "you"),
                   Rule(senders: ["cityline.example"], action: .file("Home"), source: "you")]
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
            msg("12", "me@gmail.com", "Revenue Services Help", "news@revenue.example", "100 days to go: submit your tax return now", "You now have 100 days left until the deadline to submit your online tax return.", at(13, 33), labels: ["INBOX", "CATEGORY_UPDATES"]),
            msg("11", "me@gmail.com", "Bob", "bob@example.com", "fyi", "Saw this and thought of you.", at(10, 0, daysAgo: 9), unread: false),
        ]
        d.syncedAt = ["me@gmail.com": Date()]
        d.composeDrafts["1"] = "Hi Maya, the signatory is Alex Rivera, Director. Yes, let's keep the 12-month renewal."
        return d
    }

    /// Full texts for the sample messages, as an email would really arrive: broken lines, blank runs, tracking links and a footer.
    static let bodies: [String: String] = [
        "1": """
        Hi,

        I've addressed Legal's note on §4 and the termination clause is now 30 days. The payment schedule in §7 is unchanged.

        Two small things I still need from you: the signatory name for the cover page, and whether we keep the 12-month renewal term.

        Can you sign off by Friday so we can send it over? Happy to hop on a call if that's easier.

        Thanks,
        Maya
        """,
        "12": """
        https://mail.revenue.example/seeemailinfull/EmailServlet?campaignkw=notrack&tid=cc-0_1792758791602004551&signature=5C168635A64C09291EFAABDE6DD2A3D9



        Dear customer,

        You now have 100


        days left until the deadline to submit your online tax return for the 2025


        to


        2026 tax year.

        If you've already submitted your tax return, or you've told us you no longer need to send one, thank you. You don't need to do anything else.

        File now and get it off your to-do list. You don't have to wait until 31 January.

        File your return: https://www.gov.example/self-assessment

        To unsubscribe from these emails, click here: https://mail.revenue.example/unsubscribe?id=8812&signature=ab12cd34ef56
        Privacy policy
        """,
    ]

    static let briefs: [String: MailBrief] = [
        "1": MailBrief(summary: "Maya wants your sign-off on the contract by Friday and needs two answers from you first.", points: ["Termination clause is now 30 days; payment schedule is unchanged", "Needs the signatory name for the cover page", "Asks whether the 12-month renewal term stays"], asks: "sign off by Friday, name the signatory, confirm the renewal term", replyNeeded: true, urgency: "high", dates: ["by Friday"]),
        "12": MailBrief(summary: "A reminder that your online tax return for the 2026 tax year is due in 100 days. Nothing is needed if you already filed.", points: ["You can file now, you don't have to wait for the deadline", "If you've already filed, ignore this", "Automated campaign mail, nothing personal"], asks: "file your return, if you haven't already", replyNeeded: false, urgency: "low", dates: ["100 days left", "31 January"]),
    ]
}
