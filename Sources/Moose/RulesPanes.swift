// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import MooseKit

/// Plain-language rules for what is favourite, boosted or muted. Moose scores everything else on its own.
struct RoutingPane: View {
    let mail = MailModel.shared
    @State private var text = ""
    @State private var hint: String?
    private var rules: [Rule] { mail.rules.filter { $0.action != .mute } }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Routing", subtitle: "Plain-language rules. Moose scores the rest on its own.")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    RuleInput(text: $text, hint: $hint, placeholder: "favourite maya@acme.com   ·   boost invoice, payment by 25")
                    if !mail.favourites.isEmpty {
                        RuleCard(symbol: "star.fill", title: "from " + mail.data.favourites.sorted().joined(separator: ", "), action: "always Priority", meta: "favourites · \(mail.favourites.count)", onDelete: nil, enabled: nil)
                    }
                    ForEach(rules) { r in RuleCard(rule: r) }
                    if rules.isEmpty && mail.favourites.isEmpty {
                        Text("No rules yet. Star a sender, or describe a rule above.").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.top, 20).frame(maxWidth: .infinity)
                    }
                }.padding(16)
            }
        }
    }
}

struct MutingPane: View {
    let mail = MailModel.shared
    @State private var text = ""
    @State private var hint: String?
    private var rules: [Rule] { mail.rules.filter { $0.action == .mute } }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Muting", subtitle: "Noise-free by default: newsletters, promos and automated mail are muted, never deleted.")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    RuleInput(text: $text, hint: $hint, placeholder: "mute newsletters, promos   ·   mute from news@club.com")
                    HStack(spacing: 8) {
                        ForEach(mail.mutedSummary(), id: \.0) { b, n in Badge(text: "\(n) \(b.label)") }
                        Spacer()
                        Button("Review muted") { Nav.shared.pane = .muted }.buttonStyle(Pill())
                    }
                    SectionLabel("Your mute rules").padding(.top, 6)
                    ForEach(rules) { r in RuleCard(rule: r) }
                    if rules.isEmpty { Text("No custom mute rules. Moose already mutes bulk mail from its headers.").font(.system(size: 12.5)).foregroundStyle(.secondary) }
                }.padding(16)
            }
        }
    }
}

struct RuleInput: View {
    @Binding var text: String
    @Binding var hint: String?
    let placeholder: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 13)).onSubmit(add)
                Button("Add rule") { add() }.buttonStyle(Pill(kind: .primary)).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4])))
            if let h = hint { Text(h).font(.system(size: 11.5)).foregroundStyle(Theme.danger).padding(.leading, 4) }
        }
    }
    private func add() {
        guard let r = RuleParser.parse(text) else { hint = "Moose didn't understand that. Try \"mute newsletters\", \"favourite maya@acme.com\" or \"boost invoice by 25\"."; return }
        MailModel.shared.addRule(r); text = ""; hint = nil
    }
}

struct RuleCard: View {
    var symbol: String
    var title: String
    var action: String
    var meta: String
    var onDelete: (() -> Void)?
    var enabled: Binding<Bool>?

    init(symbol: String, title: String, action: String, meta: String, onDelete: (() -> Void)?, enabled: Bool?) {
        self.symbol = symbol; self.title = title; self.action = action; self.meta = meta; self.onDelete = onDelete; self.enabled = nil
    }

    init(rule: Rule) {
        let m = MailModel.shared
        symbol = rule.action == .mute ? "bell.slash" : rule.action == .favourite ? "star.fill" : "arrow.up.right"
        title = rule.title; action = rule.actionText
        meta = rule.source == "you" ? "yours" : "added by \(rule.source)"
        onDelete = { m.removeRule(rule.id) }
        enabled = Binding(get: { rule.enabled }, set: { m.setRule(rule.id, enabled: $0) })
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 18)
            Text(title).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.accent).lineLimit(1)
            Text("→ \(action)").font(.system(size: 13))
            Spacer()
            Text(meta).font(.system(size: 11.5)).foregroundStyle(.secondary)
            if let e = enabled { Toggle("", isOn: e).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.accent) }
            if let d = onDelete { Button(action: d) { Image(systemName: "trash").foregroundStyle(.secondary).padding(4).contentShape(Rectangle()) }.buttonStyle(.plain).help("Delete rule").accessibilityLabel("Delete rule") }
        }.padding(.horizontal, 12).padding(.vertical, 9).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }
}

/// Agents: connect them, and decide how much they may do with your mail.
struct AgentsPane: View {
    let mail = MailModel.shared
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Agents", subtitle: "Moose is MCP-first: everything you can do here, an agent can do too.")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsGroup("Agent access") {
                        SettingRow("What agents may do", mail.access.explanation) {
                            Segmented(options: AgentAccess.allCases.map { ($0, $0.label) }, selection: Binding(get: { mail.access }, set: { mail.access = $0 }))
                        }
                    }
                    AgentsView()
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
