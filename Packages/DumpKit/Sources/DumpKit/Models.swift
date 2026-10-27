import Foundation

/// Message kinds that become rows.
public enum LogType: String, CaseIterable {
    case applicationLog = "application_log"
    case caller, carbon, custom
    case eloquentModel = "eloquent_model"
    case event, exception
    case executedQuery = "executed_query"
    case jobEvent = "job_event"
    case json
    case jsonString = "json_string"
    case log, mailable, measure, response, separator, table, trace, view, lock, grouped
    case customHtml = "ai_custom_html"
    case customMarkdown = "ai_custom_markdown"
    case customMermaid = "ai_custom_mermaid"
}

/// Payload kinds that change state instead of adding a row.
public enum ActionType: String, CaseIterable {
    case remove, hide
    case clearAll = "clear_all"
    case newScreen = "new_screen"
    case color, label, size, notify
    case createLock = "create_lock"
    case showApp = "show_app"
    case hideApp = "hide_app"
    case screenColor = "screen_color"
    case confetti, expand
}

public struct Origin: Hashable {
    public var file: String?
    public var line: Int?
    public var hostname: String?
    public var functionName: String?

    public init(file: String? = nil, line: Int? = nil, hostname: String? = nil, functionName: String? = nil) {
        self.file = file
        self.line = line
        self.hostname = hostname
        self.functionName = functionName
    }

    init(json: JSONValue?) {
        file = json?["file"]?.string
        line = json?["line_number"]?.int
        hostname = json?["hostname"]?.string
        functionName = json?["function_name"]?.string
    }

    var json: JSONValue {
        var o = JSONObject()
        if let file { o["file"] = .string(file) }
        if let line { o["line_number"] = .number(Double(line)) }
        if let hostname { o["hostname"] = .string(hostname) }
        if let functionName { o["function_name"] = .string(functionName) }
        return .object(o)
    }
}

public enum LockStatus: String {
    case active, continued, stopped
}

/// One row on screen. Every payload in a request becomes its own entry; they share `groupUuid`
/// (the request uuid), which is what later actions such as `color` or `remove` target.
public struct DumpEntry: Identifiable, Hashable {
    public var id: UUID
    public var groupUuid: String
    public var type: String
    public var content: JSONValue
    public var origin: Origin
    public var createdAt: Date
    public var projectName: String?
    public var color: String?
    public var size: String?
    public var label: String?
    public var collapsed: Bool
    /// Raw `expand` action content (`level` and/or `keys`) for var-dump trees.
    public var expand: JSONValue?

    public init(id: UUID = UUID(), groupUuid: String, type: String, content: JSONValue, origin: Origin = Origin(),
                createdAt: Date = Date(), projectName: String? = nil, color: String? = nil, size: String? = nil,
                label: String? = nil, collapsed: Bool = false, expand: JSONValue? = nil) {
        self.id = id
        self.groupUuid = groupUuid
        self.type = type
        self.content = content
        self.origin = origin
        self.createdAt = createdAt
        self.projectName = projectName
        self.color = color
        self.size = size
        self.label = label
        self.collapsed = collapsed
        self.expand = expand
    }

    public var logType: LogType? { LogType(rawValue: type) }

    /// Lock name for `create_lock` rows.
    public var lockName: String? { type == LogType.lock.rawValue ? content["name"]?.string : nil }

    /// Key used to fold consecutive identical messages together.
    public var groupingKey: String {
        "\(type)|\(content.serialized())|\(origin.file ?? ""):\(origin.line ?? 0)|\(color ?? "")|\(label ?? "")"
    }
}

public struct DumpScreen: Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var entries: [DumpEntry]

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), entries: [DumpEntry] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.entries = entries
    }
}

// MARK: - Persistence as JSON

extension DumpEntry {
    var json: JSONValue {
        var o = JSONObject()
        o["id"] = .string(id.uuidString)
        o["group_uuid"] = .string(groupUuid)
        o["type"] = .string(type)
        o["content"] = content
        o["origin"] = origin.json
        o["created_at"] = .number(createdAt.timeIntervalSince1970)
        if let projectName { o["project_name"] = .string(projectName) }
        if let color { o["color"] = .string(color) }
        if let size { o["size"] = .string(size) }
        if let label { o["label"] = .string(label) }
        o["collapsed"] = .bool(collapsed)
        if let expand { o["expand"] = expand }
        return .object(o)
    }

    init?(json: JSONValue) {
        guard let type = json["type"]?.string, let group = json["group_uuid"]?.string else { return nil }
        self.init(
            id: json["id"]?.string.flatMap(UUID.init(uuidString:)) ?? UUID(),
            groupUuid: group,
            type: type,
            content: json["content"] ?? .null,
            origin: Origin(json: json["origin"]),
            createdAt: Date(timeIntervalSince1970: json["created_at"]?.double ?? Date().timeIntervalSince1970),
            projectName: json["project_name"]?.string,
            color: json["color"]?.string,
            size: json["size"]?.string,
            label: json["label"]?.string,
            collapsed: json["collapsed"]?.bool ?? false,
            expand: json["expand"]
        )
    }
}

extension DumpScreen {
    var json: JSONValue {
        [
            "id": .string(id.uuidString),
            "name": .string(name),
            "created_at": .number(createdAt.timeIntervalSince1970),
            "entries": .array(entries.map(\.json)),
        ]
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.string else { return nil }
        self.init(
            id: json["id"]?.string.flatMap(UUID.init(uuidString:)) ?? UUID(),
            name: name,
            createdAt: Date(timeIntervalSince1970: json["created_at"]?.double ?? 0),
            entries: (json["entries"]?.array ?? []).compactMap(DumpEntry.init(json:))
        )
    }
}
