import Foundation

// MARK: - Milestone Engine

/// Matches log lines against milestone patterns and emits deduplicated events
public final class MilestoneEngine {
    public let definition: MilestoneDefinition
    private let eventBus: EventBus
    private let pid: Int32
    private let label: String?

    private let lock = NSLock()
    /// Tracks which milestone types have been emitted (for dedup=first)
    private var emittedFirst: Set<String> = []
    /// Tracks the last emitted milestone type (for dedup=transition)
    private var lastEmittedType: String?
    /// Tracks latest message per type (for dedup=latest)
    private var latestMessages: [String: String] = [:]
    /// Line counter
    private var lineNumber: Int = 0

    public init(definition: MilestoneDefinition, eventBus: EventBus, pid: Int32, label: String? = nil) {
        self.definition = definition
        self.eventBus = eventBus
        self.pid = pid
        self.label = label
    }

    /// Process a single log line and emit milestone events for any matching patterns
    public func processLine(_ line: String) {
        lock.lock()
        lineNumber += 1
        let currentLine = lineNumber
        lock.unlock()

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Parse JSON if format is ndjson
        var jsonObject: [String: Any]? = nil
        if definition.format == .ndjson,
           let data = trimmed.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            jsonObject = parsed
        }

        for pattern in definition.patterns {
            if let matchText = matches(pattern: pattern, line: trimmed, json: jsonObject) {
                emitIfAllowed(pattern: pattern, matchText: matchText, lineNumber: currentLine)
            }
        }
    }

    /// Reset engine state (e.g., for reprocessing)
    public func reset() {
        lock.lock()
        emittedFirst.removeAll()
        lastEmittedType = nil
        latestMessages.removeAll()
        lineNumber = 0
        lock.unlock()
    }

    // MARK: - Pattern Matching

    /// Check if a pattern matches the given line. Returns the matched text if it does.
    private func matches(pattern: MilestonePattern, line: String, json: [String: Any]?) -> String? {
        let match = pattern.match

        // any_text: simple substring match on the raw line
        if let anyText = match.anyText {
            if line.contains(anyText) {
                return anyText
            }
        }

        // json_path + value: exact value match at a JSON path
        if let jsonPath = match.jsonPath, let value = match.value, let json = json {
            let values = resolveJSONPath(jsonPath, in: json)
            for v in values {
                if v == value { return value }
            }
        }

        // json_path + regex: regex match on values at a JSON path
        if let jsonPath = match.jsonPath, let regexStr = match.regex, let json = json {
            let values = resolveJSONPath(jsonPath, in: json)
            if let regex = try? NSRegularExpression(pattern: regexStr) {
                for v in values {
                    let range = NSRange(v.startIndex..., in: v)
                    if let result = regex.firstMatch(in: v, range: range) {
                        let matchRange = Range(result.range, in: v)!
                        return String(v[matchRange])
                    }
                }
            }
        }

        // regex only (no json_path): match on the raw line
        if match.jsonPath == nil, let regexStr = match.regex {
            if let regex = try? NSRegularExpression(pattern: regexStr) {
                let range = NSRange(line.startIndex..., in: line)
                if let result = regex.firstMatch(in: line, range: range) {
                    let matchRange = Range(result.range, in: line)!
                    return String(line[matchRange])
                }
            }
        }

        return nil
    }

    // MARK: - JSON Path Resolution (simple subset: $.key.key[*].key)

    /// Resolve a simple JSON path like "$.message.content[*].name"
    /// Supports: root ($), dot notation, and wildcard array index ([*])
    private func resolveJSONPath(_ path: String, in json: [String: Any]) -> [String] {
        var pathStr = path
        if pathStr.hasPrefix("$.") {
            pathStr = String(pathStr.dropFirst(2))
        } else if pathStr.hasPrefix("$") {
            pathStr = String(pathStr.dropFirst(1))
        }

        let segments = parsePathSegments(pathStr)
        let values = resolveSegments(segments, in: json as Any)
        return values.compactMap { val -> String? in
            if let s = val as? String { return s }
            if let n = val as? Int { return String(n) }
            if let d = val as? Double { return String(d) }
            if let b = val as? Bool { return String(b) }
            return nil
        }
    }

    private struct PathSegment {
        let key: String
        let isWildcard: Bool // [*]
    }

    private func parsePathSegments(_ path: String) -> [PathSegment] {
        var segments: [PathSegment] = []
        let parts = path.split(separator: ".", omittingEmptySubsequences: true).map(String.init)

        for part in parts {
            if part.hasSuffix("[*]") {
                let key = String(part.dropLast(3))
                if !key.isEmpty {
                    segments.append(PathSegment(key: key, isWildcard: false))
                }
                segments.append(PathSegment(key: "", isWildcard: true))
            } else {
                segments.append(PathSegment(key: part, isWildcard: false))
            }
        }

        return segments
    }

    private func resolveSegments(_ segments: [PathSegment], in value: Any) -> [Any] {
        guard !segments.isEmpty else { return [value] }

        var remaining = segments
        let segment = remaining.removeFirst()

        if segment.isWildcard {
            // Expand array
            guard let array = value as? [Any] else { return [] }
            return array.flatMap { resolveSegments(remaining, in: $0) }
        } else {
            guard let dict = value as? [String: Any], let next = dict[segment.key] else { return [] }
            return resolveSegments(remaining, in: next)
        }
    }

    // MARK: - Deduplication & Emission

    private func emitIfAllowed(pattern: MilestonePattern, matchText: String, lineNumber: Int) {
        lock.lock()
        defer { lock.unlock() }

        let resolvedMessage = pattern.resolvedMessage(matchText: matchText)

        switch pattern.dedupe {
        case .first:
            guard !emittedFirst.contains(pattern.type) else { return }
            emittedFirst.insert(pattern.type)
            emitEvent(pattern: pattern, message: resolvedMessage, lineNumber: lineNumber)

        case .transition:
            guard lastEmittedType != pattern.type else { return }
            lastEmittedType = pattern.type
            emitEvent(pattern: pattern, message: resolvedMessage, lineNumber: lineNumber)

        case .latest:
            let isNew = latestMessages[pattern.type] == nil
            latestMessages[pattern.type] = resolvedMessage
            if isNew {
                emitEvent(pattern: pattern, message: resolvedMessage, lineNumber: lineNumber)
            } else {
                // Update: re-emit with latest data
                emitEvent(pattern: pattern, message: resolvedMessage, lineNumber: lineNumber)
            }

        case .every:
            emitEvent(pattern: pattern, message: resolvedMessage, lineNumber: lineNumber)
        }
    }

    private func emitEvent(pattern: MilestonePattern, message: String, lineNumber: Int) {
        var details: [String: AnyCodable] = [
            "type": AnyCodable(pattern.type),
            "emoji": AnyCodable(pattern.emoji),
            "message": AnyCodable(message),
            "line_number": AnyCodable(lineNumber),
        ]
        if let label = label {
            details["label"] = AnyCodable(label)
        }

        let event = CUAEvent(
            type: "process.milestone",
            pid: pid,
            details: details
        )
        eventBus.publish(event)
    }
}

// MARK: - Milestone Preset Loader

public struct MilestonePresets {

    /// Search paths for milestone files
    public static var searchPaths: [String] {
        [
            NSHomeDirectory() + "/.agentview/milestones",
            NSHomeDirectory() + "/.cua/milestones",
        ]
    }

    /// Load a milestone definition by name (preset) or file path
    public static func load(nameOrPath: String) throws -> MilestoneDefinition {
        // If it's a file path (contains / or ends with .yaml/.json)
        if nameOrPath.contains("/") || nameOrPath.hasSuffix(".yaml") || nameOrPath.hasSuffix(".yml") || nameOrPath.hasSuffix(".json") {
            return try loadFromFile(path: nameOrPath)
        }

        // Try built-in presets first
        if let preset = builtinPresets[nameOrPath] {
            return preset
        }

        // Search user directories
        for dir in searchPaths {
            for ext in ["yaml", "yml", "json"] {
                let path = "\(dir)/\(nameOrPath).\(ext)"
                if FileManager.default.fileExists(atPath: path) {
                    return try loadFromFile(path: path)
                }
            }
        }

        throw MilestoneYAMLParser.ParseError.invalidStructure(
            "Milestone '\(nameOrPath)' not found. Use 'cua milestones list' to see available presets."
        )
    }

    /// Load from a specific file path
    public static func loadFromFile(path: String) throws -> MilestoneDefinition {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            throw MilestoneYAMLParser.ParseError.invalidStructure("Cannot read file: \(path)")
        }

        if path.hasSuffix(".json") {
            return try MilestoneDefinition.fromJSON(data)
        }

        return try MilestoneYAMLParser.parse(content)
    }

    /// List all available presets (built-in + user-installed)
    public static func listAvailable() -> [(name: String, description: String, source: String)] {
        var results: [(name: String, description: String, source: String)] = []

        // Built-in presets
        for (name, def) in builtinPresets.sorted(by: { $0.key < $1.key }) {
            results.append((name: name, description: def.description, source: "builtin"))
        }

        // User-installed
        for dir in searchPaths {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files.sorted() {
                let ext = (file as NSString).pathExtension
                guard ["yaml", "yml", "json"].contains(ext) else { continue }
                let name = (file as NSString).deletingPathExtension
                if builtinPresets[name] != nil { continue } // Skip if shadowing built-in
                let path = "\(dir)/\(file)"
                if let def = try? loadFromFile(path: path) {
                    results.append((name: name, description: def.description, source: path))
                } else {
                    results.append((name: name, description: "(parse error)", source: path))
                }
            }
        }

        return results
    }

    // MARK: - Built-in Presets

    public static let builtinPresets: [String: MilestoneDefinition] = [
        "claude-code": claudeCodePreset,
        "cargo": cargoPreset,
        "npm": npmPreset,
        "pytest": pytestPreset,
        "docker": dockerPreset,
    ]

    public static let claudeCodePreset = MilestoneDefinition(
        name: "claude-code",
        description: "Claude Code agent milestones (NDJSON stream-json output)",
        format: .ndjson,
        patterns: [
            MilestonePattern(type: "exploring", match: MilestoneMatch(
                jsonPath: "$.message.content[*].name", value: "Read"
            ), emoji: "\u{1f50d}", message: "Exploring codebase...", messageTemplate: nil, dedupe: .first),

            MilestonePattern(type: "building", match: MilestoneMatch(
                jsonPath: "$.message.content[*].input.command",
                regex: "cargo build|npm run build|go build|swift build|make"
            ), emoji: "\u{1f528}", message: "Building...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "testing", match: MilestoneMatch(
                jsonPath: "$.message.content[*].input.command",
                regex: "cargo test|npm test|pytest|go test|swift test"
            ), emoji: "\u{1f9ea}", message: "Running tests...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "tests_passed", match: MilestoneMatch(
                jsonPath: "$.message.content[*].content",
                regex: "test result: ok|Tests:.*passed|passed|PASSED"
            ), emoji: "\u{2705}", message: "Tests passing", messageTemplate: nil, dedupe: .latest),

            MilestonePattern(type: "pr_creating", match: MilestoneMatch(
                jsonPath: "$.message.content[*].input.command",
                regex: "gh pr create"
            ), emoji: "\u{1f4dd}", message: "Creating PR...", messageTemplate: nil, dedupe: .first),

            MilestonePattern(type: "pr_opened", match: MilestoneMatch(
                jsonPath: "$.message.content[*].content",
                regex: "https://github.com/.*/pull/[0-9]+"
            ), emoji: "\u{1f517}", message: nil, messageTemplate: "PR opened: {match}", dedupe: .first),

            MilestonePattern(type: "ci_watching", match: MilestoneMatch(
                jsonPath: "$.message.content[*].input.command",
                regex: "gh pr checks|gh run watch"
            ), emoji: "\u{1f440}", message: "Watching CI...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "done", match: MilestoneMatch(
                anyText: "SWARM_DONE"
            ), emoji: "\u{1f389}", message: "Complete!", messageTemplate: nil, dedupe: .first),
        ]
    )

    public static let cargoPreset = MilestoneDefinition(
        name: "cargo",
        description: "Rust cargo build/test/clippy milestones (plain text logs)",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "compiling", match: MilestoneMatch(
                regex: "Compiling .+ v[0-9]"
            ), emoji: "\u{1f528}", message: "Compiling...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "building", match: MilestoneMatch(
                regex: "cargo build|Building"
            ), emoji: "\u{1f3d7}", message: "Building...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "testing", match: MilestoneMatch(
                regex: "running \\d+ tests?|cargo test"
            ), emoji: "\u{1f9ea}", message: "Running tests...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "tests_passed", match: MilestoneMatch(
                regex: "test result: ok\\. \\d+ passed"
            ), emoji: "\u{2705}", message: nil, messageTemplate: "Tests: {match}", dedupe: .latest),

            MilestonePattern(type: "tests_failed", match: MilestoneMatch(
                regex: "test result: FAILED"
            ), emoji: "\u{274c}", message: "Tests failed", messageTemplate: nil, dedupe: .latest),

            MilestonePattern(type: "clippy", match: MilestoneMatch(
                regex: "cargo clippy|Checking .+ with clippy"
            ), emoji: "\u{1f4ce}", message: "Running clippy...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "finished", match: MilestoneMatch(
                regex: "Finished .+ target"
            ), emoji: "\u{2705}", message: nil, messageTemplate: "{match}", dedupe: .latest),
        ]
    )

    public static let npmPreset = MilestoneDefinition(
        name: "npm",
        description: "Node.js npm/yarn/pnpm build/test milestones",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "installing", match: MilestoneMatch(
                regex: "npm install|yarn install|pnpm install|added \\d+ packages"
            ), emoji: "\u{1f4e6}", message: "Installing dependencies...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "building", match: MilestoneMatch(
                regex: "npm run build|yarn build|pnpm build|webpack|vite build|next build"
            ), emoji: "\u{1f528}", message: "Building...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "linting", match: MilestoneMatch(
                regex: "npm run lint|eslint|prettier"
            ), emoji: "\u{1f9f9}", message: "Linting...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "testing", match: MilestoneMatch(
                regex: "npm test|jest|vitest|mocha"
            ), emoji: "\u{1f9ea}", message: "Running tests...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "tests_passed", match: MilestoneMatch(
                regex: "Tests:.*\\d+ passed|test suites?.* passed|All tests passed"
            ), emoji: "\u{2705}", message: nil, messageTemplate: "{match}", dedupe: .latest),

            MilestonePattern(type: "tests_failed", match: MilestoneMatch(
                regex: "Tests:.*\\d+ failed|FAIL "
            ), emoji: "\u{274c}", message: "Tests failed", messageTemplate: nil, dedupe: .latest),

            MilestonePattern(type: "build_done", match: MilestoneMatch(
                regex: "Successfully compiled|Build completed|Compiled successfully"
            ), emoji: "\u{2705}", message: "Build complete", messageTemplate: nil, dedupe: .latest),
        ]
    )

    public static let pytestPreset = MilestoneDefinition(
        name: "pytest",
        description: "Python pytest output milestones",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "collecting", match: MilestoneMatch(
                regex: "collecting \\.\\.\\.|collected \\d+ items?"
            ), emoji: "\u{1f50d}", message: nil, messageTemplate: "{match}", dedupe: .first),

            MilestonePattern(type: "testing", match: MilestoneMatch(
                regex: "PASSED|FAILED|ERROR|::.*test_"
            ), emoji: "\u{1f9ea}", message: "Running tests...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "passed", match: MilestoneMatch(
                regex: "\\d+ passed"
            ), emoji: "\u{2705}", message: nil, messageTemplate: "{match}", dedupe: .latest),

            MilestonePattern(type: "failed", match: MilestoneMatch(
                regex: "\\d+ failed"
            ), emoji: "\u{274c}", message: nil, messageTemplate: "{match}", dedupe: .latest),

            MilestonePattern(type: "warnings", match: MilestoneMatch(
                regex: "\\d+ warnings?"
            ), emoji: "\u{26a0}\u{fe0f}", message: nil, messageTemplate: "{match}", dedupe: .latest),

            MilestonePattern(type: "coverage", match: MilestoneMatch(
                regex: "TOTAL.*\\d+%|coverage: \\d+"
            ), emoji: "\u{1f4ca}", message: nil, messageTemplate: "Coverage: {match}", dedupe: .latest),
        ]
    )

    public static let dockerPreset = MilestoneDefinition(
        name: "docker",
        description: "Docker build stage milestones",
        format: .plaintext,
        patterns: [
            MilestonePattern(type: "building", match: MilestoneMatch(
                regex: "\\[\\d+/\\d+\\]|Step \\d+/\\d+|STEP \\d+"
            ), emoji: "\u{1f40b}", message: nil, messageTemplate: "Building: {match}", dedupe: .every),

            MilestonePattern(type: "pulling", match: MilestoneMatch(
                regex: "Pulling from|Pull complete|Already exists"
            ), emoji: "\u{2b07}\u{fe0f}", message: "Pulling image layers...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "copying", match: MilestoneMatch(
                regex: "COPY |ADD "
            ), emoji: "\u{1f4c1}", message: "Copying files...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "running", match: MilestoneMatch(
                regex: "RUN "
            ), emoji: "\u{2699}\u{fe0f}", message: "Running command...", messageTemplate: nil, dedupe: .transition),

            MilestonePattern(type: "exporting", match: MilestoneMatch(
                regex: "exporting to image|exporting layers"
            ), emoji: "\u{1f4e4}", message: "Exporting image...", messageTemplate: nil, dedupe: .first),

            MilestonePattern(type: "done", match: MilestoneMatch(
                regex: "Successfully built|Successfully tagged|writing image sha256"
            ), emoji: "\u{2705}", message: nil, messageTemplate: "Built: {match}", dedupe: .first),
        ]
    )
}
