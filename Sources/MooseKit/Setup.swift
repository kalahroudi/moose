// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One thing the app needs before it is useful: a tool, a runtime, a first-run resource.
/// The setup screen renders these as a checklist and does everything it can by itself.
/// Whatever it cannot do (admin password, a licence click, a system permission) becomes a manual step
/// with a copyable command, so nothing is ever left as "go read the README".
public struct Prereq: Identifiable, Equatable, Sendable {
    public enum Install: Equatable, Sendable {
        case brew(String)               // `brew install <formula>`, automated
        case command(String)            // runs in the user's terminal (needs a password or a TTY)
        case link(String)               // a download page; the user does it, then presses "check again"
        case none                       // nothing to install; only detected (e.g. a first-run resource)
    }
    public let id: String
    public let title: String
    public let detail: String           // why it is needed, in one plain sentence
    public let install: Install
    public var isMet: Bool
    public var required: Bool

    public init(id: String, title: String, detail: String, install: Install, isMet: Bool, required: Bool = true) {
        self.required = required; self.id = id; self.title = title; self.detail = detail; self.install = install; self.isMet = isMet
    }
}

public struct SetupState: Equatable, Sendable {
    public var items: [Prereq]
    public init(items: [Prereq]) { self.items = items }

    /// What Moose needs before it is useful: the user's own Google client, one connected account, and (optionally) Claude for drafting.
    public static func detect(paths: AppPaths = AppPaths()) -> SetupState {
        let data = DataStore(paths: paths).load()
        return SetupState(items: [
            Prereq(id: "google", title: "Your Google client", detail: "Moose uses a Google sign-in client that you own, so your mail never passes through anyone else.",
                   install: .none, isMet: GoogleClient.load() != nil),
            Prereq(id: "account", title: "A Gmail account", detail: "Sign in once in your browser. Add more addresses any time.",
                   install: .none, isMet: !data.accounts.isEmpty),
            Prereq(id: "claude", title: "Claude for drafting replies", detail: "Optional. Install Claude Code and Moose can draft replies in your voice. No API key is stored.",
                   install: .command("brew install --cask claude-code"), isMet: Shell.find("claude") != nil, required: false),
        ])
    }

    public var missing: [Prereq] { items.filter { !$0.isMet && $0.required } }
    public var ready: Bool { missing.isEmpty }
    public var brewFormulae: [String] { missing.compactMap { if case .brew(let f) = $0.install { f } else { nil } } }
    public var homebrewPresent: Bool { Shell.find("brew") != nil }
    /// Can the app install everything missing by itself?
    public var canAutoInstall: Bool {
        missing.allSatisfy { if case .brew = $0.install { homebrewPresent } else { false } }
    }
    /// One line the user can paste into Terminal to do the automated part by hand.
    public var manualCommand: String { brewFormulae.isEmpty ? "" : "brew install " + brewFormulae.joined(separator: " ") }

    /// The official Homebrew installer. It asks for a password, so it runs in a terminal, never silently.
    public static let homebrewInstallCommand = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

    /// Runs `brew install` for the missing formulae and streams its output.
    public static func installMissing(_ formulae: [String], onLine: @escaping @Sendable (String) -> Void) async throws {
        guard !formulae.isEmpty else { return }
        let env = ["HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_ANALYTICS": "1"]
        let status = try await Shell.stream("brew", ["install"] + formulae, env: env, onLine: onLine)
        if status != 0 { throw ShellError.failed(command: "brew install", status: status, stderr: "brew install \(formulae.joined(separator: " ")) failed. See the log for details.") }
    }
}
