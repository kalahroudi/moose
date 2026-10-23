// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import CryptoKit

/// The user's own Google OAuth "Desktop" client. Moose is open source and ships no shared client,
/// so nothing about the user's mail ever passes through anyone else's Google project.
public struct GoogleClient: Codable, Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String

    public init(clientID: String, clientSecret: String) { self.clientID = clientID; self.clientSecret = clientSecret }

    /// Parses the `client_secret_*.json` file Google lets you download ({"installed": {...}}).
    public static func parse(_ data: Data) -> GoogleClient? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = (root["installed"] ?? root["web"]) as? [String: Any],
              let id = block["client_id"] as? String, let secret = block["client_secret"] as? String,
              id.hasSuffix(".apps.googleusercontent.com"), !secret.isEmpty else { return nil }
        return GoogleClient(clientID: id, clientSecret: secret)
    }

    public static func load() -> GoogleClient? {
        guard let s = Keychain.get("google-client"), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GoogleClient.self, from: d)
    }
    public func save() throws {
        try Keychain.set(String(decoding: try JSONEncoder().encode(self), as: UTF8.self), for: "google-client")
    }

    /// Looks for a freshly downloaded client file so the user never has to import it by hand.
    public static func findDownloaded(in dir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
                                      since: Date = .distantPast) -> (url: URL, client: GoogleClient)? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files.sorted(by: { mtime($0) > mtime($1) }) where url.lastPathComponent.hasPrefix("client_secret") && url.pathExtension == "json" {
            guard mtime(url) >= since, let d = try? Data(contentsOf: url), let c = parse(d) else { continue }
            return (url, c)
        }
        return nil
    }
    private static func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }

    // Direct links to the exact Google Cloud pages (the one step Google has no API for).
    public static func consoleLinks(project: String?) -> (credentials: URL, consent: URL) {
        let q = project.map { "?project=\($0)" } ?? ""
        return (URL(string: "https://console.cloud.google.com/apis/credentials/oauthclient" + q)!,
                URL(string: "https://console.cloud.google.com/auth/audience" + q)!)
    }
}

public enum GoogleAuthError: Error { case noClient, cancelled, badResponse(String), timedOut }

public struct TokenSet: Sendable { public var access: String; public var expires: Date; public var refresh: String? }

public enum GoogleAuth {
    public static let scope = "https://www.googleapis.com/auth/gmail.modify"

    // MARK: PKCE

    public static func pkcePair() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URL
        return (verifier, Data(SHA256.hash(data: Data(verifier.utf8))).base64URL)
    }

    public static func authURL(client: GoogleClient, redirect: String, challenge: String, state: String, loginHint: String? = nil) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: client.clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state), .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent select_account"),
        ]
        if let h = loginHint { c.queryItems?.append(.init(name: "login_hint", value: h)) }
        return c.url!
    }

    /// Opens the browser, waits for Google to redirect back to a one-shot loopback server, exchanges the code.
    public static func signIn(client: GoogleClient, open: @escaping @Sendable (URL) -> Void) async throws -> TokenSet {
        let pkce = pkcePair(); let state = UUID().uuidString
        let server = LoopbackServer()
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"
        open(authURL(client: client, redirect: redirect, challenge: pkce.challenge, state: state))
        let query = try await server.waitForRequest(timeout: 180)
        guard query["state"] == state else { throw GoogleAuthError.badResponse("state mismatch") }
        guard let code = query["code"] else { throw GoogleAuthError.cancelled }
        return try await token(client: client, params: ["code": code, "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": pkce.verifier])
    }

    public static func refresh(client: GoogleClient, refreshToken: String) async throws -> TokenSet {
        var t = try await token(client: client, params: ["refresh_token": refreshToken, "grant_type": "refresh_token"])
        t.refresh = refreshToken
        return t
    }

    static func token(client: GoogleClient, params: [String: String]) async throws -> TokenSet {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = params; all["client_id"] = client.clientID; all["client_secret"] = client.clientSecret
        req.httpBody = all.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let access = obj["access_token"] as? String else {
            throw GoogleAuthError.badResponse(String(decoding: data.prefix(400), as: UTF8.self))
        }
        return TokenSet(access: access, expires: Date().addingTimeInterval((obj["expires_in"] as? Double ?? 3600) - 60), refresh: obj["refresh_token"] as? String)
    }
}

/// A one-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect and shows a plain "you can close this tab" page.
public final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    private let lock = NSLock()

    public init() {}

    public func start() async throws -> UInt16 {
        let l = try NWListener(using: .tcp, on: .any)
        l.parameters.requiredInterfaceType = .loopback
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        return try await withCheckedThrowingContinuation { cont in
            let box = OnceBox(cont)
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(.success(l.port?.rawValue ?? 0))
                case .failed(let e): box.resume(.failure(e))
                default: break
                }
            }
            l.start(queue: .global())
        }
    }

    public func waitForRequest(timeout: TimeInterval) async throws -> [String: String] {
        defer { listener?.cancel() }
        return try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await self.nextRequest() }
            group.addTask { try await Task.sleep(for: .seconds(timeout)); throw GoogleAuthError.timedOut }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func nextRequest() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            lock.lock(); defer { lock.unlock() }
            if let p = pending { cont.resume(with: p); pending = nil } else { continuation = cont }
        }
    }

    private func deliver(_ r: Result<[String: String], Error>) {
        lock.lock(); defer { lock.unlock() }
        if let c = continuation { continuation = nil; c.resume(with: r) } else { pending = r }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let line = text.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            var q: [String: String] = [:]
            if parts.count >= 2, let comps = URLComponents(string: String(parts[1])) {
                for i in comps.queryItems ?? [] { q[i.name] = i.value ?? "" }
            }
            let ok = q["code"] != nil
            let body = "<html><body style=\"font:16px -apple-system;text-align:center;padding-top:20vh\"><h2>\(ok ? "Moose is connected." : "Nothing was connected.")</h2><p>You can close this tab.</p></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            if parts.count >= 2, String(parts[1]).contains("?") { self.deliver(.success(q)) }   // ignore favicon requests
        }
    }
}

final class OnceBox<T: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Error>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<T, Error>) { cont = c }
    func resume(_ r: Result<T, Error>) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(with: r) }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}

extension String {
    var formEncoded: String { addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? self }
}
