import CryptoKit
import Foundation
import Testing
@testable import CUACore
@testable import CUADaemonLib

// MARK: - Helpers

private func makeServerConfig(
    secret: String = "test-secret",
    tokenTtl: Int = 3600,
    blockedApps: [String] = []
) -> RemoteServerConfig {
    RemoteServerConfig(
        enabled: true,
        port: 0,  // ephemeral — overridden by start()
        bind: "0.0.0.0",
        secret: secret,
        tokenTtl: tokenTtl,
        blockedApps: blockedApps
    )
}

/// Start a RemoteServer on an ephemeral port and return (server, port).
private func startRemoteServer(config: RemoteServerConfig) async throws -> (RemoteServer, UInt16) {
    let server = RemoteServer(config: config)
    return try await withCheckedThrowingContinuation { continuation in
        server.onReady = { port in
            continuation.resume(returning: (server, port))
        }
        do {
            try server.start()
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

/// Compute HMAC-SHA256(secret, challenge:ts) — same as RemoteServer.handleAuth.
private func computeSig(secret: String, challenge: String, ts: Int) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let msg = Data("\(challenge):\(ts)".utf8)
    let mac = HMAC<SHA256>.authenticationCode(for: msg, using: key)
    return mac.map { String(format: "%02x", $0) }.joined()
}

private func httpRequest(
    method: String,
    url: URL,
    headers: [String: String] = [:],
    body: Data? = nil
) async throws -> (Int, [String: Any]) {
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 10
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    if let body = body {
        req.httpBody = body
        if req.value(forHTTPHeaderField: "Content-Type") == nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
    }
    let (data, response) = try await URLSession.shared.data(for: req)
    let status = (response as! HTTPURLResponse).statusCode
    let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    return (status, json)
}

/// Perform the full handshake: GET /handshake + POST /auth. Returns session token.
private func fullAuth(port: UInt16, secret: String) async throws -> (Int, [String: Any]) {
    // Step 1: get challenge
    let hsURL = URL(string: "http://127.0.0.1:\(port)/handshake")!
    let (hsStatus, hsBody) = try await httpRequest(method: "GET", url: hsURL)
    guard hsStatus == 200, let challenge = hsBody["challenge"] as? String else {
        return (hsStatus, hsBody)
    }

    // Step 2: POST /auth
    let ts = Int(Date().timeIntervalSince1970)
    let sig = computeSig(secret: secret, challenge: challenge, ts: ts)
    let authBody: [String: Any] = ["sig": sig, "challenge": challenge, "ts": ts]
    let authBodyData = try JSONSerialization.data(withJSONObject: authBody)
    let authURL = URL(string: "http://127.0.0.1:\(port)/auth")!
    return try await httpRequest(method: "POST", url: authURL, body: authBodyData)
}

// MARK: - HMAC Generation and Verification Tests

@Test func hmacSignatureMatchesExpected() {
    let secret = "my-test-secret"
    let challenge = "aabbccddeeff"
    let ts = 1700000000

    let sig = computeSig(secret: secret, challenge: challenge, ts: ts)

    // Recompute with CryptoKit directly and compare
    let key = SymmetricKey(data: Data(secret.utf8))
    let msg = Data("\(challenge):\(ts)".utf8)
    let expected = HMAC<SHA256>.authenticationCode(for: msg, using: key)
    let expectedHex = expected.map { String(format: "%02x", $0) }.joined()

    #expect(sig == expectedHex)
    #expect(sig.count == 64)  // 32 bytes → 64 hex chars
}

@Test func hmacDifferentSecretProducesDifferentSig() {
    let challenge = "testchallenge"
    let ts = 1700000000
    let sig1 = computeSig(secret: "secret-a", challenge: challenge, ts: ts)
    let sig2 = computeSig(secret: "secret-b", challenge: challenge, ts: ts)
    #expect(sig1 != sig2)
}

// MARK: - GET /handshake

@Test func handshakeReturnsChallenge() async throws {
    let (server, port) = try await startRemoteServer(config: makeServerConfig())
    defer { server.stop() }

    let url = URL(string: "http://127.0.0.1:\(port)/handshake")!
    let (status, body) = try await httpRequest(method: "GET", url: url)

    #expect(status == 200)
    let challenge = try #require(body["challenge"] as? String)
    #expect(challenge.count == 64)  // 32 bytes → 64 hex chars
    #expect(body["expires_in"] as? Int == 30)
}

@Test func handshakeChallengeIsUnique() async throws {
    let (server, port) = try await startRemoteServer(config: makeServerConfig())
    defer { server.stop() }

    let url = URL(string: "http://127.0.0.1:\(port)/handshake")!
    let (_, body1) = try await httpRequest(method: "GET", url: url)
    let (_, body2) = try await httpRequest(method: "GET", url: url)

    let c1 = try #require(body1["challenge"] as? String)
    let c2 = try #require(body2["challenge"] as? String)
    #expect(c1 != c2)
}

// MARK: - POST /auth

@Test func authSucceedsWithValidHMAC() async throws {
    let secret = "valid-secret"
    let (server, port) = try await startRemoteServer(config: makeServerConfig(secret: secret))
    defer { server.stop() }

    let (status, body) = try await fullAuth(port: port, secret: secret)

    #expect(status == 200)
    let token = try #require(body["token"] as? String)
    #expect(token.count == 128)  // 64 bytes → 128 hex chars
    #expect(body["ttl"] as? Int == 3600)
}

@Test func authFailsWithWrongSecret() async throws {
    let (server, port) = try await startRemoteServer(config: makeServerConfig(secret: "correct-secret"))
    defer { server.stop() }

    let url = URL(string: "http://127.0.0.1:\(port)/handshake")!
    let (_, hsBody) = try await httpRequest(method: "GET", url: url)
    let challenge = try #require(hsBody["challenge"] as? String)

    let ts = Int(Date().timeIntervalSince1970)
    let wrongSig = computeSig(secret: "wrong-secret", challenge: challenge, ts: ts)
    let authBody: [String: Any] = ["sig": wrongSig, "challenge": challenge, "ts": ts]
    let authBodyData = try JSONSerialization.data(withJSONObject: authBody)
    let authURL = URL(string: "http://127.0.0.1:\(port)/auth")!
    let (status, _) = try await httpRequest(method: "POST", url: authURL, body: authBodyData)

    #expect(status == 401)
}

@Test func authChallengeIsSingleUse() async throws {
    let secret = "single-use-secret"
    let (server, port) = try await startRemoteServer(config: makeServerConfig(secret: secret))
    defer { server.stop() }

    // Get a challenge
    let hsURL = URL(string: "http://127.0.0.1:\(port)/handshake")!
    let (_, hsBody) = try await httpRequest(method: "GET", url: hsURL)
    let challenge = try #require(hsBody["challenge"] as? String)

    let ts = Int(Date().timeIntervalSince1970)
    let sig = computeSig(secret: secret, challenge: challenge, ts: ts)
    let authBodyData = try JSONSerialization.data(withJSONObject: [
        "sig": sig, "challenge": challenge, "ts": ts
    ])
    let authURL = URL(string: "http://127.0.0.1:\(port)/auth")!

    // First auth succeeds
    let (status1, _) = try await httpRequest(method: "POST", url: authURL, body: authBodyData)
    #expect(status1 == 200)

    // Second auth with same challenge must fail (challenge consumed)
    let (status2, _) = try await httpRequest(method: "POST", url: authURL, body: authBodyData)
    #expect(status2 == 401)
}

@Test func authRejectsTimestampTooOld() async throws {
    let secret = "replay-secret"
    let (server, port) = try await startRemoteServer(config: makeServerConfig(secret: secret))
    defer { server.stop() }

    let hsURL = URL(string: "http://127.0.0.1:\(port)/handshake")!
    let (_, hsBody) = try await httpRequest(method: "GET", url: hsURL)
    let challenge = try #require(hsBody["challenge"] as? String)

    // Timestamp 60 seconds in the past (> ±30s window)
    let oldTs = Int(Date().timeIntervalSince1970) - 60
    let sig = computeSig(secret: secret, challenge: challenge, ts: oldTs)
    let authBodyData = try JSONSerialization.data(withJSONObject: [
        "sig": sig, "challenge": challenge, "ts": oldTs
    ])
    let authURL = URL(string: "http://127.0.0.1:\(port)/auth")!
    let (status, _) = try await httpRequest(method: "POST", url: authURL, body: authBodyData)

    #expect(status == 401)
}

@Test func authRejectsTimestampTooFarFuture() async throws {
    let secret = "future-replay-secret"
    let (server, port) = try await startRemoteServer(config: makeServerConfig(secret: secret))
    defer { server.stop() }

    let hsURL = URL(string: "http://127.0.0.1:\(port)/handshake")!
    let (_, hsBody) = try await httpRequest(method: "GET", url: hsURL)
    let challenge = try #require(hsBody["challenge"] as? String)

    // Timestamp 60 seconds in the future (> ±30s window)
    let futureTs = Int(Date().timeIntervalSince1970) + 60
    let sig = computeSig(secret: secret, challenge: challenge, ts: futureTs)
    let authBodyData = try JSONSerialization.data(withJSONObject: [
        "sig": sig, "challenge": challenge, "ts": futureTs
    ])
    let authURL = URL(string: "http://127.0.0.1:\(port)/auth")!
    let (status, _) = try await httpRequest(method: "POST", url: authURL, body: authBodyData)

    #expect(status == 401)
}

@Test func authRejectsUnknownChallenge() async throws {
    let secret = "unknown-challenge-secret"
    let (server, port) = try await startRemoteServer(config: makeServerConfig(secret: secret))
    defer { server.stop() }

    let ts = Int(Date().timeIntervalSince1970)
    let fakeChallenge = String(repeating: "aa", count: 32)
    let sig = computeSig(secret: secret, challenge: fakeChallenge, ts: ts)
    let authBodyData = try JSONSerialization.data(withJSONObject: [
        "sig": sig, "challenge": fakeChallenge, "ts": ts
    ])
    let authURL = URL(string: "http://127.0.0.1:\(port)/auth")!
    let (status, _) = try await httpRequest(method: "POST", url: authURL, body: authBodyData)

    #expect(status == 401)
}

// MARK: - POST /rpc

@Test func rpcRejectsWithoutToken() async throws {
    let secret = "rpc-secret"
    let (server, port) = try await startRemoteServer(config: makeServerConfig(secret: secret))
    defer { server.stop() }

    let rpcBody: [String: Any] = ["jsonrpc": "2.0", "method": "ping", "params": [:], "id": 1]
    let rpcBodyData = try JSONSerialization.data(withJSONObject: rpcBody)
    let rpcURL = URL(string: "http://127.0.0.1:\(port)/rpc")!
    let (status, _) = try await httpRequest(method: "POST", url: rpcURL, body: rpcBodyData)

    #expect(status == 401)
}

@Test func rpcRejectsWithWrongToken() async throws {
    let (server, port) = try await startRemoteServer(config: makeServerConfig())
    defer { server.stop() }

    let rpcBody: [String: Any] = ["jsonrpc": "2.0", "method": "ping", "params": [:], "id": 1]
    let rpcBodyData = try JSONSerialization.data(withJSONObject: rpcBody)
    let rpcURL = URL(string: "http://127.0.0.1:\(port)/rpc")!
    let (status, _) = try await httpRequest(
        method: "POST", url: rpcURL,
        headers: ["Authorization": "Bearer totally-wrong-token"],
        body: rpcBodyData
    )

    #expect(status == 401)
}

@Test func rpcBlocksDisallowedMethod() async throws {
    let secret = "method-block-secret"
    let (server, port) = try await startRemoteServer(config: makeServerConfig(secret: secret))
    defer { server.stop() }

    // Authenticate first
    let (authStatus, authBody) = try await fullAuth(port: port, secret: secret)
    #expect(authStatus == 200)
    let token = try #require(authBody["token"] as? String)

    // Try a method not in the allowed list
    let rpcBody: [String: Any] = ["jsonrpc": "2.0", "method": "remote.accept", "params": [:], "id": 1]
    let rpcBodyData = try JSONSerialization.data(withJSONObject: rpcBody)
    let rpcURL = URL(string: "http://127.0.0.1:\(port)/rpc")!
    let (status, body) = try await httpRequest(
        method: "POST", url: rpcURL,
        headers: ["Authorization": "Bearer \(token)"],
        body: rpcBodyData
    )

    #expect(status == 403)
    #expect(body["error"] as? String == "method not allowed")
}

@Test func rpcBlocksAppsInBlockedList() async throws {
    let secret = "app-block-secret"
    let cfg = makeServerConfig(secret: secret, blockedApps: ["1Password", "Keychain Access"])
    let (server, port) = try await startRemoteServer(config: cfg)
    defer { server.stop() }

    let (authStatus, authBody) = try await fullAuth(port: port, secret: secret)
    #expect(authStatus == 200)
    let token = try #require(authBody["token"] as? String)

    let rpcBody: [String: Any] = [
        "jsonrpc": "2.0",
        "method": "snapshot",
        "params": ["app": "1Password"],
        "id": 1
    ]
    let rpcBodyData = try JSONSerialization.data(withJSONObject: rpcBody)
    let rpcURL = URL(string: "http://127.0.0.1:\(port)/rpc")!
    let (status, body) = try await httpRequest(
        method: "POST", url: rpcURL,
        headers: ["Authorization": "Bearer \(token)"],
        body: rpcBodyData
    )

    #expect(status == 403)
    #expect(body["error"] as? String == "app blocked")
}

@Test func rpcBlockedAppCaseInsensitive() async throws {
    let secret = "case-block-secret"
    let cfg = makeServerConfig(secret: secret, blockedApps: ["Signal"])
    let (server, port) = try await startRemoteServer(config: cfg)
    defer { server.stop() }

    let (_, authBody) = try await fullAuth(port: port, secret: secret)
    let token = try #require(authBody["token"] as? String)

    let rpcBody: [String: Any] = [
        "jsonrpc": "2.0",
        "method": "snapshot",
        "params": ["app": "signal"],  // lowercase
        "id": 1
    ]
    let rpcBodyData = try JSONSerialization.data(withJSONObject: rpcBody)
    let rpcURL = URL(string: "http://127.0.0.1:\(port)/rpc")!
    let (status, body) = try await httpRequest(
        method: "POST", url: rpcURL,
        headers: ["Authorization": "Bearer \(token)"],
        body: rpcBodyData
    )

    #expect(status == 403)
    #expect(body["error"] as? String == "app blocked")
}

// MARK: - Session Token Expiry

@Test func sessionTokenExpiresAfterTTL() async throws {
    // Use a very short TTL (1 second)
    let secret = "expiry-secret"
    let cfg = makeServerConfig(secret: secret, tokenTtl: 1)
    let (server, port) = try await startRemoteServer(config: cfg)
    defer { server.stop() }

    let (authStatus, authBody) = try await fullAuth(port: port, secret: secret)
    #expect(authStatus == 200)
    let token = try #require(authBody["token"] as? String)

    // Wait for token to expire
    try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds

    let rpcBody: [String: Any] = ["jsonrpc": "2.0", "method": "ping", "params": [:], "id": 1]
    let rpcBodyData = try JSONSerialization.data(withJSONObject: rpcBody)
    let rpcURL = URL(string: "http://127.0.0.1:\(port)/rpc")!
    let (status, _) = try await httpRequest(
        method: "POST", url: rpcURL,
        headers: ["Authorization": "Bearer \(token)"],
        body: rpcBodyData
    )

    #expect(status == 401)
}

// MARK: - Tailscale IP Detection

@Test func tailscaleRangeDetection() {
    // In range: 100.64.0.0 – 100.127.255.255
    #expect(isTailscaleRange("100.64.0.0") == true)
    #expect(isTailscaleRange("100.80.200.51") == true)
    #expect(isTailscaleRange("100.127.255.255") == true)

    // Out of range
    #expect(isTailscaleRange("100.128.0.0") == false)
    #expect(isTailscaleRange("100.63.255.255") == false)
    #expect(isTailscaleRange("192.168.1.1") == false)
    #expect(isTailscaleRange("127.0.0.1") == false)
    #expect(isTailscaleRange("10.0.0.1") == false)
    #expect(isTailscaleRange("not-an-ip") == false)
}

// MARK: - CUAConfig Decoding

@Test func cuaConfigDecodesRemoteServerConfig() throws {
    let json = """
    {
      "remote": {
        "enabled": true,
        "port": 4567,
        "bind": "tailscale",
        "secret": "abc123",
        "token_ttl": 7200,
        "blocked_apps": ["1Password", "Signal"]
      }
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder().decode(CUAConfig.self, from: json)
    let remote = try #require(config.remote)

    #expect(remote.enabled == true)
    #expect(remote.port == 4567)
    #expect(remote.bind == "tailscale")
    #expect(remote.secret == "abc123")
    #expect(remote.tokenTtl == 7200)
    #expect(remote.blockedApps == ["1Password", "Signal"])
}

@Test func cuaConfigDecodesRemoteTargets() throws {
    let json = """
    {
      "remote_targets": {
        "james-laptop": {
          "url": "http://100.80.200.51:4567",
          "secret": "shared-secret"
        }
      }
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder().decode(CUAConfig.self, from: json)
    let targets = try #require(config.remoteTargets)
    let laptop = try #require(targets["james-laptop"])

    #expect(laptop.url == "http://100.80.200.51:4567")
    #expect(laptop.secret == "shared-secret")
}
