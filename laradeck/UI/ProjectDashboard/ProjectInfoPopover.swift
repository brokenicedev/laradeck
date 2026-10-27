import SwiftUI

/// "Info" popover on the project header: environment, URL, branch, path, then the Laravel configuration
/// (env, debug, drivers, storage link, migrations).
struct ProjectInfoPopover: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let environmentName: String
    let gitBranch: String?
    let isLaravel: Bool

    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Project") {
                row("Environment", environmentName)
                if let url = project.effectiveURL { row("URL", url.absoluteString) }
                if let gitBranch { row("Git branch", gitBranch) }
                row("Path", (project.path as NSString).abbreviatingWithTildeInPath)
            }

            if isLaravel {
                Divider()
                HStack {
                    LaravelLogoView(size: 14)
                    Text("Laravel").font(.headline)
                    Spacer()
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRefreshing)
                    .help("Refresh")
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                    LaravelInsightsRows(insights: appState.cachedLaravelInsights(for: project.id) ?? LaravelInsights())
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .task(id: project.id) {
            if isLaravel { await refresh() }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                content()
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            label(title)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await LaravelInsightsLoader.refresh(project: project, appState: appState)
    }
}
