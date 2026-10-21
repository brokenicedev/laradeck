import Foundation

nonisolated enum StorageLinkStatus: Equatable {
    case linked
    case missing
    case invalid

    var label: String {
        switch self {
        case .linked: return "Linked"
        case .missing: return "Missing"
        case .invalid: return "Invalid"
        }
    }

    var systemImage: String {
        switch self {
        case .linked: return "link"
        case .missing: return "link.badge.plus"
        case .invalid: return "exclamationmark.triangle"
        }
    }
}

/// Live Laravel project health snapshot — not persisted.
nonisolated struct LaravelInsights: Equatable {
    var appEnv: String?
    var appDebug: String?
    var sessionDriver: String?
    var cacheDriver: String?
    var queueConnection: String?
    var dbConnection: String?
    var storageLink: StorageLinkStatus = .missing
    var hasHorizon: Bool = false
    var hasReverb: Bool = false
    var pendingMigrations: Int?
}

nonisolated enum ArtisanTask: String, CaseIterable, Identifiable {
    case optimizeClear
    case configClear
    case routeClear
    case viewClear
    case storageLink
    case migrate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optimizeClear: return "Clear All"
        case .configClear: return "Config"
        case .routeClear: return "Routes"
        case .viewClear: return "Views"
        case .storageLink: return "Storage Link"
        case .migrate: return "Migrate"
        }
    }

    var systemImage: String {
        switch self {
        case .optimizeClear: return "trash"
        case .configClear: return "gearshape"
        case .routeClear: return "arrow.triangle.branch"
        case .viewClear: return "doc.richtext"
        case .storageLink: return "link"
        case .migrate: return "arrow.up.doc"
        }
    }

    /// Artisan arguments after `artisan`.
    var artisanArguments: [String] {
        switch self {
        case .optimizeClear: return ["optimize:clear"]
        case .configClear: return ["config:clear"]
        case .routeClear: return ["route:clear"]
        case .viewClear: return ["view:clear"]
        case .storageLink: return ["storage:link"]
        case .migrate: return ["migrate", "--force"]
        }
    }

    var successMessage: String {
        switch self {
        case .optimizeClear: return "All caches cleared"
        case .configClear: return "Config cache cleared"
        case .routeClear: return "Route cache cleared"
        case .viewClear: return "View cache cleared"
        case .storageLink: return "Storage linked"
        case .migrate: return "Migrations completed"
        }
    }

    var requiresConfirmation: Bool {
        self == .migrate
    }
}

nonisolated struct ArtisanTaskResult: Equatable {
    let task: ArtisanTask
    let exitCode: Int32
    let stderrSnippet: String?

    var succeeded: Bool { exitCode == 0 }
}

nonisolated struct ArtisanTaskStatus: Equatable {
    let task: ArtisanTask
    let succeeded: Bool
    let finishedAt: Date
}
