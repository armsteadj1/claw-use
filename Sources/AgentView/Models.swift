import Foundation

// MARK: - AnyCodable

/// Type-erased Codable wrapper for mixed AX values
struct AnyCodable: Codable {
    let value: Any?

    init(_ value: Any?) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict
        } else {
            value = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case nil:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let int as Int32:
            try container.encode(Int(int))
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [AnyCodable]:
            try container.encode(array)
        case let dict as [String: AnyCodable]:
            try container.encode(dict)
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Raw Layer

/// Raw AX tree node — direct representation of what the Accessibility API returns
struct RawAXNode: Codable {
    let role: String?
    let roleDescription: String?
    let title: String?
    let value: AnyCodable?
    let axDescription: String?
    let identifier: String?
    let placeholder: String?
    let position: Position?
    let size: Size?
    let enabled: Bool?
    let focused: Bool?
    let selected: Bool?
    let url: String?
    let actions: [String]
    let children: [RawAXNode]
    let childCount: Int
    let domId: String?
    let domClasses: [String]?
    let tempId: String?

    enum CodingKeys: String, CodingKey {
        case role, roleDescription, title, value, axDescription, identifier, placeholder
        case position, size, enabled, focused, selected, url, actions, children, childCount
        case domId, domClasses
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        roleDescription = try c.decodeIfPresent(String.self, forKey: .roleDescription)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        value = try c.decodeIfPresent(AnyCodable.self, forKey: .value)
        axDescription = try c.decodeIfPresent(String.self, forKey: .axDescription)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        position = try c.decodeIfPresent(Position.self, forKey: .position)
        size = try c.decodeIfPresent(Size.self, forKey: .size)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused)
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        actions = try c.decodeIfPresent([String].self, forKey: .actions) ?? []
        children = try c.decodeIfPresent([RawAXNode].self, forKey: .children) ?? []
        childCount = try c.decodeIfPresent(Int.self, forKey: .childCount) ?? 0
        domId = try c.decodeIfPresent(String.self, forKey: .domId)
        domClasses = try c.decodeIfPresent([String].self, forKey: .domClasses)
        tempId = nil
    }

    init(role: String?, roleDescription: String?, title: String?, value: AnyCodable?,
         axDescription: String?, identifier: String?, placeholder: String?,
         position: Position?, size: Size?, enabled: Bool?, focused: Bool?,
         selected: Bool?, url: String?, actions: [String], children: [RawAXNode],
         childCount: Int, domId: String?, domClasses: [String]?, tempId: String? = nil) {
        self.role = role; self.roleDescription = roleDescription; self.title = title
        self.value = value; self.axDescription = axDescription; self.identifier = identifier
        self.placeholder = placeholder; self.position = position; self.size = size
        self.enabled = enabled; self.focused = focused; self.selected = selected
        self.url = url; self.actions = actions; self.children = children
        self.childCount = childCount; self.domId = domId; self.domClasses = domClasses
        self.tempId = tempId
    }

    struct Position: Codable {
        let x: Double
        let y: Double
    }

    struct Size: Codable {
        let width: Double
        let height: Double
    }
}

// MARK: - Enriched Layer

/// Enriched snapshot — what the agent actually sees
struct AppSnapshot: Codable {
    let app: String
    let bundleId: String?
    let pid: Int32
    let timestamp: String
    let window: WindowInfo
    let meta: [String: AnyCodable]
    let content: ContentTree
    let actions: [InferredAction]
    let stats: SnapshotStats
}

struct WindowInfo: Codable {
    let title: String?
    let size: RawAXNode.Size?
    let focused: Bool
}

struct ContentTree: Codable {
    let summary: String?
    let sections: [Section]
}

struct Section: Codable {
    let role: String
    let label: String?
    let elements: [Element]
}

struct Element: Codable {
    let ref: String
    let role: String
    let label: String?
    let value: AnyCodable?
    let placeholder: String?
    let enabled: Bool
    let focused: Bool
    let selected: Bool
    let actions: [String]
}

struct InferredAction: Codable {
    let name: String
    let description: String
    let ref: String?
    let requires: [String]?
    let options: [ActionOption]?
}

struct ActionOption: Codable {
    let label: String
    let ref: String
}

struct SnapshotStats: Codable {
    let totalNodes: Int
    let prunedNodes: Int
    let enrichedElements: Int
    let walkTimeMs: Int
    let enrichTimeMs: Int
}

// MARK: - App Listing

struct AppInfo: Codable {
    let name: String
    let pid: Int32
    let bundleId: String?
}

// MARK: - Action Result

struct ActionResultOutput: Codable {
    let success: Bool
    let error: String?
    let snapshot: AppSnapshot?
}

// MARK: - JSON Output

struct JSONOutput {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    static func print<T: Encodable>(_ value: T, pretty: Bool = false) throws {
        let enc = pretty ? prettyEncoder : encoder
        let data = try enc.encode(value)
        Swift.print(String(data: data, encoding: .utf8)!)
    }
}
