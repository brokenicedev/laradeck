import AppKit
import PhpSwitcherCore
import SwiftUI

/// Toolbar status capsule (center of the window toolbar): Docker, PHP and the Laravel
/// installer at a glance, details in a popover.
struct EnvironmentStatusView: View {
    @Environment(AppState.self) private var appState
    @State private var showingDetails = false

    private var docker: DockerDaemonState { appState.dockerManager.daemonState }
    private var php: PHPVersionStatus { appState.phpVersionMonitor.status }
    private var installer: LaravelInstallerStatus { appState.laravelInstallerMonitor.status }
    private var node: NodeManager { appState.nodeManager }

    private var dockerIsProblem: Bool {
        docker == .stopped || docker == .notInstalled
    }

    var body: some View {
        Button {
            showingDetails.toggle()
        } label: {
            HStack(spacing: 12) {
                item(color: docker.color, systemImage: "shippingbox", text: dockerShort,
                     emphasized: dockerIsProblem)
                item(color: php.color, systemImage: "chevron.left.forwardslash.chevron.right", text: php.shortLabel)
                if node.isNvmInstalled {
                    item(color: node.defaultInstallation != nil ? .green : .gray, systemImage: "hexagon",
                         text: node.defaultInstallation.map { "Node \($0.version.major)" } ?? "Node")
                }
                HStack(spacing: 5) {
                    StatusDotView(color: installer.color, size: 7)
                    Text(installer.shortLabel)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help("Docker, PHP, Node and Laravel installer status")
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            details
        }
    }

    private var dockerShort: String {
        switch docker {
        case .unknown: return "Docker…"
        case .running: return "Docker"
        case .stopped: return "Docker stopped"
        case .notInstalled: return "No Docker"
        }
    }

    private func item(color: Color, systemImage: String, text: String, emphasized: Bool = false) -> some View {
        HStack(spacing: 5) {
            StatusDotView(color: color, size: 7)
            Image(systemName: systemImage)
            Text(text)
        }
        .foregroundStyle(emphasized ? Color.red : Color.secondary)
        .fontWeight(emphasized ? .semibold : .regular)
    }

    // MARK: Popover

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailRow(color: docker.color, systemImage: "shippingbox", title: "Docker", detail: docker.label) {
                if dockerIsProblem, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.docker.docker") {
                    Button("Open Docker Desktop") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                    .controlSize(.small)
                }
            }
            Divider()
            detailRow(color: php.color, systemImage: "chevron.left.forwardslash.chevron.right",
                      title: "PHP", detail: php.helpText) {
                phpSwitcher
            }
            if node.isNvmInstalled {
                Divider()
                detailRow(color: node.defaultInstallation != nil ? .green : .gray, systemImage: "hexagon",
                          title: "Node", detail: nodeDetail) {
                    nodeSwitcher
                }
            }
            Divider()
            detailRow(color: installer.color, systemImage: nil, title: "Laravel Installer",
                      detail: installer.helpText) {
                EmptyView()
            }
        }
        .frame(width: 340)
        .padding(.vertical, 4)
    }

    /// Quick switch between Homebrew PHP versions, plus a link to the PHP page.
    @ViewBuilder
    private var phpSwitcher: some View {
        let manager = appState.phpManager
        VStack(alignment: .leading, spacing: 6) {
            if !manager.installed.isEmpty {
                // Wraps onto two lines when there are many versions.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(manager.installed) { installation in
                        let isActive = manager.isActive(installation)
                        Button {
                            showingDetails = false
                            appState.switchPhpShowingProgress(to: installation)
                        } label: {
                            Text(installation.version.short)
                                .frame(minWidth: 34)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(isActive ? Color.green : Color.primary)
                        .fontWeight(isActive ? .semibold : .regular)
                        .disabled(isActive || manager.busy != nil)
                        .help(isActive ? "PHP \(installation.version.description) is linked" : "Switch to PHP \(installation.version.description)")
                    }
                }
            }
            if let busy = manager.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            PhpStatusBanners()
            Button("Open PHP Settings…") {
                showingDetails = false
                appState.showingPhp = true
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(.top, 4)
    }

    private var nodeDetail: String {
        guard let version = node.defaultInstallation?.version else { return "nvm has no default version" }
        return "Node \(version.description) is the nvm default. Projects can pick their own version."
    }

    /// Quick switch of the nvm default, plus a link to the Node page.
    private var nodeSwitcher: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !node.installed.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(node.installed) { installation in
                        let isDefault = node.isDefault(installation)
                        Button {
                            Task { await node.setDefault(installation) }
                        } label: {
                            Text(installation.version.description)
                                .frame(minWidth: 46)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(isDefault ? Color.green : Color.primary)
                        .fontWeight(isDefault ? .semibold : .regular)
                        .disabled(isDefault || node.busy != nil)
                        .help(isDefault ? "Node \(installation.version.description) is the nvm default"
                                        : "Make Node \(installation.version.description) the nvm default")
                    }
                }
            }
            if let busy = node.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let error = node.error {
                NoticeBanner(tone: .error, message: error) { node.error = nil }
            }
            Button("Open Node Settings…") {
                showingDetails = false
                appState.showingNode = true
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(.top, 4)
    }

    private func detailRow<Accessory: View>(color: Color, systemImage: String?, title: String, detail: String,
                                            @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(.secondary)
                } else {
                    LaravelLogoView(size: 14)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    StatusDotView(color: color, size: 7)
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

extension PHPVersionStatus {
    var color: Color {
        if case .installed = self { return .green }
        return .gray
    }

    var shortLabel: String {
        switch self {
        case .unknown: return "PHP…"
        case .installed(let version): return "PHP \(version)"
        case .notInstalled: return "No PHP"
        }
    }
}

extension LaravelInstallerStatus {
    var color: Color {
        if case .installed = self { return .green }
        return .gray
    }

    var shortLabel: String {
        switch self {
        case .unknown: return "Laravel…"
        case .installed(let version): return "Laravel \(version)"
        case .notInstalled: return "No Laravel installer"
        }
    }
}
