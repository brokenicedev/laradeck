import SwiftUI

struct SailServicesView: View {
    @Environment(AppState.self) private var appState
    let project: Project
    var onOpenLogs: (String) -> Void = { _ in }

    /// Compose output is opt-in — Sail Up / Start All shouldn't dump raw docker output on you
    /// unless something actually went wrong (see the `lastError` onChange below).
    @State private var showingComposeOutput = false

    private var services: [DockerServiceStatus] {
        appState.dockerManager.statusByProject[project.id] ?? []
    }

    private var isBusy: Bool {
        appState.dockerManager.isBusy(project.id)
    }

    private var lastError: String? {
        appState.dockerManager.lastErrorByProject[project.id]
    }

    private var dockerRunning: Bool {
        appState.dockerManager.isDaemonRunning
    }

    private var composeOutputBuffer: TerminalByteBuffer {
        appState.dockerManager.composeOutputBuffer(for: project.id)
    }

    private var showsComposeOutput: Bool {
        showingComposeOutput
    }

    private var isSailProject: Bool {
        project.environment == .sail
    }

    private var hasRunningContainers: Bool {
        services.contains { $0.isRunning || $0.isRestarting || $0.isHealthCheckStarting }
    }

    private var sectionTitle: String {
        isSailProject ? "Laravel Sail" : "Docker Compose"
    }

    private var upButtonTitle: String {
        isSailProject ? "Sail Up" : "Compose Up"
    }

    private var downButtonTitle: String {
        isSailProject ? "Sail Down" : "Compose Down"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if isSailProject {
                    LaravelLogoView(size: 16)
                } else {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.secondary)
                }
                Text(sectionTitle).font(.headline)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                if hasRunningContainers {
                    Button {
                        run { await appState.dockerManager.down(for: project) }
                    } label: {
                        Label(downButtonTitle, systemImage: "stop")
                    }
                    .buttonStyle(.laradeckOutline(accent: .red))
                    .disabled(isBusy || !dockerRunning)
                } else {
                    Button {
                        appState.composeUp(project)
                    } label: {
                        Label(upButtonTitle, systemImage: "play")
                    }
                    .buttonStyle(.laradeckOutline(accent: .green))
                    .disabled(isBusy || !dockerRunning)
                    .help(dockerRunning ? "Start containers" : DockerManager.daemonUnavailableMessage)
                }
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.laradeckOutline)
                .disabled(isBusy)

                Button {
                    showingComposeOutput.toggle()
                } label: {
                    Label("Logs", systemImage: TerminalLauncher.logsIconSystemName)
                }
                .buttonStyle(.laradeckOutline)

                if showingComposeOutput {
                    Button {
                        appState.dockerManager.clearComposeOutput(for: project.id)
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.laradeckOutline)
                    .disabled(isBusy || composeOutputBuffer.terminalData.isEmpty)
                }
            }

            if !dockerRunning {
                NoticeBanner(tone: .warning, message: DockerManager.daemonUnavailableMessage)
            }

            if let lastError {
                NoticeBanner(tone: .error, message: errorSummary(lastError)) {
                    appState.dockerManager.clearError(for: project.id)
                }
            }

            if showsComposeOutput {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if isBusy {
                            ProgressView()
                                .controlSize(.small)
                            Text("Running docker compose…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Compose output")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    TerminalOutputView(source: composeOutputBuffer, isActive: isBusy)
                        .frame(minHeight: 140, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                }
            }

            if services.isEmpty {
                NoticeBanner(
                    tone: .warning,
                    message: "No container status available. Try \"\(upButtonTitle)\" or \"Refresh\"."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(services) { service in
                        SailServiceRow(
                            project: project,
                            service: service,
                            preferredTerminal: appState.preferredTerminal,
                            dockerRunning: dockerRunning,
                            onOpenLogs: onOpenLogs
                        )
                        if service.id != services.last?.id {
                            Divider()
                        }
                    }
                }
                .laradeckCard(cornerRadius: 8)
            }
        }
        .task(id: project.id) { await refresh() }
        .onChange(of: lastError) { _, newValue in
            if newValue != nil {
                showingComposeOutput = true
            }
        }
    }

    private func refresh() async {
        await appState.dockerManager.refreshStatus(for: project)
    }

    private func run(_ operation: @escaping () async -> DockerCommandResult) {
        Task {
            _ = await operation()
            await refresh()
        }
    }

    /// Build/pull logs can be huge — the actual failure reason is almost always at the end.
    private func errorSummary(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 600
        guard trimmed.count > maxLength else { return trimmed }
        return "…" + trimmed.suffix(maxLength)
    }
}

/// Mirrors ProcessListView's row layout (status dot, icon, name/subtitle, trailing status) with
/// in-app logs and a system-terminal shell action per container.
private struct SailServiceRow: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let service: DockerServiceStatus
    let preferredTerminal: TerminalApp
    let dockerRunning: Bool
    let onOpenLogs: (String) -> Void

    private var canInteract: Bool {
        dockerRunning && service.isRunning
    }

    private func restartService() {
        Task {
            _ = await appState.dockerManager.restart(for: project, service: service.name)
            await appState.dockerManager.refreshStatus(for: project)
        }
    }

    private func stopService() {
        Task {
            _ = await appState.dockerManager.stop(for: project, service: service.name)
            await appState.dockerManager.refreshStatus(for: project)
        }
    }

    private func startService() {
        Task {
            _ = await appState.dockerManager.start(for: project, service: service.name)
            await appState.dockerManager.refreshStatus(for: project)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            StatusDotView(color: service.color)

            Image(systemName: Self.icon(for: service.name))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(service.color)
                .frame(width: 30, height: 30)
                .background(service.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(service.color.opacity(0.28), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(service.name)
                    .font(.system(size: 15, weight: .semibold))
                if let health = service.health {
                    Text(health)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !service.ports.isEmpty {
                PortBadgeView(ports: service.ports)
            }

            Divider().frame(height: 18)

            if service.isRunning {
                Button {
                    restartService()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .disabled(!canInteract)
                .help(canInteract ? "Restart container" : "Container must be running")

                Button {
                    stopService()
                } label: {
                    Image(systemName: "stop")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .frame(width: 22)
                .disabled(!canInteract)
                .help(canInteract ? "Stop container" : "Container must be running")
            } else {
                Button {
                    startService()
                } label: {
                    Image(systemName: "play")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.green)
                .frame(width: 22)
                .disabled(!dockerRunning)
                .help(dockerRunning ? "Start container" : "Docker must be running")
            }

            Button {
                onOpenLogs(LogManager.containerSource(service.name))
            } label: {
                Image(systemName: TerminalLauncher.logsIconSystemName)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: 22)
            .disabled(!canInteract)
            .help(canInteract ? "View container logs" : "Container must be running")

            Button {
                TerminalLauncher.openContainerShell(
                    preferredTerminal,
                    projectPath: project.path,
                    service: service.name
                )
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: 22)
            .disabled(!canInteract)
            .help(canInteract ? "Open shell in container" : "Container must be running")
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
    }

    private static func icon(for serviceName: String) -> String {
        let name = serviceName.lowercased()
        if name.contains("mysql") || name.contains("mariadb") || name.contains("pgsql") || name.contains("postgres") {
            return "cylinder.split.1x2"
        } else if name.contains("redis") {
            return "memorychip"
        } else if name.contains("mail") {
            return "envelope"
        } else if name.contains("meilisearch") || name.contains("search") || name.contains("elastic") {
            return "magnifyingglass"
        } else if name.contains("minio") || name.contains("s3") {
            return "externaldrive"
        }
        return "shippingbox"
    }
}
