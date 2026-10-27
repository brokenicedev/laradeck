import AppKit
import DumpKit
import SwiftUI

/// Picks a view for a message type.
struct DumpPayloadView: View {
    let entry: DumpEntry
    private var c: JSONValue { entry.content }

    var body: some View {
        switch entry.logType {
        case .log:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array((c["values"]?.array ?? []).enumerated()), id: \.offset) { _, value in
                    DumpValueView(value: value, expand: entry.expand)
                }
            }
        case .custom:
            DumpCustomView(content: c["content"] ?? .null, label: c["label"]?.string ?? "")
        case .customHtml:
            DumpHTMLView(html: c["content"]?.displayString ?? c["html"]?.displayString ?? "")
        case .customMarkdown:
            DumpMarkdownView(text: c["content"]?.displayString ?? c["markdown"]?.displayString ?? "")
        case .customMermaid:
            VStack(alignment: .leading, spacing: 4) {
                Text("Mermaid source (diagram rendering not supported)").font(.caption).foregroundStyle(.secondary)
                Text(c["content"]?.displayString ?? c["mermaid"]?.displayString ?? "")
            }
        case .table:
            DumpTableView(values: c["values"] ?? .null, expand: entry.expand)
        case .exception:
            DumpExceptionView(content: c)
        case .executedQuery:
            DumpQueryView(content: c)
        case .jsonString, .json:
            DumpJSONStringView(value: c["value"] ?? .null)
        case .carbon:
            DumpKeyValueGrid(rows: [
                ("Formatted", .string(c["formatted"]?.displayString ?? "")),
                ("Timestamp", .string(c["timestamp"]?.displayString ?? "")),
                ("Timezone", .string(c["timezone"]?.displayString ?? "")),
            ])
        case .measure:
            DumpMeasureView(content: c)
        case .caller:
            if let frame = c["frame"] {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Called from").foregroundStyle(.secondary)
                    DumpFrameRow(frame: frame, highlighted: true)
                }
            }
        case .trace:
            DumpFrameList(frames: c["frames"]?.array ?? [])
        case .lock:
            DumpLockView(entry: entry)
        case .applicationLog:
            VStack(alignment: .leading, spacing: 4) {
                Text(c["value"]?.displayString ?? "")
                if let context = c["context"], !context.isNull, context.serialized() != "[]" {
                    DumpValueView(value: context, expand: entry.expand)
                }
            }
        case .mailable:
            DumpMailView(content: c)
        case .eloquentModel:
            VStack(alignment: .leading, spacing: 6) {
                Text(c["class_name"]?.displayString ?? "Model").bold()
                if let attributes = c["attributes"] { Section("Attributes") { DumpValueView(value: attributes, expand: entry.expand) } }
                if let relations = c["relations"], !relations.isNull { Section("Relations") { DumpValueView(value: relations, expand: entry.expand) } }
            }
        case .event:
            VStack(alignment: .leading, spacing: 6) {
                Text(c["name"]?.displayString ?? "Event").bold()
                if let event = c["event"], !event.isNull { DumpValueView(value: event, expand: entry.expand) }
                if let payload = c["payload"], !payload.isNull, payload.serialized() != "[]" { DumpValueView(value: payload, expand: entry.expand) }
            }
        case .jobEvent:
            VStack(alignment: .leading, spacing: 6) {
                Text(c["event_name"]?.displayString ?? "Job event").bold()
                if let job = c["job"], !job.isNull { DumpValueView(value: job, expand: entry.expand) }
                if let ex = c["exception"], !ex.isNull { DumpValueView(value: ex, expand: entry.expand) }
            }
        case .view:
            VStack(alignment: .leading, spacing: 6) {
                DumpKeyValueGrid(rows: [("Path", c["view_path_relative_to_project_root"] ?? c["view_path"] ?? .null)])
                if let data = c["data"] { Section("Data") { DumpValueView(value: data, expand: entry.expand) } }
            }
        case .response:
            DumpResponseView(content: c)
        case .separator, .grouped, .none:
            if entry.type == DumpStore.dsTableType {
                DumpRowsTableView(content: c)
            } else if entry.logType == nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unknown payload type “\(entry.type)”").font(.caption).foregroundStyle(.secondary)
                    DumpJSONTreeView(value: c)
                }
            }
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

/// A value from a client: plain JSON scalar, var-dump HTML, or anything else.
struct DumpValueView: View {
    let value: JSONValue
    var expand: JSONValue?

    var body: some View {
        switch value {
        case .string(let s) where SfDump.isDump(s):
            VarDumpView(html: s, expand: expand)
        case .string(let s) where s.contains("<") && s.contains(">") && s.range(of: "</?[a-zA-Z][^>]*>", options: .regularExpression) != nil:
            DumpHTMLView(html: s)
        case .string(let s):
            Text(s)
        case .null:
            Text("null").foregroundStyle(DumpPalette.const)
        case .bool(let b):
            Text(b ? "true" : "false").foregroundStyle(DumpPalette.const)
        case .number:
            Text(value.displayString).foregroundStyle(DumpPalette.num)
        case .array, .object:
            DumpJSONTreeView(value: value)
        }
    }
}

struct DumpCustomView: View {
    let content: JSONValue
    let label: String

    var body: some View {
        switch label {
        case "Image":
            DumpImageView(html: content.displayString)
        case "JSON":
            DumpJSONStringView(value: content)
        default:
            DumpValueView(value: content)
        }
    }
}

struct DumpImageView: View {
    let html: String

    private var image: NSImage? {
        guard let s = Self.imageSource(html) else { return nil }
        if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") {
            let meta = s[..<comma]
            let payload = String(s[s.index(after: comma)...])
            let data = meta.contains(";base64") ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters) : payload.removingPercentEncoding.map { Data($0.utf8) }
            return data.flatMap(NSImage.init(data:))
        }
        if let url = URL(string: s), url.isFileURL { return NSImage(contentsOf: url) }
        if s.hasPrefix("/") { return NSImage(contentsOfFile: s) }
        return nil
    }

    private var remoteURL: URL? {
        guard let src = Self.imageSource(html), let url = URL(string: src),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    static func imageSource(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "src=[\"']([^\"']+)[\"']"),
              let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        return HTMLText.decodeEntities(String(html[r]))
    }

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: min(image.size.width, 600), alignment: .leading)
        } else if let url = remoteURL {
            AsyncImage(url: url) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
                .frame(maxWidth: 600, maxHeight: 400, alignment: .leading)
        } else {
            DumpHTMLView(html: html)
        }
    }
}

struct DumpKeyValueGrid: View {
    let rows: [(String, JSONValue)]
    var expand: JSONValue?

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(DumpPalette.key)
                    DumpValueView(value: row.1, expand: expand)
                }
                Divider().gridCellColumns(2).opacity(0.4)
            }
        }
    }
}

struct DumpTableView: View {
    let values: JSONValue
    var expand: JSONValue?

    var body: some View {
        switch values {
        case .object(let o):
            DumpKeyValueGrid(rows: o.pairs.map { ($0.key, $0.value) }, expand: expand)
        case .array(let a):
            DumpKeyValueGrid(rows: a.enumerated().map { (String($0.offset), $0.element) }, expand: expand)
        default:
            DumpValueView(value: values, expand: expand)
        }
    }
}

/// ds() table: `{fields: [...], values: [{field: value}], header, label}`.
struct DumpRowsTableView: View {
    let content: JSONValue

    var body: some View {
        let fields = (content["fields"]?.array ?? []).map(\.displayString)
        let rows = content["values"]?.array ?? []
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    ForEach(fields, id: \.self) { Text($0).bold().foregroundStyle(DumpPalette.key) }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(fields, id: \.self) { f in
                            Text(row[f]?.displayString ?? "").lineLimit(3)
                        }
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }
}

struct DumpQueryView: View {
    let content: JSONValue

    var body: some View {
        let sql = SQL.interpolate(content["sql"]?.string ?? "", bindings: content["bindings"]?.array ?? [])
        VStack(alignment: .leading, spacing: 6) {
            Text(DumpSQLHighlighter.highlight(sql))
            HStack(spacing: 16) {
                if let conn = content["connection_name"]?.displayString {
                    Label(conn, systemImage: "cylinder").help("Connection name")
                }
                if let time = content["time"]?.double {
                    Label(String(format: "%.2f ms", time), systemImage: "clock").help("Duration")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

enum DumpSQLHighlighter {
    static let keywords: Set<String> = ["select", "from", "where", "and", "or", "insert", "into", "values", "update", "set",
        "delete", "join", "left", "right", "inner", "outer", "on", "order", "by", "group", "having", "limit", "offset",
        "as", "in", "is", "not", "null", "like", "distinct", "count", "exists", "union", "all", "asc", "desc", "between", "case", "when", "then", "else", "end"]

    static func highlight(_ sql: String) -> AttributedString {
        var out = AttributedString()
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            var part = AttributedString(word)
            if keywords.contains(word.lowercased()) { part.foregroundColor = DumpPalette.const; part.font = .system(.body, design: .monospaced).bold() }
            else if word.first == "'" || word.first == "\"" { part.foregroundColor = DumpPalette.str }
            else if Double(word) != nil { part.foregroundColor = DumpPalette.num }
            out += part
            word = ""
        }
        var quote: Character?
        for ch in sql {
            if let q = quote {
                word.append(ch)
                if ch == q { quote = nil; flush() }
                continue
            }
            if ch == "'" || ch == "\"" { flush(); quote = ch; word.append(ch); continue }
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "." { word.append(ch) } else { flush(); out += AttributedString(String(ch)) }
        }
        flush()
        return out
    }
}

struct DumpMeasureView: View {
    let content: JSONValue

    var body: some View {
        if content["is_new_timer"]?.bool == true {
            Text("Start measuring performance...")
        } else {
            DumpKeyValueGrid(rows: [
                ("Total time", .string(ms(content["total_time"]))),
                ("Maximum memory usage during total time", .string(bytes(content["max_memory_usage_during_total_time"]))),
                ("Time since last call", .string(ms(content["time_since_last_call"]))),
                ("Maximum memory usage since last call", .string(bytes(content["max_memory_usage_since_last_call"]))),
            ])
        }
    }

    private func ms(_ v: JSONValue?) -> String { v?.double.map { String(format: "%.2f ms", $0) } ?? "-" }
    private func bytes(_ v: JSONValue?) -> String {
        guard let b = v?.double else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }
}

struct DumpMailView: View {
    let content: JSONValue

    private func people(_ key: String) -> String {
        (content[key]?.array ?? []).map { p in
            let name = p["name"]?.string ?? ""
            let email = p["email"]?.string ?? ""
            return name.isEmpty ? email : "\(name) <\(email)>"
        }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DumpKeyValueGrid(rows: [
                ("From", .string(people("from"))),
                ("To", .string(people("to"))),
                ("Subject", content["subject"] ?? .null),
                ("Mailable class", content["mailable_class"] ?? .null),
            ])
            DumpHTMLView(html: content["html"]?.displayString ?? "")
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                .environment(\.colorScheme, .light)
        }
    }
}

struct DumpResponseView: View {
    let content: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DumpKeyValueGrid(rows: [("Status code", content["status_code"] ?? .null)])
            if let headers = content["headers"], !headers.isNull {
                DisclosureGroup("Headers") { DumpJSONTreeView(value: headers) }
            }
            if let json = content["json"], !json.isNull {
                DumpJSONTreeView(value: json)
            } else if let body = content["content"] {
                DumpValueView(value: body)
            }
        }
    }
}

struct DumpLockView: View {
    @Environment(DumpSession.self) private var session
    let entry: DumpEntry

    var body: some View {
        let name = entry.lockName ?? ""
        let status = session.store.locks[name] ?? .continued
        HStack(spacing: 10) {
            switch status {
            case .active:
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                Text("Execution is paused")
                Spacer()
                Button("Continue") { session.store.resolveLock(name, stop: false) }
                    .keyboardShortcut(.defaultAction)
                Button("Stop execution", role: .destructive) { session.store.resolveLock(name, stop: true) }
            case .continued:
                Image(systemName: "play.circle").foregroundStyle(.green)
                Text("Execution continued").foregroundStyle(.secondary)
            case .stopped:
                Image(systemName: "stop.circle").foregroundStyle(.red)
                Text("Execution stopped").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
    }
}
