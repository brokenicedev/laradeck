import Foundation

/// Parses the HTML that Symfony's VarDumper (used by the PHP client) produces, e.g.
/// `<pre class=sf-dump id=sf-dump-1><span class=sf-dump-note>array:1</span> [<samp data-depth=1 class=sf-dump-expanded>…</samp>]</pre>`
/// into a tree of styled text and collapsible blocks.
public enum DumpNode: Hashable {
    case text(String, style: String?, title: String?)
    case block(id: Int, depth: Int, expanded: Bool, children: [DumpNode])
}

public enum SfDump {
    public static func isDump(_ html: String) -> Bool {
        html.contains("sf-dump")
    }

    public static func parse(_ html: String) -> [DumpNode] {
        var parser = Parser(html: html)
        return parser.run()
    }

    /// Plain text of a dump with every block expanded.
    public static func plainText(_ nodes: [DumpNode]) -> String {
        nodes.map { node -> String in
            switch node {
            case .text(let t, _, _): return t
            case .block(_, _, _, let children): return plainText(children)
            }
        }.joined()
    }

    private struct Frame {
        var children: [DumpNode] = []
        var blockDepth = 0
        var blockExpanded = true
        var isBlock = false
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        var frames = [Frame()]
        var styleStack: [(tag: String, style: String?, title: String?)] = []
        var nextID = 0

        init(html: String) { chars = Array(html) }

        mutating func run() -> [DumpNode] {
            var text = ""
            while i < chars.count {
                if chars[i] == "<" {
                    flush(&text)
                    readTag()
                } else {
                    text.append(chars[i])
                    i += 1
                }
            }
            flush(&text)
            while frames.count > 1 { closeBlock() }
            return frames[0].children
        }

        mutating func flush(_ text: inout String) {
            guard !text.isEmpty else { return }
            let decoded = HTMLText.decodeEntities(text)
            let style = styleStack.last { $0.style != nil }?.style
            let title = styleStack.last { $0.title != nil }?.title
            frames[frames.count - 1].children.append(.text(decoded, style: style, title: title))
            text = ""
        }

        mutating func readTag() {
            var raw = ""
            var quote: Character?
            i += 1
            while i < chars.count {
                let c = chars[i]
                i += 1
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == ">" {
                    break
                }
                raw.append(c)
            }
            handle(tag: raw)
        }

        mutating func handle(tag raw: String) {
            let closing = raw.hasPrefix("/")
            let body = closing ? String(raw.dropFirst()) : raw
            let name = body.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
            if name.hasPrefix("!") { return }

            if !closing && (name == "script" || name == "style") {
                skipUntilClose(name)
                return
            }
            if name == "br" {
                frames[frames.count - 1].children.append(.text("\n", style: nil, title: nil))
                return
            }

            let attrs = Self.attributes(body)
            switch (name, closing) {
            case ("samp", false):
                var frame = Frame()
                frame.isBlock = true
                frame.blockDepth = Int(attrs["data-depth"] ?? "") ?? frames.count
                frame.blockExpanded = !(attrs["class"] ?? "").contains("sf-dump-compact")
                frames.append(frame)
            case ("samp", true):
                closeBlock()
            case ("span", false), ("abbr", false), ("a", false), ("var", false):
                let cls = attrs["class"]?.split(separator: " ").first { $0.hasPrefix("sf-dump-") }
                    .map { String($0.dropFirst("sf-dump-".count)) }
                styleStack.append((name, cls, attrs["title"]))
            case ("span", true), ("abbr", true), ("a", true), ("var", true):
                if let idx = styleStack.lastIndex(where: { $0.tag == name }) { styleStack.remove(at: idx) }
            default:
                break
            }
        }

        mutating func closeBlock() {
            guard frames.count > 1, let frame = frames.popLast() else { return }
            let node = DumpNode.block(id: nextID, depth: frame.blockDepth, expanded: frame.blockExpanded, children: frame.children)
            nextID += 1
            frames[frames.count - 1].children.append(node)
        }

        mutating func skipUntilClose(_ name: String) {
            let close = Array("</\(name)")
            while i < chars.count {
                if chars[i] == "<", i + close.count <= chars.count,
                   String(chars[i..<i + close.count]).lowercased() == String(close) {
                    while i < chars.count, chars[i] != ">" { i += 1 }
                    i += 1
                    return
                }
                i += 1
            }
        }

        static func attributes(_ tag: String) -> [String: String] {
            var result: [String: String] = [:]
            let chars = Array(tag)
            var i = chars.firstIndex(where: { $0.isWhitespace }) ?? chars.count
            while i < chars.count {
                while i < chars.count, chars[i].isWhitespace || chars[i] == "/" { i += 1 }
                var key = ""
                while i < chars.count, !chars[i].isWhitespace, chars[i] != "=", chars[i] != "/" { key.append(chars[i]); i += 1 }
                guard !key.isEmpty else { i += 1; continue }
                var value = ""
                if i < chars.count, chars[i] == "=" {
                    i += 1
                    if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                        let q = chars[i]
                        i += 1
                        while i < chars.count, chars[i] != q { value.append(chars[i]); i += 1 }
                        i += 1
                    } else {
                        while i < chars.count, !chars[i].isWhitespace { value.append(chars[i]); i += 1 }
                    }
                }
                result[key.lowercased()] = HTMLText.decodeEntities(value)
            }
            return result
        }
    }
}

public enum HTMLText {
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let entity = String(s[s.index(after: i)..<semi])
                if let decoded = decode(entity) {
                    out += decoded
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    private static func decode(_ entity: String) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#039": return "'"
        case "nbsp": return "\u{00A0}"
        default:
            if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let v = UInt32(entity.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) {
                return String(Character(u))
            }
            if entity.hasPrefix("#"), let v = UInt32(entity.dropFirst()), let u = Unicode.Scalar(v) {
                return String(Character(u))
            }
            return nil
        }
    }

    /// Removes tags, scripts and styles; keeps text. Used for search and copy.
    public static func stripTags(_ html: String) -> String {
        if SfDump.isDump(html) { return SfDump.plainText(SfDump.parse(html)) }
        var s = html
        for tag in ["script", "style"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(s)
    }
}
