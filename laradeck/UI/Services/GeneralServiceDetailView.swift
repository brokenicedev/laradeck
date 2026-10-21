import AppKit
import SwiftUI

extension GeneralService {
    static let tint = Color(red: 0.11, green: 0.51, blue: 0.93)
}

/// Shared actions for a general service (sidebar context menu, detail "…" menu).
struct GeneralServiceMenuItems: View {
    @Environment(AppState.self) private var appState
    let service: GeneralService
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var services: GeneralServicesManager { appState.generalServices }

    var body: some View {
        Button(services.isRunning(service) ? "Stop" : "Start") { services.toggle(service) }
            .disabled(services.busy.contains(service.id) || !appState.dockerManager.isDaemonRunning)
        Button("Restart") { services.restart(service) }
            .disabled(!services.isRunning(service) || services.busy.contains(service.id))
        Toggle("Start When Laradeck Opens", isOn: Binding(
            get: { services.service(id: service.id)?.autoStart ?? false },
            set: { services.setAutoStart(service, $0) }
        ))
        Divider()
        Button("Edit YAML…", action: onEdit)
        Button("Show Compose File in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([services.composeURL(for: service)])
        }
        Divider()
        Button("Delete…", role: .destructive, action: onDelete)
    }
}

extension View {
    func generalServiceDeleteConfirmation(_ service: GeneralService?, isPresented: Binding<Bool>,
                                          onDelete: @escaping (_ removeVolumes: Bool) -> Void) -> some View {
        confirmationDialog("Delete \(service?.displayName ?? "service")?", isPresented: isPresented) {
            Button("Delete, Keep Volumes", role: .destructive) { onDelete(false) }
            Button("Delete with Volumes", role: .destructive) { onDelete(true) }
        } message: {
            Text("Containers are removed with docker compose down. Volumes hold the service's data (e.g. Mailpit's mailbox).")
        }
    }
}

struct GeneralServiceDetailView: View {
    @Environment(AppState.self) private var appState
    let service: GeneralService

    @State private var logTail = ""
    @State private var cleared = ClearedLog()
    @State private var showingEditor = false
    @State private var confirmingDelete = false

    private var services: GeneralServicesManager { appState.generalServices }
    private var containers: [DockerServiceStatus] { services.containers(service) }
    private var isRunning: Bool { services.isRunning(service) }
    private var isBusy: Bool { services.busy.contains(service.id) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let error = services.error {
                        NoticeBanner(tone: .error, message: error) { services.error = nil }
                    }
                    if !appState.dockerManager.isDaemonRunning {
                        NoticeBanner(tone: .warning, message: DockerManager.daemonUnavailableMessage)
                    }
                    containersCard
                    optionsCard
                    composeCard
                    }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            LogPanel(title: "Log · docker compose logs",
                     onClear: { cleared.clear(logTail) }) {
                LogTextView(text: cleared.visible(logTail))
            }
        }
        .background(LaradeckTheme.pageBackground)
        .navigationTitle(service.displayName)
        .detailCloseButton(help: "Close service") { appState.selectedServiceId = nil }
        .sheet(isPresented: $showingEditor) {
            GeneralServiceEditorSheet(editing: service)
        }
        .generalServiceDeleteConfirmation(service, isPresented: $confirmingDelete) { removeVolumes in
            appState.selectedServiceId = nil
            services.delete(service, removeVolumes: removeVolumes)
        }
        .task(id: isRunning) {
            while !Task.isCancelled {
                logTail = await services.logTail(service)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: service.systemImage)
                .font(.system(size: 26))
                .foregroundStyle(GeneralService.tint)
                .frame(width: 44, height: 44)
                .background(GeneralService.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(service.displayName)
                    .font(.title.weight(.semibold))
                HStack(spacing: 6) {
                    StatusDotView(color: isRunning ? .green : .gray, size: 8, pulsing: isBusy)
                    Text(statusText).foregroundStyle(.secondary)
                    PortBadgeView(ports: ports)
                }
            }

            Spacer()

            if isBusy { ProgressView().controlSize(.small) }

            if isRunning {
                Button {
                    services.restart(service)
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.laradeckOutline)
                .disabled(isBusy)
            }

            Button {
                services.toggle(service)
            } label: {
                Label(isRunning ? "Stop" : "Start", systemImage: isRunning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.laradeckOutline(accent: isRunning ? .red : .green))
            .disabled(isBusy || !appState.dockerManager.isDaemonRunning)

            Menu {
                GeneralServiceMenuItems(service: service,
                                        onEdit: { showingEditor = true },
                                        onDelete: { confirmingDelete = true })
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var ports: [Int] { Array(Set(containers.flatMap(\.ports))).sorted() }

    private var statusText: String {
        if isBusy { return "Working…" }
        if containers.isEmpty { return "Not created yet" }
        let running = containers.filter(\.isRunning).count
        return running == containers.count ? "Running" : (running == 0 ? "Stopped" : "\(running)/\(containers.count) running")
    }

    // MARK: Cards

    private var containersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Containers").font(.headline)
            VStack(spacing: 0) {
                if containers.isEmpty {
                    Text("Start the service to create its containers.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                ForEach(containers) { container in
                    HStack(spacing: 10) {
                        StatusDotView(color: container.color, size: 8)
                        Text(container.name).font(.body.weight(.medium))
                        Text(container.state)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ForEach(container.ports, id: \.self) { port in
                            Button {
                                NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!)
                            } label: {
                                HStack(spacing: 3) {
                                    Text(verbatim: ":\(port)")
                                    Image(systemName: "arrow.up.forward")
                                        .font(.caption2)
                                }
                                .font(.callout.monospaced())
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(!container.isRunning)
                            .help("Open http://localhost:\(port)")
                        }
                        Button {
                            TerminalLauncher.openContainerShell(appState.preferredTerminal,
                                                                projectPath: services.folder(for: service).path,
                                                                service: container.name)
                        } label: {
                            Image(systemName: "terminal")
                        }
                        .buttonStyle(.laradeckIcon())
                        .disabled(!container.isRunning)
                        .help("Open a shell in \(container.name)")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    if container.id != containers.last?.id {
                        Divider().padding(.leading, 32)
                    }
                }
            }
            .laradeckCard()
        }
    }

    private var optionsCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Start when Laradeck opens")
                Text("Runs docker compose up -d as soon as Docker is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Start when Laradeck opens", isOn: Binding(
                get: { services.service(id: service.id)?.autoStart ?? false },
                set: { services.setAutoStart(service, $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .laradeckCard()
    }

    private var composeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("compose.yaml").font(.headline.monospaced())
                Spacer()
                Button("Edit…") { showingEditor = true }
                    .buttonStyle(.link)
            }
            Text(services.yaml(for: service))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .laradeckCard()
        }
    }

}
