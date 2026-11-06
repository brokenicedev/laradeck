import Foundation
import HTTPKit

/// Renders `{{…}}` tags in response bodies and headers.
///
/// Request data: `{{params.id}}`, `{{query.page}}`, `{{header.authorization}}`, `{{cookie.session}}`,
/// `{{body}}`, `{{body.user.name}}`, `{{method}}`, `{{path}}`.
/// Helpers: `{{uuid}}`, `{{now}}`, `{{now 'yyyy-MM-dd'}}`, `{{timestamp}}`, `{{int 1 100}}`,
/// `{{float 0 10}}`, `{{bool}}`, `{{pick 'a' 'b'}}`, `{{faker.email}}` (see `Faker.generators`).
/// Blocks: `{{#repeat 3}}…{{/repeat}}` joins copies with commas and exposes `{{@index}}`.
/// Unknown tags are left untouched.
public struct TemplateRenderer {
    public var context: RequestContext?

    public init(context: RequestContext?) {
        self.context = context
    }

    public func render(_ template: String) -> String {
        guard template.contains("{{") else { return template }
        return render(template, index: nil)
    }

    private func render(_ template: String, index: Int?) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else {
                out += rest[open.lowerBound...]
                return out
            }
            let expression = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            rest = rest[close.upperBound...]

            if expression.hasPrefix("#repeat") {
                // Find the matching {{/repeat}}, counting nested blocks.
                guard let (inner, after) = blockBody(in: rest) else {
                    out += "{{\(expression)}}"
                    continue
                }
                let args = Self.tokenize(String(expression.dropFirst("#repeat".count)))
                let counts = args.compactMap { Int($0) }
                let count: Int
                if counts.count >= 2 {
                    count = Int.random(in: min(counts[0], counts[1])...max(counts[0], counts[1]))
                } else {
                    count = max(0, counts.first ?? 1)
                }
                out += (0..<count).map { render(String(inner), index: $0) }.joined(separator: ",")
                rest = after
                continue
            }

            if let value = evaluate(expression, index: index) {
                out += value
            } else {
                out += "{{\(expression)}}"
            }
        }
        out += rest
        return out
    }

    private func blockBody(in text: Substring) -> (Substring, Substring)? {
        var depth = 1
        var cursor = text.startIndex
        while let open = text.range(of: "{{", range: cursor..<text.endIndex),
              let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) {
            let tag = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if tag.hasPrefix("#repeat") { depth += 1 }
            if tag == "/repeat" {
                depth -= 1
                if depth == 0 { return (text[text.startIndex..<open.lowerBound], text[close.upperBound...]) }
            }
            cursor = close.upperBound
        }
        return nil
    }

    func evaluate(_ expression: String, index: Int?) -> String? {
        let tokens = Self.tokenize(expression)
        guard let head = tokens.first else { return nil }
        let args = Array(tokens.dropFirst())

        if head == "@index" { return index.map(String.init) }

        let (root, key) = Self.splitHead(head)
        switch root {
        case "params": return key.flatMap { context?.params[$0] } ?? (context == nil ? nil : "")
        case "query": return key.flatMap { context?.query[$0] } ?? (context == nil ? nil : "")
        case "header", "headers": return key.flatMap { context?.headers[$0.lowercased()] } ?? (context == nil ? nil : "")
        case "cookie", "cookies": return key.flatMap { context?.cookies[$0] } ?? (context == nil ? nil : "")
        case "body":
            guard let context else { return nil }
            if key == nil && context.bodyJSON == nil { return context.bodyText }
            return context.bodyValue(at: key ?? "").map(\.displayString) ?? ""
        case "method": return context?.method
        case "path": return context?.path
        case "uuid": return UUID().uuidString.lowercased()
        case "now": return Self.format(Date(), args.first)
        case "timestamp": return String(Int(Date().timeIntervalSince1970))
        case "int":
            let low = args.first.flatMap(Int.init) ?? 0
            let high = args.dropFirst().first.flatMap(Int.init) ?? max(low, 100)
            return String(Int.random(in: min(low, high)...max(low, high)))
        case "float":
            let low = args.first.flatMap(Double.init) ?? 0
            let high = args.dropFirst().first.flatMap(Double.init) ?? max(low, 100)
            let value = Double.random(in: min(low, high)...max(low, high))
            return String(format: "%.2f", value)
        case "bool": return Bool.random() ? "true" : "false"
        case "pick": return args.randomElement() ?? ""
        case "faker":
            guard let key, let generator = Faker.generators[key] else { return nil }
            return generator(args)
        default: return nil
        }
    }

    static func splitHead(_ head: String) -> (String, String?) {
        guard let dot = head.firstIndex(of: ".") else { return (head, nil) }
        return (String(head[..<dot]), String(head[head.index(after: dot)...]))
    }

    /// Splits on spaces, keeping 'quoted' and "quoted" arguments together.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for char in text {
            if let q = quote {
                if char == q { tokens.append(current); current = ""; quote = nil } else { current.append(char) }
            } else if char == "'" || char == "\"" {
                quote = char
            } else if char == " " {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func format(_ date: Date, _ pattern: String?) -> String {
        guard let pattern, !pattern.isEmpty else {
            return ISO8601DateFormatter().string(from: date)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// Small built-in fake data, enough for realistic mock bodies.
public enum Faker {
    static let firstNames = ["Alice", "Marco", "Giulia", "John", "Sofia", "Luca", "Emma", "Noah", "Chiara", "Liam", "Olivia", "Matteo", "Ava", "Leo", "Mia", "Lucas"]
    static let lastNames = ["Rossi", "Smith", "Bianchi", "Johnson", "Romano", "Brown", "Colombo", "Garcia", "Ricci", "Miller", "Marino", "Davis", "Greco", "Wilson"]
    static let cities = ["Milan", "Rome", "Turin", "London", "Paris", "Berlin", "Madrid", "Lisbon", "Amsterdam", "New York", "Austin", "Tokyo"]
    static let countries = ["Italy", "France", "Germany", "Spain", "Portugal", "Netherlands", "United Kingdom", "United States", "Japan", "Canada"]
    static let streets = ["Main St", "Via Roma", "High Street", "Elm Avenue", "Corso Italia", "Park Lane", "Via Garibaldi", "Oak Road"]
    static let companies = ["Acme", "Globex", "Initech", "Umbrella", "Stark Industries", "Wayne Enterprises", "Hooli", "Soylent"]
    static let companySuffixes = ["Inc", "LLC", "S.r.l.", "Ltd", "GmbH"]
    static let domains = ["example.com", "example.org", "mail.test", "acme.test"]
    static let words = ["alpha", "bravo", "cloud", "delta", "echo", "forest", "galaxy", "harbor", "island", "jungle", "kernel", "lunar", "matrix", "nebula", "orbit", "pixel", "quartz", "river", "signal", "tempo", "ultra", "vector", "willow", "zenith"]
    static let products = ["Chair", "Lamp", "Keyboard", "Backpack", "Watch", "Notebook", "Mug", "Headphones", "Bottle", "Sneakers"]
    static let adjectives = ["Ergonomic", "Sleek", "Rustic", "Smart", "Compact", "Durable", "Elegant", "Handmade"]

    public static let generators: [String: ([String]) -> String] = [
        "firstName": { _ in firstNames.randomElement()! },
        "lastName": { _ in lastNames.randomElement()! },
        "name": { _ in fullName() },
        "fullName": { _ in fullName() },
        "username": { _ in username() },
        "email": { _ in email() },
        "phone": { _ in phone() },
        "city": { _ in cities.randomElement()! },
        "country": { _ in countries.randomElement()! },
        "street": { _ in "\(Int.random(in: 1...200)) \(streets.randomElement()!)" },
        "address": { _ in "\(Int.random(in: 1...200)) \(streets.randomElement()!), \(cities.randomElement()!)" },
        "zip": { _ in String(format: "%05d", Int.random(in: 10000...99999)) },
        "company": { _ in "\(companies.randomElement()!) \(companySuffixes.randomElement()!)" },
        "word": { _ in words.randomElement()! },
        "words": { args in words(count: args.first.flatMap(Int.init) ?? 3) },
        "sentence": { args in sentence(words: args.first.flatMap(Int.init) ?? 8) },
        "paragraph": { args in (0..<(args.first.flatMap(Int.init) ?? 3)).map { _ in sentence(words: Int.random(in: 6...12)) }.joined(separator: " ") },
        "product": { _ in "\(adjectives.randomElement()!) \(products.randomElement()!)" },
        "price": { _ in String(format: "%.2f", Double.random(in: 1...500)) },
        "url": { _ in "https://\(domains.randomElement()!)/\(words.randomElement()!)" },
        "avatar": { _ in "https://i.pravatar.cc/150?u=\(Int.random(in: 1...10_000))" },
        "image": { args in "https://picsum.photos/\(args.first ?? "640")/\(args.dropFirst().first ?? "480")" },
        "color": { _ in String(format: "#%06x", Int.random(in: 0...0xFFFFFF)) },
        "uuid": { _ in UUID().uuidString.lowercased() },
        "ipv4": { _ in (0..<4).map { _ in String(Int.random(in: 1...254)) }.joined(separator: ".") },
        "date": { args in TemplateRenderer.format(randomDate(), args.first ?? "yyyy-MM-dd") },
        "datetime": { _ in ISO8601DateFormatter().string(from: randomDate()) },
        "past": { _ in ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double.random(in: 3600...31_536_000))) },
        "future": { _ in ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double.random(in: 3600...31_536_000))) },
        "number": { args in
            let low = args.first.flatMap(Int.init) ?? 1
            let high = args.dropFirst().first.flatMap(Int.init) ?? 1000
            return String(Int.random(in: min(low, high)...max(low, high)))
        },
        "boolean": { _ in Bool.random() ? "true" : "false" },
    ]

    static func fullName() -> String { "\(firstNames.randomElement()!) \(lastNames.randomElement()!)" }
    static func username() -> String { "\(firstNames.randomElement()!.lowercased())\(Int.random(in: 1...999))" }
    static func email() -> String { "\(firstNames.randomElement()!.lowercased()).\(lastNames.randomElement()!.lowercased())@\(domains.randomElement()!)" }
    static func phone() -> String { "+39 3\(Int.random(in: 10...99)) \(Int.random(in: 100...999)) \(Int.random(in: 1000...9999))" }
    static func words(count: Int) -> String { (0..<max(1, count)).map { _ in words.randomElement()! }.joined(separator: " ") }
    static func sentence(words count: Int) -> String {
        let text = words(count: count)
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }
    static func randomDate() -> Date { Date().addingTimeInterval(Double.random(in: -31_536_000...31_536_000)) }
}
