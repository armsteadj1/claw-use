import Foundation

// MARK: - Milestone Definition Models

/// A milestone definition file describing patterns to match in process output
public struct MilestoneDefinition: Codable {
    public let name: String
    public let description: String
    public let format: MilestoneFormat
    public let patterns: [MilestonePattern]

    public init(name: String, description: String, format: MilestoneFormat, patterns: [MilestonePattern]) {
        self.name = name
        self.description = description
        self.format = format
        self.patterns = patterns
    }
}

/// Log format expected by the milestone file
public enum MilestoneFormat: String, Codable {
    case ndjson
    case plaintext
}

/// Deduplication mode for milestone emissions
public enum DedupeMode: String, Codable {
    case first      // emit only the first match
    case transition // emit on state change (A->B->A emits 3 times)
    case latest     // emit once, update with latest match data
    case every      // emit every match
}

/// A single milestone pattern definition
public struct MilestonePattern: Codable {
    public let type: String
    public let match: MilestoneMatch
    public let emoji: String
    public let message: String?
    public let messageTemplate: String?
    public let dedupe: DedupeMode

    public init(type: String, match: MilestoneMatch, emoji: String, message: String?,
                messageTemplate: String?, dedupe: DedupeMode) {
        self.type = type
        self.match = match
        self.emoji = emoji
        self.message = message
        self.messageTemplate = messageTemplate
        self.dedupe = dedupe
    }

    enum CodingKeys: String, CodingKey {
        case type, match, emoji, message, messageTemplate = "message_template", dedupe
    }

    /// Resolved message for a given match result
    public func resolvedMessage(matchText: String?) -> String {
        if let template = messageTemplate, let text = matchText {
            return template.replacingOccurrences(of: "{match}", with: text)
        }
        return message ?? type
    }
}

/// Match criteria for a milestone pattern
public struct MilestoneMatch: Codable {
    public let jsonPath: String?
    public let value: String?
    public let regex: String?
    public let anyText: String?
    public let exitCode: Int?

    public init(jsonPath: String? = nil, value: String? = nil, regex: String? = nil,
                anyText: String? = nil, exitCode: Int? = nil) {
        self.jsonPath = jsonPath
        self.value = value
        self.regex = regex
        self.anyText = anyText
        self.exitCode = exitCode
    }

    enum CodingKeys: String, CodingKey {
        case jsonPath = "json_path"
        case value, regex
        case anyText = "any_text"
        case exitCode = "exit_code"
    }
}

// MARK: - Simple YAML Parser (subset needed for milestone files)

/// Parses a subset of YAML used for milestone definition files.
/// Supports: scalars, sequences (- items), and nested mappings with indentation.
/// Does NOT support: anchors, aliases, multi-line strings, flow style, etc.
public struct MilestoneYAMLParser {

    public enum ParseError: Error, CustomStringConvertible {
        case invalidStructure(String)
        case missingField(String)
        case invalidValue(String)

        public var description: String {
            switch self {
            case .invalidStructure(let msg): return "YAML structure error: \(msg)"
            case .missingField(let field): return "Missing required field: \(field)"
            case .invalidValue(let msg): return "Invalid value: \(msg)"
            }
        }
    }

    /// Parse a milestone YAML string into a MilestoneDefinition
    public static func parse(_ yaml: String) throws -> MilestoneDefinition {
        let lines = yaml.components(separatedBy: "\n")
        var topLevel: [String: Any] = [:]
        var patterns: [[String: Any]] = []
        var currentPattern: [String: Any]? = nil
        var currentMatch: [String: Any]? = nil
        var inPatterns = false

        for rawLine in lines {
            let line = rawLine
            // Skip empty lines and comments
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix(while: { $0 == " " }).count

            if !inPatterns {
                // Top-level key: value
                if indent == 0, let (key, val) = parseKeyValue(trimmed) {
                    if key == "patterns" {
                        inPatterns = true
                    } else {
                        topLevel[key] = val
                    }
                }
            } else {
                // Inside patterns array
                if indent == 0 && !trimmed.hasPrefix("-") {
                    // Back to top-level (shouldn't happen in valid milestone YAML)
                    break
                }

                // New pattern entry (  - type: ...)
                if trimmed.hasPrefix("- ") {
                    // Save previous pattern
                    if var cp = currentPattern {
                        if let cm = currentMatch { cp["match"] = cm }
                        patterns.append(cp)
                    }
                    currentPattern = [:]
                    currentMatch = nil

                    let afterDash = String(trimmed.dropFirst(2))
                    if let (key, val) = parseKeyValue(afterDash) {
                        currentPattern?[key] = val
                    }
                } else if indent >= 4 {
                    // Pattern property or match property
                    if let (key, val) = parseKeyValue(trimmed) {
                        if key == "match" {
                            currentMatch = [:]
                        } else if indent >= 6 && currentMatch != nil {
                            // Match sub-property
                            currentMatch?[key] = val
                        } else {
                            currentPattern?[key] = val
                        }
                    }
                }
            }
        }

        // Save last pattern
        if var cp = currentPattern {
            if let cm = currentMatch { cp["match"] = cm }
            patterns.append(cp)
        }

        // Build the MilestoneDefinition
        guard let name = topLevel["name"] as? String else {
            throw ParseError.missingField("name")
        }
        let description = topLevel["description"] as? String ?? ""
        let formatStr = topLevel["format"] as? String ?? "plaintext"
        guard let format = MilestoneFormat(rawValue: formatStr) else {
            throw ParseError.invalidValue("format must be 'ndjson' or 'plaintext', got '\(formatStr)'")
        }

        let parsedPatterns = try patterns.map { dict -> MilestonePattern in
            guard let type = dict["type"] as? String else {
                throw ParseError.missingField("type in pattern")
            }
            let emoji = dict["emoji"] as? String ?? ""
            let message = dict["message"] as? String
            let messageTemplate = dict["message_template"] as? String
            let dedupeStr = dict["dedupe"] as? String ?? "first"
            guard let dedupe = DedupeMode(rawValue: dedupeStr) else {
                throw ParseError.invalidValue("dedupe must be first/transition/latest/every, got '\(dedupeStr)'")
            }

            let matchDict = dict["match"] as? [String: Any] ?? [:]
            let match = MilestoneMatch(
                jsonPath: matchDict["json_path"] as? String,
                value: matchDict["value"] as? String,
                regex: matchDict["regex"] as? String,
                anyText: matchDict["any_text"] as? String,
                exitCode: matchDict["exit_code"] as? Int
                    ?? (matchDict["exit_code"] as? String).flatMap { Int($0) }
            )

            return MilestonePattern(
                type: type, match: match, emoji: emoji,
                message: message, messageTemplate: messageTemplate, dedupe: dedupe
            )
        }

        return MilestoneDefinition(name: name, description: description, format: format, patterns: parsedPatterns)
    }

    /// Parse "key: value" from a trimmed line, handling quoted strings
    private static func parseKeyValue(_ line: String) -> (String, String)? {
        guard let colonRange = line.range(of: ":") else { return nil }
        let key = String(line[line.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        var val = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        // Strip surrounding quotes
        if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
            val = String(val.dropFirst().dropLast())
        }

        if key.isEmpty { return nil }
        return (key, val)
    }

    // MARK: - Validation

    /// Validate a milestone definition, returning a list of warnings/errors
    public static func validate(_ def: MilestoneDefinition) -> [String] {
        var issues: [String] = []

        if def.name.isEmpty {
            issues.append("error: name is empty")
        }

        if def.patterns.isEmpty {
            issues.append("warning: no patterns defined")
        }

        var seenTypes = Set<String>()
        for (i, pattern) in def.patterns.enumerated() {
            if pattern.type.isEmpty {
                issues.append("error: pattern[\(i)] has empty type")
            }
            if seenTypes.contains(pattern.type) {
                issues.append("warning: duplicate pattern type '\(pattern.type)'")
            }
            seenTypes.insert(pattern.type)

            // Validate match has at least one criterion
            let m = pattern.match
            if m.jsonPath == nil && m.regex == nil && m.anyText == nil && m.exitCode == nil && m.value == nil {
                issues.append("error: pattern[\(i)] '\(pattern.type)' has no match criteria")
            }

            // Validate regex compiles
            if let regex = m.regex {
                do {
                    _ = try NSRegularExpression(pattern: regex)
                } catch {
                    issues.append("error: pattern[\(i)] '\(pattern.type)' has invalid regex: \(regex)")
                }
            }

            if pattern.message == nil && pattern.messageTemplate == nil {
                issues.append("warning: pattern[\(i)] '\(pattern.type)' has no message or message_template")
            }
        }

        return issues
    }
}

// MARK: - JSON-based parsing (alternative to YAML)

extension MilestoneDefinition {
    /// Parse from JSON data
    public static func fromJSON(_ data: Data) throws -> MilestoneDefinition {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MilestoneDefinition.self, from: data)
    }
}
