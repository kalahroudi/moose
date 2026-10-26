// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Secrets (refresh tokens, the user's Google client secret) live only in the Keychain.
///
/// All of them are kept in ONE Keychain item and read once per launch, then served from memory. macOS asks for permission
/// per item, so one item means at most one prompt (and "Always Allow" sticks). Items are updated in place, never deleted and
/// re-added, because re-adding resets the permission the user granted. Older versions stored one item per secret; those are
/// moved into the single item the first time they are asked for.
///
/// The item is created with an access list naming both the app and its `moose-mcp` helper, so neither needs its own
/// "Always Allow". Builds are signed with a stable designated requirement (see scripts/bundle.sh), so the list keeps
/// matching after updates. A refused prompt is remembered for a few minutes instead of asking again on every call.
public enum Keychain {
    static let service = "com.kalahroudi.moose"
    private static let vaultKey = "vault"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: String]?
    private nonisolated(unsafe) static var refusedAt: Date?
    private nonisolated(unsafe) static var legacyChecked: Set<String> = []
    private static let aclKey = "_acl", aclVersion = "2"
    private static let refusalCooldown: TimeInterval = 300

    public static func set(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        var v = try load()
        v[key] = value
        try save(v)
    }

    public static func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard var v = try? load() else { return nil }
        if let s = v[key] { return s }
        // Written by an older version as its own item: move it in.
        guard !legacyChecked.contains(key) else { return nil }
        legacyChecked.insert(key)
        guard let old = read(key) else { return nil }
        v[key] = old
        if (try? save(v)) != nil { delete(key) }
        return old
    }

    public static func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        delete(key)
        guard var v = try? load(), v.removeValue(forKey: key) != nil else { return }
        try? save(v)
    }

    // MARK: Plumbing (call with the lock held)

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    private static func read(_ key: String) -> String? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }

    /// An unreadable vault (user pressed Deny) throws instead of looking empty, so a later write can't wipe it.
    private static func load() throws -> [String: String] {
        if let c = cache { return c }
        if let t = refusedAt, Date().timeIntervalSince(t) < refusalCooldown { throw KeychainError.status(errSecAuthFailed) }
        var q = query(vaultKey); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { cache = [:]; return [:] }
        guard status == errSecSuccess, let d = out as? Data, let v = try? JSONDecoder().decode([String: String].self, from: d) else {
            if status == errSecAuthFailed || status == errSecUserCanceled || status == errSecInteractionNotAllowed { refusedAt = Date() }
            throw KeychainError.status(status)
        }
        refusedAt = nil
        cache = v
        if v[aclKey] != aclVersion { upgradeAccess(v) }
        return cache ?? v
    }

    /// Items made by older versions only trust the app that made them. Re-create the item once with the full access list.
    private static func upgradeAccess(_ v: [String: String]) {
        var v = v
        v[aclKey] = aclVersion
        guard let data = try? JSONEncoder().encode(v), let access = trustedAccess() else { return }
        let old = cache
        delete(vaultKey)
        var add = query(vaultKey)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrAccess as String] = access
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { cache = v } else {
            // Put the secrets back the way they were rather than lose them.
            var back = query(vaultKey)
            back[kSecValueData as String] = (try? JSONEncoder().encode(old ?? [:])) ?? data
            SecItemAdd(back as CFDictionary, nil)
            cache = old
        }
    }

    /// The app and its MCP helper, which live side by side in Contents/MacOS.
    private static func trustedAccess() -> SecAccess? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        var apps: [SecTrustedApplication] = []
        for name in ["Moose", "moose-mcp"] {
            var app: SecTrustedApplication?
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path),
               SecTrustedApplicationCreateFromPath(dir.appendingPathComponent(name).path, &app) == errSecSuccess, let app { apps.append(app) }
        }
        guard !apps.isEmpty else { return nil }
        var access: SecAccess?
        return SecAccessCreate("Moose" as CFString, apps as CFArray, &access) == errSecSuccess ? access : nil
    }

    private static func save(_ v: [String: String]) throws {
        var v = v
        let access = trustedAccess()
        if access != nil { v[aclKey] = aclVersion }
        let data = try JSONEncoder().encode(v)
        var status = SecItemUpdate(query(vaultKey) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(vaultKey)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if let access { add[kSecAttrAccess as String] = access }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        cache = v
    }
}

public enum KeychainError: Error { case status(OSStatus) }
