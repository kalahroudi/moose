// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network

/// The app is the only process that holds Gmail tokens and writes mail data. `moose-mcp` reads the cache directly
/// and sends every action here, over loopback with a bearer token stored in a 0600 file.
public struct ControlInfo: Codable, Sendable { public var port: UInt16; public var token: String; public var pid: Int32 }

public typealias ControlHandler = @Sendable (_ tool: String, _ args: [String: Any]) async -> (ok: Bool, text: String)

public final class ControlServer: @unchecked Sendable {
    private var listener: NWListener?
    private let token = UUID().uuidString + UUID().uuidString
    private let handler: ControlHandler
    private let paths: AppPaths

    public init(paths: AppPaths = AppPaths(), handler: @escaping ControlHandler) { self.paths = paths; self.handler = handler }

    public func start() throws {
        let l = try NWListener(using: .tcp, on: .any)
        l.parameters.requiredInterfaceType = .loopback
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, case .ready = state, let port = l?.port?.rawValue else { return }
            let info = ControlInfo(port: port, token: self.token, pid: getpid())
            try? FileManager.default.createDirectory(at: self.paths.root, withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(info) {
                try? d.write(to: self.paths.controlFile, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.paths.controlFile.path)
            }
        }
        l.start(queue: .global(qos: .utility))
        listener = l
    }

    public func stop() { listener?.cancel(); try? FileManager.default.removeItem(at: paths.controlFile) }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer; if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                Task {
                    let (status, text) = await self.respond(req)
                    let body = Data(text.utf8)
                    let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
                }
            } else if err != nil || done { conn.cancel() } else if buf.count < (4 << 20) { self.read(conn, buffer: buf) } else { conn.cancel() }
        }
    }

    struct Req { var auth: String; var body: Data }

    /// Returns nil until a complete request (headers + Content-Length bytes) has arrived.
    static func parse(_ buf: Data) -> Req? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<sep.lowerBound], as: UTF8.self)
        var len = 0, auth = ""
        for line in head.components(separatedBy: "\r\n") {
            let l = line.lowercased()
            if l.hasPrefix("content-length:") { len = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0 }
            if l.hasPrefix("authorization:") { auth = String(line.dropFirst(14)).trimmingCharacters(in: .whitespaces) }
        }
        let body = buf[sep.upperBound...]
        return body.count >= len ? Req(auth: auth, body: Data(body.prefix(len))) : nil
    }

    private func respond(_ r: Req) async -> (Int, String) {
        guard r.auth == "Bearer \(token)" else { return (401, #"{"ok":false,"text":"unauthorized"}"#) }
        guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any], let tool = obj["tool"] as? String else { return (400, #"{"ok":false,"text":"bad request"}"#) }
        let (ok, text) = await handler(tool, (obj["args"] as? [String: Any]) ?? [:])
        let out = (try? JSONSerialization.data(withJSONObject: ["ok": ok, "text": text])) ?? Data()
        return (200, String(decoding: out, as: UTF8.self))
    }
}

public enum ControlClient {
    public static func info(paths: AppPaths = AppPaths()) -> ControlInfo? {
        guard let d = try? Data(contentsOf: paths.controlFile), let i = try? JSONDecoder().decode(ControlInfo.self, from: d), kill(i.pid, 0) == 0 else { return nil }
        return i
    }

    /// Calls a tool in the running app, launching it in the background first if needed.
    public static func call(_ tool: String, _ args: [String: Any], paths: AppPaths = AppPaths()) async throws -> String {
        var info = Self.info(paths: paths)
        if info == nil {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-g", "-b", "com.kalahroudi.moose"]
            try? p.run()
            for _ in 0..<40 { try await Task.sleep(for: .milliseconds(250)); info = Self.info(paths: paths); if info != nil { break } }
        }
        guard let info else { throw UserFacingError("Moose isn't running and couldn't be started. Open the Moose app once, then try again.") }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(info.port)/")!)
        req.httpMethod = "POST"; req.timeoutInterval = 150
        req.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["tool": tool, "args": args])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = o["text"] as? String else { throw UserFacingError("Moose gave an unreadable answer.") }
        if (o["ok"] as? Bool) != true { throw UserFacingError(text) }
        return text
    }
}
