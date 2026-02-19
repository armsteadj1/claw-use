import Foundation
import Testing
@testable import CUACore

// MARK: - Rate Limiter Tests

@Test func rateLimiterAllowsFirstPost() {
    let limiter = WebhookRateLimiter(cooldown: 300, maxWakes: 20)
    #expect(limiter.canPost() == true)
}

@Test func rateLimiterEnforcesCooldown() {
    let limiter = WebhookRateLimiter(cooldown: 300, maxWakes: 20)
    let now = Date()

    // Record a post
    limiter.recordPost(now: now)

    // Should be in cooldown
    let during = now.addingTimeInterval(100)
    #expect(limiter.canPost(now: during) == false)

    // Should be ready after cooldown
    let after = now.addingTimeInterval(301)
    #expect(limiter.canPost(now: after) == true)
}

@Test func rateLimiterCircuitBreaker() {
    let limiter = WebhookRateLimiter(cooldown: 1, maxWakes: 3)
    let start = Date()

    // Fire 3 posts in rapid succession (within the hour)
    for i in 0..<3 {
        let t = start.addingTimeInterval(Double(i) * 2)
        #expect(limiter.canPost(now: t) == true)
        limiter.recordPost(now: t)
    }

    // 4th should be blocked by circuit breaker
    let afterThird = start.addingTimeInterval(7)
    #expect(limiter.canPost(now: afterThird) == false)
}

@Test func rateLimiterCircuitResetsAfterHour() {
    let limiter = WebhookRateLimiter(cooldown: 1, maxWakes: 2)
    let start = Date()

    // Use up the max wakes
    limiter.recordPost(now: start)
    limiter.recordPost(now: start.addingTimeInterval(2))

    // Circuit should be broken
    let during = start.addingTimeInterval(4)
    #expect(limiter.canPost(now: during) == false)

    // After an hour, posts should have expired from the window
    let afterHour = start.addingTimeInterval(3601)
    #expect(limiter.canPost(now: afterHour) == true)
}

@Test func rateLimiterSecondsUntilReady() {
    let limiter = WebhookRateLimiter(cooldown: 300, maxWakes: 20)
    let now = Date()

    // Initially ready
    #expect(limiter.secondsUntilReady(now: now) == 0)

    // After post, should show remaining cooldown
    limiter.recordPost(now: now)
    let check = now.addingTimeInterval(100)
    let remaining = limiter.secondsUntilReady(now: check)
    #expect(remaining > 199 && remaining <= 200)
}

@Test func rateLimiterState() {
    let limiter = WebhookRateLimiter(cooldown: 60, maxWakes: 5)
    let now = Date()

    let (posts0, broken0, _) = limiter.state(now: now)
    #expect(posts0 == 0)
    #expect(broken0 == false)

    limiter.recordPost(now: now)
    let (posts1, broken1, cooldown1) = limiter.state(now: now)
    #expect(posts1 == 1)
    #expect(broken1 == false)
    #expect(cooldown1 > 59)
}

// MARK: - Event Message Formatter Tests

@Test func formatProcessExitSuccess() {
    let event = CUAEvent(
        type: "process.exit",
        pid: 12345,
        details: [
            "exit_code": AnyCodable(0),
            "label": AnyCodable("Build Task"),
        ]
    )
    let msg = EventMessageFormatter.format(event)
    #expect(msg.contains("Build Task"))
    #expect(msg.contains("completed successfully"))
}

@Test func formatProcessExitFailure() {
    let event = CUAEvent(
        type: "process.exit",
        pid: 12345,
        details: [
            "exit_code": AnyCodable(1),
            "last_detail": AnyCodable("cargo build failed"),
            "label": AnyCodable("Issue #42"),
        ]
    )
    let msg = EventMessageFormatter.format(event)
    #expect(msg.contains("Issue #42"))
    #expect(msg.contains("exited with code 1"))
    #expect(msg.contains("cargo build failed"))
}

@Test func formatProcessError() {
    let event = CUAEvent(
        type: "process.error",
        pid: 100,
        details: [
            "error": AnyCodable("missing module auth"),
        ]
    )
    let msg = EventMessageFormatter.format(event)
    #expect(msg.contains("Process 100"))
    #expect(msg.contains("error: missing module auth"))
}

@Test func formatProcessIdle() {
    let event = CUAEvent(
        type: "process.idle",
        pid: 200,
        details: [
            "idle_seconds": AnyCodable(600),
            "label": AnyCodable("Agent"),
        ]
    )
    let msg = EventMessageFormatter.format(event)
    #expect(msg.contains("Agent"))
    #expect(msg.contains("idle for 10m"))
}

@Test func formatProcessGroupStateChange() {
    let event = CUAEvent(
        type: "process.group.state_change",
        pid: 300,
        details: [
            "label": AnyCodable("Test Runner"),
            "new_state": AnyCodable("FAILED"),
            "last_detail": AnyCodable("exit code 1"),
        ]
    )
    let msg = EventMessageFormatter.format(event)
    #expect(msg.contains("Test Runner"))
    #expect(msg.contains("FAILED"))
    #expect(msg.contains("exit code 1"))
}

@Test func formatBatchSingleEvent() {
    let event = CUAEvent(type: "app.launched", app: "Xcode")
    let msg = EventMessageFormatter.formatBatch([event])
    #expect(msg.contains("Xcode"))
    // Single event should not say "batch"
    #expect(!msg.contains("batch"))
}

@Test func formatBatchMultipleEvents() {
    let events = [
        CUAEvent(type: "process.exit", pid: 1, details: ["exit_code": AnyCodable(0)]),
        CUAEvent(type: "process.error", pid: 2, details: ["error": AnyCodable("fail")]),
        CUAEvent(type: "process.idle", pid: 3, details: ["idle_seconds": AnyCodable(300)]),
    ]
    let msg = EventMessageFormatter.formatBatch(events)
    #expect(msg.contains("cua batch (3 events)"))
}

// MARK: - WebhookDelivery Integration Tests

@Test func webhookDeliveryCreatesSubscription() {
    let config = WebhookConfig(
        url: URL(string: "http://localhost:9999/test")!,
        token: "secret",
        meta: ["agentId": AnyCodable("main")],
        cooldown: 10,
        maxWakes: 5
    )
    let delivery = WebhookDelivery(config: config)
    let bus = EventBus()

    delivery.start(eventBus: bus, typeFilters: Set(["process.*"]))

    #expect(delivery.subId != nil)
    #expect(bus.subscriberCount == 1)

    delivery.stop()
    #expect(bus.subscriberCount == 0)
}

@Test func webhookDeliveryInfoReturnsState() {
    let config = WebhookConfig(
        url: URL(string: "http://localhost:9999/test")!,
        cooldown: 60,
        maxWakes: 10
    )
    let delivery = WebhookDelivery(config: config)

    let info = delivery.info()
    #expect(info["webhook_url"]?.value as? String == "http://localhost:9999/test")
    #expect(info["cooldown_s"]?.value as? Int == 60)
    #expect(info["max_wakes"]?.value as? Int == 10)
    #expect(info["total_delivered"]?.value as? Int == 0)
    #expect(info["total_failed"]?.value as? Int == 0)
}

// MARK: - WebhookConfig Tests

@Test func webhookConfigDefaults() {
    let config = WebhookConfig(url: URL(string: "http://localhost/hook")!)
    #expect(config.cooldown == 300)
    #expect(config.maxWakes == 20)
    #expect(config.token == nil)
    #expect(config.meta.isEmpty)
    #expect(config.verbose == false)
}

@Test func webhookConfigCustom() {
    let config = WebhookConfig(
        url: URL(string: "http://localhost/hook")!,
        token: "tok",
        meta: ["channel": AnyCodable("slack")],
        cooldown: 60,
        maxWakes: 5,
        verbose: true
    )
    #expect(config.cooldown == 60)
    #expect(config.maxWakes == 5)
    #expect(config.token == "tok")
    #expect(config.verbose == true)
    #expect(config.meta["channel"]?.value as? String == "slack")
}

// MARK: - EventBus filter tests (ensure existing behavior preserved)

@Test func eventBusTypeFilterGlob() {
    #expect(EventBus.typeFilterMatches(filter: "process.*", eventType: "process.exit") == true)
    #expect(EventBus.typeFilterMatches(filter: "process.*", eventType: "process.error") == true)
    #expect(EventBus.typeFilterMatches(filter: "process.*", eventType: "app.launched") == false)
    #expect(EventBus.typeFilterMatches(filter: "*", eventType: "anything") == true)
    #expect(EventBus.typeFilterMatches(filter: "process.exit", eventType: "process.exit") == true)
    #expect(EventBus.typeFilterMatches(filter: "process.exit", eventType: "process.error") == false)
}

@Test func eventBusSubscribeAndPublish() {
    let bus = EventBus()
    var received: [CUAEvent] = []

    bus.subscribe(typeFilters: Set(["process.*"])) { event in
        received.append(event)
    }

    bus.publish(CUAEvent(type: "process.exit", pid: 1))
    bus.publish(CUAEvent(type: "app.launched", app: "Safari"))
    bus.publish(CUAEvent(type: "process.error", pid: 2))

    #expect(received.count == 2)
    #expect(received[0].type == "process.exit")
    #expect(received[1].type == "process.error")
}
