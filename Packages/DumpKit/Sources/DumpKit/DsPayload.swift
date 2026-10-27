import Foundation

/// Accepts the `ds()` wire format and maps it onto the same store.
///
/// A ds() request is one payload: `{id, type, <type>: {...}, ide_handle, to_screen, with_label, application_path, ...}`.
/// Chained calls (`ds($x)->red()->label('a')->s('users')`) reuse the same `id`, which plays the role of the request uuid.
extension DumpStore {
    /// Row type for ds() multi-column tables (`dsTable`, `ds()->table()`).
    public static let dsTableType = "ds_table"

    public func ingestDsPayload(_ payload: JSONValue) {
        guard !isPaused else { return }
        let id = payload["id"]?.string ?? UUID().uuidString
        let type = payload["type"]?.string ?? "dump"
        let body = payload[type] ?? .null
        let origin = Self.dsOrigin(payload["ide_handle"])
        let project = payload["application_path"]?.string
            .flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent }
        let label = payload["with_label"]?["label"]?.string.flatMap { $0.isEmpty || $0 == "dump" ? nil : $0 }

        func add(_ entryType: String, _ content: JSONValue, label: String? = label) {
            var entry = DumpEntry(groupUuid: id, type: entryType, content: content, origin: origin, projectName: project)
            entry.label = label
            append(entry)
        }

        switch type {
        case "dump":
            // The client sends "arg0", "arg1"… when it can't read the variable name from source.
            let name = body["variable_name"]?.string.flatMap { $0.isEmpty || $0.range(of: #"^arg\d+$"#, options: .regularExpression) != nil ? nil : $0 }
            add(LogType.log.rawValue, ["values": .array([Self.dumpValue(body["dump"])])], label: label ?? name)

        case "dump_group":
            for item in body["items"]?.array ?? [] {
                add(LogType.log.rawValue, ["values": .array([Self.dumpValue(item["dump"])])], label: item["name"]?.string)
            }

        case "table_v2":
            // values: {key: [html, sf-dump-id]}
            var values = JSONObject()
            for (key, value) in body["values"]?.object?.pairs ?? [] { values[key] = Self.dumpValue(value) }
            add(LogType.table.rawValue, ["values": .object(values), "label": .string(label ?? "Table")])

        case "table":
            add(Self.dsTableType, body, label: body["label"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? label)

        case "json":
            add(LogType.jsonString.rawValue, ["value": body["string"] ?? .null])

        case "time_track":
            let reference = payload["with_label"]?["label"]?.string ?? "default"
            let time = body["time"]?.double ?? Date().timeIntervalSince1970
            if body["end_time"] != nil, let start = dsTimers.removeValue(forKey: reference) {
                let ms = ((body["end_time"]?.double ?? time) - start) * 1000
                add(LogType.custom.rawValue, ["content": .string(String(format: "%@: %.2f ms", reference, ms)), "label": "Time"], label: nil)
            } else {
                dsTimers[reference] = time
                add(LogType.custom.rawValue, ["content": .string("\(reference): started"), "label": "Time"], label: nil)
            }

        case "validate":
            validate(groupUuid: id, rule: body, origin: origin, project: project)

        case "json_validate":
            let target = currentScreen.entries.last { $0.groupUuid == id }
            let text = target.map(\.copyText) ?? ""
            let ok = (try? JSONValue.parse(text)) != nil
            add(LogType.custom.rawValue, ["content": .string(ok ? "✓ Valid JSON" : "✗ Invalid JSON"), "label": "Validate"], label: nil)

        case "color":
            let color = Self.dsColor(body["color"]?.string)
            modify(id) { $0.color = color }

        case "label":
            let text = payload["with_label"]?["label"]?.string
            modify(id) { $0.label = text }

        case "screen":
            let name = payload["to_screen"]?["screen_name"]?.string ?? "home"
            moveGroup(id, toScreenNamed: name)

        case "clear":
            clearCurrentScreen()

        default:
            add(type, body)
        }
        onChange()
    }

    /// `Dumper::dump` returns `[html, id]` for objects/arrays and plain scalars otherwise.
    static func dumpValue(_ value: JSONValue?) -> JSONValue {
        guard let value else { return .null }
        if let pair = value.array, let first = pair.first { return first }
        return value
    }

    static func dsOrigin(_ handle: JSONValue?) -> Origin {
        guard let handle else { return Origin() }
        var path = handle["real_path"]?.string ?? ""
        let sep = handle["separator"]?.string ?? "/"
        if !path.isEmpty, !path.hasPrefix(sep) {
            // real_path is relative to the app base path; join with the configured project path when there is one.
            let base = handle["project_path"]?.string ?? handle["workdir"]?.string ?? ""
            if !base.isEmpty { path = base.hasSuffix(sep) ? base + path : base + sep + path }
        }
        return Origin(file: path.isEmpty || path == "empty" ? nil : path, line: handle["line"]?.int, hostname: nil)
    }

    /// ds() colors: red, orange, green, blue, black (`danger`, `warning`, `success`, `info`, `dark`).
    static func dsColor(_ name: String?) -> String? {
        switch name?.lowercased().replacingOccurrences(of: "border-", with: "") {
        case "red", "danger": return "red"
        case "orange", "warning", "yellow": return "orange"
        case "green", "success": return "green"
        case "blue", "info": return "blue"
        case "black", "dark", "gray", "grey": return "gray"
        case "purple": return "purple"
        default: return name
        }
    }

    private func validate(groupUuid: String, rule: JSONValue, origin: Origin, project: String?) {
        let needle = rule["content"]?.string ?? ""
        let caseSensitive = rule["is_case_sensitive"]?.bool ?? false
        let wholeWord = rule["is_whole_word"]?.bool ?? false
        let haystack = currentScreen.entries.last { $0.groupUuid == groupUuid }?.copyText ?? ""
        var options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var pattern = NSRegularExpression.escapedPattern(for: needle)
        if wholeWord { pattern = "\\b\(pattern)\\b"; options.insert(.regularExpression) } else { pattern = needle }
        let found = !needle.isEmpty && haystack.range(of: pattern, options: options) != nil
        let text = found ? "✓ Contains “\(needle)”" : "✗ Does not contain “\(needle)”"
        append(DumpEntry(groupUuid: groupUuid, type: LogType.custom.rawValue,
                        content: ["content": .string(text), "label": "Validate"], origin: origin, projectName: project))
    }
}
