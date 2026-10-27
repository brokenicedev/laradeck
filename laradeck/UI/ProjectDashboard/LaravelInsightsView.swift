import SwiftUI

extension LaravelInsights {
    /// Something worth a look: pending migrations or a broken/missing storage link.
    var needsAttention: Bool {
        storageLink != .linked || (pendingMigrations ?? 0) > 0
    }
}

/// Loads a project's Laravel insights (instant `.env` read, then `migrate:status`) and caches them.
@MainActor
enum LaravelInsightsLoader {
    static func refresh(project: Project, appState: AppState) async {
        let previous = appState.cachedLaravelInsights(for: project.id)
        // Keep showing cached values until the new snapshot is ready.
        var updated = LaravelInsightsService.loadInstant(project: project)
        updated.pendingMigrations = previous?.pendingMigrations
        appState.storeLaravelInsights(updated, for: project.id)

        let pending = await LaravelInsightsService.loadMigrationStatus(project: project)
        // Prefer the previous count over nil while artisan is slow or fails.
        updated.pendingMigrations = pending ?? previous?.pendingMigrations
        appState.storeLaravelInsights(updated, for: project.id)
    }
}

/// Laravel configuration as label/value rows, values colored by state (Env, Debug, drivers,
/// storage link, migrations). Used by the project's Info popover.
struct LaravelInsightsRows: View {
    let insights: LaravelInsights

    var body: some View {
        if let appEnv = insights.appEnv {
            row("Env", appEnv, tone: envTone(appEnv))
        }
        if let appDebug = insights.appDebug {
            let on = appDebug.lowercased() == "true"
            row("Debug", on ? "On" : "Off", tone: on ? .warning : .neutral)
        }
        if let session = insights.sessionDriver { row("Session", session, tone: .info) }
        if let cache = insights.cacheDriver { row("Cache", cache, tone: .info) }
        if let queue = insights.queueConnection { row("Queue", queue, tone: .info) }
        if let db = insights.dbConnection { row("Database", db, tone: .info) }
        row("Storage link", insights.storageLink.label, tone: storageTone)
        if insights.hasHorizon { row("Horizon", "Installed", tone: .accent) }
        if insights.hasReverb { row("Reverb", "Installed", tone: .accent) }
        if let pending = insights.pendingMigrations {
            row("Migrations", pending == 0 ? "Up to date" : "\(pending) pending",
                tone: pending == 0 ? .success : .warning)
        } else {
            row("Migrations", "Checking…", tone: .neutral)
        }
    }

    private func row(_ label: String, _ value: String, tone: TagTone) -> some View {
        GridRow {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(tone.foreground)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(tone.background, in: Capsule())
        }
    }

    private enum TagTone {
        case neutral, success, warning, danger, info, accent

        var foreground: Color {
            switch self {
            case .neutral: return .primary
            case .success: return .green
            case .warning: return .orange
            case .danger: return .red
            case .info: return .blue
            case .accent: return .purple
            }
        }

        var background: Color {
            switch self {
            case .neutral: return Color.primary.opacity(0.07)
            default: return foreground.opacity(0.15)
            }
        }
    }

    private var storageTone: TagTone {
        switch insights.storageLink {
        case .linked: return .success
        case .missing: return .warning
        case .invalid: return .danger
        }
    }

    private func envTone(_ env: String) -> TagTone {
        switch env.lowercased() {
        case "production", "prod": return .danger
        case "staging": return .warning
        case "local", "development", "dev": return .success
        default: return .info
        }
    }
}
