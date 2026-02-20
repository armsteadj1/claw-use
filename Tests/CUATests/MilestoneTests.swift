import Foundation
import Testing
@testable import CUACore

// MARK: - YAML Parser Tests

@Test func milestoneYAMLParserBasic() throws {
    let yaml = """
    name: test-preset
    description: Test milestone preset
    format: plaintext

    patterns:
      - type: building
        match:
          regex: "cargo build"
        emoji: "H"
        message: "Building..."
        dedupe: transition

      - type: done
        match:
          any_text: "DONE"
        emoji: "Y"
        message: "Complete!"
        dedupe: first
    """

    let def = try MilestoneYAMLParser.parse(yaml)
    #expect(def.name == "test-preset")
    #expect(def.description == "Test milestone preset")
    #expect(def.format == .plaintext)
    #expect(def.patterns.count == 2)
    #expect(def.patterns[0].type == "building")
    #expect(def.patterns[0].match.regex == "cargo build")
    #expect(def.patterns[0].dedupe == .transition)
    #expect(def.patterns[1].type == "done")
    #expect(def.patterns[1].match.anyText == "DONE")
    #expect(def.patterns[1].dedupe == .first)
}

@Test func milestoneYAMLParserNDJSON() throws {
    let yaml = """
    name: json-test
    description: JSON path test
    format: ndjson

    patterns:
      - type: exploring
        match:
          json_path: "$.message.content[*].name"
          value: "Read"
        emoji: "S"
        message: "Exploring..."
        dedupe: first
    """

    let def = try MilestoneYAMLParser.parse(yaml)
    #expect(def.format == .ndjson)
    #expect(def.patterns[0].match.jsonPath == "$.message.content[*].name")
    #expect(def.patterns[0].match.value == "Read")
}

@Test func milestoneYAMLParserMissingName() {
    let yaml = """
    description: No name
    format: plaintext

    patterns:
      - type: test
        match:
          any_text: "test"
        emoji: "T"
        message: "test"
        dedupe: first
    """

    #expect(throws: MilestoneYAMLParser.ParseError.self) {
        _ = try MilestoneYAMLParser.parse(yaml)
    }
}

@Test func milestoneYAMLParserInvalidFormat() {
    let yaml = """
    name: test
    description: bad format
    format: xml

    patterns:
      - type: test
        match:
          any_text: "test"
        emoji: "T"
        message: "test"
        dedupe: first
    """

    #expect(throws: MilestoneYAMLParser.ParseError.self) {
        _ = try MilestoneYAMLParser.parse(yaml)
    }
}

@Test func milestoneYAMLParserSkipsComments() throws {
    let yaml = """
    # This is a comment
    name: commented
    description: Has comments
    format: plaintext
    # Another comment

    patterns:
      # Pattern comment
      - type: test
        match:
          any_text: "hello"
        emoji: "W"
        message: "Wave"
        dedupe: first
    """

    let def = try MilestoneYAMLParser.parse(yaml)
    #expect(def.name == "commented")
    #expect(def.patterns.count == 1)
}

// MARK: - Validation Tests

@Test func milestoneValidationValid() {
    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "build", match: MilestoneMatch(regex: "build"),
                           emoji: "H", message: "Building", messageTemplate: nil, dedupe: .transition)
        ]
    )
    let issues = MilestoneYAMLParser.validate(def)
    let errors = issues.filter { $0.hasPrefix("error:") }
    #expect(errors.isEmpty)
}

@Test func milestoneValidationEmptyName() {
    let def = MilestoneDefinition(
        name: "",
        description: "Test",
        format: .plaintext,
        patterns: []
    )
    let issues = MilestoneYAMLParser.validate(def)
    #expect(issues.contains { $0.contains("name is empty") })
}

@Test func milestoneValidationNoMatchCriteria() {
    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "bad", match: MilestoneMatch(),
                           emoji: "X", message: "Bad", messageTemplate: nil, dedupe: .first)
        ]
    )
    let issues = MilestoneYAMLParser.validate(def)
    #expect(issues.contains { $0.contains("no match criteria") })
}

@Test func milestoneValidationInvalidRegex() {
    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "bad", match: MilestoneMatch(regex: "[invalid"),
                           emoji: "X", message: "Bad", messageTemplate: nil, dedupe: .first)
        ]
    )
    let issues = MilestoneYAMLParser.validate(def)
    #expect(issues.contains { $0.contains("invalid regex") })
}

@Test func milestoneValidationDuplicateType() {
    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "build", match: MilestoneMatch(regex: "a"),
                           emoji: "A", message: "A", messageTemplate: nil, dedupe: .first),
            MilestonePattern(type: "build", match: MilestoneMatch(regex: "b"),
                           emoji: "B", message: "B", messageTemplate: nil, dedupe: .first),
        ]
    )
    let issues = MilestoneYAMLParser.validate(def)
    #expect(issues.contains { $0.contains("duplicate pattern type") })
}

// MARK: - MilestoneEngine Tests

@Test func milestoneEngineAnyTextMatch() {
    let eventBus = EventBus()
    var receivedEvents: [CUAEvent] = []
    eventBus.subscribe(typeFilters: Set(["process.milestone"])) { event in
        receivedEvents.append(event)
    }

    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "done", match: MilestoneMatch(anyText: "SWARM_DONE"),
                           emoji: "Y", message: "Complete!", messageTemplate: nil, dedupe: .first)
        ]
    )

    let engine = MilestoneEngine(definition: def, eventBus: eventBus, pid: 123)
    engine.processLine("some output line")
    engine.processLine("SWARM_DONE")
    engine.processLine("more output")

    #expect(receivedEvents.count == 1)
    #expect(receivedEvents[0].type == "process.milestone")
    #expect(receivedEvents[0].pid == 123)
    #expect(receivedEvents[0].details?["type"]?.value as? String == "done")
    #expect(receivedEvents[0].details?["message"]?.value as? String == "Complete!")
}

@Test func milestoneEngineRegexMatch() {
    let eventBus = EventBus()
    var receivedEvents: [CUAEvent] = []
    eventBus.subscribe(typeFilters: Set(["process.milestone"])) { event in
        receivedEvents.append(event)
    }

    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "testing", match: MilestoneMatch(regex: "running \\d+ tests?"),
                           emoji: "T", message: "Running tests...", messageTemplate: nil, dedupe: .transition)
        ]
    )

    let engine = MilestoneEngine(definition: def, eventBus: eventBus, pid: 456)
    engine.processLine("running 42 tests")

    #expect(receivedEvents.count == 1)
    #expect(receivedEvents[0].details?["type"]?.value as? String == "testing")
}

@Test func milestoneEngineDedupeFirst() {
    let eventBus = EventBus()
    var count = 0
    eventBus.subscribe(typeFilters: Set(["process.milestone"])) { _ in
        count += 1
    }

    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "done", match: MilestoneMatch(anyText: "DONE"),
                           emoji: "Y", message: "Done", messageTemplate: nil, dedupe: .first)
        ]
    )

    let engine = MilestoneEngine(definition: def, eventBus: eventBus, pid: 1)
    engine.processLine("DONE")
    engine.processLine("DONE")
    engine.processLine("DONE")

    #expect(count == 1) // first only
}

@Test func milestoneEngineDedupeTransition() {
    let eventBus = EventBus()
    var types: [String] = []
    eventBus.subscribe(typeFilters: Set(["process.milestone"])) { event in
        types.append(event.details?["type"]?.value as? String ?? "")
    }

    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "building", match: MilestoneMatch(regex: "build"),
                           emoji: "B", message: "Building", messageTemplate: nil, dedupe: .transition),
            MilestonePattern(type: "testing", match: MilestoneMatch(regex: "test"),
                           emoji: "T", message: "Testing", messageTemplate: nil, dedupe: .transition),
        ]
    )

    let engine = MilestoneEngine(definition: def, eventBus: eventBus, pid: 1)
    engine.processLine("build start")     // emit building
    engine.processLine("build continue")  // suppress (same state)
    engine.processLine("test start")      // emit testing
    engine.processLine("build again")     // emit building (transition back)

    #expect(types == ["building", "testing", "building"])
}

@Test func milestoneEngineDedupeEvery() {
    let eventBus = EventBus()
    var count = 0
    eventBus.subscribe(typeFilters: Set(["process.milestone"])) { _ in
        count += 1
    }

    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "step", match: MilestoneMatch(regex: "Step \\d+"),
                           emoji: "S", message: nil, messageTemplate: "{match}", dedupe: .every)
        ]
    )

    let engine = MilestoneEngine(definition: def, eventBus: eventBus, pid: 1)
    engine.processLine("Step 1")
    engine.processLine("Step 2")
    engine.processLine("Step 3")

    #expect(count == 3)
}

@Test func milestoneEngineMessageTemplate() {
    let eventBus = EventBus()
    var messages: [String] = []
    eventBus.subscribe(typeFilters: Set(["process.milestone"])) { event in
        messages.append(event.details?["message"]?.value as? String ?? "")
    }

    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "pr", match: MilestoneMatch(regex: "https://github.com/.*/pull/\\d+"),
                           emoji: "L", message: nil, messageTemplate: "PR opened: {match}", dedupe: .first)
        ]
    )

    let engine = MilestoneEngine(definition: def, eventBus: eventBus, pid: 1)
    engine.processLine("Created https://github.com/foo/bar/pull/42")

    #expect(messages.count == 1)
    #expect(messages[0] == "PR opened: https://github.com/foo/bar/pull/42")
}

@Test func milestoneEngineJSONPathMatch() {
    let eventBus = EventBus()
    var receivedEvents: [CUAEvent] = []
    eventBus.subscribe(typeFilters: Set(["process.milestone"])) { event in
        receivedEvents.append(event)
    }

    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .ndjson,
        patterns: [
            MilestonePattern(type: "exploring", match: MilestoneMatch(jsonPath: "$.message.content[*].name", value: "Read"),
                           emoji: "S", message: "Exploring...", messageTemplate: nil, dedupe: .first)
        ]
    )

    let engine = MilestoneEngine(definition: def, eventBus: eventBus, pid: 1)
    let jsonLine = """
    {"message":{"content":[{"name":"Read","input":{"path":"/foo"}},{"name":"Write"}]}}
    """
    engine.processLine(jsonLine)

    #expect(receivedEvents.count == 1)
    #expect(receivedEvents[0].details?["type"]?.value as? String == "exploring")
}

@Test func milestoneEngineJSONPathRegex() {
    let eventBus = EventBus()
    var receivedEvents: [CUAEvent] = []
    eventBus.subscribe(typeFilters: Set(["process.milestone"])) { event in
        receivedEvents.append(event)
    }

    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .ndjson,
        patterns: [
            MilestonePattern(type: "building", match: MilestoneMatch(
                jsonPath: "$.message.content[*].input.command",
                regex: "cargo build|npm run build"
            ), emoji: "H", message: "Building...", messageTemplate: nil, dedupe: .transition)
        ]
    )

    let engine = MilestoneEngine(definition: def, eventBus: eventBus, pid: 1)
    let jsonLine = """
    {"message":{"content":[{"input":{"command":"cargo build --release"}}]}}
    """
    engine.processLine(jsonLine)

    #expect(receivedEvents.count == 1)
}

@Test func milestoneEngineReset() {
    let eventBus = EventBus()
    var count = 0
    eventBus.subscribe(typeFilters: Set(["process.milestone"])) { _ in
        count += 1
    }

    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "done", match: MilestoneMatch(anyText: "DONE"),
                           emoji: "Y", message: "Done", messageTemplate: nil, dedupe: .first)
        ]
    )

    let engine = MilestoneEngine(definition: def, eventBus: eventBus, pid: 1)
    engine.processLine("DONE")
    #expect(count == 1)

    engine.reset()
    engine.processLine("DONE")
    #expect(count == 2) // After reset, first dedup allows again
}

@Test func milestoneEngineLineNumber() {
    let eventBus = EventBus()
    var lineNumbers: [Int] = []
    eventBus.subscribe(typeFilters: Set(["process.milestone"])) { event in
        lineNumbers.append(event.details?["line_number"]?.value as? Int ?? 0)
    }

    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "match", match: MilestoneMatch(anyText: "HIT"),
                           emoji: "O", message: "Hit", messageTemplate: nil, dedupe: .every)
        ]
    )

    let engine = MilestoneEngine(definition: def, eventBus: eventBus, pid: 1)
    engine.processLine("miss")
    engine.processLine("miss")
    engine.processLine("HIT")
    engine.processLine("miss")
    engine.processLine("HIT")

    #expect(lineNumbers == [3, 5])
}

// MARK: - Preset Tests

@Test func milestonePresetsExist() {
    let presets = MilestonePresets.builtinPresets
    #expect(presets["claude-code"] != nil)
    #expect(presets["cargo"] != nil)
    #expect(presets["npm"] != nil)
    #expect(presets["pytest"] != nil)
    #expect(presets["docker"] != nil)
}

@Test func milestonePresetsValidate() {
    for (name, def) in MilestonePresets.builtinPresets {
        let issues = MilestoneYAMLParser.validate(def)
        let errors = issues.filter { $0.hasPrefix("error:") }
        #expect(errors.isEmpty, "Preset '\(name)' has validation errors: \(errors)")
    }
}

@Test func milestonePresetsListAvailable() {
    let available = MilestonePresets.listAvailable()
    #expect(available.count >= 5)
    #expect(available.contains { $0.name == "claude-code" })
    #expect(available.contains { $0.name == "cargo" })
}

@Test func milestonePresetLoadBuiltin() throws {
    let def = try MilestonePresets.load(nameOrPath: "claude-code")
    #expect(def.name == "claude-code")
    #expect(def.format == .ndjson)
    #expect(!def.patterns.isEmpty)
}

@Test func milestonePresetLoadNotFound() {
    #expect(throws: MilestoneYAMLParser.ParseError.self) {
        _ = try MilestonePresets.load(nameOrPath: "nonexistent-preset")
    }
}

// MARK: - MilestoneDefinition Codable

@Test func milestoneDefinitionCodable() throws {
    let def = MilestoneDefinition(
        name: "test",
        description: "Test preset",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "build", match: MilestoneMatch(regex: "build"),
                           emoji: "H", message: "Building", messageTemplate: nil, dedupe: .transition)
        ]
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(def)

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let decoded = try decoder.decode(MilestoneDefinition.self, from: data)

    #expect(decoded.name == "test")
    #expect(decoded.format == .plaintext)
    #expect(decoded.patterns.count == 1)
    #expect(decoded.patterns[0].type == "build")
    #expect(decoded.patterns[0].dedupe == .transition)
}

@Test func milestonePatternResolvedMessage() {
    let pattern = MilestonePattern(
        type: "pr",
        match: MilestoneMatch(regex: "https://.*"),
        emoji: "L",
        message: nil,
        messageTemplate: "PR opened: {match}",
        dedupe: .first
    )

    #expect(pattern.resolvedMessage(matchText: "https://github.com/foo/pull/1") == "PR opened: https://github.com/foo/pull/1")
}

@Test func milestonePatternResolvedMessageFallback() {
    let pattern = MilestonePattern(
        type: "build",
        match: MilestoneMatch(regex: "build"),
        emoji: "H",
        message: "Building...",
        messageTemplate: nil,
        dedupe: .transition
    )

    #expect(pattern.resolvedMessage(matchText: nil) == "Building...")
}

@Test func milestoneDedupeLatest() {
    let eventBus = EventBus()
    var messages: [String] = []
    eventBus.subscribe(typeFilters: Set(["process.milestone"])) { event in
        messages.append(event.details?["message"]?.value as? String ?? "")
    }

    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "count", match: MilestoneMatch(regex: "\\d+ passed"),
                           emoji: "Y", message: nil, messageTemplate: "{match}", dedupe: .latest)
        ]
    )

    let engine = MilestoneEngine(definition: def, eventBus: eventBus, pid: 1)
    engine.processLine("5 passed")
    engine.processLine("10 passed")
    engine.processLine("15 passed")

    #expect(messages.count == 3) // latest emits every time
    #expect(messages[0] == "5 passed")
    #expect(messages[2] == "15 passed")
}

@Test func milestoneEngineNonMatchingLineIgnored() {
    let eventBus = EventBus()
    var count = 0
    eventBus.subscribe(typeFilters: Set(["process.milestone"])) { _ in
        count += 1
    }

    let def = MilestoneDefinition(
        name: "test",
        description: "Test",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "match", match: MilestoneMatch(regex: "^IMPORTANT:"),
                           emoji: "!", message: "Important", messageTemplate: nil, dedupe: .every)
        ]
    )

    let engine = MilestoneEngine(definition: def, eventBus: eventBus, pid: 1)
    engine.processLine("just a regular line")
    engine.processLine("nothing special here")
    engine.processLine("")

    #expect(count == 0)
}
