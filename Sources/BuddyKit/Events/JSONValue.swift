import Foundation

/// Minimal Sendable JSON tree used for hook payload fields whose shape varies per tool.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Maximum nesting depth accepted when decoding, measured by `codingPath.count`
    /// (so keys above the value, such as `tool_input`, count towards it). Deeper input throws
    /// before any further recursion, which bounds parse time and stack use.
    public static let maxDecodingDepth = 32

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= Self.maxDecodingDepth else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "JSON nesting deeper than \(Self.maxDecodingDepth) levels"))
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if var array = try? decoder.unkeyedContainer() {
            // No `try?` around recursive decoding: a depth error must propagate, not be retried.
            var items: [JSONValue] = []
            while !array.isAtEnd {
                items.append(try array.decode(JSONValue.self))
            }
            self = .array(items)
        } else if let keyed = try? decoder.container(keyedBy: DynamicKey.self) {
            var members: [String: JSONValue] = [:]
            for key in keyed.allKeys {
                members[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
            }
            self = .object(members)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
