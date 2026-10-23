import Foundation

/// A short, bounded, human-readable description of a tool call, safe to show in a UI or push
/// notification no matter how large the underlying `tool_input` is.
public struct ToolSummary: Sendable, Equatable {
    public static let defaultMaxLength = 200

    public let text: String
    public let isTruncated: Bool

    public init(text: String, isTruncated: Bool) {
        self.text = text
        self.isTruncated = isTruncated
    }

    /// The marker put before a Bash command that asks to run outside the sandbox
    /// (`dangerouslyDisableSandbox: true`), so whoever allows it sees that.
    public static let sandboxOffMarker = "[sandbox off] "

    /// Bash shows its `command` (with `sandboxOffMarker` first when it asks to leave the sandbox);
    /// Read/Edit/Write/MultiEdit show `file_path` and NotebookEdit `notebook_path`. Any other tool, or one
    /// of those without its field, shows every input field as `key: value` lines (keys sorted, strings as
    /// they are, other values as compact JSON), so nothing the request carries is hidden from the person
    /// allowing it. No input at all shows the tool name. Text longer than `maxLength` characters is cut
    /// to exactly `maxLength` characters ending in `…` and flagged `isTruncated` (which turns Allow off).
    /// Only about `maxLength + 1` characters of output are ever built, so cost does not grow with the
    /// size of the input.
    public static func make(
        toolName: String,
        toolInput: JSONValue?,
        maxLength: Int = defaultMaxLength
    ) -> ToolSummary {
        let limit = max(maxLength, 0)
        let members: [String: JSONValue]
        switch toolInput {
        case .object(let value)?: members = value
        case nil, .null?: members = [:]
        case let other?:
            var writer = BoundedWriter(limit: limit)
            writer.appendJSON(other)
            return bounded(writer.text, maxLength: limit)
        }
        if let primary = primaryText(toolName: toolName, members: members, limit: limit) {
            return bounded(primary, maxLength: limit)
        }
        guard !members.isEmpty else { return bounded(toolName, maxLength: limit) }
        var writer = BoundedWriter(limit: limit)
        for (index, key) in members.keys.sorted().enumerated() {
            if index > 0 { writer.append("\n") }
            writer.append(key)
            writer.append(": ")
            if case .string(let value)? = members[key] {
                writer.append(value)
            } else if let value = members[key] {
                writer.appendJSON(value)
            }
            if writer.isFull { break }
        }
        return bounded(writer.text, maxLength: limit)
    }

    /// The one field that says what a well-known tool does, or nil when the tool is not one of those or
    /// the field is missing.
    private static func primaryText(toolName: String, members: [String: JSONValue], limit: Int) -> String? {
        let key: String
        switch toolName {
        case "Bash": key = "command"
        case "Read", "Edit", "Write", "MultiEdit": key = "file_path"
        case "NotebookEdit": key = "notebook_path"
        default: return nil
        }
        guard case .string(let value)? = members[key] else { return nil }
        if toolName == "Bash", case .bool(true)? = members["dangerouslyDisableSandbox"] {
            return sandboxOffMarker + value.prefix(limit + 1)
        }
        return value
    }

    /// Builds text from pieces and stops growing once it holds more than `limit` characters, so a huge
    /// input never costs more than its first few hundred characters.
    private struct BoundedWriter {
        let limit: Int
        private(set) var text = ""

        init(limit: Int) { self.limit = limit }

        var isFull: Bool { text.count > limit }

        mutating func append(_ piece: some StringProtocol) {
            guard !isFull else { return }
            text += piece.prefix(limit + 1)
        }

        /// Compact JSON with sorted keys.
        mutating func appendJSON(_ value: JSONValue) {
            guard !isFull else { return }
            switch value {
            case .null: append("null")
            case .bool(let flag): append(flag ? "true" : "false")
            case .number(let number):
                if number.rounded() == number, abs(number) < 1e15 {
                    append(String(Int64(number)))
                } else {
                    append(String(number))
                }
            case .string(let string):
                append("\"")
                append(string)
                append("\"")
            case .array(let items):
                append("[")
                for (index, item) in items.enumerated() {
                    if isFull { return }
                    if index > 0 { append(",") }
                    appendJSON(item)
                }
                append("]")
            case .object(let members):
                append("{")
                for (index, key) in members.keys.sorted().enumerated() {
                    if isFull { return }
                    if index > 0 { append(",") }
                    append("\"")
                    append(key)
                    append("\":")
                    if let member = members[key] { appendJSON(member) }
                }
                append("}")
            }
        }
    }

    private static func bounded(_ source: String, maxLength: Int) -> ToolSummary {
        let limit = max(maxLength, 0)
        let head = source.prefix(limit + 1)
        guard head.count > limit else {
            return ToolSummary(text: String(head), isTruncated: false)
        }
        guard limit > 0 else { return ToolSummary(text: "", isTruncated: true) }
        return ToolSummary(text: String(head.prefix(limit - 1)) + "…", isTruncated: true)
    }
}
