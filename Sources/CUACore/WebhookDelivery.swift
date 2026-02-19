import Foundation

// MARK: - Webhook Configuration

/// Configuration for a webhook subscription
public struct WebhookConfig {
    public let url: URL
    public let token: String?
    public let meta: [String: AnyCodable]
    public let cooldown: TimeInterval
    public let maxWakes: Int
    public let verbose: Bool

    public init(url: URL, token: String? = nil, meta: [String: AnyCodable] = [:],
                cooldown: TimeInterval = 300, maxWakes: Int = 20, verbose: Bool = false) {
        self.url = url
        self.token = token
        self.meta = meta
        self.cooldown = cooldown
        self.maxWakes = maxWakes
        self.verbose = verbose
    }
}

// MARK: - Rate Limiter

/// Rate limiter with cooldown and hourly circuit breaker
public final class WebhookRateLimiter {
    private let lock = NSLock()
    private let cooldown: TimeInterval
    private let maxWakes: Int

    /// Timestamp of the last POST
    private var lastPostTime: Date?
    /// Sliding window of POST timestamps for the current hour
    private var postTimestamps: [Date] = []
    /// Whether the circuit breaker has tripped
    private var circuitBroken = false

    public init(cooldown: TimeInterval, maxWakes: Int) {
        self.cooldown = cooldown
        self.maxWakes = maxWakes
    }

    /// Check if a POST is currently allowed (without consuming a slot).
    public func canPost(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        pruneOldTimestamps(now: now)

        if circuitBroken {
            // Check if we've rolled into a new window
            if postTimestamps.count < maxWakes {
                circuitBroken = false
            } else {
                return false
            }
        }

        if let last = lastPostTime, now.timeIntervalSince(last) < cooldown {
            return false  // Still in cooldown
        }

        return postTimestamps.count < maxWakes
    }

    /// Record that a POST was made.
    public func recordPost(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        lastPostTime = now
        postTimestamps.append(now)
        pruneOldTimestamps(now: now)

        if postTimestamps.count >= maxWakes {
            circuitBroken = true
        }
    }

    /// Seconds until cooldown expires (0 if ready now).
    public func secondsUntilReady(now: Date = Date()) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }

        guard let last = lastPostTime else { return 0 }
        let elapsed = now.timeIntervalSince(last)
        return max(0, cooldown - elapsed)
    }

    /// Current state for diagnostics.
    public func state(now: Date = Date()) -> (postsThisHour: Int, circuitBroken: Bool, cooldownRemaining: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        pruneOldTimestamps(now: now)
        let remaining: TimeInterval
        if let last = lastPostTime {
            remaining = max(0, cooldown - now.timeIntervalSince(last))
        } else {
            remaining = 0
        }
        return (postTimestamps.count, circuitBroken && postTimestamps.count >= maxWakes, remaining)
    }

    private func pruneOldTimestamps(now: Date) {
        let oneHourAgo = now.addingTimeInterval(-3600)
        postTimestamps = postTimestamps.filter { $0 > oneHourAgo }
    }
}

// MARK: - Event Message Formatter

/// Generates human-readable messages from CUAEvents
public struct EventMessageFormatter {
    public static func format(_ event: CUAEvent) -> String {
        let details = event.details
        switch event.type {
        case "process.exit":
            let pid = event.pid.map { String($0) } ?? "?"
            let label = details?["label"]?.value as? String
            let exitCode = details?["exit_code"]?.value as? Int ?? -1
            let detail = details?["last_detail"]?.value as? String ?? ""
            let processDesc = label ?? "Process \(pid)"
            if exitCode == 0 {
                return "\(processDesc) completed successfully"
            } else {
                let suffix = detail.isEmpty ? "" : " — \(detail)"
                return "\(processDesc) exited with code \(exitCode)\(suffix)"
            }

        case "process.error":
            let pid = event.pid.map { String($0) } ?? "?"
            let label = details?["label"]?.value as? String
            let errorMsg = details?["error"]?.value as? String ?? "unknown error"
            let processDesc = label ?? "Process \(pid)"
            return "\(processDesc) error: \(errorMsg)"

        case "process.idle":
            let pid = event.pid.map { String($0) } ?? "?"
            let label = details?["label"]?.value as? String
            let seconds = details?["idle_seconds"]?.value as? Int ?? 0
            let processDesc = label ?? "Process \(pid)"
            return "\(processDesc) idle for \(seconds / 60)m"

        case "process.group.state_change":
            let pid = event.pid.map { String($0) } ?? "?"
            let label = details?["label"]?.value as? String ?? "Process \(pid)"
            let newState = details?["new_state"]?.value as? String ?? "?"
            let detail = details?["last_detail"]?.value as? String ?? ""
            let suffix = detail.isEmpty ? "" : " — \(detail)"
            return "\(label) → \(newState)\(suffix)"

        default:
            let app = event.app ?? "unknown"
            return "[\(event.type)] \(app)"
        }
    }

    public static func formatBatch(_ events: [CUAEvent]) -> String {
        if events.count == 1 {
            return format(events[0])
        }
        let summaries = events.map { format($0) }
        return "cua batch (\(events.count) events): \(summaries.joined(separator: "; "))"
    }
}

// MARK: - Webhook Delivery

/// Delivers events to a webhook URL with rate limiting and batching.
/// Thread-safe: all state is protected by a lock.
public final class WebhookDelivery {
    private let config: WebhookConfig
    public let rateLimiter: WebhookRateLimiter
    private let lock = NSLock()

    /// Pending events accumulated during cooldown
    private var pendingEvents: [CUAEvent] = []
    /// Timer for flushing pending events after cooldown
    private var flushTimer: DispatchWorkItem?
    private let deliveryQueue = DispatchQueue(label: "cua.webhook.delivery")

    /// EventBus subscription ID
    private var subscriptionId: String?
    private weak var eventBus: EventBus?

    /// Stats
    private var totalDelivered: Int = 0
    private var totalFailed: Int = 0
    private var totalSuppressed: Int = 0
    private var startTime: Date

    /// URLSession for HTTP POSTs (injectable for testing)
    public var urlSession: URLSession

    public init(config: WebhookConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.rateLimiter = WebhookRateLimiter(cooldown: config.cooldown, maxWakes: config.maxWakes)
        self.urlSession = urlSession
        self.startTime = Date()
    }

    /// Start subscribing to events from the EventBus
    public func start(eventBus: EventBus, appFilter: String? = nil, typeFilters: Set<String>? = nil) {
        self.eventBus = eventBus
        subscriptionId = eventBus.subscribe(appFilter: appFilter, typeFilters: typeFilters) { [weak self] event in
            self?.handleEvent(event)
        }
    }

    /// Stop subscribing and flush pending events
    public func stop() {
        lock.lock()
        flushTimer?.cancel()
        flushTimer = nil
        let pending = pendingEvents
        pendingEvents = []
        lock.unlock()

        if let id = subscriptionId, let bus = eventBus {
            bus.unsubscribe(id)
        }
        subscriptionId = nil

        // Deliver any pending events on stop
        if !pending.isEmpty {
            deliverBatch(pending)
        }
    }

    /// Current subscription ID (for tracking)
    public var subId: String? { subscriptionId }

    /// Diagnostic info
    public func info() -> [String: AnyCodable] {
        let (postsThisHour, broken, cooldownRemaining) = rateLimiter.state()
        lock.lock()
        let pending = pendingEvents.count
        let delivered = totalDelivered
        let failed = totalFailed
        let suppressed = totalSuppressed
        lock.unlock()

        return [
            "webhook_url": AnyCodable(config.url.absoluteString),
            "cooldown_s": AnyCodable(Int(config.cooldown)),
            "max_wakes": AnyCodable(config.maxWakes),
            "posts_this_hour": AnyCodable(postsThisHour),
            "circuit_broken": AnyCodable(broken),
            "cooldown_remaining_s": AnyCodable(Int(cooldownRemaining)),
            "pending_events": AnyCodable(pending),
            "total_delivered": AnyCodable(delivered),
            "total_failed": AnyCodable(failed),
            "total_suppressed": AnyCodable(suppressed),
            "verbose": AnyCodable(config.verbose),
        ]
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: CUAEvent) {
        if config.verbose {
            logWebhook("event received: \(event.type)")
        }

        lock.lock()

        if rateLimiter.canPost() {
            // Deliver immediately
            lock.unlock()
            deliverBatch([event])
        } else {
            // Queue for later
            pendingEvents.append(event)
            totalSuppressed += 1
            if config.verbose {
                logWebhook("event queued (cooldown/circuit), pending=\(pendingEvents.count)")
            }
            scheduleFlushIfNeeded()
            lock.unlock()
        }
    }

    /// Schedule a timer to flush pending events when cooldown expires.
    /// Must be called with lock held.
    private func scheduleFlushIfNeeded() {
        guard flushTimer == nil else { return }

        let delay = rateLimiter.secondsUntilReady()
        let work = DispatchWorkItem { [weak self] in
            self?.flushPending()
        }
        flushTimer = work
        deliveryQueue.asyncAfter(deadline: .now() + delay + 0.1, execute: work)
    }

    private func flushPending() {
        lock.lock()
        flushTimer = nil

        guard !pendingEvents.isEmpty else {
            lock.unlock()
            return
        }

        if rateLimiter.canPost() {
            let batch = pendingEvents
            pendingEvents = []
            lock.unlock()
            deliverBatch(batch)
        } else {
            // Still rate limited, reschedule
            scheduleFlushIfNeeded()
            lock.unlock()
        }
    }

    // MARK: - HTTP Delivery

    private func deliverBatch(_ events: [CUAEvent]) {
        let message = EventMessageFormatter.formatBatch(events)
        var payload = config.meta
        payload["message"] = AnyCodable(message)
        payload["event_count"] = AnyCodable(events.count)
        payload["timestamp"] = AnyCodable(ISO8601DateFormatter().string(from: Date()))

        // Include the first event's type for single events
        if events.count == 1 {
            payload["event_type"] = AnyCodable(events[0].type)
            if let pid = events[0].pid { payload["pid"] = AnyCodable(Int(pid)) }
        }

        post(payload: payload, retryCount: 0)
        rateLimiter.recordPost()
    }

    private func post(payload: [String: AnyCodable], retryCount: Int) {
        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = config.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(payload) else {
            logWebhook("failed to encode payload")
            return
        }
        request.httpBody = body

        let task = urlSession.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }

            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0

            if let error = error {
                self.logWebhook("POST failed: \(error.localizedDescription)")
                self.handleFailure(payload: payload, retryCount: retryCount)
                return
            }

            if statusCode >= 200 && statusCode < 300 {
                self.lock.lock()
                self.totalDelivered += 1
                self.lock.unlock()
                self.logWebhook("POST \(statusCode) OK")
            } else {
                self.logWebhook("POST failed: HTTP \(statusCode)")
                self.handleFailure(payload: payload, retryCount: retryCount)
            }
        }
        task.resume()
    }

    private func handleFailure(payload: [String: AnyCodable], retryCount: Int) {
        if retryCount < 1 {
            logWebhook("retrying in 5s (attempt \(retryCount + 2))")
            deliveryQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.post(payload: payload, retryCount: retryCount + 1)
            }
        } else {
            lock.lock()
            totalFailed += 1
            lock.unlock()
            logWebhook("giving up after retry")
        }
    }

    private func logWebhook(_ msg: String) {
        fputs("[webhook] \(msg)\n", stderr)
    }
}
