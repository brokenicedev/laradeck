import AppKit
import MockAPIKit
import SwiftUI

/// Colored HTTP method label, e.g. GET in blue.
struct MethodBadge: View {
    let method: String
    var compact = false

    var body: some View {
        Text(method)
            .font((compact ? Font.caption2 : Font.caption).weight(.bold).monospaced())
            .foregroundStyle(Self.color(for: method))
            .frame(minWidth: compact ? 38 : 50, alignment: .leading)
    }

    static func color(for method: String) -> Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        case "PUT": return .orange
        case "PATCH": return .yellow
        case "DELETE": return .red
        case "ANY": return .purple
        default: return .secondary
        }
    }
}

/// Status code colored by class: 2xx green, 3xx blue, 4xx orange, 5xx red.
struct StatusBadge: View {
    let status: Int

    var body: some View {
        Text(verbatim: "\(status)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var color: Color {
        switch status {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        default: return .red
        }
    }
}

/// Editable name/value list for response and server headers.
struct HeaderListEditor: View {
    @Binding var headers: [MockHeader]
    var placeholder = "Header"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($headers) { $header in
                HStack(spacing: 6) {
                    TextField(placeholder, text: $header.name)
                        .frame(maxWidth: 220)
                    TextField("Value", text: $header.value)
                    Button {
                        headers.removeAll { $0.id == header.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove header")
                }
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            }
            HStack {
                Button {
                    headers.append(MockHeader(name: "", value: ""))
                } label: {
                    Label("Add Header", systemImage: "plus")
                }
                Menu("Common") {
                    ForEach(Self.common, id: \.0) { name, value in
                        Button("\(name): \(value)") { headers.append(MockHeader(name: name, value: value)) }
                    }
                }
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }

    static let common: [(String, String)] = [
        ("Content-Type", "application/json"),
        ("Content-Type", "text/plain"),
        ("Content-Type", "text/html"),
        ("Cache-Control", "no-store"),
        ("Location", "/"),
        ("Retry-After", "60"),
        ("X-Request-Id", "{{uuid}}"),
    ]
}

/// Rules that pick a response: target, key, operator, value.
struct RuleListEditor: View {
    @Binding var rules: [MockRule]
    @Binding var rulesOperator: RulesOperator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rules.count > 1 {
                Picker("Match", selection: $rulesOperator) {
                    Text("All rules (AND)").tag(RulesOperator.and)
                    Text("Any rule (OR)").tag(RulesOperator.or)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ForEach($rules) { $rule in
                HStack(spacing: 6) {
                    Picker("Target", selection: $rule.target) {
                        ForEach(RuleTarget.allCases, id: \.self) { Text(Self.label($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    if Self.hasKey(rule.target) {
                        TextField(Self.keyPlaceholder(rule.target), text: $rule.key)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                            .frame(maxWidth: 160)
                    }
                    Toggle("Not", isOn: $rule.invert)
                        .toggleStyle(.checkbox)
                        .help("Invert the rule")
                    Picker("Operator", selection: $rule.op) {
                        ForEach(RuleOperator.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    if rule.op != .exists {
                        TextField(rule.op == .regex ? "Pattern" : "Value", text: $rule.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                    } else {
                        Spacer()
                    }
                    Button {
                        rules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove rule")
                }
            }
            Button {
                rules.append(MockRule(target: .query))
            } label: {
                Label("Add Rule", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }

    static func label(_ target: RuleTarget) -> String {
        switch target {
        case .query: return "Query"
        case .header: return "Header"
        case .body: return "Body"
        case .params: return "Route param"
        case .cookie: return "Cookie"
        case .path: return "Path"
        case .method: return "Method"
        }
    }

    static func hasKey(_ target: RuleTarget) -> Bool {
        ![.path, .method].contains(target)
    }

    static func keyPlaceholder(_ target: RuleTarget) -> String {
        switch target {
        case .body: return "user.email (empty = whole)"
        case .params: return "id"
        case .header: return "Authorization"
        default: return "name"
        }
    }
}

/// Monospaced body editor with JSON validation and formatting.
struct BodyEditor: View {
    @Binding var text: String
    let contentType: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 180, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack(spacing: 10) {
                if let status = jsonStatus {
                    Label(status.message, systemImage: status.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(status.ok ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
                Spacer()
                Button("Format JSON") {
                    if let json = try? JSONValue.parse(text) { text = json.serialized(pretty: true) }
                }
                .disabled((try? JSONValue.parse(text)) == nil)
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }

    /// Only shown for JSON bodies. Templates make JSON invalid until rendered, so they're just noted.
    private var jsonStatus: (ok: Bool, message: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isJSONType = contentType?.lowercased().contains("json") ?? false
        guard isJSONType || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        if trimmed.isEmpty { return nil }
        do {
            _ = try JSONValue.parse(trimmed)
            return (true, "Valid JSON")
        } catch {
            if trimmed.contains("{{") { return (true, "JSON with template tags") }
            return (false, "\(error)")
        }
    }
}

/// Quick reference of template tags, shown in a popover.
struct TemplateHelpView: View {
    static let entries: [(String, String)] = [
        ("{{params.id}}", "Route parameter (:id)"),
        ("{{query.page}}", "Query string value"),
        ("{{header.authorization}}", "Request header"),
        ("{{cookie.session}}", "Cookie"),
        ("{{body.user.email}}", "Value from a JSON or form body"),
        ("{{body}}", "The whole request body"),
        ("{{method}} {{path}}", "Request method and path"),
        ("{{uuid}}", "Random UUID"),
        ("{{now}} {{now 'yyyy-MM-dd'}}", "Current date"),
        ("{{timestamp}}", "Unix timestamp"),
        ("{{int 1 100}} {{float 0 10}}", "Random numbers"),
        ("{{bool}} {{pick 'a' 'b'}}", "Random boolean / choice"),
        ("{{faker.name}} {{faker.email}}", "Fake data: firstName, lastName, username, phone, city, country, address, company, word, sentence, paragraph, product, price, url, avatar, image, color, date, datetime, past, future"),
        ("[{{#repeat 3}}{…}{{/repeat}}]", "Repeat a block, comma-separated; {{@index}} inside"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Template tags").font(.headline)
            Text("Rendered when “Templating” is on. Force a response with the x-mock-response-code or x-mock-response-name request header.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Self.entries, id: \.0) { tag, description in
                    GridRow {
                        Text(tag).font(.caption.monospaced()).textSelection(.enabled)
                        Text(description).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}
