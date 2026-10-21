import Foundation

/// How a value was quoted in the source `.env`, so saving writes it back the same way.
nonisolated enum EnvQuoteStyle: String, Hashable, Codable {
    case none
    case double
    case single
}

nonisolated struct EnvVariable: Identifiable, Hashable {
    let id: UUID
    var key: String
    var value: String
    /// Original quoting — preserved on save so `KEY="value"` doesn't become `KEY=value`.
    var quote: EnvQuoteStyle
    /// UI-only — whether the value is shown in clear text for sensitive keys.
    var isRevealed: Bool

    init(id: UUID = UUID(), key: String, value: String, quote: EnvQuoteStyle = .none, isRevealed: Bool = false) {
        self.id = id
        self.key = key
        self.value = value
        self.quote = quote
        self.isRevealed = isRevealed
    }
}

/// Parses/serializes `.env` files as an ordered list of key/value pairs for the table editor.
///
/// Comments and blank-line formatting are not round-tripped — saving from the table rewrites the
/// file as plain `KEY=VALUE` pairs. Quoting is preserved per value.
nonisolated enum EnvFileCodec {
    static let sensitiveKeyMarkers = ["PASSWORD", "SECRET", "KEY", "TOKEN"]

    static func isSensitive(_ key: String) -> Bool {
        sensitiveKeyMarkers.contains { key.uppercased().contains($0) }
    }

    static func parse(_ contents: String) -> [EnvVariable] {
        var result: [EnvVariable] = []
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let eqIndex = line.firstIndex(of: "=") else { continue }

            var key = String(line[line.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("export ") {
                key = String(key.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard !key.isEmpty else { continue }

            let rawValue = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            let (value, quote) = parseValue(rawValue)
            result.append(EnvVariable(key: key, value: value, quote: quote))
        }
        return result
    }

    /// Splits a raw value into its content and quoting. A quoted value ends at its closing quote,
    /// so a trailing `# comment` is ignored; an unquoted value drops a ` #comment` suffix.
    private static func parseValue(_ raw: String) -> (String, EnvQuoteStyle) {
        if let first = raw.first, first == "\"" || first == "'" {
            let body = raw.dropFirst()
            var index = body.startIndex
            while index < body.endIndex {
                let char = body[index]
                if first == "\"", char == "\\" {
                    // Skip escaped character (e.g. \" inside a double-quoted value).
                    index = body.index(after: index)
                    if index < body.endIndex { index = body.index(after: index) }
                    continue
                }
                if char == first {
                    return (String(body[body.startIndex..<index]), first == "\"" ? .double : .single)
                }
                index = body.index(after: index)
            }
            // No closing quote — keep the text as written.
            return (raw, .none)
        }

        if let range = raw.range(of: " #") ?? raw.range(of: "\t#") {
            return (String(raw[raw.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces), .none)
        }
        return (raw, .none)
    }

    static func serialize(_ variables: [EnvVariable]) -> String {
        let lines = variables.map { "\($0.key)=\(serializedValue($0))" }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func serializedValue(_ variable: EnvVariable) -> String {
        let value = variable.value
        switch variable.quote {
        case .double:
            return "\"\(value)\""
        case .single:
            return "'\(value)'"
        case .none:
            let needsQuotes = value.isEmpty
                || value.contains(where: \.isWhitespace)
                || value.contains("#")
            guard needsQuotes, !value.contains("\"") else { return value }
            return "\"\(value)\""
        }
    }
}
