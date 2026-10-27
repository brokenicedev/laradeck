import Foundation

extension DumpEntry {
    /// Lowercased text used by the search box. Indexes the relevant fields per type.
    public var searchText: String {
        let c = content
        var typeField: String
        switch logType {
        case .log:
            typeField = (c["values"]?.array ?? []).map { HTMLText.stripTags($0.displayString) }.joined(separator: " ")
        case .custom, .customHtml, .customMarkdown, .customMermaid:
            typeField = HTMLText.stripTags(c["content"]?.displayString ?? c.displayString)
        case .view:
            typeField = "\(c["view_path"]?.displayString ?? "") \(HTMLText.stripTags(c["data"]?.displayString ?? ""))"
        case .table:
            typeField = HTMLText.stripTags(c["values"]?.serialized() ?? "")
        case .json, .jsonString, .applicationLog:
            typeField = c["value"]?.displayString ?? ""
        case .carbon:
            typeField = c["formatted"]?.displayString ?? ""
        case .executedQuery:
            typeField = "\(c["sql"]?.displayString ?? "") \(c["connection_name"]?.displayString ?? "")"
        case .caller:
            let f = c["frame"]
            typeField = "Called from \(f?["class"]?.displayString ?? "") \(f?["file_name"]?.displayString ?? "") \(f?["method"]?.displayString ?? "")"
        case .trace:
            typeField = (c["frames"]?.array ?? []).map { $0["method"]?.displayString ?? "" }.joined(separator: " ")
        case .exception:
            typeField = "\(c["class"]?.displayString ?? "") \(c["message"]?.displayString ?? "") \(c["frames"]?.serialized() ?? "")"
        case .response:
            typeField = c["content"]?.displayString ?? c["json"]?.serialized() ?? ""
        case .event:
            typeField = "\(c["name"]?.displayString ?? "") \(HTMLText.stripTags(c["event"]?.displayString ?? ""))"
        case .jobEvent:
            typeField = "\(c["event_name"]?.displayString ?? "") \(HTMLText.stripTags(c["job"]?.displayString ?? ""))"
        case .eloquentModel:
            typeField = "\(c["class_name"]?.displayString ?? "") \(HTMLText.stripTags(c["attributes"]?.displayString ?? ""))"
        case .mailable:
            let to = (c["to"]?.array ?? []).map { $0["name"]?.displayString ?? $0["email"]?.displayString ?? "" }.joined(separator: " ")
            typeField = "\(c["subject"]?.displayString ?? "") \(HTMLText.stripTags(c["html"]?.displayString ?? "")) \(to)"
        case .lock:
            typeField = c["name"]?.displayString ?? ""
        case .measure:
            typeField = c["name"]?.displayString ?? ""
        default:
            typeField = c.serialized()
        }
        return [label ?? "", type, origin.file ?? "", projectName ?? "", typeField]
            .filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }

    /// Text placed on the clipboard by "Copy".
    public var copyText: String {
        switch logType {
        case .log:
            return (content["values"]?.array ?? []).map { HTMLText.stripTags($0.displayString) }.joined(separator: "\n")
        case .custom, .customHtml, .customMarkdown, .customMermaid:
            return HTMLText.stripTags(content["content"]?.displayString ?? "")
        case .executedQuery:
            return SQL.interpolate(content["sql"]?.string ?? "", bindings: content["bindings"]?.array ?? [])
        case .jsonString, .json:
            return content["value"]?.displayString ?? ""
        default:
            return searchText
        }
    }
}

public enum SQL {
    /// Puts bindings in place of `?` placeholders, quoting strings, for display only.
    public static func interpolate(_ sql: String, bindings: [JSONValue]) -> String {
        var out = ""
        var iterator = bindings.makeIterator()
        var inQuote: Character?
        for ch in sql {
            if let q = inQuote {
                if ch == q { inQuote = nil }
                out.append(ch)
                continue
            }
            if ch == "'" || ch == "\"" { inQuote = ch; out.append(ch); continue }
            if ch == "?", let b = iterator.next() {
                switch b {
                case .string(let s): out += "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
                case .null: out += "NULL"
                case .bool(let v): out += v ? "1" : "0"
                default: out += b.displayString
                }
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
