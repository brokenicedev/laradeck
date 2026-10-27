import AppKit
import DumpKit
import SwiftUI

enum DumpPalette {
    static var theme: AppTheme { ThemeStore.shared.theme }

    static var num: Color { theme.dumpNumber }
    static var const: Color { theme.dumpMeta }
    static var str: Color { theme.dumpString }
    static var key: Color { theme.dumpKey }
    static var note: Color { theme.dumpNote }
    static var meta: Color { theme.dumpReference }

    static func color(for style: String?) -> Color? {
        switch style {
        case "num": return theme.dumpNumber
        case "const": return theme.dumpMeta
        case "str": return theme.dumpString
        case "key": return theme.dumpKey
        case "note": return theme.dumpNote
        case "index": return theme.dumpIndex
        case "ref": return theme.dumpReference
        case "meta": return theme.dumpMeta
        case "ellipsis": return theme.dumpEllipsis
        case "public", "protected", "private": return theme.dumpProperty
        default: return theme.dumpText
        }
    }
}

/// Renders Symfony var-dump HTML as native text with clickable ▶/▼ toggles.
struct VarDumpView: View {
    let html: String
    var expand: JSONValue?
    @State private var overrides: [Int: Bool] = [:]
    @State private var nodes: [DumpNode] = []
    @State private var parsedFrom = ""

    var body: some View {
        Text(render())
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DumpPalette.theme.codeBackground, in: RoundedRectangle(cornerRadius: 4))
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "laradeck-dump", let id = Int(url.lastPathComponent) else { return .systemAction }
                overrides[id] = !(isExpanded(id: id) ?? true)
                return .handled
            })
            .onAppear(perform: parseIfNeeded)
            .onChange(of: html) { parseIfNeeded() }
            .onChange(of: expand) { overrides = [:] }
    }

    private func parseIfNeeded() {
        guard parsedFrom != html else { return }
        nodes = SfDump.parse(html)
        parsedFrom = html
    }

    private func isExpanded(id: Int) -> Bool? {
        if let o = overrides[id] { return o }
        return lookup(nodes, id: id)
    }

    private func lookup(_ nodes: [DumpNode], id: Int) -> Bool? {
        for node in nodes {
            if case .block(let bid, let depth, let expanded, let children) = node {
                if bid == id { return defaultExpanded(depth: depth, expanded: expanded) }
                if let r = lookup(children, id: id) { return r }
            }
        }
        return nil
    }

    /// `expand` action: `{level: n}` opens all blocks up to depth n; no content opens one level.
    private func defaultExpanded(depth: Int, expanded: Bool) -> Bool {
        guard let expand else { return expanded }
        if let level = expand["level"]?.int { return depth <= level || expanded }
        if let keys = expand["keys"]?.array, !keys.isEmpty { return true }
        return depth <= 1 || expanded
    }

    private func render() -> AttributedString {
        var out = AttributedString()
        append(nodes.isEmpty ? SfDump.parse(html) : nodes, to: &out)
        // Trim the leading/trailing newlines sf-dump adds inside <pre>.
        while out.characters.last == "\n" { out.characters.removeLast() }
        return out
    }

    private func append(_ nodes: [DumpNode], to out: inout AttributedString) {
        for node in nodes {
            switch node {
            case .text(let text, let style, _):
                var part = AttributedString(text)
                if let color = DumpPalette.color(for: style) { part.foregroundColor = color }
                out += part
            case .block(let id, _, _, let children):
                let open = isExpanded(id: id) ?? true
                var toggle = AttributedString(open ? "▼" : "▶")
                toggle.link = URL(string: "laradeck-dump://toggle/\(id)")
                toggle.foregroundColor = .secondary
                out += toggle
                if open {
                    append(children, to: &out)
                } else {
                    var dots = AttributedString("…")
                    dots.foregroundColor = .secondary
                    out += dots
                }
            }
        }
    }
}

/// Generic HTML through AppKit's importer (scripts removed). Results are cached per string.
struct DumpHTMLView: View {
    let html: String

    @MainActor private static var cache: [String: AttributedString] = [:]

    var body: some View {
        Text(Self.attributed(html))
    }

    @MainActor static func attributed(_ html: String) -> AttributedString {
        if let hit = cache[html] { return hit }
        var cleaned = html
        for tag in ["script", "style"] {
            cleaned = cleaned.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        let wrapped = "<meta charset=utf-8><style>body{font-family:-apple-system,'SF Mono',Menlo;font-size:13px;color:\(cssColor())}</style>" + cleaned
        var result: AttributedString
        if let ns = try? NSAttributedString(data: Data(wrapped.utf8),
                                            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                                            documentAttributes: nil),
           var a = try? AttributedString(ns, including: \.appKit) {
            while a.characters.last == "\n" { a.characters.removeLast() }
            result = a
        } else {
            result = AttributedString(HTMLText.stripTags(html))
        }
        if cache.count > 500 { cache.removeAll() }
        cache[html] = result
        return result
    }

    private static func cssColor() -> String {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "#eeeeee" : "#111111"
    }
}

struct DumpMarkdownView: View {
    let text: String
    var body: some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .font(.system(size: 13))
    }
}

/// JSON shown as a collapsible tree.
struct DumpJSONTreeView: View {
    let value: JSONValue
    var name: String? = nil
    var depth = 0

    var body: some View {
        switch value {
        case .object(let o):
            DisclosureGroup {
                ForEach(Array(o.pairs.enumerated()), id: \.offset) { _, pair in
                    DumpJSONTreeView(value: pair.value, name: pair.key, depth: depth + 1)
                }
            } label: { header("{\(o.count)}") }
            .modifier(TreeExpansion(initiallyOpen: depth < 3))
        case .array(let a):
            DisclosureGroup {
                ForEach(Array(a.enumerated()), id: \.offset) { i, v in
                    DumpJSONTreeView(value: v, name: String(i), depth: depth + 1)
                }
            } label: { header("[\(a.count)]") }
            .modifier(TreeExpansion(initiallyOpen: depth < 3))
        default:
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let name { Text("\(name):").foregroundStyle(DumpPalette.key) }
                leaf
            }
        }
    }

    private func header(_ summary: String) -> some View {
        HStack(spacing: 4) {
            if let name { Text("\(name):").foregroundStyle(DumpPalette.key) }
            Text(summary).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var leaf: some View {
        switch value {
        case .string(let s): Text("\"\(s)\"").foregroundStyle(DumpPalette.str)
        case .number: Text(value.displayString).foregroundStyle(DumpPalette.num)
        default: Text(value.displayString).foregroundStyle(DumpPalette.const)
        }
    }
}

/// DisclosureGroup with its own open/closed state.
private struct TreeExpansion: ViewModifier {
    @State var open: Bool
    init(initiallyOpen: Bool) { _open = State(initialValue: initiallyOpen) }
    func body(content: Content) -> some View {
        content.disclosureGroupStyle(ToggleDisclosureStyle(open: $open))
    }
}

private struct ToggleDisclosureStyle: DisclosureGroupStyle {
    @Binding var open: Bool
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { open.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).frame(width: 10)
                    configuration.label
                }
            }
            .buttonStyle(.plain)
            if open { configuration.content.padding(.leading, 14) }
        }
    }
}

struct DumpJSONStringView: View {
    let value: JSONValue
    var body: some View {
        if let s = value.string, let parsed = try? JSONValue.parse(s) {
            DumpJSONTreeView(value: parsed)
        } else {
            DumpJSONTreeView(value: value)
        }
    }
}

// MARK: - Stack frames

struct DumpFrameRow: View {
    @Environment(AppState.self) private var appState
    @Environment(DumpSession.self) private var session
    let frame: JSONValue
    var highlighted = false

    var body: some View {
        let file = frame["file_name"]?.string ?? ""
        let line = frame["line_number"]?.int ?? 0
        let cls = frame["class"]?.string ?? ""
        let method = frame["method"]?.string ?? ""
        let vendor = frame["vendor_frame"]?.bool ?? false
        Button {
            if !file.isEmpty { appState.dumpService.open(file: file, line: line, target: session.target) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(cls.isEmpty ? method : "\(cls)::\(method)")
                    .foregroundStyle(vendor ? Color.secondary : Color.primary)
                    .fontWeight(highlighted ? .semibold : .regular)
                Text("\(file):\(line)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in \(appState.dumpService.editor.displayName)")
    }
}

struct DumpFrameList: View {
    let frames: [JSONValue]
    @State private var showVendor = false

    var body: some View {
        let shown = frames.enumerated().filter { showVendor || !($0.element["vendor_frame"]?.bool ?? false) || $0.offset == 0 }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(shown, id: \.offset) { item in
                DumpFrameRow(frame: item.element, highlighted: item.offset == 0)
            }
            let vendorCount = frames.filter { $0["vendor_frame"]?.bool ?? false }.count
            if vendorCount > 0 {
                Button(showVendor ? "Hide vendor frames" : "Show \(vendorCount) vendor frames") { showVendor.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

struct DumpExceptionView: View {
    let content: JSONValue

    var body: some View {
        let frames = content["frames"]?.array ?? []
        let appFrame = frames.first { !($0["vendor_frame"]?.bool ?? false) } ?? frames.first
        VStack(alignment: .leading, spacing: 8) {
            Text(content["class"]?.displayString ?? "Exception")
                .foregroundStyle(.red).bold()
            Text(content["message"]?.displayString ?? "")
                .font(.system(size: 15, weight: .medium))
            if let appFrame, let snippet = appFrame["snippet"]?.array, !snippet.isEmpty {
                DumpSnippetView(snippet: snippet, highlight: appFrame["line_number"]?.int ?? -1)
            }
            DisclosureGroup("Stack trace (\(frames.count) frames)") {
                DumpFrameList(frames: frames)
            }
        }
    }
}

struct DumpSnippetView: View {
    let snippet: [JSONValue]
    let highlight: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(snippet.enumerated()), id: \.offset) { _, line in
                let n = line["line_number"]?.int ?? 0
                HStack(alignment: .top, spacing: 8) {
                    Text(String(n)).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    Text(line["text"]?.displayString ?? "")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.vertical, 1)
                .background(n == highlight ? DumpPalette.theme.snippetActiveLine : .clear)
            }
        }
        .padding(6)
        .background(DumpPalette.theme.snippetBackground, in: RoundedRectangle(cornerRadius: 4))
    }
}
