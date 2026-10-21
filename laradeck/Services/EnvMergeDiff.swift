import Foundation

nonisolated enum EnvMergeChoice: String, Codable, CaseIterable {
    case keepLocal
    case takeIncoming
    case drop
}

nonisolated enum EnvMergeKind: String, Codable {
    case onlyLocal
    case onlyIncoming
    case conflict
    case identical
}

nonisolated struct EnvMergeRow: Identifiable, Hashable {
    let id: String
    let key: String
    let kind: EnvMergeKind
    let localValue: String?
    let incomingValue: String?
    let localQuote: EnvQuoteStyle
    let incomingQuote: EnvQuoteStyle
    var choice: EnvMergeChoice

    init(
        key: String,
        kind: EnvMergeKind,
        localValue: String?,
        incomingValue: String?,
        localQuote: EnvQuoteStyle = .none,
        incomingQuote: EnvQuoteStyle = .none,
        choice: EnvMergeChoice
    ) {
        self.id = key
        self.key = key
        self.kind = kind
        self.localValue = localValue
        self.incomingValue = incomingValue
        self.localQuote = localQuote
        self.incomingQuote = incomingQuote
        self.choice = choice
    }
}

/// Builds a per-key review model from local vs incoming `.env` contents.
nonisolated enum EnvMergeDiff {
    static func rows(local: [EnvVariable], incoming: [EnvVariable]) -> [EnvMergeRow] {
        // Last occurrence wins, matching how dotenv loaders resolve duplicate keys.
        let localMap = Dictionary(local.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        let incomingMap = Dictionary(incoming.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        let keys = Set(localMap.keys).union(incomingMap.keys).sorted()

        return keys.map { key in
            let l = localMap[key]
            let i = incomingMap[key]
            let kind: EnvMergeKind
            let choice: EnvMergeChoice
            switch (l, i) {
            case let (l?, i?) where l.value == i.value:
                kind = .identical; choice = .keepLocal
            case (_?, _?):
                kind = .conflict; choice = .takeIncoming
            case (nil, _?):
                kind = .onlyIncoming; choice = .takeIncoming
            case (_?, nil):
                kind = .onlyLocal; choice = .keepLocal
            case (nil, nil):
                kind = .identical; choice = .drop
            }
            return EnvMergeRow(
                key: key,
                kind: kind,
                localValue: l?.value,
                incomingValue: i?.value,
                localQuote: l?.quote ?? .none,
                incomingQuote: i?.quote ?? .none,
                choice: choice
            )
        }
    }

    static func apply(_ rows: [EnvMergeRow]) -> [EnvVariable] {
        rows.compactMap { row in
            switch row.choice {
            case .keepLocal:
                guard let value = row.localValue else { return nil }
                return EnvVariable(key: row.key, value: value, quote: row.localQuote)
            case .takeIncoming:
                guard let value = row.incomingValue else { return nil }
                return EnvVariable(key: row.key, value: value, quote: row.incomingQuote)
            case .drop:
                return nil
            }
        }
    }
}

nonisolated enum EnvFileIO {
    static func envURL(at projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath, isDirectory: true).appendingPathComponent(".env")
    }

    static func exists(at projectPath: String) -> Bool {
        FileManager.default.fileExists(atPath: envURL(at: projectPath).path)
    }

    static func read(at projectPath: String) -> String? {
        try? String(contentsOf: envURL(at: projectPath), encoding: .utf8)
    }

    static func write(_ contents: String, to projectPath: String, backupExisting: Bool) throws {
        let url = envURL(at: projectPath)
        if backupExisting, FileManager.default.fileExists(atPath: url.path) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingLastPathComponent().appendingPathComponent(".env.bak.\(stamp)")
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
