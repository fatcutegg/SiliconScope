//
//  File:      FleetAgentServer.swift
//  Created:   2026-07-22
//  Updated:   2026-10-05
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The Mac-side fleet agent: serves this machine's MachineMetrics over token-protected
//             TLS and advertises via mDNS (_sscope-agent._tcp), so another Mac's Fleet view discovers
//             and pairs with it exactly like the Linux Go agent. Reused by both the app's "share this
//             Mac" toggle and the headless CLI agent — they only differ in how they build the metrics.
//  Notes:     Mirrors agent/security.go: a persisted bearer token (auth) + self-signed cert
//             (encryption, TOFU-pinned by the viewer). The cert is minted once via /usr/bin/openssl
//             and loaded as a SecIdentity through a PKCS#12; the p12 password is not a secret (the
//             viewer pins the cert fingerprint, not a CA). GET /metrics requires the token; GET
//             /healthz is open for discovery/liveness. HTTP is parsed by hand — only tiny GETs.
//             Connections are kept alive (HTTP/1.1's default) and closed after `idleTimeout`
//             without a request, and /metrics is gzipped when the request accepts it: a viewer
//             polls every 3 s, and a fresh TLS handshake plus an uncompressed body per poll was
//             ~11 KB each time (#71).
//
import Foundation
import Network
import Security

public final class FleetAgentServer: @unchecked Sendable {
    public enum AgentError: Error { case identityLoadFailed(OSStatus), opensslFailed(String), badPort }

    private let port: UInt16
    private let token: String
    private let identity: SecIdentity
    private let metricsProvider: @Sendable () -> Data   // encoded MachineMetrics JSON
    private var listener: NWListener?

    /// - Parameters:
    ///   - configDir: writable dir for the token + TLS material (created if missing).
    ///   - metricsProvider: returns freshly-encoded MachineMetrics JSON per request.
    public init(port: UInt16, configDir: URL,
                metricsProvider: @escaping @Sendable () -> Data) throws {
        guard port > 0 else { throw AgentError.badPort }
        self.port = port
        self.metricsProvider = metricsProvider
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        self.token = try Self.loadOrCreateToken(configDir)
        self.identity = try Self.loadOrCreateIdentity(configDir)
    }

    /// The bearer token to hand to the pairing user (printed / shown in Settings).
    public var pairingToken: String { token }

    public func start() throws {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else {
            throw AgentError.identityLoadFailed(errSecParam)
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)

        let params = NWParameters(tls: tls)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false

        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        // Advertise over mDNS so the Mac aggregator auto-discovers this agent.
        l.service = NWListener.Service(name: nil, type: "_sscope-agent._tcp")
        l.stateUpdateHandler = { state in
            switch state {
            case .failed(let e):  NSLog("[Agent] listener failed: \(e)")
            case .waiting(let e): NSLog("[Agent] listener waiting: \(e)")
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: .global(qos: .utility))
        self.listener = l
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - HTTP (tiny GET server)

    /// How long a kept-alive connection may sit without a request. A viewer polls every 3 s, so
    /// only a viewer that has stopped watching ever reaches it.
    static let idleTimeout: TimeInterval = 30

    private func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            if case .failed = state { conn.cancel() }
        }
        conn.start(queue: .global(qos: .utility))
        readRequest(conn, buffer: Data(), idle: IdleTimer())
    }

    /// Closes a connection left idle between requests. Each arm supersedes the previous one, and
    /// any bytes arriving disarm it — a generation counter rather than a cancellable work item,
    /// so the timer can cross into the receive callback as a Sendable value.
    private final class IdleTimer: @unchecked Sendable {
        private let lock = NSLock()
        private var generation = 0       // guarded by `lock`

        func arm(_ conn: NWConnection, after seconds: TimeInterval) {
            lock.lock(); generation += 1; let armed = generation; lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [self] in
                lock.lock(); let current = generation; lock.unlock()
                if current == armed { conn.cancel() }
            }
        }

        func disarm() { lock.lock(); generation += 1; lock.unlock() }
    }

    private func readRequest(_ conn: NWConnection, buffer: Data, idle: IdleTimer) {
        if buffer.isEmpty { idle.arm(conn, after: Self.idleTimeout) }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            idle.disarm()
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(data: buf[..<range.lowerBound], encoding: .utf8) ?? ""
                // Only bodiless GETs are served, so whatever follows the blank line is the next
                // request (pipelined) and is carried over rather than dropped.
                let rest = Data(buf[range.upperBound...])
                self.respond(conn, header: header) { keepAlive in
                    if keepAlive && !isComplete { self.readRequest(conn, buffer: rest, idle: idle) } else { conn.cancel() }
                }
            } else if isComplete || error != nil || buf.count > 16384 {
                conn.cancel()
            } else {
                self.readRequest(conn, buffer: buf, idle: idle)
            }
        }
    }

    private func respond(_ conn: NWConnection, header: String, then next: @escaping @Sendable (Bool) -> Void) {
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let fields = requestLine.split(separator: " ")
        let path = fields.count >= 2 ? String(fields[1]) : "/"
        func field(_ name: String) -> String? {
            lines.dropFirst().first { $0.lowercased().hasPrefix(name + ":") }
                .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        let authHeader = field("authorization") ?? ""
        // HTTP/1.1 keeps the connection unless the client says otherwise; HTTP/1.0 is not kept.
        let keepAlive = requestLine.hasSuffix("HTTP/1.1") && field("connection")?.lowercased() != "close"

        let status: String, contentType: String, body: Data, needsAuthChallenge: Bool
        switch path {
        case "/healthz":
            status = "200 OK"; contentType = "text/plain"; body = Data("ok".utf8); needsAuthChallenge = false
        case "/metrics":
            if constantTimeEqual(authHeader, "Bearer " + token) {
                status = "200 OK"; contentType = "application/json"; body = metricsProvider(); needsAuthChallenge = false
            } else {
                status = "401 Unauthorized"; contentType = "text/plain"; body = Data("unauthorized".utf8); needsAuthChallenge = true
            }
        default:
            status = "404 Not Found"; contentType = "text/plain"; body = Data("not found".utf8); needsAuthChallenge = false
        }

        var payload = body, encoding = ""
        if path == "/metrics", needsAuthChallenge == false,
           Gzip.accepted(byAcceptEncoding: field("accept-encoding")), let gz = Gzip.encode(body) {
            payload = gz
            encoding = "Content-Encoding: gzip\r\nVary: Accept-Encoding\r\n"
        }
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\n"
        head += encoding
        head += keepAlive ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
        if needsAuthChallenge { head += "WWW-Authenticate: Bearer\r\n" }
        head += "\r\n"
        var out = Data(head.utf8); out.append(payload)
        conn.send(content: out, completion: .contentProcessed { error in next(keepAlive && error == nil) })
    }

    // MARK: - Token + TLS identity (persisted, mirrors security.go)

    private static func loadOrCreateToken(_ dir: URL) throws -> String {
        let path = dir.appendingPathComponent("token")
        if let t = try? String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty { return t }
        var raw = Data(count: 32)
        _ = raw.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let token = raw.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try (token + "\n").write(to: path, atomically: true, encoding: .utf8)
        return token
    }

    private static func loadOrCreateIdentity(_ dir: URL) throws -> SecIdentity {
        let p12 = dir.appendingPathComponent("identity.p12")
        let password = "sscope"   // not a secret: the viewer TOFU-pins the cert, there is no CA trust
        if !FileManager.default.fileExists(atPath: p12.path) {
            try generateSelfSignedP12(dir: dir, password: password)
        }

        // Import into a DEDICATED file keychain, not the login keychain. On macOS SecPKCS12Import
        // against the login keychain blocks on a keychain-access XPC (silently, no visible prompt),
        // which is exactly the hang we hit. A private keychain we own avoids that entirely.
        let kcPath = dir.appendingPathComponent("agent.keychain-db").path
        unlink(kcPath)   // start fresh so create never collides with a stale file
        var keychain: SecKeychain?
        let pw = Array(password.utf8)
        // SecKeychain* is deprecated wholesale, but SecPKCS12Import still requires a file-based
        // keychain on macOS and there is no non-deprecated replacement for this import path — the
        // deprecation warning on the next line is expected and intentional.
        let created = SecKeychainCreate(kcPath, UInt32(pw.count), pw, false, nil, &keychain)
        guard created == errSecSuccess, let kc = keychain else {
            throw AgentError.identityLoadFailed(created)
        }

        // Turn OFF auto-lock, or the keychain locks on sleep / after 5 min idle — and then EVERY TLS
        // handshake needs a private-key signature, which pops a "keychain password" prompt each time
        // (issue #34). The obvious `SecKeychainSetSettings` can't do this from an unsigned binary on
        // macOS 26 — it itself prompts for authorization — so shell out to Apple's own signed
        // `security` tool, which sets it silently. Then unlock once so the first import/sign is ready.
        try? runSecurity(["set-keychain-settings", kcPath])          // no -l / -u = no lock-on-sleep, no timeout
        _ = SecKeychainUnlock(kc, UInt32(pw.count), pw, true)

        let data = try Data(contentsOf: p12)
        let opts = [kSecImportExportPassphrase as String: password,
                    kSecImportExportKeychain as String: kc] as CFDictionary
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, opts, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let identity = array.first?[kSecImportItemIdentity as String]
        else { throw AgentError.identityLoadFailed(status) }
        return identity as! SecIdentity
    }

    /// Mint a self-signed RSA-2048 cert via /usr/bin/openssl and bundle it into a PKCS#12.
    /// (RSA, not EC: on macOS 26 SecPKCS12Import crashes in SecKeyCopyExternalRepresentation while
    /// building the trust chain for an openssl-generated EC key.)
    private static func generateSelfSignedP12(dir: URL, password: String) throws {
        let key = dir.appendingPathComponent("key.pem").path
        let cert = dir.appendingPathComponent("cert.pem").path
        let p12 = dir.appendingPathComponent("identity.p12").path
        try runOpenSSL(["req", "-x509", "-newkey", "rsa:2048",
                        "-keyout", key, "-out", cert,
                        "-days", "3650", "-nodes", "-subj", "/CN=sscope-agent"])
        try runOpenSSL(["pkcs12", "-export", "-inkey", key, "-in", cert,
                        "-out", p12, "-passout", "pass:" + password])
    }

    private static func runOpenSSL(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw AgentError.opensslFailed(String(data: errData, encoding: .utf8) ?? "openssl exit \(p.terminationStatus)")
        }
    }

    /// Run Apple's signed `/usr/bin/security` tool. Used for `set-keychain-settings`, which the
    /// `SecKeychainSetSettings` API refuses to do silently from an unsigned agent on macOS 26.
    /// Best-effort: a failure here only means auto-lock stays on, so callers ignore the result.
    private static func runSecurity(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        p.standardError = Pipe()
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
