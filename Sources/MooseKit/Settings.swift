// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How much an agent may do with mail. Stored where both the app and `moose-mcp` can read it.
public enum AgentAccess: String, Codable, CaseIterable, Sendable {
    case readOnly, draftAndAsk, full
    public var label: String { switch self { case .readOnly: "Read only"; case .draftAndAsk: "Draft & ask"; case .full: "Full access" } }
    public var explanation: String {
        switch self {
        case .readOnly: "Agents can read and organise (mark read, mute, favourite). They cannot write or send."
        case .draftAndAsk: "Agents write drafts. Every send needs your approval in a native dialog."
        case .full: "Agents may send without asking. Every send is logged and can be undone for 30 seconds."
        }
    }
    public var canDraft: Bool { self != .readOnly }
}

/// State shared by the app and the MCP server. Kept small and plain JSON so it is easy to inspect.
public struct MooseData: Codable, Sendable {
    public var version = 1
    public var accounts: [MailAccount] = []
    public var favourites: [String] = []
    public var rules: [Rule] = []
    public var repliedTo: [String] = []
    public var agentAccess: AgentAccess = .draftAndAsk
    public var undoSeconds = 30
    public var sendSignature = ""
    public var messages: [MailMessage] = []
    public var syncedAt: [String: Date] = [:]
    /// Reply text the user is in the middle of writing, by message id. Survives quit and crash (rule: work is never lost).
    public var composeDrafts: [String: String] = [:]
    /// Folder names in the order the user arranged them. Folders themselves come from the filing rules (see `Folders`).
    public var folderOrder: [String] = []
    /// Messages the user moved back to the inbox from a folder. Filing rules leave them alone.
    public var keepInInbox: [String] = []
    /// The newest mail of each folder (by `Folders.key`), so a folder opens at once and is refreshed from Gmail behind it.
    public var folderCache: [String: [MailMessage]] = [:]
    public init() {}

    /// Every key is optional on disk, so a file written by an older version still loads instead of being treated as corrupt.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        accounts = try c.decodeIfPresent([MailAccount].self, forKey: .accounts) ?? []
        favourites = try c.decodeIfPresent([String].self, forKey: .favourites) ?? []
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        repliedTo = try c.decodeIfPresent([String].self, forKey: .repliedTo) ?? []
        agentAccess = try c.decodeIfPresent(AgentAccess.self, forKey: .agentAccess) ?? .draftAndAsk
        undoSeconds = try c.decodeIfPresent(Int.self, forKey: .undoSeconds) ?? 30
        sendSignature = try c.decodeIfPresent(String.self, forKey: .sendSignature) ?? ""
        messages = try c.decodeIfPresent([MailMessage].self, forKey: .messages) ?? []
        syncedAt = try c.decodeIfPresent([String: Date].self, forKey: .syncedAt) ?? [:]
        composeDrafts = try c.decodeIfPresent([String: String].self, forKey: .composeDrafts) ?? [:]
        folderOrder = try c.decodeIfPresent([String].self, forKey: .folderOrder) ?? []
        keepInInbox = try c.decodeIfPresent([String].self, forKey: .keepInInbox) ?? []
        folderCache = try c.decodeIfPresent([String: [MailMessage]].self, forKey: .folderCache) ?? [:]
    }

    public var context: PriorityContext {
        PriorityContext(favourites: Set(favourites), repliedTo: Set(repliedTo), rules: rules)
    }
    public func scored() -> [ScoredMessage] { Priority.scoreAll(messages, context) }
}

/// Atomic JSON persistence for `MooseData` (temp file + rename), with a .bak and a .corrupt fallback.
public struct DataStore: Sendable {
    public let file: URL
    public init(paths: AppPaths = AppPaths()) { file = paths.root.appendingPathComponent("moose.json") }
    public init(file: URL) { self.file = file }

    public func load() -> MooseData {
        let fm = FileManager.default
        guard let raw = try? Data(contentsOf: file) else { return MooseData() }
        let dec = Self.decoder
        if let d = try? dec.decode(MooseData.self, from: raw) { return d }
        // Unreadable: keep it for support, try the backup, never crash and never silently discard.
        try? fm.moveItem(at: file, to: file.appendingPathExtension("corrupt"))
        if let bak = try? Data(contentsOf: file.appendingPathExtension("bak")), let d = try? dec.decode(MooseData.self, from: bak) { return d }
        return MooseData()
    }

    public func save(_ data: MooseData) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try Self.encoder.encode(data)
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".moose-\(UUID().uuidString).tmp")
        try out.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: file.path) {
            try? fm.removeItem(at: file.appendingPathExtension("bak"))
            try? fm.copyItem(at: file, to: file.appendingPathExtension("bak"))
            _ = try fm.replaceItemAt(file, withItemAt: tmp)
        } else { try fm.moveItem(at: tmp, to: file) }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
