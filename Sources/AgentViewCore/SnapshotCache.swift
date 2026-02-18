import Foundation

// MARK: - Element Identity (for ref stability)

/// Identifies an element across snapshots by its stable properties
public struct ElementIdentity: Hashable {
    public let role: String
    public let title: String?
    public let identifier: String?

    public init(role: String, title: String?, identifier: String?) {
        self.role = role
        self.title = title
        self.identifier = identifier
    }

    /// Build identity from an Element
    public static func from(_ element: Element) -> ElementIdentity {
        ElementIdentity(role: element.role, title: element.label, identifier: nil)
    }
}

// MARK: - Ref Stability Manager

/// Maintains persistent ref→element mappings across snapshots for an app.
/// Ensures e1 stays e1 as long as the element exists (matched by role+title+identifier).
/// New elements get the next available ref. Deleted refs are tombstoned for 60s.
public final class RefStabilityManager {
    private let lock = NSLock()

    /// Maps identity -> assigned ref (e.g. "e1")
    private var identityToRef: [ElementIdentity: String] = [:]

    /// Maps ref -> identity (reverse lookup)
    private var refToIdentity: [String: ElementIdentity] = [:]

    /// Tombstoned refs: ref -> expiry time. Not reused until expired.
    private var tombstones: [String: Date] = [:]

    /// Tombstoned identity -> ref, so returning elements can reclaim their ref
    private var tombstonedIdentityToRef: [ElementIdentity: String] = [:]

    /// Next ref counter
    private var nextRefNumber: Int = 1

    /// How long a tombstone lasts before the ref can be reused
    public var tombstoneDuration: TimeInterval = 60.0

    public init() {}

    /// Assign stable refs to a list of elements from a new snapshot.
    /// Returns a new list of Elements with stabilized refs.
    public func stabilize(elements: [Element]) -> [Element] {
        lock.lock()
        defer { lock.unlock() }

        // Purge expired tombstones
        let now = Date()
        for (ref, expiry) in tombstones where expiry <= now {
            if let identity = refToIdentity[ref] {
                tombstonedIdentityToRef.removeValue(forKey: identity)
            }
            tombstones.removeValue(forKey: ref)
            refToIdentity.removeValue(forKey: ref)
        }

        // Track which identities are seen in this snapshot
        var seenIdentities = Set<ElementIdentity>()
        var result: [Element] = []

        for element in elements {
            let identity = ElementIdentity(role: element.role, title: element.label, identifier: nil)
            seenIdentities.insert(identity)

            let ref: String
            if let existingRef = identityToRef[identity] {
                // Element still exists — keep its ref
                ref = existingRef
            } else if let tombstonedRef = tombstonedIdentityToRef[identity] {
                // Element returned from tombstone — reclaim its ref
                ref = tombstonedRef
                tombstones.removeValue(forKey: ref)
                tombstonedIdentityToRef.removeValue(forKey: identity)
                identityToRef[identity] = ref
                refToIdentity[ref] = identity
            } else {
                // New element — assign next available ref
                ref = allocateRef()
                identityToRef[identity] = ref
                refToIdentity[ref] = identity
            }

            result.append(Element(
                ref: ref,
                role: element.role,
                label: element.label,
                value: element.value,
                placeholder: element.placeholder,
                enabled: element.enabled,
                focused: element.focused,
                selected: element.selected,
                actions: element.actions
            ))
        }

        // Tombstone any identities not seen in this snapshot
        for (identity, ref) in identityToRef {
            if !seenIdentities.contains(identity) {
                tombstones[ref] = now.addingTimeInterval(tombstoneDuration)
                tombstonedIdentityToRef[identity] = ref
                identityToRef.removeValue(forKey: identity)
            }
        }

        return result
    }

    /// Allocate a ref, skipping tombstoned ones
    private func allocateRef() -> String {
        while true {
            let ref = "e\(nextRefNumber)"
            nextRefNumber += 1
            if tombstones[ref] == nil {
                return ref
            }
        }
    }

    /// Get current mapping count (for stats)
    public var mappingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return identityToRef.count
    }

    /// Get tombstone count
    public var tombstoneCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tombstones.count
    }

    /// Reset all state
    public func reset() {
        lock.lock()
        identityToRef.removeAll()
        refToIdentity.removeAll()
        tombstones.removeAll()
        tombstonedIdentityToRef.removeAll()
        nextRefNumber = 1
        lock.unlock()
    }
}

// MARK: - Cache Entry

/// A cached snapshot with metadata
public struct CacheEntry {
    public let snapshot: AppSnapshot
    public let transport: String
    public let cachedAt: Date
    public let ttl: TimeInterval

    public var isExpired: Bool {
        Date().timeIntervalSince(cachedAt) > ttl
    }

    public var ageMs: Int {
        Int(Date().timeIntervalSince(cachedAt) * 1000)
    }
}

// MARK: - Snapshot Cache

/// In-memory snapshot cache with configurable TTL per transport.
/// Caches last snapshot per app (keyed by app name).
/// Tracks hit/miss stats.
public final class SnapshotCache {
    private let lock = NSLock()

    /// Cached snapshots keyed by app name (lowercased)
    private var entries: [String: CacheEntry] = [:]

    /// Per-app ref stability managers
    private var refManagers: [String: RefStabilityManager] = [:]

    /// TTL configuration per transport
    public var axTTL: TimeInterval = 5.0
    public var cdpTTL: TimeInterval = 30.0
    public var applescriptTTL: TimeInterval = 30.0
    public var defaultTTL: TimeInterval = 5.0

    /// Stats
    private var _hits: Int = 0
    private var _misses: Int = 0

    public init() {}

    /// Get a cached snapshot for an app, if fresh.
    /// Returns nil if no cache entry or if expired.
    public func get(app: String) -> CacheEntry? {
        lock.lock()
        defer { lock.unlock() }

        let key = app.lowercased()
        guard let entry = entries[key], !entry.isExpired else {
            _misses += 1
            return nil
        }
        _hits += 1
        return entry
    }

    /// Store a snapshot in the cache with ref stabilization.
    public func put(app: String, snapshot: AppSnapshot, transport: String) -> AppSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let key = app.lowercased()
        let ttl = ttlFor(transport: transport)

        // Apply ref stability
        let manager = refManagers[key] ?? RefStabilityManager()
        refManagers[key] = manager

        let allElements = snapshot.content.sections.flatMap { $0.elements }
        let stabilized = manager.stabilize(elements: allElements)

        // Rebuild sections with stabilized refs
        var elementIndex = 0
        let newSections = snapshot.content.sections.map { section -> Section in
            let newElements = section.elements.map { _ -> Element in
                let el = stabilized[elementIndex]
                elementIndex += 1
                return el
            }
            return Section(role: section.role, label: section.label, elements: newElements)
        }

        let newContent = ContentTree(summary: snapshot.content.summary, sections: newSections)
        let stabilizedSnapshot = AppSnapshot(
            app: snapshot.app,
            bundleId: snapshot.bundleId,
            pid: snapshot.pid,
            timestamp: snapshot.timestamp,
            window: snapshot.window,
            meta: snapshot.meta,
            content: newContent,
            actions: snapshot.actions,
            stats: snapshot.stats
        )

        entries[key] = CacheEntry(
            snapshot: stabilizedSnapshot,
            transport: transport,
            cachedAt: Date(),
            ttl: ttl
        )

        return stabilizedSnapshot
    }

    /// Invalidate cache for an app
    public func invalidate(app: String) {
        lock.lock()
        entries.removeValue(forKey: app.lowercased())
        lock.unlock()
    }

    /// Invalidate all entries
    public func invalidateAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// Get cache stats
    public var stats: (entries: Int, hits: Int, misses: Int, hitRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        let total = _hits + _misses
        let rate = total > 0 ? Double(_hits) / Double(total) : 0.0
        return (entries: entries.count, hits: _hits, misses: _misses, hitRate: rate)
    }

    /// Get the ref stability manager for an app (for external use e.g. by Router)
    public func refManager(for app: String) -> RefStabilityManager {
        lock.lock()
        defer { lock.unlock() }
        let key = app.lowercased()
        if let manager = refManagers[key] {
            return manager
        }
        let manager = RefStabilityManager()
        refManagers[key] = manager
        return manager
    }

    /// TTL for a given transport name
    private func ttlFor(transport: String) -> TimeInterval {
        switch transport.lowercased() {
        case "ax": return axTTL
        case "cdp": return cdpTTL
        case "applescript": return applescriptTTL
        default: return defaultTTL
        }
    }
}
