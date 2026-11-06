import Foundation

/// Space used by Docker images and build cache, from `docker system df`.
struct DockerDiskUsage: Equatable {
    struct Item: Equatable {
        /// Total size, as Docker prints it ("19.3GB").
        var size: String
        /// What a prune would free ("5.04GB"), without the percentage.
        var reclaimable: String
        /// Number of images / cache entries.
        var count: Int

        /// True when there's nothing worth cleaning ("0B").
        var hasReclaimable: Bool {
            let digits = reclaimable.filter { $0.isNumber || $0 == "." }
            return (Double(digits) ?? 0) > 0
        }
    }

    var images: Item?
    var buildCache: Item?

    func item(for kind: DockerPruneKind) -> Item? {
        switch kind {
        case .images: return images
        case .buildCache: return buildCache
        }
    }

    /// Parses `docker system df --format '{{json .}}'`: one JSON object per line, e.g.
    /// `{"Reclaimable":"5.04GB (26%)","Size":"19.3GB","TotalCount":"13","Type":"Images"}`.
    init(systemDfOutput output: String) {
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["Type"] as? String else { continue }
            let reclaimable = (object["Reclaimable"] as? String ?? "0B")
                .split(separator: " ").first.map(String.init) ?? "0B"
            let item = Item(
                size: object["Size"] as? String ?? "0B",
                reclaimable: reclaimable,
                count: Int(object["TotalCount"] as? String ?? "") ?? 0
            )
            switch type {
            case "Images": images = item
            case "Build Cache": buildCache = item
            default: break
            }
        }
    }

    /// Freed space from prune output: "Total reclaimed space: 5.04GB" (image prune)
    /// or "Total:\t21.45GB" (builder prune).
    static func reclaimedSpace(fromPruneOutput output: String) -> String? {
        for line in output.split(separator: "\n").reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["Total reclaimed space:", "Total:"] where text.hasPrefix(prefix) {
                let value = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
}

/// What a prune would remove, from `docker system df -v`: unused images, or build cache not in use.
struct DockerPrunePreview: Equatable {
    struct Row: Identifiable, Equatable {
        var id: String
        /// Image name:tag, or the build step that produced the cache entry.
        var title: String
        /// Age, cache type, etc.
        var detail: String
        var size: String
        var bytes: Double
    }

    /// Largest first.
    var rows: [Row]
    /// Sum of the rows' sizes (images: space not shared with images that stay).
    var totalBytes: Double

    var totalSize: String { DockerPrunePreview.format(bytes: totalBytes) }

    /// Parses `docker system df -v --format '{{json .}}'` for one kind of cleanup.
    init?(kind: DockerPruneKind, verboseOutput output: String) {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var rows: [Row] = []
        switch kind {
        case .images:
            for image in root["Images"] as? [[String: Any]] ?? [] where (image["Containers"] as? String ?? "0") == "0" {
                let repository = image["Repository"] as? String ?? "<none>"
                let tag = image["Tag"] as? String ?? "<none>"
                let id = image["ID"] as? String ?? UUID().uuidString
                let title = repository == "<none>" ? "<untagged> \(Self.shortID(id))" : "\(repository):\(tag)"
                // Unique size is what deleting this image actually frees; shared layers stay.
                let size = image["UniqueSize"] as? String ?? image["Size"] as? String ?? "0B"
                rows.append(Row(id: id, title: title, detail: image["CreatedSince"] as? String ?? "",
                                size: size, bytes: Self.bytes(from: size)))
            }
        case .buildCache:
            for entry in root["BuildCache"] as? [[String: Any]] ?? [] {
                let inUse = entry["InUse"] as? String ?? (entry["InUse"] as? Bool).map { $0 ? "true" : "false" } ?? "false"
                guard inUse != "true" else { continue }
                let size = entry["Size"] as? String ?? "0B"
                let description = (entry["Description"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let type = entry["CacheType"] as? String ?? ""
                let used = entry["LastUsedSince"] as? String ?? ""
                let created = entry["CreatedSince"] as? String ?? ""
                rows.append(Row(id: entry["ID"] as? String ?? UUID().uuidString,
                                title: description.isEmpty ? type : description,
                                detail: [type, used.isEmpty ? created : "used \(used)"].filter { !$0.isEmpty }.joined(separator: " · "),
                                size: size, bytes: Self.bytes(from: size)))
            }
        }
        self.rows = rows.sorted { $0.bytes > $1.bytes }
        totalBytes = rows.reduce(0) { $0 + $1.bytes }
    }

    private static func shortID(_ id: String) -> String {
        String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12))
    }

    /// "84.3MB", "8.29kB", "2B", "1.5GiB" → bytes. Docker uses decimal units.
    static func bytes(from text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        let unit = trimmed.dropFirst(number.count).lowercased().replacingOccurrences(of: "i", with: "")
        let multiplier: Double
        switch unit {
        case "kb": multiplier = 1e3
        case "mb": multiplier = 1e6
        case "gb": multiplier = 1e9
        case "tb": multiplier = 1e12
        default: multiplier = 1
        }
        return (Double(number) ?? 0) * multiplier
    }

    static func format(bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .decimal)
    }
}

/// The two cleanups offered in the toolbar popover.
enum DockerPruneKind: CaseIterable, Identifiable {
    case images
    case buildCache

    var id: Self { self }

    var title: String {
        switch self {
        case .images: return "Images"
        case .buildCache: return "Build cache"
        }
    }

    /// `-a` matches what `docker system df` counts as reclaimable: every image no container
    /// uses (not only dangling ones), and all unused build cache.
    var arguments: [String] {
        switch self {
        case .images: return ["image", "prune", "-a", "-f"]
        case .buildCache: return ["builder", "prune", "-a", "-f"]
        }
    }

    /// The command as you'd type it in Terminal.
    var command: String {
        "docker " + arguments.joined(separator: " ")
    }

    /// "image" / "cache entry" for counts in the cleanup sheet.
    func noun(count: Int) -> String {
        switch self {
        case .images: return count == 1 ? "image" : "images"
        case .buildCache: return count == 1 ? "cache entry" : "cache entries"
        }
    }

    /// Explains the trade-off before confirming.
    var warning: String {
        switch self {
        case .images:
            return "Removes every image not used by a container, including those of stopped projects. They'll be pulled or rebuilt (e.g. sail build) the next time you start them."
        case .buildCache:
            return "Removes all unused build cache. The next docker build or sail build starts from scratch and takes longer."
        }
    }
}
