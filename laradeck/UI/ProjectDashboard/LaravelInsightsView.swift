import SwiftUI

struct LaravelInsightsView: View {
    @Environment(AppState.self) private var appState

    let project: Project
    var refreshToken: Int = 0

    @State private var insights: LaravelInsights
    @State private var isExpanded: Bool
    @State private var isRefreshing = false

    init(project: Project, refreshToken: Int = 0, cachedInsights: LaravelInsights? = nil) {
        self.project = project
        self.refreshToken = refreshToken
        let key = "laravelInsightsExpanded.\(project.id.uuidString)"
        _isExpanded = State(initialValue: UserDefaults.standard.object(forKey: key) as? Bool ?? true)
        _insights = State(initialValue: cachedInsights ?? LaravelInsights())
    }

    private var expansionKey: String {
        "laravelInsightsExpanded.\(project.id.uuidString)"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if isExpanded {
                Divider()
                expandedContent
            }
        }
        .laradeckCard(cornerRadius: 10)
        .task(id: taskKey) {
            await refreshInsights(includeMigrations: true)
        }
    }

    private var taskKey: String {
        "\(project.id.uuidString)-\(refreshToken)"
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Button {
                isExpanded.toggle()
                UserDefaults.standard.set(isExpanded, forKey: expansionKey)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    LaravelLogoView(size: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Laravel")
                            .font(.subheadline.weight(.semibold))
                        if !isExpanded {
                            Text(collapsedSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            if isRefreshing {
                ProgressView().controlSize(.small)
            }

            Button {
                Task { await refreshInsights(includeMigrations: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshing)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isExpanded ? 12 : 10)
    }

    private var collapsedSummary: String {
        var parts: [String] = []
        if let env = insights.appEnv { parts.append(env) }
        if let session = insights.sessionDriver { parts.append("session \(session)") }
        if insights.storageLink != .linked { parts.append("storage \(insights.storageLink.label.lowercased())") }
        if let pending = insights.pendingMigrations, pending > 0 { parts.append("\(pending) migrations") }
        return parts.isEmpty ? "Tap to expand" : parts.joined(separator: " · ")
    }

    // MARK: - Body

    private var expandedContent: some View {
        insightTags
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
    }

    private var insightTags: some View {
        FlowLayout(spacing: 8) {
            if let appEnv = insights.appEnv {
                insightTag("Env", appEnv, tone: envTone(appEnv))
            }
            if let appDebug = insights.appDebug {
                let on = appDebug.lowercased() == "true"
                insightTag("Debug", on ? "On" : "Off", tone: on ? .warning : .neutral)
            }
            if let sessionDriver = insights.sessionDriver {
                insightTag("Session", sessionDriver, tone: .info)
            }
            if let cacheDriver = insights.cacheDriver {
                insightTag("Cache", cacheDriver, tone: .info)
            }
            if let queueConnection = insights.queueConnection {
                insightTag("Queue", queueConnection, tone: .info)
            }
            if let dbConnection = insights.dbConnection {
                insightTag("DB", dbConnection, tone: .info)
            }
            insightTag("Storage", insights.storageLink.label, tone: storageTone)
            if insights.hasHorizon {
                insightTag("Horizon", "Yes", tone: .accent)
            }
            if insights.hasReverb {
                insightTag("Reverb", "Yes", tone: .accent)
            }
            if let pending = insights.pendingMigrations {
                insightTag(
                    "Migrations",
                    pending == 0 ? "OK" : "\(pending) pending",
                    tone: pending == 0 ? .success : .warning
                )
            }
        }
    }

    private enum TagTone {
        case neutral, success, warning, danger, info, accent

        var foreground: Color {
            switch self {
            case .neutral: return .primary
            case .success: return Color(red: 0.1, green: 0.55, blue: 0.25)
            case .warning: return Color(red: 0.75, green: 0.45, blue: 0.05)
            case .danger: return Color(red: 0.85, green: 0.2, blue: 0.2)
            case .info: return Color(red: 0.15, green: 0.4, blue: 0.75)
            case .accent: return Color(red: 0.45, green: 0.25, blue: 0.75)
            }
        }

        var background: Color {
            switch self {
            case .neutral: return Color.primary.opacity(0.07)
            case .success: return Color(red: 0.1, green: 0.55, blue: 0.25).opacity(0.14)
            case .warning: return Color(red: 0.75, green: 0.45, blue: 0.05).opacity(0.14)
            case .danger: return Color(red: 0.85, green: 0.2, blue: 0.2).opacity(0.14)
            case .info: return Color(red: 0.15, green: 0.4, blue: 0.75).opacity(0.14)
            case .accent: return Color(red: 0.45, green: 0.25, blue: 0.75).opacity(0.14)
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

    private func insightTag(_ label: String, _ value: String, tone: TagTone = .neutral) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(tone.foreground)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tone.background, in: Capsule())
    }

    // MARK: - Logic

    private func refreshInsights(includeMigrations: Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }

        // Keep showing cached / previous values until the new snapshot is ready.
        var updated = LaravelInsightsService.loadInstant(project: project)
        if includeMigrations {
            let pending = await LaravelInsightsService.loadMigrationStatus(project: project)
            // Prefer previous pending count over nil while artisan is slow / fails.
            updated.pendingMigrations = pending ?? insights.pendingMigrations
        }
        insights = updated
        appState.storeLaravelInsights(updated, for: project.id)
    }
}

// MARK: - Flow layout

/// Simple wrapping row layout for compact insight tags.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
