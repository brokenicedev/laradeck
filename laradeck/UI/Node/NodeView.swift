import SwiftUI

/// Detail page for the sidebar's "Node" row: Node versions installed with nvm, the nvm default,
/// and releases available from nodejs.org. Same layout as the PHP page.
struct NodeView: View {
    @Environment(AppState.self) private var appState
    @State private var confirmUninstall: NodeInstallation?
    @State private var confirmInstall: NodeRelease?
    @State private var customVersion = ""

    private var node: NodeManager { appState.nodeManager }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if !node.isNvmInstalled {
                    NoticeBanner(tone: .info,
                                 message: "Node versions are managed with nvm. Install it from github.com/nvm-sh/nvm, then reopen this page.")
                } else {
                    installedSection
                    availableSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LaradeckTheme.pageBackground)
        .laradeckTitle("Node")
        .detailCloseButton(help: "Close Node") { appState.showingNode = false }
        .toolbar {
            ToolbarItem {
                Button {
                    node.refresh()
                    node.loadReleases(force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload nvm versions and the nodejs.org release list")
                .disabled(node.busy != nil)
            }
        }
        .onAppear {
            node.refresh()
            node.loadReleases()
        }
        .confirmationDialog("Uninstall Node \(confirmUninstall?.version.description ?? "")?", isPresented: Binding(
            get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } }
        ), presenting: confirmUninstall) { installation in
            Button("Uninstall", role: .destructive) {
                let users = projects(using: installation)
                Task {
                    if await node.uninstall(installation) {
                        for project in users { appState.setNodeVersion(nil, for: project) }
                    }
                }
            }
        } message: { installation in
            let users = projects(using: installation)
            Text(users.isEmpty
                 ? "Runs nvm uninstall. Global npm packages installed with this version are removed too."
                 : "Used by \(users.map(\.name).joined(separator: ", ")); they'll go back to the nvm default.")
        }
        .confirmationDialog("Install Node \(confirmInstall?.version.description ?? "")?", isPresented: Binding(
            get: { confirmInstall != nil }, set: { if !$0 { confirmInstall = nil } }
        ), presenting: confirmInstall) { release in
            Button("Install") {
                Task { await node.install(release.version.description) }
            }
        } message: { _ in
            Text("Runs nvm install. It downloads Node from nodejs.org.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "hexagon")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 44, height: 44)
                    .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.defaultInstallation.map { "Node \($0.version.description)" } ?? "Node")
                        .font(.title.weight(.semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let busy = node.busy {
                    ProgressView().controlSize(.small)
                    Text(busy)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 360, alignment: .trailing)
                }
            }
            if let error = node.error {
                NoticeBanner(tone: .error, message: error) { node.error = nil }
            } else if let message = node.lastMessage {
                NoticeBanner(tone: .success, message: message) { node.lastMessage = nil }
            }
        }
    }

    private var subtitle: String {
        guard let dir = node.nvmDirectory else { return "nvm not found" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shortDir = dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
        return node.defaultInstallation != nil ? "nvm default · \(shortDir)" : "No nvm default · \(shortDir)"
    }

    // MARK: Installed

    private var installedSection: some View {
        DetailSection("Installed",
                      footer: "The default is what new terminals and projects without their own version use (nvm alias default). Pick a version for a single project from its dashboard.") {
            ForEach(node.installed) { installation in
                installedRow(installation)
            }
            if node.installed.isEmpty {
                emptyRow("No Node versions installed with nvm yet.")
            }
        }
    }

    private func installedRow(_ installation: NodeInstallation) -> some View {
        let users = projects(using: installation)
        let update = node.update(for: installation)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Node \(installation.version.description)")
                    if let lts = ltsName(for: installation.version.major) {
                        Text("LTS \(lts)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !users.isEmpty {
                    Text("Used by \(users.map(\.name).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let update {
                Text("\(update.version.description) available")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            if node.isDefault(installation) {
                Label("Default", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Make Default") { Task { await node.setDefault(installation) } }
                    .disabled(node.busy != nil)
            }
            RowMenu {
                if let update {
                    Button("Install \(update.version.description)") {
                        Task { await node.install(update.version.description) }
                    }
                }
                Button("Uninstall…", role: .destructive) { confirmUninstall = installation }
                    .disabled(node.isDefault(installation))
            }
            .disabled(node.busy != nil)
        }
        .detailRow()
    }

    // MARK: Available

    private var availableSection: some View {
        let installedMajors = Set(node.installed.map(\.version.major))
        let available = node.releases.filter { !installedMajors.contains($0.version.major) }
        return DetailSection("Available", footer: "Newest release of each Node line from nodejs.org.") {
            if node.loadingReleases {
                ProgressView().controlSize(.small)
            }
        } content: {
            if let error = node.releasesError {
                emptyRow(error)
            }
            ForEach(available) { release in
                HStack {
                    Text("Node \(release.version.description)")
                    if let lts = release.lts {
                        Text("LTS \(lts)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(release.date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Install…") { confirmInstall = release }
                        .disabled(node.busy != nil)
                }
                .detailRow()
            }
            HStack {
                TextField("Other version, e.g. 20.11.1 or lts/iron", text: $customVersion)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onSubmit(installCustom)
                Button("Install", action: installCustom)
                    .disabled(customVersion.trimmingCharacters(in: .whitespaces).isEmpty || node.busy != nil)
                Spacer()
            }
            .detailRow()
        }
    }

    private func installCustom() {
        let version = customVersion.trimmingCharacters(in: .whitespaces)
        guard !version.isEmpty, node.busy == nil else { return }
        Task {
            if await node.install(version) { customVersion = "" }
        }
    }

    // MARK: Helpers

    private func projects(using installation: NodeInstallation) -> [Project] {
        appState.projects.filter { node.pinned(for: $0) == installation }
    }

    private func ltsName(for major: Int) -> String? {
        node.releases.first { $0.version.major == major }?.lts
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).detailRow()
    }
}

/// Small icon-only "…" menu used in rows.
private struct RowMenu<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
