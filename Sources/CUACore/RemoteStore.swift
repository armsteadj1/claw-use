import Foundation

/// Persistent storage for remote pairing sessions and snapshots.
///
/// Layout under `~/.cua/remote/`:
/// - `config.json`           – RemoteConfig (port, retain duration)
/// - `sessions.json`         – dict of peerId -> RemoteSession
/// - `<peerId>/snapshots.jsonl` – append-only JSONL per peer
public final class RemoteStore {
    public static let remoteDir = NSHomeDirectory() + "/.cua/remote"

    /// The base directory used by this instance (may differ from the static default).
    public let baseDir: String

    private let sessionsPath: String
    private let configPath: String
    private let sessionsLock = NSLock()
    private var _sessions: [String: RemoteSession] = [:]
    private var _config: RemoteConfig

    /// Designated initialiser.  Pass a custom `baseDir` to isolate storage (useful in tests).
    public init(baseDir: String? = nil) {
        let dir = baseDir ?? RemoteStore.remoteDir
        self.baseDir = dir
        sessionsPath = dir + "/sessions.json"
        configPath = dir + "/config.json"
        _config = RemoteConfig()

        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Load config
        let configDecoder = JSONDecoder()
        configDecoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let config = try? configDecoder.decode(RemoteConfig.self, from: data) {
            _config = config
        }

        loadSessions()
    }

    public var config: RemoteConfig { _config }

    public func updateConfig(_ config: RemoteConfig) {
        _config = config
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(config) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    // MARK: - Sessions

    private func loadSessions() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sessionsPath)),
              let sessions = try? decoder.decode([String: RemoteSession].self, from: data) else { return }
        sessionsLock.lock()
        _sessions = sessions
        sessionsLock.unlock()
    }

    private func saveSessions() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(_sessions) else { return }
        try? data.write(to: URL(fileURLWithPath: sessionsPath))
    }

    public func addSession(_ session: RemoteSession) {
        sessionsLock.lock()
        _sessions[session.peerId] = session
        saveSessions()
        sessionsLock.unlock()
    }

    public func session(forPeer peerId: String) -> RemoteSession? {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        return _sessions[peerId]
    }

    public func session(forToken token: String) -> RemoteSession? {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        return _sessions.values.first { $0.sessionToken == token }
    }

    public func updateSessionLastUsed(_ peerId: String) {
        sessionsLock.lock()
        if var s = _sessions[peerId] {
            s.lastUsed = Date()
            _sessions[peerId] = s
            saveSessions()
        }
        sessionsLock.unlock()
    }

    public func removeSession(peerId: String) {
        sessionsLock.lock()
        _sessions.removeValue(forKey: peerId)
        saveSessions()
        sessionsLock.unlock()
    }

    public func allSessions() -> [RemoteSession] {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        return Array(_sessions.values)
    }

    // MARK: - Snapshot Storage

    private func peerDir(_ peerId: String) -> String {
        baseDir + "/" + peerId
    }

    private func snapshotsPath(for peerId: String) -> String {
        peerDir(peerId) + "/snapshots.jsonl"
    }

    /// Append a snapshot record and trim stale entries.
    public func appendSnapshot(_ record: RemoteSnapshotRecord) {
        let dir = peerDir(record.peerId)
        let path = snapshotsPath(for: record.peerId)
        let fm = FileManager.default

        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record),
              let line = String(data: data, encoding: .utf8) else { return }

        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data((line + "\n").utf8))
            fh.closeFile()
        }

        trimSnapshots(for: record.peerId, retainSeconds: _config.retainSeconds)
    }

    private func trimSnapshots(for peerId: String, retainSeconds: Int) {
        let path = snapshotsPath(for: peerId)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        let cutoff = Date().addingTimeInterval(-TimeInterval(retainSeconds))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let kept = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { line -> Bool in
                guard let data = String(line).data(using: .utf8),
                      let record = try? decoder.decode(RemoteSnapshotRecord.self, from: data) else { return false }
                return record.timestamp > cutoff
            }
            .joined(separator: "\n")

        let result = kept.isEmpty ? "" : kept + "\n"
        try? result.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Most recent snapshot for a peer, or nil if none exists.
    public func latestSnapshot(forPeer peerId: String) -> RemoteSnapshotRecord? {
        querySnapshots(forPeer: peerId, since: nil, app: nil).last
    }

    /// Query snapshots with optional filters.
    public func querySnapshots(forPeer peerId: String, since: Date?, app: String?) -> [RemoteSnapshotRecord] {
        let path = snapshotsPath(for: peerId)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> RemoteSnapshotRecord? in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(RemoteSnapshotRecord.self, from: data)
            }
            .filter { record in
                if let since = since, record.timestamp < since { return false }
                if let app = app,
                   !record.snapshot.app.lowercased().contains(app.lowercased()) { return false }
                return true
            }
    }

    /// Delete all snapshots for a peer.
    public func deleteSnapshots(forPeer peerId: String) {
        let path = snapshotsPath(for: peerId)
        try? FileManager.default.removeItem(atPath: path)
    }
}
