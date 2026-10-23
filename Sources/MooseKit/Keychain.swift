// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Secrets (refresh tokens, the user's Google client secret) live only in the Keychain.
///
/// All of them are kept in ONE Keychain item and read once per launch, then served from memory. macOS asks for permission
/// per item, so one item means at most one prompt (and "Always Allow" sticks). Items are updated in place, never deleted and
/// re-added, because re-adding resets the permission the user granted. Older versions stored one item per secret; those are
/// moved into the single item the first time they are asked for.
public enum Keychain {
    static let service = "com.kalahroudi.moose"
    private static let vaultKey = "vault"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: String]?

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
        var q = query(vaultKey); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { cache = [:]; return [:] }
        guard status == errSecSuccess, let d = out as? Data, let v = try? JSONDecoder().decode([String: String].self, from: d) else { throw KeychainError.status(status) }
        cache = v
        return v
    }

    private static func save(_ v: [String: String]) throws {
        let data = try JSONEncoder().encode(v)
        var status = SecItemUpdate(query(vaultKey) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(vaultKey)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        cache = v
    }
}

public enum KeychainError: Error { case status(OSStatus) }
