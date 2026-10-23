// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import MooseKit

/// Plain-language help and a glossary. Every option in Settings that introduces a term gets an entry here.
struct HelpPane: View {
    private let terms: [(String, String)] = [
        ("Stack", "All mail from one sender, grouped into a single card. Ranked by the most important message inside."),
        ("Priority score", "0–100, worked out on your Mac from: favourites, people you write to, questions, deadlines, money, security notices, unread and recent. The reason is shown next to each stack."),
        ("Favourite", "A sender that always ranks high and is never auto-muted."),
        ("Muted", "Newsletters, promos and automated mail. Muted mail is hidden from Priority but never deleted; review it any time."),
        ("Routing", "Rules in plain English: favourite someone, boost a topic, mute for a while, or file mail into a folder (a Gmail label) like “move emails from cassiobury school to Cassiobury School”."),
        ("Agent access", "How much an AI agent connected over MCP may do. Read only, Draft & ask (you approve every send) or Full access (with a short undo window)."),
        ("Google client", "A sign-in key you create once in your own Google Cloud account. Moose is open source and ships none, so no one else ever sees your mail."),
        ("MCP", "Model Context Protocol: the standard way AI agents such as Claude Code use apps. Moose ships its own MCP server."),
    ]
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Help", subtitle: "Moose reads text only. It never loads images or tracking pixels.")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(terms, id: \.0) { t in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.0).font(.system(size: 13, weight: .semibold))
                            Text(t.1).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).card()
                    }
                }.padding(22).frame(maxWidth: 720, alignment: .leading)
            }
        }
    }
}
