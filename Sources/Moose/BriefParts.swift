// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit

/// A small pill used for dates, urgency and link counts on a brief.
struct BriefChip: View {
    let text: String
    let icon: String
    var warn = false
    var small = false
    var body: some View {
        HStack(spacing: 5) { Image(systemName: icon).font(.system(size: small ? 9 : 10)); Text(text) }
            .font(.system(size: small ? 11.5 : 12)).padding(.horizontal, small ? 8 : 10).padding(.vertical, small ? 2 : 3)
            .foregroundStyle(warn ? Theme.accent : Color.primary)
            .background(warn ? Theme.accentSoft : Theme.fill, in: Capsule())
            .overlay(Capsule().stroke(warn ? Theme.accent.opacity(0.6) : Theme.hairline))
    }
}

/// Appears next to selected email text: reply to that passage, or copy it.
struct QuotePopover: View {
    let text: String
    let reply: () -> Void
    let done: () -> Void
    var body: some View {
        HStack(spacing: 2) {
            Button(action: reply) { Text("Reply to this").fontWeight(.semibold).padding(.horizontal, 10).padding(.vertical, 4).background(Theme.accent, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(Theme.onAccent) }.buttonStyle(.plain)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); done() } label: { Text("Copy").padding(.horizontal, 10).padding(.vertical, 4) }.buttonStyle(.plain)
        }.font(.system(size: 12.5)).padding(4).foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .background(Color(nsColor: .labelColor), in: RoundedRectangle(cornerRadius: 9)).shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}
